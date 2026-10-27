import Foundation

/// Lecture simulée (méthode §1 et §2) : rien n'est décodé, seul le réseau est
/// mesuré. À partir des instants réels d'arrivée des segments (horloge monotone,
/// en nanosecondes), le modèle rejoue une lecture à vitesse normale qui démarre à
/// l'arrivée du premier segment et attend quand le tampon est vide.
struct ExperiencePlaybackModel: Sendable {
    private let segmentNanos: Int64
    private var started = false
    private var startAt: Int64 = 0
    private var lastAt: Int64 = 0
    /// Avance de lecture à `lastAt`, en nanosecondes de vidéo.
    private var buffer: Int64 = 0
    private var played: Int64 = 0
    private var integral: Double = 0
    private var minBeforeArrival: Int64?
    private(set) var stalls: [ExperienceStall] = []
    private(set) var segmentCount = 0

    init(segmentMs: Int64 = ExperienceMethod.segmentMs) {
        segmentNanos = segmentMs * 1_000_000
    }

    /// Instant où le tampon se vide si rien n'arrive.
    var drainsAt: Int64 { lastAt + buffer }

    /// Avance minimale juste avant l'arrivée d'un segment, à partir du 2ᵉ.
    var bufferMinMs: Int64? { minBeforeArrival.map { $0 / 1_000_000 } }

    /// Avance en millisecondes à `now` (affichage en direct, jamais enregistrée).
    func bufferAheadMs(at now: Int64) -> Int64 {
        started ? max(0, buffer - (now - lastAt)) / 1_000_000 : 0
    }

    /// Attente en cours à `now` : positive seulement si le tampon est déjà vide.
    func waitingNanos(at now: Int64) -> Int64 {
        started ? max(0, now - drainsAt) : 0
    }

    mutating func onSegment(at time: Int64) {
        guard started else {
            started = true
            startAt = time
            lastAt = time
            buffer = segmentNanos
            segmentCount = 1
            return
        }
        let dt = max(0, time - lastAt)
        if buffer >= dt {
            integral += Double(buffer + (buffer - dt)) / 2 * Double(dt)
            buffer -= dt
            played += dt
            minBeforeArrival = min(minBeforeArrival ?? buffer, buffer)
        } else {
            // Le tampon s'est vidé avant l'arrivée : coupure à la position de lecture atteinte.
            integral += Double(buffer) * Double(buffer) / 2
            played += buffer
            stalls.append(ExperienceStall(atPlaybackMs: played / 1_000_000, waitMs: (dt - buffer) / 1_000_000))
            buffer = 0
            minBeforeArrival = 0
        }
        buffer += segmentNanos
        lastAt = time
        segmentCount += 1
    }

    /// Coupure en cours à `now`, sans l'ajouter : le segment attendu n'arrivera pas.
    func pendingStall(at now: Int64) -> ExperienceStall? {
        let wait = waitingNanos(at: now)
        guard started, wait > 0 else { return nil }
        return ExperienceStall(atPlaybackMs: (played + buffer) / 1_000_000, waitMs: wait / 1_000_000)
    }

    /// Avance moyenne sur la lecture, en millisecondes (le tampon est lu jusqu'au bout).
    func bufferAvgMs() -> Int64? {
        guard started else { return nil }
        let total = integral + Double(buffer) * Double(buffer) / 2
        let duration = lastAt + buffer - startAt
        return duration <= 0 ? nil : Int64(total / Double(duration) / 1_000_000)
    }
}

/// Choix de qualité du lecteur adaptatif (méthode §2).
enum ExperienceAdaptivePlayer {
    struct SegmentTransfer: Equatable, Sendable {
        let bytes: Int64
        let nanos: Int64
    }

    /// La plus haute qualité dont le débit nécessaire est ≤ 80 % du débit de décision.
    static func target(throughputBps: Double) -> ExperienceVideoQuality {
        ExperienceVideoQuality.allCases.last { Double($0.requiredBps) <= throughputBps * ExperienceMethod.adaptiveSafety } ?? .p480
    }

    /// Départ en 480p ; montée d'un cran à la fois si le tampon est ≥ 8 s ;
    /// descente immédiate vers la cible si le tampon est < 4 s.
    static func next(current: ExperienceVideoQuality, throughputBps: Double?, bufferMs: Int64) -> ExperienceVideoQuality {
        guard let throughputBps else { return .p480 }
        let target = target(throughputBps: throughputBps)
        if bufferMs < ExperienceMethod.adaptiveDropBelowBufferMs && target < current { return target }
        if target > current && bufferMs >= ExperienceMethod.adaptiveClimbMinBufferMs { return current.higher ?? current }
        return current
    }

    /// Débit des 3 derniers segments : octets × 8 ÷ temps de réception.
    static func throughputBps(_ recent: [SegmentTransfer]) -> Double? {
        let window = recent.suffix(ExperienceMethod.adaptiveThroughputWindow)
        let nanos = window.reduce(Int64(0)) { $0 + $1.nanos }
        guard !window.isEmpty, nanos > 0 else { return nil }
        return Double(window.reduce(Int64(0)) { $0 + $1.bytes }) * 8 / (Double(nanos) / 1e9)
    }
}

/// Barème `video-score-v1` (méthode §2), arrondis « demi vers le haut » sur la valeur finale.
enum ExperienceVideoScoring {
    static func score(timeByQualityMs: [ExperienceVideoQuality: Int64], stalls: [ExperienceStall], startupMs: Int64) -> ExperienceVideoScore {
        let total = timeByQualityMs.values.reduce(0, +)
        let quality = total <= 0 ? 0 : roundHalfUp(
            timeByQualityMs.reduce(0.0) { $0 + Double($1.key.scorePoints) * Double($1.value) } / Double(total)
        )
        let waitSeconds = Double(stalls.reduce(Int64(0)) { $0 + $1.waitMs }) / 1_000
        let smoothness = roundHalfUp(max(0, 40 - 10 * Double(stalls.count) - 5 * waitSeconds))
        let startup = switch startupMs {
        case ...1_000: 20
        case ...2_000: 15
        case ...4_000: 8
        default: 0
        }
        return ExperienceVideoScore(total: quality + smoothness + startup, quality: quality, smoothness: smoothness, startup: startup)
    }

    private static func roundHalfUp(_ value: Double) -> Int { Int((value + 0.5).rounded(.down)) }
}

/// Statistiques des sondes de « Jeu et appels » (méthode §4), sur les valeurs entières envoyées.
enum ExperienceGameStats {
    struct Summary: Equatable, Sendable {
        let medianMs: Int64
        let jitterMs: Double
        let maxMs: Int64
        let spikeCount: Int
        let spikeShare: Double
    }

    enum Usage: CaseIterable, Sendable { case competitiveGaming, casualGaming, hdVideoCall, audioCall }

    static func summarize(_ series: [Int]) -> Summary? {
        guard let median = ExperienceHighlights.median(series), let maximum = series.max() else { return nil }
        let spikes = series.filter { $0 > median + ExperienceMethod.gameSpikeMarginMs }.count
        return Summary(
            medianMs: Int64(median), jitterMs: jitter(series) ?? 0, maxMs: Int64(maximum),
            spikeCount: spikes, spikeShare: Double(spikes) / Double(series.count)
        )
    }

    /// Moyenne des écarts absolus entre deux mesures successives, avec ses décimales ; nil sous 2 mesures.
    static func jitter(_ series: [Int]) -> Double? {
        guard series.count >= 2 else { return nil }
        let sum = zip(series, series.dropFirst()).reduce(0) { $0 + abs($1.1 - $1.0) }
        return Double(sum) / Double(series.count - 1)
    }

    /// Échec sous 20 valides, ou sous 50 % des sondes ENVOYÉES (la chauffe et les créneaux sautés ne comptent pas).
    static func hasEnoughProbes(sent: Int, valid: Int) -> Bool {
        valid >= ExperienceMethod.gameMinValidProbes && Double(valid) >= Double(sent) * ExperienceMethod.gameMinSuccessShare
    }

    /// Verdicts par usage, seuils inclusifs.
    static func suits(_ usage: Usage, medianMs: Int64, jitterMs: Int64?, spikeCount: Int?) -> Bool {
        switch usage {
        case .competitiveGaming: medianMs <= 50 && (jitterMs.map { $0 <= 10 } ?? false) && spikeCount == 0
        case .casualGaming: medianMs <= 100 && (jitterMs.map { $0 <= 30 } ?? false)
        case .hdVideoCall: medianMs <= 150 && (jitterMs.map { $0 <= 30 } ?? false)
        case .audioCall: medianMs <= 300
        }
    }

    /// Note A à F de la latence sous charge : écart entre la pire latence sous charge
    /// et la latence au repos (A ≤ 5 ms, B ≤ 30, C ≤ 60, D ≤ 200, F au-delà).
    static func underLoadGrade(idleMs: Double, loadedDownMs: Double?, loadedUpMs: Double?) -> (grade: String, deltaMs: Double)? {
        guard idleMs.isFinite, let worst = [loadedDownMs, loadedUpMs].compactMap({ $0 }).filter({ $0.isFinite && $0 > 0 }).max() else {
            return nil
        }
        let delta = max(0, worst - idleMs)
        let grade = switch delta {
        case ...5: "A"
        case ...30: "B"
        case ...60: "C"
        case ...200: "D"
        default: "F"
        }
        return (grade, delta)
    }
}

/// Phases d'une ouverture de page (méthode §3), relevées sur la requête du
/// document, la seule qui ouvre la connexion (en h2, les 6 autres la réutilisent).
enum ExperienceWebPhases {
    /// Instants monotones en nanosecondes ; nil = non observé.
    struct Times: Equatable, Sendable {
        var dnsStart: UInt64?
        var dnsEnd: UInt64?
        var connectStart: UInt64?
        var connectEnd: UInt64?
        var secureStart: UInt64?
        var secureEnd: UInt64?
        var requestStart: UInt64?
        var responseStart: UInt64?
        var reusedConnection = false
    }

    private static func spanMs(_ from: UInt64?, _ to: UInt64?) -> Int64? {
        guard let from, let to, to >= from else { return nil }
        return Int64((to - from) / 1_000_000)
    }

    /// `contentMs` = total − DNS − connexion − TLS − premier octet. Sans date DNS sur une
    /// connexion neuve (cache du système), `dnsCached` vaut vrai sans `dnsMs`, jamais 0.
    /// Une connexion réutilisée compte en échec : ses phases ne seraient pas celles d'une première ouverture.
    static func opening(_ times: Times, totalNanos: UInt64, protocolName: String?) -> ExperienceWebOpening {
        guard !times.reusedConnection, times.connectStart != nil else {
            return ExperienceWebOpening(measured: false, protocolName: protocolName, freshConnection: false)
        }
        let totalMs = Int64(totalNanos / 1_000_000)
        let firstByte = spanMs(times.requestStart, times.responseStart)
        let dnsNanos: UInt64? = {
            guard let start = times.dnsStart, let end = times.dnsEnd, end >= start else { return nil }
            return end - start
        }()
        let dns = dnsNanos.map { Int64($0 / 1_000_000) }
        let connect = spanMs(times.connectStart, times.secureStart ?? times.connectEnd)
        let tls = spanMs(times.secureStart, times.secureEnd)
        let content = max(0, totalMs - (dns ?? 0) - (connect ?? 0) - (tls ?? 0) - (firstByte ?? 0))
        let cached = dnsNanos.map { $0 < ExperienceMethod.webDNSCachedBelowNanos } ?? true
        return ExperienceWebOpening(
            measured: true, protocolName: protocolName, freshConnection: true,
            dnsMs: dns, dnsCached: cached,
            connectMs: connect, tlsMs: tls, firstByteMs: firstByte, contentMs: content, totalMs: totalMs
        )
    }

    /// `URLSessionTaskTransactionMetrics.networkProtocolName` vers le vocabulaire du contrat.
    static func protocolWire(_ name: String?) -> String? {
        switch name?.lowercased() {
        case "h2": "h2"
        case "h3", "h3-29": "h3"
        case "http/1.1", "http/1.0": "http/1.1"
        default: nil
        }
    }
}

/// Chemin réseau d'une mesure : de quoi dire que deux mesures partent du même réseau (méthode §4).
struct ExperienceNetworkPath: Equatable, Codable, Sendable {
    enum Transport: String, Codable, Sendable { case wifi, cellular }

    let transport: Transport
    /// Wi-Fi : SSID (absent sans la permission de localisation).
    var ssid: String?
    /// Mobile : service de données de la SIM (`dataServiceIdentifier`).
    var dataServiceId: String?
    /// Mobile : opérateur qui transporte les données, résolu par IP/ASN (l'hôte pour un MVNO).
    var carrierOperatorKey: String?
    /// nil = inconnu.
    var vpn: Bool?
}

/// Reprise des latences d'un speedtest récent pour « Jeu et appels » : dès
/// qu'un élément manque d'un côté, pas de reprise, la courte charge est mesurée.
enum ExperienceLatencyReuse {
    struct Snapshot: Equatable, Codable, Sendable {
        let measuredAt: Date
        let path: ExperienceNetworkPath
        let idleMs: Double
        let loadedDownMs: Double?
        let loadedUpMs: Double?
    }

    static func sameNetwork(_ speedtest: ExperienceNetworkPath?, _ now: ExperienceNetworkPath?) -> Bool {
        guard let speedtest, let now, speedtest.transport == now.transport else { return false }
        switch now.transport {
        case .wifi:
            guard let before = speedtest.ssid, !before.isEmpty, let after = now.ssid, !after.isEmpty else { return false }
            return before == after && (speedtest.vpn == true) == (now.vpn == true)
        case .cellular:
            guard let before = speedtest.dataServiceId, before == now.dataServiceId,
                  let carrier = speedtest.carrierOperatorKey, !carrier.isEmpty, carrier == now.carrierOperatorKey else { return false }
            return speedtest.vpn == false && now.vpn == false
        }
    }

    /// Le relevé repris : moins de 10 min, une latence sous charge, et le même réseau prouvé.
    static func reuse(_ snapshot: Snapshot?, now: ExperienceNetworkPath?, at date: Date) -> ExperienceUnderLoad? {
        guard let snapshot, sameNetwork(snapshot.path, now) else { return nil }
        let ageMs = date.timeIntervalSince(snapshot.measuredAt) * 1_000
        guard ageMs >= 0, ageMs < Double(ExperienceMethod.recentSpeedtestMaxAgeMs),
              let grade = ExperienceGameStats.underLoadGrade(
                idleMs: snapshot.idleMs, loadedDownMs: snapshot.loadedDownMs, loadedUpMs: snapshot.loadedUpMs
              ) else { return nil }
        return ExperienceUnderLoad(
            idleMs: ExperienceSubmission.roundHalfUp(snapshot.idleMs),
            loadedDownMs: snapshot.loadedDownMs.map(ExperienceSubmission.roundHalfUp),
            loadedUpMs: snapshot.loadedUpMs.map(ExperienceSubmission.roundHalfUp),
            grade: grade.grade, deltaMs: ExperienceSubmission.roundHalfUp(grade.deltaMs), source: .recentSpeedtest
        )
    }
}
