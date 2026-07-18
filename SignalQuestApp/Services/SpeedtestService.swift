import Foundation
import CoreLocation
import Network
import UIKit
import WidgetKit
import Security
import SwiftData

// MARK: - Service protocol

protocol SpeedtestServicing: Sendable {
    func run(pathStatus: NetworkPathStatus, location: Coordinates?, settings: SpeedtestRunSettings) async throws -> SpeedtestRunResult
    func run(pathStatus: NetworkPathStatus, location: Coordinates?, settings: SpeedtestRunSettings, progress: SpeedtestProgressHandler?) async throws -> SpeedtestRunResult
    func save(_ result: SpeedtestRunResult) async throws
    func save(_ result: SpeedtestRunResult, streams: Int) async throws
    func save(_ result: SpeedtestRunResult, streams: Int, publishToMap: Bool) async throws
    func save(_ result: SpeedtestRunResult, streams: Int, publishToMap: Bool, shareExactLocation: Bool) async throws
    func details(id: String) async throws -> SpeedtestDetail
    func guestDeletionReceipts() -> [GuestSpeedtestDeletionReceipt]
    func deleteGuestSpeedtest(_ receipt: GuestSpeedtestDeletionReceipt) async throws
    /// Identifiant serveur d'un test de l'historique, `nil` s'il n'a jamais été
    /// envoyé (hors ligne) ou s'il précède la mémorisation de cet id.
    func serverId(forClientId clientId: UUID) async -> String?
    /// Publie a posteriori un test déjà envoyé sur la carte publique.
    /// Réservé aux comptes : la route exige une authentification.
    func publishOnMap(clientId: UUID, shareExactLocation: Bool) async throws
}

struct GuestSpeedtestDeletionReceipt: Codable, Equatable, Identifiable, Sendable {
    /// Identifiant serveur du speedtest, requis par la route DELETE.
    let id: String
    let clientSubmissionId: String
    let deleteToken: String
    let createdAt: Date
}

private enum GuestSpeedtestReceiptError: LocalizedError {
    case tokenGenerationFailed

    var errorDescription: String? {
        "Impossible de créer le reçu de suppression local. Le speedtest invité n’a pas été envoyé. Réessaie."
    }
}

/// Les reçus invités sont sensibles : ils donnent le droit de supprimer une mesure.
/// Ils vivent donc dans un service Keychain dédié, et non dans UserDefaults.
final class GuestSpeedtestReceiptStore: @unchecked Sendable {
    private let store: TokenStore
    private let lock = NSLock()
    private let key = "guest-speedtest-deletion-receipts-v1"

    init(store: TokenStore = KeychainStore(service: "fr.signalquest.ios.guest-speedtests")) {
        self.store = store
    }

    func all() -> [GuestSpeedtestDeletionReceipt] {
        lock.withLock { readUnlocked() }
    }

    func upsert(_ receipt: GuestSpeedtestDeletionReceipt) {
        lock.withLock {
            var values = readUnlocked().filter { $0.id != receipt.id }
            values.append(receipt)
            writeUnlocked(values.sorted { $0.createdAt > $1.createdAt })
        }
    }

    func remove(id: String) {
        lock.withLock {
            writeUnlocked(readUnlocked().filter { $0.id != id })
        }
    }

    private func readUnlocked() -> [GuestSpeedtestDeletionReceipt] {
        guard let raw = try? store.string(for: key),
              let data = raw.data(using: .utf8),
              let values = try? JSONDecoder.signalQuest.decode([GuestSpeedtestDeletionReceipt].self, from: data) else {
            return []
        }
        return values
    }

    private func writeUnlocked(_ values: [GuestSpeedtestDeletionReceipt]) {
        guard !values.isEmpty else {
            try? store.remove(key)
            return
        }
        guard let data = try? JSONEncoder.signalQuest.encode(values),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? store.set(raw, for: key, accessibility: .whenUnlocked)
    }
}

/// Live progress emitted by the engine during a run. The UI uses this to drive
/// the speedometer gauge before the final result lands.
struct SpeedtestLiveProgress: Sendable {
    let phase: SpeedtestPhase
    let currentMbps: Double
    /// Fraction of the current phase (0…1) — useful for a future progress arc.
    let fraction: Double
    let downloadLiveMbps: Double?
    let downloadAverageMbps: Double?
    let uploadLiveMbps: Double?
    let uploadAverageMbps: Double?
    let pingLiveMs: Double?
    let pingFinalMs: Double?
    let jitterMs: Double?
    let pingProtocol: String?
    let pingSampleCount: Int
    let pingSampleTarget: Int
    let serverName: String?
    /// Message contextuel affichable (ex. serveur manuel injoignable → fallback).
    let notice: String?

    init(
        phase: SpeedtestPhase,
        currentMbps: Double = 0,
        fraction: Double = 0,
        downloadLiveMbps: Double? = nil,
        downloadAverageMbps: Double? = nil,
        uploadLiveMbps: Double? = nil,
        uploadAverageMbps: Double? = nil,
        pingLiveMs: Double? = nil,
        pingFinalMs: Double? = nil,
        jitterMs: Double? = nil,
        pingProtocol: String? = nil,
        pingSampleCount: Int = 0,
        pingSampleTarget: Int = 0,
        serverName: String? = nil,
        notice: String? = nil
    ) {
        self.phase = phase
        self.currentMbps = currentMbps
        self.fraction = fraction
        self.downloadLiveMbps = downloadLiveMbps
        self.downloadAverageMbps = downloadAverageMbps
        self.uploadLiveMbps = uploadLiveMbps
        self.uploadAverageMbps = uploadAverageMbps
        self.pingLiveMs = pingLiveMs
        self.pingFinalMs = pingFinalMs
        self.jitterMs = jitterMs
        self.pingProtocol = pingProtocol
        self.pingSampleCount = pingSampleCount
        self.pingSampleTarget = pingSampleTarget
        self.serverName = serverName
        self.notice = notice
    }
}

typealias SpeedtestProgressHandler = @Sendable (SpeedtestLiveProgress) -> Void

protocol SpeedtestTCPProbing: Sendable {
    func connectLatencyMs(host: String, port: UInt16, timeoutSeconds: TimeInterval) async throws -> Double
}

struct NetworkSpeedtestTCPProbe: SpeedtestTCPProbing {
    func connectLatencyMs(host: String, port: UInt16, timeoutSeconds: TimeInterval) async throws -> Double {
        final class ResumeGate: @unchecked Sendable {
            private let lock = NSLock()
            private var didResume = false

            func run(_ action: () -> Void) {
                lock.lock()
                guard !didResume else {
                    lock.unlock()
                    return
                }
                didResume = true
                lock.unlock()
                action()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            let queue = DispatchQueue(label: "fr.signalquest.speedtest.tcp")
            let start = Date()
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? .https,
                using: .tcp
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = Date().timeIntervalSince(start) * 1_000
                    gate.run {
                        connection.cancel()
                        continuation.resume(returning: elapsed)
                    }
                case .failed(let error):
                    gate.run {
                        connection.cancel()
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                gate.run {
                    connection.cancel()
                    continuation.resume(throwing: SpeedtestEngineError.pingFailed)
                }
            }
            connection.start(queue: queue)
        }
    }
}

// MARK: - Engine constants (mirrors Android SpeedTestEngine.kt)

private enum SpeedtestEngineConfig {
    /// Window length used to compute Mbps samples post-grace. Android uses
    /// 1000 ms and reads the same value for the public p90/p95/peak stats.
    static let publicPeakWindowMs: Double = 1_000
    /// Hard cap on parallel streams (download reverse).
    static let hardMaxStreams: Int = 16
    /// Upload : plafonner plus bas que le DL. 16 flux × 12 blocs en vol
    /// provoquent souvent des RST sur les POP publics (Scaleway / Bouygues)
    /// et sur la montée cellulaire — le test UL plantait en silence.
    static let hardMaxUploadStreams: Int = 8
    /// Second essai UL si le premier échoue (RST / busy).
    static let uploadRetryStreams: Int = 4
    /// Petite pause entre DL et UL pour laisser le démon iPerf libérer le port.
    static let interPhaseDelayMs: Double = 300
    /// OVH proof : 5201–5210. Bouygues : 9200–9240. Scaleway online.net : 5200–5209.
    static let iperf3PortMin: UInt16 = 5_201
    static let iperf3PortMax: UInt16 = 5_210
    static let bytelIperfPortMin: UInt16 = 9_200
    static let bytelIperfPortMax: UInt16 = 9_240
    static let onlineNetIperfPortMin: UInt16 = 5_200
    static let onlineNetIperfPortMax: UInt16 = 5_209
    /// Warm-up discarded by the iPerf3 protocol itself (TCP slow-start).
    static let iperf3OmitSeconds: Int = 1
    /// Block size for iPerf3 data streams (matches stock iperf3 TCP default).
    static let iperf3BlockSize: Int = 131_072
    /// PingProbe: maximum 8 total attempts. We use one warmup when possible,
    /// then up to 7 measured samples at a short cadence so the phase feels instant.
    static let pingAttemptBudget: Int = 8
    static let pingWarmupCount: Int = 1
    static let pingMinimumValidSamples: Int = 3
    static let pingIntervalMs: Double = 300
    static let pingTimeoutSeconds: TimeInterval = 1.2
    /// Probes de rattrapage (cadence rapprochée) quand le budget principal
    /// n'a pas produit assez d'échantillons valides sur un réseau perdant.
    static let pingSalvageAttempts: Int = 3
    static let pingSalvageIntervalMs: Double = 150
    /// Fenêtre fine de la SÉRIE GRAPHE (courbe de partage) : ~4 points/s pour
    /// une courbe détaillée du test entier — les stats publiques (moyenne,
    /// p90/p95, max) restent en fenêtres `publicPeakWindowMs` (1 s).
    static let graphWindowMs: Double = 250
}

private enum SpeedtestEngineError: LocalizedError {
    case pingFailed
    case noServerReachable

    var errorDescription: String? {
        switch self {
        case .pingFailed:
            return "Impossible de mesurer une latence réseau fiable."
        case .noServerReachable:
            return "Les serveurs speedtest sont occupés ou injoignables depuis ce réseau. Réessaie dans un instant."
        }
    }
}

// MARK: - Service implementation

final class SpeedtestService: SpeedtestServicing, @unchecked Sendable {
    private let api: APIClient
    private let markets: MarketRegistryServicing
    private let networkOperator: NetworkOperatorServicing
    private let historyCache: DiskCache
    private let pendingStore: SpeedtestPendingStoring
    private let guestReceiptStore: GuestSpeedtestReceiptStore
    private let tcpProbe: SpeedtestTCPProbing
    static let pendingSaveKey = "pending-speedtest-saves"
    /// Dossier de la file d'attente durable (partagé entre l'init durable et la migration).
    /// `internal` (pas `private`) : référencé dans une valeur par défaut d'initialiseur.
    static let pendingFolderName = "SignalQuestSpeedtestPending"

    init(
        api: APIClient,
        markets: MarketRegistryServicing? = nil,
        networkOperator: NetworkOperatorServicing? = nil,
        historyCache: DiskCache = DiskCache(folderName: "SignalQuestSpeedtestHistory"),
        // File des sauvegardes EN ATTENTE d'envoi : DURABLE (Application Support, non
        // purgeable par iOS) et protégée — au contraire de l'historique (cache jetable).
        // Un speedtest non encore envoyé (backend HS, hors-ligne) ne doit jamais être perdu.
        pendingCache: DiskCache = DiskCache(
            folderName: SpeedtestService.pendingFolderName,
            baseDirectory: .applicationSupportDirectory,
            evicts: false,
            fileProtection: .completeUntilFirstUserAuthentication
        ),
        guestReceiptStore: GuestSpeedtestReceiptStore = GuestSpeedtestReceiptStore(),
        tcpProbe: SpeedtestTCPProbing = NetworkSpeedtestTCPProbe()
    ) {
        // Migration unique : les sauvegardes en attente vivaient dans Caches (purgeable).
        // On les remonte vers Application Support avant toute lecture, pour ne pas perdre
        // un test non envoyé lors de la mise à jour de l'app.
        SpeedtestService.migratePendingSavesFromCachesIfNeeded()
        self.api = api
        self.markets = markets ?? MarketRegistryService(api: api)
        self.networkOperator = networkOperator ?? NetworkOperatorService(api: api)
        self.historyCache = historyCache
        // iOS 17+ : vraie base SwiftData ; iOS 16 : repli sur la file durable (DiskCache).
        // La `pendingCache` durable sert de source de migration (17+) ou de backing (16).
        self.pendingStore = SpeedtestPendingStoreFactory.make(durableCache: pendingCache, key: Self.pendingSaveKey)
        self.guestReceiptStore = guestReceiptStore
        self.tcpProbe = tcpProbe
    }

    /// Migration unique Caches → Application Support pour la file d'attente durable.
    /// Idempotente : après le déplacement la source n'existe plus (no-op ensuite).
    private static func migratePendingSavesFromCachesIfNeeded(fileManager: FileManager = .default) {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldFolder = caches.appendingPathComponent(pendingFolderName, isDirectory: true)
        let newFolder = appSupport.appendingPathComponent(pendingFolderName, isDirectory: true)
        guard fileManager.fileExists(atPath: oldFolder.path),
              let files = try? fileManager.contentsOfDirectory(at: oldFolder, includingPropertiesForKeys: nil) else { return }
        try? fileManager.createDirectory(at: newFolder, withIntermediateDirectories: true)
        for file in files where file.pathExtension == "json" {
            let dest = newFolder.appendingPathComponent(file.lastPathComponent)
            // Ne pas écraser une file déjà présente/plus récente en Application Support.
            if !fileManager.fileExists(atPath: dest.path) {
                try? fileManager.moveItem(at: file, to: dest)
            }
        }
    }

    func run(pathStatus: NetworkPathStatus, location: Coordinates?, settings: SpeedtestRunSettings) async throws -> SpeedtestRunResult {
        try await run(pathStatus: pathStatus, location: location, settings: settings, progress: nil)
    }

    func run(
        pathStatus: NetworkPathStatus,
        location: Coordinates?,
        settings: SpeedtestRunSettings,
        progress: SpeedtestProgressHandler?
    ) async throws -> SpeedtestRunResult {
        let startedAt = Date()
        let omitSeconds = SpeedtestEngineConfig.iperf3OmitSeconds
        let durationSeconds = max(5, min(settings.durationSeconds, 30))
        // Multi-stream is required to saturate 5G / fibre : un seul flux TCP
        // plafonne souvent sous le débit réel du lien.
        let parallelStreams = min(max(settings.streams, 4), SpeedtestEngineConfig.hardMaxStreams)

        // 1. Resolve selected server (with fallback to closest if manual choice unreachable)
        progress?(SpeedtestLiveProgress(phase: .ping, fraction: 0, serverName: nil))

        // Cible « Cloudflare » : moteur HTTPS anycast directement (pas d'iPerf3).
        if settings.downloadTarget == .cloudflare {
            return try await runCloudflareTest(
                pathStatus: pathStatus,
                location: location,
                durationSeconds: durationSeconds,
                parallelStreams: parallelStreams,
                startedAt: startedAt,
                progress: progress,
                notice: nil
            )
        }

        var iperfServer = selectIPerfServer(for: settings.downloadTarget, location: location)
        let requestedServer = iperfServer
        var endpoint = await resolveIPerfEndpoint(for: iperfServer)

        if endpoint == nil && settings.downloadTarget != .hybridAuto {
            iperfServer = findClosestIPerfServer(to: location)
            endpoint = await resolveIPerfEndpoint(for: iperfServer)
        }

        // Dernier filet : essayer chaque serveur public (régions sans iPerf → plus proche).
        if endpoint == nil {
            let ordered = iperfServersSortedByDistance(from: location)
            for candidate in ordered where candidate.hostname != iperfServer.hostname {
                if let found = await resolveIPerfEndpoint(for: candidate) {
                    iperfServer = candidate
                    endpoint = found
                    break
                }
            }
        }

        guard let endpoint else {
            // Chaîne de secours : tous les iPerf3 injoignables → edge Cloudflare
            // (HTTPS). L'erreur sèche n'arrive que si l'edge échoue aussi.
            return try await runCloudflareTest(
                pathStatus: pathStatus,
                location: location,
                durationSeconds: durationSeconds,
                parallelStreams: parallelStreams,
                startedAt: startedAt,
                progress: progress,
                notice: "Serveurs iPerf3 injoignables — test via Cloudflare"
            )
        }

        var port = endpoint.port
        let serverName = iperfServer.name

        // Choix manuel écrasé par le fallback : le dire, pas le cacher
        // (ex. serveur IPv6-only sur un réseau cellulaire IPv4).
        if settings.downloadTarget.migrated != .hybridAuto, iperfServer.hostname != requestedServer.hostname {
            progress?(SpeedtestLiveProgress(
                phase: .ping,
                fraction: 0,
                serverName: serverName,
                notice: "\(requestedServer.name) injoignable — test sur \(serverName)"
            ))
        }

        // Mode Auto : si l'edge anycast Cloudflare est NETTEMENT plus proche
        // que le meilleur iPerf3 du catalogue (voyage hors zones couvertes),
        // il devient le serveur de test — couverture mondiale automatique.
        // Le seuil garde les serveurs opérateurs prioritaires en France.
        if settings.downloadTarget.migrated == .hybridAuto {
            let iperfMs = try? await tcpProbe.connectLatencyMs(
                host: iperfServer.hostname,
                port: port,
                timeoutSeconds: SpeedtestEngineConfig.pingTimeoutSeconds
            )
            let cloudflareMs = try? await tcpProbe.connectLatencyMs(
                host: CloudflareSpeedtestConfig.host,
                port: 443,
                timeoutSeconds: SpeedtestEngineConfig.pingTimeoutSeconds
            )
            if let cloudflareMs, cloudflareMs + CloudflareSpeedtestConfig.autoAdvantageMs < (iperfMs ?? .infinity) {
                return try await runCloudflareTest(
                    pathStatus: pathStatus,
                    location: location,
                    durationSeconds: durationSeconds,
                    parallelStreams: parallelStreams,
                    startedAt: startedAt,
                    progress: progress,
                    notice: nil
                )
            }
        }

        // 2. Ping TCP pur sur le port iPerf (pas de fallback HTTP : ATS bloquerait
        // les hosts Bouygues/OVH en clair, et le port iPerf n'est pas un serveur HTTP).
        progress?(SpeedtestLiveProgress(
            phase: .ping,
            fraction: 0,
            pingSampleTarget: SpeedtestEngineConfig.pingAttemptBudget,
            serverName: serverName
        ))

        let pingOutcome = try await measureIPerfTcpPings(
            host: iperfServer.hostname,
            port: port,
            serverName: serverName,
            progress: progress
        )

        let pingValue = SpeedMetricCalculator.average(pingOutcome.values)
        let pingMedianValue = SpeedMetricCalculator.median(pingOutcome.values)
        let pingMinValue = pingOutcome.values.min()
        let pingMaxValue = pingOutcome.values.max()
        let jitterValue = SpeedMetricCalculator.jitter(pingOutcome.values)

        // 3. Download measurement (iPerf3 reverse) — démarre immédiatement après le ping.
        progress?(SpeedtestLiveProgress(phase: .download, fraction: 0, serverName: serverName))

        let dlSamplesBox = SpeedtestSamplesBox()
        let dlLiveSampler = SpeedtestLiveSampler()
        let dlState = ProgressState()
        let usefulDuration = Double(durationSeconds)
        /// Octets et temps cumulés pendant l'omit — permettent au live sampler
        /// de voir un flux continu (omit + utile) pour une aiguille sans saut.
        let dlOmitBridge = OmitBridge()
        // Boîte GRAPHE : timeline complète (grâce [0, omit] + utile décalé de
        // l'omit) en fenêtres fines — la courbe de partage montre le test en
        // totalité, montée en charge comprise. Les stats restent sur l'utile.
        let dlGraphBox = SpeedtestSamplesBox()
        let dlGraphWarmupState = ProgressState()
        let omitMs = Double(omitSeconds) * 1_000

        // Ping / jitter en charge pendant le DL — sur un port voisin (pas le port
        // de mesure) pour ne pas RST le démon iPerf3 en cours de test.
        let dlLoadedHost = iperfServer.hostname
        let dlLoadedPort = iperfSiblingPort(preferred: port, min: iperfServer.portMin, max: iperfServer.portMax)
        let dlLoadedOmit = omitSeconds
        let dlLoadedDeadline = Date().addingTimeInterval(Double(omitSeconds + durationSeconds) + 2)
        let dlLoadedProbe = tcpProbe
        let dlLoadedPingsTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(dlLoadedOmit) * 1_000_000_000)
            guard !Task.isCancelled else { return [Double]() }
            return await SpeedtestService.collectIPerfLoadedPings(
                host: dlLoadedHost,
                port: dlLoadedPort,
                deadline: dlLoadedDeadline,
                tcpProbe: dlLoadedProbe
            )
        }
        // Sur les chemins d'erreur du DL, la sonde continuait à pinger jusqu'à
        // sa deadline ; le defer la coupe quoi qu'il arrive (no-op sinon).
        defer { dlLoadedPingsTask.cancel() }

        let dlResult: IPerf3Result
        let dlPort: UInt16
        do {
            (dlResult, dlPort) = try await runIPerf3WithPortFallback(
            hostname: iperfServer.hostname,
            preferredPort: port,
            portMin: iperfServer.portMin,
            portMax: iperfServer.portMax,
            streams: parallelStreams,
            durationSeconds: durationSeconds,
            omitSeconds: omitSeconds,
            isDownload: true,
            knownOpenPorts: endpoint.openPorts,
            onProgress: { @Sendable bytes, elapsed in
                let elapsedMs = elapsed * 1000.0
                // Flux continu : omit + utile → aiguille sans discontinuité.
                let bridged = dlOmitBridge.bridged(usefulBytes: bytes, usefulMs: elapsedMs)
                let needleMbps = dlLiveSampler.observe(totalBytes: bridged.totalBytes, elapsedMs: bridged.totalMs)
                let averageMbps = (Double(bytes) * 8.0 / 1_000_000.0) / max(0.1, elapsed)
                let deltaBytes = dlState.update(bytes: bytes, time: elapsedMs)
                dlSamplesBox.append(start: max(0, elapsedMs - 150), end: elapsedMs, bytes: deltaBytes)
                dlGraphBox.append(start: omitMs + max(0, elapsedMs - 150), end: omitMs + elapsedMs, bytes: deltaBytes)
                progress?(SpeedtestLiveProgress(
                    phase: .download,
                    currentMbps: needleMbps,
                    fraction: min(1, elapsed / usefulDuration),
                    downloadLiveMbps: needleMbps,
                    downloadAverageMbps: averageMbps,
                    serverName: serverName
                ))
            },
            onWarmup: { @Sendable rawBytes, wallSeconds in
                let wallMs = wallSeconds * 1000.0
                dlOmitBridge.capture(rawBytes: rawBytes, rawMs: wallMs)
                // Rampe réelle enregistrée pour la courbe (segment de grâce).
                let warmupDelta = dlGraphWarmupState.update(bytes: rawBytes, time: wallMs)
                dlGraphBox.append(start: max(0, wallMs - 150), end: wallMs, bytes: warmupDelta)
                let needleMbps = dlLiveSampler.observe(totalBytes: rawBytes, elapsedMs: wallMs)
                progress?(SpeedtestLiveProgress(
                    phase: .download,
                    currentMbps: needleMbps,
                    fraction: 0,
                    downloadLiveMbps: needleMbps,
                    downloadAverageMbps: 0,
                    serverName: serverName
                ))
            },
            onPortAttempt: { @Sendable _, _ in
                progress?(SpeedtestLiveProgress(phase: .download, fraction: 0, serverName: serverName))
            }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Sauvetage : DL iPerf3 impossible sur toute la plage → moteur
            // Cloudflare (résultat complet plutôt qu'une erreur sèche).
            sqDebugLog("[SpeedtestService] DL iPerf3 KO (\(error.localizedDescription)) — bascule Cloudflare")
            return try await runCloudflareTest(
                pathStatus: pathStatus,
                location: location,
                durationSeconds: durationSeconds,
                parallelStreams: parallelStreams,
                startedAt: startedAt,
                progress: progress,
                notice: "\(serverName) indisponible — test via Cloudflare"
            )
        }
        port = dlPort
        dlLoadedPingsTask.cancel()
        let downloadPings = await dlLoadedPingsTask.value
        let pingDlMs = downloadPings.isEmpty ? nil : SpeedMetricCalculator.average(downloadPings)
        let jitterDlMs = downloadPings.isEmpty ? nil : SpeedMetricCalculator.jitter(downloadPings)

        guard dlResult.measuredBytes > 100_000, dlResult.measuredDuration >= 1.0 else {
            // Même sauvetage : un DL quasi vide (POP saturé) vaut une bascule,
            // pas un échec du test.
            sqDebugLog("[SpeedtestService] DL iPerf3 incomplet (\(dlResult.measuredBytes) octets) — bascule Cloudflare")
            return try await runCloudflareTest(
                pathStatus: pathStatus,
                location: location,
                durationSeconds: durationSeconds,
                parallelStreams: parallelStreams,
                startedAt: startedAt,
                progress: progress,
                notice: "\(serverName) indisponible — test via Cloudflare"
            )
        }

        // Les samples live sont déjà post-omit (progress ne pousse que la phase utile).
        let dlStats = dlSamplesBox.publicStats(
            windowMs: SpeedtestEngineConfig.publicPeakWindowMs,
            graceMs: 0,
            endMs: max(dlResult.measuredDuration, 0.001) * 1_000
        )
        let dlAverageMbps = dlResult.averageMbps
        let dlPeakMbps = max(dlStats.peak, dlAverageMbps)

        // Série GRAPHE du test entier : fenêtres fines de grâce [0, omit] puis
        // utiles — la frontière (nombre de fenêtres de grâce) part au renderer.
        let dlGraceSeries = dlGraphBox.publicStats(
            windowMs: SpeedtestEngineConfig.graphWindowMs,
            graceMs: 0,
            endMs: omitMs
        ).seriesMbps
        let dlUsefulSeries = dlGraphBox.publicStats(
            windowMs: SpeedtestEngineConfig.graphWindowMs,
            graceMs: omitMs,
            endMs: omitMs + max(dlResult.measuredDuration, 0.001) * 1_000
        ).seriesMbps
        let dlGraphSeries = dlGraceSeries + dlUsefulSeries

        // 4. Upload — best-effort. Après un reverse DL, le démon iPerf3 public
        // a souvent besoin d'un court délai + d'un **autre port** de la plage
        // (un process par port). Les RST immédiats sur le même port étaient
        // avalés sans retry → UL systématiquement vide.
        progress?(SpeedtestLiveProgress(phase: .upload, fraction: 0, serverName: serverName))

        // Contexte de résultat (géocodage inverse, SSID, opérateur) résolu EN
        // PARALLÈLE de l'upload — jusqu'à ~2-3 s de gagnés avant `.finished`.
        let contextTask = resultContextTask(pathStatus: pathStatus, location: location)

        let ulSamplesBox = SpeedtestSamplesBox()
        let ulLiveSampler = SpeedtestLiveSampler()
        let ulState = ProgressState()
        let ulOmitBridge = OmitBridge()
        let ulGraphBox = SpeedtestSamplesBox()
        let ulGraphWarmupState = ProgressState()

        var ulAverageMbps: Double?
        var ulPeakMbps: Double?
        var ulStats = SpeedtestSamplesBox.PublicStats(p90: nil, p95: nil, peak: 0, windowCount: 0, seriesMbps: [])
        var ulGraphSeries: [Double] = []
        var ulGraceCount = 0
        var uploadSource = "client-written"
        var pingUlMs: Double?
        var jitterUlMs: Double?

        // Pause courte : laisse le serveur fermer proprement la session reverse.
        try? await Task.sleep(nanoseconds: UInt64(SpeedtestEngineConfig.interPhaseDelayMs * 1_000_000))

        // Port UL : de préférence un port CONFIRMÉ ouvert au probe initial
        // (≠ port DL, occupé côté démon) — zéro re-scan entre les phases.
        let ulPreferredPort = endpoint.openPorts.first(where: { $0 != port })
            ?? iperfSiblingPort(
                preferred: port,
                min: iperfServer.portMin,
                max: iperfServer.portMax
            )
        let ulStreamAttempts = [
            min(parallelStreams, SpeedtestEngineConfig.hardMaxUploadStreams),
            SpeedtestEngineConfig.uploadRetryStreams
        ]
        // Loaded pings sur un 3e port si possible, jamais le port d'upload actif.
        let ulLoadedHost = iperfServer.hostname
        let ulLoadedPort = endpoint.openPorts.first(where: { $0 != port && $0 != ulPreferredPort })
            ?? iperfSiblingPort(
                preferred: ulPreferredPort,
                min: iperfServer.portMin,
                max: iperfServer.portMax
            )
        let ulLoadedOmit = omitSeconds
        let ulLoadedDeadline = Date().addingTimeInterval(Double(omitSeconds + durationSeconds) + 3)
        let ulLoadedProbe = tcpProbe
        let ulLoadedPingsTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(ulLoadedOmit) * 1_000_000_000)
            guard !Task.isCancelled else { return [Double]() }
            return await SpeedtestService.collectIPerfLoadedPings(
                host: ulLoadedHost,
                port: ulLoadedPort,
                deadline: ulLoadedDeadline,
                tcpProbe: ulLoadedProbe
            )
        }
        defer { ulLoadedPingsTask.cancel() }

        do {
            var lastULError: Error?
            var didUpload = false
            for (attemptIndex, ulStreams) in ulStreamAttempts.enumerated() {
                // 1er essai : port voisin ; 2e essai : port du DL (souvent libre).
                let preferred = attemptIndex == 0 ? ulPreferredPort : port
                do {
                    let (ulResult, ulPort) = try await runIPerf3WithPortFallback(
                        hostname: iperfServer.hostname,
                        preferredPort: preferred,
                        portMin: iperfServer.portMin,
                        portMax: iperfServer.portMax,
                        streams: max(1, ulStreams),
                        durationSeconds: durationSeconds,
                        omitSeconds: omitSeconds,
                        isDownload: false,
                        knownOpenPorts: endpoint.openPorts,
                        onProgress: { @Sendable bytes, elapsed in
                            let elapsedMs = elapsed * 1000.0
                            let bridged = ulOmitBridge.bridged(usefulBytes: bytes, usefulMs: elapsedMs)
                            let needleMbps = ulLiveSampler.observe(totalBytes: bridged.totalBytes, elapsedMs: bridged.totalMs)
                            let averageMbps = (Double(bytes) * 8.0 / 1_000_000.0) / max(0.1, elapsed)
                            let deltaBytes = ulState.update(bytes: bytes, time: elapsedMs)
                            ulSamplesBox.append(start: max(0, elapsedMs - 150), end: elapsedMs, bytes: deltaBytes)
                            ulGraphBox.append(start: omitMs + max(0, elapsedMs - 150), end: omitMs + elapsedMs, bytes: deltaBytes)
                            progress?(SpeedtestLiveProgress(
                                phase: .upload,
                                currentMbps: needleMbps,
                                fraction: min(1, elapsed / usefulDuration),
                                uploadLiveMbps: needleMbps,
                                uploadAverageMbps: averageMbps,
                                serverName: serverName
                            ))
                        },
                        onWarmup: { @Sendable rawBytes, wallSeconds in
                            let wallMs = wallSeconds * 1000.0
                            ulOmitBridge.capture(rawBytes: rawBytes, rawMs: wallMs)
                            let warmupDelta = ulGraphWarmupState.update(bytes: rawBytes, time: wallMs)
                            ulGraphBox.append(start: max(0, wallMs - 150), end: wallMs, bytes: warmupDelta)
                            let needleMbps = ulLiveSampler.observe(totalBytes: rawBytes, elapsedMs: wallMs)
                            progress?(SpeedtestLiveProgress(
                                phase: .upload,
                                currentMbps: needleMbps,
                                fraction: 0,
                                uploadLiveMbps: needleMbps,
                                uploadAverageMbps: 0,
                                serverName: serverName
                            ))
                        },
                        onPortAttempt: { @Sendable _, _ in
                            progress?(SpeedtestLiveProgress(phase: .upload, fraction: 0, serverName: serverName))
                        }
                    )
                    port = ulPort
                    if ulResult.measuredBytes > 100_000, ulResult.measuredDuration >= 1.0 {
                        ulStats = ulSamplesBox.publicStats(
                            windowMs: SpeedtestEngineConfig.publicPeakWindowMs,
                            graceMs: 0,
                            endMs: max(ulResult.measuredDuration, 0.001) * 1_000
                        )
                        let ulGraceSeries = ulGraphBox.publicStats(
                            windowMs: SpeedtestEngineConfig.graphWindowMs,
                            graceMs: 0,
                            endMs: omitMs
                        ).seriesMbps
                        let ulUsefulSeries = ulGraphBox.publicStats(
                            windowMs: SpeedtestEngineConfig.graphWindowMs,
                            graceMs: omitMs,
                            endMs: omitMs + max(ulResult.measuredDuration, 0.001) * 1_000
                        ).seriesMbps
                        ulGraphSeries = ulGraceSeries + ulUsefulSeries
                        ulGraceCount = ulGraceSeries.count
                        ulAverageMbps = ulResult.averageMbps
                        ulPeakMbps = max(ulStats.peak, ulAverageMbps ?? 0)
                        uploadSource = ulResult.serverBytes != nil ? "server-received" : "client-written"
                        didUpload = true
                        break
                    }
                    lastULError = NSError(
                        domain: "iPerfClient",
                        code: -8,
                        userInfo: [NSLocalizedDescriptionKey: "Upload incomplet (\(ulResult.measuredBytes) octets)"]
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastULError = error
                    sqDebugLog("[SpeedtestService] Upload attempt \(attemptIndex + 1) failed (streams=\(ulStreams) portPref=\(preferred)): \(error.localizedDescription)")
                    // Court backoff avant le second essai (RST / busy).
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            }
            if !didUpload, let lastULError {
                sqDebugLog("[SpeedtestService] Upload failed (best-effort, DL only): \(lastULError.localizedDescription)")
            }
        } catch is CancellationError {
            ulLoadedPingsTask.cancel()
            throw CancellationError()
        }

        ulLoadedPingsTask.cancel()
        let uploadPings = await ulLoadedPingsTask.value
        if !uploadPings.isEmpty {
            pingUlMs = SpeedMetricCalculator.average(uploadPings)
            jitterUlMs = SpeedMetricCalculator.jitter(uploadPings)
        }

        // 5. Assemblage partagé (commun aux moteurs iPerf3 et Cloudflare).
        let measurements = EngineMeasurements(
            serverName: serverName,
            downloadServerId: "iperf3_\(iperfServer.hostname):\(port)",
            downloadServerCode: "\(port)",
            pingProtocol: pingOutcome.protocolName,
            pingMs: pingValue,
            pingMedianMs: pingMedianValue,
            pingMinMs: pingMinValue,
            pingMaxMs: pingMaxValue,
            jitterMs: jitterValue,
            downloadAverageMbps: dlAverageMbps,
            downloadMaxMbps: dlPeakMbps,
            downloadP90Mbps: dlStats.p90,
            downloadP95Mbps: dlStats.p95,
            downloadSeriesMbps: dlGraphSeries.isEmpty ? dlStats.seriesMbps : dlGraphSeries,
            uploadAverageMbps: ulAverageMbps,
            uploadMaxMbps: ulPeakMbps,
            uploadP90Mbps: ulStats.p90,
            uploadP95Mbps: ulStats.p95,
            uploadSeriesMbps: ulGraphSeries.isEmpty
                ? (ulStats.seriesMbps.isEmpty ? nil : ulStats.seriesMbps)
                : ulGraphSeries,
            downloadGraceWindowCount: dlGraphSeries.isEmpty ? 0 : dlGraceSeries.count,
            uploadGraceWindowCount: ulGraphSeries.isEmpty ? 0 : ulGraceCount,
            uploadMeasurementSource: uploadSource,
            pingDlMs: pingDlMs,
            jitterDlMs: jitterDlMs,
            pingUlMs: pingUlMs,
            jitterUlMs: jitterUlMs
        )
        return await finalizeRun(
            measurements,
            startedAt: startedAt,
            pathStatus: pathStatus,
            location: location,
            context: contextTask,
            progress: progress
        )
    }

    /// Sorties communes des moteurs de mesure (iPerf3 / Cloudflare),
    /// consommées par `finalizeRun` pour l'assemblage du résultat.
    private struct EngineMeasurements: Sendable {
        let serverName: String
        let downloadServerId: String
        let downloadServerCode: String
        let pingProtocol: String
        let pingMs: Double
        let pingMedianMs: Double?
        let pingMinMs: Double?
        let pingMaxMs: Double?
        let jitterMs: Double?
        let downloadAverageMbps: Double
        let downloadMaxMbps: Double
        let downloadP90Mbps: Double?
        let downloadP95Mbps: Double?
        let downloadSeriesMbps: [Double]
        let uploadAverageMbps: Double?
        let uploadMaxMbps: Double?
        let uploadP90Mbps: Double?
        let uploadP95Mbps: Double?
        let uploadSeriesMbps: [Double]?
        let downloadGraceWindowCount: Int
        let uploadGraceWindowCount: Int
        let uploadMeasurementSource: String
        let pingDlMs: Double?
        let jitterDlMs: Double?
        let pingUlMs: Double?
        let jitterUlMs: Double?
    }

    /// Contexte de résultat (lieu, SSID, opérateur) — résolu en tâche
    /// parallèle pendant la phase d'upload pour ne pas retarder `.finished`.
    private struct RunContextInfo: Sendable {
        let place: ResolvedPlace
        let wifiSSID: String?
        let operatorContext: CellularOperatorContext
    }

    private func resultContextTask(pathStatus: NetworkPathStatus, location: Coordinates?) -> Task<RunContextInfo, Never> {
        Task {
            async let place = self.reverseGeocodedPlace(for: location)
            async let ssid = self.currentWiFiSSID(for: pathStatus)
            async let operatorContext = self.resolveCellularOperatorContext(pathStatus: pathStatus, location: location)
            return await RunContextInfo(place: place, wifiSSID: ssid, operatorContext: operatorContext)
        }
    }

    /// Assemblage + persistance + émission `.finished` — indépendant du moteur.
    /// `context` : tâche lancée pendant l'upload (géocodage/SSID/opérateur en
    /// parallèle du transfert) ; sinon résolution concurrente ici.
    private func finalizeRun(
        _ m: EngineMeasurements,
        startedAt: Date,
        pathStatus: NetworkPathStatus,
        location: Coordinates?,
        context: Task<RunContextInfo, Never>? = nil,
        progress: SpeedtestProgressHandler?
    ) async -> SpeedtestRunResult {
        let duration = Date().timeIntervalSince(startedAt)
        let info: RunContextInfo
        if let context {
            info = await context.value
        } else {
            info = await resultContextTask(pathStatus: pathStatus, location: location).value
        }
        let resolvedPlace = info.place
        let wifiSSID = info.wifiSSID
        let operatorContext = info.operatorContext

        let result = SpeedtestRunResult(
            id: UUID(),
            label: "iOS speedtest",
            downloadMbps: m.downloadAverageMbps,
            downloadAverageMbps: m.downloadAverageMbps,
            downloadMaxMbps: m.downloadMaxMbps,
            downloadP90Mbps: m.downloadP90Mbps,
            downloadP95Mbps: m.downloadP95Mbps,
            uploadMbps: m.uploadAverageMbps,
            uploadAverageMbps: m.uploadAverageMbps,
            uploadMaxMbps: m.uploadMaxMbps,
            uploadP90Mbps: m.uploadP90Mbps,
            uploadP95Mbps: m.uploadP95Mbps,
            pingMs: m.pingMs,
            pingMedianMs: m.pingMedianMs,
            pingMinMs: m.pingMinMs,
            pingMaxMs: m.pingMaxMs,
            jitterMs: m.jitterMs,
            pingDlMs: m.pingDlMs,
            jitterDlMs: m.jitterDlMs,
            pingUlMs: m.pingUlMs,
            jitterUlMs: m.jitterUlMs,
            pingProtocol: m.pingProtocol,
            durationSeconds: duration,
            connectionType: pathStatus.connection,
            cellularTechnology: pathStatus.cellularTechnology,
            networkOperatorName: operatorContext.mobileOperator ?? pathStatus.operatorName,
            networkOperatorMcc: operatorContext.mcc,
            networkOperatorMnc: operatorContext.mnc,
            marketCode: operatorContext.marketCode,
            operatorKey: operatorContext.operatorKey,
            wifiSSID: wifiSSID,
            city: resolvedPlace.city,
            address: resolvedPlace.address,
            coordinate: location,
            serverName: m.serverName,
            downloadServerName: m.serverName,
            downloadServerId: m.downloadServerId,
            downloadServerCode: m.downloadServerCode,
            createdAt: startedAt,
            downloadSeriesMbps: m.downloadSeriesMbps,
            uploadSeriesMbps: m.uploadSeriesMbps,
            downloadGraceWindowCount: m.downloadGraceWindowCount > 0 ? m.downloadGraceWindowCount : nil,
            uploadGraceWindowCount: m.uploadGraceWindowCount > 0 ? m.uploadGraceWindowCount : nil,
            uploadMeasurementSource: m.uploadMeasurementSource,
            deviceModel: AppleDeviceDescriptor.currentShareModelName,
            osVersion: AppleDeviceDescriptor.currentOSVersionLabel
        )

        do {
            try await appendHistory(result)
        } catch {
            sqDebugLog("SQ_IPERF history save failed: \(error.localizedDescription)")
        }

        progress?(SpeedtestLiveProgress(
            phase: .finished,
            currentMbps: result.downloadAverageMbps,
            fraction: 1,
            downloadAverageMbps: result.downloadAverageMbps,
            uploadAverageMbps: result.uploadAverageMbps,
            pingFinalMs: result.pingMinMs ?? result.pingMs,
            jitterMs: result.jitterMs,
            pingProtocol: result.pingProtocol,
            serverName: m.serverName
        ))

        return result
    }

    // MARK: - Moteur Cloudflare (mesures)

    private enum CloudflareTransferDirection: Sendable { case download, upload }

    private struct CloudflareTransferOutcome: Sendable {
        let bytes: Int
        let duration: Double

        var averageMbps: Double {
            guard bytes > 0, duration > 0 else { return 0 }
            let mbps = (Double(bytes) * 8.0 / 1_000_000.0) / duration
            return mbps.isFinite && mbps >= 0 ? mbps : 0
        }
    }

    /// Test complet via l'edge anycast Cloudflare — ping (TTFB), download
    /// `__down`, upload `__up` et pings chargés sur le MÊME edge. HTTPS pur
    /// (ATS OK), utilisé comme cible manuelle, choix Auto hors zone iPerf3,
    /// et filet de secours quand les serveurs iPerf3 sont injoignables.
    private func runCloudflareTest(
        pathStatus: NetworkPathStatus,
        location: Coordinates?,
        durationSeconds: Int,
        parallelStreams: Int,
        startedAt: Date,
        progress: SpeedtestProgressHandler?,
        notice: String?
    ) async throws -> SpeedtestRunResult {
        let dlStreams = min(max(2, parallelStreams), CloudflareSpeedtestConfig.maxStreams)
        let ulStreams = min(dlStreams, CloudflareSpeedtestConfig.maxUploadStreams)
        let session = makeMeasurementSession(
            maxConnectionsPerHost: dlStreams + 2,
            requestTimeout: Double(durationSeconds) + 15
        )
        defer { session.finishTasksAndInvalidate() }

        let colo = await fetchCloudflareColo(session: session)
        let serverName = cloudflareServerName(colo: colo)

        progress?(SpeedtestLiveProgress(
            phase: .ping,
            fraction: 0,
            pingSampleTarget: SpeedtestEngineConfig.pingAttemptBudget,
            serverName: serverName,
            notice: notice
        ))

        // 1. Ping HTTPS (TTFB sur __down?bytes=0).
        let pingValues = try await measureCloudflarePings(serverName: serverName, progress: progress)
        let pingValue = SpeedMetricCalculator.average(pingValues)
        let pingMedianValue = SpeedMetricCalculator.median(pingValues)
        let pingMinValue = pingValues.min()
        let pingMaxValue = pingValues.max()
        let jitterValue = SpeedMetricCalculator.jitter(pingValues)

        // 2. Download.
        progress?(SpeedtestLiveProgress(phase: .download, fraction: 0, serverName: serverName))
        let usefulDuration = Double(durationSeconds)
        let dlSamplesBox = SpeedtestSamplesBox()
        let dlLiveSampler = SpeedtestLiveSampler()
        let dlState = ProgressState()
        let dlLoadedDeadline = Date().addingTimeInterval(usefulDuration + 1)
        let cfLoadedProbe = tcpProbe
        let dlLoadedTask = Task.detached(priority: .utility) {
            await SpeedtestService.collectIPerfLoadedPings(
                host: CloudflareSpeedtestConfig.host,
                port: CloudflareSpeedtestConfig.httpsPort,
                deadline: dlLoadedDeadline,
                tcpProbe: cfLoadedProbe
            )
        }
        defer { dlLoadedTask.cancel() }

        let dlOutcome = await measureCloudflareTransfer(
            direction: .download,
            session: session,
            streams: dlStreams,
            duration: usefulDuration,
            onProgress: { @Sendable bytes, elapsed in
                let elapsedMs = elapsed * 1000.0
                let needleMbps = dlLiveSampler.observe(totalBytes: bytes, elapsedMs: elapsedMs)
                let averageMbps = (Double(bytes) * 8.0 / 1_000_000.0) / max(0.1, elapsed)
                let deltaBytes = dlState.update(bytes: bytes, time: elapsedMs)
                dlSamplesBox.append(start: max(0, elapsedMs - 150), end: elapsedMs, bytes: deltaBytes)
                progress?(SpeedtestLiveProgress(
                    phase: .download,
                    currentMbps: needleMbps,
                    fraction: min(1, elapsed / usefulDuration),
                    downloadLiveMbps: needleMbps,
                    downloadAverageMbps: averageMbps,
                    serverName: serverName
                ))
            }
        )
        dlLoadedTask.cancel()
        let downloadPings = await dlLoadedTask.value
        let pingDlMs = downloadPings.isEmpty ? nil : SpeedMetricCalculator.average(downloadPings)
        let jitterDlMs = downloadPings.isEmpty ? nil : SpeedMetricCalculator.jitter(downloadPings)

        try Task.checkCancellation()
        guard dlOutcome.bytes > 100_000, dlOutcome.duration >= 1.0 else {
            sqDebugLog("SQ_CLOUDFLARE DL insuffisant : \(dlOutcome.bytes) octets en \(String(format: "%.1f", dlOutcome.duration))s (edge \(colo ?? "?"))")
            throw SpeedtestEngineError.noServerReachable
        }
        let dlStats = dlSamplesBox.publicStats(
            windowMs: SpeedtestEngineConfig.publicPeakWindowMs,
            graceMs: 0,
            endMs: max(dlOutcome.duration, 0.001) * 1_000
        )
        // Pas d'omit protocolaire côté Cloudflare : la série fine couvre le
        // test entier dès le premier octet (rampe réelle visible, grâce = 0).
        let dlGraphSeries = dlSamplesBox.publicStats(
            windowMs: SpeedtestEngineConfig.graphWindowMs,
            graceMs: 0,
            endMs: max(dlOutcome.duration, 0.001) * 1_000
        ).seriesMbps
        let dlAverageMbps = dlOutcome.averageMbps
        let dlPeakMbps = max(dlStats.peak, dlAverageMbps)

        // 3. Upload — best effort, le DL seul reste un résultat valide.
        progress?(SpeedtestLiveProgress(phase: .upload, fraction: 0, serverName: serverName))

        // Contexte (géocodage/SSID/opérateur) en parallèle de l'upload.
        let contextTask = resultContextTask(pathStatus: pathStatus, location: location)
        let ulSamplesBox = SpeedtestSamplesBox()
        let ulLiveSampler = SpeedtestLiveSampler()
        let ulState = ProgressState()
        var ulAverageMbps: Double?
        var ulPeakMbps: Double?
        var ulStats = SpeedtestSamplesBox.PublicStats(p90: nil, p95: nil, peak: 0, windowCount: 0, seriesMbps: [])
        var pingUlMs: Double?
        var jitterUlMs: Double?

        let ulLoadedDeadline = Date().addingTimeInterval(usefulDuration + 1)
        let ulLoadedTask = Task.detached(priority: .utility) {
            await SpeedtestService.collectIPerfLoadedPings(
                host: CloudflareSpeedtestConfig.host,
                port: CloudflareSpeedtestConfig.httpsPort,
                deadline: ulLoadedDeadline,
                tcpProbe: cfLoadedProbe
            )
        }
        defer { ulLoadedTask.cancel() }

        let ulOutcome = await measureCloudflareTransfer(
            direction: .upload,
            session: session,
            streams: ulStreams,
            duration: usefulDuration,
            onProgress: { @Sendable bytes, elapsed in
                let elapsedMs = elapsed * 1000.0
                let needleMbps = ulLiveSampler.observe(totalBytes: bytes, elapsedMs: elapsedMs)
                let averageMbps = (Double(bytes) * 8.0 / 1_000_000.0) / max(0.1, elapsed)
                let deltaBytes = ulState.update(bytes: bytes, time: elapsedMs)
                ulSamplesBox.append(start: max(0, elapsedMs - 150), end: elapsedMs, bytes: deltaBytes)
                progress?(SpeedtestLiveProgress(
                    phase: .upload,
                    currentMbps: needleMbps,
                    fraction: min(1, elapsed / usefulDuration),
                    uploadLiveMbps: needleMbps,
                    uploadAverageMbps: averageMbps,
                    serverName: serverName
                ))
            }
        )
        ulLoadedTask.cancel()
        let uploadPings = await ulLoadedTask.value
        if !uploadPings.isEmpty {
            pingUlMs = SpeedMetricCalculator.average(uploadPings)
            jitterUlMs = SpeedMetricCalculator.jitter(uploadPings)
        }
        try Task.checkCancellation()
        var ulGraphSeries: [Double] = []
        if ulOutcome.bytes > 100_000, ulOutcome.duration >= 1.0 {
            ulStats = ulSamplesBox.publicStats(
                windowMs: SpeedtestEngineConfig.publicPeakWindowMs,
                graceMs: 0,
                endMs: max(ulOutcome.duration, 0.001) * 1_000
            )
            ulGraphSeries = ulSamplesBox.publicStats(
                windowMs: SpeedtestEngineConfig.graphWindowMs,
                graceMs: 0,
                endMs: max(ulOutcome.duration, 0.001) * 1_000
            ).seriesMbps
            ulAverageMbps = ulOutcome.averageMbps
            ulPeakMbps = max(ulStats.peak, ulAverageMbps ?? 0)
        }

        let measurements = EngineMeasurements(
            serverName: serverName,
            downloadServerId: "cloudflare_\(colo ?? "edge")",
            downloadServerCode: colo ?? "edge",
            pingProtocol: "TCP",
            pingMs: pingValue,
            pingMedianMs: pingMedianValue,
            pingMinMs: pingMinValue,
            pingMaxMs: pingMaxValue,
            jitterMs: jitterValue,
            downloadAverageMbps: dlAverageMbps,
            downloadMaxMbps: dlPeakMbps,
            downloadP90Mbps: dlStats.p90,
            downloadP95Mbps: dlStats.p95,
            downloadSeriesMbps: dlGraphSeries.isEmpty ? dlStats.seriesMbps : dlGraphSeries,
            uploadAverageMbps: ulAverageMbps,
            uploadMaxMbps: ulPeakMbps,
            uploadP90Mbps: ulStats.p90,
            uploadP95Mbps: ulStats.p95,
            uploadSeriesMbps: ulGraphSeries.isEmpty
                ? (ulStats.seriesMbps.isEmpty ? nil : ulStats.seriesMbps)
                : ulGraphSeries,
            downloadGraceWindowCount: 0,
            uploadGraceWindowCount: 0,
            uploadMeasurementSource: "client-written",
            pingDlMs: pingDlMs,
            jitterDlMs: jitterDlMs,
            pingUlMs: pingUlMs,
            jitterUlMs: jitterUlMs
        )
        return await finalizeRun(
            measurements,
            startedAt: startedAt,
            pathStatus: pathStatus,
            location: location,
            context: contextTask,
            progress: progress
        )
    }

    /// Colo (code IATA) de l'edge joint — best effort, nil si trace KO.
    private func fetchCloudflareColo(session: URLSession) async -> String? {
        var request = URLRequest(url: CloudflareSpeedtestConfig.traceURL)
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return cloudflareParseColo(fromTrace: text)
    }

    /// Ping Cloudflare : **connexion TCP pure** sur l'edge (:443), exactement
    /// l'instrument du chemin iPerf3 → chiffres comparables entre serveurs.
    ///
    /// Un aller-retour HTTPS `__down?bytes=0` mesurerait aussi l'exécution du
    /// Worker et la surcouche URLSession : 44–222 ms observés là où le RTT
    /// réseau réel est de 17 ms (RTT confirmé par le header `server-timing:
    /// cfL4` de l'edge et par ICMP). Le handshake TCP, lui, colle au RTT.
    private func measureCloudflarePings(
        serverName: String,
        progress: SpeedtestProgressHandler?
    ) async throws -> [Double] {
        let result = await measureTcpPings(
            host: CloudflareSpeedtestConfig.host,
            port: CloudflareSpeedtestConfig.httpsPort,
            serverName: serverName,
            progress: progress,
            minimumValidSamples: 2
        )
        guard !result.values.isEmpty else { throw SpeedtestEngineError.pingFailed }
        return result.values
    }


    /// Transfert borné par une deadline : N flux concurrents qui enchaînent
    /// les requêtes `__down`/`__up` jusqu'à la fin de la fenêtre ; les octets
    /// sont comptés au fil de l'eau par les delegates de streaming.
    private func measureCloudflareTransfer(
        direction: CloudflareTransferDirection,
        session: URLSession,
        streams: Int,
        duration: Double,
        onProgress: @escaping @Sendable (_ bytes: Int, _ elapsedSeconds: Double) -> Void
    ) async -> CloudflareTransferOutcome {
        let counter = SafeCounter()
        let start = Date()
        let deadline = start.addingTimeInterval(duration)
        // Corps UL partagé (Data immuable, copy-on-write → 1 seule allocation).
        let uploadBody = direction == .upload ? Data(count: CloudflareSpeedtestConfig.uploadBytesPerRequest) : Data()

        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                let elapsed = Date().timeIntervalSince(start)
                onProgress(counter.value, min(elapsed, duration))
                if elapsed >= duration { break }
            }
        }
        defer { ticker.cancel() }

        // Une rafale d'échecs (endpoint refusé, réseau coupé) doit laisser une
        // trace : sans ça, un transfert vide se lit comme « serveurs occupés »
        // sans aucun indice de la vraie cause.
        let didLogFailure = AtomicBool(false)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, streams) {
                group.addTask { [counter, uploadBody, didLogFailure] in
                    while Date() < deadline, !Task.isCancelled {
                        do {
                            switch direction {
                            case .download:
                                var request = URLRequest(url: CloudflareSpeedtestConfig.downURL(bytes: CloudflareSpeedtestConfig.downloadBytesPerRequest))
                                request.timeoutInterval = duration + 10
                                let delegate = SpeedtestDownloadDelegate(deadline: deadline, onBytes: { counter.add($0) })
                                let task = session.dataTask(with: request)
                                task.delegate = delegate
                                try await delegate.run(task: task)
                            case .upload:
                                var request = URLRequest(url: CloudflareSpeedtestConfig.upURL)
                                request.httpMethod = "POST"
                                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                                request.timeoutInterval = duration + 10
                                let delegate = SpeedtestUploadDelegate(deadline: deadline, onBytesSent: { counter.add($0) })
                                let task = session.uploadTask(with: request, from: uploadBody)
                                task.delegate = delegate
                                _ = try await delegate.run(task: task)
                            }
                        } catch {
                            if Task.isCancelled || Date() >= deadline { break }
                            if !didLogFailure.value {
                                didLogFailure.value = true
                                sqDebugLog("SQ_CLOUDFLARE \(direction == .download ? "DL" : "UL") requête échouée : \(error.localizedDescription)")
                            }
                            // Requête ratée : court répit puis nouvel essai
                            // dans la fenêtre restante.
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }
                    }
                }
            }
        }
        ticker.cancel()
        let elapsed = min(Date().timeIntervalSince(start), duration)
        return CloudflareTransferOutcome(bytes: counter.value, duration: max(0.001, elapsed))
    }

    /// Lance iPerf3 en essayant la plage de ports du serveur si le port préféré
    /// est occupé (ACCESS_DENIED) ou refuse la connexion.
    ///
    /// **Fast path** : le `preferredPort` est tenté **immédiatement** (sans
    /// re-scan TCP de toute la plage). C’est critique entre DL et UL : le port
    /// qui a réussi le download est déjà connu — un probe 1.5 s bloquait
    /// artificiellement le démarrage de l’upload.
    ///
    /// **Fallback** : seulement si le preferred échoue, on sonde les autres
    /// ports de la plage puis on réessaie.
    private func runIPerf3WithPortFallback(
        hostname: String,
        preferredPort: UInt16,
        portMin: UInt16,
        portMax: UInt16,
        streams: Int,
        durationSeconds: Int,
        omitSeconds: Int,
        isDownload: Bool,
        knownOpenPorts: [UInt16] = [],
        onProgress: (@Sendable (_ bytesTransferred: Int, _ elapsedSeconds: Double) -> Void)?,
        onWarmup: (@Sendable (_ rawTotalBytes: Int, _ wallSeconds: Double) -> Void)? = nil,
        onPortAttempt: (@Sendable (_ port: UInt16, _ attempt: Int) -> Void)? = nil
    ) async throws -> (IPerf3Result, UInt16) {
        let lo = min(portMin, portMax)
        let hi = max(portMin, portMax)
        var siblingPorts = Array(lo...hi).filter { $0 != preferredPort }
        // Plages larges (Bouygues 9200–9240) : échantillonner les siblings.
        if siblingPorts.count > 15 {
            let sampleStride = max(1, siblingPorts.count / 12)
            var sampled: [UInt16] = []
            for p in stride(from: Int(lo), through: Int(hi), by: sampleStride) {
                let port = UInt16(p)
                if port != preferredPort { sampled.append(port) }
            }
            if !sampled.contains(lo), lo != preferredPort { sampled.insert(lo, at: 0) }
            if !sampled.contains(hi), hi != preferredPort { sampled.append(hi) }
            siblingPorts = sampled
        }

        var lastError: Error?
        var attempt = 0

        // 1) Preferred d’abord — zéro latence de discovery (cas UL après DL).
        onPortAttempt?(preferredPort, attempt)
        attempt += 1
        do {
            let runner = IPerf3Runner(
                hostname: hostname,
                port: preferredPort,
                streams: streams,
                durationSeconds: durationSeconds,
                omitSeconds: omitSeconds,
                isDownload: isDownload,
                onProgress: onProgress,
                onWarmup: onWarmup
            )
            return (try await runner.run(), preferredPort)
        } catch {
            // Un « Arrêter » utilisateur ne doit JAMAIS déclencher le re-scan
            // de la plage : l'erreur .cancelled est retryable côté serveur,
            // pas côté tâche annulée.
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            if isRetryableIPerfTransportError(error) {
                lastError = error
            } else {
                throw error
            }
        }

        // 2) Preferred KO → ports déjà confirmés ouverts au probe initial
        // (zéro re-scan en cours de test), sinon sonde rapide des siblings.
        try Task.checkCancellation()
        let orderedPorts: [UInt16]
        let knownCandidates = knownOpenPorts.filter { $0 != preferredPort }
        if !knownCandidates.isEmpty {
            orderedPorts = knownCandidates
        } else {
            let probedOpen = await probeOpenTCPPorts(
                host: hostname,
                ports: siblingPorts,
                timeoutSeconds: 0.9
            )
            orderedPorts = probedOpen.isEmpty ? siblingPorts : probedOpen
        }

        for candidatePort in orderedPorts {
            try Task.checkCancellation()
            onPortAttempt?(candidatePort, attempt)
            attempt += 1
            do {
                let runner = IPerf3Runner(
                    hostname: hostname,
                    port: candidatePort,
                    streams: streams,
                    durationSeconds: durationSeconds,
                    omitSeconds: omitSeconds,
                    isDownload: isDownload,
                    onProgress: onProgress,
                    onWarmup: onWarmup
                )
                return (try await runner.run(), candidatePort)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                if isRetryableIPerfTransportError(error) {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError ?? SpeedtestEngineError.noServerReachable
    }

    private struct CellularOperatorContext: Sendable {
        let mobileOperator: String?
        let mcc: Int?
        let mnc: Int?
        let marketCode: String?
        let operatorKey: String?

        static let empty = CellularOperatorContext(
            mobileOperator: nil,
            mcc: nil,
            mnc: nil,
            marketCode: nil,
            operatorKey: nil
        )
    }

    /// Construit le contexte opérateur d'un test cellulaire.
    ///
    /// CoreTelephony (`CTCarrier`) ne renvoie plus MCC/MNC/nom depuis iOS 16.4+
    /// (placeholders `--` / 65535, filtrés en amont → nil). On reconstruit donc le
    /// contexte comme la carte : opérateur via IP/ASN (`/api/speedtest/operator`,
    /// hors VPN), marché via la localisation, puis backfill MCC/MNC depuis le
    /// registre. Sous VPN la résolution IP renvoie un opérateur nul : on
    /// n'enregistre JAMAIS l'opérateur du tunnel.
    private func resolveCellularOperatorContext(
        pathStatus: NetworkPathStatus,
        location: Coordinates?
    ) async -> CellularOperatorContext {
        guard pathStatus.connection == .cellular else { return .empty }
        let ctMcc = pathStatus.operatorMcc
        let ctMnc = pathStatus.operatorMnc
        let registry = await markets.registry()

        // Marché : MCC de la SIM (si encore lisible) → localisation GPS.
        var market = ctMcc.flatMap { mcc in registry.markets.first { $0.mccs.contains(mcc) } }
        if market == nil, let location {
            market = await markets.marketForLocation(latitude: location.latitude, longitude: location.longitude)
        }

        // Opérateur fiable sur iOS moderne : résolution IP/ASN côté backend.
        // `viaVpn` → le backend renvoie un opérateur nul sous tunnel (l'IP
        // refléterait le VPN), donc aucun faux opérateur n'est enregistré.
        let detected = await networkOperator.resolve(viaVpn: VPNDetector.isActive())
        let trusted = (detected?.viaVpn == true) ? nil : detected

        var operatorEntry: MarketRegistryOperator?
        if let key = trusted?.operatorKey {
            operatorEntry = market?.operatorEntry(forKey: key)
            // MCC muet (16.4+) : retrouve le marché via l'opérateur IP.
            if market == nil {
                market = registry.markets.first { $0.operatorEntry(forKey: key) != nil }
                operatorEntry = market?.operatorEntry(forKey: key)
            }
        }
        // Repli : opérateur via le MNC de la SIM (rare sur 16.4+, mais gratuit).
        if operatorEntry == nil, let mnc = ctMnc {
            operatorEntry = market?.selectableOperators.first { $0.mncs.contains(mnc) }
        }

        // Backfill : MCC depuis le marché ; MNC = MNC principal (1er du registre) de
        // l'opérateur résolu. Best-effort si l'opérateur a plusieurs MNC (ex. Orange
        // 208-01/02) : l'operatorKey reste exact, le MNC sert d'indication.
        let mcc = ctMcc ?? market?.mccs.first
        let mnc = ctMnc ?? operatorEntry?.mncs.first

        return CellularOperatorContext(
            // nil quand inconnu → l'UI retombe proprement sur la techno seule.
            mobileOperator: pathStatus.operatorName
                ?? trusted?.shortLabel ?? trusted?.label
                ?? operatorEntry?.shortLabel ?? operatorEntry?.label,
            mcc: mcc,
            mnc: mnc,
            marketCode: market?.marketCode,
            operatorKey: operatorEntry?.key ?? trusted?.operatorKey
        )
    }

    // MARK: Persistence

    func save(_ result: SpeedtestRunResult) async throws {
        try await save(result, streams: 4, publishToMap: false)
    }

    func save(_ result: SpeedtestRunResult, streams: Int) async throws {
        try await save(result, streams: streams, publishToMap: false)
    }

    func save(_ result: SpeedtestRunResult, streams: Int, publishToMap: Bool) async throws {
        try await save(
            result,
            streams: streams,
            publishToMap: publishToMap,
            shareExactLocation: false,
            driveSessionId: nil
        )
    }

    // Surcharge « drive test » : `driveSessionId` (id local de la session en cours)
    // rattache le speedtest à sa session côté serveur. Paramètre REQUIS (pas de valeur
    // par défaut) pour ne pas entrer en ambiguïté avec la surcharge sans session
    // ci-dessus, et pour laisser les 4 méthodes du protocole SpeedtestServicing intactes.
    func save(
        _ result: SpeedtestRunResult,
        streams: Int,
        publishToMap: Bool,
        driveSessionId: String?
    ) async throws {
        try await save(
            result,
            streams: streams,
            publishToMap: publishToMap,
            shareExactLocation: false,
            driveSessionId: driveSessionId
        )
    }

    func save(
        _ result: SpeedtestRunResult,
        streams: Int,
        publishToMap: Bool,
        shareExactLocation: Bool
    ) async throws {
        try await save(
            result,
            streams: streams,
            publishToMap: publishToMap,
            shareExactLocation: shareExactLocation,
            driveSessionId: nil
        )
    }

    func save(
        _ result: SpeedtestRunResult,
        streams: Int,
        publishToMap: Bool,
        shareExactLocation: Bool,
        driveSessionId: String?
    ) async throws {
        let guestDeleteToken: String?
        if api.credentials.accessToken() == nil {
            guard let token = Self.makeGuestDeleteToken() else {
                throw GuestSpeedtestReceiptError.tokenGenerationFailed
            }
            guestDeleteToken = token
        } else {
            guestDeleteToken = nil
        }
        let pending = PendingSpeedtestSave(
            id: result.id.uuidString,
            result: result,
            streams: streams,
            deviceModel: await UIDevice.current.modelName,
            createdAt: Date(),
            isVisibleOnMap: publishToMap,
            shareExactLocation: publishToMap && shareExactLocation,
            guestDeleteToken: guestDeleteToken,
            driveSessionId: driveSessionId
        )
        try await upsertPendingSave(pending)
        do {
            try await submitPendingSave(pending)
            await removePendingSave(id: pending.id)
            try? await flushPendingSaves(excluding: Set([pending.id]))
        } catch {
            throw error
        }
    }

    func history() async -> [SpeedtestRunResult] {
        (try? await historyCache.read([SpeedtestRunResult].self, for: "history")) ?? []
    }

    func retryPendingSaves() async {
        try? await flushPendingSaves()
    }

    func details(id: String) async throws -> SpeedtestDetail {
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await api.request(
            APIEndpoint(path: "/api/speedtests/\(encodedId)", authenticated: false),
            as: SpeedtestDetail.self
        )
    }

    func guestDeletionReceipts() -> [GuestSpeedtestDeletionReceipt] {
        guestReceiptStore.all()
    }

    func deleteGuestSpeedtest(_ receipt: GuestSpeedtestDeletionReceipt) async throws {
        let encodedId = receipt.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? receipt.id
        let _: SuccessResponse = try await api.request(
            APIEndpoint(
                path: "/api/speedtests/\(encodedId)",
                method: .delete,
                headers: ["X-Speedtest-Delete-Token": receipt.deleteToken],
                authenticated: false
            ),
            as: SuccessResponse.self
        )
        guestReceiptStore.remove(id: receipt.id)
    }

    private func appendHistory(_ result: SpeedtestRunResult) async throws {
        var values = await history()
        values.insert(result, at: 0)
        if values.count > 20 { values = Array(values.prefix(20)) }
        try await historyCache.write(values, for: "history")
        // Partage le dernier résultat avec le widget (App Group), rafraîchit le
        // widget et indexe l'item Spotlight.
        let snapshot = SpeedtestWidgetSnapshot(
            downloadMbps: result.downloadMbps,
            uploadMbps: result.uploadMbps,
            pingMs: result.pingMinMs ?? result.pingMs,
            jitterMs: result.jitterMs,
            network: result.networkOperatorName ?? result.wifiSSID ?? "Réseau",
            label: result.label,
            date: result.createdAt
        )
        WidgetSharedStore.saveLastSpeedtest(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        SQSpotlight.donateLastSpeedtest(snapshot)
    }

    private func pendingSaves() async -> [PendingSpeedtestSave] {
        await pendingStore.loadAll()
    }

    private func writePendingSaves(_ values: [PendingSpeedtestSave]) async throws {
        try await pendingStore.replaceAll(values)
    }

    private func upsertPendingSave(_ pending: PendingSpeedtestSave) async throws {
        var values = await pendingSaves().filter { $0.id != pending.id }
        values.append(pending)
        try await writePendingSaves(values)
    }

    private func removePendingSave(id: String) async {
        let values = await pendingSaves().filter { $0.id != id }
        do {
            try await writePendingSaves(values)
        } catch {
            sqDebugLog("SQ_IPERF pending save cleanup failed: \(error.localizedDescription)")
        }
    }

    private func submitPendingSave(_ pending: PendingSpeedtestSave) async throws {
        let payload = SpeedtestSubmission.iosPayload(
            from: pending.result,
            streams: pending.streams,
            deviceModel: pending.deviceModel,
            isVisibleOnMap: pending.isVisibleOnMap ?? false,
            shareExactLocation: pending.shareExactLocation ?? false,
            guestDeleteToken: pending.guestDeleteToken,
            sessionId: pending.driveSessionId
        )
        let response: SpeedtestSaveResponse = try await api.requestJSON(
            "/api/speedtests",
            body: payload,
            idempotencyKey: pending.id
        )
        if let serverId = response.resolvedID {
            // Mémorisé pour TOUS : sans cet id, un test de l'historique ne peut
            // plus être ciblé (publication a posteriori). Il n'était conservé
            // que pour les invités, via le reçu de suppression.
            await rememberServerId(serverId, forClientId: pending.id)
            if let deleteToken = response.deleteToken ?? pending.guestDeleteToken {
                guestReceiptStore.upsert(GuestSpeedtestDeletionReceipt(
                    id: serverId,
                    clientSubmissionId: pending.id,
                    deleteToken: deleteToken,
                    createdAt: pending.createdAt
                ))
            }
        }
    }

    // MARK: - Correspondance id client → id serveur

    private var serverIdMapKey: String { "serverIds" }

    private func rememberServerId(_ serverId: String, forClientId clientId: String) async {
        var map = (try? await historyCache.read([String: String].self, for: serverIdMapKey)) ?? [:]
        guard map[clientId] != serverId else { return }
        map[clientId] = serverId
        // Bornée comme l'historique : inutile de garder des ids dont le test a
        // déjà disparu de la liste.
        if map.count > 60 {
            let keep = Set(((try? await history()) ?? []).map(\.id.uuidString))
            map = map.filter { keep.contains($0.key) || $0.key == clientId }
        }
        try? await historyCache.write(map, for: serverIdMapKey)
    }

    func serverId(forClientId clientId: UUID) async -> String? {
        let map = (try? await historyCache.read([String: String].self, for: serverIdMapKey)) ?? [:]
        return map[clientId.uuidString]
    }

    func publishOnMap(clientId: UUID, shareExactLocation: Bool) async throws {
        guard let serverId = await serverId(forClientId: clientId) else {
            throw SpeedtestPublishError.unknownServerId
        }
        // PATCH et non POST : re-soumettre le même test renverrait la réponse
        // idempotente d'origine sans rien modifier — publication silencieusement
        // sans effet (vérifié côté backend).
        try await api.requestJSON(
            "/api/speedtests/\(serverId)",
            method: .patch,
            body: SpeedtestVisibilityUpdate(
                isVisibleOnMap: true,
                shareExactLocation: shareExactLocation
            )
        )
    }

    private static func makeGuestDeleteToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            return nil
        }
        return Data(bytes).base64URLEncodedNoPadding()
    }

    private func flushPendingSaves(excluding excludedIds: Set<String> = []) async throws {
        let pending = await pendingSaves()
        guard !pending.isEmpty else { return }
        var remaining: [PendingSpeedtestSave] = []
        var firstError: Error?
        for item in pending where !excludedIds.contains(item.id) {
            do {
                try await submitPendingSave(item)
            } catch {
                remaining.append(item)
                if firstError == nil { firstError = error }
            }
        }
        for item in pending where excludedIds.contains(item.id) {
            remaining.append(item)
        }
        do {
            try await writePendingSaves(remaining)
        } catch {
            sqDebugLog("SQ_IPERF flush save failed: \(error.localizedDescription)")
        }
        if let firstError { throw firstError }
    }

    // MARK: - Ping

    private struct PingOutcome: Sendable {
        let values: [Double]
        let protocolName: String
    }

    private struct PingAttemptResult: Sendable {
        let values: [Double]
        let attemptsUsed: Int
    }

    /// Ping TCP dédié iPerf : jamais de fallback HTTP (ATS / ports non-HTTP).
    /// Exige ≥ 2 échantillons (jitter/médiane sans signification à 1) — avec
    /// salvage intégré à `measureTcpPings` avant d'échouer le run.
    private func measureIPerfTcpPings(
        host: String,
        port: UInt16,
        serverName: String,
        progress: SpeedtestProgressHandler?
    ) async throws -> PingOutcome {
        let result = await measureTcpPings(
            host: host,
            port: port,
            serverName: serverName,
            progress: progress,
            minimumValidSamples: 2
        )
        guard !result.values.isEmpty else { throw SpeedtestEngineError.pingFailed }
        return PingOutcome(values: result.values, protocolName: "TCP")
    }

    /// RTT TCP sous charge (pendant DL/UL iPerf) : connect latency uniquement,
    /// sans handshake iPerf3, pour peupler pingDl/Ul + jitterDl/Ul.
    private static func collectIPerfLoadedPings(
        host: String,
        port: UInt16,
        deadline: Date,
        tcpProbe: SpeedtestTCPProbing
    ) async -> [Double] {
        var values: [Double] = []
        while Date() < deadline && !Task.isCancelled {
            do {
                let elapsed = try await tcpProbe.connectLatencyMs(
                    host: host,
                    port: port,
                    timeoutSeconds: SpeedtestEngineConfig.pingTimeoutSeconds
                )
                if !Task.isCancelled,
                   elapsed > 0,
                   elapsed < SpeedtestEngineConfig.pingTimeoutSeconds * 1_000 {
                    values.append(elapsed)
                }
            } catch {
                // Échantillon raté sous charge : on continue.
            }
            if Task.isCancelled || Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: UInt64(SpeedtestEngineConfig.pingIntervalMs * 1_000_000))
        }
        return values
    }

    private func measureTcpPings(
        host: String,
        port: UInt16,
        serverName: String,
        progress: SpeedtestProgressHandler?,
        minimumValidSamples: Int = SpeedtestEngineConfig.pingMinimumValidSamples
    ) async -> PingAttemptResult {
        var values: [Double] = []
        var attemptsUsed = 0
        let measuredTarget = speedtestPingMeasuredSampleTarget(
            attemptBudget: SpeedtestEngineConfig.pingAttemptBudget,
            warmupCount: SpeedtestEngineConfig.pingWarmupCount
        )

        // Warm-up (non compté) — un échec n'abandonne pas tout le run iPerf.
        do {
            attemptsUsed += 1
            _ = try await tcpProbe.connectLatencyMs(
                host: host,
                port: port,
                timeoutSeconds: SpeedtestEngineConfig.pingTimeoutSeconds
            )
        } catch {
            // Continuer : le premier connect peut échouer (DNS / cold start).
        }

        try? await Task.sleep(nanoseconds: UInt64(SpeedtestEngineConfig.pingIntervalMs * 1_000_000))
        for _ in 0..<measuredTarget where attemptsUsed < SpeedtestEngineConfig.pingAttemptBudget {
            do {
                attemptsUsed += 1
                let elapsed = try await tcpProbe.connectLatencyMs(
                    host: host,
                    port: port,
                    timeoutSeconds: SpeedtestEngineConfig.pingTimeoutSeconds
                )
                // Filtre les outliers aberrants (timeout partiel → latence saturée).
                if elapsed > 0, elapsed < SpeedtestEngineConfig.pingTimeoutSeconds * 1_000 {
                    values.append(elapsed)
                    emitPingProgress(
                        values: values,
                        protocolName: "TCP",
                        target: measuredTarget,
                        serverName: serverName,
                        progress: progress
                    )
                } else {
                    emitPingAttemptTick(attemptsUsed: attemptsUsed, values: values, target: measuredTarget, serverName: serverName, progress: progress)
                }
            } catch {
                // Échantillon raté : on continue pour maximiser le nombre de mesures,
                // mais la barre avance quand même (réseau perdant ≠ UI figée).
                emitPingAttemptTick(attemptsUsed: attemptsUsed, values: values, target: measuredTarget, serverName: serverName, progress: progress)
            }
            try? await Task.sleep(nanoseconds: UInt64(SpeedtestEngineConfig.pingIntervalMs * 1_000_000))
        }
        // Salvage : sur réseau perdant, quelques probes rapprochées valent
        // mieux qu'un run entier avorté faute d'échantillons.
        var salvageUsed = 0
        while values.count < minimumValidSamples, salvageUsed < SpeedtestEngineConfig.pingSalvageAttempts {
            salvageUsed += 1
            attemptsUsed += 1
            do {
                let elapsed = try await tcpProbe.connectLatencyMs(
                    host: host,
                    port: port,
                    timeoutSeconds: SpeedtestEngineConfig.pingTimeoutSeconds
                )
                if elapsed > 0, elapsed < SpeedtestEngineConfig.pingTimeoutSeconds * 1_000 {
                    values.append(elapsed)
                    emitPingProgress(values: values, protocolName: "TCP", target: measuredTarget, serverName: serverName, progress: progress)
                }
            } catch {
                // Dernier recours déjà : rien d'autre à faire.
            }
            try? await Task.sleep(nanoseconds: UInt64(SpeedtestEngineConfig.pingSalvageIntervalMs * 1_000_000))
        }
        if values.count < minimumValidSamples {
            return PingAttemptResult(values: [], attemptsUsed: attemptsUsed)
        }
        return PingAttemptResult(values: values, attemptsUsed: attemptsUsed)
    }

    /// Tick de progression émis sur tentative ratée : la fraction suit les
    /// tentatives consommées pour que la phase ping ne paraisse jamais figée.
    private func emitPingAttemptTick(
        attemptsUsed: Int,
        values: [Double],
        target: Int,
        serverName: String,
        progress: SpeedtestProgressHandler?
    ) {
        let budget = SpeedtestEngineConfig.pingAttemptBudget
        progress?(SpeedtestLiveProgress(
            phase: .ping,
            fraction: budget > 0 ? min(1, Double(attemptsUsed) / Double(budget)) : 0,
            pingLiveMs: values.last,
            pingProtocol: "TCP",
            pingSampleCount: values.count,
            pingSampleTarget: target,
            serverName: serverName
        ))
    }

    private func emitPingProgress(
        values: [Double],
        protocolName: String,
        target: Int,
        serverName: String,
        progress: SpeedtestProgressHandler?
    ) {
        let sampleCount = values.count
        progress?(SpeedtestLiveProgress(
            phase: .ping,
            fraction: target > 0 ? min(1, Double(sampleCount) / Double(target)) : 0,
            pingLiveMs: values.last,
            pingFinalMs: values.min(),
            jitterMs: SpeedMetricCalculator.jitter(values),
            pingProtocol: protocolName,
            pingSampleCount: sampleCount,
            pingSampleTarget: target,
            serverName: serverName
        ))
    }

    /// Session de MESURE persistante pour une phase (download OU upload),
    /// partagée par tous les streams : `httpMaximumConnectionsPerHost` = nombre
    /// de streams pour qu'ils conservent chacun leur connexion. Invalidée par
    /// l'appelant en fin de phase.
    private func makeMeasurementSession(maxConnectionsPerHost: Int, requestTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = max(1, maxConnectionsPerHost)
        config.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: config)
    }

    struct ResolvedPlace: Sendable {
        let city: String?
        let address: String?
    }

    private func reverseGeocodedPlace(for coordinate: Coordinates?) async -> ResolvedPlace {
        guard let coordinate else { return ResolvedPlace(city: nil, address: nil) }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return await withTaskGroup(of: ResolvedPlace?.self) { group in
            group.addTask {
                guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
                    return nil
                }
                let city = [
                    placemark.locality,
                    placemark.subAdministrativeArea,
                    placemark.administrativeArea
                ]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                return ResolvedPlace(
                    city: city,
                    address: Self.minimizedAddress(from: placemark, fallbackCity: city)
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let place = await group.next() ?? nil
            group.cancelAll()
            return place ?? ResolvedPlace(city: nil, address: nil)
        }
    }

    /// Compose une adresse « rue, code postal commune » à partir d'un placemark,
    /// sans le numéro de voirie (`subThoroughfare`) pour rester cohérent avec la
    /// minimisation des coordonnées (RGPD art. 5.1.c).
    private static func minimizedAddress(from placemark: CLPlacemark, fallbackCity: String?) -> String? {
        let street = placemark.thoroughfare?.trimmingCharacters(in: .whitespacesAndNewlines)
        let postalCode = placemark.postalCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = placemark.locality?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackCity
        let locality = [postalCode, city]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")
        let parts = [street, locality.isEmpty ? nil : locality]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func currentWiFiSSID(for pathStatus: NetworkPathStatus) async -> String? {
        guard pathStatus.connection == .wifi else { return nil }
        return await WiFiSSIDProvider.currentSSID()
    }
}

struct IPerfPublicServer: Sendable, Equatable {
    let hostname: String
    let name: String
    let latitude: Double
    let longitude: Double
    /// Code court (RBX, PAR-BBR, …).
    let code: String
    let countryCode: String
    let provider: IPerfServerProvider
    let portMin: UInt16
    let portMax: UInt16

    var defaultPort: UInt16 { portMin }
}

enum IPerfServerProvider: String, Sendable {
    case ovh
    case bouygues
    case scaleway
    case milkywan
}

/// Catalogue des serveurs iPerf3 publics (OVH + Bouygues sains + Scaleway online.net).
/// `poi.cubic.iperf.bytel.fr` est volontairement absent (host non joignable).
let iperfPublicServers: [IPerfPublicServer] = {
    let ovhMin = SpeedtestEngineConfig.iperf3PortMin
    let ovhMax = SpeedtestEngineConfig.iperf3PortMax
    let bytMin = SpeedtestEngineConfig.bytelIperfPortMin
    let bytMax = SpeedtestEngineConfig.bytelIperfPortMax
    let scwMin = SpeedtestEngineConfig.onlineNetIperfPortMin
    let scwMax = SpeedtestEngineConfig.onlineNetIperfPortMax
    let parisLat = 48.8566
    let parisLon = 2.3522
    return [
        // OVH proof (ports 5201–5210)
        IPerfPublicServer(hostname: "rbx.proof.ovh.net", name: "Roubaix (OVH RBX)", latitude: 50.692, longitude: 3.178, code: "RBX", countryCode: "FR", provider: .ovh, portMin: ovhMin, portMax: ovhMax),
        IPerfPublicServer(hostname: "sbg.proof.ovh.net", name: "Strasbourg (OVH SBG)", latitude: 48.573, longitude: 7.752, code: "SBG", countryCode: "FR", provider: .ovh, portMin: ovhMin, portMax: ovhMax),
        IPerfPublicServer(hostname: "gra.proof.ovh.net", name: "Gravelines (OVH GRA)", latitude: 50.986, longitude: 2.124, code: "GRA", countryCode: "FR", provider: .ovh, portMin: ovhMin, portMax: ovhMax),
        IPerfPublicServer(hostname: "bom.proof.ovh.net", name: "Mumbai (OVH YNM)", latitude: 19.076, longitude: 72.877, code: "YNM", countryCode: "IN", provider: .ovh, portMin: ovhMin, portMax: ovhMax),
        IPerfPublicServer(hostname: "bhs.proof.ovh.ca", name: "Beauharnois (OVH BHS)", latitude: 45.312, longitude: -73.875, code: "BHS", countryCode: "CA", provider: .ovh, portMin: ovhMin, portMax: ovhMax),
        IPerfPublicServer(hostname: "proof.ovh.us", name: "Ashburn (OVH US)", latitude: 39.0438, longitude: -77.4874, code: "US", countryCode: "US", provider: .ovh, portMin: ovhMin, portMax: ovhMax),
        // Bouygues Telecom (ports 9200–9240) — BBR & CUBIC (poi.cubic exclu)
        IPerfPublicServer(hostname: "paris.bbr.iperf.bytel.fr", name: "Paris BBR (Bouygues)", latitude: parisLat, longitude: parisLon, code: "PAR-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "paris.cubic.iperf.bytel.fr", name: "Paris CUBIC (Bouygues)", latitude: parisLat, longitude: parisLon, code: "PAR-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "mrs.bbr.iperf.bytel.fr", name: "Marseille BBR (Bouygues)", latitude: 43.2965, longitude: 5.3698, code: "MRS-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "mrs.cubic.iperf.bytel.fr", name: "Marseille CUBIC (Bouygues)", latitude: 43.2965, longitude: 5.3698, code: "MRS-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "lyo.bbr.iperf.bytel.fr", name: "Lyon BBR (Bouygues)", latitude: 45.7640, longitude: 4.8357, code: "LYO-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "lyo.cubic.iperf.bytel.fr", name: "Lyon CUBIC (Bouygues)", latitude: 45.7640, longitude: 4.8357, code: "LYO-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "tls.bbr.iperf.bytel.fr", name: "Toulouse BBR (Bouygues)", latitude: 43.6047, longitude: 1.4442, code: "TLS-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "tls.cubic.iperf.bytel.fr", name: "Toulouse CUBIC (Bouygues)", latitude: 43.6047, longitude: 1.4442, code: "TLS-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "str.bbr.iperf.bytel.fr", name: "Strasbourg BBR (Bouygues)", latitude: 48.5734, longitude: 7.7521, code: "STR-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "str.cubic.iperf.bytel.fr", name: "Strasbourg CUBIC (Bouygues)", latitude: 48.5734, longitude: 7.7521, code: "STR-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "poi.bbr.iperf.bytel.fr", name: "Poitiers BBR (Bouygues)", latitude: 46.5802, longitude: 0.3404, code: "POI-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "ren.bbr.iperf.bytel.fr", name: "Rennes BBR (Bouygues)", latitude: 48.1173, longitude: -1.6778, code: "REN-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(hostname: "ren.cubic.iperf.bytel.fr", name: "Rennes CUBIC (Bouygues)", latitude: 48.1173, longitude: -1.6778, code: "REN-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        // Scaleway / online.net (ports 5200–5209 TCP) — filet de secours + IPv6
        IPerfPublicServer(hostname: "ping.online.net", name: "Paris Scaleway", latitude: parisLat, longitude: parisLon, code: "SCW", countryCode: "FR", provider: .scaleway, portMin: scwMin, portMax: scwMax),
        IPerfPublicServer(hostname: "ping6.online.net", name: "Paris Scaleway IPv6", latitude: parisLat, longitude: parisLon, code: "SCW6", countryCode: "FR", provider: .scaleway, portMin: scwMin, portMax: scwMax),
        IPerfPublicServer(hostname: "ping-90ms.online.net", name: "Paris Scaleway +90 ms", latitude: parisLat, longitude: parisLon, code: "SCW90", countryCode: "FR", provider: .scaleway, portMin: scwMin, portMax: scwMax),
        IPerfPublicServer(hostname: "ping6-90ms.online.net", name: "Paris Scaleway IPv6 +90 ms", latitude: parisLat, longitude: parisLon, code: "SCW690", countryCode: "FR", provider: .scaleway, portMin: scwMin, portMax: scwMax),
        // MilkyWan AS2027 (ports 9200–9240 TCP, BBR, 40 Gbit/s) — vérifié en ligne 2026-07
        IPerfPublicServer(hostname: "speedtest.milkywan.fr", name: "Croissy-Beaubourg (MilkyWan)", latitude: 48.8412, longitude: 2.6724, code: "CBO", countryCode: "FR", provider: .milkywan, portMin: bytMin, portMax: bytMax),
    ]
}()

class ConcurrencyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag { return true }
        flag = true
        return false
    }
}

class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var val: Bool

    init(_ val: Bool) { self.val = val }

    var value: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return val
        }
        set {
            lock.lock(); val = newValue; lock.unlock()
        }
    }
}

func haversineDistanceKm(from c1: Coordinates, to c2: Coordinates) -> Double {
    let lat1 = c1.latitude * .pi / 180.0
    let lon1 = c1.longitude * .pi / 180.0
    let lat2 = c2.latitude * .pi / 180.0
    let lon2 = c2.longitude * .pi / 180.0
    let dlat = lat2 - lat1
    let dlon = lon2 - lon1
    let a = sin(dlat / 2) * sin(dlat / 2) + cos(lat1) * cos(lat2) * sin(dlon / 2) * sin(dlon / 2)
    let c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return 6371.0 * c
}

func iperfServersSortedByDistance(from location: Coordinates?) -> [IPerfPublicServer] {
    guard let location else {
        // Sans GPS : POP FR stables d'abord ; IPv6 / +90 ms en bas de liste.
        let preferred = [
            "paris.bbr.iperf.bytel.fr",
            "ping.online.net",
            "speedtest.milkywan.fr",
            "gra.proof.ovh.net",
            "rbx.proof.ovh.net",
            "sbg.proof.ovh.net",
            "lyo.bbr.iperf.bytel.fr",
            "paris.cubic.iperf.bytel.fr",
            "ping6.online.net",
            "ping-90ms.online.net",
            "ping6-90ms.online.net",
        ]
        return iperfPublicServers.sorted { a, b in
            let ia = preferred.firstIndex(of: a.hostname) ?? 99
            let ib = preferred.firstIndex(of: b.hostname) ?? 99
            if ia != ib { return ia < ib }
            return a.name < b.name
        }
    }
    // Avec GPS : distance, mais déprioriser les hosts à latence artificielle (+90 ms)
    // et les IPv6-only pour éviter de les choisir en Auto sur un réseau IPv4.
    return iperfPublicServers.sorted { s1, s2 in
        let p1 = iperfAutoPriorityBoost(s1)
        let p2 = iperfAutoPriorityBoost(s2)
        if p1 != p2 { return p1 < p2 }
        let d1 = haversineDistanceKm(from: location, to: Coordinates(latitude: s1.latitude, longitude: s1.longitude))
        let d2 = haversineDistanceKm(from: location, to: Coordinates(latitude: s2.latitude, longitude: s2.longitude))
        return d1 < d2
    }
}

/// 0 = prioritaire Auto, 1 = IPv6, 2 = latence artificielle +90 ms.
private func iperfAutoPriorityBoost(_ server: IPerfPublicServer) -> Int {
    switch server.hostname {
    case "ping-90ms.online.net", "ping6-90ms.online.net": return 2
    case "ping6.online.net": return 1
    default: return 0
    }
}

func findClosestIPerfServer(to location: Coordinates?) -> IPerfPublicServer {
    iperfServersSortedByDistance(from: location).first ?? iperfPublicServers[0]
}

func selectIPerfServer(for target: SpeedtestDownloadTarget, location: Coordinates?) -> IPerfPublicServer {
    let host: String?
    switch target.migrated {
    case .rbx: host = "rbx.proof.ovh.net"
    case .sbg: host = "sbg.proof.ovh.net"
    case .gra: host = "gra.proof.ovh.net"
    case .bom: host = "bom.proof.ovh.net"
    case .bhs: host = "bhs.proof.ovh.ca"
    case .us: host = "proof.ovh.us"
    case .bytelParisBbr: host = "paris.bbr.iperf.bytel.fr"
    case .bytelParisCubic: host = "paris.cubic.iperf.bytel.fr"
    case .bytelMrsBbr: host = "mrs.bbr.iperf.bytel.fr"
    case .bytelMrsCubic: host = "mrs.cubic.iperf.bytel.fr"
    case .bytelLyoBbr: host = "lyo.bbr.iperf.bytel.fr"
    case .bytelLyoCubic: host = "lyo.cubic.iperf.bytel.fr"
    case .bytelTlsBbr: host = "tls.bbr.iperf.bytel.fr"
    case .bytelTlsCubic: host = "tls.cubic.iperf.bytel.fr"
    case .bytelStrBbr: host = "str.bbr.iperf.bytel.fr"
    case .bytelStrCubic: host = "str.cubic.iperf.bytel.fr"
    case .bytelPoiBbr: host = "poi.bbr.iperf.bytel.fr"
    case .bytelRenBbr: host = "ren.bbr.iperf.bytel.fr"
    case .bytelRenCubic: host = "ren.cubic.iperf.bytel.fr"
    case .onlineNet: host = "ping.online.net"
    case .onlineNet6: host = "ping6.online.net"
    case .onlineNet90ms: host = "ping-90ms.online.net"
    case .onlineNet6_90ms: host = "ping6-90ms.online.net"
    case .milkywan: host = "speedtest.milkywan.fr"
    // .cloudflare n'est pas un serveur iPerf3 : le moteur HTTPS est choisi en
    // amont dans run() ; ici on retombe sur le plus proche par sécurité.
    case .hybridAuto, .cloudflare, .bytelPoiCubic, .cloudflareR2, .awsCloudFront, .vpsInternal:
        host = nil
    }
    if let host, let server = iperfPublicServers.first(where: { $0.hostname == host }) {
        return server
    }
    return findClosestIPerfServer(to: location)
}

struct IPerfEndpoint: Sendable {
    let port: UInt16
    /// Ports confirmés ouverts au probe initial — réutilisés entre DL et UL
    /// pour éviter un re-scan TCP de la plage en cours de test.
    let openPorts: [UInt16]

    init(port: UInt16, openPorts: [UInt16] = []) {
        self.port = port
        self.openPorts = openPorts
    }
}

/// Probe TCP parallèle de la plage de ports du serveur.
/// Les ports « busy » (ACCESS_DENIED) sont gérés ensuite par
/// `runIPerf3WithPortFallback` au moment du vrai test.
func resolveIPerfEndpoint(for server: IPerfPublicServer) async -> IPerfEndpoint? {
    let lo = server.portMin
    let hi = server.portMax
    let allPorts = Array(lo...hi)
    // Plages larges : sonder un sous-ensemble + min/max pour rester rapide.
    let ports: [UInt16]
    if allPorts.count <= 16 {
        ports = allPorts
    } else {
        let strideN = max(1, allPorts.count / 12)
        var sample: [UInt16] = [lo]
        for p in stride(from: Int(lo) + strideN, through: Int(hi), by: strideN) {
            sample.append(UInt16(p))
        }
        if sample.last != hi { sample.append(hi) }
        ports = sample
    }
    let openPorts = await probeOpenTCPPorts(host: server.hostname, ports: ports, timeoutSeconds: 1.0)
    if let first = openPorts.first {
        return IPerfEndpoint(port: first, openPorts: openPorts)
    }
    // Aucun port ouvert — retourner nil pour permettre au fallback serveur
    // de tenter un autre hôte au lieu de perdre 30s en port scanning séquentiel.
    return nil
}

private func probeOpenTCPPorts(host: String, ports: [UInt16], timeoutSeconds: TimeInterval) async -> [UInt16] {
    await withTaskGroup(of: UInt16?.self) { group in
        for port in ports {
            group.addTask {
                await tcpPortIsOpen(host: host, port: port, timeoutSeconds: timeoutSeconds) ? port : nil
            }
        }
        var open: [UInt16] = []
        for await result in group {
            if let port = result { open.append(port) }
        }
        return open.sorted()
    }
}

private func tcpPortIsOpen(host: String, port: UInt16, timeoutSeconds: TimeInterval) async -> Bool {
    // Port 0 est le seul rawValue invalide : un port improbable = fermé, pas un crash.
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
    let gate = ConcurrencyGate()
    return await withCheckedContinuation { continuation in
        let queue = DispatchQueue(label: "fr.signalquest.speedtest.portprobe.\(port)")
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: iperfTCPParameters()
        )
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !gate.testAndSet() {
                    connection.cancel()
                    continuation.resume(returning: true)
                }
            case .failed:
                if !gate.testAndSet() {
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + timeoutSeconds) {
            if !gate.testAndSet() {
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
        connection.start(queue: queue)
    }
}

func iperfTCPParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = false
    tcp.connectionTimeout = 3
    let params = NWParameters(tls: nil, tcp: tcp)
    params.serviceClass = .responsiveData
    params.allowLocalEndpointReuse = true
    return params
}

/// Erreurs transport / serveur iPerf qu'on peut retenter (autre port / moins de flux).
/// Inclut explicitement ECONNRESET (54) — cause n°1 des UL vides sur POP publics.
func isRetryableIPerfTransportError(_ error: Error) -> Bool {
    if let e = error as? IPerf3Error { return e.isRetryable }
    if let nw = error as? NWError {
        switch nw {
        case .posix(let code):
            switch code {
            case .ECONNRESET, .ECONNREFUSED, .ETIMEDOUT, .ENETDOWN,
                 .EHOSTUNREACH, .ENETUNREACH, .EPIPE, .ECONNABORTED:
                return true
            default:
                break
            }
        case .dns:
            return true
        default:
            break
        }
    }
    let desc = (error as NSError).localizedDescription.lowercased()
    return desc.contains("reset")
        || desc.contains("refused")
        || desc.contains("timed out")
        || desc.contains("timeout")
        || desc.contains("network is down")
        || desc.contains("broken pipe")
        || desc.contains("aborted")
        || desc.contains("socket is not connected")
}

/// Port voisin public (hors classe service) — tests / helpers.
func iperfSiblingPort(preferred: UInt16, min portMin: UInt16, max portMax: UInt16) -> UInt16 {
    let lo = min(portMin, portMax)
    let hi = max(portMin, portMax)
    guard hi > lo else { return preferred }
    if preferred < hi { return preferred &+ 1 }
    return lo
}

private func connectNW(_ connection: NWConnection, queue: DispatchQueue, timeoutSeconds: TimeInterval) async throws {
    let gate = ConcurrencyGate()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !gate.testAndSet() { continuation.resume() }
            case .failed(let error):
                if !gate.testAndSet() { continuation.resume(throwing: error) }
            case .cancelled:
                if !gate.testAndSet() {
                    continuation.resume(throwing: IPerf3Error.cancelled)
                }
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + timeoutSeconds) {
            if !gate.testAndSet() {
                connection.cancel()
                continuation.resume(throwing: IPerf3Error.timeout)
            }
        }
        connection.start(queue: queue)
    }
}

private func sendNW(_ connection: NWConnection, _ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        })
    }
}

private func readExactNW(_ connection: NWConnection, count: Int, timeoutSeconds: TimeInterval = 30) async throws -> Data {
    var buffer = Data()
    buffer.reserveCapacity(count)
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while buffer.count < count {
        let remaining = count - buffer.count
        let remainingTime = deadline.timeIntervalSinceNow
        guard remainingTime > 0 else { throw IPerf3Error.timeout }
        let alreadyRead = buffer.count
        let chunk: Data = try await withCheckedThrowingContinuation { continuation in
            let gate = ConcurrencyGate()
            // Échéance ferme : un serveur qui accepte le TCP puis se tait ne
            // doit pas suspendre la boucle de contrôle indéfiniment. Le gate
            // absorbe la complétion tardive du receive.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + remainingTime) {
                if !gate.testAndSet() {
                    continuation.resume(throwing: IPerf3Error.timeout)
                }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                if !gate.testAndSet() {
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: IPerf3Error.connectionClosed(got: alreadyRead, expected: count))
                    } else {
                        continuation.resume(throwing: IPerf3Error.emptyRead)
                    }
                }
            }
        }
        buffer.append(chunk)
    }
    return buffer
}

class ProgressState: @unchecked Sendable {
    private let lock = NSLock()
    var lastBytes = 0
    var lastTime = 0.0

    func update(bytes: Int, time: Double) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let delta = max(0, bytes - lastBytes)
        lastBytes = bytes
        lastTime = time
        return delta
    }
}

class SafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int = 0

    func add(_ count: Int) {
        lock.lock()
        bytes += count
        lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    func snapshot() -> Int { value }
}

/// Pont de continuité omit → utile pour le `SpeedtestLiveSampler`.
/// Pendant l'omit le live sampler reçoit les octets bruts ; quand la phase
/// utile démarre, les octets repartent de zéro (post-omit). L'OmitBridge
/// ajoute l'offset omit aux valeurs utiles pour que le sampler voie un flux
/// **continu** et que l'aiguille ne saute pas à zéro puis remonte.
final class OmitBridge: @unchecked Sendable {
    struct Bridged: Sendable { let totalBytes: Int; let totalMs: Double }

    private let lock = NSLock()
    private var rawBytes: Int = 0
    private var rawMs: Double = 0

    /// À appeler depuis `onWarmup` avec les octets bruts cumulés.
    func capture(rawBytes: Int, rawMs: Double) {
        lock.lock()
        self.rawBytes = rawBytes
        self.rawMs = rawMs
        lock.unlock()
    }

    /// À appeler depuis `onProgress` : ajoute l'offset omit aux valeurs utiles.
    func bridged(usefulBytes: Int, usefulMs: Double) -> Bridged {
        lock.lock()
        let b = rawBytes
        let m = rawMs
        lock.unlock()
        return Bridged(totalBytes: b + usefulBytes, totalMs: m + usefulMs)
    }
}

enum IPerf3Error: Error, LocalizedError {
    case cancelled
    case timeout
    case emptyRead
    case connectionClosed(got: Int, expected: Int)
    case accessDenied
    case serverError
    case invalidJSON
    case incomplete
    case invalidPort
    case unexpectedState(Int8)

    var isRetryable: Bool {
        switch self {
        case .accessDenied, .timeout, .cancelled, .connectionClosed, .serverError:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Connexion iPerf3 annulée"
        case .timeout: return "Délai dépassé sur le serveur iPerf3"
        case .emptyRead: return "Lecture iPerf3 vide"
        case .connectionClosed(let got, let expected):
            return "Connexion iPerf3 fermée (\(got)/\(expected) octets)"
        case .accessDenied: return "Serveur iPerf3 occupé (ACCESS_DENIED)"
        case .serverError: return "Erreur serveur iPerf3"
        case .invalidJSON: return "Réponse iPerf3 JSON invalide"
        case .incomplete: return "Test iPerf3 incomplet"
        case .invalidPort: return "Port iPerf3 invalide"
        case .unexpectedState(let s): return "État iPerf3 inattendu (\(s))"
        }
    }
}

struct IPerf3Result: Sendable {
    /// Octets utiles après omit (côté client, ou serveur si disponible pour l'upload).
    let measuredBytes: Int
    let clientBytes: Int
    let serverBytes: Int?
    /// Durée utile (hors omit) en secondes.
    let measuredDuration: Double
    /// Durée murale totale (omit + mesure).
    let wallDuration: Double

    var averageMbps: Double {
        guard measuredBytes > 0, measuredDuration > 0 else { return 0 }
        let mbps = (Double(measuredBytes) * 8.0 / 1_000_000.0) / measuredDuration
        return mbps.isFinite && mbps >= 0 ? mbps : 0
    }

    /// Compat : ancien champ `duration`.
    var duration: Double { measuredDuration }
}

/// Somme les `bytes` de chaque entrée du tableau `streams` renvoyé à EXCHANGE_RESULTS.
func iperf3ExtractStreamBytes(from json: [String: Any]?) -> Int? {
    guard let json,
          let streams = json["streams"] as? [[String: Any]],
          !streams.isEmpty else {
        // Ancien format éventuel end.sum_*
        if let end = json?["end"] as? [String: Any] {
            for key in ["sum_received", "sum_sent", "sum"] {
                if let sum = end[key] as? [String: Any] {
                    if let b = sum["bytes"] as? Int { return b }
                    if let b = sum["bytes"] as? Double { return Int(b) }
                }
            }
        }
        return nil
    }
    var total = 0
    var any = false
    for stream in streams {
        if let b = stream["bytes"] as? Int {
            total += b; any = true
        } else if let b = stream["bytes"] as? Double {
            total += Int(b); any = true
        }
    }
    return any ? total : nil
}

// MARK: - Moteur Cloudflare (HTTPS anycast, couverture mondiale)

/// Endpoints du speedtest Cloudflare (`speed.cloudflare.com`) — mêmes
/// endpoints que le client officiel open-source `cloudflare/speedtest`.
/// DL, UL, ping et pings chargés touchent le MÊME edge anycast.
enum CloudflareSpeedtestConfig {
    static let host = "speed.cloudflare.com"
    /// Port sondé pour le ping (handshake TCP pur = 1 RTT, comme iPerf3).
    static let httpsPort: UInt16 = 443
    static let traceURL = URL(string: "https://speed.cloudflare.com/cdn-cgi/trace")!
    static let upURL = URL(string: "https://speed.cloudflare.com/__up")!
    /// Plafond dur de `__down` : l'edge répond **403** dès `bytes >= 1e8`
    /// (vérifié en ligne : 99 999 999 → 200, 100 000 000 → 403). Dépasser ce
    /// seuil fait échouer TOUTES les requêtes du download.
    static let downloadMaxBytesPerRequest = 100_000_000
    /// Octets par requête DL : sous le plafond avec marge, et assez gros pour
    /// qu'un lien rapide n'enchaîne pas les requêtes (la deadline borne le
    /// transfert, la boucle relance tant qu'il reste du temps).
    static let downloadBytesPerRequest = 90_000_000
    /// Corps UL partagé entre les flux (Data immuable → une seule allocation).
    static let uploadBytesPerRequest = 32_000_000
    /// Flux concurrents maximum vers l'edge (politesse anycast).
    static let maxStreams = 6
    static let maxUploadStreams = 4
    /// Avantage de latence exigé pour préférer Cloudflare en mode Auto —
    /// garde les serveurs opérateurs iPerf3 prioritaires en France.
    static let autoAdvantageMs: Double = 20

    static func downURL(bytes: Int) -> URL {
        var components = URLComponents(string: "https://speed.cloudflare.com/__down")!
        components.queryItems = [URLQueryItem(name: "bytes", value: String(max(0, bytes)))]
        return components.url!
    }
}

/// Parse le champ `colo=` (code IATA de l'edge) d'une réponse
/// `/cdn-cgi/trace` (lignes `clé=valeur`).
func cloudflareParseColo(fromTrace text: String) -> String? {
    for line in text.split(separator: "\n") {
        guard line.hasPrefix("colo=") else { continue }
        let value = line.dropFirst("colo=".count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value.uppercased()
    }
    return nil
}

/// Nom lisible d'un colo Cloudflare — villes FR/CA + voisines usuelles,
/// repli sur le code IATA brut sinon.
func cloudflareServerName(colo: String?) -> String {
    guard let colo, !colo.isEmpty else { return "Cloudflare · edge anycast" }
    let cities: [String: String] = [
        "CDG": "Paris", "ORY": "Paris", "MRS": "Marseille", "LYS": "Lyon",
        "BOD": "Bordeaux", "LIL": "Lille", "NCE": "Nice", "TLS": "Toulouse",
        "YUL": "Montréal", "YYZ": "Toronto", "YVR": "Vancouver", "YYC": "Calgary",
        "YOW": "Ottawa", "YHZ": "Halifax", "YWG": "Winnipeg", "YXE": "Saskatoon",
        "LHR": "Londres", "AMS": "Amsterdam", "FRA": "Francfort", "BRU": "Bruxelles",
        "GVA": "Genève", "ZRH": "Zurich", "MAD": "Madrid", "BCN": "Barcelone",
        "MXP": "Milan", "FCO": "Rome", "LIS": "Lisbonne", "DUB": "Dublin",
        "LUX": "Luxembourg", "EWR": "Newark", "JFK": "New York", "IAD": "Washington",
        "LAX": "Los Angeles", "BOM": "Mumbai", "DXB": "Dubaï", "SIN": "Singapour",
        "NRT": "Tokyo", "HND": "Tokyo", "GRU": "São Paulo", "SYD": "Sydney",
    ]
    let code = colo.uppercased()
    if let city = cities[code] {
        return "Cloudflare · \(city) (\(code))"
    }
    return "Cloudflare · \(code)"
}

/// Sac de connexions annulable : `NWConnection` ignore `Task.isCancelled`,
/// donc l'annulation coopérative passe par la coupure des connexions — les
/// receive/send en vol échouent et la boucle de contrôle se déroule en erreur
/// au lieu de continuer à transférer (ou de fuiter) après un « Arrêter ».
final class IPerf3ConnectionBag: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ connection: NWConnection) {
        lock.lock()
        let wasCancelled = cancelled
        if !wasCancelled { connections.append(connection) }
        lock.unlock()
        if wasCancelled { connection.cancel() }
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        let toCancel = connections
        connections.removeAll()
        lock.unlock()
        for connection in toCancel { connection.cancel() }
    }
}

actor IPerf3Runner {
    let hostname: String
    let port: UInt16
    let streams: Int
    let durationSeconds: Int
    let omitSeconds: Int
    let isDownload: Bool
    let onProgress: (@Sendable (_ bytesTransferred: Int, _ elapsedSeconds: Double) -> Void)?
    /// Callback émis toutes les ~150 ms PENDANT la phase omit (warm-up TCP)
    /// avec les octets bruts cumulés et le temps mural. Permet au cadran de
    /// montrer le débit dès le début du transfert sans attendre la fin de l'omit.
    let onWarmup: (@Sendable (_ rawTotalBytes: Int, _ wallSeconds: Double) -> Void)?

    private var activeSenders: [StreamSender] = []
    private var activeReceivers: [StreamReceiver] = []

    init(
        hostname: String,
        port: UInt16,
        streams: Int,
        durationSeconds: Int,
        omitSeconds: Int = SpeedtestEngineConfig.iperf3OmitSeconds,
        isDownload: Bool,
        onProgress: (@Sendable (_ bytesTransferred: Int, _ elapsedSeconds: Double) -> Void)? = nil,
        onWarmup: (@Sendable (_ rawTotalBytes: Int, _ wallSeconds: Double) -> Void)? = nil
    ) {
        self.hostname = hostname
        self.port = port
        self.streams = max(1, streams)
        self.durationSeconds = max(1, durationSeconds)
        self.omitSeconds = max(0, omitSeconds)
        self.isDownload = isDownload
        self.onProgress = onProgress
        self.onWarmup = onWarmup
    }

    private func makeCookie() -> Data {
        let chars = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var data = Data(capacity: 37)
        for _ in 0..<36 {
            data.append(chars[Int.random(in: 0..<chars.count)])
        }
        data.append(0)
        return data
    }

    func run() async throws -> IPerf3Result {
        guard let portEndpoint = NWEndpoint.Port(rawValue: port) else {
            throw IPerf3Error.invalidPort
        }
        let bag = IPerf3ConnectionBag()
        let isTestRunning = AtomicBool(false)
        return try await withTaskCancellationHandler {
            try await runInternal(portEndpoint: portEndpoint, bag: bag, isTestRunning: isTestRunning)
        } onCancel: {
            // Stoppe l'ender-task et coupe toutes les connexions : les
            // receive/send en vol échouent → la boucle de contrôle se déroule.
            isTestRunning.value = false
            bag.cancelAll()
        }
    }

    private func runInternal(
        portEndpoint: NWEndpoint.Port,
        bag: IPerf3ConnectionBag,
        isTestRunning: AtomicBool
    ) async throws -> IPerf3Result {
        let host = NWEndpoint.Host(hostname)
        let queue = DispatchQueue(label: "fr.signalquest.iperf.client.\(port)", qos: .userInitiated)
        let params = iperfTCPParameters()

        let controlConnection = NWConnection(host: host, port: portEndpoint, using: params)
        bag.register(controlConnection)
        try await connectNW(controlConnection, queue: queue, timeoutSeconds: 5)
        defer { controlConnection.cancel() }

        let cookieData = makeCookie()
        let cookieString = String(data: cookieData.prefix(36), encoding: .ascii) ?? ""
        try await sendNW(controlConnection, cookieData)

        var dataConnections: [NWConnection] = []
        defer {
            for conn in dataConnections { conn.cancel() }
        }

        let totalBytesCounter = SafeCounter()
        let omitBytesCounter = SafeCounter()
        var startTestTime: Date?
        var transferEndTime: Date?
        let serverEnded = AtomicBool(false)
        var finishedResult: IPerf3Result?
        var enderStarted = false

        while finishedResult == nil {
            let raw = try await readExactNW(controlConnection, count: 1, timeoutSeconds: 60)
            let signed = Int8(bitPattern: raw[0])

            switch signed {
            case 9: // PARAM_EXCHANGE
                var paramsJSON: [String: Any] = [
                    "client_version": "3.17.1",
                    "omit": omitSeconds,
                    "parallel": streams,
                    "pacing_timer": 1000,
                    "time": durationSeconds,
                    "num": 0,
                    "blockcount": 0,
                    "tcp": true,
                    "len": SpeedtestEngineConfig.iperf3BlockSize,
                    "cookie": cookieString
                ]
                if isDownload {
                    paramsJSON["reverse"] = true
                }
                try await sendJSON(controlConnection, paramsJSON)

            case 10: // CREATE_STREAMS
                for _ in 0..<streams {
                    let dataConn = NWConnection(host: host, port: portEndpoint, using: params)
                    bag.register(dataConn)
                    try await connectNW(dataConn, queue: queue, timeoutSeconds: 5)
                    dataConnections.append(dataConn)
                    try await sendNW(dataConn, cookieData)
                }

            case 1: // TEST_START
                break

            case 2: // TEST_RUNNING
                guard !enderStarted else { break }
                enderStarted = true
                isTestRunning.value = true
                startTestTime = Date()

                for conn in dataConnections {
                    if isDownload {
                        let receiver = StreamReceiver(
                            connection: conn,
                            totalBytes: totalBytesCounter,
                            isRunning: isTestRunning
                        )
                        activeReceivers.append(receiver)
                        receiver.start()
                    } else {
                        let payload = Data(repeating: 0x5a, count: SpeedtestEngineConfig.iperf3BlockSize)
                        let sender = StreamSender(
                            connection: conn,
                            payload: payload,
                            totalBytes: totalBytesCounter,
                            isRunning: isTestRunning
                        )
                        activeSenders.append(sender)
                        sender.start()
                    }
                }

                // Client always ends the test after omit + duration (both directions).
                let progressHandler = onProgress
                let warmupHandler = onWarmup
                let omitCap = omitSeconds
                let measureCap = durationSeconds
                Task {
                    let omit = Double(omitCap)
                    let measure = Double(measureCap)
                    let start = Date()
                    // Phase omit — feedback live pour l'aiguille du cadran.
                    while isTestRunning.value {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        let wall = Date().timeIntervalSince(start)
                        if wall >= omit { break }
                        warmupHandler?(totalBytesCounter.value, wall)
                    }
                    let bytesAtOmit = totalBytesCounter.value
                    if omitBytesCounter.value == 0, bytesAtOmit > 0 {
                        omitBytesCounter.add(bytesAtOmit)
                    }
                    // Phase de mesure utile.
                    while isTestRunning.value {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        let wall = Date().timeIntervalSince(start)
                        let usefulElapsed = max(0, wall - omit)
                        let usefulBytes = max(0, totalBytesCounter.value - omitBytesCounter.value)
                        progressHandler?(usefulBytes, usefulElapsed)
                        if wall >= omit + measure { break }
                    }
                    isTestRunning.value = false
                    // Inutile (et parfois RST) si le serveur a déjà clos le
                    // test, ou si le run a été annulé (connexions coupées).
                    if !serverEnded.value, !bag.isCancelled {
                        try? await sendCommand(controlConnection, 4) // TEST_END
                    }
                }

            case 4: // TEST_END (server-initiated)
                serverEnded.value = true
                isTestRunning.value = false
                if transferEndTime == nil { transferEndTime = Date() }

            case 13: // EXCHANGE_RESULTS
                serverEnded.value = true
                isTestRunning.value = false
                if transferEndTime == nil { transferEndTime = Date() }
                for conn in dataConnections { conn.cancel() }
                dataConnections.removeAll()
                activeSenders.removeAll()
                activeReceivers.removeAll()

                let wall = (transferEndTime ?? Date()).timeIntervalSince(startTestTime ?? Date())
                let omit = Double(omitSeconds)
                let measuredDuration = max(0.001, wall - omit)
                let clientTotal = totalBytesCounter.value
                let omitBytes = omitBytesCounter.value > 0
                    ? omitBytesCounter.value
                    : 0
                let clientUseful = max(0, clientTotal - omitBytes)

                // Un seul stream id=1 avec le total : accepté par le serveur
                // (évite le quirk d'IDs 1,3,4… et l'erreur « invalid id »).
                let clientResults: [String: Any] = [
                    "cpu_util_total": 0.0,
                    "cpu_util_user": 0.0,
                    "cpu_util_system": 0.0,
                    "sender_has_retransmits": isDownload ? -1 : 0,
                    "congestion_used": "cubic",
                    "streams": [[
                        "id": 1,
                        "bytes": clientUseful,
                        "retransmits": isDownload ? -1 : 0,
                        "jitter": 0.0,
                        "errors": 0,
                        "packets": 0,
                        "start_time": 0.0,
                        "end_time": measuredDuration
                    ]]
                ]
                try await sendJSON(controlConnection, clientResults)

                let serverResults = try? await readJSON(controlConnection)
                let serverBytes = iperf3ExtractStreamBytes(from: serverResults)

                // Download : octets reçus client = vérité terrain.
                // Upload : octets reçus serveur si dispo (évite le buffer-bloat client).
                let measuredBytes: Int
                if isDownload {
                    measuredBytes = clientUseful > 0 ? clientUseful : (serverBytes ?? 0)
                } else if let serverBytes, serverBytes > 0 {
                    measuredBytes = serverBytes
                } else {
                    measuredBytes = clientUseful
                }

                finishedResult = IPerf3Result(
                    measuredBytes: measuredBytes,
                    clientBytes: clientUseful,
                    serverBytes: serverBytes,
                    measuredDuration: measuredDuration,
                    wallDuration: max(measuredDuration, wall)
                )

            case 14: // DISPLAY_RESULTS
                try? await sendCommand(controlConnection, 16) // IPERF_DONE
                if finishedResult == nil {
                    let wall = (transferEndTime ?? Date()).timeIntervalSince(startTestTime ?? Date())
                    let measuredDuration = max(0.001, wall - Double(omitSeconds))
                    let useful = max(0, totalBytesCounter.value - omitBytesCounter.value)
                    finishedResult = IPerf3Result(
                        measuredBytes: useful,
                        clientBytes: useful,
                        serverBytes: nil,
                        measuredDuration: measuredDuration,
                        wallDuration: max(measuredDuration, wall)
                    )
                }

            case -1: // ACCESS_DENIED (busy)
                throw IPerf3Error.accessDenied

            case -2: // SERVER_ERROR
                throw IPerf3Error.serverError

            case 11: // SERVER_TERMINATE
                throw IPerf3Error.serverError

            default:
                throw IPerf3Error.unexpectedState(signed)
            }
        }

        guard let result = finishedResult, result.measuredBytes > 0 else {
            throw IPerf3Error.incomplete
        }
        return result
    }

    private func sendCommand(_ connection: NWConnection, _ cmd: UInt8) async throws {
        try await sendNW(connection, Data([cmd]))
    }

    private func sendJSON(_ connection: NWConnection, _ dictionary: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [])
        var length = UInt32(data.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)
        // Envoyer en un seul write (évite une race rare sur le framing).
        try await sendNW(connection, packet)
    }

    private func readJSON(_ connection: NWConnection) async throws -> [String: Any] {
        let lengthData = try await readExactNW(connection, count: 4, timeoutSeconds: 15)
        let length = UInt32(bigEndian: lengthData.withUnsafeBytes { $0.load(as: UInt32.self) })
        guard length > 0, length < 16_000_000 else { throw IPerf3Error.invalidJSON }
        let jsonData = try await readExactNW(connection, count: Int(length), timeoutSeconds: 15)
        guard let json = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
            throw IPerf3Error.invalidJSON
        }
        return json
    }
}

class StreamSender: @unchecked Sendable {
    private let connection: NWConnection
    private let payload: Data
    /// Fenêtre d'envois concurrents par flux. 8 × 128 KiB ≈ 1 Mo en vol —
    /// assez pour saturer un lien asymétrique sans provoquer de RST sur les
    /// POP publics (l'ancien 12 avec 16 flux tuait l'UL).
    private let limit = 8
    private let outstanding = SafeCounter()
    private let totalBytes: SafeCounter
    private let isRunning: AtomicBool

    init(connection: NWConnection, payload: Data, totalBytes: SafeCounter, isRunning: AtomicBool) {
        self.connection = connection
        self.payload = payload
        self.totalBytes = totalBytes
        self.isRunning = isRunning
    }

    func start() { sendNext() }

    private func sendNext() {
        guard isRunning.value else { return }
        while outstanding.value < limit && isRunning.value {
            outstanding.add(1)
            let size = payload.count
            connection.send(content: payload, completion: .contentProcessed({ [weak self] error in
                guard let self else { return }
                self.outstanding.add(-1)
                // Erreur (RST) : on arrête ce flux mais on ne propage pas —
                // le runner contrôle la fin via TEST_END / EXCHANGE_RESULTS.
                if error == nil, self.isRunning.value {
                    self.totalBytes.add(size)
                    self.sendNext()
                }
            }))
        }
    }
}

class StreamReceiver: @unchecked Sendable {
    private let connection: NWConnection
    private let totalBytes: SafeCounter
    private let isRunning: AtomicBool

    init(connection: NWConnection, totalBytes: SafeCounter, isRunning: AtomicBool) {
        self.connection = connection
        self.totalBytes = totalBytes
        self.isRunning = isRunning
    }

    func start() { receiveNext() }

    private func receiveNext() {
        guard isRunning.value else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.totalBytes.add(data.count)
            }
            if error == nil && !isComplete && self.isRunning.value {
                self.receiveNext()
            }
        }
    }
}

// MARK: - Helpers

private func boundedMbps(bytes: Int, durationMs: Double) -> Double {
    guard bytes > 0, durationMs > 0 else { return 0 }
    let mbps = (Double(bytes) * 8.0 / 1_000_000.0) / (durationMs / 1_000)
    return mbps.isFinite && mbps >= 0 ? mbps : 0
}

func speedtestPingMeasuredSampleTarget(attemptBudget: Int, warmupCount: Int) -> Int {
    let budget = max(0, attemptBudget)
    guard budget > 0 else { return 0 }
    let warmups = min(max(0, warmupCount), max(0, budget - 1))
    return max(0, budget - warmups)
}

private struct SpeedtestRateLimitedError: Error {}

private struct SpeedtestUploadTaskResult: Sendable {
    let data: Data
    let httpStatusCode: Int?
    let receivedResponse: Bool
    let sentBytes: Int
}

private final class SpeedtestURLSessionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

private final class SpeedtestDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let deadline: Date
    private let onBytes: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var responseError: Error?
    private var receivedBytes = 0

    init(deadline: Date, onBytes: @escaping @Sendable (Int) -> Void) {
        self.deadline = deadline
        self.onBytes = onBytes
    }

    func run(task: URLSessionDataTask) async throws {
        let taskBox = SpeedtestURLSessionTaskBox()
        let timeoutTask = Task { [deadline, taskBox] in
            let seconds = max(0, deadline.timeIntervalSinceNow)
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            taskBox.cancel()
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                taskBox.set(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        guard (200..<400).contains(http.statusCode) else {
            lock.lock()
            responseError = http.statusCode == 429
                ? SpeedtestRateLimitedError()
                : APIError.http(
                    status: http.statusCode,
                    code: nil,
                    message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                    requestId: nil,
                    retryAfter: nil
                )
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let count = data.count
        guard count > 0, Date() <= deadline else { return }
        lock.lock()
        receivedBytes += count
        lock.unlock()
        onBytes(count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let storedError: Error?
        let byteCount: Int
        lock.lock()
        storedError = responseError
        byteCount = receivedBytes
        lock.unlock()

        if let storedError {
            finish(.failure(storedError))
            return
        }
        if let error {
            if isCancellation(error), Date() >= deadline, byteCount > 0 {
                finish(.success(()))
            } else {
                finish(.failure(error))
            }
            return
        }
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private final class SpeedtestUploadDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let deadline: Date
    private let onBytesSent: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SpeedtestUploadTaskResult, Error>?
    private var responseData = Data()
    private var httpStatusCode: Int?
    private var receivedResponse = false
    private var sentBytes = 0

    init(deadline: Date, onBytesSent: @escaping @Sendable (Int) -> Void) {
        self.deadline = deadline
        self.onBytesSent = onBytesSent
    }

    func run(task: URLSessionUploadTask) async throws -> SpeedtestUploadTaskResult {
        let taskBox = SpeedtestURLSessionTaskBox()
        let timeoutTask = Task { [deadline, taskBox] in
            let seconds = max(0, deadline.timeIntervalSinceNow)
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            taskBox.cancel()
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SpeedtestUploadTaskResult, Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                taskBox.set(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        receivedResponse = true
        httpStatusCode = (response as? HTTPURLResponse)?.statusCode
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        responseData.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let count = max(0, Int(bytesSent))
        guard count > 0 else { return }
        lock.lock()
        sentBytes += count
        lock.unlock()
        if Date() <= deadline {
            onBytesSent(count)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = snapshotResult()
        if let error, !(isCancellation(error) && Date() >= deadline && result.sentBytes > 0) {
            finish(.failure(error))
            return
        }
        finish(.success(result))
    }

    private func snapshotResult() -> SpeedtestUploadTaskResult {
        lock.lock()
        let result = SpeedtestUploadTaskResult(
            data: responseData,
            httpStatusCode: httpStatusCode,
            receivedResponse: receivedResponse,
            sentBytes: sentBytes
        )
        lock.unlock()
        return result
    }

    private func finish(_ result: Result<SpeedtestUploadTaskResult, Error>) {
        let continuation: CheckedContinuation<SpeedtestUploadTaskResult, Error>?
        lock.lock()
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        switch result {
        case .success(let uploadResult):
            continuation.resume(returning: uploadResult)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private func isCancellation(_ error: Error) -> Bool {
    (error as? CancellationError) != nil || (error as? URLError)?.code == .cancelled
}

/// Collected (start, end, bytes) samples used to derive p90 / p95 / peak via
/// 1-second windows post-test, mirroring `measuredThroughputWindows` on
/// Android.
///
/// Lock-based (pas actor) : les callbacks iPerf poussaient `append` via
/// `Task { await box.append }` sans attendre, ce qui faisait perdre des
/// samples au moment de `publicStats` → séries vides / graphes plats faux.
final class SpeedtestSamplesBox: @unchecked Sendable {
    struct Sample: Sendable { let startMs: Double; let endMs: Double; let bytes: Int }
    private let lock = NSLock()
    private var samples: [Sample] = []

    func append(start: Double, end: Double, bytes: Int) {
        guard bytes > 0, end > start else { return }
        lock.lock()
        samples.append(Sample(startMs: start, endMs: end, bytes: bytes))
        lock.unlock()
    }

    struct PublicStats: Sendable {
        let p90: Double?
        let p95: Double?
        let peak: Double
        let windowCount: Int
        let seriesMbps: [Double]
    }

    func publicStats(windowMs: Double, graceMs: Double, endMs: Double) -> PublicStats {
        lock.lock()
        let snapshot = samples
        lock.unlock()
        guard endMs > graceMs else { return PublicStats(p90: nil, p95: nil, peak: 0, windowCount: 0, seriesMbps: []) }
        var windowSpeeds: [Double] = []
        var windowIndex = 0
        while true {
            let windowStart = graceMs + Double(windowIndex) * windowMs
            let windowEnd = windowStart + windowMs
            if windowStart >= endMs { break }
            var bytesInWindow = 0
            for sample in snapshot {
                let overlapStart = max(sample.startMs, windowStart)
                let overlapEnd = min(sample.endMs, windowEnd)
                guard overlapEnd > overlapStart else { continue }
                let sampleSpan = max(1, sample.endMs - sample.startMs)
                let ratio = (overlapEnd - overlapStart) / sampleSpan
                bytesInWindow += Int(Double(sample.bytes) * ratio)
            }
            if bytesInWindow > 0 {
                let mbps = boundedMbps(bytes: bytesInWindow, durationMs: windowMs)
                if mbps > 0 && mbps < 10_000 {
                    windowSpeeds.append(mbps)
                }
            }
            windowIndex += 1
        }
        guard !windowSpeeds.isEmpty else {
            return PublicStats(p90: nil, p95: nil, peak: 0, windowCount: 0, seriesMbps: [])
        }
        let sorted = windowSpeeds.sorted()
        func percentile(_ p: Double) -> Double {
            let clamped = min(max(p, 0), 1)
            let index = Int((Double(sorted.count - 1) * clamped).rounded())
            return sorted[index]
        }
        return PublicStats(
            p90: percentile(0.9),
            p95: percentile(0.95),
            peak: sorted.max() ?? 0,
            windowCount: sorted.count,
            seriesMbps: windowSpeeds
        )
    }
}

/// Émetteur du débit live pour l'aiguille du cadran : débit INSTANTANÉ calculé
/// sur une fenêtre GLISSANTE (~1 s) de relevés cumulés, lissé par un léger EMA
/// pour éviter le tremblement. L'aiguille suit ainsi le réseau en temps réel —
/// l'ancienne version affichait la moyenne cumulée lissée, qui traînait
/// systématiquement derrière le débit courant. La valeur FINALE affichée reste
/// la moyenne cumulée post-grace, calculée en fin de phase (inchangée).
final class SpeedtestLiveSampler: @unchecked Sendable {
    private struct Point {
        let elapsedMs: Double
        let totalBytes: Int
    }

    private let windowMs: Double
    private let smoothing: Double
    private var points: [Point] = []
    private var emaMbps: Double = 0
    /// Dernier débit instantané NON lissé (fenêtre glissante brute) — sert
    /// notamment à la décision de grace adaptative.
    private(set) var lastInstantMbps: Double = 0

    init(windowMs: Double = 1_000, smoothing: Double = 0.35) {
        self.windowMs = max(1, windowMs)
        self.smoothing = min(1, max(0.01, smoothing))
    }

    /// À appeler à chaque tick avec le TOTAL cumulé d'octets : renvoie le débit
    /// instantané lissé (fenêtre glissante), indépendant de la grace — pendant
    /// le warm-up l'aiguille montre déjà le débit réel, seule la moyenne
    /// l'exclut.
    func observe(totalBytes: Int, elapsedMs: Double) -> Double {
        points.append(Point(elapsedMs: elapsedMs, totalBytes: totalBytes))
        // Conserve un point au-delà de la fenêtre pour que le delta couvre
        // toujours ~windowMs une fois la fenêtre remplie.
        while points.count > 2, points[1].elapsedMs <= elapsedMs - windowMs {
            points.removeFirst()
        }
        guard points.count >= 2, let first = points.first else { return emaMbps }
        let spanMs = elapsedMs - first.elapsedMs
        guard spanMs > 0 else { return emaMbps }
        let instant = boundedMbps(bytes: max(0, totalBytes - first.totalBytes), durationMs: spanMs)
        lastInstantMbps = instant
        if emaMbps == 0 {
            emaMbps = instant
        } else {
            emaMbps = (smoothing * instant) + ((1 - smoothing) * emaMbps)
        }
        return emaMbps
    }
}

// MARK: - Persistance des sauvegardes speedtest (SwiftData iOS 17+ / repli JSON iOS 16)

/// Sauvegarde speedtest en attente d'envoi (persistée AVANT le POST, renvoyée plus tard).
/// Au niveau fichier (au lieu d'imbriquée dans SpeedtestService) pour être référencée par
/// le protocole de store et l'entité SwiftData.
struct PendingSpeedtestSave: Codable, Equatable, Sendable {
    let id: String
    let result: SpeedtestRunResult
    let streams: Int
    let deviceModel: String
    let createdAt: Date
    /// Choix de publication sur la carte communautaire (opt-in). Optionnel pour rester
    /// compatible avec les sauvegardes sérialisées avant l'ajout du consentement
    /// (`nil` = non publié).
    let isVisibleOnMap: Bool?
    /// Opt-in explicite. Optionnel pour décoder les anciennes files locales.
    let shareExactLocation: Bool?
    /// Généré et persisté AVANT le POST : le même secret survit à un commit serveur dont
    /// la réponse aurait été perdue.
    let guestDeleteToken: String?
    /// Id LOCAL de la session Drive Test en cours (UUID) si ce speedtest a été lancé
    /// pendant un drive → rattachement serveur. Optionnel pour décoder les files locales
    /// sérialisées avant cet ajout (`nil` = speedtest hors drive).
    let driveSessionId: String?
}

/// File des sauvegardes speedtest en attente, abstraite pour offrir deux implémentations
/// derrière la MÊME API asynchrone :
/// - **iOS 17+** : `SwiftDataSpeedtestPendingStore` (vraie base embarquée SwiftData) ;
/// - **iOS 16**  : repli `DiskCacheSpeedtestPendingStore` (JSON durable, Application Support).
protocol SpeedtestPendingStoring: Sendable {
    func loadAll() async -> [PendingSpeedtestSave]
    func replaceAll(_ values: [PendingSpeedtestSave]) async throws
}

/// Fabrique : SwiftData si iOS 17+ ET l'init réussit (migration depuis la file durable),
/// sinon repli sur la file durable JSON (`DiskCache`).
enum SpeedtestPendingStoreFactory {
    static func make(durableCache: DiskCache, key: String) -> SpeedtestPendingStoring {
        if #available(iOS 17, *) {
            if let store = SwiftDataSpeedtestPendingStore(legacyCache: durableCache, legacyKey: key) {
                return store
            }
        }
        return DiskCacheSpeedtestPendingStore(cache: durableCache, key: key)
    }
}

/// Repli iOS 16 : lit/écrit tout le tableau dans la file durable (`DiskCache` en
/// Application Support). Comportement identique à l'accès direct précédent.
struct DiskCacheSpeedtestPendingStore: SpeedtestPendingStoring {
    let cache: DiskCache
    let key: String

    func loadAll() async -> [PendingSpeedtestSave] {
        (try? await cache.read([PendingSpeedtestSave].self, for: key)) ?? []
    }

    func replaceAll(_ values: [PendingSpeedtestSave]) async throws {
        if values.isEmpty {
            await cache.remove(key)
        } else {
            try await cache.write(values, for: key)
        }
    }
}

/// Entité SwiftData d'une sauvegarde en attente : la sauvegarde est stockée telle quelle
/// en `payload` JSON (toujours lue/écrite d'un bloc) ; `createdAtMs` sert au tri.
@available(iOS 17, *)
@Model
final class SpeedtestPendingEntity {
    @Attribute(.unique) var saveId: String
    var createdAtMs: Int
    var payload: Data

    init(saveId: String, createdAtMs: Int, payload: Data) {
        self.saveId = saveId
        self.createdAtMs = createdAtMs
        self.payload = payload
    }
}

/// Store SwiftData des sauvegardes en attente. L'API du protocole étant ASYNCHRONE, on
/// l'implémente en `actor` : SwiftData n'est utilisé que sous isolation d'acteur (un seul
/// `ModelContext`, jamais partagé entre threads), sans verrou manuel.
/// ⚠️ À compiler/tester dans Xcode (indisponible sous Linux).
@available(iOS 17, *)
actor SwiftDataSpeedtestPendingStore: SpeedtestPendingStoring {
    private let container: ModelContainer
    private let context: ModelContext
    private let legacyCache: DiskCache?
    private let legacyKey: String
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest

    /// `init?` : si le `ModelContainer` ne peut pas être créé, la fabrique retombe sur JSON.
    init?(storeURL: URL? = nil, legacyCache: DiskCache? = nil, legacyKey: String) {
        self.legacyCache = legacyCache
        self.legacyKey = legacyKey
        let url = storeURL ?? Self.defaultStoreURL()
        guard let container = try? ModelContainer(
            for: SpeedtestPendingEntity.self,
            configurations: ModelConfiguration(url: url)
        ) else { return nil }
        self.container = container
        self.context = ModelContext(container)
    }

    func loadAll() async -> [PendingSpeedtestSave] {
        await importLegacyIfPresent()
        var descriptor = FetchDescriptor<SpeedtestPendingEntity>()
        descriptor.sortBy = [SortDescriptor(\SpeedtestPendingEntity.createdAtMs, order: .forward)]
        let entities = (try? context.fetch(descriptor)) ?? []
        return entities.compactMap { try? decoder.decode(PendingSpeedtestSave.self, from: $0.payload) }
    }

    func replaceAll(_ values: [PendingSpeedtestSave]) async throws {
        // Delete-all + insert-all : fidèle au contrat lecture-tout / écriture-tout du
        // service (file d'attente petite). L'import legacy est fait par loadAll, qui
        // précède toujours une écriture (read-modify-write), donc rien n'est perdu.
        for entity in (try? context.fetch(FetchDescriptor<SpeedtestPendingEntity>())) ?? [] {
            context.delete(entity)
        }
        for save in values {
            let payload = try encoder.encode(save)
            context.insert(SpeedtestPendingEntity(
                saveId: save.id,
                createdAtMs: Int(save.createdAt.timeIntervalSince1970 * 1_000),
                payload: payload
            ))
        }
        try context.save()
    }

    /// Import unique depuis la file durable JSON (`DiskCache`) au premier `loadAll`, puis
    /// purge de cette file. Idempotent (unicité `saveId`) ; une fois la file legacy vidée,
    /// cette méthode devient un no-op. La logique d'insertion est synchrone (sans point de
    /// suspension) → pas de conflit d'unicité en cas de réentrance d'acteur.
    private func importLegacyIfPresent() async {
        guard let legacyCache else { return }
        let legacy = (try? await legacyCache.read([PendingSpeedtestSave].self, for: legacyKey)) ?? []
        guard !legacy.isEmpty else { return }
        let existing = Set(((try? context.fetch(FetchDescriptor<SpeedtestPendingEntity>())) ?? []).map(\.saveId))
        var inserted = false
        for save in legacy where !existing.contains(save.id) {
            guard let payload = try? encoder.encode(save) else { continue }
            context.insert(SpeedtestPendingEntity(
                saveId: save.id,
                createdAtMs: Int(save.createdAt.timeIntervalSince1970 * 1_000),
                payload: payload
            ))
            inserted = true
        }
        if inserted { try? context.save() }
        await legacyCache.remove(legacyKey)
    }

    private static func defaultStoreURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = appSupport.appendingPathComponent("SignalQuest", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SpeedtestPending.store", isDirectory: false)
    }
}
