import Foundation
import os

/// Catalogue des POPs iPerf3 servi par `GET /api/speedtest/servers`.
///
/// Avant lui, la liste vivait en dur dans l'app ET dans l'app Android, dupliquée et
/// déjà divergente. Un POP qui mourait exigeait une release sur les deux stores —
/// plusieurs jours pendant lesquels les utilisateurs mesuraient vers un serveur
/// injoignable, ou pire, vers un port muet qui coûte un timeout à chaque test.
///
/// Chaîne de résolution, calquée sur `MarketRegistryService` :
/// mémoire → réseau (+ cache disque) → cache disque → catalogue embarqué.
/// Le catalogue embarqué (`iperfPublicServers`) n'est plus la vérité, seulement la
/// valeur de départ : il garantit qu'un premier lancement hors ligne peut mesurer.
///
/// Rien ici n'est bloquant : une panne de l'API ne doit jamais empêcher un test.

// MARK: - Payload

struct IPerfCatalogPayload: Codable, Sendable {
    let schemaVersion: Int
    let revision: String
    let ttlSeconds: Int?
    let providers: [ProviderDTO]
    let servers: [ServerDTO]

    struct ProviderDTO: Codable, Sendable {
        let key: String
        let label: String
        let order: Int
    }

    struct ServerDTO: Codable, Sendable {
        let id: String
        let host: String
        let name: String
        let code: String
        let provider: String
        let city: String
        let countryCode: String
        let lat: Double
        let lon: Double
        let portMin: Int
        let portMax: Int
        let portPreferred: Int
        let selectable: Bool
        let autoEligible: Bool
    }
}

// MARK: - Validation

/// Le payload décrit des hôtes vers lesquels l'app ouvrira des connexions TCP. Il
/// arrive en HTTPS depuis notre propre API, mais on le valide quand même : une
/// plage de ports aberrante transformerait le port-walk en balayage de ports, ce
/// qui ressemble à du scan vu du réseau de l'opérateur.
enum IPerfCatalogValidator {
    /// Version de schéma que ce binaire sait lire. Une version SUPÉRIEURE est
    /// refusée en bloc plutôt que décodée au mieux : mieux vaut l'embarqué qu'une
    /// interprétation approximative d'un format qu'on ne connaît pas.
    static let supportedSchemaVersion = 1
    static let maxServers = 500
    /// Au-delà, la plage n'est plus un fallback anti-BUSY mais un balayage.
    static let maxPortSpan = 128

    static func validate(_ payload: IPerfCatalogPayload) -> [IPerfPublicServer]? {
        guard payload.schemaVersion == supportedSchemaVersion else { return nil }
        guard !payload.servers.isEmpty, payload.servers.count <= maxServers else { return nil }

        var seenIds = Set<String>()
        var result: [IPerfPublicServer] = []
        result.reserveCapacity(payload.servers.count)

        for dto in payload.servers {
            guard let server = convert(dto) else { return nil }
            // Un id dupliqué rendrait la préférence utilisateur ambiguë.
            guard seenIds.insert(server.id).inserted else { return nil }
            result.append(server)
        }
        return result
    }

    private static func convert(_ dto: IPerfCatalogPayload.ServerDTO) -> IPerfPublicServer? {
        let host = dto.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dto.id.isEmpty, !host.isEmpty, host.count <= 253, !dto.name.isEmpty else { return nil }
        // Pas d'URL déguisée en hôte, pas de séparateur de port : `NWEndpoint.Host`
        // accepterait des formes qu'on ne veut pas ouvrir.
        guard !host.contains("/"), !host.contains(" "), !host.contains(":") else { return nil }
        guard dto.lat.isFinite, dto.lat >= -90, dto.lat <= 90,
              dto.lon.isFinite, dto.lon >= -180, dto.lon <= 180 else { return nil }
        guard dto.portMin >= 1, dto.portMax <= 65_535, dto.portMin <= dto.portMax else { return nil }
        guard dto.portMax - dto.portMin <= maxPortSpan else { return nil }
        guard dto.portPreferred >= dto.portMin, dto.portPreferred <= dto.portMax else { return nil }

        return IPerfPublicServer(
            id: dto.id,
            hostname: host,
            name: dto.name,
            latitude: dto.lat,
            longitude: dto.lon,
            code: String(dto.code.prefix(20)),
            countryCode: dto.countryCode,
            // Un fournisseur inconnu de ce binaire ne fait pas disparaître le POP :
            // c'est tout l'intérêt de pouvoir en introduire un côté serveur.
            provider: IPerfServerProvider(rawValue: dto.provider) ?? .community,
            portMin: UInt16(dto.portMin),
            portMax: UInt16(dto.portMax),
            portPreferred: UInt16(dto.portPreferred)
        )
    }
}

// MARK: - Service

protocol IPerfCatalogServicing: Sendable {
    /// Best-effort, jamais throwing : rafraîchit le catalogue actif si le TTL est
    /// dépassé. À appeler à l'ouverture de l'écran Speedtest — JAMAIS pendant un
    /// test, sous peine de changer de serveur au milieu d'une mesure.
    func refreshIfNeeded() async
}

final class IPerfCatalogService: IPerfCatalogServicing, @unchecked Sendable {
    private let api: APIClient
    private let cache: DiskCache
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "IPerfCatalog")

    private struct State {
        var lastAppliedAt: Date?
        var lastAttemptAt: Date?
        var inFlight: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private static let diskKey = "iperf-catalog-v1"
    /// Repli si l'API ne sert pas de `ttlSeconds`.
    private static let defaultTTL: TimeInterval = 6 * 60 * 60
    /// Le catalogue disque reste utilisable bien après le TTL : périmé vaut mieux
    /// que rien, et l'API le rafraîchira à la prochaine occasion.
    private static let diskMaxAge: TimeInterval = 30 * 24 * 60 * 60
    /// Après un échec, on ne martèle pas : l'app doit rester utilisable hors ligne.
    private static let retryInterval: TimeInterval = 15 * 60

    init(api: APIClient, cache: DiskCache = DiskCache(folderName: "SignalQuestIPerfCatalog")) {
        self.api = api
        self.cache = cache
    }

    func refreshIfNeeded() async {
        let now = Date()
        let shouldSkip = state.withLock { st -> Bool in
            if let applied = st.lastAppliedAt, now.timeIntervalSince(applied) < Self.defaultTTL {
                return true
            }
            if let attempt = st.lastAttemptAt, now.timeIntervalSince(attempt) < Self.retryInterval {
                return true
            }
            return false
        }
        if shouldSkip { return }

        let task: Task<Void, Never> = state.withLock { st in
            if let inFlight = st.inFlight { return inFlight }
            st.lastAttemptAt = now
            let task = Task { [weak self] in
                guard let self else { return }
                await self.resolveAndApply()
            }
            st.inFlight = task
            return task
        }
        await task.value
        state.withLock { $0.inFlight = nil }
    }

    /// Charge le catalogue disque au démarrage, sans réseau : l'app dispose ainsi
    /// du dernier catalogue connu avant même la première requête.
    func primeFromDisk() async {
        guard let payload = try? await cache.read(
            IPerfCatalogPayload.self, for: Self.diskKey, maxAge: Self.diskMaxAge
        ), let servers = IPerfCatalogValidator.validate(payload) else { return }
        setActiveIPerfServers(servers)
        logger.debug("Catalogue iPerf3 restauré du disque (\(servers.count, privacy: .public) POPs)")
    }

    private func resolveAndApply() async {
        do {
            let payload = try await api.request(
                APIEndpoint(path: "/api/speedtest/servers", authenticated: false),
                as: IPerfCatalogPayload.self
            )
            guard let servers = IPerfCatalogValidator.validate(payload) else {
                // Rejet EN BLOC, jamais partiel : un catalogue à moitié appliqué est
                // un état que personne ne saura déboguer.
                logger.error("Catalogue iPerf3 refusé par la validation (schema \(payload.schemaVersion, privacy: .public))")
                return
            }
            try? await cache.write(payload, for: Self.diskKey)
            setActiveIPerfServers(servers)
            state.withLock { $0.lastAppliedAt = Date() }
            logger.debug("Catalogue iPerf3 à jour : \(servers.count, privacy: .public) POPs, révision \(payload.revision, privacy: .public)")
        } catch {
            // Hors ligne, API en panne, réponse illisible : on garde ce qu'on a.
            logger.debug("Catalogue iPerf3 réseau indisponible: \(error.localizedDescription, privacy: .public)")
        }
    }
}
