import Foundation

/// Récap d'un trajet Drive Test à envoyer (MES-14, contrat
/// `coverage-drive-summary-v1`, figé le 05/11) : le trajet apparaît alors dans
/// « Mes trajets » comme ceux d'Android, sans tracé. Aucune position ici.
struct DriveTripSummaryDraft: Codable, Equatable, Sendable {
    /// « ios-drive-<uuid> », tiré au hasard : il devient l'id de la session serveur.
    let clientTripId: String
    let ownerScopeId: String
    let startedAt: Date
    let endedAt: Date
    let distanceMeters: Double
    let testCount: Int
    let bytesUsed: Int
    let stoppedByDataCap: Bool
    /// VPN vu à un moment du trajet : le serveur garde alors le trajet privé.
    let vpnActive: Bool
    let downloadAvgMbps: Double?
    let downloadMaxMbps: Double?
    /// Réseau du trajet, seulement quand tous les tests l'ont vu identique : le
    /// contrat demande de l'omettre plutôt que d'en choisir un.
    let marketCode: String?
    let operatorKey: String?
    /// Ids locaux des speedtests du trajet ; traduits en ids serveur à l'envoi.
    let speedtestClientIds: [UUID]
    let deviceModel: String?
    let osVersion: String?
    let appVersion: String?
    /// Ids serveur déjà liés au dernier envoi réussi, pour ne renvoyer que si
    /// d'autres tests ont été enregistrés depuis.
    var sentServerIdCount: Int? = nil

    static func newTripId() -> String { "ios-drive-\(UUID().uuidString.lowercased())" }

    /// Corps de `POST /api/coverage/session/drive-summary`.
    func body(serverSpeedtestIds: [String]) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        var body: [String: Any] = [
            "clientTripId": clientTripId,
            "startedAt": formatter.string(from: startedAt),
            "endedAt": formatter.string(from: endedAt),
            "distanceMeters": Int(max(0, distanceMeters).rounded()),
            "testCount": testCount,
            "bytesUsed": max(0, bytesUsed),
            "stoppedByDataCap": stoppedByDataCap,
            "vpnActive": vpnActive,
            // Sans test, pas de débit : null, comme le contrat l'attend.
            "downloadAvgMbps": testCount > 0 ? (downloadAvgMbps as Any? ?? NSNull()) : NSNull(),
            "downloadMaxMbps": testCount > 0 ? (downloadMaxMbps as Any? ?? NSNull()) : NSNull(),
            "speedtestIds": serverSpeedtestIds,
        ]
        if let marketCode, let operatorKey {
            body["operator"] = ["marketCode": marketCode, "operatorKey": operatorKey]
        }
        if let deviceModel { body["deviceModel"] = deviceModel }
        if let osVersion { body["osVersion"] = osVersion }
        if let appVersion { body["appVersion"] = appVersion }
        return body
    }
}

struct DriveTripSummaryResponse: Decodable, Equatable, Sendable {
    let sessionId: String?
    let created: Bool?
    let linkedSpeedtests: Int?
    let ignoredSpeedtests: Int?
}

/// File des récaps de trajet, par compte, rejouée jusqu'à l'envoi.
///
/// L'envoi est idempotent côté serveur (même `clientTripId` → 200 et récap
/// réécrit) : on peut le rejouer après une coupure, et le renvoyer quand des
/// speedtests restés en file locale ont fini par recevoir leur id serveur.
actor DriveTripSummaryService {
    /// Au-delà, un trajet non envoyé (ou dont des tests n'ont jamais reçu d'id)
    /// n'est plus rejoué.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let maxQueued = 20

    private let api: APIClientProtocol
    private let serverId: @Sendable (UUID) async -> String?
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var flushing = false

    init(
        api: APIClientProtocol,
        serverId: @escaping @Sendable (UUID) async -> String?,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.serverId = serverId
        self.defaults = defaults
        self.now = now
    }

    private var storageKey: String { "drive_trip_summary_outbox.\(LocalAccountScope.storageNamespace)" }

    func queued() -> [DriveTripSummaryDraft] {
        defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([DriveTripSummaryDraft].self, from: $0) } ?? []
    }

    private func store(_ drafts: [DriveTripSummaryDraft]) {
        if drafts.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(drafts) {
            defaults.set(data, forKey: storageKey)
        }
    }

    func enqueue(_ draft: DriveTripSummaryDraft) {
        var drafts = queued().filter { $0.clientTripId != draft.clientTripId }
        drafts.append(draft)
        store(Array(drafts.suffix(Self.maxQueued)))
    }

    /// Envoie ce qui attend. Une erreur passagère (réseau, 401, 426, 429, 5xx)
    /// garde le récap ; un refus définitif (400, 409) l'abandonne, il ne passerait
    /// jamais.
    func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        let owner = LocalAccountScope.currentOwnerScopeId
        guard owner != "guest" else { return }
        let current = now()
        for draft in queued() {
            guard draft.ownerScopeId == owner else { continue }
            guard current.timeIntervalSince(draft.endedAt) <= Self.maxAge else {
                remove(draft.clientTripId)
                continue
            }
            var serverIds: [String] = []
            for clientId in draft.speedtestClientIds {
                if let id = await serverId(clientId) { serverIds.append(id) }
            }
            if let sent = draft.sentServerIdCount, serverIds.count <= sent { continue }
            do {
                let body = try JSONSerialization.data(withJSONObject: draft.body(serverSpeedtestIds: serverIds))
                _ = try await api.request(
                    APIEndpoint(
                        path: "/api/coverage/session/drive-summary",
                        method: .post,
                        headers: ["Content-Type": "application/json"],
                        body: body,
                        idempotencyKey: "\(draft.clientTripId)-\(serverIds.count)"
                    ),
                    as: DriveTripSummaryResponse.self
                )
                if serverIds.count >= draft.speedtestClientIds.count {
                    remove(draft.clientTripId)
                } else {
                    // Des tests attendent encore leur id : on renverra quand ils l'auront.
                    update(draft.clientTripId) { $0.sentServerIdCount = serverIds.count }
                }
            } catch let APIError.http(status, _, _, _, _) where status == 400 || status == 409 {
                remove(draft.clientTripId)
            } catch {
                // Passager : on réessaiera au prochain passage.
                continue
            }
        }
    }

    private func remove(_ clientTripId: String) {
        store(queued().filter { $0.clientTripId != clientTripId })
    }

    private func update(_ clientTripId: String, _ change: (inout DriveTripSummaryDraft) -> Void) {
        store(queued().map { draft in
            guard draft.clientTripId == clientTripId else { return draft }
            var copy = draft
            change(&copy)
            return copy
        })
    }
}
