import Foundation

/// Sentinelle — lecture et configuration des connexions surveillées.
///
/// La sonde tourne sur le serveur : l'application ne mesure rien, elle lit —
/// et écrit uniquement la configuration (quelle adresse surveiller). C'est ce
/// qui permet à cet écran de tenir sans `BGTaskScheduler` ni tâche de fond.
///
/// Les routes enveloppent leur charge utile (`{"targets": [...]}`), d'où les
/// enveloppes de décodage ci-dessous plutôt qu'un tableau nu.

struct SentinelleTargetsResponse: Decodable, Sendable {
    let targets: [SentinelleTarget]
    let quota: SentinelleQuota?
}

struct SentinelleDetailResponse: Decodable, Sendable {
    let target: SentinelleTarget
    let incidents: [SentinelleIncident]
}

struct SentinelleSeriesResponse: Decodable, Sendable {
    private let familyRaw: String?
    let granularity: String?
    let points: [SentinelleSeriesPoint]

    enum CodingKeys: String, CodingKey {
        case familyRaw = "family"
        case granularity, points
    }

    /// Famille réellement appliquée par le serveur (nulle = les deux piles
    /// mélangées). La comparer à celle demandée est le seul moyen honnête de
    /// savoir si le graphe montre bien CETTE adresse.
    var family: SentinelleFamily? { familyRaw.flatMap(SentinelleFamily.init(rawValue:)) }
}

/// Adresse publique vue par le serveur.
struct SentinelleCurrentIp: Decodable, Sendable {
    let ip: String?
    private let familyRaw: String?
    /// Faux derrière un CGNAT (box 4G, certains opérateurs) : l'adresse vue par
    /// le serveur n'est alors pas joignable de l'extérieur, et la proposer
    /// créerait une cible morte-née.
    let usable: Bool
    let message: String?

    enum CodingKeys: String, CodingKey {
        case ip
        case familyRaw = "family"
        case usable, message
    }

    var family: SentinelleFamily? { familyRaw.flatMap(SentinelleFamily.init(rawValue:)) }
}

/// Distingué du reste : l'écran doit proposer l'abonnement, pas afficher une erreur.
struct SentinelleAccessDenied: Error {}

protocol SentinelleServicing: Sendable {
    func targets() async throws -> SentinelleTargetsResponse
    func detail(targetId: String) async throws -> SentinelleDetailResponse
    func series(targetId: String, window: SentinelleWindow, family: SentinelleFamily?) async throws -> SentinelleSeriesResponse
    func diagnostic(targetId: String, family: SentinelleFamily?) async throws -> SentinelleDiagnostic
    func trends(targetId: String, family: SentinelleFamily?) async throws -> SentinelleTrends
    func proof(targetId: String, family: SentinelleFamily?) async throws -> SentinelleProof
    func create(label: String, address: String, ownerLabel: String?, ownerEmoji: String?) async throws
    func setOwner(targetId: String, ownerLabel: String?, ownerEmoji: String?) async throws
    func setAddress(targetId: String, family: SentinelleFamily, address: String) async throws
    func delete(targetId: String) async throws
    func currentIp() async throws -> SentinelleCurrentIp
    func preferences() async throws -> SentinellePreferencesResponse
    func savePreferences(_ changes: SentinellePreferencesPatch) async throws
    func testWebhook() async throws -> SentinelleWebhookTest
    func followers(targetId: String) async throws -> SentinelleFollowersResponse
    func following() async throws -> SentinelleFollowingResponse
    func followedSeries(followId: String) async throws -> SentinelleSeriesResponse
    func sharedBox(slug: String) async throws -> SentinelleSharedBox
    func follow(shareInput: String) async throws
    func unfollow(followId: String) async throws
    func revokeFollower(targetId: String, followerId: String) async throws
    func setSharing(targetId: String, changes: SentinelleSharingPatch) async throws -> SentinelleTarget
}

final class SentinelleService: SentinelleServicing, @unchecked Sendable {
    private let api: APIClientProtocol

    init(api: APIClientProtocol) {
        self.api = api
    }

    func targets() async throws -> SentinelleTargetsResponse {
        try await get(APIEndpoint(path: "/api/sentinelle/targets"))
    }

    func detail(targetId: String) async throws -> SentinelleDetailResponse {
        try await get(APIEndpoint(path: "/api/sentinelle/targets/\(targetId)"))
    }

    func series(
        targetId: String,
        window: SentinelleWindow,
        family: SentinelleFamily?
    ) async throws -> SentinelleSeriesResponse {
        try await get(APIEndpoint(
            path: "/api/sentinelle/targets/\(targetId)/series",
            query: [URLQueryItem(name: "window", value: window.rawValue)] + Self.familyQuery(family)
        ))
    }

    func diagnostic(targetId: String, family: SentinelleFamily?) async throws -> SentinelleDiagnostic {
        try await get(insights(targetId: targetId, section: "diagnostic", family: family))
    }

    func trends(targetId: String, family: SentinelleFamily?) async throws -> SentinelleTrends {
        try await get(insights(targetId: targetId, section: "trends", family: family))
    }

    func proof(targetId: String, family: SentinelleFamily?) async throws -> SentinelleProof {
        try await get(insights(targetId: targetId, section: "proof", family: family))
    }

    func create(label: String, address: String, ownerLabel: String?, ownerEmoji: String?) async throws {
        // On laisse le serveur trancher ce qu'il accepte de sonder : dupliquer
        // ses règles ici les ferait diverger, et c'est une frontière de sécurité.
        // Le client ne décide que du CHAMP, que le contrat impose de nommer.
        let field: String
        if address.contains(":") {
            field = "ipv6"
        } else if address.allSatisfy({ $0.isNumber || $0 == "." }) {
            field = "ipv4"
        } else {
            field = "hostname"
        }
        // Les champs vides sont OMIS plutôt qu'envoyés nuls : le serveur
        // distingue « non fourni » de « effacer », et une création n'a rien à
        // effacer.
        // Les champs vides sont OMIS plutôt qu'envoyés vides : une création
        // n'a rien à effacer.
        var body: [String: String] = ["label": label, field: address]
        if let owner = SentinelleOwnerLabel.normalise(ownerLabel) { body["ownerLabel"] = owner }
        if let emoji = ownerEmoji, !emoji.isEmpty { body["ownerEmoji"] = emoji }
        try await send(path: "/api/sentinelle/targets", method: .post, body: body)
    }

    /// Change l'attribution. La chaîne VIDE efface : le serveur la normalise
    /// en `null` (`normaliseOwnerLabel`). C'est ce qui permet de retirer une
    /// étiquette sans introduire un corps de requête à valeurs nulles, que
    /// `send` — typé `[String: String]` — ne saurait pas transporter.
    func setOwner(targetId: String, ownerLabel: String?, ownerEmoji: String?) async throws {
        try await send(
            path: "/api/sentinelle/targets/\(targetId)",
            method: .patch,
            body: [
                "ownerLabel": SentinelleOwnerLabel.normalise(ownerLabel) ?? "",
                "ownerEmoji": ownerEmoji ?? "",
            ]
        )
    }

    /// Renseigne l'adresse d'UNE famille — qu'on comble un trou (ajout de
    /// l'IPv6) ou qu'on corrige une adresse existante.
    ///
    /// C'est une modification, pas une création : une box suivie en IPv4 et en
    /// IPv6 reste UNE connexion, avec un seul historique et un seul quota. En
    /// créer une deuxième dédoublerait les alertes.
    ///
    /// La famille est passée explicitement plutôt que devinée à la présence
    /// d'un « : » : l'appelant sait toujours quelle ligne il modifie, et une
    /// faute de frappe ne doit pas silencieusement écrire dans l'autre champ.
    func setAddress(targetId: String, family: SentinelleFamily, address: String) async throws {
        try await send(
            path: "/api/sentinelle/targets/\(targetId)",
            method: .patch,
            body: [family == .v6 ? "ipv6" : "ipv4": address]
        )
    }

    func delete(targetId: String) async throws {
        try await send(path: "/api/sentinelle/targets/\(targetId)", method: .delete, body: nil)
    }

    func currentIp() async throws -> SentinelleCurrentIp {
        try await get(APIEndpoint(path: "/api/sentinelle/current-ip"))
    }

    // MARK: Transport

    func preferences() async throws -> SentinellePreferencesResponse {
        try await get(APIEndpoint(path: "/api/sentinelle/preferences"))
    }

    func savePreferences(_ changes: SentinellePreferencesPatch) async throws {
        do {
            var endpoint = APIEndpoint(path: "/api/sentinelle/preferences", method: .patch)
            endpoint.headers = ["Content-Type": "application/json"]
            endpoint.body = try JSONEncoder.signalQuest.encode(changes)
            try await api.request(endpoint)
        } catch {
            throw Self.mapping(error)
        }
    }

    /// Le serveur répond 200 même quand le destinataire refuse : c'est `ok` qui
    /// tranche et `status` qui dit pourquoi. Un webhook Discord mal formé
    /// échouait jusqu'ici en silence — tout l'intérêt est d'exposer ce code.
    func testWebhook() async throws -> SentinelleWebhookTest {
        do {
            let endpoint = APIEndpoint(path: "/api/sentinelle/preferences/test-webhook", method: .post)
            return try await api.request(endpoint, as: SentinelleWebhookTest.self)
        } catch {
            throw Self.mapping(error)
        }
    }

    /// Les connexions que JE suis.
    ///
    /// Volontairement séparé de `targets()` : cette route n'exige PAS Premium,
    /// alors que la liste de mes propres box, si. Les enchaîner ferait
    /// disparaître les abonnements d'un utilisateur Free derrière un 403 qui ne
    /// les concerne pas.
    /// Lit une box partagée à partir de son jeton. Sans authentification —
    /// mais l'identité, si elle existe, sert au serveur à dire si on suit déjà.
    func sharedBox(slug: String) async throws -> SentinelleSharedBox {
        try await get(APIEndpoint(path: "/api/sentinelle/p/\(slug)", method: .get))
    }

    /// La courbe d'une box qu'on SUIT. Elle passe par l'identifiant de
    /// L'ABONNEMENT, jamais par le jeton de partage : le suiveur n'a pas ce
    /// jeton et ne doit pas l'obtenir — il pourrait le rediffuser, alors que le
    /// propriétaire n'a autorisé que lui.
    func followedSeries(followId: String) async throws -> SentinelleSeriesResponse {
        try await get(APIEndpoint(
            path: "/api/sentinelle/following/\(followId)/series",
            method: .get,
            query: [URLQueryItem(name: "window", value: SentinelleWindow.h24.rawValue)]
        ))
    }

    func following() async throws -> SentinelleFollowingResponse {
        try await get(APIEndpoint(path: "/api/sentinelle/following", method: .get))
    }

    /// Suit une box à partir de son lien de partage. Le jeton fait l'autorisation.
    func follow(shareInput: String) async throws {
        guard let slug = SentinelleShareLink.extractSlug(shareInput) else {
            throw SentinelleShareLinkError.invalid
        }
        try await send(path: "/api/sentinelle/p/\(slug)/follow", method: .post, body: nil)
    }

    /// Ne plus suivre. Le serveur révoque la ligne, il ne la supprime pas.
    func unfollow(followId: String) async throws {
        try await send(path: "/api/sentinelle/following/\(followId)", method: .delete, body: nil)
    }

    func followers(targetId: String) async throws -> SentinelleFollowersResponse {
        try await get(APIEndpoint(path: "/api/sentinelle/targets/\(targetId)/followers"))
    }

    /// Le serveur pose `revokedAt`, il ne supprime pas la ligne : l'historique
    /// des accès reste consultable par le propriétaire.
    func revokeFollower(targetId: String, followerId: String) async throws {
        do {
            let endpoint = APIEndpoint(
                path: "/api/sentinelle/targets/\(targetId)/followers",
                method: .delete,
                query: [URLQueryItem(name: "followerId", value: followerId)]
            )
            try await api.request(endpoint)
        } catch {
            throw Self.mapping(error)
        }
    }

    func setSharing(targetId: String, changes: SentinelleSharingPatch) async throws -> SentinelleTarget {
        do {
            var endpoint = APIEndpoint(path: "/api/sentinelle/targets/\(targetId)", method: .patch)
            endpoint.headers = ["Content-Type": "application/json"]
            endpoint.body = try JSONEncoder.signalQuest.encode(changes)
            let response = try await api.request(endpoint, as: SentinelleTargetResponse.self)
            return response.target
        } catch {
            throw Self.mapping(error)
        }
    }

    private func get<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        do {
            return try await api.request(endpoint, as: T.self)
        } catch {
            throw Self.mapping(error)
        }
    }

    private func send(path: String, method: HTTPMethod, body: [String: String]?) async throws {
        do {
            var endpoint = APIEndpoint(path: path, method: method)
            if let body {
                endpoint.headers = ["Content-Type": "application/json"]
                endpoint.body = try JSONEncoder.signalQuest.encode(body)
            }
            try await api.request(endpoint)
        } catch {
            throw Self.mapping(error)
        }
    }

    private func insights(targetId: String, section: String, family: SentinelleFamily?) -> APIEndpoint {
        APIEndpoint(
            path: "/api/sentinelle/targets/\(targetId)/insights",
            query: [URLQueryItem(name: "section", value: section)] + Self.familyQuery(family)
        )
    }

    /// Le paramètre `family` s'OMET quand il n'y a pas de famille à filtrer :
    /// un `family=` vide vaut 400 côté serveur.
    private static func familyQuery(_ family: SentinelleFamily?) -> [URLQueryItem] {
        guard let family else { return [] }
        return [URLQueryItem(name: "family", value: family.rawValue)]
    }

    /// Un 403 signifie « pas d'accès Premium », pas « quelque chose a échoué ».
    private static func mapping(_ error: Error) -> Error {
        if case APIError.http(let status, _, _, _, _) = error, status == 403 {
            return SentinelleAccessDenied()
        }
        return error
    }
}
