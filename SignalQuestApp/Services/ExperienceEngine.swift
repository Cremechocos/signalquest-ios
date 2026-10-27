import Foundation

/// Issue d'un transfert vers le serveur de mesure.
enum ExperienceFetch: Equatable, Sendable {
    case done
    case timedOut
    case failed(ExperienceFailureCause)
    case stopped
}

/// Pourquoi un test a échoué : pour l'écran seulement, jamais envoyé (le contrat
/// n'a pas de champ de raison pour `failed`).
enum ExperienceFailureCause: Equatable, Sendable {
    /// HTTP 429 : serveur de mesure limité.
    case serverBusy
    /// Redirection, jamais suivie : la route de mesure a changé.
    case routeChanged
    case generic

    static func http(_ status: Int) -> Self {
        switch status {
        case 429: .serverBusy
        case 300...399: .routeChanged
        default: .generic
        }
    }
}

/// Une ouverture de page telle que le transport l'a relevée.
struct ExperiencePageFetch: Sendable {
    let fetch: ExperienceFetch
    var times = ExperienceWebPhases.Times()
    var totalNanos: UInt64 = 0
    var protocolName: String?
}

/// Les transferts réels, à part du moteur : les tests rejouent une horloge virtuelle.
protocol ExperienceTransport: Sendable {
    /// `GET /__down?bytes=` ; tout le transfert tient dans `timeoutMs`. `shouldStop` est relu à chaque bloc reçu.
    func download(bytes: Int64, timeoutMs: Int64, shouldStop: @escaping @Sendable () -> Bool,
                  onRead: @escaping @Sendable (Int) -> Void) async -> ExperienceFetch
    /// `POST /__up` de contenu non compressible ; durée de la demande à la RÉPONSE du serveur.
    func upload(bytes: Int64, timeoutMs: Int64, shouldStop: @escaping @Sendable () -> Bool,
                onWrite: @escaping @Sendable (Int) -> Void) async -> (fetch: ExperienceFetch, nanos: Int64)
    /// Une ouverture de la page type sur une connexion neuve (document, puis 6 requêtes parallèles).
    func openPage(timeoutMs: Int64, shouldStop: @escaping @Sendable () -> Bool,
                  onRead: @escaping @Sendable (Int) -> Void) async -> ExperiencePageFetch
    /// Adresse IP du serveur de mesure, résolue une seule fois par test.
    func resolveHost() async -> String?
    /// Poignée de main TCP vers l'adresse:443 ; RTT en nanosecondes, nil en échec ou au-delà du délai.
    func tcpProbe(address: String, timeoutMs: Int64) async -> Int64?
}

/// Conditions relues pendant le test : une fausse arrête la suite, les tests finis sont gardés.
struct ExperienceConditions: Sendable {
    var isForeground: @Sendable () -> Bool = { true }
    var isSameNetwork: @Sendable () -> Bool = { true }
    var isOnline: @Sendable () -> Bool = { true }
}

/// Ce que l'écran montre pendant le test ; jamais enregistré.
struct ExperienceLive: Equatable, Sendable {
    let test: ExperienceTestKind
    var quality: ExperienceVideoQuality?
    var playedMs: Int64 = 0
    var bufferAheadMs: Int64 = 0
    /// Ouverture web (à partir de 1), sondes envoyées ou élément envoyé.
    var step = 0
    var latestRttMs: Int?
    var bytesUsed: Int64 = 0
    var stallCount = 0
}

/// Sortie du moteur : `stop` est la cause extérieure qui a coupé la suite.
struct ExperienceRun: Sendable {
    let tests: ExperienceTestsResult
    let bytesUsed: Int64
    let durationMs: Int64
    let stop: ExperienceStopReason?
    let failures: [ExperienceTestKind: ExperienceFailureCause]
    /// Consommation et durée de chaque test lancé : la somme des octets est `bytesUsed`.
    let usage: [ExperienceTestKind: ExperienceTestUsage]
}

struct ExperienceTestUsage: Equatable, Sendable {
    let bytes: Int64
    let durationMs: Int64
}

/// Moteur des tests d'expérience v3 (méthode révision 8) sur `speed.cloudflare.com` :
/// octets comptés à la lecture et à l'écriture, horloge monotone, rien d'extrapolé.
/// Mêmes déroulés et mêmes issues que le moteur Android (`ExperienceEngine.kt`).
final class ExperienceEngine: @unchecked Sendable {
    private let transport: ExperienceTransport
    private let conditions: ExperienceConditions
    private let recentLatency: ExperienceUnderLoad?
    private let nowNanos: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async -> Void

    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var stop: ExperienceStopReason?
    private var pendingStop: ExperienceStopReason?
    private var lastCheck: Int64?
    private var currentTest: ExperienceTestKind?
    private var failures: [ExperienceTestKind: ExperienceFailureCause] = [:]

    init(
        transport: ExperienceTransport,
        conditions: ExperienceConditions = ExperienceConditions(),
        recentLatency: ExperienceUnderLoad? = nil,
        nowNanos: @escaping @Sendable () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds) },
        sleep: @escaping @Sendable (Int64) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) }
    ) {
        self.transport = transport
        self.conditions = conditions
        self.recentLatency = recentLatency
        self.nowNanos = nowNanos
        self.sleep = sleep
    }

    /// « Arrêter » ou arrière-plan : le transfert en cours s'interrompt.
    func requestStop(_ reason: ExperienceStopReason = .userStopped) {
        lock.withLock { if pendingStop == nil { pendingStop = reason } }
    }

    var bytesUsed: Int64 { lock.withLock { bytes } }

    private func count(_ amount: Int) { lock.withLock { bytes += Int64(amount) } }

    func run(_ selected: Set<ExperienceTestKind>, onLive: @escaping @Sendable (ExperienceLive) -> Void = { _ in }) async -> ExperienceRun {
        let startedAt = nowNanos()
        var tests = ExperienceTestsResult()
        var usage: [ExperienceTestKind: ExperienceTestUsage] = [:]
        for key in ExperienceMethod.order where selected.contains(key) {
            if let blocked = interruption(force: true) {
                tests.set(key, notTested: blocked)
                continue
            }
            lock.withLock { currentTest = key }
            let bytesBefore = bytesUsed
            let testStartedAt = nowNanos()
            switch key {
            case .videoLadder: tests.videoLadder = await runLadder(onLive)
            case .videoAdaptive: tests.videoAdaptive = await runAdaptive(onLive)
            case .webPage: tests.webPage = await runWeb(onLive)
            case .gameAndCalls: tests.gameAndCalls = await runGame(onLive)
            case .upload: tests.upload = await runUpload(onLive)
            }
            usage[key] = ExperienceTestUsage(bytes: bytesUsed - bytesBefore, durationMs: (nowNanos() - testStartedAt) / 1_000_000)
        }
        let (used, stopped, failed) = lock.withLock { (bytes, stop, failures) }
        return ExperienceRun(
            tests: tests, bytesUsed: used, durationMs: (nowNanos() - startedAt) / 1_000_000, stop: stopped,
            failures: failed.filter { tests.state(of: $0.key) == .failed }, usage: usage
        )
    }

    // MARK: Arrêts

    /// La cause qui arrête la suite ; arrière-plan et réseau relus 4 fois par seconde.
    private func interruption(force: Bool = false) -> ExperienceStopReason? {
        let now = nowNanos()
        let check: Bool = lock.withLock {
            if stop == nil, let pending = pendingStop { stop = pending }
            guard stop == nil, force || lastCheck.map({ now - $0 >= 250_000_000 }) ?? true else { return false }
            lastCheck = now
            return true
        }
        if check {
            let reason: ExperienceStopReason? = !conditions.isForeground() ? .background
                : !conditions.isSameNetwork() ? .networkChanged : nil
            if let reason { lock.withLock { if stop == nil { stop = reason } } }
        }
        return lock.withLock { stop }
    }

    /// Un transfert a échoué : cause extérieure, perte de connexion, ou nil (serveur injoignable ou trop lent).
    private func failureReason() -> ExperienceStopReason? {
        if let reason = interruption(force: true) { return reason }
        guard !conditions.isOnline() else { return nil }
        lock.withLock { if stop == nil { stop = .offline } }
        return .offline
    }

    private var stopped: ExperienceStopReason? { lock.withLock { stop } }

    /// Retient la cause d'échec du test en cours (la plus précise l'emporte sur « générique »).
    private func remember(_ fetch: ExperienceFetch) {
        guard case .failed(let cause) = fetch else { return }
        lock.withLock {
            guard let key = currentTest else { return }
            if failures[key] == nil || failures[key] == .generic { failures[key] = cause }
        }
    }

    /// 429 ou redirection : pas de nouvel essai dans le même test.
    private var serverRefused: Bool {
        lock.withLock { currentTest.flatMap { failures[$0] }.map { $0 != .generic } ?? false }
    }

    private func sleepWatching(_ ms: Int64) async {
        var left = ms
        while left > 0, interruption() == nil {
            let slice = min(left, 250)
            await sleep(slice)
            left -= slice
        }
    }

    private func download(_ size: Int64, timeoutMs: Int64, onRead: @escaping @Sendable (Int) -> Void = { _ in }) async -> ExperienceFetch {
        let fetch = await transport.download(
            bytes: size, timeoutMs: timeoutMs, shouldStop: { [weak self] in self?.interruption() != nil },
            onRead: { [weak self] read in
                self?.count(read)
                onRead(read)
            }
        )
        remember(fetch)
        return fetch
    }

    // MARK: Vidéo : échelle

    private func runLadder(_ onLive: @escaping @Sendable (ExperienceLive) -> Void) async -> ExperienceLadderResult {
        var rungs: [ExperienceRung] = []
        var ended = false
        for quality in ExperienceVideoQuality.allCases {
            guard !ended, stopped == nil, let rung = await playRung(quality, onLive) else {
                rungs.append(ExperienceRung(quality: quality, state: .notTested))
                continue
            }
            rungs.append(rung)
            // On ne monte que si la qualité n'a eu aucune coupure.
            if rung.state != .measured || !rung.stalls.isEmpty { ended = true }
        }
        if let reason = stopped { return ExperienceLadderResult(state: .interrupted, reason: reason, rungs: rungs) }
        return ExperienceLadderResult(state: rungs.contains { $0.state == .measured } ? .measured : .failed, rungs: rungs)
    }

    /// Un palier : 5 segments de 2 s à la suite, joués jusqu'au bout même après une
    /// coupure. nil si la suite s'arrête pendant le palier.
    private func playRung(_ quality: ExperienceVideoQuality, _ onLive: @escaping @Sendable (ExperienceLive) -> Void) async -> ExperienceRung? {
        var model = ExperiencePlaybackModel()
        let bytesAtStart = bytesUsed
        let startAll = nowNanos()
        var startupMs: Int64?
        var abandoned = false
        var pending: ExperienceStall?
        var lastEventAt = startAll
        let maxWaitNanos = ExperienceMethod.maxStallWaitMs * 1_000_000
        for k in 0..<ExperienceMethod.ladderSegmentsPerRung {
            if interruption() != nil { return nil }
            let requestedAt = nowNanos()
            let timeoutMs = k == 0
                ? ExperienceMethod.startupTimeoutMs
                : max(1, (model.drainsAt + maxWaitNanos - requestedAt) / 1_000_000)
            let fetch = await download(quality.segmentBytes, timeoutMs: timeoutMs)
            let now = nowNanos()
            switch fetch {
            case .stopped:
                return nil
            case .done:
                // Arrivé plus de 6 s après l'instant où la lecture l'attendait : abandon.
                if k > 0 && model.waitingNanos(at: now) > maxWaitNanos {
                    pending = model.pendingStall(at: now)
                    abandoned = true
                } else {
                    model.onSegment(at: now)
                    if k == 0 { startupMs = (now - requestedAt) / 1_000_000 }
                    onLive(ExperienceLive(
                        test: .videoLadder, quality: quality,
                        playedMs: Int64(model.segmentCount) * ExperienceMethod.segmentMs - model.bufferAheadMs(at: now),
                        bufferAheadMs: model.bufferAheadMs(at: now), bytesUsed: bytesUsed, stallCount: model.stalls.count
                    ))
                }
            case .timedOut:
                pending = k == 0 ? nil : model.pendingStall(at: now)
                abandoned = true
            case .failed:
                if failureReason() != nil { return nil }
                abandoned = true
            }
            lastEventAt = now
            if abandoned { break }
        }
        let stalls = model.stalls + [pending].compactMap { $0 }
        let rungBytes = bytesUsed - bytesAtStart
        let elapsed = max(1, lastEventAt - startAll)
        let receivedBps = ExperienceSubmission.roundHalfUp(Double(rungBytes) * 8 * 1e9 / Double(elapsed))
        if abandoned {
            return ExperienceRung(quality: quality, state: .abandoned, startupMs: startupMs, stalls: stalls,
                                  receivedBps: receivedBps, bytes: rungBytes)
        }
        return ExperienceRung(quality: quality, state: .measured, startupMs: startupMs, stalls: stalls,
                              bufferMinMs: model.bufferMinMs, bufferAvgMs: model.bufferAvgMs(),
                              receivedBps: receivedBps, bytes: rungBytes)
    }

    // MARK: Vidéo : lecteur adaptatif

    private func runAdaptive(_ onLive: @escaping @Sendable (ExperienceLive) -> Void) async -> ExperienceAdaptiveResult {
        var model = ExperiencePlaybackModel()
        var transfers: [ExperienceAdaptivePlayer.SegmentTransfer] = []
        var timeByQuality: [ExperienceVideoQuality: Int64] = [:]
        let total = Int(ExperienceMethod.adaptivePlaybackMs / ExperienceMethod.segmentMs)
        var current = ExperienceVideoQuality.p480
        var up = 0
        var down = 0
        var startupMs: Int64?
        var failed = false
        var pending: ExperienceStall?
        let maxWaitNanos = ExperienceMethod.maxStallWaitMs * 1_000_000

        for j in 0..<total {
            if interruption() != nil { break }
            // Pas de segment suivant tant que l'avance est ≥ 10 s.
            if j > 0 {
                let ahead = model.bufferAheadMs(at: nowNanos())
                if ahead >= ExperienceMethod.adaptiveTargetBufferMs {
                    await sleepWatching(ahead - ExperienceMethod.adaptiveTargetBufferMs + 1)
                    if interruption() != nil { break }
                }
            }
            let quality = j == 0 ? .p480 : ExperienceAdaptivePlayer.next(
                current: current, throughputBps: ExperienceAdaptivePlayer.throughputBps(transfers),
                bufferMs: model.bufferAheadMs(at: nowNanos())
            )
            let requestedAt = nowNanos()
            let timeoutMs = j == 0
                ? ExperienceMethod.startupTimeoutMs
                : max(1, (model.drainsAt + maxWaitNanos - requestedAt) / 1_000_000)
            let fetch = await download(quality.segmentBytes, timeoutMs: timeoutMs)
            let now = nowNanos()
            if case .stopped = fetch { break }
            if case .failed = fetch {
                if failureReason() == nil { failed = true }
                break
            }
            if fetch == .timedOut || (j > 0 && model.waitingNanos(at: now) > maxWaitNanos) {
                // Plus de 6 s d'attente (ou un démarrage au-delà de 10 s) : la lecture est abandonnée.
                pending = j == 0 ? nil : model.pendingStall(at: now)
                failed = true
                break
            }
            model.onSegment(at: now)
            transfers.append(.init(bytes: quality.segmentBytes, nanos: now - requestedAt))
            timeByQuality[quality, default: 0] += ExperienceMethod.segmentMs
            if j == 0 { startupMs = (now - requestedAt) / 1_000_000 } else if quality > current { up += 1 } else if quality < current { down += 1 }
            current = quality
            onLive(ExperienceLive(
                test: .videoAdaptive, quality: quality,
                playedMs: Int64(model.segmentCount) * ExperienceMethod.segmentMs - model.bufferAheadMs(at: now),
                bufferAheadMs: model.bufferAheadMs(at: now), bytesUsed: bytesUsed, stallCount: model.stalls.count
            ))
        }

        let stalls = model.stalls + [pending].compactMap { $0 }
        let received = model.segmentCount
        let external = stopped
        let playbackMs: Int64? = received == 0 ? nil : external != nil
            ? max(0, Int64(received) * ExperienceMethod.segmentMs - model.bufferAheadMs(at: nowNanos()))
            : Int64(received) * ExperienceMethod.segmentMs
        var result = ExperienceAdaptiveResult(
            state: .failed, playbackMs: playbackMs, startupMs: startupMs, timeByQualityMs: timeByQuality,
            switchesUp: received > 0 ? up : nil, switchesDown: received > 0 ? down : nil, stalls: received > 0 ? stalls : nil
        )
        if let external { return ExperienceAdaptiveResult(state: .interrupted, reason: external, playbackMs: playbackMs, startupMs: startupMs,
                                                          timeByQualityMs: timeByQuality, switchesUp: result.switchesUp,
                                                          switchesDown: result.switchesDown, stalls: result.stalls) }
        guard !failed, received == total, let startupMs else { return result }
        result = ExperienceAdaptiveResult(
            state: .measured, playbackMs: playbackMs, startupMs: startupMs, timeByQualityMs: timeByQuality,
            switchesUp: up, switchesDown: down, stalls: stalls,
            score: ExperienceVideoScoring.score(timeByQualityMs: timeByQuality, stalls: stalls, startupMs: startupMs)
        )
        return result
    }

    // MARK: Web

    private func runWeb(_ onLive: @escaping @Sendable (ExperienceLive) -> Void) async -> ExperienceWebResult {
        var openings: [ExperienceWebOpening] = []
        for index in 1...ExperienceMethod.webOpenings {
            if interruption() != nil { break }
            onLive(ExperienceLive(test: .webPage, step: index, bytesUsed: bytesUsed))
            let page = await transport.openPage(
                timeoutMs: ExperienceMethod.webOpeningTimeoutMs, shouldStop: { [weak self] in self?.interruption() != nil },
                onRead: { [weak self] in self?.count($0) }
            )
            remember(page.fetch)
            switch page.fetch {
            case .stopped:
                break
            case .done:
                openings.append(ExperienceWebPhases.opening(page.times, totalNanos: page.totalNanos, protocolName: page.protocolName))
                continue
            case .failed, .timedOut:
                if failureReason() != nil { break }
                openings.append(ExperienceWebOpening(measured: false, protocolName: page.protocolName))
                // 429 ou redirection : rouvrir la page ne changerait rien.
                if serverRefused { break }
                continue
            }
            break
        }
        let measured = openings.contains { $0.measured }
        if let reason = stopped { return ExperienceWebResult(state: .interrupted, reason: reason, openings: openings) }
        return ExperienceWebResult(
            state: measured ? .measured : .failed,
            pageBytes: measured ? ExperienceMethod.webPageBytes : nil,
            parallelRequests: measured ? ExperienceMethod.webParallelRequests : nil,
            openings: openings
        )
    }

    // MARK: Jeu et appels

    private func runGame(_ onLive: @escaping @Sendable (ExperienceLive) -> Void) async -> ExperienceGameResult {
        guard let address = await transport.resolveHost() else {
            if let reason = failureReason() { return ExperienceGameResult(state: .interrupted, reason: reason) }
            return ExperienceGameResult(state: .failed)
        }
        // Sonde de chauffe, NON comptée : elle sort la radio de veille.
        _ = await transport.tcpProbe(address: address, timeoutMs: ExperienceMethod.gameProbeTimeoutMs)
        let bytes: @Sendable () -> Int64 = { [weak self] in self?.bytesUsed ?? 0 }
        let probes = await runProbes(address, slots: ExperienceMethod.gameProbeSlots, while: { true }) { rtt, sent in
            onLive(ExperienceLive(test: .gameAndCalls, step: sent, latestRttMs: rtt, bytesUsed: bytes()))
        }
        if let reason = stopped { return ExperienceGameResult(state: .interrupted, reason: reason) }
        guard ExperienceGameStats.hasEnoughProbes(sent: probes.sent, valid: probes.valid.count),
              let summary = ExperienceGameStats.summarize(probes.valid) else {
            // Réseau trop instable pour une médiane honnête : les sondes réussies restent montrées.
            return ExperienceGameResult(state: .failed, probeMethod: "tcp_connect", series: probes.valid)
        }
        let underLoad = await measureUnderLoad(address)
        if let reason = stopped { return ExperienceGameResult(state: .interrupted, reason: reason) }
        return ExperienceGameResult(
            state: .measured, probeMethod: "tcp_connect", medianMs: summary.medianMs, jitterMs: summary.jitterMs,
            maxMs: summary.maxMs, spikeCount: summary.spikeCount, spikeShare: summary.spikeShare,
            series: probes.valid, underLoad: underLoad
        )
    }

    /// Sondes TCP sur une grille de créneaux de 100 ms, au plus 2 en vol : un créneau
    /// sauté faute de place n'est ni envoyé ni compté. RTT valides dans l'ordre des créneaux.
    private func runProbes(
        _ address: String, slots: Int, while shouldContinue: @escaping @Sendable () -> Bool,
        onProbe: @escaping @Sendable (Int?, Int) -> Void = { _, _ in }
    ) async -> (valid: [Int], sent: Int) {
        let state = ProbeState(slots: slots)
        let start = nowNanos()
        await withTaskGroup(of: Void.self) { group in
            for slot in 0..<slots {
                if !shouldContinue() || interruption() != nil { break }
                let wait = (start + Int64(slot) * ExperienceMethod.gameProbeIntervalMs * 1_000_000 - nowNanos()) / 1_000_000
                if wait > 0 { await sleepWatching(wait) }
                if !shouldContinue() || interruption() != nil { break }
                guard let sent = state.tryLaunch(max: ExperienceMethod.gameMaxInFlight) else { continue }
                group.addTask { [transport] in
                    let rtt = await transport.tcpProbe(address: address, timeoutMs: ExperienceMethod.gameProbeTimeoutMs)
                    let ms = rtt.map { Int((Double($0) / 1e6).rounded()) }
                    state.finish(slot: slot, rttMs: ms)
                    onProbe(ms, sent)
                }
            }
        }
        return (state.valid, state.sent)
    }

    /// Latence sous charge : reprise d'un speedtest récent du même réseau, sinon courte charge.
    private func measureUnderLoad(_ address: String) async -> ExperienceUnderLoad? {
        if let recentLatency { return recentLatency }
        let idle = await runProbes(address, slots: ExperienceMethod.loadIdleProbes, while: { true })
        guard stopped == nil, let idleMs = ExperienceHighlights.median(idle.valid) else { return nil }
        let down = await loadedLatency(address, upload: false)
        guard stopped == nil else { return nil }
        let up = await loadedLatency(address, upload: true)
        guard stopped == nil,
              let grade = ExperienceGameStats.underLoadGrade(idleMs: Double(idleMs), loadedDownMs: down.map(Double.init),
                                                            loadedUpMs: up.map(Double.init)) else { return nil }
        return ExperienceUnderLoad(
            idleMs: Int64(idleMs), loadedDownMs: down.map(Int64.init), loadedUpMs: up.map(Int64.init),
            grade: grade.grade, deltaMs: ExperienceSubmission.roundHalfUp(grade.deltaMs), source: .shortLoad
        )
    }

    /// Médiane des sondes pendant une charge de 5 s au plus, moitié du budget par sens, en 4 flux.
    private func loadedLatency(_ address: String, upload: Bool) async -> Int? {
        let active = LoadFlag()
        let perStream = ExperienceMethod.loadMaxBytes / 2 / Int64(ExperienceMethod.loadStreams)
        let timeoutMs = ExperienceMethod.loadSeconds * 1_000
        async let probing = runProbes(address, slots: ExperienceMethod.loadedProbeSlots, while: { active.isOn })
        let loads = await withTaskGroup(of: ExperienceFetch.self) { group in
            for _ in 0..<ExperienceMethod.loadStreams {
                group.addTask { [self] in
                    // La charge s'arrête au délai de 5 s : un délai dépassé est ici le cas normal.
                    if upload {
                        let sent = await transport.upload(
                            bytes: perStream, timeoutMs: timeoutMs, shouldStop: { [weak self] in self?.interruption() != nil },
                            onWrite: { [weak self] in self?.count($0) }
                        )
                        remember(sent.fetch)
                        return sent.fetch
                    }
                    return await download(perStream, timeoutMs: timeoutMs)
                }
            }
            var fetches: [ExperienceFetch] = []
            for await fetch in group { fetches.append(fetch) }
            return fetches
        }
        active.isOn = false
        let samples = await probing.valid
        // Une charge refusée (429, redirection, erreur) n'a pas chargé la liaison.
        if loads.contains(where: { if case .failed = $0 { true } else { false } }) { return nil }
        return samples.count < ExperienceMethod.loadMinSamples ? nil : ExperienceHighlights.median(samples)
    }

    // MARK: Envoi photo et vidéo

    private func runUpload(_ onLive: @escaping @Sendable (ExperienceLive) -> Void) async -> ExperienceUploadResult {
        var items: [ExperienceUploadItem] = []
        let plan: [(ExperienceUploadItem.Kind, Int64)] = [(.photo, ExperienceMethod.uploadPhotoBytes), (.video, ExperienceMethod.uploadVideoBytes)]
        for (index, entry) in plan.enumerated() {
            if interruption() != nil { break }
            onLive(ExperienceLive(test: .upload, step: index + 1, bytesUsed: bytesUsed))
            let sent = await transport.upload(
                bytes: entry.1, timeoutMs: ExperienceMethod.uploadTimeoutMs, shouldStop: { [weak self] in self?.interruption() != nil },
                onWrite: { [weak self] in self?.count($0) }
            )
            remember(sent.fetch)
            switch sent.fetch {
            case .done: items.append(ExperienceUploadItem(kind: entry.0, bytes: entry.1, totalMs: sent.nanos / 1_000_000))
            case .stopped: break
            case .timedOut: continue
            case .failed: if failureReason() != nil || serverRefused { break } else { continue }
            }
            if case .done = sent.fetch { continue }
            break
        }
        if let reason = stopped { return ExperienceUploadResult(state: .interrupted, reason: reason, items: items) }
        return ExperienceUploadResult(state: items.isEmpty ? .failed : .measured, items: items)
    }
}

private extension ExperienceTestsResult {
    mutating func set(_ key: ExperienceTestKind, notTested reason: ExperienceStopReason) {
        switch key {
        case .videoLadder: videoLadder = ExperienceLadderResult(state: .notTested, reason: reason)
        case .videoAdaptive: videoAdaptive = ExperienceAdaptiveResult(state: .notTested, reason: reason)
        case .webPage: webPage = ExperienceWebResult(state: .notTested, reason: reason)
        case .gameAndCalls: gameAndCalls = ExperienceGameResult(state: .notTested, reason: reason)
        case .upload: upload = ExperienceUploadResult(state: .notTested, reason: reason)
        }
    }
}

/// Créneaux de sondes : en vol, envoyées, RTT par créneau.
private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Int?]
    private var inFlight = 0
    private var sentCount = 0

    init(slots: Int) { results = Array(repeating: nil, count: slots) }

    /// Rend le rang de la sonde envoyée, ou nil si 2 sondes sont déjà en vol.
    func tryLaunch(max: Int) -> Int? {
        lock.withLock {
            guard inFlight < max else { return nil }
            inFlight += 1
            sentCount += 1
            return sentCount
        }
    }

    func finish(slot: Int, rttMs: Int?) {
        lock.withLock {
            inFlight -= 1
            results[slot] = rttMs
        }
    }

    var valid: [Int] { lock.withLock { results.compactMap { $0 } } }
    var sent: Int { lock.withLock { sentCount } }
}

private final class LoadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

/// Transport réel vers `speed.cloudflare.com` : jamais de redirection suivie ni de cache,
/// octets comptés au fil de la réception et de l'envoi.
final class URLSessionExperienceTransport: NSObject, ExperienceTransport, @unchecked Sendable {
    private let host: String
    private let session: URLSession
    private let tcp = NetworkSpeedtestTCPProbe()
    /// Contenu non compressible, tiré une fois et répété.
    private static let chunk: Data = {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<65_536).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }()

    init(host: String = ExperienceMethod.host) {
        self.host = host
        session = URLSession(configuration: Self.configuration())
    }

    deinit { session.invalidateAndCancel() }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        return configuration
    }

    private func url(_ path: String) -> URL? { URL(string: "https://\(host)\(path)") }

    func download(bytes: Int64, timeoutMs: Int64, shouldStop: @escaping @Sendable () -> Bool,
                  onRead: @escaping @Sendable (Int) -> Void) async -> ExperienceFetch {
        await fetch(bytes: bytes, in: session, timeoutMs: timeoutMs, shouldStop: shouldStop, onRead: onRead).fetch
    }

    func upload(bytes: Int64, timeoutMs: Int64, shouldStop: @escaping @Sendable () -> Bool,
                onWrite: @escaping @Sendable (Int) -> Void) async -> (fetch: ExperienceFetch, nanos: Int64) {
        guard let url = url("/__up") else { return (.failed(.generic), 0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        var body = Data(capacity: Int(bytes))
        while body.count < Int(bytes) { body.append(Self.chunk.prefix(Int(bytes) - body.count)) }
        let task = session.uploadTask(with: request, from: body)
        let outcome = await ExperienceTaskRunner(task: task, expectedBytes: nil, timeoutMs: timeoutMs, shouldStop: shouldStop,
                                                 onRead: { _ in }, onWrite: onWrite).run()
        // Durée de la demande à la réponse : le dernier octet écrit ne dit rien du débit réel.
        return (outcome.fetch, outcome.fetch == .done ? outcome.responseNanos : 0)
    }

    func openPage(timeoutMs: Int64, shouldStop: @escaping @Sendable () -> Bool,
                  onRead: @escaping @Sendable (Int) -> Void) async -> ExperiencePageFetch {
        // Session neuve par ouverture : aucune connexion ni résolution réutilisée.
        let pageSession = URLSession(configuration: Self.configuration())
        defer { pageSession.invalidateAndCancel() }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        func remainingMs() -> Int64 {
            max(1, timeoutMs - Int64((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000))
        }
        let document = await fetch(bytes: ExperienceMethod.webDocumentBytes, in: pageSession, timeoutMs: remainingMs(),
                                   shouldStop: shouldStop, onRead: onRead)
        var page = ExperiencePageFetch(fetch: document.fetch, times: document.times, protocolName: document.protocolName)
        guard document.fetch == .done else { return page }
        let rest = ExperienceMethod.webPageBytes - ExperienceMethod.webDocumentBytes
        let count = ExperienceMethod.webParallelRequests
        let part = rest / Int64(count)
        let timeout = remainingMs()
        let parts = await withTaskGroup(of: ExperienceFetch.self) { group in
            for index in 0..<count {
                let size = index == count - 1 ? rest - part * Int64(index) : part
                group.addTask { [self] in
                    await fetch(bytes: size, in: pageSession, timeoutMs: timeout, shouldStop: shouldStop, onRead: onRead).fetch
                }
            }
            var fetches: [ExperienceFetch] = []
            for await fetch in group { fetches.append(fetch) }
            return fetches
        }
        if parts.contains(.stopped) {
            page = ExperiencePageFetch(fetch: .stopped, protocolName: page.protocolName)
        } else if let failed = parts.first(where: { $0 != .done }) {
            page = ExperiencePageFetch(fetch: failed, protocolName: page.protocolName)
        } else {
            page.totalNanos = DispatchTime.now().uptimeNanoseconds - startedAt
        }
        return page
    }

    func resolveHost() async -> String? {
        let host = host
        return await Task.detached { try? ICMPPinger.resolve(host: host).addressText }.value
    }

    func tcpProbe(address: String, timeoutMs: Int64) async -> Int64? {
        guard let ms = try? await tcp.connectLatencyMs(host: address, port: ExperienceMethod.tcpPort,
                                                       timeoutSeconds: Double(timeoutMs) / 1_000) else { return nil }
        return Int64((ms * 1_000_000).rounded())
    }

    private func fetch(bytes: Int64, in session: URLSession, timeoutMs: Int64, shouldStop: @escaping @Sendable () -> Bool,
                       onRead: @escaping @Sendable (Int) -> Void) async -> ExperienceTaskRunner.Outcome {
        guard let url = url("/__down?bytes=\(bytes)") else { return .init(fetch: .failed(.generic)) }
        var request = URLRequest(url: url)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return await ExperienceTaskRunner(task: session.dataTask(with: request), expectedBytes: bytes, timeoutMs: timeoutMs,
                                          shouldStop: shouldStop, onRead: onRead, onWrite: { _ in }).run()
    }
}

/// Une tâche URLSession suivie par son propre délégué : délai global, arrêt relu toutes les
/// 250 ms, statut vérifié avant le corps, phases relevées sur la transaction réseau.
private final class ExperienceTaskRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Outcome: Sendable {
        var fetch: ExperienceFetch
        var times = ExperienceWebPhases.Times()
        var protocolName: String?
        var responseNanos: Int64 = 0
    }

    private let task: URLSessionTask
    private let expectedBytes: Int64?
    private let timeoutMs: Int64
    private let shouldStop: @Sendable () -> Bool
    private let onRead: @Sendable (Int) -> Void
    private let onWrite: @Sendable (Int) -> Void

    private let lock = NSLock()
    private var received: Int64 = 0
    private var ended: ExperienceFetch?
    private var outcome = Outcome(fetch: .failed(.generic))
    private var continuation: CheckedContinuation<Outcome, Never>?
    private let startedAt = DispatchTime.now().uptimeNanoseconds

    init(task: URLSessionTask, expectedBytes: Int64?, timeoutMs: Int64, shouldStop: @escaping @Sendable () -> Bool,
         onRead: @escaping @Sendable (Int) -> Void, onWrite: @escaping @Sendable (Int) -> Void) {
        self.task = task
        self.expectedBytes = expectedBytes
        self.timeoutMs = timeoutMs
        self.shouldStop = shouldStop
        self.onRead = onRead
        self.onWrite = onWrite
    }

    func run() async -> Outcome {
        task.delegate = self
        let watcher = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let elapsedMs = Int64((DispatchTime.now().uptimeNanoseconds - self.startedAt) / 1_000_000)
                if self.shouldStop() { self.end(.stopped) } else if elapsedMs >= self.timeoutMs { self.end(.timedOut) }
            }
        }
        defer { watcher.cancel() }
        return await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            task.resume()
        }
    }

    /// Première issue retenue ; la tâche est annulée, `didCompleteWithError` rend le résultat.
    private func end(_ fetch: ExperienceFetch) {
        let first: Bool = lock.withLock {
            guard ended == nil else { return false }
            ended = fetch
            return true
        }
        if first { task.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Jamais suivie : une redirection de l'edge signale une route de mesure changée.
        end(.failed(.routeChanged))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.withLock { outcome.responseNanos = Int64(DispatchTime.now().uptimeNanoseconds - startedAt) }
        guard (200...299).contains(status) else {
            end(.failed(.http(status)))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { received += Int64(data.count) }
        onRead(data.count)
        if shouldStop() { end(.stopped) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onWrite(Int(bytesSent))
        if shouldStop() { end(.stopped) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad }) else { return }
        // Dates du système ramenées sur l'horloge monotone par leur écart au début de la transaction.
        let base = transaction.fetchStartDate ?? metrics.taskInterval.start
        func nanos(_ date: Date?) -> UInt64? {
            date.map { UInt64(max(0, $0.timeIntervalSince(base)) * 1e9) }
        }
        var times = ExperienceWebPhases.Times()
        times.dnsStart = nanos(transaction.domainLookupStartDate)
        times.dnsEnd = nanos(transaction.domainLookupEndDate)
        times.connectStart = nanos(transaction.connectStartDate)
        times.connectEnd = nanos(transaction.connectEndDate)
        times.secureStart = nanos(transaction.secureConnectionStartDate)
        times.secureEnd = nanos(transaction.secureConnectionEndDate)
        times.requestStart = nanos(transaction.requestStartDate)
        times.responseStart = nanos(transaction.responseStartDate)
        times.reusedConnection = transaction.isReusedConnection
        lock.withLock {
            outcome.times = times
            outcome.protocolName = transaction.networkProtocolName
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            guard let continuation else { return }
            self.continuation = nil
            if let ended {
                outcome.fetch = ended
            } else if let error {
                outcome.fetch = (error as? URLError)?.code == .timedOut ? .timedOut : .failed(.generic)
            } else if let expectedBytes, received < expectedBytes {
                outcome.fetch = .failed(.generic)
            } else {
                outcome.fetch = .done
            }
            continuation.resume(returning: outcome)
        }
    }
}
