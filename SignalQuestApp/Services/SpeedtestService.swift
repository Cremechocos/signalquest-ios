import Foundation
import CoreLocation
import Network
import os
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
    let stage: String?
    let usefulElapsedSeconds: Double?
    let totalElapsedSeconds: Double?

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
        notice: String? = nil,
        stage: String? = nil,
        usefulElapsedSeconds: Double? = nil,
        totalElapsedSeconds: Double? = nil
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
        self.stage = stage
        self.usefulElapsedSeconds = usefulElapsedSeconds
        self.totalElapsedSeconds = totalElapsedSeconds ?? SpeedtestTraceScope.current.map { speedtestMonotonicSeconds() - $0.origin }
    }
}

typealias SpeedtestProgressHandler = @Sendable (SpeedtestLiveProgress) -> Void

protocol SpeedtestTCPProbing: Sendable {
    func connectLatencyMs(host: String, port: UInt16, timeoutSeconds: TimeInterval) async throws -> Double
}

struct NetworkSpeedtestTCPProbe: SpeedtestTCPProbing {
    /// File PARTAGÉE. Une file par sonde faisait payer à chaque échantillon la
    /// création d'une queue et l'ordonnancement d'un fil — du bruit pur ajouté à une
    /// mesure de latence.
    private static let probeQueue = DispatchQueue(label: "fr.signalquest.speedtest.tcp")

    /// ⚠️ `host` doit être une ADRESSE IP déjà résolue, pas un nom.
    /// `NWEndpoint.Host(name)` déclenche une résolution DNS à l'intérieur de la fenêtre
    /// chronométrée : c'est l'une des causes du ping surévalué. Les appelants résolvent
    /// une fois par série (`ICMPPinger.resolve`) et passent l'adresse.
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
            let queue = Self.probeQueue
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? .https,
                using: .tcp
            )
            // Le chronomètre démarre au plus près de `start()`. Il englobait auparavant
            // la construction de `NWConnection` ET la création d'une `DispatchQueue`
            // neuve à chaque sonde — quelques millisecondes ajoutées à CHAQUE
            // échantillon, sur une grandeur qui en vaut vingt.
            let start = speedtestMonotonicSeconds()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = (speedtestMonotonicSeconds() - start) * 1_000
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
    /// Part de la durée utile couverte par la fenêtre du débit crête (30 %).
    ///
    /// Même définition que nPerf : « le débit crête correspond à la moyenne de la
    /// meilleure fenêtre sur 30 % de la durée du test ». Ne sert QU'AU pic —
    /// p90/p95 et la série du graphe restent en fenêtres d'1 s, changer leur
    /// largeur modifierait silencieusement d'autres champs publiés.
    static let peakWindowRatio: Double = 0.30
    /// Hard cap on parallel streams (download reverse).
    static let hardMaxStreams: Int = 16
    /// Upload : aligné sur le descendant et sur Android, qui monte à 16 depuis
    /// toujours — l'écart rendait les débits montants des deux apps incomparables.
    static let hardMaxUploadStreams: Int = 16
    /// Palier INTERMÉDIAIRE, et non un simple second essai.
    ///
    /// 16 flux × 12 blocs en vol provoquent des RST sur certains POP publics
    /// (Scaleway, Bouygues) et sur la montée cellulaire : c'est ce qui avait fait
    /// plafonner iOS à 8. Le repli doit donc repasser par 8 — valeur éprouvée en
    /// production — avant de descendre à 4. Sans ce palier, un POP qui refuse 16 flux
    /// tomberait droit à 4 et SOUS-mesurerait, soit l'inverse de l'effet recherché.
    static let uploadFallbackStreams: Int = 8
    /// Dernier essai UL quand même 8 flux échouent.
    static let uploadRetryStreams: Int = 4

    static func uploadStreamLadder(requested: Int) -> [Int] {
        speedtestUploadStreamLadder(
            requested: requested,
            hardMax: hardMaxUploadStreams,
            fallback: uploadFallbackStreams,
            last: uploadRetryStreams
        )
    }
    /// Petite pause entre DL et UL pour laisser le démon iPerf libérer le port.
    static let interPhaseDelayMs: Double = 300
    /// OVH proof : 5201–5210. Bouygues : 9200–9240. Scaleway online.net : 5200–5209.
    static let iperf3PortMin: UInt16 = 5_201
    static let iperf3PortMax: UInt16 = 5_210
    static let bytelIperfPortMin: UInt16 = 9_200
    static let bytelIperfPortMax: UInt16 = 9_240
    static let onlineNetIperfPortMin: UInt16 = 5_200
    static let onlineNetIperfPortMax: UInt16 = 5_209
    /// POP iPerf3 publics FR/EU (vérifiés juil. 2026). Serveurs mono-slot →
    /// enregistrer la plage complète pour laisser le fallback de port éviter les
    /// collisions « BUSY ». Moji expose 41 ports (anti-collision), les autres 4-10.
    static let mojiIperfPortMin: UInt16 = 5_200
    static let mojiIperfPortMax: UInt16 = 5_240
    static let clouviderIperfPortMin: UInt16 = 5_200
    static let clouviderIperfPortMax: UInt16 = 5_209
    static let leasewebIperfPortMin: UInt16 = 5_201
    static let leasewebIperfPortMax: UInt16 = 5_210
    static let init7IperfPortMin: UInt16 = 5_201
    static let init7IperfPortMax: UInt16 = 5_204
    /// Warm-up jeté par le protocole iPerf3 (`--omit`) : borne HAUTE de la durée
    /// de rampe écartée. Doit couvrir slow-start TCP + BBR STARTUP + remplissage
    /// du buffer, qui dure 2-3 s sur une ligne fibre/5G rapide (≈800 Mbps+) — un
    /// omit de 1 s laissait la rampe plomber la moyenne cumulée des tests courts
    /// (sous-estimation du débit). `--omit` N'AMPUTE PAS la fenêtre mesurée (les
    /// deadlines valent omit + durationSeconds) : on écarte plus de rampe sans
    /// raccourcir la mesure. La valeur effective est calquée sur la durée (2-3 s).
    static let iperf3OmitSeconds: Int = 3
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
            return String(localized: "Impossible de mesurer une latence réseau fiable.")
        case .noServerReachable:
            return String(localized: "Les serveurs speedtest sont occupés ou injoignables depuis ce réseau. Réessaie dans un instant.")
        }
    }
}

/// Mémorise localement une indisponibilité temporaire de l'edge Cloudflare.
///
/// Une rafale ne doit pas réessayer un edge qui vient de répondre 429 ou de
/// s'arrêter sans octet : elle privilégie alors un POP iPerf3 pendant une courte
/// fenêtre. L'état reste volontairement en mémoire (ni préférence, ni donnée
/// métier) et disparaît au redémarrage de l'application.
final class CloudflareAutoFallbackPolicy: @unchecked Sendable {
    static let defaultCooldown: TimeInterval = 90

    private let lock = NSLock()
    private let cooldown: TimeInterval
    private let now: () -> Date
    private var unavailableUntil: Date?

    init(
        cooldown: TimeInterval = CloudflareAutoFallbackPolicy.defaultCooldown,
        now: @escaping () -> Date = Date.init
    ) {
        self.cooldown = max(0, cooldown)
        self.now = now
    }

    func recordTemporaryFailure() {
        lock.lock()
        unavailableUntil = now().addingTimeInterval(cooldown)
        lock.unlock()
    }

    func shouldAvoidCloudflare() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let unavailableUntil else { return false }
        guard now() < unavailableUntil else {
            self.unavailableUntil = nil
            return false
        }
        return true
    }
}

/// Erreur typée uniquement le temps de sortir du moteur Cloudflare. Elle évite
/// de confondre une indisponibilité du fournisseur avec un échec du réseau de
/// l'utilisateur et permet au mode Auto de changer de serveur une seule fois.
private struct CloudflareSpeedtestFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

// MARK: - Service implementation

final class SpeedtestService: SpeedtestServicing, @unchecked Sendable {
    private let api: APIClient
    private let markets: MarketRegistryServicing
    private let networkOperator: NetworkOperatorServicing
    private let historyCache: DiskCache
    private let legacyHistoryCache = DiskCache(folderName: "SignalQuestSpeedtestHistory")
    private let pendingStore: SpeedtestPendingStoring
    private let guestReceiptStore: GuestSpeedtestReceiptStore
    private let tcpProbe: SpeedtestTCPProbing
    private let cloudflareFallbackPolicy: CloudflareAutoFallbackPolicy
    static let pendingSaveKey = "pending-speedtest-saves"
    /// Dossier de la file d'attente durable (partagé entre l'init durable et la migration).
    /// `internal` (pas `private`) : référencé dans une valeur par défaut d'initialiseur.
    static let pendingFolderName = "SignalQuestSpeedtestPending"

    init(
        api: APIClient,
        markets: MarketRegistryServicing? = nil,
        networkOperator: NetworkOperatorServicing? = nil,
        historyCache: DiskCache = DiskCache(folderName: "SignalQuestSpeedtestHistory",
            baseDirectory: .applicationSupportDirectory, evicts: false,
            fileProtection: .completeUntilFirstUserAuthentication),
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
        tcpProbe: SpeedtestTCPProbing = NetworkSpeedtestTCPProbe(),
        cloudflareFallbackPolicy: CloudflareAutoFallbackPolicy = CloudflareAutoFallbackPolicy(),
        pendingStore: SpeedtestPendingStoring? = nil
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
        self.pendingStore = pendingStore ?? SpeedtestPendingStoreFactory.make(durableCache: pendingCache, key: Self.pendingSaveKey)
        self.guestReceiptStore = guestReceiptStore
        self.tcpProbe = tcpProbe
        self.cloudflareFallbackPolicy = cloudflareFallbackPolicy
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
        let recorder = SpeedtestTraceRecorder()
        return try await SpeedtestTraceScope.$current.withValue(recorder) {
            try await runScoped(pathStatus: pathStatus, location: location, settings: settings, progress: progress)
        }
    }

    private func runScoped(pathStatus: NetworkPathStatus, location: Coordinates?, settings: SpeedtestRunSettings,
                           progress: SpeedtestProgressHandler?) async throws -> SpeedtestRunResult {
        let forceIPerfForCloudflareFallback =
            settings.downloadTarget.migrated == .hybridAuto &&
            cloudflareFallbackPolicy.shouldAvoidCloudflare()
        do {
            return try await runAttempt(
                pathStatus: pathStatus,
                location: location,
                settings: settings,
                progress: progress,
                forceIPerfForCloudflareFallback: forceIPerfForCloudflareFallback
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CloudflareSpeedtestFailure {
            cloudflareFallbackPolicy.recordTemporaryFailure()
            // Le mode Auto est le seul que l'on réoriente sans demander : un
            // serveur Cloudflare choisi explicitement reste un choix explicite.
            guard settings.downloadTarget.migrated == .hybridAuto,
                  !forceIPerfForCloudflareFallback else {
                throw error
            }
            sqDebugLog("SQ_CLOUDFLARE indisponible — relance Auto via iPerf3")
            return try await runAttempt(
                pathStatus: pathStatus,
                location: location,
                settings: settings,
                progress: progress,
                forceIPerfForCloudflareFallback: true
            )
        }
    }

    /// Un run complet. Le wrapper public peut l'appeler une seconde fois après
    /// une erreur Cloudflare, mais jamais plus : pas de boucle de repli.
    private func runAttempt(
        pathStatus: NetworkPathStatus,
        location: Coordinates?,
        settings: SpeedtestRunSettings,
        progress: SpeedtestProgressHandler?,
        forceIPerfForCloudflareFallback: Bool
    ) async throws -> SpeedtestRunResult {
        let startedAt = SpeedtestTraceScope.current?.startedAt ?? Date()
        // Vide la mémoire des sondages de ports si le réseau n'est plus le même :
        // un serveur injoignable en 4G peut répondre en WiFi, et inversement.
        await IPerfEndpointCache.shared.invalidateIfNetworkChanged(
            "\(pathStatus.connection.rawValue)|\(pathStatus.operatorName ?? "?")|\(pathStatus.operatorMcc ?? 0)"
        )
        let durationSeconds = max(5, min(settings.durationSeconds, 30))
        // Omit adaptatif 2-3 s (jamais plus que `iperf3OmitSeconds`, jamais moins
        // de 2 s) : écarte la rampe TCP/BBR sans raccourcir la fenêtre mesurée.
        let omitSeconds = min(SpeedtestEngineConfig.iperf3OmitSeconds, max(2, durationSeconds / 4))
        // Multi-stream is required to saturate 5G / fibre : un seul flux TCP
        // plafonne souvent sous le débit réel du lien.
        let parallelStreams = min(max(settings.streams, 4), SpeedtestEngineConfig.hardMaxStreams)

        // 1. Résoudre la cible : mesure de plusieurs candidats en Auto, choix exact
        // en manuel, puis repli explicite si la cible demandée est indisponible.
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

        // Cible « LibreSpeed » : moteur HTTPS (garbage.php/empty.php) sur le POP
        // LibreSpeed le plus proche — HTTPS pur (ATS OK), licence LGPL propre,
        // aucune contrainte Ookla. Serveurs data-driven (`libreSpeedServers`).
        if settings.downloadTarget == .libreSpeed {
            do {
                return try await runLibreSpeedTest(
                    pathStatus: pathStatus,
                    location: location,
                    durationSeconds: durationSeconds,
                    parallelStreams: parallelStreams,
                    startedAt: startedAt,
                    preferredHost: settings.libreSpeedHost,
                    progress: progress
                )
            } catch is CancellationError {
                throw CancellationError()   // annulation utilisateur : propager
            } catch {
                // Serveur LibreSpeed injoignable / TLS refusé par l'ATS / occupé →
                // repli Cloudflare (HTTPS, résultat garanti), comme le chemin iPerf3.
                // NE PAS gater sur `Task.checkCancellation()` : un échec (même long)
                // ne doit pas empêcher le repli de produire un résultat.
                //
                // MAIS il faut distinguer « le serveur a échoué » de « l'utilisateur a
                // arrêté, ce qui a fait échouer le serveur ». Une annulation ferme les
                // sockets et remonte des erreurs qui ne sont PAS des `CancellationError`
                // (le `catch` ci-dessus ne les attrape donc pas) : sans cette garde, un
                // appui sur « Arrêter » relançait un run Cloudflare complet.
                if Task.isCancelled { throw CancellationError() }
                sqDebugLog("SQ_LIBRESPEED repli Cloudflare : \(error.localizedDescription)")
                return try await runCloudflareTest(
                    pathStatus: pathStatus,
                    location: location,
                    durationSeconds: durationSeconds,
                    parallelStreams: parallelStreams,
                    startedAt: startedAt,
                    progress: progress,
                    notice: "Serveur LibreSpeed injoignable — test via Cloudflare",
                    fallbackReason: "librespeed_failed"
                )
            }
        }

        // Snapshot immuable pour tout le run : un refresh API qui termine pendant
        // le ping ne peut changer ni l'hôte mesuré ni l'id ensuite publié.
        let runCatalogSnapshot = activeIPerfServers
        let migratedTarget = settings.downloadTarget.migrated
        let isAutomatic = migratedTarget == .hybridAuto
        let manualRequestedServerId: String? = {
            guard !isAutomatic else { return nil }
            if migratedTarget == .iperfCatalog {
                let value = settings.iperfServerId?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            }
            return migratedTarget.rawValue
        }()

        let resolvedCandidate: ResolvedIPerfCandidate
        var requestedServerIdForResult: String? = nil
        var manualFallbackNotice: String? = nil

        if isAutomatic {
            // Mesurer plusieurs POPs plausibles et Cloudflare en parallèle évite de
            // confondre proximité géographique et proximité réseau réelle.
            async let candidateTask = resolveAutoIPerfCandidate(
                location: location,
                servers: runCatalogSnapshot
            )
            let cloudflareProbe = forceIPerfForCloudflareFallback ? nil : Task<Double?, Never> {
                try? await tcpProbe.connectLatencyMs(
                    host: CloudflareSpeedtestConfig.host,
                    port: 443,
                    timeoutSeconds: SpeedtestEngineConfig.pingTimeoutSeconds
                )
            }
            let candidate = await candidateTask
            let cloudflareMs = await cloudflareProbe?.value

            guard let candidate else {
                if forceIPerfForCloudflareFallback {
                    throw SpeedtestEngineError.noServerReachable
                }
                return try await runCloudflareTest(
                    pathStatus: pathStatus,
                    location: location,
                    durationSeconds: durationSeconds,
                    parallelStreams: parallelStreams,
                    startedAt: startedAt,
                    progress: progress,
                    notice: "Serveurs iPerf3 injoignables — test via Cloudflare",
                    fallbackReason: "no_iperf_pop"
                )
            }
            if let cloudflareMs,
               cloudflareMs + CloudflareSpeedtestConfig.autoAdvantageMs < (candidate.latencyMs ?? .infinity) {
                return try await runCloudflareTest(
                    pathStatus: pathStatus,
                    location: location,
                    durationSeconds: durationSeconds,
                    parallelStreams: parallelStreams,
                    startedAt: startedAt,
                    progress: progress,
                    notice: nil,
                    fallbackReason: "auto_latency",
                    requestedServerId: candidate.server.id
                )
            }
            resolvedCandidate = candidate
        } else {
            let requestedServer = selectableIPerfServer(
                for: migratedTarget,
                location: location,
                catalogId: settings.iperfServerId,
                servers: runCatalogSnapshot
            )
            if let requestedServer,
               let requestedEndpoint = await resolveIPerfEndpoint(for: requestedServer) {
                resolvedCandidate = ResolvedIPerfCandidate(
                    server: requestedServer,
                    endpoint: requestedEndpoint,
                    latencyMs: nil
                )
            } else {
                let fallback = await resolveAutoIPerfCandidate(
                    location: location,
                    servers: runCatalogSnapshot,
                    excludingHostnames: Set(requestedServer.map { [$0.hostname] } ?? [])
                )
                guard let fallback else {
                    return try await runCloudflareTest(
                        pathStatus: pathStatus,
                        location: location,
                        durationSeconds: durationSeconds,
                        parallelStreams: parallelStreams,
                        startedAt: startedAt,
                        progress: progress,
                        notice: "Serveur iPerf3 sélectionné indisponible — test via Cloudflare",
                        fallbackReason: "no_iperf_pop",
                        requestedServerId: manualRequestedServerId
                    )
                }
                resolvedCandidate = fallback
                requestedServerIdForResult = manualRequestedServerId
                let requestedLabel = requestedServer?.name ?? "Serveur sélectionné"
                manualFallbackNotice = "\(requestedLabel) injoignable — test sur \(fallback.server.name)"
            }
        }

        let iperfServer = resolvedCandidate.server
        let endpoint = resolvedCandidate.endpoint
        var port = endpoint.port
        let serverName = iperfServer.name

        if let manualFallbackNotice {
            progress?(SpeedtestLiveProgress(
                phase: .ping,
                fraction: 0,
                serverName: serverName,
                notice: manualFallbackNotice
            ))
        }
        if forceIPerfForCloudflareFallback {
            progress?(SpeedtestLiveProgress(
                phase: .ping,
                fraction: 0,
                serverName: serverName,
                notice: "Cloudflare temporairement indisponible — test via \(serverName)"
            ))
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
        progress?(SpeedtestLiveProgress(phase: .download, fraction: 0, serverName: serverName, stage: "preparation", usefulElapsedSeconds: 0))

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
        // `nil` = la plage ne permet pas d'éviter le port de données (POP mono-port) :
        // on renonce à l'échantillon plutôt que de faire tomber le démon en pleine mesure.
        let dlLoadedPort = iperfLoadedLatencyProbePort(
            avoiding: [port],
            min: iperfServer.portMin,
            max: iperfServer.portMax
        )
        let dlLoadedOmit = omitSeconds
        let dlLoadedDeadline = speedtestMonotonicSeconds() + (Double(omitSeconds + durationSeconds) + 2)
        let dlLoadedProbe = tcpProbe
        let dlLoadedPingsTask = Task.detached(priority: .utility) {
            guard let dlLoadedPort else { return [Double]() }
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
                if let interval = dlState.interval(bytes: bytes, time: elapsedMs) {
                    dlSamplesBox.append(start: interval.start, end: interval.end, bytes: interval.bytes)
                    dlGraphBox.append(start: omitMs + interval.start, end: omitMs + interval.end, bytes: interval.bytes)
                }
                progress?(SpeedtestLiveProgress(
                    phase: .download,
                    currentMbps: needleMbps,
                    fraction: min(1, elapsed / usefulDuration),
                    downloadLiveMbps: needleMbps,
                    downloadAverageMbps: averageMbps,
                    serverName: serverName,
                    stage: "measurement", usefulElapsedSeconds: elapsed
                ))
            },
            onWarmup: { @Sendable rawBytes, wallSeconds in
                let wallMs = wallSeconds * 1000.0
                dlOmitBridge.capture(rawBytes: rawBytes, rawMs: wallMs)
                // Rampe réelle enregistrée pour la courbe (segment de grâce).
                if let interval = dlGraphWarmupState.interval(bytes: rawBytes, time: wallMs) {
                    dlGraphBox.append(start: interval.start, end: interval.end, bytes: interval.bytes)
                }
                let needleMbps = dlLiveSampler.observe(totalBytes: rawBytes, elapsedMs: wallMs)
                progress?(SpeedtestLiveProgress(
                    phase: .download,
                    currentMbps: needleMbps,
                    fraction: 0,
                    downloadLiveMbps: needleMbps,
                    downloadAverageMbps: 0,
                    serverName: serverName,
                    stage: "warmup", usefulElapsedSeconds: 0
                ))
            },
            onPortAttempt: { @Sendable _, attempt in
                dlSamplesBox.reset(); dlGraphBox.reset(); dlState.reset(); dlGraphWarmupState.reset()
                dlLiveSampler.reset(); dlOmitBridge.reset()
                progress?(SpeedtestLiveProgress(phase: .download, fraction: 0, serverName: serverName, stage: attempt > 0 ? "reconnecting" : "preparation", usefulElapsedSeconds: 0))
            }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Sauvetage : DL iPerf3 impossible sur toute la plage → moteur
            // Cloudflare (résultat complet plutôt qu'une erreur sèche).
            // Sauf si l'utilisateur a arrêté : l'annulation ferme les connexions et
            // remonte ici une erreur qui n'est pas une `CancellationError`.
            if Task.isCancelled { throw CancellationError() }
            if forceIPerfForCloudflareFallback { throw error }
            sqDebugLog("[SpeedtestService] DL iPerf3 KO (\(error.localizedDescription)) — bascule Cloudflare")
            return try await runCloudflareTest(
                pathStatus: pathStatus,
                location: location,
                durationSeconds: durationSeconds,
                parallelStreams: parallelStreams,
                startedAt: startedAt,
                progress: progress,
                notice: "\(serverName) indisponible — test via Cloudflare",
                fallbackReason: "dl_incomplete",
                requestedServerId: requestedServerIdForResult ?? iperfServer.id
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
            // Piège : un DL ARRÊTÉ par l'utilisateur est lui aussi « quasi vide ». Sans
            // cette garde, appuyer sur « Arrêter » pendant le download déclenchait un
            // run Cloudflare complet — exactement l'inverse de ce qui est demandé.
            if Task.isCancelled { throw CancellationError() }
            if forceIPerfForCloudflareFallback {
                throw SpeedtestEngineError.noServerReachable
            }
            sqDebugLog("[SpeedtestService] DL iPerf3 incomplet (\(dlResult.measuredBytes) octets) — bascule Cloudflare")
            return try await runCloudflareTest(
                pathStatus: pathStatus,
                location: location,
                durationSeconds: durationSeconds,
                parallelStreams: parallelStreams,
                startedAt: startedAt,
                progress: progress,
                notice: "\(serverName) indisponible — test via Cloudflare",
                fallbackReason: "dl_incomplete",
                requestedServerId: requestedServerIdForResult ?? iperfServer.id
            )
        }

        // Les samples live sont déjà post-omit (progress ne pousse que la phase utile).
        let dlStats = dlSamplesBox.publicStats(
            windowMs: SpeedtestEngineConfig.publicPeakWindowMs,
            graceMs: 0,
            endMs: max(dlResult.measuredDuration, 0.001) * 1_000
        )
        let dlAverageMbps = dlResult.averageMbps
        let dlPeakMbps = dlSamplesBox.nperfPeakMbps(
            usefulDurationMs: max(dlResult.measuredDuration, 0.001) * 1_000,
            flooredAt: dlAverageMbps
        )

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
        progress?(SpeedtestLiveProgress(phase: .upload, fraction: 0, serverName: serverName, stage: "preparation", usefulElapsedSeconds: 0))

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
        let ulStreamAttempts = SpeedtestEngineConfig.uploadStreamLadder(requested: parallelStreams)
        // Loaded pings sur un 3e port si possible, jamais le port d'upload actif.
        let ulLoadedHost = iperfServer.hostname
        // Deux ports de données sont occupés à ce stade (celui du DL et celui de l'UL) :
        // la sonde doit les éviter tous les deux, et renoncer si la plage ne le permet pas.
        let ulLoadedPort = endpoint.openPorts.first(where: { $0 != port && $0 != ulPreferredPort })
            ?? iperfLoadedLatencyProbePort(
                avoiding: [port, ulPreferredPort],
                min: iperfServer.portMin,
                max: iperfServer.portMax
            )
        let ulLoadedOmit = omitSeconds
        let ulLoadedDeadline = speedtestMonotonicSeconds() + (Double(omitSeconds + durationSeconds) + 3)
        let ulLoadedProbe = tcpProbe
        let ulLoadedPingsTask = Task.detached(priority: .utility) {
            guard let ulLoadedPort else { return [Double]() }
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
                            if let interval = ulState.interval(bytes: bytes, time: elapsedMs) {
                                ulSamplesBox.append(start: interval.start, end: interval.end, bytes: interval.bytes)
                                ulGraphBox.append(start: omitMs + interval.start, end: omitMs + interval.end, bytes: interval.bytes)
                            }
                            progress?(SpeedtestLiveProgress(
                                phase: .upload,
                                currentMbps: needleMbps,
                                fraction: min(1, elapsed / usefulDuration),
                                uploadLiveMbps: needleMbps,
                                uploadAverageMbps: averageMbps,
                                serverName: serverName,
                                stage: "measurement", usefulElapsedSeconds: elapsed
                            ))
                        },
                        onWarmup: { @Sendable rawBytes, wallSeconds in
                            let wallMs = wallSeconds * 1000.0
                            ulOmitBridge.capture(rawBytes: rawBytes, rawMs: wallMs)
                            if let interval = ulGraphWarmupState.interval(bytes: rawBytes, time: wallMs) {
                                ulGraphBox.append(start: interval.start, end: interval.end, bytes: interval.bytes)
                            }
                            let needleMbps = ulLiveSampler.observe(totalBytes: rawBytes, elapsedMs: wallMs)
                            progress?(SpeedtestLiveProgress(
                                phase: .upload,
                                currentMbps: needleMbps,
                                fraction: 0,
                                uploadLiveMbps: needleMbps,
                                uploadAverageMbps: 0,
                                serverName: serverName,
                                stage: "warmup", usefulElapsedSeconds: 0
                            ))
                        },
                        onPortAttempt: { @Sendable _, attempt in
                            ulSamplesBox.reset(); ulGraphBox.reset(); ulState.reset(); ulGraphWarmupState.reset()
                            ulLiveSampler.reset(); ulOmitBridge.reset()
                            progress?(SpeedtestLiveProgress(phase: .upload, fraction: 0, serverName: serverName, stage: attempt > 0 ? "reconnecting" : "preparation", usefulElapsedSeconds: 0))
                        }
                    )
                    port = ulPort
                    if ulResult.measuredBytes > 100_000, ulResult.measuredDuration >= 1.0 {
                        ulStats = ulSamplesBox.publicStats(
                            windowMs: SpeedtestEngineConfig.publicPeakWindowMs,
                            graceMs: 0,
                            endMs: max(ulResult.clientDuration, 0.001) * 1_000
                        )
                        let ulGraceSeries = ulGraphBox.publicStats(
                            windowMs: SpeedtestEngineConfig.graphWindowMs,
                            graceMs: 0,
                            endMs: omitMs
                        ).seriesMbps
                        let ulUsefulSeries = ulGraphBox.publicStats(
                            windowMs: SpeedtestEngineConfig.graphWindowMs,
                            graceMs: omitMs,
                            endMs: omitMs + max(ulResult.clientDuration, 0.001) * 1_000
                        ).seriesMbps
                        ulGraphSeries = ulGraceSeries + ulUsefulSeries
                        ulGraceCount = ulGraceSeries.count
                        ulAverageMbps = ulResult.averageMbps
                        ulPeakMbps = ulSamplesBox.nperfPeakMbps(
                            usefulDurationMs: max(ulResult.clientDuration, 0.001) * 1_000,
                            flooredAt: SpeedMetricCalculator.mbps(bytes: ulResult.clientBytes, seconds: ulResult.clientDuration)
                        )
                        uploadSource = ulResult.serverBytesUsed ? "server-received" : "client-written"
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
            // L'id de catalogue, pas une chaîne dérivée de l'hôte : c'est lui qui
            // part en base et il doit être comparable à celui d'Android. La forme
            // « iperf3_<host>:<port> » publiée jusqu'ici rendait tout regroupement
            // par POP impossible, et écrasait `downloadServerCode` — censé porter le
            // code POP (RBX, PAR-BBR) — avec un numéro de port. L'hôte et le port
            // ont désormais leurs propres champs.
            downloadServerId: iperfServer.id,
            downloadServerCode: iperfServer.code,
            downloadServerHost: iperfServer.hostname,
            downloadServerPort: Int(dlPort),
            engine: "iperf3",
            engineFallbackReason: forceIPerfForCloudflareFallback
                ? "cloudflare_temporarily_unavailable"
                : nil,
            requestedServerId: forceIPerfForCloudflareFallback
                ? SpeedtestDownloadTarget.cloudflare.rawValue
                : requestedServerIdForResult,
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
            jitterUlMs: jitterUlMs,
            pingServerHost: iperfServer.hostname,
            pingServerPort: pingOutcome.protocolName == "TCP" ? Int(endpoint.port) : nil,
            uploadServerHost: ulAverageMbps == nil ? nil : iperfServer.hostname,
            uploadServerPort: ulAverageMbps == nil ? nil : Int(port)
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

    private struct ResolvedIPerfCandidate: Sendable {
        let server: IPerfPublicServer
        let endpoint: IPerfEndpoint
        let latencyMs: Double?
    }

    private struct ReachableIPerfObservation: Sendable {
        let candidate: IPerfLatencyCandidate
        let endpoint: IPerfEndpoint
    }

    /// Découvre puis mesure le port réellement joignable de quatre POPs au plus.
    private func resolveAutoIPerfCandidate(
        location: Coordinates?,
        servers: [IPerfPublicServer],
        excludingHostnames: Set<String> = []
    ) async -> ResolvedIPerfCandidate? {
        let shortlist = iperfAutoCandidateShortlist(
            from: location,
            servers: servers,
            limit: 4,
            excludingHostnames: excludingHostnames
        )
        guard !shortlist.isEmpty else { return nil }

        let probe = tcpProbe
        let reachable = await withTaskGroup(of: ReachableIPerfObservation?.self) { group in
            for (index, server) in shortlist.enumerated() {
                group.addTask {
                    guard let endpoint = await resolveIPerfEndpoint(for: server) else {
                        return nil
                    }
                    let latency = try? await probe.connectLatencyMs(
                        host: server.hostname,
                        port: endpoint.port,
                        timeoutSeconds: SpeedtestEngineConfig.pingTimeoutSeconds
                    )
                    return ReachableIPerfObservation(
                        candidate: IPerfLatencyCandidate(
                            server: server,
                            latencyMs: latency,
                            sourceOrder: index
                        ),
                        endpoint: endpoint
                    )
                }
            }
            var values: [ReachableIPerfObservation] = []
            values.reserveCapacity(shortlist.count)
            for await observation in group {
                if let observation { values.append(observation) }
            }
            return values
        }

        var endpointByServer: [String: IPerfEndpoint] = [:]
        for observation in reachable {
            endpointByServer[observation.candidate.server.id] = observation.endpoint
        }
        for observation in rankIPerfLatencyCandidates(reachable.map(\.candidate)) {
            guard !Task.isCancelled else { return nil }
            let server = observation.server
            guard let endpoint = endpointByServer[server.id] else { continue }
            let measuredLatency = observation.latencyMs
            let latencyLabel = measuredLatency.map { String(format: "%.1f", $0) } ?? "--"
            sqDebugLog(
                "SQ_SPEEDTEST Auto candidat \(server.id): " +
                    "latence=\(latencyLabel) ms, port=\(endpoint.port)"
            )
            return ResolvedIPerfCandidate(
                server: server,
                endpoint: endpoint,
                latencyMs: measuredLatency
            )
        }
        return nil
    }

    /// Sorties communes des moteurs de mesure (iPerf3 / Cloudflare),
    /// consommées par `finalizeRun` pour l'assemblage du résultat.
    private struct EngineMeasurements: Sendable {
        let serverName: String
        let downloadServerId: String
        let downloadServerCode: String
        /// Hôte et port RÉELLEMENT mesurés. `downloadServerId` étant un alias de
        /// catalogue, sans eux il est impossible de savoir a posteriori quel POP —
        /// et sur quel port, le port-walk le faisant varier — a produit la mesure.
        let downloadServerHost: String?
        let downloadServerPort: Int?
        /// Moteur ayant RÉELLEMENT produit la mesure, et pourquoi il diffère de la
        /// cible demandée le cas échéant. Sans eux, un run iPerf3 et un run replié
        /// sur Cloudflare arrivent indiscernables en base : impossible de mesurer
        /// le taux de bascule, donc de vérifier qu'on l'a fait baisser.
        let engine: String
        let engineFallbackReason: String?
        let requestedServerId: String?
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
        var pingServerHost: String? = nil
        var pingServerPort: Int? = nil
        var uploadServerHost: String? = nil
        var uploadServerPort: Int? = nil
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
        let duration = SpeedtestTraceScope.current.map { speedtestMonotonicSeconds() - $0.origin } ?? Date().timeIntervalSince(startedAt)
        progress?(SpeedtestLiveProgress(phase: .saving, downloadAverageMbps: m.downloadAverageMbps,
            uploadAverageMbps: m.uploadAverageMbps, serverName: m.serverName, stage: "finalizing"))
        let info: RunContextInfo
        if let context {
            info = await context.value
        } else {
            info = await resultContextTask(pathStatus: pathStatus, location: location).value
        }
        let resolvedPlace = info.place
        let wifiSSID = info.wifiSSID
        let operatorContext = info.operatorContext
        let trace = SpeedtestTraceScope.current?.snapshot(retainingUpload: m.uploadAverageMbps != nil)

        let result = SpeedtestRunResult(
            id: SpeedtestTraceScope.current?.runId ?? UUID(),
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
            networkOperatorName: operatorContext.mobileOperator,
            networkOperatorMcc: operatorContext.mcc,
            networkOperatorMnc: operatorContext.mnc,
            observedPlmn: nil,
            simPlmn: operatorContext.simPlmn,
            isRoaming: nil,
            networkIdentitySource: nil,
            radioEvidence: SpeedtestRadioEvidence.technologySnapshot(
                technology: pathStatus.cellularTechnology,
                observedAt: startedAt,
                location: location
            ),
            marketCode: operatorContext.marketCode,
            operatorKey: operatorContext.operatorKey,
            carrierName: pathStatus.operatorName,
            mvnoKey: nil,
            mvnoName: nil,
            wifiSSID: wifiSSID,
            city: resolvedPlace.city,
            address: resolvedPlace.address,
            coordinate: location,
            serverName: m.serverName,
            downloadServerName: m.serverName,
            downloadServerId: m.downloadServerId,
            downloadServerCode: m.downloadServerCode,
            downloadServerHost: m.downloadServerHost,
            downloadServerPort: m.downloadServerPort,
            engine: m.engine,
            engineFallbackReason: m.engineFallbackReason,
            requestedServerId: m.requestedServerId,
            createdAt: startedAt,
            downloadSeriesMbps: trace?.phases.first(where: { $0.phase == "download" })?.recentSeries.map(\.mbps) ?? m.downloadSeriesMbps,
            uploadSeriesMbps: trace?.phases.first(where: { $0.phase == "upload" })?.recentSeries.map(\.mbps) ?? m.uploadSeriesMbps,
            downloadGraceWindowCount: trace == nil && m.downloadGraceWindowCount > 0 ? m.downloadGraceWindowCount : nil,
            uploadGraceWindowCount: trace == nil && m.uploadGraceWindowCount > 0 ? m.uploadGraceWindowCount : nil,
            uploadMeasurementSource: m.uploadMeasurementSource,
            deviceModel: AppleDeviceDescriptor.currentShareModelName,
            osVersion: AppleDeviceDescriptor.currentOSVersionLabel,
            measurementTrace: trace,
            methodologyVersion: 6,
            ownerScopeId: SpeedtestTraceScope.current?.ownerScopeId,
            pingServerHost: m.pingServerHost,
            pingServerPort: m.pingServerPort,
            uploadServerHost: m.uploadServerHost,
            uploadServerPort: m.uploadServerPort
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
            pingFinalMs: result.primaryPingMs,
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
        notice: String?,
        fallbackReason: String? = nil,
        requestedServerId: String? = nil
    ) async throws -> SpeedtestRunResult {
        do {
            return try await runCloudflareTestAttempt(
                pathStatus: pathStatus,
                location: location,
                durationSeconds: durationSeconds,
                parallelStreams: parallelStreams,
                startedAt: startedAt,
                progress: progress,
                notice: notice,
                fallbackReason: fallbackReason,
                requestedServerId: requestedServerId
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudflareSpeedtestFailure(message: error.localizedDescription)
        }
    }

    private func runCloudflareTestAttempt(
        pathStatus: NetworkPathStatus,
        location: Coordinates?,
        durationSeconds: Int,
        parallelStreams: Int,
        startedAt: Date,
        progress: SpeedtestProgressHandler?,
        notice: String?,
        /// Code stable de la raison du repli — le `notice` est destiné à l'écran,
        /// celui-ci aux agrégats. Voir l'enum côté serveur (`speedtestSchema`).
        fallbackReason: String? = nil,
        /// Cible demandée AVANT bascule : `downloadServerId` porte celle obtenue.
        requestedServerId: String? = nil
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
        progress?(SpeedtestLiveProgress(phase: .download, fraction: 0, serverName: serverName, stage: "preparation", usefulElapsedSeconds: 0))
        let usefulDuration = Double(durationSeconds)
        let dlSamplesBox = SpeedtestSamplesBox()
        let dlLiveSampler = SpeedtestLiveSampler()
        let dlState = ProgressState()
        let dlLoadedDeadline = speedtestMonotonicSeconds() + (usefulDuration + 1)
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
                if let interval = dlState.interval(bytes: bytes, time: elapsedMs) {
                    dlSamplesBox.append(start: interval.start, end: interval.end, bytes: interval.bytes)
                }
                progress?(SpeedtestLiveProgress(
                    phase: .download,
                    currentMbps: needleMbps,
                    fraction: min(1, elapsed / usefulDuration),
                    downloadLiveMbps: needleMbps,
                    downloadAverageMbps: averageMbps,
                    serverName: serverName,
                    stage: "measurement", usefulElapsedSeconds: elapsed
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
        let dlPeakMbps = dlSamplesBox.nperfPeakMbps(
            usefulDurationMs: max(dlOutcome.duration, 0.001) * 1_000,
            flooredAt: dlAverageMbps
        )

        // 3. Upload — best effort, le DL seul reste un résultat valide.
        progress?(SpeedtestLiveProgress(phase: .upload, fraction: 0, serverName: serverName, stage: "preparation", usefulElapsedSeconds: 0))

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

        let ulLoadedDeadline = speedtestMonotonicSeconds() + (usefulDuration + 1)
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
                if let interval = ulState.interval(bytes: bytes, time: elapsedMs) {
                    ulSamplesBox.append(start: interval.start, end: interval.end, bytes: interval.bytes)
                }
                progress?(SpeedtestLiveProgress(
                    phase: .upload,
                    currentMbps: needleMbps,
                    fraction: min(1, elapsed / usefulDuration),
                    uploadLiveMbps: needleMbps,
                    uploadAverageMbps: averageMbps,
                    serverName: serverName,
                    stage: "measurement", usefulElapsedSeconds: elapsed
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
            ulPeakMbps = ulSamplesBox.nperfPeakMbps(
                usefulDurationMs: max(ulOutcome.duration, 0.001) * 1_000,
                flooredAt: ulAverageMbps ?? 0
            )
        }

        let measurements = EngineMeasurements(
            serverName: serverName,
            downloadServerId: "cloudflare_\(colo ?? "edge")",
            downloadServerCode: colo ?? "edge",
            downloadServerHost: CloudflareSpeedtestConfig.host,
            downloadServerPort: Int(CloudflareSpeedtestConfig.httpsPort),
            engine: "cloudflare",
            engineFallbackReason: fallbackReason,
            requestedServerId: requestedServerId,
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
            jitterUlMs: jitterUlMs,
            pingServerHost: CloudflareSpeedtestConfig.host,
            pingServerPort: Int(CloudflareSpeedtestConfig.httpsPort),
            uploadServerHost: ulAverageMbps == nil ? nil : CloudflareSpeedtestConfig.host,
            uploadServerPort: ulAverageMbps == nil ? nil : Int(CloudflareSpeedtestConfig.httpsPort)
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
        let recorder = SpeedtestTraceScope.current
        let counter = SafeCounter(onDelta: { bytes in
            recorder?.recordTraffic(phase: direction == .download ? "download" : "upload", bytes: bytes)
        })
        let start = counter.timedSnapshot().timestamp
        let traceSamples = SpeedtestSamplesBox()
        let traceState = ProgressState()
        let attemptId = UUID().uuidString
        let deadline = start + duration
        // Corps UL partagé (Data immuable, copy-on-write → 1 seule allocation).
        let uploadBody = direction == .upload ? Data(count: CloudflareSpeedtestConfig.uploadBytesPerRequest) : Data()

        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { break }
                let snapshot = counter.timedSnapshot()
                let elapsed = snapshot.timestamp - start
                if let interval = traceState.interval(bytes: snapshot.bytes, time: elapsed * 1000) {
                    traceSamples.append(start: interval.start, end: interval.end, bytes: interval.bytes)
                }
                onProgress(snapshot.bytes, elapsed)
                if elapsed >= duration { _ = counter.close(); break }
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
                    while speedtestMonotonicSeconds() < deadline, !Task.isCancelled {
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
                            if Task.isCancelled || speedtestMonotonicSeconds() >= deadline { break }
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
        await ticker.value
        let final = counter.close()
        if let interval = traceState.interval(bytes: final.bytes, time: (final.timestamp - start) * 1000) {
            traceSamples.append(start: interval.start, end: interval.end, bytes: interval.bytes)
        }
        recorder?.retain(phase: direction == .download ? "download" : "upload", id: attemptId,
            start: start, baseline: start, end: final.timestamp, measuredBytes: final.bytes,
            totalBytes: counter.trafficValue, source: direction == .download ? "client-received" : "client-written",
            samples: traceSamples.snapshotIntervals())
        onProgress(final.bytes, final.timestamp - start)
        return CloudflareTransferOutcome(bytes: final.bytes, duration: max(0.001, final.timestamp - start))
    }

    // MARK: - Moteur LibreSpeed (HTTPS, POP le plus proche)

    /// Test complet via un backend LibreSpeed HTTPS (`garbage.php`/`empty.php`)
    /// sur le POP le plus proche : ping (handshake TCP :443), download, upload,
    /// pings chargés sur le même hôte. Même mécanique URLSession que Cloudflare.
    private func runLibreSpeedTest(
        pathStatus: NetworkPathStatus,
        location: Coordinates?,
        durationSeconds: Int,
        parallelStreams: Int,
        startedAt: Date,
        preferredHost: String? = nil,
        progress: SpeedtestProgressHandler?
    ) async throws -> SpeedtestRunResult {
        // Serveur choisi manuellement (par hostname) sinon le plus proche.
        let server = (preferredHost.flatMap { host in libreSpeedServers.first { $0.hostname == host } })
            ?? nearestLibreSpeedServer(to: location)
        let serverName = server.name
        let dlStreams = min(max(2, parallelStreams), LibreSpeedConfig.maxStreams)
        let ulStreams = min(dlStreams, LibreSpeedConfig.maxUploadStreams)
        let session = makeMeasurementSession(
            maxConnectionsPerHost: dlStreams + 2,
            requestTimeout: Double(durationSeconds) + 15
        )
        defer { session.finishTasksAndInvalidate() }

        // 0. Pré-vol HTTPS (~6 s max) : le handshake TCP du ping ne teste PAS le
        // TLS ; or certains serveurs LibreSpeed passent `curl` mais échouent le TLS
        // de l'ATS iOS (« TLS error »), ou ont un backend mort. On le détecte vite
        // ici — un `garbage.php?ckSize=1` réel doit renvoyer des octets — pour
        // basculer promptement sur le repli Cloudflare (plutôt que 14 s à vide).
        do {
            var preflight = URLRequest(url: server.downloadURL(ckSizeMiB: 1))
            preflight.timeoutInterval = 6
            let (data, response) = try await session.data(for: preflight)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode), !data.isEmpty else {
                throw SpeedtestEngineError.noServerReachable
            }
        } catch {
            sqDebugLog("SQ_LIBRESPEED pré-vol échoué (\(server.hostname)) : \(error.localizedDescription)")
            throw SpeedtestEngineError.noServerReachable
        }

        progress?(SpeedtestLiveProgress(
            phase: .ping, fraction: 0,
            pingSampleTarget: SpeedtestEngineConfig.pingAttemptBudget,
            serverName: serverName
        ))

        // 1. Ping = handshake TCP pur sur :443 (comparable au ping iPerf3/Cloudflare).
        let pingResult = await measureTcpPings(
            host: server.hostname, port: LibreSpeedConfig.httpsPort,
            serverName: serverName, progress: progress, minimumValidSamples: 2
        )
        guard !pingResult.values.isEmpty else { throw SpeedtestEngineError.pingFailed }
        let pingValues = pingResult.values
        let pingValue = SpeedMetricCalculator.average(pingValues)
        let pingMedianValue = SpeedMetricCalculator.median(pingValues)
        let jitterValue = SpeedMetricCalculator.jitter(pingValues)

        // 2. Download.
        progress?(SpeedtestLiveProgress(phase: .download, fraction: 0, serverName: serverName, stage: "preparation", usefulElapsedSeconds: 0))
        let usefulDuration = Double(durationSeconds)
        let dlSamplesBox = SpeedtestSamplesBox()
        let dlLiveSampler = SpeedtestLiveSampler()
        let dlState = ProgressState()
        let lsLoadedProbe = tcpProbe
        let lsHost = server.hostname
        let dlLoadedDeadline = speedtestMonotonicSeconds() + (usefulDuration + 1)
        let dlLoadedTask = Task.detached(priority: .utility) {
            await SpeedtestService.collectIPerfLoadedPings(
                host: lsHost, port: LibreSpeedConfig.httpsPort,
                deadline: dlLoadedDeadline, tcpProbe: lsLoadedProbe
            )
        }
        defer { dlLoadedTask.cancel() }

        let dlOutcome = await measureLibreSpeedTransfer(
            server: server, direction: .download, session: session,
            streams: dlStreams, duration: usefulDuration,
            onProgress: { @Sendable bytes, elapsed in
                let elapsedMs = elapsed * 1000.0
                let needleMbps = dlLiveSampler.observe(totalBytes: bytes, elapsedMs: elapsedMs)
                let averageMbps = (Double(bytes) * 8.0 / 1_000_000.0) / max(0.1, elapsed)
                if let interval = dlState.interval(bytes: bytes, time: elapsedMs) {
                    dlSamplesBox.append(start: interval.start, end: interval.end, bytes: interval.bytes)
                }
                progress?(SpeedtestLiveProgress(
                    phase: .download, currentMbps: needleMbps,
                    fraction: min(1, elapsed / usefulDuration),
                    downloadLiveMbps: needleMbps, downloadAverageMbps: averageMbps,
                    serverName: serverName,
                    stage: "measurement", usefulElapsedSeconds: elapsed
                ))
            }
        )
        dlLoadedTask.cancel()
        let downloadPings = await dlLoadedTask.value
        let pingDlMs = downloadPings.isEmpty ? nil : SpeedMetricCalculator.average(downloadPings)
        let jitterDlMs = downloadPings.isEmpty ? nil : SpeedMetricCalculator.jitter(downloadPings)

        try Task.checkCancellation()
        guard dlOutcome.bytes > 100_000, dlOutcome.duration >= 1.0 else {
            sqDebugLog("SQ_LIBRESPEED DL insuffisant : \(dlOutcome.bytes) octets en \(String(format: "%.1f", dlOutcome.duration))s (\(server.hostname))")
            throw SpeedtestEngineError.noServerReachable
        }
        let dlStats = dlSamplesBox.publicStats(
            windowMs: SpeedtestEngineConfig.publicPeakWindowMs, graceMs: 0,
            endMs: max(dlOutcome.duration, 0.001) * 1_000
        )
        let dlGraphSeries = dlSamplesBox.publicStats(
            windowMs: SpeedtestEngineConfig.graphWindowMs, graceMs: 0,
            endMs: max(dlOutcome.duration, 0.001) * 1_000
        ).seriesMbps
        let dlAverageMbps = dlOutcome.averageMbps
        let dlPeakMbps = dlSamplesBox.nperfPeakMbps(
            usefulDurationMs: max(dlOutcome.duration, 0.001) * 1_000,
            flooredAt: dlAverageMbps
        )

        // 3. Upload — best effort.
        progress?(SpeedtestLiveProgress(phase: .upload, fraction: 0, serverName: serverName, stage: "preparation", usefulElapsedSeconds: 0))
        let contextTask = resultContextTask(pathStatus: pathStatus, location: location)
        let ulSamplesBox = SpeedtestSamplesBox()
        let ulLiveSampler = SpeedtestLiveSampler()
        let ulState = ProgressState()
        var ulAverageMbps: Double?
        var ulPeakMbps: Double?
        var ulStats = SpeedtestSamplesBox.PublicStats(p90: nil, p95: nil, peak: 0, windowCount: 0, seriesMbps: [])
        var pingUlMs: Double?
        var jitterUlMs: Double?

        let ulLoadedDeadline = speedtestMonotonicSeconds() + (usefulDuration + 1)
        let ulLoadedTask = Task.detached(priority: .utility) {
            await SpeedtestService.collectIPerfLoadedPings(
                host: lsHost, port: LibreSpeedConfig.httpsPort,
                deadline: ulLoadedDeadline, tcpProbe: lsLoadedProbe
            )
        }
        defer { ulLoadedTask.cancel() }

        let ulOutcome = await measureLibreSpeedTransfer(
            server: server, direction: .upload, session: session,
            streams: ulStreams, duration: usefulDuration,
            onProgress: { @Sendable bytes, elapsed in
                let elapsedMs = elapsed * 1000.0
                let needleMbps = ulLiveSampler.observe(totalBytes: bytes, elapsedMs: elapsedMs)
                let averageMbps = (Double(bytes) * 8.0 / 1_000_000.0) / max(0.1, elapsed)
                if let interval = ulState.interval(bytes: bytes, time: elapsedMs) {
                    ulSamplesBox.append(start: interval.start, end: interval.end, bytes: interval.bytes)
                }
                progress?(SpeedtestLiveProgress(
                    phase: .upload, currentMbps: needleMbps,
                    fraction: min(1, elapsed / usefulDuration),
                    uploadLiveMbps: needleMbps, uploadAverageMbps: averageMbps,
                    serverName: serverName,
                    stage: "measurement", usefulElapsedSeconds: elapsed
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
                windowMs: SpeedtestEngineConfig.publicPeakWindowMs, graceMs: 0,
                endMs: max(ulOutcome.duration, 0.001) * 1_000
            )
            ulGraphSeries = ulSamplesBox.publicStats(
                windowMs: SpeedtestEngineConfig.graphWindowMs, graceMs: 0,
                endMs: max(ulOutcome.duration, 0.001) * 1_000
            ).seriesMbps
            ulAverageMbps = ulOutcome.averageMbps
            ulPeakMbps = ulSamplesBox.nperfPeakMbps(
                usefulDurationMs: max(ulOutcome.duration, 0.001) * 1_000,
                flooredAt: ulAverageMbps ?? 0
            )
        }

        let measurements = EngineMeasurements(
            serverName: serverName,
            downloadServerId: "librespeed_\(server.countryCode.lowercased())",
            downloadServerCode: server.hostname,
            downloadServerHost: server.hostname,
            downloadServerPort: Int(LibreSpeedConfig.httpsPort),
            engine: "librespeed",
            engineFallbackReason: nil,
            requestedServerId: nil,
            pingProtocol: "TCP",
            pingMs: pingValue,
            pingMedianMs: pingMedianValue,
            pingMinMs: pingValues.min(),
            pingMaxMs: pingValues.max(),
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
            jitterUlMs: jitterUlMs,
            pingServerHost: server.hostname,
            pingServerPort: Int(LibreSpeedConfig.httpsPort),
            uploadServerHost: ulAverageMbps == nil ? nil : server.hostname,
            uploadServerPort: ulAverageMbps == nil ? nil : Int(LibreSpeedConfig.httpsPort)
        )
        return await finalizeRun(
            measurements, startedAt: startedAt, pathStatus: pathStatus,
            location: location, context: contextTask, progress: progress
        )
    }

    /// Transfert LibreSpeed borné par une deadline : N flux concurrents qui
    /// enchaînent `garbage.php` (DL) ou des POST `empty.php` (UL, blocs de 4 Mo
    /// car les gros POST sont refusés en 413). Octets comptés au fil de l'eau.
    private func measureLibreSpeedTransfer(
        server: LibreSpeedServer,
        direction: CloudflareTransferDirection,
        session: URLSession,
        streams: Int,
        duration: Double,
        onProgress: @escaping @Sendable (_ bytes: Int, _ elapsedSeconds: Double) -> Void
    ) async -> CloudflareTransferOutcome {
        let recorder = SpeedtestTraceScope.current
        let counter = SafeCounter(onDelta: { bytes in
            recorder?.recordTraffic(phase: direction == .download ? "download" : "upload", bytes: bytes)
        })
        let start = counter.timedSnapshot().timestamp
        let traceSamples = SpeedtestSamplesBox()
        let traceState = ProgressState()
        let attemptId = UUID().uuidString
        let deadline = start + duration
        let downURL = server.downloadURL(ckSizeMiB: LibreSpeedConfig.downloadCkSizeMiB)
        let upURL = server.uploadURL
        let uploadBody = direction == .upload ? Data(count: LibreSpeedConfig.uploadBytesPerRequest) : Data()

        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { break }
                let snapshot = counter.timedSnapshot()
                let elapsed = snapshot.timestamp - start
                if let interval = traceState.interval(bytes: snapshot.bytes, time: elapsed * 1000) {
                    traceSamples.append(start: interval.start, end: interval.end, bytes: interval.bytes)
                }
                onProgress(snapshot.bytes, elapsed)
                if elapsed >= duration { _ = counter.close(); break }
            }
        }
        defer { ticker.cancel() }

        let didLogFailure = AtomicBool(false)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, streams) {
                group.addTask { [counter, uploadBody, didLogFailure] in
                    while speedtestMonotonicSeconds() < deadline, !Task.isCancelled {
                        do {
                            switch direction {
                            case .download:
                                var request = URLRequest(url: downURL)
                                request.timeoutInterval = duration + 10
                                let delegate = SpeedtestDownloadDelegate(deadline: deadline, onBytes: { counter.add($0) })
                                let task = session.dataTask(with: request)
                                task.delegate = delegate
                                try await delegate.run(task: task)
                            case .upload:
                                var request = URLRequest(url: upURL)
                                request.httpMethod = "POST"
                                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                                request.timeoutInterval = duration + 10
                                let delegate = SpeedtestUploadDelegate(deadline: deadline, onBytesSent: { counter.add($0) })
                                let task = session.uploadTask(with: request, from: uploadBody)
                                task.delegate = delegate
                                _ = try await delegate.run(task: task)
                            }
                        } catch {
                            if Task.isCancelled || speedtestMonotonicSeconds() >= deadline { break }
                            if !didLogFailure.value {
                                didLogFailure.value = true
                                sqDebugLog("SQ_LIBRESPEED \(direction == .download ? "DL" : "UL") requête échouée : \(error.localizedDescription)")
                            }
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }
                    }
                }
            }
        }
        ticker.cancel()
        await ticker.value
        let final = counter.close()
        if let interval = traceState.interval(bytes: final.bytes, time: (final.timestamp - start) * 1000) {
            traceSamples.append(start: interval.start, end: interval.end, bytes: interval.bytes)
        }
        recorder?.retain(phase: direction == .download ? "download" : "upload", id: attemptId,
            start: start, baseline: start, end: final.timestamp, measuredBytes: final.bytes,
            totalBytes: counter.trafficValue, source: direction == .download ? "client-received" : "client-written",
            samples: traceSamples.snapshotIntervals())
        onProgress(final.bytes, final.timestamp - start)
        return CloudflareTransferOutcome(bytes: final.bytes, duration: max(0.001, final.timestamp - start))
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
        let siblingPorts = iperfSiblingCandidatePorts(
            preferred: preferredPort,
            min: lo,
            max: hi
        )

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
                // Le port préféré vient d'échouer : il est mémorisé pour 10 min, et un
                // démon iPerf3 public est souvent mono-slot. Sans cette invalidation, le
                // test SUIVANT de la rafale (lancé moins d'une seconde après) rejouait le
                // même port occupé et retombait sur le repli Cloudflare, à chaque fois.
                await IPerfEndpointCache.shared.invalidate(hostname)
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
        let simPlmn: String?
        let marketCode: String?
        let operatorKey: String?

        static let empty = CellularOperatorContext(
            mobileOperator: nil,
            mcc: nil,
            mnc: nil,
            simPlmn: nil,
            marketCode: nil,
            operatorKey: nil
        )
    }

    /// Construit le contexte opérateur d'un test cellulaire.
    ///
    /// CoreTelephony (`CTCarrier`) ne renvoie plus MCC/MNC/nom depuis iOS 16.4+
    /// (placeholders `--` / 65535, filtrés en amont → nil). On reconstruit donc le
    /// contexte comme la carte : opérateur via IP/ASN (`/api/speedtest/operator`,
    /// hors VPN) et marché via la localisation. Le PLMN CoreTelephony reste une
    /// information SIM séparée. Sous VPN la résolution IP renvoie un opérateur
    /// nul : on n'enregistre JAMAIS l'opérateur du tunnel.
    private func resolveCellularOperatorContext(
        pathStatus: NetworkPathStatus,
        location: Coordinates?
    ) async -> CellularOperatorContext {
        guard pathStatus.connection == .cellular else { return .empty }
        let ctMcc = pathStatus.operatorMcc
        let ctMnc = pathStatus.operatorMnc
        let registry = await markets.registry()

        // Le marché de mesure vient de la position, jamais du PLMN SIM : en
        // roaming, la SIM décrit le pays d'origine et non le réseau visité.
        var market: MarketRegistryEntry?
        if let location {
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
        return CellularOperatorContext(
            // Le réseau utilisé vient de la résolution IP ; le nom CoreTelephony
            // reste séparé dans `carrierName` comme information SIM.
            mobileOperator: trusted?.shortLabel ?? trusted?.label
                ?? operatorEntry?.shortLabel ?? operatorEntry?.label,
            // Ces deux entiers restent dans le résultat local historique, mais
            // `SpeedtestSubmission` ne les envoie plus comme preuve servante.
            mcc: ctMcc,
            mnc: ctMnc,
            simPlmn: pathStatus.simPlmn,
            marketCode: market?.marketCode,
            operatorKey: trusted?.operatorKey ?? operatorEntry?.key
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
        try await saveCoordinator.submit(id: result.id.uuidString) { [self] in
            try await queueAndSave(result, streams: streams, publishToMap: publishToMap,
                                   shareExactLocation: shareExactLocation, driveSessionId: driveSessionId)
        }
    }

    private let saveCoordinator = SpeedtestSubmissionCoordinator()
    private func queueAndSave(_ result: SpeedtestRunResult, streams: Int, publishToMap: Bool,
                              shareExactLocation: Bool, driveSessionId: String?) async throws {
        guard result.ownerScopeId == nil || result.ownerScopeId == LocalAccountScope.currentOwnerScopeId else { throw CancellationError() }
        if let existing = await pendingStore.loadAll().first(where: { $0.id == result.id.uuidString }) {
            try await submitPendingSave(existing)
            await removePendingSave(id: existing.id)
            return
        }
        let guestDeleteToken: String?
        if (result.ownerScopeId ?? LocalAccountScope.currentOwnerScopeId) == "guest" {
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
            driveSessionId: driveSessionId,
            ownerScopeId: result.ownerScopeId ?? LocalAccountScope.currentOwnerScopeId
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
        let key = historyCacheKey
        if let values = try? await historyCache.read([SpeedtestRunResult].self, for: key) { return values }
        try? await historyMutations.perform { [self] in
            guard (try? await historyCache.read([SpeedtestRunResult].self, for: key)) == nil else { return }
            let legacy = (try? await legacyHistoryCache.read([SpeedtestRunResult].self, for: key)) ?? []
            if !legacy.isEmpty { try await historyCache.write(legacy, for: key) }
        }
        return (try? await historyCache.read([SpeedtestRunResult].self, for: key)) ?? []
    }

    func retryPendingSaves() async {
        try? await flushPendingSaves()
    }

    func details(id: String) async throws -> SpeedtestDetail {
        let owner = LocalAccountScope.currentOwnerScopeId
        let session = LocalAccountScope.sessionSnapshot()
        let token = owner == "guest" ? "" : api.credentials.accessToken()
        guard owner == "guest" || (token.map { session?.matchesAuthToken($0) == true } == true) else { throw APIError.missingAuthToken }
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let (data, http) = try await api.performSingleAttempt(
            APIEndpoint(path: "/api/speedtests/\(encodedId)", authenticated: false),
            fixedAuthToken: token, expectedSession: session)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, code: nil, message: "", requestId: nil, retryAfter: nil)
        }
        guard owner == LocalAccountScope.currentOwnerScopeId else { throw CancellationError() }
        if owner != "guest" {
            guard let currentToken = api.credentials.accessToken(), session?.matchesAuthToken(currentToken) == true else { throw CancellationError() }
        }
        return try JSONDecoder.signalQuest.decode(SpeedtestDetail.self, from: data)
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

    private let historyMutations = SpeedtestMutationQueue()
    private func appendHistory(_ result: SpeedtestRunResult) async throws {
        try await historyMutations.perform { [self] in try await appendOwnedHistory(result) }
    }

    private func appendOwnedHistory(_ result: SpeedtestRunResult) async throws {
        let key = "history-\(LocalAccountScope.storageNamespace(for: result.ownerScopeId ?? LocalAccountScope.currentOwnerScopeId))"
        let archived = try? await historyCache.read([SpeedtestRunResult].self, for: key)
        let legacy = archived == nil ? (try? await legacyHistoryCache.read([SpeedtestRunResult].self, for: key)) : nil
        var values = archived ?? legacy ?? []
        values.removeAll { $0.id == result.id }
        values.insert(result, at: 0)
        if values.count > 20 { values = Array(values.prefix(20)) }
        try await historyCache.write(values, for: key)
        guard result.ownerScopeId == nil || result.ownerScopeId == LocalAccountScope.currentOwnerScopeId else { return }
        // Partage le dernier résultat avec le widget (App Group), rafraîchit le
        // widget et indexe l'item Spotlight.
        let snapshot = SpeedtestWidgetSnapshot(
            downloadMbps: result.downloadMbps,
            uploadMbps: result.uploadMbps,
            pingMs: result.primaryPingMs,
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
        let ownerScopeId = LocalAccountScope.currentOwnerScopeId
        return await pendingStore.loadAll().filter { $0.ownerScopeId == ownerScopeId }
    }

    private func upsertPendingSave(_ pending: PendingSpeedtestSave) async throws {
        // Atomique côté store (iOS 17+) : plus de read-modify-write dans ce service
        // non isolé, donc plus de perte si deux sauvegardes s'enchaînent (ROB-11).
        try await pendingStore.upsert(pending)
    }

    private func removePendingSave(id: String) async {
        await pendingStore.remove(id: id)
    }

    private let submissionCoordinator = SpeedtestSubmissionCoordinator()

    private func submitPendingSave(_ pending: PendingSpeedtestSave) async throws {
        try await submissionCoordinator.submit(id: pending.id) { [self] in
            try await submitOwnedPendingSave(pending)
        }
    }

    private func submitOwnedPendingSave(_ pending: PendingSpeedtestSave) async throws {
        guard let ownerScopeId = pending.ownerScopeId, ownerScopeId == LocalAccountScope.currentOwnerScopeId else {
            // La session a changé entre la lecture et l'envoi : conserver l'entrée
            // pour son propriétaire, sans l'attribuer au compte désormais actif.
            throw CancellationError()
        }
        let payload = SpeedtestSubmission.iosPayload(
            from: pending.result,
            streams: pending.streams,
            deviceModel: pending.deviceModel,
            isVisibleOnMap: pending.isVisibleOnMap ?? false,
            shareExactLocation: pending.shareExactLocation ?? false,
            guestDeleteToken: pending.guestDeleteToken,
            sessionId: pending.driveSessionId
        )
        let session = LocalAccountScope.sessionSnapshot()
        let token = pending.ownerScopeId == "guest" ? "" : api.credentials.accessToken()
        guard pending.ownerScopeId == "guest" || (token.map { session?.matchesAuthToken($0) == true } == true) else { throw APIError.missingAuthToken }
        guard pending.ownerScopeId == LocalAccountScope.currentOwnerScopeId else { throw CancellationError() }
        let endpoint = APIEndpoint(path: "/api/speedtests", method: .post,
            headers: ["Content-Type": "application/json"], body: try JSONEncoder.signalQuest.encode(payload),
            authenticated: false, idempotencyKey: pending.id)
        let (data, http) = try await api.performSingleAttempt(endpoint, fixedAuthToken: token, expectedSession: session)
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, code: nil,
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode), requestId: nil,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
        let response = try JSONDecoder.signalQuest.decode(SpeedtestSaveResponse.self, from: data)
        if ownerScopeId != "guest" {
            guard let currentToken = api.credentials.accessToken(), session?.matchesAuthToken(currentToken) == true else { throw CancellationError() }
        }
        guard response.success, let resolvedID = response.resolvedID,
              !resolvedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.decoding("Unacknowledged speedtest submission")
        }
        guard pending.ownerScopeId == LocalAccountScope.currentOwnerScopeId else { throw CancellationError() }
        if let association = response.physicalSiteAssociation {
            try await rememberPhysicalSiteAssociation(
                association,
                keys: [pending.id, response.resolvedID].compactMap { $0 },
                ownerScopeId: ownerScopeId
            )
        }
        if let serverId = response.resolvedID {
            // Mémorisé pour TOUS : sans cet id, un test de l'historique ne peut
            // plus être ciblé (publication a posteriori). Il n'était conservé
            // que pour les invités, via le reçu de suppression.
            try await rememberServerId(serverId, forClientId: pending.id, ownerScopeId: ownerScopeId)
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

    private var historyCacheKey: String { "history-\(LocalAccountScope.storageNamespace)" }
    private var serverIdMapKey: String { "serverIds-\(LocalAccountScope.storageNamespace)" }
    private func physicalSiteAssociationCacheKey(_ id: String) -> String {
        "physicalSiteAssociation-\(LocalAccountScope.storageNamespace)-\(id)"
    }

    private func rememberPhysicalSiteAssociation(
        _ association: SpeedtestPhysicalSiteAssociation,
        keys: [String],
        ownerScopeId: String
    ) async throws {
        // Une cle par mesure evite le read-modify-write d'un dictionnaire global :
        // deux POST termines en parallele ne peuvent pas perdre l'association de
        // l'autre. Le brut radio reste dans le resultat, jamais remplace ici.
        let namespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        for key in keys where !key.isEmpty {
            try await historyCache.write(association, for: "physicalSiteAssociation-\(namespace)-\(key)")
        }
    }

    func physicalSiteAssociation(forClientId clientId: UUID) async -> SpeedtestPhysicalSiteAssociation? {
        try? await historyCache.read(
            SpeedtestPhysicalSiteAssociation.self,
            for: physicalSiteAssociationCacheKey(clientId.uuidString)
        )
    }

    private func rememberServerId(_ serverId: String, forClientId clientId: String, ownerScopeId: String) async throws {
        let namespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        let key = "serverIds-\(namespace)"
        // Independent durable mapping: concurrent A/B responses cannot lose each other.
        try await historyCache.write(serverId, for: "\(key)-\(clientId)")
        var map = (try? await historyCache.read([String: String].self, for: key)) ?? [:]
        guard map[clientId] != serverId else { return }
        map[clientId] = serverId
        // Bornée comme l'historique : inutile de garder des ids dont le test a
        // déjà disparu de la liste.
        if map.count > 60 {
            let keep = Set(((try? await historyCache.read([SpeedtestRunResult].self, for: "history-\(namespace)")) ?? []).map(\.id.uuidString))
            map = map.filter { keep.contains($0.key) || $0.key == clientId }
        }
        try await historyCache.write(map, for: key)
    }

    func serverId(forClientId clientId: UUID) async -> String? {
        if let id = try? await historyCache.read(String.self, for: "\(serverIdMapKey)-\(clientId.uuidString)") { return id }
        let map = (try? await historyCache.read([String: String].self, for: serverIdMapKey)) ?? [:]
        if let id = map[clientId.uuidString] { return id }
        let legacy = (try? await legacyHistoryCache.read([String: String].self, for: serverIdMapKey)) ?? [:]
        return legacy[clientId.uuidString]
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
        var firstError: Error?
        // Retrait par id APRÈS chaque envoi réussi, plutôt qu'un `replaceAll` final
        // depuis ce snapshot périmé : un test sauvegardé hors-ligne pendant la
        // fenêtre réseau du flush n'est plus écrasé (ROB-11). Les entrées exclues
        // et les échecs restent simplement en place.
        for item in pending where !excludedIds.contains(item.id) {
            do {
                try await submitPendingSave(item)
                await pendingStore.remove(id: item.id)
            } catch {
                if firstError == nil { firstError = error }
            }
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
        // ICMP d'abord : c'est le seul vrai RTT. Le connect TCP reste en repli parce
        // que beaucoup d'opérateurs mobiles et de POP publics filtrent l'ICMP — mais
        // il ne doit plus être le chemin nominal, il surestime structurellement.
        if let icmp = await measureIcmpPings(host: host, serverName: serverName, progress: progress) {
            return icmp
        }

        // Repli : hôte résolu UNE fois, la sonde reçoit une adresse et non un nom.
        let address = (try? ICMPPinger.resolve(host: host))?.addressText ?? host
        let result = await measureTcpPings(
            host: address,
            port: port,
            serverName: serverName,
            progress: progress,
            minimumValidSamples: 2
        )
        guard !result.values.isEmpty else { throw SpeedtestEngineError.pingFailed }
        return PingOutcome(values: result.values, protocolName: "TCP")
    }

    /// Série ICMP. `nil` — et non une erreur — quand l'ICMP n'aboutit pas : c'est le
    /// signal que le repli TCP doit prendre la main, pas que le test a échoué.
    ///
    /// Le seuil de 2 échantillons est le même que pour le TCP : une valeur unique ne
    /// permet ni médiane ni gigue honnêtes.
    private func measureIcmpPings(
        host: String,
        serverName: String,
        progress: SpeedtestProgressHandler?
    ) async -> PingOutcome? {
        let target = speedtestPingMeasuredSampleTarget(
            attemptBudget: SpeedtestEngineConfig.pingAttemptBudget,
            warmupCount: SpeedtestEngineConfig.pingWarmupCount
        )
        let pinger = ICMPPinger(host: host, timeout: SpeedtestEngineConfig.pingTimeoutSeconds)
        // Un échantillon d'échauffement en plus, écarté ensuite : le premier écho paie
        // souvent la mise en route du chemin radio.
        guard let samples = try? await pinger.ping(
            count: target + 1,
            intervalMs: SpeedtestEngineConfig.pingIntervalMs,
            onSample: { [weak self] running in
                // Même `dropFirst()` que le résultat final ci-dessous : le premier
                // écho paie la mise en route du chemin radio et sera écarté. Afficher
                // une latence qui ne sera PAS celle retenue serait pire que d'attendre
                // un tour de plus.
                let measured = speedtestIcmpMeasuredValues(running)
                guard !measured.isEmpty else { return }
                self?.emitPingProgress(
                    values: Array(measured),
                    protocolName: "ICMP",
                    target: target,
                    serverName: serverName,
                    progress: progress
                )
            }
        ) else { return nil }

        let values = speedtestIcmpMeasuredValues(samples)
        guard values.count >= 2 else { return nil }
        emitPingProgress(
            values: Array(values),
            protocolName: "ICMP",
            target: target,
            serverName: serverName,
            progress: progress
        )
        return PingOutcome(values: Array(values), protocolName: "ICMP")
    }

    /// RTT TCP sous charge (pendant DL/UL iPerf) : connect latency uniquement,
    /// sans handshake iPerf3, pour peupler pingDl/Ul + jitterDl/Ul.
    private static func collectIPerfLoadedPings(
        host: String,
        port: UInt16,
        deadline: TimeInterval,
        tcpProbe: SpeedtestTCPProbing
    ) async -> [Double] {
        var values: [Double] = []
        while speedtestMonotonicSeconds() < deadline && !Task.isCancelled {
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
            if Task.isCancelled || speedtestMonotonicSeconds() >= deadline { break }
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

        // ⚠️ Annulation : les `try? await Task.sleep` ci-dessous retournent
        // INSTANTANÉMENT sur une tâche annulée. Sans les gardes explicites, appuyer
        // sur « Arrêter » pendant la phase ping ne stoppait pas la boucle — elle
        // s'emballait au contraire à pleine vitesse, en continuant d'émettre des
        // ticks de progression qui repeignaient le cadran.
        if Task.isCancelled { return PingAttemptResult(values: [], attemptsUsed: attemptsUsed) }

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
            if Task.isCancelled { break }
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
        while values.count < minimumValidSamples,
              salvageUsed < SpeedtestEngineConfig.pingSalvageAttempts,
              !Task.isCancelled {
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
            pingLiveMs: values.min(),
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
            pingLiveMs: values.min(),
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
    /// Identifiant de catalogue, STABLE À VIE : c'est lui qui part en base dans
    /// `Speedtest.downloadServerId`. Il vaut le `rawValue` de la cible
    /// correspondante et il est commun à Android — l'hôte, lui, peut changer.
    let id: String
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
    /// Port vérifié par handshake iPerf3 réel, point de départ du port-walk.
    ///
    /// Le premier port d'une plage est très souvent inutilisable, et un port MUET
    /// (TCP ouvert, daemon qui ne répond jamais) coûte un timeout complet là où un
    /// port refusé est instantané. Démarrer sur `portMin` faisait donc payer une
    /// attente à chaque test — mesuré le 2026-08-10 : Scaleway est muet sur 5200,
    /// Bouygues refuse 9200 sur la plupart de ses POPs, Clouvider Londres est muet
    /// de 5200 à 5206.
    let portPreferred: UInt16
    /// Visible dans les choix manuels de l'utilisateur.
    let selectable: Bool
    /// Autorisé dans la sélection automatique mesurée.
    let autoEligible: Bool
    /// Malus géographique fourni par le catalogue, sans effet sur un choix manuel.
    let autoPenaltyKm: Double
    let ipVersion: IPerfIPVersion
    /// Information de diagnostic uniquement : elle ne décide jamais du vainqueur.
    let linkGbps: Double?
    /// Latence artificielle injectée par une mire de test.
    let syntheticLatencyMs: Int

    init(
        id: String,
        hostname: String,
        name: String,
        latitude: Double,
        longitude: Double,
        code: String,
        countryCode: String,
        provider: IPerfServerProvider,
        portMin: UInt16,
        portMax: UInt16,
        portPreferred: UInt16? = nil,
        selectable: Bool = true,
        autoEligible: Bool = true,
        autoPenaltyKm: Double = 0,
        ipVersion: IPerfIPVersion = .ipv4,
        linkGbps: Double? = nil,
        syntheticLatencyMs: Int = 0
    ) {
        self.id = id
        self.hostname = hostname
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.code = code
        self.countryCode = countryCode
        self.provider = provider
        self.portMin = portMin
        self.portMax = portMax
        // Par défaut le premier port de la plage : on ne surcharge que les POPs dont
        // la mesure a montré qu'il ne répond pas.
        self.portPreferred = portPreferred ?? portMin
        self.selectable = selectable
        self.autoEligible = autoEligible
        self.autoPenaltyKm = autoPenaltyKm
        self.ipVersion = ipVersion
        self.linkGbps = linkGbps
        self.syntheticLatencyMs = syntheticLatencyMs
    }

    var defaultPort: UInt16 { portPreferred }
}

enum IPerfIPVersion: String, Sendable {
    case ipv4
    case ipv6
    case dual
}

enum IPerfServerProvider: String, Sendable {
    case ovh
    case bouygues
    case scaleway
    case milkywan
    case moji
    case clouvider
    case leaseweb
    case init7
    /// POPs publics sans marque propre, et **repli pour tout fournisseur inconnu**
    /// servi par l'API : le catalogue distant doit pouvoir introduire un
    /// fournisseur que ce binaire ne connaît pas encore sans que le POP disparaisse.
    case community
}

/// Catalogue ACTIF : celui servi par `/api/speedtest/servers` dès qu'il a été chargé,
/// sinon le catalogue embarqué ci-dessous.
///
/// C'est ce qui permet de corriger un POP mort côté serveur sans release App Store.
/// L'embarqué n'est plus la vérité, seulement la valeur de départ — indispensable
/// au tout premier lancement, hors ligne, ou si l'API est injoignable.
private let activeIPerfCatalogLock = OSAllocatedUnfairLock<[IPerfPublicServer]?>(initialState: nil)

var activeIPerfServers: [IPerfPublicServer] {
    activeIPerfCatalogLock.withLock { $0 } ?? iperfPublicServers
}

/// Publie un catalogue chargé à distance. `nil` revient à l'embarqué.
/// Un catalogue vide est ignoré : mieux vaut l'embarqué que plus aucun serveur.
func setActiveIPerfServers(_ servers: [IPerfPublicServer]?) {
    activeIPerfCatalogLock.withLock { current in
        guard let servers else { current = nil; return }
        guard !servers.isEmpty else { return }
        current = servers
    }
}

/// Catalogue des serveurs iPerf3 publics EMBARQUÉ — valeur de repli.
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
        // OVH proof (ports 5201–5210) — 5201 répond, pas de surcharge nécessaire.
        IPerfPublicServer(id: "rbx", hostname: "rbx.proof.ovh.net", name: "Roubaix (OVH RBX)", latitude: 50.692, longitude: 3.178, code: "RBX", countryCode: "FR", provider: .ovh, portMin: ovhMin, portMax: ovhMax),
        IPerfPublicServer(id: "sbg", hostname: "sbg.proof.ovh.net", name: "Strasbourg (OVH SBG)", latitude: 48.573, longitude: 7.752, code: "SBG", countryCode: "FR", provider: .ovh, portMin: ovhMin, portMax: ovhMax),
        IPerfPublicServer(id: "gra", hostname: "gra.proof.ovh.net", name: "Gravelines (OVH GRA)", latitude: 50.986, longitude: 2.124, code: "GRA", countryCode: "FR", provider: .ovh, portMin: ovhMin, portMax: ovhMax),
        IPerfPublicServer(id: "bom", hostname: "bom.proof.ovh.net", name: "Mumbai (OVH YNM)", latitude: 19.076, longitude: 72.877, code: "YNM", countryCode: "IN", provider: .ovh, portMin: ovhMin, portMax: ovhMax, autoEligible: false),
        // ⚠️ `bhs.proof.ovh.ca` (Beauharnois, QC) RETIRÉ : OVH n'y expose plus que
        // 5208/5209, et ces deux daemons acceptent le TCP sans jamais répondre au
        // handshake iPerf3. La sonde de joignabilité ne teste QUE le connect → le
        // POP était élu, le ping TCP excellent, et le DL mourait sur timeout.
        //
        // ⚠️ `proof.ovh.us` (Ashburn) RETIRÉ à son tour le 2026-08-10 : timeout sur
        // TOUTE la plage 5201–5210, vérifié par handshake réel. Une cible retirée du
        // catalogue retombe proprement sur le POP le plus proche
        // (`selectIPerfServer` → `findClosestIPerfServer`), la préférence
        // utilisateur n'a donc pas besoin d'être migrée.
        // Bouygues Telecom (ports 9200–9240) — BBR & CUBIC (poi.cubic exclu).
        // 9200 est REFUSÉ sur la quasi-totalité des POPs : chaque portPreferred
        // ci-dessous est mesuré individuellement.
        IPerfPublicServer(id: "bytel_paris_bbr", hostname: "paris.bbr.iperf.bytel.fr", name: "Paris BBR (Bouygues)", latitude: parisLat, longitude: parisLon, code: "PAR-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9201),
        IPerfPublicServer(id: "bytel_paris_cubic", hostname: "paris.cubic.iperf.bytel.fr", name: "Paris CUBIC (Bouygues)", latitude: parisLat, longitude: parisLon, code: "PAR-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax),
        IPerfPublicServer(id: "bytel_mrs_bbr", hostname: "mrs.bbr.iperf.bytel.fr", name: "Marseille BBR (Bouygues)", latitude: 43.2965, longitude: 5.3698, code: "MRS-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9202),
        IPerfPublicServer(id: "bytel_mrs_cubic", hostname: "mrs.cubic.iperf.bytel.fr", name: "Marseille CUBIC (Bouygues)", latitude: 43.2965, longitude: 5.3698, code: "MRS-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9204),
        IPerfPublicServer(id: "bytel_lyo_bbr", hostname: "lyo.bbr.iperf.bytel.fr", name: "Lyon BBR (Bouygues)", latitude: 45.7640, longitude: 4.8357, code: "LYO-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9202),
        IPerfPublicServer(id: "bytel_lyo_cubic", hostname: "lyo.cubic.iperf.bytel.fr", name: "Lyon CUBIC (Bouygues)", latitude: 45.7640, longitude: 4.8357, code: "LYO-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9202),
        IPerfPublicServer(id: "bytel_tls_bbr", hostname: "tls.bbr.iperf.bytel.fr", name: "Toulouse BBR (Bouygues)", latitude: 43.6047, longitude: 1.4442, code: "TLS-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9204),
        IPerfPublicServer(id: "bytel_tls_cubic", hostname: "tls.cubic.iperf.bytel.fr", name: "Toulouse CUBIC (Bouygues)", latitude: 43.6047, longitude: 1.4442, code: "TLS-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9201),
        IPerfPublicServer(id: "bytel_str_bbr", hostname: "str.bbr.iperf.bytel.fr", name: "Strasbourg BBR (Bouygues)", latitude: 48.5734, longitude: 7.7521, code: "STR-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9201),
        IPerfPublicServer(id: "bytel_str_cubic", hostname: "str.cubic.iperf.bytel.fr", name: "Strasbourg CUBIC (Bouygues)", latitude: 48.5734, longitude: 7.7521, code: "STR-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9203),
        IPerfPublicServer(id: "bytel_poi_bbr", hostname: "poi.bbr.iperf.bytel.fr", name: "Poitiers BBR (Bouygues)", latitude: 46.5802, longitude: 0.3404, code: "POI-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9202),
        IPerfPublicServer(id: "bytel_ren_bbr", hostname: "ren.bbr.iperf.bytel.fr", name: "Rennes BBR (Bouygues)", latitude: 48.1173, longitude: -1.6778, code: "REN-BBR", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9202),
        IPerfPublicServer(id: "bytel_ren_cubic", hostname: "ren.cubic.iperf.bytel.fr", name: "Rennes CUBIC (Bouygues)", latitude: 48.1173, longitude: -1.6778, code: "REN-CUBIC", countryCode: "FR", provider: .bouygues, portMin: bytMin, portMax: bytMax, portPreferred: 9202),
        // Scaleway / online.net (ports 5200–5209 TCP) — filet de secours + IPv6.
        // 5200 est MUET sur toutes les mires : il coûtait un timeout à chaque test.
        IPerfPublicServer(id: "online_net", hostname: "ping.online.net", name: "Paris Scaleway", latitude: parisLat, longitude: parisLon, code: "SCW", countryCode: "FR", provider: .scaleway, portMin: scwMin, portMax: scwMax, portPreferred: 5201),
        IPerfPublicServer(id: "online_net6", hostname: "ping6.online.net", name: "Paris Scaleway IPv6", latitude: parisLat, longitude: parisLon, code: "SCW6", countryCode: "FR", provider: .scaleway, portMin: scwMin, portMax: scwMax, portPreferred: 5201, autoEligible: false, ipVersion: .ipv6),
        IPerfPublicServer(id: "online_net_90ms", hostname: "ping-90ms.online.net", name: "Paris Scaleway +90 ms", latitude: parisLat, longitude: parisLon, code: "SCW90", countryCode: "FR", provider: .scaleway, portMin: scwMin, portMax: scwMax, portPreferred: 5201, selectable: false, autoEligible: false, syntheticLatencyMs: 90),
        IPerfPublicServer(id: "online_net6_90ms", hostname: "ping6-90ms.online.net", name: "Paris Scaleway IPv6 +90 ms", latitude: parisLat, longitude: parisLon, code: "SCW690", countryCode: "FR", provider: .scaleway, portMin: scwMin, portMax: scwMax, portPreferred: 5201, selectable: false, autoEligible: false, ipVersion: .ipv6, syntheticLatencyMs: 90),
        // MilkyWan AS2027 (ports 9200–9240 TCP, BBR, 40 Gbit/s) — vérifié en ligne 2026-07
        IPerfPublicServer(id: "milkywan_cbo", hostname: "speedtest.milkywan.fr", name: "Croissy-Beaubourg (MilkyWan)", latitude: 48.8412, longitude: 2.6724, code: "CBO", countryCode: "FR", provider: .milkywan, portMin: bytMin, portMax: bytMax, portPreferred: 9201),
        // POP iPerf3 publics FR/EU — handshake iPerf3 réel vérifié (juil. 2026).
        // Serveurs mono-slot : plage de ports complète pour le fallback anti-BUSY.
        IPerfPublicServer(id: "moji_paris", hostname: "iperf3.moji.fr", name: "Paris (Moji)", latitude: parisLat, longitude: parisLon, code: "MOJI", countryCode: "FR", provider: .moji, portMin: SpeedtestEngineConfig.mojiIperfPortMin, portMax: SpeedtestEngineConfig.mojiIperfPortMax),
        IPerfPublicServer(id: "clouvider_fra", hostname: "fra.speedtest.clouvider.net", name: "Francfort (Clouvider)", latitude: 50.1109, longitude: 8.6821, code: "FRA-CLV", countryCode: "DE", provider: .clouvider, portMin: SpeedtestEngineConfig.clouviderIperfPortMin, portMax: SpeedtestEngineConfig.clouviderIperfPortMax),
        IPerfPublicServer(id: "clouvider_ams", hostname: "ams.speedtest.clouvider.net", name: "Amsterdam (Clouvider)", latitude: 52.3676, longitude: 4.9041, code: "AMS-CLV", countryCode: "NL", provider: .clouvider, portMin: SpeedtestEngineConfig.clouviderIperfPortMin, portMax: SpeedtestEngineConfig.clouviderIperfPortMax),
        // ⚠️ Londres est MUET de 5200 à 5206 : huit sauts avant une réponse. C'est ce
        // POP qui faisait conclure « serveur mort » et basculer sur Cloudflare.
        IPerfPublicServer(id: "clouvider_lon", hostname: "lon.speedtest.clouvider.net", name: "Londres (Clouvider)", latitude: 51.5074, longitude: -0.1278, code: "LON-CLV", countryCode: "GB", provider: .clouvider, portMin: SpeedtestEngineConfig.clouviderIperfPortMin, portMax: SpeedtestEngineConfig.clouviderIperfPortMax, portPreferred: 5207),
        IPerfPublicServer(id: "clouvider_man", hostname: "man.speedtest.clouvider.net", name: "Manchester (Clouvider)", latitude: 53.4808, longitude: -2.2426, code: "MAN-CLV", countryCode: "GB", provider: .clouvider, portMin: SpeedtestEngineConfig.clouviderIperfPortMin, portMax: SpeedtestEngineConfig.clouviderIperfPortMax),
        IPerfPublicServer(id: "leaseweb_fra", hostname: "speedtest.fra1.de.leaseweb.net", name: "Francfort (Leaseweb)", latitude: 50.1109, longitude: 8.6821, code: "FRA-LSW", countryCode: "DE", provider: .leaseweb, portMin: SpeedtestEngineConfig.leasewebIperfPortMin, portMax: SpeedtestEngineConfig.leasewebIperfPortMax),
        // TCP ouvert mais aucun premier état iPerf3 sur 5201–5204 (2026-08-26).
        // Conserver l'id pour l'historique, sans exposer une cible muette.
        IPerfPublicServer(id: "init7_ch", hostname: "speedtest.init7.net", name: "Winterthour (Init7)", latitude: 47.4989, longitude: 8.7286, code: "INIT7", countryCode: "CH", provider: .init7, portMin: SpeedtestEngineConfig.init7IperfPortMin, portMax: SpeedtestEngineConfig.init7IperfPortMax, selectable: false, autoEligible: false),
        // Amérique du Nord — le retrait de `proof.ovh.us` (mort) laissait le
        // catalogue SANS aucun POP nord-américain, alors que le Canada est un marché
        // du produit : un utilisateur montréalais serait parti mesurer vers
        // Manchester, à ~5 000 km. Ces deux POPs sont vérifiés par handshake réel
        // (2026-08-10) et Montréal a désormais un POP dans sa propre ville.
        IPerfPublicServer(id: "leaseweb_mtl", hostname: "speedtest.mtl2.ca.leaseweb.net", name: "Montréal (Leaseweb)", latitude: 45.5017, longitude: -73.5673, code: "MTL-LSW", countryCode: "CA", provider: .leaseweb, portMin: SpeedtestEngineConfig.leasewebIperfPortMin, portMax: SpeedtestEngineConfig.leasewebIperfPortMax),
        IPerfPublicServer(id: "clouvider_ash", hostname: "ash.speedtest.clouvider.net", name: "Ashburn (Clouvider)", latitude: 39.0438, longitude: -77.4874, code: "ASH-CLV", countryCode: "US", provider: .clouvider, portMin: SpeedtestEngineConfig.clouviderIperfPortMin, portMax: SpeedtestEngineConfig.clouviderIperfPortMax, portPreferred: 5201),
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

func iperfServersSortedByDistance(
    from location: Coordinates?,
    servers: [IPerfPublicServer] = activeIPerfServers
) -> [IPerfPublicServer] {
    let automaticServers = servers.filter(\.autoEligible)
    guard let location else {
        // Sans GPS : ordre de repli déterministe. Les POPs non éligibles (IPv6-only,
        // mires synthétiques, POP désactivé côté serveur) ont déjà été exclus.
        let preferred = [
            "paris.bbr.iperf.bytel.fr",
            "speedtest.milkywan.fr",
            "ping.online.net",
            "lyo.bbr.iperf.bytel.fr",
            "paris.cubic.iperf.bytel.fr",
            "gra.proof.ovh.net",
            "rbx.proof.ovh.net",
            "sbg.proof.ovh.net",
        ]
        return automaticServers.sorted { a, b in
            let ia = preferred.firstIndex(of: a.hostname) ?? 99
            let ib = preferred.firstIndex(of: b.hostname) ?? 99
            if ia != ib { return ia < ib }
            if a.autoPenaltyKm != b.autoPenaltyKm { return a.autoPenaltyKm < b.autoPenaltyKm }
            return a.name < b.name
        }
    }
    // L'index d'origine départage explicitement les égalités : le classement reste
    // déterministe même pour deux POPs co-localisés.
    return automaticServers.enumerated().sorted { lhs, rhs in
        let d1 = haversineDistanceKm(
            from: location,
            to: Coordinates(latitude: lhs.element.latitude, longitude: lhs.element.longitude)
        ) + lhs.element.autoPenaltyKm
        let d2 = haversineDistanceKm(
            from: location,
            to: Coordinates(latitude: rhs.element.latitude, longitude: rhs.element.longitude)
        ) + rhs.element.autoPenaltyKm
        return d1 == d2 ? lhs.offset < rhs.offset : d1 < d2
    }.map(\.element)
}

func findClosestIPerfServer(
    to location: Coordinates?,
    servers: [IPerfPublicServer] = activeIPerfServers
) -> IPerfPublicServer {
    iperfServersSortedByDistance(from: location, servers: servers).first
        ?? iperfPublicServers.first(where: \.autoEligible)
        ?? iperfPublicServers[0]
}

/// Résout uniquement un choix manuel réellement autorisé par le catalogue actif.
/// `nil` signifie que la cible a disparu ou a été désactivée : l'appelant doit
/// annoncer son repli, jamais faire croire qu'elle a été honorée.
func selectableIPerfServer(
    for target: SpeedtestDownloadTarget,
    location: Coordinates?,
    catalogId: String? = nil,
    servers: [IPerfPublicServer] = activeIPerfServers
) -> IPerfPublicServer? {
    // 1. POP choisi dans le catalogue distant. Il n'a pas forcément de cas d'enum :
    //    c'est précisément ce qui permet à l'API d'introduire un serveur sans
    //    attendre une mise à jour de l'app.
    if target.migrated == .iperfCatalog,
       let catalogId,
       let server = servers.first(where: { $0.id == catalogId && $0.selectable }) {
        return server
    }
    // 2. Les ids de catalogue et les rawValues de cible partagent le même espace de
    //    noms (aligné avec Android) : quand le catalogue connaît la cible demandée,
    //    c'est LUI qui fait foi — ports corrigés compris — et non la table en dur.
    if let server = servers.first(where: { $0.id == target.migrated.rawValue && $0.selectable }) {
        return server
    }
    // 3. Table historique, pour les cibles qu'aucun catalogue ne décrit encore.
    let host: String?
    switch target.migrated {
    case .rbx: host = "rbx.proof.ovh.net"
    case .sbg: host = "sbg.proof.ovh.net"
    case .gra: host = "gra.proof.ovh.net"
    case .bom: host = "bom.proof.ovh.net"
    // Branche désormais INATTEIGNABLE : `.us` migre vers `.hybridAuto` depuis que
    // `proof.ovh.us` est mort. Conservée pour l'exhaustivité du switch, qui refuse
    // qu'on oublie un cas — c'est ce filet qui a rendu visibles les deux POPs
    // nord-américains manquants ci-dessous.
    case .us: host = "proof.ovh.us"
    case .clouviderAsh: host = "ash.speedtest.clouvider.net"
    case .leasewebMtl: host = "speedtest.mtl2.ca.leaseweb.net"
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
    case .mojiParis: host = "iperf3.moji.fr"
    case .clouviderFra: host = "fra.speedtest.clouvider.net"
    case .clouviderAms: host = "ams.speedtest.clouvider.net"
    case .clouviderLon: host = "lon.speedtest.clouvider.net"
    case .clouviderMan: host = "man.speedtest.clouvider.net"
    case .leasewebFra: host = "speedtest.fra1.de.leaseweb.net"
    case .init7: host = "speedtest.init7.net"
    // .cloudflare n'est pas un serveur iPerf3 : le moteur HTTPS est choisi en
    // amont dans run(). `.iperfCatalog` sans id résolvable, ou une cible héritée
    // disparue du catalogue, renvoie `nil` afin que l'appelant annonce le repli.
    case .hybridAuto, .cloudflare, .libreSpeed, .iperfCatalog, .bytelPoiCubic, .bhs, .cloudflareR2, .awsCloudFront, .vpsInternal:
        host = nil
    }
    if let host, let server = servers.first(where: { $0.hostname == host && $0.selectable }) {
        return server
    }
    return nil
}

/// Compatibilité des appelants historiques : cible explicite si elle existe,
/// sinon premier candidat Auto du snapshot fourni.
func selectIPerfServer(
    for target: SpeedtestDownloadTarget,
    location: Coordinates?,
    catalogId: String? = nil,
    servers: [IPerfPublicServer] = activeIPerfServers
) -> IPerfPublicServer {
    selectableIPerfServer(
        for: target,
        location: location,
        catalogId: catalogId,
        servers: servers
    ) ?? findClosestIPerfServer(to: location, servers: servers)
}

struct IPerfLatencyCandidate: Sendable, Equatable {
    let server: IPerfPublicServer
    let latencyMs: Double?
    let sourceOrder: Int
}

/// Les observations réelles passent avant les échecs ; une égalité conserve
/// l'ordre géographique initial.
func rankIPerfLatencyCandidates(_ candidates: [IPerfLatencyCandidate]) -> [IPerfLatencyCandidate] {
    candidates.sorted { lhs, rhs in
        let l = lhs.latencyMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let r = rhs.latencyMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        switch (l, r) {
        case let (left?, right?):
            return left == right ? lhs.sourceOrder < rhs.sourceOrder : left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.sourceOrder < rhs.sourceOrder
        }
    }
}

func iperfAutoCandidateShortlist(
    from location: Coordinates?,
    servers: [IPerfPublicServer] = activeIPerfServers,
    limit: Int = 4,
    excludingHostnames: Set<String> = []
) -> [IPerfPublicServer] {
    guard limit > 0 else { return [] }
    return Array(
        iperfServersSortedByDistance(from: location, servers: servers)
            .lazy
            .filter { !excludingHostnames.contains($0.hostname) }
            .prefix(limit)
    )
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

/// Mémoire courte des sondages de ports, positive ET négative.
///
/// Sans elle, chaque `run()` re-sondait tout : ~13 ports par serveur, et le dernier
/// filet essaie CHAQUE serveur du catalogue trié par distance. Dans un pays où les
/// iPerf3 sont injoignables — le cas nominal hors d'Europe — cela faisait jusqu'à
/// ~30 s de scan et plusieurs centaines de connexions TCP **par test**, répété à
/// chaque itération de la boucle Drive Test. Vu du réseau de l'opérateur, cela
/// ressemble d'ailleurs à du scan de ports.
///
/// L'échec est mis en cache plus longtemps que le succès : un serveur injoignable
/// le reste, alors qu'un port ouvert peut se remplir.
actor IPerfEndpointCache {
    static let shared = IPerfEndpointCache()

    private struct Entry {
        let endpoint: IPerfEndpoint?
        let expiry: Date
    }

    private var entries: [String: Entry] = [:]
    private var networkSignature: String?
    private static let successTTL: TimeInterval = 600   // 10 min
    private static let failureTTL: TimeInterval = 900   // 15 min

    /// La configuration de ports fait partie de l'identité de cache. Le catalogue
    /// distant peut corriger une plage ou un port préféré sans changer le hostname ;
    /// réutiliser alors l'ancien résultat ferait mesurer (ou déclarer indisponible)
    /// un endpoint qui n'appartient plus à la révision active.
    private static func key(for server: IPerfPublicServer) -> String {
        "\(server.hostname.lowercased())|\(server.portMin)-\(server.portMax)|\(server.portPreferred)"
    }

    /// Le réseau a changé (cellulaire ↔ WiFi, changement d'opérateur, itinérance) :
    /// ce qui était injoignable peut très bien répondre maintenant. Appelé une fois
    /// au début de chaque test plutôt que dispersé dans les appelants.
    func invalidateIfNetworkChanged(_ signature: String) {
        guard networkSignature != signature else { return }
        networkSignature = signature
        entries.removeAll()
    }

    func cached(_ server: IPerfPublicServer) -> IPerfEndpoint?? {
        let key = Self.key(for: server)
        guard let entry = entries[key] else { return nil }
        guard entry.expiry > Date() else { entries[key] = nil; return nil }
        return .some(entry.endpoint)
    }

    func store(_ endpoint: IPerfEndpoint?, for server: IPerfPublicServer) {
        let ttl = endpoint == nil ? Self.failureTTL : Self.successTTL
        entries[Self.key(for: server)] = Entry(
            endpoint: endpoint,
            expiry: Date().addingTimeInterval(ttl)
        )
    }

    /// Oublie l'endpoint mémorisé pour cet hôte, pour forcer un nouveau sondage.
    ///
    /// Nécessaire en rafale : le port retenu est mis en cache 10 min, mais un démon
    /// iPerf3 public est souvent MONO-SLOT. Le test suivant, lancé moins d'une seconde
    /// après, rejouait donc le même port encore occupé → `ACCESS_DENIED` → repli
    /// Cloudflare dégradé, à répétition. C'est ce qui donnait « le premier test donne
    /// un vrai chiffre, les suivants non ».
    func invalidate(_ hostname: String) {
        let prefix = "\(hostname.lowercased())|"
        for key in entries.keys.filter({ $0.hasPrefix(prefix) }) {
            entries[key] = nil
        }
    }

    func invalidateAll() {
        entries.removeAll()
        networkSignature = nil
    }
}

/// Probe TCP parallèle de la plage de ports du serveur, mémoïsé par hôte et
/// configuration de ports du catalogue.
/// Les ports « busy » (ACCESS_DENIED) sont gérés ensuite par
/// `runIPerf3WithPortFallback` au moment du vrai test.
func resolveIPerfEndpoint(for server: IPerfPublicServer) async -> IPerfEndpoint? {
    if let hit = await IPerfEndpointCache.shared.cached(server) {
        return hit
    }
    let resolved = await resolveIPerfEndpointUncached(for: server)
    await IPerfEndpointCache.shared.store(resolved, for: server)
    return resolved
}

private func resolveIPerfEndpointUncached(for server: IPerfPublicServer) async -> IPerfEndpoint? {
    let ports = iperfDiscoveryPorts(
        min: server.portMin,
        max: server.portMax,
        preferred: server.portPreferred
    )
    let openPorts = await probeOpenTCPPorts(host: server.hostname, ports: ports, timeoutSeconds: 1.0)
    guard !openPorts.isEmpty else {
        // Aucun port ouvert — retourner nil pour permettre au fallback serveur
        // de tenter un autre hôte au lieu de perdre 30s en port scanning séquentiel.
        return nil
    }
    // ⚠️ Cette sonde ne valide QUE le connect TCP, jamais le handshake iPerf3. Un
    // port MUET (TCP ouvert, démon qui ne répond jamais) la passe donc sans
    // encombre. Prendre `openPorts.first` revenait à élire ce port muet, puis à le
    // figer 10 minutes dans le cache : sur Clouvider Londres, ouvert mais muet de
    // 5200 à 5206, chaque test de la fenêtre payait le timeout avant de récupérer.
    //
    // `portPreferred` est, lui, vérifié par un handshake réel : quand il est ouvert,
    // il prime. On le remonte aussi en tête de `openPorts`, qui sert ensuite à
    // choisir le port d'upload.
    let preferred = openPorts.contains(server.portPreferred) ? server.portPreferred : openPorts[0]
    let ordered = [preferred] + openPorts.filter { $0 != preferred }
    return IPerfEndpoint(port: preferred, openPorts: ordered)
}

private let iperfPortSamplingThreshold = 15
private let iperfPortSampleMax = 18
private let iperfPortNeighborRadius = 4
private let iperfPortRangePrefix = 4

/// Ports de découverte bornés. Sur une plage large, le port annoncé et ses
/// voisins immédiats passent avant quelques bornes et points répartis.
///
/// L'ancien stride 9200/9203/9206 sautait 9202 et 9204, seuls ports réellement
/// actifs sur certains POP Bouygues.
func iperfDiscoveryPorts(
    min portMin: UInt16,
    max portMax: UInt16,
    preferred: UInt16? = nil
) -> [UInt16] {
    let lo = Swift.min(portMin, portMax)
    let hi = Swift.max(portMin, portMax)
    let all = Array(lo...hi)
    guard all.count > iperfPortSamplingThreshold + 1 else { return all }
    return prioritizedWideIPerfPortSample(min: lo, max: hi, preferred: preferred).sorted()
}

private func prioritizedWideIPerfPortSample(
    min portMin: UInt16,
    max portMax: UInt16,
    preferred: UInt16?
) -> [UInt16] {
    let lo = Int(Swift.min(portMin, portMax))
    let hi = Int(Swift.max(portMin, portMax))
    let requested = preferred.map(Int.init)
    let anchor = requested.flatMap { (lo...hi).contains($0) ? $0 : nil } ?? lo
    var sample: [UInt16] = []
    var seen = Set<UInt16>()

    func add(_ candidate: Int) {
        guard sample.count < iperfPortSampleMax, (lo...hi).contains(candidate) else { return }
        let port = UInt16(candidate)
        if seen.insert(port).inserted { sample.append(port) }
    }

    add(anchor)
    for offset in 1...iperfPortNeighborRadius {
        add(anchor - offset)
        add(anchor + offset)
    }
    for port in lo...Swift.min(hi, lo + iperfPortRangePrefix - 1) { add(port) }
    add(hi)

    let span = hi - lo
    for index in 1..<iperfPortSampleMax {
        add(lo + (span * index) / iperfPortSampleMax)
    }
    return sample
}

func iperfSiblingCandidatePorts(
    preferred: UInt16,
    min portMin: UInt16,
    max portMax: UInt16
) -> [UInt16] {
    let lo = Swift.min(portMin, portMax)
    let hi = Swift.max(portMin, portMax)
    let siblings = Array(lo...hi).filter { $0 != preferred }
    guard siblings.count > iperfPortSamplingThreshold else { return siblings }
    return prioritizedWideIPerfPortSample(min: lo, max: hi, preferred: preferred)
        .filter { $0 != preferred }
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
///
/// Sert à choisir un port de DONNÉES de repli (l'upload, qui ne peut pas réutiliser
/// le port du download). Pour une SONDE de latence, utiliser
/// `iperfLoadedLatencyProbePort` : elle seule sait renoncer.
func iperfSiblingPort(preferred: UInt16, min portMin: UInt16, max portMax: UInt16) -> UInt16 {
    let lo = min(portMin, portMax)
    let hi = max(portMin, portMax)
    guard hi > lo else { return preferred }
    if preferred < hi { return preferred &+ 1 }
    return lo
}

/// Port de SONDE pour la latence sous charge — jamais un port de données actif.
///
/// Vise le HAUT de la plage. Le download part du bas et l'upload prend le voisin
/// immédiat : le haut ne gêne donc ni l'un ni l'autre, et surtout il n'entre pas en
/// concurrence avec le port-walk. `iperfSiblingPort` visait `actif + 1`,
/// c'est-à-dire précisément le port que le walk et l'upload allaient réclamer
/// ensuite — un conflit qu'on s'infligeait à soi-même.
///
/// Renvoie `nil` quand la plage ne permet pas d'éviter les ports occupés : on saute
/// alors l'échantillon plutôt que d'ouvrir une connexion sur le port de données, ce
/// qui RST le démon iPerf3 en pleine mesure et fausse à la fois la latence ET le
/// débit. Le cas n'a rien de théorique : plusieurs POPs publics du catalogue
/// n'exposent qu'un seul port, et l'ancienne fonction y renvoyait le port actif.
///
/// Miroir de `computeLoadedLatencyProbePort` côté Android : les deux doivent rester
/// alignés, faute de quoi les latences chargées des deux plateformes cessent d'être
/// comparables.
func iperfLoadedLatencyProbePort(
    avoiding busyPorts: Set<UInt16>,
    min portMin: UInt16,
    max portMax: UInt16
) -> UInt16? {
    let lo = min(portMin, portMax)
    let hi = max(portMin, portMax)
    guard hi > lo else { return nil }
    var candidate = hi
    while candidate >= lo {
        if !busyPorts.contains(candidate) { return candidate }
        if candidate == lo { break }
        candidate -= 1
    }
    return nil
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
    let deadline = speedtestMonotonicSeconds() + timeoutSeconds
    while buffer.count < count {
        let remaining = count - buffer.count
        let remainingTime = deadline - speedtestMonotonicSeconds()
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
    private(set) var lastBytes = 0
    private(set) var lastTime = 0.0

    func interval(bytes: Int, time: Double) -> (start: Double, end: Double, bytes: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= lastBytes, time > lastTime else { return nil }
        let result = (start: lastTime, end: time, bytes: bytes - lastBytes)
        lastBytes = bytes; lastTime = time
        return result
    }
    func update(bytes: Int, time: Double) -> Int { interval(bytes: bytes, time: time)?.bytes ?? 0 }
    func reset() { lock.lock(); lastBytes = 0; lastTime = 0; lock.unlock() }
}

private func speedtestMonotonicSeconds() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

class SafeCounter: @unchecked Sendable {
    struct TimedSnapshot: Sendable { let timestamp: TimeInterval; let bytes: Int }
    private let lock = NSLock()
    private var bytes: Int = 0
    private var closedSnapshot: TimedSnapshot?
    private var baselineSnapshot: TimedSnapshot?
    private let onDelta: (@Sendable (Int) -> Void)?

    init(onDelta: (@Sendable (Int) -> Void)? = nil) { self.onDelta = onDelta }

    func add(_ count: Int) {
        lock.lock()
        // The sender also uses this type for its in-flight slot count: decrements
        // must release slots. Measurement counters only receive positive bytes.
        bytes = max(0, bytes + count)
        if count > 0 { onDelta?(count) }
        lock.unlock()
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return closedSnapshot?.bytes ?? bytes
    }
    var trafficValue: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }
    func snapshot() -> Int { value }
    func timedSnapshot() -> TimedSnapshot {
        lock.lock(); defer { lock.unlock() }
        return closedSnapshot ?? TimedSnapshot(timestamp: speedtestMonotonicSeconds(), bytes: bytes)
    }
    func markMeasurementStart() -> TimedSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let baselineSnapshot { return baselineSnapshot }
        let snapshot = TimedSnapshot(timestamp: speedtestMonotonicSeconds(), bytes: bytes)
        baselineSnapshot = snapshot
        return snapshot
    }
    var measurementStart: TimedSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return baselineSnapshot
    }
    func close() -> TimedSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let closedSnapshot { return closedSnapshot }
        let snapshot = TimedSnapshot(timestamp: speedtestMonotonicSeconds(), bytes: bytes)
        closedSnapshot = snapshot
        return snapshot
    }
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

    func reset() { lock.lock(); rawBytes = 0; rawMs = 0; lock.unlock() }

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
        case .cancelled: return String(localized: "Connexion iPerf3 annulée")
        case .timeout: return String(localized: "Délai dépassé sur le serveur iPerf3")
        case .emptyRead: return "Lecture iPerf3 vide"
        case .connectionClosed(let got, let expected):
            return String(localized: "Connexion iPerf3 fermée (\(got)/\(expected) octets)")
        case .accessDenied: return String(localized: "Serveur iPerf3 occupé (ACCESS_DENIED)")
        case .serverError: return "Erreur serveur iPerf3"
        case .invalidJSON: return String(localized: "Réponse iPerf3 JSON invalide")
        case .incomplete: return "Test iPerf3 incomplet"
        case .invalidPort: return "Port iPerf3 invalide"
        case .unexpectedState(let s): return String(localized: "État iPerf3 inattendu (\(s))")
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
    var serverBytesUsed: Bool = false
    var clientMeasuredDuration: Double? = nil
    var clientDuration: Double { clientMeasuredDuration ?? measuredDuration }
    var finalServerMeasurement: SpeedtestFinalMeasurement? {
        guard serverBytesUsed else { return nil }
        let duration = max(1, Int64((measuredDuration * 1000).rounded()))
        return .init(bytes: Int64(measuredBytes), durationMs: duration, source: "server-received",
            averageMbps: SpeedtestTraceMath.mbps(bytes: Double(measuredBytes), durationMs: duration), maxMbps: nil,
            peakWindowMs: max(1000, Int64(Double(duration) * 0.3)), samples: [])
    }

    var averageMbps: Double {
        guard measuredBytes > 0, measuredDuration > 0 else { return 0 }
        let mbps = (Double(measuredBytes) * 8.0 / 1_000_000.0) / measuredDuration
        return mbps.isFinite && mbps >= 0 ? mbps : 0
    }

    /// Compat : ancien champ `duration`.
    var duration: Double { measuredDuration }
}

struct IPerf3ServerMeasurement: Equatable, Sendable {
    let bytes: Int
    let duration: Double
}

/// ESnet EXCHANGE_RESULTS streams carry their own post-omit start_time/end_time.
/// Never divide a server byte counter by the client's clock or nominal duration.
func iperf3ExtractServerMeasurement(from json: [String: Any]?) -> IPerf3ServerMeasurement? {
    func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991,
              value.rounded(.down) == value else { return nil }
        return Int(value)
    }
    if let streams = json?["streams"] as? [[String: Any]], !streams.isEmpty {
        var bytes = 0
        var start = Double.infinity, end = -Double.infinity
        for stream in streams {
            guard let value = count(stream["bytes"]),
                  let lower = stream["start_time"] as? Double, lower.isFinite, lower >= 0,
                  let upper = stream["end_time"] as? Double, upper.isFinite, upper > lower,
                  bytes <= 9_007_199_254_740_991 - value else { return nil }
            bytes += value; start = min(start, lower); end = max(end, upper)
        }
        guard end - start >= 0.001, (end - start) * 1000 <= 9_007_199_254_740_991 else { return nil }
        return .init(bytes: bytes, duration: end - start)
    }
    if let end = json?["end"] as? [String: Any], let received = end["sum_received"] as? [String: Any],
       let bytes = count(received["bytes"]), let seconds = received["seconds"] as? Double,
       seconds.isFinite, seconds >= 0.001, seconds * 1000 <= 9_007_199_254_740_991 {
        return .init(bytes: bytes, duration: seconds)
    }
    return nil
}

func iperf3SelectMeasurement(clientBytes: Int, clientDuration: Double, wallDuration: Double,
                            isDownload: Bool, server: IPerf3ServerMeasurement?) -> IPerf3Result {
    if !isDownload, let server {
        return .init(measuredBytes: server.bytes, clientBytes: clientBytes, serverBytes: server.bytes,
            measuredDuration: server.duration, wallDuration: wallDuration, serverBytesUsed: true,
            clientMeasuredDuration: clientDuration)
    }
    return .init(measuredBytes: clientBytes, clientBytes: clientBytes, serverBytes: server?.bytes,
        measuredDuration: clientDuration, wallDuration: wallDuration, serverBytesUsed: false,
        clientMeasuredDuration: clientDuration)
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

// MARK: - LibreSpeed (moteur HTTPS open-source, alternative propre à Ookla)

/// Schéma de chemin d'un backend LibreSpeed. Le préfixe varie selon le
/// déploiement : PHP « standard » sous `/backend/`, PHP à la racine, ou backend
/// Go (endpoints sans extension `.php`). Chaque serveur porte donc le sien.
enum LibreSpeedPathScheme: String, Sendable {
    case backendPHP   // /backend/garbage.php, /backend/empty.php
    case rootPHP      // /garbage.php, /empty.php
    case go           // /garbage, /empty  (backend Go, sans .php)
}

/// Un backend LibreSpeed public (HTTPS, cert valide → ATS-OK). Sélectionné par
/// distance en mode `.libreSpeed`. Data-driven : ajouter un serveur = une entrée.
struct LibreSpeedServer: Sendable {
    let hostname: String
    let name: String
    let latitude: Double
    let longitude: Double
    let countryCode: String
    let pathScheme: LibreSpeedPathScheme

    private var prefix: String { pathScheme == .backendPHP ? "/backend" : "" }
    private var ext: String { pathScheme == .go ? "" : ".php" }

    /// Download : renvoie `ckSizeMiB` Mio de données incompressibles (chunké,
    /// souvent sans Content-Length → compter les octets REÇUS).
    func downloadURL(ckSizeMiB: Int) -> URL {
        var c = URLComponents()
        c.scheme = "https"; c.host = hostname
        c.path = "\(prefix)/garbage\(ext)"
        c.queryItems = [URLQueryItem(name: "ckSize", value: String(max(1, ckSizeMiB)))]
        return c.url!
    }

    /// Upload : puits qui absorbe le corps POST (limité en taille côté serveur).
    var uploadURL: URL {
        URL(string: "https://\(hostname)\(prefix)/empty\(ext)")!
    }
}

enum LibreSpeedConfig {
    static let httpsPort: UInt16 = 443
    /// Taille demandée par requête DL (le serveur plafonne ~1024 Mio ; assez gros
    /// pour qu'un lien rapide n'enchaîne pas les requêtes, la deadline borne).
    static let downloadCkSizeMiB = 200
    /// Corps par requête UL. Les serveurs LibreSpeed plafonnent le POST via
    /// `post_max_size` — très variable : Clouvider accepte ~5 Mo, mais HostKey
    /// Paris **refuse dès 1,5 Mo** (413). Un bloc trop gros fait échouer TOUT
    /// l'upload sur ces serveurs. On prend donc une taille universellement sûre
    /// (1 Mo, sous la limite HostKey) et on sature par la concurrence (6 flux).
    static let uploadBytesPerRequest = 1_000_000
    static let maxStreams = 6
    static let maxUploadStreams = 6
}

/// Catalogue LibreSpeed public — HTTPS cert valide vérifié (2026-07). Les POP
/// Clouvider font iPerf3 ET LibreSpeed ; HostKey Paris est un hébergeur FR.
/// Étendu au fil des découvertes (recherche mondiale). Sélection par distance.
let libreSpeedServers: [LibreSpeedServer] = [
    // Clouvider — Europe (proches FR d'abord)
    LibreSpeedServer(hostname: "fra.speedtest.clouvider.net", name: "Francfort (Clouvider)", latitude: 50.1109, longitude: 8.6821, countryCode: "DE", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "ams.speedtest.clouvider.net", name: "Amsterdam (Clouvider)", latitude: 52.3676, longitude: 4.9041, countryCode: "NL", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "lon.speedtest.clouvider.net", name: "Londres (Clouvider)", latitude: 51.5074, longitude: -0.1278, countryCode: "GB", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "man.speedtest.clouvider.net", name: "Manchester (Clouvider)", latitude: 53.4808, longitude: -2.2426, countryCode: "GB", pathScheme: .backendPHP),
    // NB : HostKey Paris (spd-frsrv.hostkey.com) RETIRÉ — son TLS passe `curl`
    // mais est refusé par l'ATS iOS (« TLS error »), donc inutilisable par l'app.
    // (Un utilisateur FR tombe sur Clouvider Londres/Amsterdam, les plus proches.)
    // Clouvider — USA
    LibreSpeedServer(hostname: "nyc.speedtest.clouvider.net", name: "New York (Clouvider)", latitude: 40.7128, longitude: -74.0060, countryCode: "US", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "atl.speedtest.clouvider.net", name: "Atlanta (Clouvider)", latitude: 33.7490, longitude: -84.3880, countryCode: "US", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "dal.speedtest.clouvider.net", name: "Dallas (Clouvider)", latitude: 32.7767, longitude: -96.7970, countryCode: "US", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "la.speedtest.clouvider.net", name: "Los Angeles (Clouvider)", latitude: 34.0522, longitude: -118.2437, countryCode: "US", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "phx.speedtest.clouvider.net", name: "Phoenix (Clouvider)", latitude: 33.4484, longitude: -112.0740, countryCode: "US", pathScheme: .backendPHP),
    // Europe — communautaires vérifiés (HTTPS cert valide, ckSize honoré, juil. 2026)
    LibreSpeedServer(hostname: "amsspeed.sharktech.net", name: "Amsterdam (Sharktech)", latitude: 52.3676, longitude: 4.9041, countryCode: "NL", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "de3.backend.librespeed.org", name: "Nuremberg (LibreSpeed)", latitude: 49.4521, longitude: 11.0767, countryCode: "DE", pathScheme: .rootPHP),
    LibreSpeedServer(hostname: "de5.backend.librespeed.org", name: "Nuremberg (LibreSpeed)", latitude: 49.4521, longitude: 11.0767, countryCode: "DE", pathScheme: .rootPHP),
    LibreSpeedServer(hostname: "speedtest.retzo.net", name: "Falkenstein (Retzo)", latitude: 50.4779, longitude: 12.3713, countryCode: "DE", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "librespeed.turris.cz", name: "Prague (Turris)", latitude: 50.0755, longitude: 14.4378, countryCode: "CZ", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "speedtest.cesnet.cz", name: "Prague (CESNET)", latitude: 50.0755, longitude: 14.4378, countryCode: "CZ", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "speedtest.kamilszczepanski.com", name: "Poznań", latitude: 52.4064, longitude: 16.9252, countryCode: "PL", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "www.librespeed.fi", name: "Helsinki (LibreSpeed.fi)", latitude: 60.1699, longitude: 24.9384, countryCode: "FI", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "argalasti.skoultsos.eu", name: "Argalasti", latitude: 39.2333, longitude: 23.2333, countryCode: "GR", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "st-be-rm2.infra.garr.it", name: "Rome (GARR)", latitude: 41.9028, longitude: 12.4964, countryCode: "IT", pathScheme: .rootPHP),
    // Amérique du Nord — Sharktech / RackGenius (hors Clouvider)
    LibreSpeedServer(hostname: "chispeed.sharktech.net", name: "Chicago (Sharktech)", latitude: 41.8781, longitude: -87.6298, countryCode: "US", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "mispeed.rackgenius.com", name: "Grand Rapids (RackGenius)", latitude: 42.9634, longitude: -85.6681, countryCode: "US", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "denspeed.sharktech.net", name: "Denver (Sharktech)", latitude: 39.7392, longitude: -104.9903, countryCode: "US", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "laxspeed.sharktech.net", name: "Los Angeles (Sharktech)", latitude: 34.0522, longitude: -118.2437, countryCode: "US", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "lasspeed.sharktech.net", name: "Las Vegas (Sharktech)", latitude: 36.1699, longitude: -115.1398, countryCode: "US", pathScheme: .backendPHP),
    // Amérique du Sud (seules options publiques valides)
    LibreSpeedServer(hostname: "speedtest.tdi.ind.br", name: "Brésil (TDI)", latitude: -23.5505, longitude: -46.6333, countryCode: "BR", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "blm.testepower.com.br", name: "Blumenau", latitude: -26.9194, longitude: -49.0661, countryCode: "BR", pathScheme: .backendPHP),
    LibreSpeedServer(hostname: "speedtest.dpt.gba.gob.ar", name: "Buenos Aires", latitude: -34.6037, longitude: -58.3816, countryCode: "AR", pathScheme: .backendPHP),
    // Asie (unique nœud public à cert valide ; filtre UA curl, OK avec l'UA iOS)
    LibreSpeedServer(hostname: "librespeed.a573.net", name: "Tokyo", latitude: 35.6762, longitude: 139.6503, countryCode: "JP", pathScheme: .backendPHP),
]

/// POP LibreSpeed le plus proche (repli sur le 1er du catalogue sans GPS).
func nearestLibreSpeedServer(to location: Coordinates?) -> LibreSpeedServer {
    guard let location else { return libreSpeedServers[0] }
    return libreSpeedServers.min { a, b in
        haversineDistanceKm(from: location, to: Coordinates(latitude: a.latitude, longitude: a.longitude))
            < haversineDistanceKm(from: location, to: Coordinates(latitude: b.latitude, longitude: b.longitude))
    } ?? libreSpeedServers[0]
}

extension LibreSpeedServer {
    /// Continent (pour le regroupement du sélecteur).
    var continent: String {
        switch countryCode {
        case "FR", "DE", "NL", "GB", "CZ", "PL", "FI", "GR", "IT", "ES", "CH", "SE", "NO", "DK", "AT", "BE", "IE", "PT":
            return "Europe"
        case "US", "CA": return String(localized: "Amérique du Nord")
        case "BR", "AR", "CL", "CO", "PE", "UY": return String(localized: "Amérique du Sud")
        case "JP", "CN", "KR", "IN", "SG", "HK", "TW", "TH", "VN", "MY", "ID": return "Asie"
        case "AU", "NZ": return String(localized: "Océanie")
        default: return "Autres"
        }
    }
    var continentRank: Int {
        ["Europe": 0, "Amérique du Nord": 1, "Amérique du Sud": 2, "Asie": 3, "Océanie": 4][continent] ?? 5
    }
    /// Sous-titre du sélecteur : « Pays · hostname ».
    var pickerSubtitle: String { "\(countryCode) · \(hostname)" }
}

/// Serveurs LibreSpeed groupés par continent (ordre stable) pour le sélecteur.
func libreSpeedPickerGroups() -> [(region: String, servers: [LibreSpeedServer])] {
    let sorted = libreSpeedServers.sorted {
        $0.continentRank != $1.continentRank ? $0.continentRank < $1.continentRank : $0.name < $1.name
    }
    var groups: [(region: String, servers: [LibreSpeedServer])] = []
    for s in sorted {
        if let i = groups.firstIndex(where: { $0.region == s.continent }) { groups[i].servers.append(s) }
        else { groups.append((region: s.continent, servers: [s])) }
    }
    return groups
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

let iperfFirstControlStateTimeoutSeconds: TimeInterval = 3
let iperfSubsequentControlStateTimeoutSeconds: TimeInterval = 60

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
        // Filet de sécurité : `onCancel` ne s'exécute QUE sur annulation. Si
        // `runInternal` lève (timeout de lecture, erreur serveur iPerf3), le
        // ticker de progression — qui boucle sur `while isTestRunning.value` —
        // continuait d'émettre pendant que le repli Cloudflare pilotait déjà
        // l'aiguille et la Live Activity : deux sources concurrentes sur le même
        // cadran. Le `defer` couvre succès, échec et annulation.
        defer { isTestRunning.value = false }
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
        let recorder = SpeedtestTraceScope.current
        let attemptId = UUID().uuidString
        let attemptStart = speedtestMonotonicSeconds()
        var retained = false
        defer {
            if !retained { recorder?.abandon(phase: isDownload ? "download" : "upload", id: attemptId,
                                             start: attemptStart, reason: "TRANSFER_FAILED") }
        }
        let traceSamples = SpeedtestSamplesBox()
        let traceState = ProgressState()
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

        let phaseName = isDownload ? "download" : "upload"
        let totalBytesCounter = SafeCounter(onDelta: { bytes in recorder?.recordTraffic(phase: phaseName, bytes: bytes) })
        let omitBytesCounter = SafeCounter()
        var startTestTime: TimeInterval?
        var transferEndTime: TimeInterval?
        let serverEnded = AtomicBool(false)
        var finishedResult: IPerf3Result?
        var enderStarted = false

        var hasReceivedControlState = false
        while finishedResult == nil {
            let controlStateTimeout = hasReceivedControlState
                ? iperfSubsequentControlStateTimeoutSeconds
                : iperfFirstControlStateTimeoutSeconds
            let raw = try await readExactNW(
                controlConnection,
                count: 1,
                timeoutSeconds: controlStateTimeout
            )
            hasReceivedControlState = true
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
                startTestTime = speedtestMonotonicSeconds()

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
                let phaseStart = startTestTime ?? speedtestMonotonicSeconds()
                Task {
                    let omit = Double(omitCap)
                    let measure = Double(measureCap)
                    let start = phaseStart
                    // Phase omit — feedback live pour l'aiguille du cadran.
                    while isTestRunning.value {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard isTestRunning.value, !Task.isCancelled else { break }
                        let wall = speedtestMonotonicSeconds() - start
                        if wall >= omit { break }
                        warmupHandler?(totalBytesCounter.value, wall)
                    }
                    guard isTestRunning.value, !Task.isCancelled else { return }
                    let omitSnapshot = totalBytesCounter.markMeasurementStart()
                    // The bridge receives the actual byte/time boundary, not the previous tick.
                    warmupHandler?(omitSnapshot.bytes, omitSnapshot.timestamp - start)
                    let bytesAtOmit = omitSnapshot.bytes
                    if omitBytesCounter.value == 0, bytesAtOmit > 0 {
                        omitBytesCounter.add(bytesAtOmit)
                    }
                    // Phase de mesure utile.
                    while isTestRunning.value {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard isTestRunning.value, !Task.isCancelled else { break }
                        let wall = speedtestMonotonicSeconds() - start
                        let current = totalBytesCounter.timedSnapshot()
                        let usefulElapsed = max(0, current.timestamp - omitSnapshot.timestamp)
                        let usefulBytes = max(0, current.bytes - omitSnapshot.bytes)
                        if let interval = traceState.interval(bytes: usefulBytes, time: usefulElapsed * 1000) {
                            traceSamples.append(start: interval.start, end: interval.end, bytes: interval.bytes)
                        }
                        progressHandler?(usefulBytes, usefulElapsed)
                        if usefulElapsed >= measure { break }
                    }
                    _ = totalBytesCounter.close()
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
                if transferEndTime == nil { transferEndTime = totalBytesCounter.close().timestamp }

            case 13: // EXCHANGE_RESULTS
                serverEnded.value = true
                isTestRunning.value = false
                if transferEndTime == nil { transferEndTime = totalBytesCounter.close().timestamp }
                for conn in dataConnections { conn.cancel() }
                dataConnections.removeAll()
                activeSenders.removeAll()
                activeReceivers.removeAll()

                let frozen = totalBytesCounter.close()
                let wall = frozen.timestamp - (startTestTime ?? frozen.timestamp)
                guard let baseline = totalBytesCounter.measurementStart else { throw IPerf3Error.incomplete }
                let measuredDuration = max(0.001, frozen.timestamp - baseline.timestamp)
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
                let receipt = iperf3ExtractServerMeasurement(from: serverResults)
                finishedResult = iperf3SelectMeasurement(clientBytes: clientUseful, clientDuration: measuredDuration,
                    wallDuration: max(measuredDuration, wall), isDownload: isDownload, server: receipt)

            case 14: // DISPLAY_RESULTS
                try? await sendCommand(controlConnection, 16) // IPERF_DONE
                if finishedResult == nil {
                    let frozen = totalBytesCounter.close()
                let wall = frozen.timestamp - (startTestTime ?? frozen.timestamp)
                    guard let baseline = totalBytesCounter.measurementStart else { throw IPerf3Error.incomplete }
                    let measuredDuration = max(0.001, frozen.timestamp - baseline.timestamp)
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
        if let baseline = totalBytesCounter.measurementStart {
            let final = totalBytesCounter.close()
            let durationMs = (final.timestamp - baseline.timestamp) * 1000
            let bytes = max(0, final.bytes - baseline.bytes)
            if let interval = traceState.interval(bytes: bytes, time: durationMs) {
                traceSamples.append(start: interval.start, end: interval.end, bytes: interval.bytes)
            }
            onProgress?(bytes, durationMs / 1000)
            recorder?.retain(phase: isDownload ? "download" : "upload", id: attemptId,
                start: attemptStart, baseline: baseline.timestamp, end: final.timestamp,
                measuredBytes: result.clientBytes, totalBytes: totalBytesCounter.trafficValue,
                source: isDownload ? "client-received" : "client-written",
                samples: traceSamples.snapshotIntervals(), finalMeasurement: result.finalServerMeasurement)
            retained = true
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
        // `load(as:)` EXIGE un pointeur aligné sur 4 octets pour UInt32 et trappe
        // sinon (« load from misaligned raw pointer »). `lengthData` est
        // reconstruite depuis des buffers réseau : son adresse de base n'offre
        // aucune garantie d'alignement. `loadUnaligned` (iOS 16+) est l'idiome sûr.
        let length = UInt32(bigEndian: lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
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
                if error == nil {
                    self.totalBytes.add(size)
                    if self.isRunning.value { self.sendNext() }
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

/// Échelle de repli de l'upload, du plus ambitieux au plus prudent.
///
/// Fonction libre pour rester testable : la configuration du moteur est `private`, et
/// c'est exactement le genre de logique qui casse en silence — une échelle qui remonte,
/// ou qui rejoue deux fois le même palier, ne se voit dans aucune capture.
///
/// Strictement décroissante et dédoublonnée : demander 4 flux doit donner `[4]`, pas
/// `[4, 8, 4]` — qui essaierait plus haut que la demande puis répéterait un échec.
func speedtestUploadStreamLadder(requested: Int, hardMax: Int, fallback: Int, last: Int) -> [Int] {
    let top = min(max(requested, 1), max(hardMax, 1))
    var ladder: [Int] = []
    for rung in [top, fallback, last] where rung >= 1 && rung <= top && !ladder.contains(rung) {
        ladder.append(rung)
    }
    return ladder
}

/// Échantillons ICMP RETENUS pour la mesure, à partir de la série brute.
///
/// Le premier écho est écarté : il paie la mise en route du chemin radio et sa
/// valeur est systématiquement gonflée. Les RTT nuls ou négatifs le sont aussi —
/// ce sont des échos perdus, pas des latences de 0 ms.
///
/// Fonction dédiée parce que cette transformation sert DEUX fois : pour la valeur
/// affichée en direct pendant la mesure, et pour le résultat final. Les écrire
/// séparément les laisserait diverger, et la divergence serait invisible en test
/// tout en étant parfaitement visible à l'écran — la latence affichée changerait
/// au moment où le résultat remplace le direct.
func speedtestIcmpMeasuredValues(_ samples: [ICMPPinger.Sample]) -> [Double] {
    samples.dropFirst().map(\.rttMs).filter { $0 > 0 }
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
    private let deadline: TimeInterval
    private let onBytes: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var responseError: Error?
    private var receivedBytes = 0

    init(deadline: TimeInterval, onBytes: @escaping @Sendable (Int) -> Void) {
        self.deadline = deadline
        self.onBytes = onBytes
    }

    func run(task: URLSessionDataTask) async throws {
        let taskBox = SpeedtestURLSessionTaskBox()
        let timeoutTask = Task { [deadline, taskBox] in
            let seconds = max(0, deadline - speedtestMonotonicSeconds())
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
        guard count > 0 else { return }
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
            if isCancellation(error), speedtestMonotonicSeconds() >= deadline, byteCount > 0 {
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
    private let deadline: TimeInterval
    private let onBytesSent: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SpeedtestUploadTaskResult, Error>?
    private var responseData = Data()
    private var httpStatusCode: Int?
    private var receivedResponse = false
    private var sentBytes = 0

    init(deadline: TimeInterval, onBytesSent: @escaping @Sendable (Int) -> Void) {
        self.deadline = deadline
        self.onBytesSent = onBytesSent
    }

    func run(task: URLSessionUploadTask) async throws -> SpeedtestUploadTaskResult {
        let taskBox = SpeedtestURLSessionTaskBox()
        let timeoutTask = Task { [deadline, taskBox] in
            let seconds = max(0, deadline - speedtestMonotonicSeconds())
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
        onBytesSent(count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = snapshotResult()
        if let error, !(isCancellation(error) && speedtestMonotonicSeconds() >= deadline && result.sentBytes > 0) {
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

    func reset() { lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock() }

    func append(start: Double, end: Double, bytes: Int) {
        guard bytes >= 0, end > start else { return }
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

    /// Débit crête « nPerf » : moyenne de la MEILLEURE fenêtre glissante couvrant
    /// `SpeedtestEngineConfig.peakWindowRatio` de la durée utile.
    ///
    /// Remplace l'ancien « max des fenêtres d'1 s », qui mesurait autre chose : une
    /// rafale de 600 ms suffisait à le faire doubler, alors qu'elle ne représente
    /// pas un débit tenu. Trois conséquences voulues — la valeur baisse sur les
    /// liens instables (c'est le but), elle devient comparable au débit crête
    /// annoncé par nPerf, et elle s'élargit avec la durée du test au lieu de rester
    /// figée à 1 s.
    ///
    /// Fenêtres ancrées sur la FIN de chaque échantillon, pas tuilées depuis zéro :
    /// une tuile fixe coupe en deux une rafale à cheval sur sa frontière et la
    /// dilue. C'est aussi ce que fait déjà Android, et les deux plateformes doivent
    /// donner le même nombre sur la même trace.
    ///
    /// `flooredAt` garde le filet existant : un pic ne peut pas être sous la
    /// moyenne du test.
    func snapshotIntervals() -> [SpeedtestMeasurementInterval] {
        lock.lock()
        defer { lock.unlock() }
        var result: [SpeedtestMeasurementInterval] = []
        for sample in samples {
            let start = Int64(sample.startMs.rounded()), end = Int64(sample.endMs.rounded())
            if end > start {
                result.append(.init(startMs: start, endMs: end, bytes: Int64(sample.bytes)))
            } else if let previous = result.popLast() {
                result.append(.init(startMs: previous.startMs, endMs: previous.endMs, bytes: previous.bytes + Int64(sample.bytes)))
            }
        }
        return result
    }

    func nperfPeakMbps(usefulDurationMs: Double, flooredAt average: Double) -> Double {
        let window = max(1000, Int64((usefulDurationMs * 0.30).rounded(.down)))
        return max(average, SpeedtestTraceMath.windows(snapshotIntervals(), windowMs: window).map(\.mbps).max() ?? 0)
    }

    func publicStats(windowMs: Double, graceMs: Double, endMs: Double) -> PublicStats {
        let start = Int64(graceMs.rounded()), end = Int64(endMs.rounded())
        let clipped = snapshotIntervals().compactMap { sample -> SpeedtestMeasurementInterval? in
            let lower = max(start, sample.startMs), upper = min(end, sample.endMs)
            guard upper > lower else { return nil }
            let bytes = (Double(sample.bytes) * Double(upper - lower) / Double(sample.endMs - sample.startMs)).rounded()
            return SpeedtestMeasurementInterval(startMs: lower, endMs: upper, bytes: Int64(bytes))
        }
        let speeds = SpeedtestTraceMath.windows(clipped, windowMs: Int64(windowMs.rounded())).map(\.mbps)
        return PublicStats(p90: SpeedtestTraceMath.percentile(speeds, 0.90), p95: SpeedtestTraceMath.percentile(speeds, 0.95),
                           peak: speeds.max() ?? 0, windowCount: speeds.count, seriesMbps: speeds)
    }

}

/// Émetteur du débit live pour l'aiguille du cadran : débit INSTANTANÉ calculé
/// sur une fenêtre GLISSANTE (~1 s) de relevés cumulés, lissé par un léger EMA
/// pour éviter le tremblement. L'aiguille suit ainsi le réseau en temps réel —
/// l'ancienne version affichait la moyenne cumulée lissée, qui traînait
/// systématiquement derrière le débit courant. La valeur FINALE affichée reste
/// la moyenne cumulée post-grace, calculée en fin de phase (inchangée).
/// `@unchecked Sendable` : la conformité est assurée par le verrou ci-dessous,
/// pas par le compilateur. L'état était auparavant muté SANS synchronisation
/// alors que `observe(...)` est appelé depuis les callbacks `NWConnection`
/// (queues réseau) : deux `append`/`removeFirst` concurrents sur un `Array`
/// Swift corrompent le buffer et font crasher le processus.
/// Volume de données consommé par les speedtests, tous moteurs confondus.
///
/// Un Drive Test enchaîne les tests, et un test vaut débit × durée : ~375 Mo à
/// 300 Mb/s sur 10 s. Sans compteur, une session pouvait engloutir plusieurs
/// dizaines de gigaoctets du forfait de l'utilisateur sans que rien ne l'indique.
///
/// Le comptage se fait ICI, dans l'échantillonneur, et non dans chacun des trois
/// moteurs : ils lui passent tous des totaux cumulés monotones, donc la somme des
/// deltas par instance vaut exactement le volume transféré — rampe comprise.
final class SpeedtestDataMeter: @unchecked Sendable {
    static let shared = SpeedtestDataMeter()

    private let total = OSAllocatedUnfairLock(initialState: 0)

    /// Octets consommés depuis le dernier `reset()`.
    var bytes: Int { total.withLock { $0 } }

    func add(_ delta: Int) {
        guard delta > 0 else { return }
        total.withLock { $0 += delta }
    }

    func reset() { total.withLock { $0 = 0 } }
}

final class SpeedtestLiveSampler: @unchecked Sendable {
    private struct Point {
        let elapsedMs: Double
        let totalBytes: Int
    }

    private struct State {
        var points: [Point] = []
        var emaMbps: Double = 0
        /// Dernier débit instantané NON lissé (fenêtre glissante brute) — sert
        /// notamment à la décision de grace adaptative.
        var lastInstantMbps: Double = 0
        /// Dernier total cumulé vu, pour n'ajouter au compteur global que le
        /// delta — un total ne s'additionne pas, il se dérive.
        var lastCountedTotal: Int = 0
    }

    private let windowMs: Double
    private let smoothing: Double
    private let state = OSAllocatedUnfairLock(initialState: State())

    func reset() { state.withLock { $0 = State() } }

    var lastInstantMbps: Double { state.withLock { $0.lastInstantMbps } }

    init(windowMs: Double = 1_000, smoothing: Double = 0.35) {
        self.windowMs = max(1, windowMs)
        self.smoothing = min(1, max(0.01, smoothing))
    }

    /// À appeler à chaque tick avec le TOTAL cumulé d'octets : renvoie le débit
    /// instantané lissé (fenêtre glissante), indépendant de la grace — pendant
    /// le warm-up l'aiguille montre déjà le débit réel, seule la moyenne
    /// l'exclut.
    func observe(totalBytes: Int, elapsedMs: Double) -> Double {
        state.withLock { s in
            // Comptabilise le volume AVANT toute sortie anticipée : les premiers
            // ticks repartent par `guard s.points.count >= 2` et leurs octets
            // seraient sinon perdus du compteur.
            SpeedtestDataMeter.shared.add(totalBytes - s.lastCountedTotal)
            s.lastCountedTotal = max(s.lastCountedTotal, totalBytes)
            guard elapsedMs.isFinite, elapsedMs > 0, totalBytes >= 0 else { return s.emaMbps }
            if s.points.isEmpty { s.points.append(Point(elapsedMs: 0, totalBytes: 0)) }
            guard let previous = s.points.last, elapsedMs > previous.elapsedMs, totalBytes >= previous.totalBytes else { return s.emaMbps }
            let tickMs = elapsedMs - previous.elapsedMs
            s.points.append(Point(elapsedMs: elapsedMs, totalBytes: totalBytes))
            // Conserve un point au-delà de la fenêtre pour que le delta couvre
            // toujours ~windowMs une fois la fenêtre remplie.
            while s.points.count > 2, s.points[1].elapsedMs <= elapsedMs - windowMs {
                s.points.removeFirst()
            }
            guard s.points.count >= 2, let first = s.points.first else { return s.emaMbps }
            let lower = max(0, elapsedMs - windowMs)
            let second = s.points[1]
            let ratio = max(0, min(1, (lower - first.elapsedMs) / (second.elapsedMs - first.elapsedMs)))
            let baseline = Double(first.totalBytes) + Double(second.totalBytes - first.totalBytes) * ratio
            let spanMs = elapsedMs - lower
            guard spanMs > 0 else { return s.emaMbps }
            let instant = max(0, Double(totalBytes) - baseline) * 8 / spanMs / 1000
            s.lastInstantMbps = instant
            if s.emaMbps == 0 {
                s.emaMbps = instant
            } else {
                let alpha = 1 - pow(1 - smoothing, tickMs / 150)
                s.emaMbps = (alpha * instant) + ((1 - alpha) * s.emaMbps)
            }
            return s.emaMbps
        }
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
    /// Portée capturée à la création. `nil` désigne une ancienne entrée mise en
    /// quarantaine et jamais attribuée automatiquement au compte courant.
    var ownerScopeId: String? = LocalAccountScope.currentOwnerScopeId
}

/// File des sauvegardes speedtest en attente, abstraite pour offrir deux implémentations
/// derrière la MÊME API asynchrone :
/// - **iOS 17+** : `SwiftDataSpeedtestPendingStore` (vraie base embarquée SwiftData) ;
/// - **iOS 16**  : repli `DiskCacheSpeedtestPendingStore` (JSON durable, Application Support).
protocol SpeedtestPendingStoring: Sendable {
    func loadAll() async -> [PendingSpeedtestSave]
    func replaceAll(_ values: [PendingSpeedtestSave]) async throws
    /// Insère/remplace UNE entrée (par `id`) de façon atomique côté store. Évite le
    /// read-modify-write multi-appels de l'ancien chemin, où deux ajouts concurrents
    /// (ou un ajout concurrent d'un flush réseau en cours) s'écrasaient (ROB-11).
    func upsert(_ value: PendingSpeedtestSave) async throws
    /// Retire UNE entrée par `id` de façon atomique (no-op si absente).
    func remove(id: String) async
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
    private let mutations = SpeedtestMutationQueue()

    init(cache: DiskCache, key: String) { self.cache = cache; self.key = key }

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

    // Serialize the full read-modify-write operation across suspension points.
    func upsert(_ value: PendingSpeedtestSave) async throws {
        try await mutations.perform {
            var values = await loadAll().filter { $0.id != value.id }
            values.append(value)
            try await replaceAll(values)
        }
    }

    func remove(id: String) async {
        try? await mutations.perform {
            let values = await loadAll().filter { $0.id != id }
            try await replaceAll(values)
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
    /// Créé au premier accès sur l'exécuteur de l'acteur. Le construire dans
    /// `init` liait le contexte a la main queue lorsque AppServices demarrait,
    /// puis l'utilisait hors de cette queue dans les methodes de l'acteur.
    private lazy var context: ModelContext = {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }()
    private let legacyCache: DiskCache?
    private let legacyKey: String
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest
    private let beforeMigrationSave: (@Sendable () throws -> Void)?

    /// `init?` : si le `ModelContainer` ne peut pas être créé, la fabrique retombe sur JSON.
    init?(storeURL: URL? = nil, legacyCache: DiskCache? = nil, legacyKey: String,
          beforeMigrationSave: (@Sendable () throws -> Void)? = nil) {
        self.beforeMigrationSave = beforeMigrationSave
        self.legacyCache = legacyCache
        self.legacyKey = legacyKey
        let url = storeURL ?? Self.defaultStoreURL()
        guard let container = try? ModelContainer(
            for: SpeedtestPendingEntity.self,
            configurations: ModelConfiguration(url: url)
        ) else { return nil }
        self.container = container
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
        try saveContextOrRollback()
    }

    func upsert(_ value: PendingSpeedtestSave) async throws {
        await importLegacyIfPresent()
        // Après ce point de suspension, tout est synchrone (encode/fetch/delete/
        // insert/save) : la réentrance d'acteur ne peut PAS s'intercaler, donc le
        // remplacement de cette entrée est atomique vis-à-vis d'un autre upsert /
        // remove concurrent (ROB-11).
        let payload = try encoder.encode(value)
        let targetId = value.id
        let existing = (try? context.fetch(FetchDescriptor<SpeedtestPendingEntity>(
            predicate: #Predicate { $0.saveId == targetId }
        ))) ?? []
        for entity in existing { context.delete(entity) }
        context.insert(SpeedtestPendingEntity(
            saveId: value.id,
            createdAtMs: Int(value.createdAt.timeIntervalSince1970 * 1_000),
            payload: payload
        ))
        try saveContextOrRollback()
    }

    func remove(id: String) async {
        await importLegacyIfPresent()
        let matches = (try? context.fetch(FetchDescriptor<SpeedtestPendingEntity>(
            predicate: #Predicate { $0.saveId == id }
        ))) ?? []
        guard !matches.isEmpty else { return }
        for entity in matches { context.delete(entity) }
        try? saveContextOrRollback()
    }

    /// Import unique depuis la file durable JSON (`DiskCache`) au premier `loadAll`, puis
    /// purge de cette file. Idempotent (unicité `saveId`) ; une fois la file legacy vidée,
    /// cette méthode devient un no-op. La logique d'insertion est synchrone (sans point de
    /// suspension) → pas de conflit d'unicité en cas de réentrance d'acteur.
    private func importLegacyIfPresent() async {
        guard let legacyCache else { return }
        let legacy = (try? await legacyCache.read([PendingSpeedtestSave].self, for: legacyKey)) ?? []
        guard !legacy.isEmpty else { return }
        do {
            let existing = Set(try context.fetch(FetchDescriptor<SpeedtestPendingEntity>()).map(\.saveId))
            var inserted = false
            for save in legacy where !existing.contains(save.id) {
                let payload = try encoder.encode(save)
                context.insert(SpeedtestPendingEntity(saveId: save.id,
                    createdAtMs: Int(save.createdAt.timeIntervalSince1970 * 1000), payload: payload))
                inserted = true
            }
            if inserted {
                try beforeMigrationSave?()
                try saveContextOrRollback()
            }
        } catch {
            context.rollback()
            return // The source journal remains the recoverable authority.
        }
        await legacyCache.remove(legacyKey)
    }

    private func saveContextOrRollback() throws {
        do { try context.save() } catch { context.rollback(); throw error }
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


actor SpeedtestSubmissionCoordinator {
    private var active: [String: Task<Void, Error>] = [:]
    func submit(id: String, operation: @escaping @Sendable () async throws -> Void) async throws {
        if let task = active[id] { return try await task.value }
        let task = Task { try await operation() }
        active[id] = task
        defer { active[id] = nil }
        try await task.value
    }
}


actor SpeedtestMutationQueue {
    private var tail: Task<Void, Never>?
    func perform(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task {
            await previous?.value
            try await operation()
        }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
}
