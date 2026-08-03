import Foundation

/// Sentinelle — état des connexions surveillées.
///
/// La sonde tourne sur le serveur : l'application ne mesure rien, elle lit.
/// C'est ce qui permet à cet écran de tenir sans `BGTaskScheduler` ni tâche de
/// fond — le projet n'en a aucun, et il n'en a pas besoin ici.
///
/// Les routes enveloppent leur charge utile (`{"targets": [...]}`), d'où les
/// enveloppes de décodage ci-dessous plutôt qu'un tableau nu.

struct SentinelleTarget: Codable, Identifiable, Sendable {
    let id: String
    let label: String
    let hostname: String?
    let ipv4: String?
    let ipv6: String?
    let status: String
    let statusSince: String?
    let lastProbeAt: String?
    let protocolName: String?
    let isActive: Bool?
    let suspendedReason: String?
    let operatorKey: String?

    enum CodingKeys: String, CodingKey {
        case id, label, hostname, ipv4, ipv6, status, statusSince, lastProbeAt
        // `protocol` est un mot réservé en Swift : on le renomme sans toucher au contrat serveur.
        case protocolName = "protocol"
        case isActive, suspendedReason, operatorKey
    }

    /// Adresse affichable : le nom d'hôte prime, il est plus parlant qu'une IP.
    var displayAddress: String { hostname ?? ipv4 ?? ipv6 ?? "—" }
}

struct SentinelleIncident: Codable, Identifiable, Sendable {
    let id: String
    let kind: String
    let startedAt: String
    let endedAt: String?
    let durationSec: Int?
    let cause: String?
    let correlatedUsers: Int?
}

struct SentinelleQuota: Codable, Sendable {
    let used: Int
    let max: Int
}

struct SentinelleTargetsResponse: Codable, Sendable {
    let targets: [SentinelleTarget]
    let quota: SentinelleQuota?
}

struct SentinelleDetailResponse: Codable, Sendable {
    let target: SentinelleTarget
    let incidents: [SentinelleIncident]
}

/// Distingué du reste : l'écran doit proposer l'abonnement, pas afficher une erreur.
struct SentinelleAccessDenied: Error {}

protocol SentinelleServicing: Sendable {
    func targets() async throws -> SentinelleTargetsResponse
    func detail(targetId: String) async throws -> SentinelleDetailResponse
}

final class SentinelleService: SentinelleServicing, @unchecked Sendable {
    private let api: APIClientProtocol

    init(api: APIClientProtocol) {
        self.api = api
    }

    func targets() async throws -> SentinelleTargetsResponse {
        do {
            return try await api.request(
                APIEndpoint(path: "/api/sentinelle/targets"),
                as: SentinelleTargetsResponse.self
            )
        } catch {
            throw Self.mapping(error)
        }
    }

    func detail(targetId: String) async throws -> SentinelleDetailResponse {
        do {
            return try await api.request(
                APIEndpoint(path: "/api/sentinelle/targets/\(targetId)"),
                as: SentinelleDetailResponse.self
            )
        } catch {
            throw Self.mapping(error)
        }
    }

    /// Un 403 signifie « pas d'accès Premium », pas « quelque chose a échoué ».
    private static func mapping(_ error: Error) -> Error {
        if case APIError.http(let status, _, _, _, _) = error, status == 403 {
            return SentinelleAccessDenied()
        }
        return error
    }
}
