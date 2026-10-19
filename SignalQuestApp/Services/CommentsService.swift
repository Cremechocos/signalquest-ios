import Foundation

protocol CommentsServicing: Sendable {
    func list(postId: String, cursor: String?) async throws -> SocialCommentsResponse
    /// Une page de `limit` commentaires (le détail d'un post n'en montre qu'un).
    func list(postId: String, cursor: String?, limit: Int) async throws -> SocialCommentsResponse
    func add(postId: String, text: String, parentId: String?) async throws -> SocialComment
    /// Les réponses d'un commentaire, chargées À LA DEMANDE.
    ///
    /// Pas avec le fil : une panne discutée porte vite des dizaines de réponses, et les descendre
    /// toutes pour n'en montrer aucune ferait payer à chacun la conversation des autres.
    func replies(postId: String, commentId: String, cursor: String?) async throws -> SocialCommentsResponse
    /// Like ❤️ d'un commentaire (idempotent). Renvoie l'état final `{ liked, count }`.
    func like(postId: String, commentId: String) async throws -> CommentReactionResponse
    /// Retire le like ❤️ d'un commentaire (idempotent).
    func unlike(postId: String, commentId: String) async throws -> CommentReactionResponse
    /// Supprime son propre commentaire (App Store, règle 1.2) : 403 pour celui
    /// d'un autre, 404 s'il n'existe plus.
    func delete(postId: String, commentId: String) async throws
}

extension CommentsServicing {
    func list(postId: String, cursor: String?, limit: Int) async throws -> SocialCommentsResponse {
        try await list(postId: postId, cursor: cursor)
    }

    /// Les doubles de test et de démonstration n'ont rien à supprimer.
    func delete(postId: String, commentId: String) async throws {}
}

final class CommentsService: CommentsServicing {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// Le feed unifié préfixe les ids de posts ("post-…") ; les routes de
    /// commentaires attendent l'id brut.
    private func normalizedPostId(_ raw: String) -> String {
        raw.hasPrefix("post-") ? String(raw.dropFirst("post-".count)) : raw
    }

    func list(postId: String, cursor: String? = nil) async throws -> SocialCommentsResponse {
        try await list(postId: postId, cursor: cursor, limit: 50)
    }

    func list(postId: String, cursor: String?, limit: Int) async throws -> SocialCommentsResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await api.request(
            APIEndpoint(path: "/api/social/posts/\(normalizedPostId(postId))/comments", query: query),
            as: SocialCommentsResponse.self
        )
    }

    func replies(
        postId: String,
        commentId: String,
        cursor: String? = nil
    ) async throws -> SocialCommentsResponse {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: "20")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await api.request(
            APIEndpoint(
                path: "/api/social/posts/\(normalizedPostId(postId))/comments/\(commentId)/replies",
                query: query
            ),
            as: SocialCommentsResponse.self
        )
    }

    func add(postId: String, text: String, parentId: String? = nil) async throws -> SocialComment {
        let response: CreateCommentResponse = try await api.requestJSON(
            "/api/social/posts/\(normalizedPostId(postId))/comments",
            body: CreateCommentRequest(text: text, parentId: parentId)
        )
        return response.comment
    }

    /// `POST .../comments/{commentId}/reactions` avec `{ emoji: "❤️" }` (même
    /// convention que les réactions de post). Le backend borne l'emoji à ❤️.
    func like(postId: String, commentId: String) async throws -> CommentReactionResponse {
        try await api.requestJSON(
            "/api/social/posts/\(normalizedPostId(postId))/comments/\(commentId)/reactions",
            body: ["emoji": "❤️"]
        )
    }

    /// `DELETE .../comments/{commentId}` → `{ deleted: true, commentId }`
    /// (suppression douce côté serveur, auteur seulement ; SOC-12).
    func delete(postId: String, commentId: String) async throws {
        try await api.request(
            APIEndpoint(
                path: "/api/social/posts/\(normalizedPostId(postId))/comments/\(commentId)",
                method: .delete
            )
        )
    }

    /// `DELETE .../comments/{commentId}/reactions` (retire le ❤️, sans corps).
    func unlike(postId: String, commentId: String) async throws -> CommentReactionResponse {
        try await api.request(
            APIEndpoint(
                path: "/api/social/posts/\(normalizedPostId(postId))/comments/\(commentId)/reactions",
                method: .delete
            ),
            as: CommentReactionResponse.self
        )
    }

}

// MARK: - Fil d'un site (SITE-1)

/// Ce qu'on publie dans le fil d'un site : une remarque, ou une demande d'aide qui joint l'état
/// radio de l'appareil.
enum SiteCommentKind: String, Codable, Sendable {
    case comment, help
}

/// L'état radio joint à une demande d'aide, aux noms du serveur, jamais de position.
///
/// iOS n'en remplit que la technologie : le reste (bande, PCI, RSRP…) n'est pas lisible sur
/// iPhone. Les autres champs servent à afficher ce qu'Android ou le web ont joint.
struct SiteCommentRadio: Codable, Equatable, Sendable {
    var technology: String?
    var band: String?
    var arfcn: Int?
    var pci: Int?
    var cellId: String?
    var tac: Int?
    var rsrp: Double?
    var rsrq: Double?
    var sinr: Double?
    var timingAdvance: Int?

    /// La technologie au format du serveur (« 2G » à « 5G ») : NSA et SA y sont la même 5G.
    static func coarse(_ technology: CellularRadioTechnology?) -> SiteCommentRadio? {
        switch technology {
        case .twoG: return SiteCommentRadio(technology: "2G")
        case .threeG: return SiteCommentRadio(technology: "3G")
        case .fourG: return SiteCommentRadio(technology: "4G")
        case .fiveGNSA, .fiveGSA: return SiteCommentRadio(technology: "5G")
        case nil: return nil
        }
    }

    /// « 4G · B3 · PCI 214 · −98 dBm », dans l'ordre où on lit une cellule.
    var summary: String {
        var parts: [String] = []
        if let technology { parts.append(technology) }
        if let band { parts.append(band.uppercased()) }
        if let pci { parts.append("PCI \(pci)") }
        if let rsrp { parts.append(String(localized: "\(Int(rsrp.rounded())) dBm")) }
        if let sinr { parts.append(String(localized: "SINR \(Int(sinr.rounded())) dB")) }
        return parts.joined(separator: " · ")
    }
}

struct SiteComment: Decodable, Identifiable, Equatable {
    let id: String
    let kind: SiteCommentKind
    let text: String
    let createdAt: Date?
    let radio: SiteCommentRadio?
    let author: SocialFeedAuthor
    let own: Bool
    let canDelete: Bool
}

struct SiteThreadSummary: Decodable, Equatable {
    let commentCount: Int
}

struct SiteCommentsPage: Decodable {
    let thread: SiteThreadSummary
    let comments: [SiteComment]
    let nextCursor: String?
}

private struct SiteCommentCreateRequest: Encodable {
    let market: String
    let `operator`: String
    let siteId: String
    let kind: SiteCommentKind
    let text: String
    let radio: SiteCommentRadio?
}

private struct SiteCommentCreateResponse: Decodable {
    let comment: SiteComment
}

protocol SiteCommentsServicing: Sendable {
    /// Le fil d'un site pour un opérateur, du plus récent au plus ancien. Lecture ouverte à tous.
    func list(market: String, operatorKey: String, siteId: String, cursor: String?) async throws -> SiteCommentsPage
    func add(market: String, operatorKey: String, siteId: String, kind: SiteCommentKind, text: String, radio: SiteCommentRadio?) async throws -> SiteComment
    /// Ses propres messages seulement.
    func delete(id: String) async throws
    /// Le membre a ouvert la discussion d'un site qu'il suit : son activité repart de maintenant.
    func markSeen(market: String, operatorKey: String, siteId: String) async
}

final class SiteCommentsService: SiteCommentsServicing {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// La clé du fil passe en query string : certains identifiants de site contiennent « : ».
    func list(market: String, operatorKey: String, siteId: String, cursor: String? = nil) async throws -> SiteCommentsPage {
        if AppEnvironment.usesDemoData { return Self.demoPage }
        var query = [
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "operator", value: operatorKey),
            URLQueryItem(name: "siteId", value: siteId),
            URLQueryItem(name: "limit", value: "20"),
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await api.request(
            APIEndpoint(path: "/api/site-threads/comments", query: query),
            as: SiteCommentsPage.self
        )
    }

    func add(market: String, operatorKey: String, siteId: String, kind: SiteCommentKind, text: String, radio: SiteCommentRadio?) async throws -> SiteComment {
        if AppEnvironment.usesDemoData {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return SiteComment(
                id: UUID().uuidString, kind: kind, text: text, createdAt: Date(), radio: radio,
                author: SocialFeedAuthor(id: "demo-me", name: "Alex", handle: "alex", avatarUrl: nil,
                                         isFriend: nil, isFollowing: nil, liveRadio: nil),
                own: true, canDelete: true
            )
        }
        let response: SiteCommentCreateResponse = try await api.requestJSON(
            "/api/site-threads/comments",
            body: SiteCommentCreateRequest(market: market, operator: operatorKey, siteId: siteId,
                                           kind: kind, text: text, radio: kind == .help ? radio : nil)
        )
        return response.comment
    }

    func delete(id: String) async throws {
        if AppEnvironment.usesDemoData { return }
        try await api.request(APIEndpoint(path: "/api/site-threads/comments/\(id)", method: .delete))
    }

    /// Sans suivi, rien n'est écrit ; un échec ne se montre pas, c'est un simple compteur.
    func markSeen(market: String, operatorKey: String, siteId: String) async {
        guard !AppEnvironment.usesDemoData,
              let key = SiteFollowKey(market: market, operatorKey: operatorKey, siteId: siteId) else { return }
        do {
            let status = try await api.request(APIEndpoint(path: "/api/me/follows/status", query: key.queryItems),
                                               as: SiteFollowStatus.self)
            guard let followId = status.followId else { return }
            try await api.request(APIEndpoint(path: "/api/me/follows/\(followId)/seen", method: .post))
        } catch {}
    }

    private static var demoPage: SiteCommentsPage { SiteCommentsPage(
        thread: SiteThreadSummary(commentCount: 2),
        comments: [
            SiteComment(
                id: "demo-site-comment-2", kind: .help,
                text: "Débit très faible ce soir au pied du pylône, quelqu'un d'autre ?",
                createdAt: Date().addingTimeInterval(-3_600),
                radio: SiteCommentRadio(technology: "4G", band: "b3", pci: 214, rsrp: -98),
                author: SocialFeedAuthor(id: "demo-camille", name: "Camille", handle: "camille", avatarUrl: nil,
                                         isFriend: nil, isFollowing: nil, liveRadio: nil),
                own: false, canDelete: false
            ),
            SiteComment(
                id: "demo-site-comment-1", kind: .comment,
                text: "La 5G est active sur ce site depuis lundi, 700 Mbit/s mesurés au centre-ville.",
                createdAt: Date().addingTimeInterval(-86_400 * 2),
                radio: nil,
                author: SocialFeedAuthor(id: "demo-yanis", name: "Yanis", handle: "yanis", avatarUrl: nil,
                                         isFriend: nil, isFollowing: nil, liveRadio: nil),
                own: false, canDelete: false
            ),
        ],
        nextCursor: nil
    ) }
}

/// La clé d'un suivi de site : un site, un marché et un opérateur précis (jamais « ALL »).
struct SiteFollowKey: Equatable, Sendable {
    let market: String
    let operatorKey: String
    let siteId: String

    init?(market: String, operatorKey: String?, siteId: String) {
        let market = market.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let operatorKey = operatorKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let siteId = siteId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !market.isEmpty, !siteId.isEmpty, !operatorKey.isEmpty, operatorKey.uppercased() != "ALL" else { return nil }
        self.market = market
        self.operatorKey = operatorKey
        self.siteId = siteId
    }

    init?(_ favorite: FavoriteAntenna) {
        self.init(market: favorite.market, operatorKey: favorite.operator, siteId: favorite.siteId)
    }

    /// Corps strict de `POST /api/me/follows` : le serveur refuse toute autre clé.
    var followBody: [String: String] {
        ["kind": "site", "market": market, "operator": operatorKey, "siteId": siteId]
    }

    /// L'identifiant passe en query string : certains contiennent « : ».
    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "market", value: market),
         URLQueryItem(name: "operator", value: operatorKey),
         URLQueryItem(name: "siteId", value: siteId)]
    }
}

struct SiteFollowStatus: Decodable, Equatable {
    let following: Bool
    let followId: String?
}

// MARK: - Salons (ROOM-1)

/// La région d'un salon (« auvergne-rhone-alpes », « Auvergne-Rhône-Alpes »).
struct RoomRegion: Decodable, Equatable, Hashable, Sendable {
    let slug: String
    let name: String
}

/// Un salon public : fixe, décrit par le serveur, jamais créé par un membre.
///
/// `scope` vaut `region` (une région ou un territoire × un opérateur) ou `national` (un opérateur,
/// ou « 5G SA · France »). `departments` porte les codes ANFR sur 3 caractères (« 038 », « 02A »,
/// « 971 ») : c'est ce qui permet de retrouver « Ton salon » sans envoyer de position.
struct RoomSummary: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let market: String
    let scope: String
    let name: String
    let region: RoomRegion?
    let departments: [String]?
    let operatorKey: String?
    let technology: String?
    /// Partages radio en cours dans le salon.
    let liveCount: Int
    let lastMessageAt: Date?
    let messages24h: Int

    var isNational: Bool { scope == "national" }

    private enum CodingKeys: String, CodingKey {
        case id, market, scope, name, region, departments, technology, liveCount, lastMessageAt, messages24h
        case operatorKey = "operator"
    }

    init(id: String, market: String = "FR", scope: String = "region", name: String, region: RoomRegion? = nil,
         departments: [String]? = nil, operatorKey: String? = nil, technology: String? = nil,
         liveCount: Int = 0, lastMessageAt: Date? = nil, messages24h: Int = 0) {
        self.id = id
        self.market = market
        self.scope = scope
        self.name = name
        self.region = region
        self.departments = departments
        self.operatorKey = operatorKey
        self.technology = technology
        self.liveCount = liveCount
        self.lastMessageAt = lastMessageAt
        self.messages24h = messages24h
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        market = c.decodeFlexibleString(forKey: .market) ?? "FR"
        scope = c.decodeFlexibleString(forKey: .scope) ?? "region"
        region = try? c.decodeIfPresent(RoomRegion.self, forKey: .region)
        departments = try? c.decodeIfPresent([String].self, forKey: .departments)
        operatorKey = c.decodeFlexibleString(forKey: .operatorKey)
        technology = c.decodeFlexibleString(forKey: .technology)
        liveCount = (try? c.decodeIfPresent(Int.self, forKey: .liveCount)) ?? 0
        lastMessageAt = try? c.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        messages24h = (try? c.decodeIfPresent(Int.self, forKey: .messages24h)) ?? 0
    }
}

private struct RoomsListResponse: Decodable {
    let rooms: [RoomSummary]

    private enum CodingKeys: String, CodingKey { case rooms }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rooms = c.decodeLossyArray([RoomSummary].self, forKey: .rooms)
    }
}

/// Un message de salon. Même forme que celui du fil d'une antenne, sans genre « aide ».
struct RoomMessage: Decodable, Identifiable, Equatable {
    let id: String
    let text: String
    let createdAt: Date?
    /// Ce qu'Android ou le web ont joint ; iOS n'en joint pas (aucune métrique radio lisible).
    let radio: SiteCommentRadio?
    let author: SocialFeedAuthor
    let own: Bool
    let canDelete: Bool

    private enum CodingKeys: String, CodingKey { case id, text, createdAt, radio, author, own, canDelete }

    init(id: String, text: String, createdAt: Date?, radio: SiteCommentRadio?, author: SocialFeedAuthor,
         own: Bool, canDelete: Bool) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.radio = radio
        self.author = author
        self.own = own
        self.canDelete = canDelete
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        radio = try? c.decodeIfPresent(SiteCommentRadio.self, forKey: .radio)
        author = try c.decode(SocialFeedAuthor.self, forKey: .author)
        let own = (try? c.decodeIfPresent(Bool.self, forKey: .own)) ?? false
        self.own = own
        canDelete = (try? c.decodeIfPresent(Bool.self, forKey: .canDelete)) ?? own
    }
}

/// Une page de messages, du plus récent au plus ancien. Un message illisible est écarté sans
/// vider la page.
struct RoomMessagesPage: Decodable {
    let room: RoomSummary?
    let messages: [RoomMessage]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey { case room, messages, nextCursor }

    init(room: RoomSummary? = nil, messages: [RoomMessage], nextCursor: String?) {
        self.room = room
        self.messages = messages
        self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        room = try? c.decodeIfPresent(RoomSummary.self, forKey: .room)
        messages = c.decodeLossyArray([RoomMessage].self, forKey: .messages)
        nextCursor = c.decodeFlexibleString(forKey: .nextCursor)
    }
}

private struct RoomMessageCreateResponse: Decodable {
    let message: RoomMessage
}

/// Corps STRICT de `POST /api/rooms/{id}/messages` : le serveur refuse toute autre clé.
private struct RoomMessageCreateRequest: Encodable {
    let text: String
}

/// Le partage radio en direct d'un membre du salon, en lecture seule (ROOM-1b).
///
/// Le serveur n'expose que des mesures, jamais de position ni de cellule. Un partage expire 90 s
/// après le dernier envoi de son auteur. iOS ne peut pas en publier (aucune métrique radio lisible).
struct RoomLiveShare: Decodable, Identifiable, Equatable {
    struct Download: Decodable, Equatable {
        let mbps: Double
        let measuredAt: Date?
    }

    let author: SocialFeedAuthor
    /// `radio` (mesures détaillées) ou `coarse` (technologie seule).
    let detail: String
    let radio: SiteCommentRadio?
    /// Clé de l'opérateur du réseau servant observé par le membre, ou nil.
    let network: String?
    let download: Download?
    let updatedAt: Date?
    let own: Bool

    var id: String { author.id }

    private enum CodingKeys: String, CodingKey { case author, detail, radio, network, download, updatedAt, own }

    init(author: SocialFeedAuthor, detail: String = "coarse", radio: SiteCommentRadio? = nil, network: String? = nil,
         download: Download? = nil, updatedAt: Date? = nil, own: Bool = false) {
        self.author = author
        self.detail = detail
        self.radio = radio
        self.network = network
        self.download = download
        self.updatedAt = updatedAt
        self.own = own
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        author = try c.decode(SocialFeedAuthor.self, forKey: .author)
        detail = c.decodeFlexibleString(forKey: .detail) ?? "coarse"
        radio = try? c.decodeIfPresent(SiteCommentRadio.self, forKey: .radio)
        network = c.decodeFlexibleString(forKey: .network)
        download = try? c.decodeIfPresent(Download.self, forKey: .download)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        own = (try? c.decodeIfPresent(Bool.self, forKey: .own)) ?? false
    }
}

private struct RoomLiveResponse: Decodable {
    let live: [RoomLiveShare]

    private enum CodingKeys: String, CodingKey { case live }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        live = c.decodeLossyArray([RoomLiveShare].self, forKey: .live)
    }
}

protocol RoomsServicing: Sendable {
    /// Les salons d'un marché (« FR » ou « DROM »), avec leur activité. Lecture ouverte à tous.
    func rooms(market: String) async throws -> [RoomSummary]
    /// Une page de messages, du plus récent au plus ancien. Lecture ouverte à tous.
    func messages(roomId: String, cursor: String?) async throws -> RoomMessagesPage
    func post(roomId: String, text: String) async throws -> RoomMessage
    /// Ses propres messages seulement : le serveur répond 404 pour celui d'un autre.
    func delete(messageId: String) async throws
    /// Les partages radio en cours. Exige une session : à n'appeler que connecté.
    func live(roomId: String) async throws -> [RoomLiveShare]
}

final class RoomsService: RoomsServicing {
    /// 20 par page, comme le fil d'une antenne.
    static let pageSize = 20

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func rooms(market: String) async throws -> [RoomSummary] {
        if AppEnvironment.usesDemoData { return RoomsDemo.rooms(market: market) }
        let response = try await api.request(
            APIEndpoint(path: "/api/rooms", query: [URLQueryItem(name: "market", value: market)]),
            as: RoomsListResponse.self
        )
        return response.rooms
    }

    func messages(roomId: String, cursor: String? = nil) async throws -> RoomMessagesPage {
        if AppEnvironment.usesDemoData { return RoomsDemo.page(roomId: roomId, cursor: cursor) }
        var query = [URLQueryItem(name: "limit", value: String(Self.pageSize))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await api.request(
            APIEndpoint(path: "/api/rooms/\(roomId)/messages", query: query),
            as: RoomMessagesPage.self
        )
    }

    func post(roomId: String, text: String) async throws -> RoomMessage {
        if AppEnvironment.usesDemoData {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return RoomsDemo.ownMessage(text: text)
        }
        let response: RoomMessageCreateResponse = try await api.requestJSON(
            "/api/rooms/\(roomId)/messages",
            body: RoomMessageCreateRequest(text: text)
        )
        return response.message
    }

    func delete(messageId: String) async throws {
        if AppEnvironment.usesDemoData { return }
        try await api.request(APIEndpoint(path: "/api/rooms/messages/\(messageId)", method: .delete))
    }

    func live(roomId: String) async throws -> [RoomLiveShare] {
        if AppEnvironment.usesDemoData { return RoomsDemo.live(roomId: roomId) }
        return try await api.request(
            APIEndpoint(path: "/api/rooms/\(roomId)/live"),
            as: RoomLiveResponse.self
        ).live
    }
}

/// Les règles locales des salons, sans réseau ni position envoyée.
enum RoomsLogic {
    /// Les quatre opérateurs métropolitains des salons de région et des salons nationaux.
    static let metroOperators = ["ORANGE", "SFR", "BOUYGUES", "FREE"]

    /// Clés du registre radio des territoires d'outre-mer.
    private static let dromOperators: Set<String> = [
        "FREE_CARAIBES", "DIGICEL", "OUTREMER_TELECOM", "SRR", "TELCO_OI", "ZEOP", "MAORE_MOBILE",
    ]

    /// Le nom d'un opérateur dans un salon : un nom propre, identique dans toutes les langues.
    static func operatorLabel(_ key: String) -> String {
        switch key {
        case "ORANGE": return "Orange"
        case "SFR": return "SFR"
        case "BOUYGUES": return "Bouygues"
        case "FREE": return "Free"
        case "FREE_CARAIBES": return "Free Caraïbe"
        case "OUTREMER_TELECOM": return "SFR Caraïbe"
        case "SRR": return "SFR Réunion"
        case "TELCO_OI": return "Free Réunion"
        case "DIGICEL": return "Digicel"
        case "ZEOP": return "Zeop"
        case "MAORE_MOBILE": return "Maore Mobile"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// La clé d'opérateur d'un salon à partir d'une clé du registre (« ORANGE », « Free »,
    /// « OUTREMER_TELECOM ») ou d'un nom d'opérateur (« Orange F », « F SFR »). nil si l'opérateur
    /// n'a aucun salon : mieux vaut ne rien proposer que le mauvais.
    static func operatorKey(from raw: String?) -> String? {
        guard let raw else { return nil }
        let folded = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .uppercased()
        guard !folded.isEmpty else { return nil }
        let key = folded.replacingOccurrences(of: "[ -]", with: "_", options: .regularExpression)
        if metroOperators.contains(key) || dromOperators.contains(key) { return key }
        // Un nom d'opérateur ultramarin n'est jamais ramené à son homonyme métropolitain.
        let overseas = ["CARAIB", "REUNION", "MAYOTTE", "GUADELOUPE", "MARTINIQUE", "GUYANE", "DIGICEL", "ZEOP", "OUTREMER"]
        guard !overseas.contains(where: folded.contains) else { return nil }
        if folded.contains("ORANGE") { return "ORANGE" }
        if folded.contains("BOUYGUES") || folded.contains("BYTEL") { return "BOUYGUES" }
        if folded.contains("SFR") || folded.contains("ALTICE") { return "SFR" }
        if folded.split(whereSeparator: { !$0.isLetter }).contains("FREE") { return "FREE" }
        return nil
    }

    /// Le code ANFR sur 3 caractères d'un code postal métropolitain ou ultramarin : « 38000 » →
    /// « 038 », « 20090 » → « 02A », « 97100 » → « 971 ». nil pour Monaco, un code incomplet ou
    /// un territoire sans salon.
    static func departmentCode(postalCode: String?) -> String? {
        guard let digits = postalCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              digits.count == 5, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let prefix = String(digits.prefix(2))
        switch prefix {
        case "00", "96", "98", "99":
            return nil
        case "20":
            // 200xx et 201xx : Corse-du-Sud ; à partir de 202xx : Haute-Corse.
            return (Int(digits.prefix(3)) ?? 0) <= 201 ? "02A" : "02B"
        case "97":
            let code = String(digits.prefix(3))
            return DromRegion(rawValue: code) != nil ? code : nil
        default:
            return "0" + prefix
        }
    }

    /// « Ton salon » : le salon de la région de l'utilisateur chez son opérateur, sinon le salon
    /// national de cet opérateur. Sans opérateur connu, rien. Un département d'outre-mer sans salon
    /// pour cet opérateur ne retombe pas sur un salon métropolitain.
    static func yourRoom(in rooms: [RoomSummary], operatorKey: String?, department: String?) -> RoomSummary? {
        guard let operatorKey = self.operatorKey(from: operatorKey) else { return nil }
        if let department {
            if let regional = rooms.first(where: {
                !$0.isNational && $0.operatorKey == operatorKey && ($0.departments ?? []).contains(department)
            }) { return regional }
            if DromRegion.fromDepartment(department) != nil { return nil }
        }
        return rooms.first { $0.isNational && $0.operatorKey == operatorKey && $0.technology == nil }
    }

    /// Relecture de la première page : les messages reçus passent devant, ceux déjà descendus
    /// (pages suivantes) restent dessous, et un message supprimé ou masqué disparaît s'il tombait
    /// dans la fenêtre relue. Fusion par identifiant, sans doublon.
    static func refreshed(firstPage: [RoomMessage], hasMore: Bool, existing: [RoomMessage]) -> [RoomMessage] {
        guard hasMore, let oldest = firstPage.last else { return firstPage }
        let ids = Set(firstPage.map(\.id))
        let older = existing.filter { message in
            guard !ids.contains(message.id) else { return false }
            guard let date = message.createdAt, let boundary = oldest.createdAt else { return true }
            return date <= boundary
        }
        return firstPage + older
    }

    /// Une page de plus sous les messages déjà lus, sans doublon.
    static func appending(_ page: [RoomMessage], to existing: [RoomMessage]) -> [RoomMessage] {
        let ids = Set(existing.map(\.id))
        return existing + page.filter { !ids.contains($0.id) }
    }

    /// Les identifiants que la relecture ajoute à ce qui est affiché.
    static func newIds(in merged: [RoomMessage], comparedTo shown: [RoomMessage]) -> [String] {
        let known = Set(shown.map(\.id))
        return merged.map(\.id).filter { !known.contains($0) }
    }
}

/// Le dernier passage de l'utilisateur dans chaque salon, gardé sur l'appareil : il sert au badge
/// « nouveaux messages » de la liste et ne part jamais au serveur.
enum RoomSeenStore {
    static let key = "rooms.lastSeen.v1"

    static func seenAt(_ roomId: String, defaults: UserDefaults = .standard) -> Date? {
        let all = defaults.dictionary(forKey: key) as? [String: Double]
        return all?[roomId].map { Date(timeIntervalSince1970: $0) }
    }

    static func markSeen(_ roomId: String, at date: Date = Date(), defaults: UserDefaults = .standard) {
        var all = (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]
        all[roomId] = date.timeIntervalSince1970
        defaults.set(all, forKey: key)
    }

    /// Le nombre à afficher sur la ligne d'un salon : l'activité des dernières 24 h, quand un message
    /// est arrivé depuis le dernier passage (ou que le salon n'a jamais été ouvert).
    static func newMessageCount(for room: RoomSummary, defaults: UserDefaults = .standard) -> Int {
        guard room.messages24h > 0, let last = room.lastMessageAt else { return 0 }
        guard let seen = seenAt(room.id, defaults: defaults) else { return room.messages24h }
        return last > seen ? room.messages24h : 0
    }
}

/// Salons de démonstration (`--demo-data`) : « Ton salon » en tête, des messages avec et sans
/// radio, un message à soi.
enum RoomsDemo {
    private static func author(_ id: String, _ name: String) -> SocialFeedAuthor {
        SocialFeedAuthor(id: id, name: name, handle: name.lowercased(), avatarUrl: nil,
                         isFriend: nil, isFollowing: nil, liveRadio: nil)
    }

    static func rooms(market: String) -> [RoomSummary] {
        let now = Date()
        if market.uppercased() == "DROM" {
            let region = RoomRegion(slug: "guadeloupe", name: "Guadeloupe")
            return [
                RoomSummary(id: "drom-guadeloupe-orange", market: "DROM", name: "Orange · Guadeloupe", region: region,
                            departments: ["971"], operatorKey: "ORANGE", liveCount: 1,
                            lastMessageAt: now.addingTimeInterval(-900), messages24h: 6),
                RoomSummary(id: "drom-guadeloupe-digicel", market: "DROM", name: "Digicel · Guadeloupe", region: region,
                            departments: ["971"], operatorKey: "DIGICEL"),
            ]
        }
        let ara = RoomRegion(slug: "auvergne-rhone-alpes", name: "Auvergne-Rhône-Alpes")
        let idf = RoomRegion(slug: "ile-de-france", name: "Île-de-France")
        let paca = RoomRegion(slug: "provence-alpes-cote-d-azur", name: "Provence-Alpes-Côte d'Azur")
        return [
            RoomSummary(id: "fr-auvergne-rhone-alpes-sfr", name: "SFR · Auvergne-Rhône-Alpes", region: ara,
                        departments: ["001", "038", "069"], operatorKey: "SFR", liveCount: 2,
                        lastMessageAt: now.addingTimeInterval(-240), messages24h: 14),
            RoomSummary(id: "fr-auvergne-rhone-alpes-orange", name: "Orange · Auvergne-Rhône-Alpes", region: ara,
                        departments: ["001", "038", "069"], operatorKey: "ORANGE",
                        lastMessageAt: now.addingTimeInterval(-7_200), messages24h: 5),
            RoomSummary(id: "fr-auvergne-rhone-alpes-bouygues", name: "Bouygues Telecom · Auvergne-Rhône-Alpes", region: ara,
                        departments: ["001", "038", "069"], operatorKey: "BOUYGUES"),
            RoomSummary(id: "fr-auvergne-rhone-alpes-free", name: "Free · Auvergne-Rhône-Alpes", region: ara,
                        departments: ["001", "038", "069"], operatorKey: "FREE",
                        lastMessageAt: now.addingTimeInterval(-40_000), messages24h: 1),
            RoomSummary(id: "fr-ile-de-france-sfr", name: "SFR · Île-de-France", region: idf,
                        departments: ["075", "092"], operatorKey: "SFR",
                        lastMessageAt: now.addingTimeInterval(-600), messages24h: 31),
            RoomSummary(id: "fr-ile-de-france-orange", name: "Orange · Île-de-France", region: idf,
                        departments: ["075", "092"], operatorKey: "ORANGE",
                        lastMessageAt: now.addingTimeInterval(-3_000), messages24h: 22),
            RoomSummary(id: "fr-provence-alpes-cote-d-azur-free", name: "Free · Provence-Alpes-Côte d'Azur", region: paca,
                        departments: ["006", "013"], operatorKey: "FREE"),
            RoomSummary(id: "fr-national-sfr", scope: "national", name: "SFR · France", operatorKey: "SFR",
                        lastMessageAt: now.addingTimeInterval(-1_800), messages24h: 48),
            RoomSummary(id: "fr-national-orange", scope: "national", name: "Orange · France", operatorKey: "ORANGE",
                        lastMessageAt: now.addingTimeInterval(-2_400), messages24h: 52),
            RoomSummary(id: "fr-national-5g-sa", scope: "national", name: "5G SA · France", technology: "5G_SA",
                        liveCount: 1, lastMessageAt: now.addingTimeInterval(-5_400), messages24h: 9),
        ]
    }

    static func page(roomId: String, cursor: String?) -> RoomMessagesPage {
        let now = Date()
        return RoomMessagesPage(room: nil, messages: [
            RoomMessage(id: "demo-room-3", text: "Plus de 5G depuis ce matin du côté de la Part-Dieu, quelqu'un d'autre ?",
                        createdAt: now.addingTimeInterval(-240),
                        radio: SiteCommentRadio(technology: "4G", band: "b3", pci: 214, rsrp: -98),
                        author: author("demo-camille", "Camille"), own: false, canDelete: false),
            RoomMessage(id: "demo-room-2", text: "Chez moi, la 5G est revenue vers midi.",
                        createdAt: now.addingTimeInterval(-1_500), radio: nil,
                        author: author("demo-me", "Alex"), own: true, canDelete: true),
            RoomMessage(id: "demo-room-1", text: "Bonjour à tous, le débit est correct à Grenoble ce matin.",
                        createdAt: now.addingTimeInterval(-9_000), radio: nil,
                        author: author("demo-yanis", "Yanis"), own: false, canDelete: false),
        ], nextCursor: nil)
    }

    static func ownMessage(text: String) -> RoomMessage {
        RoomMessage(id: UUID().uuidString, text: text, createdAt: Date(), radio: nil,
                    author: author("demo-me", "Alex"), own: true, canDelete: true)
    }

    static func live(roomId: String) -> [RoomLiveShare] {
        [RoomLiveShare(
            author: author("demo-nora", "Nora"), detail: "radio",
            radio: SiteCommentRadio(technology: "5G", band: "n78", pci: 417, rsrp: -91, sinr: 17),
            network: "SFR", download: RoomLiveShare.Download(mbps: 312, measuredAt: Date().addingTimeInterval(-120)),
            updatedAt: Date().addingTimeInterval(-20), own: false
        )]
    }
}
