@preconcurrency import CoreTelephony
import Foundation

/// Accusé de `POST /api/experience-tests` : 201 (créé, `post` si publié) ou 200 (rejeu, sans `post`).
struct ExperienceReceipt: Equatable, Sendable {
    let id: String
    let idempotent: Bool
    let postId: String?
    let warnings: [String]
}

/// Refus ou échec d'un envoi, tels que l'app doit les distinguer (contrat §2).
enum ExperienceSubmitFailure: Equatable, Sendable {
    case invalid(path: String?)
    case methodologyUnsupported
    case scoreScaleUnsupported
    case tooLarge
    /// 409 : l'identifiant appartient à un autre compte. Distinct d'un rejeu (200).
    case submissionIdConflict
    case unauthorized
    case rateLimited
    case server
    /// Hors ligne ou délai dépassé : l'envoi a pu partir, le rejeu avec le même identifiant est sûr.
    case network
    case other(status: Int?)

    /// Le rejeu ne changerait rien : le test sort de la file.
    var isDefinitive: Bool {
        switch self {
        case .invalid, .methodologyUnsupported, .scoreScaleUnsupported, .tooLarge, .submissionIdConflict: true
        default: false
        }
    }

    var diagnosticCode: String {
        switch self {
        case .invalid(let path): "invalid:\(path ?? "-")"
        case .methodologyUnsupported: "methodology_unsupported"
        case .scoreScaleUnsupported: "score_scale_unsupported"
        case .tooLarge: "too_large"
        case .submissionIdConflict: "submission_id_conflict"
        case .unauthorized: "unauthorized"
        case .rateLimited: "rate_limited"
        case .server: "server"
        case .network: "network"
        case .other(let status): "http_\(status.map(String.init) ?? "-")"
        }
    }
}

/// Une ligne de l'historique : un résumé, jamais le détail.
struct ExperienceHistoryItem: Equatable, Sendable, Identifiable {
    let id: String
    let measuredAt: Date
    let platform: String
    let connectionType: String
    var technology: String?
    var operatorKey: String?
    var marketCode: String?
    var city: String?
    let highlights: ExperienceHighlights
    let states: [ExperienceTestKind: ExperienceTestState]
    var postId: String?
    var postVisibility: String?
    /// Présent pour une ligne tenue sur le téléphone.
    var clientSubmissionId: String?
    /// État d'envoi de la ligne locale ; nil pour une ligne du serveur.
    var delivery: ExperienceDelivery?
}

struct ExperienceHistoryPage: Equatable, Sendable {
    let items: [ExperienceHistoryItem]
    let hasMore: Bool
}

/// Détail servi : le résultat (sans ville pour un autre lecteur), ses `highlights` et son post.
struct ExperienceDetail: Equatable, Sendable {
    let id: String
    let result: ExperienceStoredResult?
    let highlights: ExperienceHighlights
    let postId: String?
    let postVisibility: String?
}

/// Filtres de l'historique, ceux de `GET /api/user/speedtests`.
struct ExperienceHistoryQuery: Equatable, Sendable {
    var period = "30d"
    var limit = 25
    var page = 1
    var connectionType: String?
    var marketCode: String?
    var operatorKey: String?

    var queryItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "period", value: period),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
            URLQueryItem(name: "page", value: String(max(page, 1)))
        ]
        if let connectionType, !connectionType.isEmpty { items.append(.init(name: "connectionType", value: connectionType)) }
        // Le serveur exige `marketCode` pour lire `operatorKey`.
        if let marketCode, !marketCode.isEmpty {
            items.append(.init(name: "marketCode", value: marketCode))
            if let operatorKey, !operatorKey.isEmpty { items.append(.init(name: "operatorKey", value: operatorKey)) }
        }
        return items
    }
}

/// Lecture des réponses du serveur et classement des échecs : pur, testé sans réseau.
enum ExperienceAPIMapping {
    static let endpoint = "/api/experience-tests"
    static let historyEndpoint = "/api/user/experience-tests"

    static func parseReceipt(_ data: Data) -> ExperienceReceipt? {
        guard let object = json(data) else { return nil }
        if let success = object["success"] as? Bool, !success { return nil }
        guard let id = text(object["id"]) else { return nil }
        return ExperienceReceipt(
            id: id, idempotent: object["idempotent"] as? Bool ?? false,
            postId: (object["post"] as? [String: Any]).flatMap { text($0["id"]) },
            warnings: (object["warnings"] as? [Any] ?? []).compactMap { $0 as? String }
        )
    }

    /// Le CODE fait foi pour un 400 ; le statut seul ne suffit pas.
    static func failure(_ error: Error) -> ExperienceSubmitFailure {
        guard let api = error as? APIError else { return (error as? URLError) != nil ? .network : .other(status: nil) }
        switch api {
        case .transport: return .network
        case .missingAuthToken: return .unauthorized
        case .http(let status, let code, _, _, _):
            switch (status, code) {
            case (401, _): return .unauthorized
            case (413, _), (_, "EXPERIENCE_TEST_TOO_LARGE"): return .tooLarge
            case (409, "EXPERIENCE_TEST_CLIENT_SUBMISSION_ID_CONFLICT"): return .submissionIdConflict
            case (400, "EXPERIENCE_TEST_METHODOLOGY_UNSUPPORTED"): return .methodologyUnsupported
            case (400, "EXPERIENCE_TEST_SCORE_SCALE_UNSUPPORTED"): return .scoreScaleUnsupported
            case (400, _): return .invalid(path: nil)
            case (429, _): return .rateLimited
            case (500...599, _): return .server
            default: return .other(status: status)
            }
        default: return .other(status: nil)
        }
    }

    static func parseHistoryPage(_ data: Data) -> ExperienceHistoryPage? {
        guard let object = json(data), let array = object["experienceTests"] as? [Any] else { return nil }
        let meta = object["meta"] as? [String: Any]
        // Une ligne illisible est ignorée, pas l'historique entier.
        return ExperienceHistoryPage(
            items: array.compactMap { ($0 as? [String: Any]).flatMap(historyItem) },
            hasMore: meta?["hasMore"] as? Bool ?? false
        )
    }

    static func historyItem(_ object: [String: Any]) -> ExperienceHistoryItem? {
        guard let id = text(object["id"]), let measuredAt = ExperienceResultReader.date(object["measuredAt"]) else { return nil }
        var states: [ExperienceTestKind: ExperienceTestState] = [:]
        for (key, value) in object["states"] as? [String: Any] ?? [:] {
            if let kind = ExperienceTestKind(rawValue: key), let state = text(value).flatMap(ExperienceTestState.init(rawValue:)) {
                states[kind] = state
            }
        }
        let post = object["post"] as? [String: Any]
        return ExperienceHistoryItem(
            id: id, measuredAt: measuredAt, platform: text(object["platform"]) ?? "android",
            connectionType: text(object["connectionType"]) ?? "unknown", technology: text(object["technology"]),
            operatorKey: text(object["operatorKey"]), marketCode: text(object["marketCode"]), city: text(object["city"]),
            highlights: highlights(object["highlights"]), states: states,
            postId: post.flatMap { text($0["id"]) }, postVisibility: post.flatMap { text($0["visibility"]) }
        )
    }

    /// `{ experienceTest: { …résultat, id, highlights, post } }`.
    static func parseDetail(_ data: Data) -> ExperienceDetail? {
        guard let item = json(data)?["experienceTest"] as? [String: Any], let id = text(item["id"]) else { return nil }
        let post = item["post"] as? [String: Any]
        return ExperienceDetail(
            id: id, result: ExperienceResultReader.read(item), highlights: highlights(item["highlights"]),
            postId: post.flatMap { text($0["id"]) }, postVisibility: post.flatMap { text($0["visibility"]) }
        )
    }

    private static func highlights(_ value: Any?) -> ExperienceHighlights {
        guard let object = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object),
              let served = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return ExperienceHighlights() }
        return ExperienceHighlights(served: served)
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}

/// Fusion de l'historique : lignes locales et lignes du serveur.
enum ExperienceHistoryMerge {
    static func localItem(_ record: ExperienceJournalRecord) -> ExperienceHistoryItem? {
        guard let result = record.result,
              let object = try? JSONSerialization.jsonObject(with: record.body) as? [String: Any],
              let testsData = try? JSONSerialization.data(withJSONObject: object["tests"] as? [String: Any] ?? [:]),
              let tests = try? JSONDecoder().decode([String: JSONValue].self, from: testsData) else { return nil }
        var states: [ExperienceTestKind: ExperienceTestState] = [:]
        for kind in ExperienceTestKind.allCases { states[kind] = result.tests.state(of: kind) }
        return ExperienceHistoryItem(
            id: record.serverId ?? record.clientSubmissionId, measuredAt: result.measuredAt, platform: result.platform,
            connectionType: result.network.connectionType, technology: result.network.technology,
            operatorKey: result.network.operatorKey, marketCode: result.network.marketCode, city: result.city,
            highlights: ExperienceHighlights(tests: tests), states: states.compactMapValues { $0 },
            postId: record.postId, clientSubmissionId: record.clientSubmissionId, delivery: record.delivery
        )
    }

    /// Les lignes du serveur font foi. Une ligne locale déjà confirmée (même identifiant serveur) est
    /// écartée ; une ligne en attente reçue par le serveur sans accusé (même `measuredAt` à la
    /// milliseconde) aussi. Du plus récent au plus ancien, sans doublon.
    static func merge(local: [ExperienceHistoryItem], remote: [ExperienceHistoryItem]) -> [ExperienceHistoryItem] {
        let remoteIds = Set(remote.map(\.id))
        let remoteInstants = Set(remote.map { Int64(($0.measuredAt.timeIntervalSince1970 * 1_000).rounded()) })
        let kept = local.filter { item in
            guard !remoteIds.contains(item.id) else { return false }
            let ms = Int64((item.measuredAt.timeIntervalSince1970 * 1_000).rounded())
            return !(item.delivery == .pending && remoteInstants.contains(ms))
        }
        return (remote + kept).sorted { $0.measuredAt > $1.measuredAt }
    }
}

/// Enregistrement, envoi, historique et suppression des tests d'expérience. L'envoi passe
/// par le journal : l'identifiant d'envoi est écrit sur le téléphone AVANT le POST.
@MainActor
final class ExperienceTestsService {
    enum SaveOutcome: Equatable, Sendable {
        /// Gardé et mis en file : le serveur confirmera.
        case queued(clientSubmissionId: String)
        /// Gardé sur le téléphone seulement (sans compte).
        case localOnly(clientSubmissionId: String)
        /// Corps de plus de 64 Kio ou illisible : gardé, jamais envoyé.
        case refused(clientSubmissionId: String)
        /// Aucun test mesuré : rien n'est gardé (règle du serveur, §4).
        case nothingMeasured
    }

    enum DeleteOutcome: Equatable, Sendable {
        case deleted
        /// Supprimer sur le serveur exige le réseau : la ligne est conservée.
        case failed(ExperienceSubmitFailure)
    }

    typealias Send = @Sendable (APIEndpoint) async throws -> Data

    private let store: ExperienceJournalStore
    private let send: Send
    private let uploadEnabled: Bool
    private let ownerScopeId: @Sendable () -> String
    private var retrying: Task<Void, Never>?

    init(
        store: ExperienceJournalStore = ExperienceJournalStore(),
        send: @escaping Send,
        uploadEnabled: Bool = SQFeatures.experienceTestsUploadEnabled,
        ownerScopeId: @escaping @Sendable () -> String = { LocalAccountScope.currentOwnerScopeId }
    ) {
        self.store = store
        self.send = send
        self.uploadEnabled = uploadEnabled
        self.ownerScopeId = ownerScopeId
    }

    convenience init(api: APIClient) {
        self.init(send: { try await api.requestData($0) })
    }

    // MARK: Enregistrement et envoi

    func save(_ submission: ExperienceSubmission, run: ExperienceRun) async -> SaveOutcome {
        guard ExperienceTestKind.allCases.contains(where: { submission.tests.state(of: $0) == .measured }) else {
            return .nothingMeasured
        }
        let id = submission.clientSubmissionId.uuidString.lowercased()
        let owner = ownerScopeId()
        let body = try? submission.body()
        let signedIn = owner.hasPrefix("user:")
        let delivery: ExperienceDelivery = body.map { $0.count <= ExperienceMethod.maxBodyBytes } == true
            ? (signedIn ? .pending : .localOnly) : .rejected
        var record = ExperienceJournalRecord(
            clientSubmissionId: id, ownerScopeId: owner,
            measuredAtMs: Int64((submission.measuredAt.timeIntervalSince1970 * 1_000).rounded(.down)),
            body: body ?? Data(), delivery: delivery, lastError: delivery == .rejected ? "too_large" : nil
        )
        record.usage = Dictionary(uniqueKeysWithValues: run.usage.map {
            ($0.key.rawValue, ExperienceJournalRecord.Usage(bytes: $0.value.bytes, durationMs: $0.value.durationMs))
        })
        record.failureCauses = Dictionary(uniqueKeysWithValues: run.failures.map { ($0.key.rawValue, "\($0.value)") })
        do {
            try await store.insertIfAbsent(record)
        } catch {
            SQDiagnostics.record(error, area: .experienceTests, context: ["action": "save"])
        }
        switch delivery {
        case .rejected: return .refused(clientSubmissionId: id)
        case .localOnly: return .localOnly(clientSubmissionId: id)
        default:
            await retryPending()
            return .queued(clientSubmissionId: id)
        }
    }

    /// Envoie les tests en attente du compte courant, du plus ancien au plus récent ; un seul passage à la fois.
    /// Fermé tant que `SQFeatures.experienceTestsUploadEnabled` l'est : les tests restent en attente.
    func retryPending() async {
        guard uploadEnabled else { return }
        if let retrying { return await retrying.value }
        let task = Task { [weak self] in _ = await self?.flush() }
        retrying = task
        await task.value
        retrying = nil
    }

    private func flush() async {
        let owner = ownerScopeId()
        guard owner.hasPrefix("user:"), let records = try? await store.records(ownerScopeId: owner) else { return }
        for record in records.reversed() where record.delivery == .pending {
            guard ownerScopeId() == owner else { return }
            var endpoint = APIEndpoint(path: ExperienceAPIMapping.endpoint, method: .post,
                                       headers: ["Content-Type": "application/json"], body: record.body)
            endpoint.idempotencyKey = record.clientSubmissionId
            do {
                let data = try await send(endpoint)
                guard let receipt = ExperienceAPIMapping.parseReceipt(data) else { continue }
                try? await store.update(ownerScopeId: owner, clientSubmissionId: record.clientSubmissionId) {
                    $0.delivery = .synced
                    $0.serverId = receipt.id
                    $0.postId = receipt.postId ?? $0.postId
                    $0.lastError = nil
                }
            } catch {
                let failure = ExperienceAPIMapping.failure(error)
                try? await store.update(ownerScopeId: owner, clientSubmissionId: record.clientSubmissionId) {
                    $0.lastError = failure.diagnosticCode
                    if failure.isDefinitive { $0.delivery = .rejected }
                }
                // Hors ligne, sans session ou limité : inutile d'essayer les suivants maintenant.
                if [.network, .unauthorized, .rateLimited, .server].contains(failure) || error.isCancellation { return }
            }
        }
    }

    // MARK: Lecture

    func localRecords() async -> [ExperienceJournalRecord] {
        (try? await store.records(ownerScopeId: ownerScopeId())) ?? []
    }

    func localItems() async -> [ExperienceHistoryItem] {
        await localRecords().compactMap(ExperienceHistoryMerge.localItem)
    }

    func history(_ query: ExperienceHistoryQuery = ExperienceHistoryQuery()) async throws -> ExperienceHistoryPage {
        let data = try await send(APIEndpoint(path: ExperienceAPIMapping.historyEndpoint, query: query.queryItems))
        guard let page = ExperienceAPIMapping.parseHistoryPage(data) else { throw APIError.decoding("experience-history") }
        return page
    }

    func detail(id: String) async throws -> ExperienceDetail {
        let data = try await send(APIEndpoint(path: "\(ExperienceAPIMapping.endpoint)/\(Self.pathSegment(id))"))
        guard let detail = ExperienceAPIMapping.parseDetail(data) else { throw APIError.decoding("experience-detail") }
        return detail
    }

    // MARK: Suppression

    /// Jamais confirmé : suppression locale. Sinon le serveur d'abord (le test ET son post), la ligne locale
    /// ensuite ; un 404 vaut supprimé. Hors ligne, rien n'est supprimé.
    func delete(serverId: String?, clientSubmissionId: String?) async -> DeleteOutcome {
        let owner = ownerScopeId()
        var local: ExperienceJournalRecord?
        if let clientSubmissionId {
            local = try? await store.record(ownerScopeId: owner, clientSubmissionId: clientSubmissionId)
        } else if let serverId {
            local = (try? await store.records(ownerScopeId: owner))?.first { $0.serverId == serverId }
        }
        guard let remoteId = local.map({ $0.serverId }) ?? serverId else {
            if let local { try? await store.remove(ownerScopeId: owner, clientSubmissionId: local.clientSubmissionId) }
            return .deleted
        }
        do {
            _ = try await send(APIEndpoint(path: "\(ExperienceAPIMapping.endpoint)/\(Self.pathSegment(remoteId))", method: .delete))
        } catch {
            guard case .http(404, _, _, _, _)? = error as? APIError else { return .failed(ExperienceAPIMapping.failure(error)) }
        }
        if let local { try? await store.remove(ownerScopeId: owner, clientSubmissionId: local.clientSubmissionId) }
        return .deleted
    }

    private static func pathSegment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? id
    }
}

/// Latences du dernier speedtest et chemin réseau d'où il est parti, gardés en mémoire seulement
/// (10 minutes utiles, méthode §4) : « Jeu et appels » les reprend sur le même réseau au lieu
/// d'une courte charge. Rien n'est écrit sur le disque, SSID compris.
enum ExperienceRecentLatency {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var snapshot: ExperienceLatencyReuse.Snapshot?

    static func record(_ value: ExperienceLatencyReuse.Snapshot) { lock.withLock { snapshot = value } }

    static var current: ExperienceLatencyReuse.Snapshot? { lock.withLock { snapshot } }

    static func clear() { lock.withLock { snapshot = nil } }

    /// Chemin d'une mesure : Wi-Fi par son SSID, mobile par le service de données de la SIM et
    /// l'opérateur qui transporte (IP/ASN). Autre connexion : pas de chemin, donc pas de reprise.
    static func path(connection: NetworkConnectionKind, ssid: String?, carrierOperatorKey: String?) -> ExperienceNetworkPath? {
        let vpn = VPNDetector.isActive()
        switch connection {
        case .wifi:
            return ExperienceNetworkPath(transport: .wifi, ssid: ssid, vpn: vpn)
        case .cellular:
            return ExperienceNetworkPath(transport: .cellular, dataServiceId: CTTelephonyNetworkInfo().dataServiceIdentifier,
                                         carrierOperatorKey: carrierOperatorKey, vpn: vpn)
        case .wired, .other:
            return nil
        }
    }
}
