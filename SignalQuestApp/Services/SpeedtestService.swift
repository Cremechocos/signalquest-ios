import Foundation
import CoreLocation
import Network
import UIKit
import WidgetKit
import Security

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
        serverName: String? = nil
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
    /// Bytes received in the first 2 s are discarded — TCP slow-start would
    /// otherwise drag the average down on fast links.
    static let downloadGraceTimeMs: Double = 2_000
    static let uploadGraceTimeMs: Double = 2_000
    /// Grace ÉTENDUE, appliquée quand le débit instantané est encore en rampe
    /// (ou dépasse `fastLinkThresholdMbps`) à l'approche de la frontière des
    /// 2 s : sur les liens rapides le slow-start TCP dure plus longtemps que le
    /// warm-up de base et écraserait la moyenne. Reste dans la fourchette
    /// 3-4 s que le serveur accepte via `warmupMs` au finalize.
    static let extendedGraceTimeMs: Double = 3_500
    /// Au-delà de ce débit instantané, 2 s de warm-up ne suffisent jamais.
    static let fastLinkThresholdMbps: Double = 200
    /// Croissance relative (+15 %) du débit instantané en fin de warm-up qui
    /// signe un lien encore en slow-start.
    static let risingGraceRatio: Double = 1.15
    /// Recul (ms) utilisé pour comparer débit récent vs antérieur lors de la
    /// décision de grace adaptative.
    static let graceComparisonLookbackMs: Double = 600
    /// Window length used to compute Mbps samples post-grace. Android uses
    /// 1000 ms and reads the same value for the public p90/p95/peak stats.
    static let publicPeakWindowMs: Double = 1_000
    /// Live-progress emission interval. We push a smoothed value to the UI at
    /// this cadence so the gauge climbs visibly instead of staying at 0.
    static let sampleIntervalMs: Double = 150
    /// Per-stream stagger to avoid thundering-herd on the first request and
    /// match Android's behaviour exactly.
    static let streamStaggerMs: Double = 200
    /// If the global byte counter stops increasing for this long after grace,
    /// the engine aborts the attempt with a stall error.
    static let downloadStallTimeoutMs: Double = 2_500
    /// Hard cap on parallel streams.
    static let hardMaxStreams: Int = 16
    /// Android caps upload fan-out lower than download to avoid saturating
    /// client memory while several large POSTs are in flight.
    static let hardMaxUploadStreams: Int = 12
    /// HTTP request timeout for a single download chunk.
    static let chunkTimeoutSeconds: TimeInterval = 25
    /// Upload chunks can legitimately take longer on asymmetric links.
    static let uploadTimeoutSeconds: TimeInterval = 90
    static let minUploadBytesPerRequest: Int = 256 * 1_024
    static let maxUploadBytesPerRequest: Int = 32 * 1_024 * 1_024
    /// PingProbe: maximum 8 total attempts. We use one warmup when possible,
    /// then up to 7 measured samples at a short cadence so the phase feels instant.
    static let pingAttemptBudget: Int = 8
    static let pingWarmupCount: Int = 1
    static let pingIntervalMs: Double = 300
    static let pingTimeoutSeconds: TimeInterval = 1.2
}

private enum SpeedtestEngineError: LocalizedError {
    case downloadProducedNoBytes
    case uploadUnavailable
    case uploadProducedNoBytes
    case uploadHandshakeFailed
    case pingFailed

    var errorDescription: String? {
        switch self {
        case .downloadProducedNoBytes:
            return "Le téléchargement n'a reçu aucun octet mesurable. Le speedtest a été annulé pour éviter un résultat faux."
        case .uploadUnavailable:
            return "Le serveur speedtest n'a pas fourni d'URL d'upload complète. Le test a été annulé."
        case .uploadProducedNoBytes:
            return "L'upload n'a confirmé aucun octet côté serveur. Le speedtest a été annulé pour éviter un résultat faux."
        case .uploadHandshakeFailed:
            return "Le serveur speedtest n'a pas accepté l'initialisation de l'upload."
        case .pingFailed:
            return "Impossible de mesurer une latence réseau fiable."
        }
    }
}

// MARK: - Service implementation

final class SpeedtestService: SpeedtestServicing, @unchecked Sendable {
    private let api: APIClient
    private let markets: MarketRegistryServicing
    private let networkOperator: NetworkOperatorServicing
    private let session: URLSession
    private let historyCache: DiskCache
    private let pendingCache: DiskCache
    private let guestReceiptStore: GuestSpeedtestReceiptStore
    private let tcpProbe: SpeedtestTCPProbing
    private let pendingSaveKey = "pending-speedtest-saves"

    init(
        api: APIClient,
        markets: MarketRegistryServicing? = nil,
        networkOperator: NetworkOperatorServicing? = nil,
        session: URLSession? = nil,
        historyCache: DiskCache = DiskCache(folderName: "SignalQuestSpeedtestHistory"),
        pendingCache: DiskCache = DiskCache(folderName: "SignalQuestSpeedtestPending"),
        guestReceiptStore: GuestSpeedtestReceiptStore = GuestSpeedtestReceiptStore(),
        tcpProbe: SpeedtestTCPProbing = NetworkSpeedtestTCPProbe()
    ) {
        self.api = api
        self.markets = markets ?? MarketRegistryService(api: api)
        self.networkOperator = networkOperator ?? NetworkOperatorService(api: api)
        // Use ephemeral config to bypass system caching of the download payload.
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 32
        config.timeoutIntervalForRequest = SpeedtestEngineConfig.chunkTimeoutSeconds
        self.session = session ?? URLSession(configuration: config)
        self.historyCache = historyCache
        self.pendingCache = pendingCache
        self.guestReceiptStore = guestReceiptStore
        self.tcpProbe = tcpProbe
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

        let sessionResponse: SpeedtestSessionResponse = try await api.requestJSON(
            "/api/speedtest/session",
            body: ["streams": settings.streams, "durationSec": settings.durationSeconds],
            authenticated: false
        )

        let downloadTarget = await resolveDownloadTarget(settings: settings, sessionResponse: sessionResponse)

        // Le serveur de MESURE est le VPS sélectionné par la session : il reçoit
        // toujours l'upload et reste le « serveur de test » affiché/soumis. Le
        // download (et désormais le ping, voir plus bas) peut provenir du CDN
        // CloudFront quand l'utilisateur le sélectionne.
        // Hôte réel de mesure (le VPS qui sert l'upload), extrait des URL de
        // session. Sert de repli honnête quand le backend ne renvoie pas de
        // `selectedServer` nommé — au lieu du générique « Serveur SignalQuest ».
        let measurementHost = sessionResponse.uploadUrl.host(percentEncoded: false)
            ?? sessionResponse.downloadUrl.host(percentEncoded: false)
        let measurementServerName = sessionResponse.selectedServer?.name
            ?? sessionResponse.selectedServer?.location
            ?? sessionResponse.selectedServer?.host
            ?? measurementHost
            ?? "Serveur SignalQuest"

        progress?(SpeedtestLiveProgress(
            phase: .ping,
            fraction: 0,
            pingSampleTarget: speedtestPingMeasuredSampleTarget(
                attemptBudget: SpeedtestEngineConfig.pingAttemptBudget,
                warmupCount: SpeedtestEngineConfig.pingWarmupCount
            ),
            serverName: measurementServerName
        ))
        // Cible du ping. Par défaut le VPS (`sessionResponse.downloadUrl`), qui
        // répond au GET — ce que le repli HTTP du ping exige (l'endpoint d'upload
        // rejette le GET). Mais quand le download provient réellement d'AWS
        // CloudFront, on mesure la latence contre l'edge CloudFront pour refléter
        // le chemin du download. `downloadTarget` encode déjà l'URL + le token
        // (nil pour le CDN, qui sert le fichier en GET/HEAD avec Range).
        let pingsAgainstCDN = downloadTarget.url != sessionResponse.downloadUrl
        let pingURL = pingsAgainstCDN ? downloadTarget.url : sessionResponse.downloadUrl
        let pingToken = pingsAgainstCDN ? downloadTarget.token : sessionResponse.sessionToken
        let pingOutcome = try await measurePings(
            url: pingURL,
            token: pingToken,
            serverName: measurementServerName,
            progress: progress
        )

        progress?(SpeedtestLiveProgress(phase: .download, fraction: 0, serverName: measurementServerName))
        let downloadOutcome = try await measureDownload(
            url: downloadTarget.url,
            token: downloadTarget.token,
            chunkBytes: min(sessionResponse.maxDownloadBytesPerRequest ?? 25_000_000, 64_000_000),
            durationSeconds: settings.durationSeconds,
            streams: min(settings.streams, sessionResponse.maxStreams ?? settings.streams),
            reliabilityMode: settings.reliabilityMode,
            serverName: measurementServerName,
            pingProtocol: pingOutcome.protocolName,
            progress: progress
        )

        guard let uploadBeginURL = sessionResponse.uploadBeginUrl,
              let uploadFinalizeURL = sessionResponse.uploadFinalizeUrl else {
            throw SpeedtestEngineError.uploadUnavailable
        }
        progress?(SpeedtestLiveProgress(phase: .upload, fraction: 0, serverName: measurementServerName))
        let uploadOutcome = try await measureUpload(
            beginURL: uploadBeginURL,
            uploadURL: sessionResponse.uploadUrl,
            finalizeURL: uploadFinalizeURL,
            token: sessionResponse.sessionToken,
            maxBytes: boundedUploadRequestBytes(sessionResponse.maxUploadBytesPerRequest),
            durationSeconds: settings.durationSeconds,
            streams: min(settings.streams, sessionResponse.maxStreams ?? settings.streams),
            serverName: measurementServerName,
            pingProtocol: pingOutcome.protocolName,
            progress: progress
        )

        let duration = Date().timeIntervalSince(startedAt)
        let resolvedPlace = await reverseGeocodedPlace(for: location)
        let wifiSSID = await currentWiFiSSID(for: pathStatus)
        let operatorContext = await resolveCellularOperatorContext(pathStatus: pathStatus, location: location)
        let result = SpeedtestRunResult(
            id: UUID(),
            label: "iOS speedtest",
            downloadMbps: downloadOutcome.averageMbps,
            downloadAverageMbps: downloadOutcome.averageMbps,
            downloadMaxMbps: downloadOutcome.peakMbps,
            downloadP90Mbps: downloadOutcome.p90Mbps,
            downloadP95Mbps: downloadOutcome.p95Mbps,
            uploadMbps: uploadOutcome.averageMbps,
            uploadAverageMbps: uploadOutcome.averageMbps,
            uploadMaxMbps: uploadOutcome.peakMbps,
            uploadP90Mbps: uploadOutcome.p90Mbps,
            uploadP95Mbps: uploadOutcome.p95Mbps,
            pingMs: SpeedMetricCalculator.average(pingOutcome.values),
            pingMedianMs: SpeedMetricCalculator.median(pingOutcome.values),
            pingMinMs: pingOutcome.values.min(),
            pingMaxMs: pingOutcome.values.max(),
            jitterMs: SpeedMetricCalculator.jitter(pingOutcome.values),
            pingDlMs: downloadOutcome.pingDlMs,
            jitterDlMs: downloadOutcome.jitterDlMs,
            pingUlMs: uploadOutcome.pingUlMs,
            jitterUlMs: uploadOutcome.jitterUlMs,
            pingProtocol: pingOutcome.protocolName,
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
            serverName: measurementServerName,
            downloadServerName: downloadTarget.serverName,
            createdAt: startedAt,
            downloadSeriesMbps: downloadOutcome.seriesMbps,
            uploadSeriesMbps: uploadOutcome.seriesMbps,
            uploadMeasurementSource: uploadOutcome.measurementSource,
            deviceModel: AppleDeviceDescriptor.currentShareModelName,
            osVersion: AppleDeviceDescriptor.currentOSVersionLabel
        )
        try? await appendHistory(result)
        progress?(SpeedtestLiveProgress(
            phase: .finished,
            currentMbps: result.downloadAverageMbps,
            fraction: 1,
            downloadAverageMbps: result.downloadAverageMbps,
            uploadAverageMbps: result.uploadAverageMbps,
            pingFinalMs: result.pingMinMs ?? result.pingMs,
            jitterMs: result.jitterMs,
            pingProtocol: result.pingProtocol,
            serverName: measurementServerName
        ))
        return result
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
            shareExactLocation: false
        )
    }

    func save(
        _ result: SpeedtestRunResult,
        streams: Int,
        publishToMap: Bool,
        shareExactLocation: Bool
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
            guestDeleteToken: guestDeleteToken
        )
        try? await upsertPendingSave(pending)
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

    private struct PendingSpeedtestSave: Codable, Equatable, Sendable {
        let id: String
        let result: SpeedtestRunResult
        let streams: Int
        let deviceModel: String
        let createdAt: Date
        /// Choix de publication sur la carte communautaire (opt-in). Optionnel pour
        /// rester compatible avec les sauvegardes en attente déjà sérialisées avant
        /// l'ajout du consentement — `nil` est traité comme « non publié ».
        let isVisibleOnMap: Bool?
        /// Opt-in explicite. Optionnel pour décoder les anciennes files locales.
        let shareExactLocation: Bool?
        /// Généré et persisté dans la file AVANT le POST : le même secret survit
        /// à un commit serveur dont la réponse aurait été perdue.
        let guestDeleteToken: String?
    }

    private func pendingSaves() async -> [PendingSpeedtestSave] {
        (try? await pendingCache.read([PendingSpeedtestSave].self, for: pendingSaveKey)) ?? []
    }

    private func writePendingSaves(_ values: [PendingSpeedtestSave]) async throws {
        if values.isEmpty {
            await pendingCache.remove(pendingSaveKey)
        } else {
            try await pendingCache.write(values, for: pendingSaveKey)
        }
    }

    private func upsertPendingSave(_ pending: PendingSpeedtestSave) async throws {
        var values = await pendingSaves().filter { $0.id != pending.id }
        values.append(pending)
        try await writePendingSaves(values)
    }

    private func removePendingSave(id: String) async {
        let values = await pendingSaves().filter { $0.id != id }
        try? await writePendingSaves(values)
    }

    private func submitPendingSave(_ pending: PendingSpeedtestSave) async throws {
        let payload = SpeedtestSubmission.iosPayload(
            from: pending.result,
            streams: pending.streams,
            deviceModel: pending.deviceModel,
            isVisibleOnMap: pending.isVisibleOnMap ?? false,
            shareExactLocation: pending.shareExactLocation ?? false,
            guestDeleteToken: pending.guestDeleteToken
        )
        let response: SpeedtestSaveResponse = try await api.requestJSON(
            "/api/speedtests",
            body: payload,
            idempotencyKey: pending.id
        )
        if let serverId = response.resolvedID,
           let deleteToken = response.deleteToken ?? pending.guestDeleteToken {
            guestReceiptStore.upsert(GuestSpeedtestDeletionReceipt(
                id: serverId,
                clientSubmissionId: pending.id,
                deleteToken: deleteToken,
                createdAt: pending.createdAt
            ))
        }
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
        try? await writePendingSaves(remaining)
        if let firstError { throw firstError }
    }

    // MARK: - Target resolution

    private struct ResolvedDownloadTarget: Sendable {
        let url: URL
        let token: String?
        let serverName: String
    }

    private func resolveDownloadTarget(
        settings: SpeedtestRunSettings,
        sessionResponse: SpeedtestSessionResponse
    ) async -> ResolvedDownloadTarget {
        switch settings.downloadTarget {
        case .hybridAuto:
            return await preflightBestDownloadTarget(sessionResponse: sessionResponse)
        case .cloudflareR2:
            if let target = cdnTarget(.cloudflareR2, sessionResponse: sessionResponse) { return target }
        case .awsCloudFront:
            if let target = cdnTarget(.awsCloudFront, sessionResponse: sessionResponse) { return target }
        case .vpsInternal:
            break
        }

        return vpsTarget(sessionResponse: sessionResponse)
    }

    private func vpsTarget(sessionResponse: SpeedtestSessionResponse) -> ResolvedDownloadTarget {
        ResolvedDownloadTarget(
            url: sessionResponse.downloadUrl,
            token: sessionResponse.sessionToken,
            serverName: sessionResponse.selectedServer?.name ?? SpeedtestDownloadTarget.vpsInternal.displayName
        )
    }

    /// Cible CDN (CloudFront / Cloudflare R2) si son URL configurée ne pointe
    /// pas par erreur vers l'endpoint protégé du VPS (garde-fou historique).
    private func cdnTarget(
        _ target: SpeedtestDownloadTarget,
        sessionResponse: SpeedtestSessionResponse
    ) -> ResolvedDownloadTarget? {
        let url: URL
        switch target {
        case .awsCloudFront: url = api.config.speedtestCloudFrontDownloadURL
        case .cloudflareR2: url = api.config.speedtestCloudflareDownloadURL
        default: return nil
        }
        guard !isProtectedSpeedtestDownloadURL(
            url,
            protectedDownloadURL: api.config.speedtestDownloadURL,
            sessionDownloadURL: sessionResponse.downloadUrl,
            speedtestBaseURL: api.config.speedtestBaseURL
        ) else { return nil }
        return ResolvedDownloadTarget(url: url, token: nil, serverName: target.displayName)
    }

    /// Sélection automatique « hybride » (parité Android `hybrid_auto`) :
    /// mini-warmup séquentiel sur chaque CDN — on chronomètre la lecture des
    /// 256 premiers Ko (GET streamé, annulé ensuite ; PAS de Range : R2
    /// l'ignore) avec timeout 2,5 s — le plus rapide gagne. Le ping du test
    /// suivra la cible retenue (chemin réellement mesuré). Le VPS n'est PLUS
    /// candidat (TTFB 2× supérieur) : il ne sert que de repli si les deux CDN
    /// sont injoignables (il reste toujours joignable via la session).
    private func preflightBestDownloadTarget(
        sessionResponse: SpeedtestSessionResponse
    ) async -> ResolvedDownloadTarget {
        var candidates: [ResolvedDownloadTarget] = []
        if let cloudflare = cdnTarget(.cloudflareR2, sessionResponse: sessionResponse) {
            candidates.append(cloudflare)
        }
        if let cloudFront = cdnTarget(.awsCloudFront, sessionResponse: sessionResponse) {
            candidates.append(cloudFront)
        }

        var best: (target: ResolvedDownloadTarget, elapsed: TimeInterval)?
        for candidate in candidates {
            if let elapsed = await preflightElapsed(candidate) {
                if best == nil || elapsed < best!.elapsed {
                    best = (candidate, elapsed)
                }
            }
        }
        return best?.target ?? vpsTarget(sessionResponse: sessionResponse)
    }

    /// Temps de lecture des 256 premiers Ko du candidat (nil = échec/timeout).
    private func preflightElapsed(_ target: ResolvedDownloadTarget) async -> TimeInterval? {
        let sampleBytes = 262_144
        var components = URLComponents(url: target.url, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "cachebust", value: UUID().uuidString))
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token = target.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let started = Date()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            var received = 0
            for try await _ in bytes {
                received += 1
                if received >= sampleBytes { break }
                // Garde-fou timeout vérifié tous les 16 Ko (pas à chaque octet).
                if received & 0x3FFF == 0, Date().timeIntervalSince(started) > 2.5 { return nil }
            }
            guard received >= min(sampleBytes, 1) else { return nil }
            return Date().timeIntervalSince(started)
        } catch {
            return nil
        }
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

    private func measurePings(
        url: URL,
        token: String?,
        serverName: String,
        progress: SpeedtestProgressHandler?
    ) async throws -> PingOutcome {
        guard let host = url.host(percentEncoded: false) ?? url.host else {
            throw SpeedtestEngineError.pingFailed
        }
        let port = UInt16(url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443))

        let tcp = await measureTcpPings(host: host, port: port, serverName: serverName, progress: progress)
        if !tcp.values.isEmpty {
            return PingOutcome(values: tcp.values, protocolName: "TCP")
        }

        let remainingBudget = max(0, SpeedtestEngineConfig.pingAttemptBudget - tcp.attemptsUsed)
        let http = try await measureHttpPings(url: url, token: token, attemptBudget: remainingBudget, serverName: serverName, progress: progress)
        guard !http.values.isEmpty else { throw SpeedtestEngineError.pingFailed }
        return PingOutcome(values: http.values, protocolName: "HTTP")
    }

    private func measureTcpPings(
        host: String,
        port: UInt16,
        serverName: String,
        progress: SpeedtestProgressHandler?
    ) async -> PingAttemptResult {
        var values: [Double] = []
        var attemptsUsed = 0
        let measuredTarget = speedtestPingMeasuredSampleTarget(
            attemptBudget: SpeedtestEngineConfig.pingAttemptBudget,
            warmupCount: SpeedtestEngineConfig.pingWarmupCount
        )

        do {
            attemptsUsed += 1
            _ = try await tcpProbe.connectLatencyMs(
                host: host,
                port: port,
                timeoutSeconds: SpeedtestEngineConfig.pingTimeoutSeconds
            )
        } catch {
            return PingAttemptResult(values: [], attemptsUsed: attemptsUsed)
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
                values.append(elapsed)
                emitPingProgress(values: values, protocolName: "TCP", target: measuredTarget, serverName: serverName, progress: progress)
            } catch {
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(SpeedtestEngineConfig.pingIntervalMs * 1_000_000))
        }
        return PingAttemptResult(values: values, attemptsUsed: attemptsUsed)
    }

    private func measureHttpPings(
        url: URL,
        token: String?,
        attemptBudget: Int,
        serverName: String,
        progress: SpeedtestProgressHandler?
    ) async throws -> PingAttemptResult {
        guard attemptBudget > 0 else { return PingAttemptResult(values: [], attemptsUsed: 0) }
        var values: [Double] = []
        var attemptsUsed = 0
        let warmupCount = min(SpeedtestEngineConfig.pingWarmupCount, max(0, attemptBudget - 1))
        let measuredTarget = max(0, attemptBudget - warmupCount)
        progress?(SpeedtestLiveProgress(
            phase: .ping,
            fraction: 0,
            pingProtocol: "HTTP",
            pingSampleTarget: measuredTarget,
            serverName: serverName
        ))

        let total = warmupCount + measuredTarget
        for index in 0..<total {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            var query = components.queryItems ?? []
            if token != nil {
                query.append(URLQueryItem(name: "bytes", value: "1"))
            }
            components.queryItems = query
            let start = Date()
            try await performPingRequest(url: components.url ?? url, token: token)
            attemptsUsed += 1
            let elapsed = Date().timeIntervalSince(start) * 1_000
            if index >= warmupCount {
                values.append(elapsed)
                emitPingProgress(values: values, protocolName: "HTTP", target: measuredTarget, serverName: serverName, progress: progress)
            }
            try await Task.sleep(nanoseconds: UInt64(SpeedtestEngineConfig.pingIntervalMs * 1_000_000))
        }
        return PingAttemptResult(values: values, attemptsUsed: attemptsUsed)
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

    private func performPingRequest(url: URL, token: String?) async throws {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = SpeedtestEngineConfig.pingTimeoutSeconds
        if let token { head.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (_, response) = try await session.data(for: head)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) { return }
        } catch {
            // Some CDNs reject HEAD — fall back to a tiny GET.
        }
        var get = URLRequest(url: url)
        get.httpMethod = "GET"
        get.timeoutInterval = SpeedtestEngineConfig.pingTimeoutSeconds
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        if let token { get.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await session.data(for: get)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw APIError.http(
                status: http.statusCode,
                code: nil,
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                requestId: nil,
                retryAfter: nil
            )
        }
    }

    /// `deadline` est une closure : l'échéance de la phase peut glisser quand la
    /// grace adaptative est étendue.
    private func measureLoadedPings(
        url: URL,
        token: String?,
        deadline: @escaping @Sendable () -> Date,
        protocolName: String
    ) async -> [Double] {
        var values: [Double] = []
        guard let host = url.host(percentEncoded: false) ?? url.host else {
            return []
        }
        let port = UInt16(url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443))

        while Date() < deadline() && !Task.isCancelled {
            let start = Date()
            do {
                if protocolName == "TCP" {
                    let elapsed = try await tcpProbe.connectLatencyMs(
                        host: host,
                        port: port,
                        timeoutSeconds: SpeedtestEngineConfig.pingTimeoutSeconds
                    )
                    if !Task.isCancelled {
                        values.append(elapsed)
                    }
                } else {
                    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
                    var query = components.queryItems ?? []
                    if token != nil {
                        query.append(URLQueryItem(name: "bytes", value: "1"))
                    }
                    components.queryItems = query
                    try await performPingRequest(url: components.url ?? url, token: token)
                    if !Task.isCancelled {
                        let elapsed = Date().timeIntervalSince(start) * 1_000
                        values.append(elapsed)
                    }
                }
            } catch {
                // Ignore individual failures under load
            }
            try? await Task.sleep(nanoseconds: UInt64(SpeedtestEngineConfig.pingIntervalMs * 1_000_000))
        }
        return values
    }

    // MARK: - Download (Android-aligned)

    /// Aggregate outcome produced by the engine: a final average plus percentile / peak.
    private struct DownloadOutcome: Sendable {
        let averageMbps: Double
        let p90Mbps: Double?
        let p95Mbps: Double?
        let peakMbps: Double
        let measuredWindows: Int
        let seriesMbps: [Double]
        let pingDlMs: Double?
        let jitterDlMs: Double?
    }

    private struct UploadOutcome: Sendable {
        let averageMbps: Double
        let p90Mbps: Double?
        let p95Mbps: Double?
        let peakMbps: Double
        let confirmedBytes: Int
        let measurementSource: String
        let seriesMbps: [Double]
        let pingUlMs: Double?
        let jitterUlMs: Double?
    }

    private func measureDownload(
        url: URL,
        token: String?,
        chunkBytes: Int,
        durationSeconds: Int,
        streams: Int,
        reliabilityMode: Bool,
        serverName: String,
        pingProtocol: String,
        progress: SpeedtestProgressHandler?
    ) async throws -> DownloadOutcome {
        do {
            let outcome = try await measureDownloadAttempt(
                url: url,
                token: token,
                chunkBytes: chunkBytes,
                durationSeconds: durationSeconds,
                streams: streams,
                serverName: serverName,
                pingProtocol: pingProtocol,
                progress: progress
            )
            // If the multi-stream attempt yielded a meaningful number of windows
            // we keep it. Otherwise (network refused parallelism, hit 429, …) we
            // fall back to a single-stream run that's more conservative.
            if outcome.measuredWindows >= 2 || !reliabilityMode || streams <= 1 {
                return outcome
            }
        } catch {
            if !reliabilityMode || streams <= 1 { throw error }
        }
        return try await measureDownloadAttempt(
            url: url,
            token: token,
            chunkBytes: chunkBytes,
            durationSeconds: durationSeconds,
            streams: 1,
            serverName: serverName,
            pingProtocol: pingProtocol,
            progress: progress
        )
    }

    /// Core download algorithm — ported from Android SpeedTestEngine.measureDownload().
    private func measureDownloadAttempt(
        url: URL,
        token: String?,
        chunkBytes: Int,
        durationSeconds: Int,
        streams: Int,
        serverName: String,
        pingProtocol: String,
        progress: SpeedtestProgressHandler?
    ) async throws -> DownloadOutcome {
        let baseGraceMs = SpeedtestEngineConfig.downloadGraceTimeMs
        let usefulDurationMs = Double(max(5, min(durationSeconds, 30))) * 1_000
        let attemptStart = Date()
        // Grace ADAPTATIVE : la fenêtre démarre au warm-up de base (2 s) et
        // peut être étendue UNE fois, avant son expiration, si le lien est
        // encore en slow-start — l'échéance glisse d'autant pour préserver la
        // durée utile de mesure.
        let window = SpeedtestAdaptivePhaseWindow(
            graceMs: baseGraceMs,
            deadline: attemptStart.addingTimeInterval((usefulDurationMs + baseGraceMs) / 1_000)
        )

        let totals = SpeedtestSyncByteCounter()
        let liveAggregator = SpeedtestLiveSampler()
        let samplesBox = SpeedtestSamplesBox()
        let progressMonitor = SpeedtestStallMonitor(timeoutMs: SpeedtestEngineConfig.downloadStallTimeoutMs)

        // Session PERSISTANTE pour toute la phase : les streams se partagent le
        // pool (une connexion par stream) et chaque rotation de requête réutilise
        // sa connexion (keep-alive) au lieu de repayer handshake TLS + slow-start
        // TCP — cause n°1 de sous-estimation avec l'ancienne session éphémère.
        let streamCount = max(1, min(streams, SpeedtestEngineConfig.hardMaxStreams))
        let phaseSession = makeMeasurementSession(
            maxConnectionsPerHost: streamCount,
            requestTimeout: SpeedtestEngineConfig.chunkTimeoutSeconds
        )

        let loadedPingsTask = Task { [weak self] in
            guard let self else { return [Double]() }
            try? await Task.sleep(nanoseconds: UInt64(baseGraceMs * 1_000_000))
            // La grace a pu être étendue pendant le warm-up de base : attendre le
            // complément pour ne mesurer la latence en charge que sur la fenêtre utile.
            let extraMs = window.graceMs - baseGraceMs
            if extraMs > 0 { try? await Task.sleep(nanoseconds: UInt64(extraMs * 1_000_000)) }
            guard !Task.isCancelled else { return [Double]() }
            return await self.measureLoadedPings(url: url, token: token, deadline: { window.deadline }, protocolName: pingProtocol)
        }

        // Live progress sampler — pulses the UI every 150 ms.
        let progressTask = Task { [weak self] in
            guard self != nil else { return }
            var lastSampleMs: Double?
            var lastSampleTotalBytes = 0
            var instantHistory: [(ms: Double, mbps: Double)] = []
            var graceDecided = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(SpeedtestEngineConfig.sampleIntervalMs * 1_000_000))
                if Task.isCancelled { return }
                let now = Date()
                if now >= window.deadline { return }
                let elapsedMs = now.timeIntervalSince(attemptStart) * 1_000
                let snapshot = totals.snapshot()

                // Aiguille = débit INSTANTANÉ (fenêtre glissante 1 s + léger EMA),
                // émis dès le warm-up. La moyenne (valeur finale) reste cumulée
                // post-grace, inchangée.
                let needleMbps = liveAggregator.observe(totalBytes: snapshot.total, elapsedMs: elapsedMs)
                instantHistory.append((ms: elapsedMs, mbps: liveAggregator.lastInstantMbps))

                // Grace adaptative : décidée au dernier tick AVANT la frontière du
                // warm-up (jamais après — les octets seraient déjà comptés utiles).
                if !graceDecided, elapsedMs >= baseGraceMs - SpeedtestEngineConfig.sampleIntervalMs * 1.5 {
                    graceDecided = true
                    let earlier = instantHistory.last(where: { $0.ms <= elapsedMs - SpeedtestEngineConfig.graceComparisonLookbackMs })?.mbps
                    if speedtestShouldExtendGrace(recentMbps: liveAggregator.lastInstantMbps, earlierMbps: earlier) {
                        window.extendGrace(to: SpeedtestEngineConfig.extendedGraceTimeMs, ifNotPastMs: elapsedMs)
                    }
                }

                let graceMs = window.graceMs
                if elapsedMs >= graceMs {
                    if let startMs = lastSampleMs, startMs >= graceMs {
                        let bytesDiff = max(0, snapshot.total - lastSampleTotalBytes)
                        if bytesDiff > 0, elapsedMs > startMs {
                            await samplesBox.append(start: startMs, end: elapsedMs, bytes: bytesDiff)
                        }
                    }
                    lastSampleMs = elapsedMs
                    lastSampleTotalBytes = snapshot.total

                    let effectiveBytes = max(0, snapshot.total - snapshot.grace)
                    let averageMbps = boundedMbps(bytes: effectiveBytes, durationMs: elapsedMs - graceMs)
                    let fraction = max(0, min(1, (elapsedMs - graceMs) / usefulDurationMs))
                    progress?(SpeedtestLiveProgress(
                        phase: .download,
                        currentMbps: needleMbps,
                        fraction: fraction,
                        downloadLiveMbps: needleMbps,
                        downloadAverageMbps: averageMbps,
                        serverName: serverName
                    ))
                    await progressMonitor.observe(elapsedMs: elapsedMs, totalBytes: snapshot.total)
                } else {
                    lastSampleMs = elapsedMs
                    lastSampleTotalBytes = snapshot.total
                    // Pendant le warm-up : l'aiguille bouge (débit réel instantané),
                    // mais aucune moyenne n'est encore publiée.
                    progress?(SpeedtestLiveProgress(
                        phase: .download,
                        currentMbps: needleMbps,
                        fraction: 0,
                        downloadLiveMbps: needleMbps,
                        serverName: serverName
                    ))
                }
            }
        }
        defer {
            progressTask.cancel()
            loadedPingsTask.cancel()
            phaseSession.invalidateAndCancel()
        }

        // Concurrent streams (staggered).
        try await withThrowingTaskGroup(of: Void.self) { group in
            for streamIndex in 0..<streamCount {
                group.addTask { [self] in
                    try await Task.sleep(nanoseconds: UInt64(Double(streamIndex) * SpeedtestEngineConfig.streamStaggerMs * 1_000_000))
                    try await runDownloadStream(
                        streamIndex: streamIndex,
                        url: url,
                        token: token,
                        chunkBytes: chunkBytes,
                        session: phaseSession,
                        window: window,
                        attemptStart: attemptStart,
                        totals: totals,
                        stallMonitor: progressMonitor
                    )
                }
            }
            try await group.waitForAll()
        }

        progressTask.cancel()

        let downloadPings = await loadedPingsTask.value
        let pingDlMs = downloadPings.isEmpty ? nil : SpeedMetricCalculator.average(downloadPings)
        let jitterDlMs = downloadPings.isEmpty ? nil : SpeedMetricCalculator.jitter(downloadPings)

        // Aggregate: avg = effectiveBytes * 8 / (effectiveDurationSec) / 1e6.
        let finalGraceMs = window.graceMs
        let snapshot = totals.snapshot()
        let measurementEndMs = min(Date().timeIntervalSince(attemptStart) * 1_000, usefulDurationMs + finalGraceMs)
        let effectiveBytes = max(0, snapshot.total - snapshot.grace)
        let effectiveDurationMs = max(1, measurementEndMs - finalGraceMs)
        guard let averageMbps = measuredTransferMbps(effectiveBytes: effectiveBytes, durationMs: effectiveDurationMs) else {
            throw SpeedtestEngineError.downloadProducedNoBytes
        }

        // p90 / p95 / peak via 1 s windows.
        let stats = await samplesBox.publicStats(windowMs: SpeedtestEngineConfig.publicPeakWindowMs, graceMs: finalGraceMs, endMs: measurementEndMs)

        return DownloadOutcome(
            averageMbps: averageMbps,
            p90Mbps: stats.p90,
            p95Mbps: stats.p95,
            peakMbps: max(averageMbps, stats.peak),
            measuredWindows: stats.windowCount,
            seriesMbps: stats.seriesMbps,
            pingDlMs: pingDlMs,
            jitterDlMs: jitterDlMs
        )
    }

    /// One download stream — pulls bytes through a `URLSessionDataDelegate` so
    /// we count real received chunks without a Swift byte-by-byte loop. Toutes
    /// les requêtes du stream passent par la session PERSISTANTE de la phase :
    /// la rotation de chunk réutilise la connexion (keep-alive).
    private func runDownloadStream(
        streamIndex: Int,
        url: URL,
        token: String?,
        chunkBytes: Int,
        session: URLSession,
        window: SpeedtestAdaptivePhaseWindow,
        attemptStart: Date,
        totals: SpeedtestSyncByteCounter,
        stallMonitor: SpeedtestStallMonitor
    ) async throws {
        while Date() < window.deadline && !Task.isCancelled {
            if await stallMonitor.stalled { return }

            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            var query = components.queryItems ?? []
            query.append(URLQueryItem(name: "r", value: "\(UUID().uuidString)-\(streamIndex)"))
            if token != nil {
                query.append(URLQueryItem(name: "bytes", value: "\(chunkBytes)"))
            }
            components.queryItems = query

            var request = URLRequest(url: components.url ?? url)
            request.timeoutInterval = SpeedtestEngineConfig.chunkTimeoutSeconds
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue("bytes=0-\(chunkBytes - 1)", forHTTPHeaderField: "Range")
            }

            do {
                try await performStreamingDownload(request: request, session: session, deadline: window.deadline) { byteCount in
                    guard byteCount > 0 else { return }
                    let elapsedMs = Date().timeIntervalSince(attemptStart) * 1_000
                    guard elapsedMs <= window.deadline.timeIntervalSince(attemptStart) * 1_000 else { return }
                    totals.add(byteCount, isGrace: elapsedMs < window.graceMs)
                }
            } catch is SpeedtestRateLimitedError {
                try? await Task.sleep(nanoseconds: UInt64(250 + (streamIndex * 50)) * 1_000_000)
                continue
            } catch is CancellationError {
                return
            } catch {
                // Stream errors are non-fatal — let other streams keep working.
                // We back off briefly to avoid hammering the server.
                try? await Task.sleep(nanoseconds: 120_000_000)
                continue
            }
        }
    }

    /// Exécute une requête de download sur la session PERSISTANTE de la phase,
    /// avec un délégué PAR TÂCHE (iOS 15+) qui compte les octets reçus. La
    /// connexion survit à la requête (keep-alive) — plus de handshake TLS ni de
    /// slow-start TCP à chaque rotation de chunk.
    private func performStreamingDownload(
        request: URLRequest,
        session: URLSession,
        deadline: Date,
        onBytes: @escaping @Sendable (Int) -> Void
    ) async throws {
        let delegate = SpeedtestDownloadDelegate(deadline: deadline, onBytes: onBytes)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        try await delegate.run(task: task)
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

    // MARK: - Upload (Android-aligned, simpler — single chunk POSTs)

    private func measureUpload(
        beginURL: URL,
        uploadURL: URL,
        finalizeURL: URL,
        token: String,
        maxBytes: Int,
        durationSeconds: Int,
        streams: Int,
        serverName: String,
        pingProtocol: String,
        progress: SpeedtestProgressHandler?
    ) async throws -> UploadOutcome {
        let baseGraceMs = SpeedtestEngineConfig.uploadGraceTimeMs
        let usefulDurationMs = Double(max(5, min(durationSeconds, 30))) * 1_000
        let beginBody = Data(#"{"warmupMs":\#(Int(baseGraceMs)),"durationMs":\#(Int(usefulDurationMs)),"windowMs":1000}"#.utf8)
        var begin = URLRequest(url: beginURL)
        begin.httpMethod = "POST"
        begin.timeoutInterval = SpeedtestEngineConfig.uploadTimeoutSeconds
        begin.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        begin.setValue("application/json", forHTTPHeaderField: "Content-Type")
        begin.httpBody = beginBody
        let (beginData, beginResponse) = try await session.data(for: begin)
        if let http = beginResponse as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw APIError.http(
                status: http.statusCode, code: nil,
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                requestId: nil, retryAfter: nil
            )
        }
        let beginJson = try JSONSerialization.jsonObject(with: beginData) as? [String: Any]
        guard let runId = beginJson?["uploadRunId"] as? String, !runId.isEmpty else {
            throw SpeedtestEngineError.uploadHandshakeFailed
        }

        let payload = Data(repeating: 0x5A, count: maxBytes)
        let attemptStart = Date()
        // Grace ADAPTATIVE (cf. download) : extension possible une seule fois,
        // avant la frontière du warm-up, échéance repoussée d'autant.
        let window = SpeedtestAdaptivePhaseWindow(
            graceMs: baseGraceMs,
            deadline: attemptStart.addingTimeInterval((usefulDurationMs + baseGraceMs) / 1_000)
        )
        let totals = SpeedtestSyncByteCounter()
        let samples = SpeedtestSamplesBox()
        let liveAggregator = SpeedtestLiveSampler()

        // Session PERSISTANTE pour toute la phase upload : les POSTs successifs
        // d'un même stream réutilisent leur connexion (keep-alive) — plus de
        // handshake TLS + slow-start TCP à chaque rotation de 32 Mo, qui
        // plafonnaient artificiellement l'upload (~100 Mbps à 4 streams).
        let streamCount = max(1, min(streams, SpeedtestEngineConfig.hardMaxUploadStreams))
        let phaseSession = makeMeasurementSession(
            maxConnectionsPerHost: streamCount,
            requestTimeout: SpeedtestEngineConfig.uploadTimeoutSeconds
        )

        let loadedPingsTask = Task { [weak self] in
            guard let self else { return [Double]() }
            try? await Task.sleep(nanoseconds: UInt64(baseGraceMs * 1_000_000))
            let extraMs = window.graceMs - baseGraceMs
            if extraMs > 0 { try? await Task.sleep(nanoseconds: UInt64(extraMs * 1_000_000)) }
            guard !Task.isCancelled else { return [Double]() }
            return await self.measureLoadedPings(url: uploadURL, token: token, deadline: { window.deadline }, protocolName: pingProtocol)
        }

        let progressTask = Task { [weak self] in
            guard self != nil else { return }
            var lastSampleMs: Double?
            var lastSampleTotalBytes = 0
            var instantHistory: [(ms: Double, mbps: Double)] = []
            var graceDecided = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(SpeedtestEngineConfig.sampleIntervalMs * 1_000_000))
                if Task.isCancelled { return }
                let now = Date()
                if now >= window.deadline { return }
                let elapsedMs = now.timeIntervalSince(attemptStart) * 1_000
                let snapshot = totals.snapshot()

                // Aiguille = débit INSTANTANÉ (fenêtre glissante 1 s + léger EMA).
                let needleMbps = liveAggregator.observe(totalBytes: snapshot.total, elapsedMs: elapsedMs)
                instantHistory.append((ms: elapsedMs, mbps: liveAggregator.lastInstantMbps))

                if !graceDecided, elapsedMs >= baseGraceMs - SpeedtestEngineConfig.sampleIntervalMs * 1.5 {
                    graceDecided = true
                    let earlier = instantHistory.last(where: { $0.ms <= elapsedMs - SpeedtestEngineConfig.graceComparisonLookbackMs })?.mbps
                    if speedtestShouldExtendGrace(recentMbps: liveAggregator.lastInstantMbps, earlierMbps: earlier) {
                        window.extendGrace(to: SpeedtestEngineConfig.extendedGraceTimeMs, ifNotPastMs: elapsedMs)
                    }
                }

                let graceMs = window.graceMs
                if elapsedMs >= graceMs {
                    if let startMs = lastSampleMs, startMs >= graceMs {
                        let bytesDiff = max(0, snapshot.total - lastSampleTotalBytes)
                        if bytesDiff > 0, elapsedMs > startMs {
                            await samples.append(start: startMs, end: elapsedMs, bytes: bytesDiff)
                        }
                    }
                    lastSampleMs = elapsedMs
                    lastSampleTotalBytes = snapshot.total

                    let effectiveBytes = max(0, snapshot.total - snapshot.grace)
                    let averageMbps = boundedMbps(bytes: effectiveBytes, durationMs: elapsedMs - graceMs)
                    let fraction = max(0, min(1, (elapsedMs - graceMs) / usefulDurationMs))
                    progress?(SpeedtestLiveProgress(
                        phase: .upload,
                        currentMbps: needleMbps,
                        fraction: fraction,
                        uploadLiveMbps: needleMbps,
                        uploadAverageMbps: averageMbps,
                        serverName: serverName
                    ))
                } else {
                    lastSampleMs = elapsedMs
                    lastSampleTotalBytes = snapshot.total
                    progress?(SpeedtestLiveProgress(
                        phase: .upload,
                        currentMbps: needleMbps,
                        fraction: 0,
                        uploadLiveMbps: needleMbps,
                        serverName: serverName
                    ))
                }
            }
        }
        defer {
            progressTask.cancel()
            loadedPingsTask.cancel()
            phaseSession.invalidateAndCancel()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for streamIndex in 0..<streamCount {
                group.addTask { [self] in
                    try await Task.sleep(nanoseconds: UInt64(Double(streamIndex) * SpeedtestEngineConfig.streamStaggerMs * 1_000_000))
                    while Date() < window.deadline && !Task.isCancelled {
                        guard var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false) else { continue }
                        var query = components.queryItems ?? []
                        query.append(URLQueryItem(name: "r", value: "\(UUID().uuidString)-\(streamIndex)"))
                        components.queryItems = query
                        var upload = URLRequest(url: components.url ?? uploadURL)
                        upload.httpMethod = "POST"
                        upload.timeoutInterval = SpeedtestEngineConfig.uploadTimeoutSeconds
                        upload.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        do {
                            let requestTimeout = max(
                                3,
                                min(SpeedtestEngineConfig.uploadTimeoutSeconds, window.deadline.timeIntervalSinceNow + 3)
                            )
                            let requestDeadline = min(window.deadline, Date().addingTimeInterval(requestTimeout))
                            let result = try await performStreamingUpload(
                                upload,
                                session: phaseSession,
                                payload: payload,
                                deadline: requestDeadline
                            ) { sentBytes in
                                guard sentBytes > 0 else { return }
                                let elapsedMs = Date().timeIntervalSince(attemptStart) * 1_000
                                guard elapsedMs <= window.deadline.timeIntervalSince(attemptStart) * 1_000 else { return }
                                totals.add(sentBytes, isGrace: elapsedMs < window.graceMs)
                            }
                            guard result.receivedResponse else { continue }
                            if let statusCode = result.httpStatusCode, !(200..<400).contains(statusCode) {
                                if statusCode == 429 {
                                    try? await Task.sleep(nanoseconds: 250_000_000)
                                    continue
                                }
                                continue
                            }
                            let serverConfirmed = parseUploadAckBytes(from: result.data)
                            let confirmedBytes = computeConfirmedUploadBytes(
                                clientWrittenBytes: result.sentBytes,
                                serverConfirmedBytes: serverConfirmed
                            )
                            guard confirmedBytes > 0 else { continue }
                        } catch {
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            continue
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        progressTask.cancel()

        let uploadPings = await loadedPingsTask.value
        let pingUlMs = uploadPings.isEmpty ? nil : SpeedMetricCalculator.average(uploadPings)
        let jitterUlMs = uploadPings.isEmpty ? nil : SpeedMetricCalculator.jitter(uploadPings)

        // Finalize on the server (best-effort). Transmet le warm-up réellement
        // appliqué (grace adaptative) pour que la fenêtre serveur exclue
        // exactement la même rampe — `warmupMs` au finalize est accepté par le
        // protocole existant.
        var finalize = URLRequest(url: finalizeURL)
        finalize.httpMethod = "POST"
        finalize.timeoutInterval = SpeedtestEngineConfig.uploadTimeoutSeconds
        finalize.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        finalize.setValue("application/json", forHTTPHeaderField: "Content-Type")
        finalize.httpBody = speedtestUploadFinalizeBody(runId: runId, warmupMs: window.graceMs)
        let serverMeasurement: UploadServerMeasurement?
        do {
            let (finalData, finalResponse) = try await session.data(for: finalize)
            if let http = finalResponse as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
                serverMeasurement = nil
            } else {
                serverMeasurement = UploadServerMeasurement(data: finalData)
            }
        } catch {
            serverMeasurement = nil
        }

        let finalGraceMs = window.graceMs
        let snapshot = totals.snapshot()
        let measurementEndMs = min(Date().timeIntervalSince(attemptStart) * 1_000, usefulDurationMs + finalGraceMs)
        let effectiveBytes = max(0, snapshot.total - snapshot.grace)
        let effectiveDurationMs = max(1, measurementEndMs - finalGraceMs)
        let confirmedBytes = computeConfirmedUploadBytes(
            clientWrittenBytes: effectiveBytes,
            serverConfirmedBytes: serverMeasurement?.serverBytesReceived
        )
        let clientAverage = measuredTransferMbps(effectiveBytes: confirmedBytes, durationMs: effectiveDurationMs) ?? 0
        let stats = await samples.publicStats(windowMs: SpeedtestEngineConfig.publicPeakWindowMs, graceMs: finalGraceMs, endMs: measurementEndMs)

        let usableServerMeasurement = serverMeasurement?.isUsable(expectedUsefulDurationMs: usefulDurationMs) == true
        // Mesure serveur utilisable → `serverAvgMbps` est AUTORITAIRE : octets et
        // durée proviennent de la MÊME fenêtre serveur. L'ancien mix
        // min(client, serveur) / durée serveur mélangeait deux fenêtres et
        // sous-estimait. Sinon, repli client borné par les octets confirmés
        // (anti-triche conservé).
        let averageMbps = resolvedUploadAverageMbps(
            serverMeasurement: serverMeasurement,
            expectedUsefulDurationMs: usefulDurationMs,
            clientAverageMbps: clientAverage
        )
        guard confirmedBytes > 0, averageMbps > 0 else {
            throw SpeedtestEngineError.uploadProducedNoBytes
        }

        // Scale client-side series and peaks by the confirmation ratio to prevent socket buffer inflation
        let clientWrittenBytes = max(1, effectiveBytes)
        let scaleRatio = min(1.0, Double(confirmedBytes) / Double(clientWrittenBytes))

        let scaledP90 = stats.p90.map { $0 * scaleRatio }
        let scaledP95 = stats.p95.map { $0 * scaleRatio }
        let scaledPeak = stats.peak * scaleRatio
        let scaledSeries = stats.seriesMbps.map { $0 * scaleRatio }

        return UploadOutcome(
            averageMbps: averageMbps,
            p90Mbps: usableServerMeasurement ? (serverMeasurement?.serverP90Mbps ?? scaledP90) : scaledP90,
            p95Mbps: usableServerMeasurement ? (serverMeasurement?.serverP95Mbps ?? scaledP95) : scaledP95,
            peakMbps: max(averageMbps, usableServerMeasurement ? (serverMeasurement?.serverPeakMbps ?? scaledPeak) : scaledPeak),
            confirmedBytes: confirmedBytes,
            measurementSource: usableServerMeasurement ? "server-confirmed" : "client-written",
            seriesMbps: scaledSeries,
            pingUlMs: pingUlMs,
            jitterUlMs: jitterUlMs
        )
    }

    /// Exécute un POST d'upload sur la session PERSISTANTE de la phase, avec un
    /// délégué PAR TÂCHE (iOS 15+) qui compte les octets réellement envoyés.
    private func performStreamingUpload(
        _ request: URLRequest,
        session: URLSession,
        payload: Data,
        deadline: Date,
        onBytesSent: @escaping @Sendable (Int) -> Void
    ) async throws -> SpeedtestUploadTaskResult {
        let delegate = SpeedtestUploadDelegate(deadline: deadline, onBytesSent: onBytesSent)
        let task = session.uploadTask(with: request, from: payload)
        task.delegate = delegate
        return try await delegate.run(task: task)
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

// MARK: - Helpers

private func boundedMbps(bytes: Int, durationMs: Double) -> Double {
    guard bytes > 0, durationMs > 0 else { return 0 }
    let mbps = (Double(bytes) * 8.0 / 1_000_000.0) / (durationMs / 1_000)
    return mbps.isFinite && mbps >= 0 ? mbps : 0
}

func measuredTransferMbps(effectiveBytes: Int, durationMs: Double) -> Double? {
    let mbps = boundedMbps(bytes: effectiveBytes, durationMs: durationMs)
    guard effectiveBytes > 0, mbps > 0 else { return nil }
    return mbps
}

func speedtestPingMeasuredSampleTarget(attemptBudget: Int, warmupCount: Int) -> Int {
    let budget = max(0, attemptBudget)
    guard budget > 0 else { return 0 }
    let warmups = min(max(0, warmupCount), max(0, budget - 1))
    return max(0, budget - warmups)
}

func boundedUploadRequestBytes(_ serverValue: Int?) -> Int {
    let value = serverValue ?? SpeedtestEngineConfig.maxUploadBytesPerRequest
    return min(
        max(value, SpeedtestEngineConfig.minUploadBytesPerRequest),
        SpeedtestEngineConfig.maxUploadBytesPerRequest
    )
}

func computeConfirmedUploadBytes(clientWrittenBytes: Int, serverConfirmedBytes: Int?) -> Int {
    guard clientWrittenBytes > 0 else { return 0 }
    guard let serverConfirmedBytes else { return clientWrittenBytes }
    return max(0, min(clientWrittenBytes, serverConfirmedBytes))
}

/// Décide si la grace (warm-up) doit être étendue au-delà de la fenêtre de
/// base : oui quand le débit instantané dépasse `fastLinkThresholdMbps`
/// (2 s de slow-start pèsent lourd sur la moyenne des liens rapides) ou quand
/// il croît encore nettement (≥ `risingGraceRatio`) par rapport au début de
/// fenêtre — signature d'un lien toujours en rampe TCP.
func speedtestShouldExtendGrace(recentMbps: Double, earlierMbps: Double?) -> Bool {
    guard recentMbps > 0 else { return false }
    if recentMbps > SpeedtestEngineConfig.fastLinkThresholdMbps { return true }
    guard let earlierMbps, earlierMbps > 0 else { return false }
    return recentMbps >= earlierMbps * SpeedtestEngineConfig.risingGraceRatio
}

/// Corps du POST de finalize upload : `uploadRunId` + le `warmupMs` réellement
/// appliqué côté client (grace adaptative), pour que la fenêtre de mesure
/// serveur exclue la même rampe. Paramètre déjà accepté par le serveur.
func speedtestUploadFinalizeBody(runId: String, warmupMs: Double) -> Data {
    Data("{\"uploadRunId\":\"\(runId)\",\"warmupMs\":\(Int(warmupMs.rounded()))}".utf8)
}

/// Moyenne finale d'upload. Quand la mesure serveur est utilisable (et non
/// tronquée), `serverAvgMbps` est AUTORITAIRE : octets et durée proviennent de
/// la même fenêtre serveur — c'est aussi la valeur anti-triche par excellence
/// (mesurée côté serveur). Sinon, repli sur la moyenne client bornée par les
/// octets confirmés (min client/serveur), qui ne peut jamais gonfler le score.
func resolvedUploadAverageMbps(
    serverMeasurement: UploadServerMeasurement?,
    expectedUsefulDurationMs: Double,
    clientAverageMbps: Double
) -> Double {
    if let serverMeasurement,
       serverMeasurement.isUsable(expectedUsefulDurationMs: expectedUsefulDurationMs),
       let serverAverage = serverMeasurement.serverAvgMbps {
        return serverAverage
    }
    return clientAverageMbps
}

func isProtectedSpeedtestDownloadURL(
    _ candidate: URL,
    protectedDownloadURL: URL,
    sessionDownloadURL: URL,
    speedtestBaseURL: URL
) -> Bool {
    func normalizedKey(_ url: URL) -> String {
        let scheme = (url.scheme ?? "https").lowercased()
        let host = (url.host ?? "").lowercased()
        let port = url.port.map { ":\($0)" } ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(scheme)://\(host)\(port)/\(path)"
    }

    let candidateKey = normalizedKey(candidate)
    let canonicalProtected = speedtestBaseURL.appendingPathComponent("download")
    return candidateKey == normalizedKey(protectedDownloadURL)
        || candidateKey == normalizedKey(sessionDownloadURL)
        || candidateKey == normalizedKey(canonicalProtected)
}

private func parseUploadAckBytes(from data: Data) -> Int? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json.intValue("bytesReceived")
}

private struct SpeedtestRateLimitedError: Error {}

private struct SpeedtestUploadTaskResult: Sendable {
    let data: Data
    let httpStatusCode: Int?
    let receivedResponse: Bool
    let sentBytes: Int
}

struct UploadServerMeasurement: Equatable, Sendable {
    let serverBytesReceived: Int?
    let serverDurationMs: Double?
    let serverAvgMbps: Double?
    let serverP90Mbps: Double?
    let serverP95Mbps: Double?
    let serverPeakMbps: Double?
    let serverMeasuredWindows: Int?
    let serverMeasurementComplete: Bool?
    /// Run interrompu prématurément côté serveur : sa fenêtre de mesure n'est
    /// pas représentative — la moyenne serveur ne doit PAS être autoritaire.
    let serverRunTruncated: Bool?

    init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        serverBytesReceived = json.intValue("serverBytesReceived")
        serverDurationMs = json.doubleValue("serverDurationMs")
        serverAvgMbps = json.doubleValue("serverAvgMbps")
        serverP90Mbps = json.doubleValue("serverP90Mbps")
        serverP95Mbps = json.doubleValue("serverP95Mbps")
        serverPeakMbps = json.doubleValue("serverPeakMbps")
        serverMeasuredWindows = json.intValue("serverMeasuredWindows")
        serverMeasurementComplete = json.boolValue("serverMeasurementComplete")
        serverRunTruncated = json.boolValue("serverRunTruncated")
    }

    func isUsable(expectedUsefulDurationMs: Double) -> Bool {
        guard let bytes = serverBytesReceived, bytes > 0,
              let duration = serverDurationMs, duration >= expectedUsefulDurationMs * 0.7,
              let average = serverAvgMbps, average.isFinite, average > 0 else {
            return false
        }
        if let windows = serverMeasuredWindows, windows <= 0 {
            return false
        }
        // Respect de `serverRunTruncated` (ignoré auparavant) : un run tronqué
        // retombe sur le calcul client borné par les octets confirmés.
        if serverRunTruncated == true {
            return false
        }
        return true
    }
}

/// Thread-safe byte counter for URLSession delegate callbacks. Delegates are
/// synchronous callbacks, so an actor would add avoidable scheduling overhead
/// on fast links.
final class SpeedtestSyncByteCounter: @unchecked Sendable {
    struct Snapshot: Sendable { let total: Int; let grace: Int }

    private let lock = NSLock()
    private var total: Int = 0
    private var grace: Int = 0

    func add(_ count: Int, isGrace: Bool) {
        let safeCount = max(0, count)
        guard safeCount > 0 else { return }
        lock.lock()
        total += safeCount
        if isGrace { grace += safeCount }
        lock.unlock()
    }

    func add(total count: Int, grace graceCount: Int) {
        let safeCount = max(0, count)
        guard safeCount > 0 else { return }
        lock.lock()
        total += safeCount
        grace += max(0, min(safeCount, graceCount))
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(total: total, grace: grace)
        lock.unlock()
        return snapshot
    }
}

/// Fenêtre temporelle ADAPTATIVE d'une phase de mesure : la grace (warm-up)
/// démarre à sa valeur de base et peut être étendue UNE seule fois, avant son
/// expiration, quand le lien est encore en slow-start à la frontière (liens
/// rapides). L'échéance de la phase glisse du même délai pour préserver la
/// durée utile de mesure. Thread-safe : lue depuis les callbacks URLSession et
/// les boucles de streams, étendue depuis la tâche de progression.
final class SpeedtestAdaptivePhaseWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var graceMsValue: Double
    private var deadlineValue: Date
    private var extended = false

    init(graceMs: Double, deadline: Date) {
        self.graceMsValue = graceMs
        self.deadlineValue = deadline
    }

    var graceMs: Double { lock.withLock { graceMsValue } }
    var deadline: Date { lock.withLock { deadlineValue } }
    var wasExtended: Bool { lock.withLock { extended } }

    /// Étend la grace à `newGraceMs` et repousse l'échéance du même délai.
    /// Sans effet (renvoie false) si déjà étendue, si la frontière de grace est
    /// déjà passée (`elapsedMs`), ou si la nouvelle valeur ne l'allonge pas —
    /// une extension tardive fausserait le marquage grace/utile des octets.
    @discardableResult
    func extendGrace(to newGraceMs: Double, ifNotPastMs elapsedMs: Double) -> Bool {
        lock.withLock {
            guard !extended, elapsedMs < graceMsValue, newGraceMs > graceMsValue else { return false }
            deadlineValue = deadlineValue.addingTimeInterval((newGraceMs - graceMsValue) / 1_000)
            graceMsValue = newGraceMs
            extended = true
            return true
        }
    }
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

private extension Dictionary where Key == String, Value == Any {
    func intValue(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? String { return Int(value) }
        return nil
    }

    func doubleValue(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? Int { return Double(value) }
        if let value = self[key] as? String { return Double(value) }
        return nil
    }

    func boolValue(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? String {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return nil
    }
}

/// Tracks the global byte total and the bytes received during the grace window
/// so we can subtract them at the end.
actor SpeedtestByteCounter {
    struct Snapshot: Sendable { let total: Int; let grace: Int }
    private var total: Int = 0
    private var grace: Int = 0

    func add(_ count: Int, isGrace: Bool) {
        total += count
        if isGrace { grace += count }
    }

    func add(total count: Int, grace graceCount: Int) {
        total += max(0, count)
        grace += max(0, min(count, graceCount))
    }

    func snapshot() -> Snapshot { Snapshot(total: total, grace: grace) }
}

/// Collected (start, end, bytes) samples used to derive p90 / p95 / peak via
/// 1-second windows post-test, mirroring `measuredThroughputWindows` on
/// Android.
actor SpeedtestSamplesBox {
    struct Sample: Sendable { let startMs: Double; let endMs: Double; let bytes: Int }
    private var samples: [Sample] = []

    func append(start: Double, end: Double, bytes: Int) {
        samples.append(Sample(startMs: start, endMs: end, bytes: bytes))
    }

    struct PublicStats: Sendable {
        let p90: Double?
        let p95: Double?
        let peak: Double
        let windowCount: Int
        let seriesMbps: [Double]
    }

    func publicStats(windowMs: Double, graceMs: Double, endMs: Double) -> PublicStats {
        guard endMs > graceMs else { return PublicStats(p90: nil, p95: nil, peak: 0, windowCount: 0, seriesMbps: []) }
        var windowSpeeds: [Double] = []
        var windowIndex = 0
        while true {
            let windowStart = graceMs + Double(windowIndex) * windowMs
            let windowEnd = windowStart + windowMs
            if windowStart >= endMs { break }
            var bytesInWindow = 0
            for sample in samples {
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

/// Simple monotonic stall detector: aborts the attempt when the total byte
/// counter has not progressed for `timeoutMs` after the grace period.
actor SpeedtestStallMonitor {
    private let timeoutMs: Double
    private var lastBytes: Int = 0
    private var lastProgressAtMs: Double = 0
    var stalled: Bool = false

    init(timeoutMs: Double) { self.timeoutMs = timeoutMs }

    func observe(elapsedMs: Double, totalBytes: Int) {
        if totalBytes > lastBytes {
            lastBytes = totalBytes
            lastProgressAtMs = elapsedMs
            stalled = false
            return
        }
        if lastProgressAtMs == 0 {
            lastProgressAtMs = elapsedMs
            return
        }
        if elapsedMs - lastProgressAtMs > timeoutMs {
            stalled = true
        }
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
