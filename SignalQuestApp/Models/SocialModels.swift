import Foundation

struct SocialFeedPage: Codable, Equatable {
    let items: [UnifiedSocialFeedItem]
    let nextCursor: String?
    let stories: [SocialStory]
    let trendingHashtags: [TrendingHashtag]
    let suggestedUsers: [SocialFeedAuthor]
    let requestId: String?
}

extension SocialFeedPage {
    private enum CodingKeys: String, CodingKey {
        case items, nextCursor, stories, trendingHashtags, suggestedUsers, requestId
    }

    // init(from:) en EXTENSION pour préserver l'init memberwise (utilisé pour le
    // mode démo et les mises à jour locales du feed). Décodage tolérant : un post
    // malformé ne vide pas tout le feed (décodage par élément), et les sections non
    // demandées selon `include=` (stories/trends/suggestions) peuvent être absentes
    // sans faire échouer tout l'appel — au lieu du `keyNotFound` fatal (ROB-02).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.decodeLossyElementArray([UnifiedSocialFeedItem].self, forKey: .items)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        stories = c.decodeLossyElementArray([SocialStory].self, forKey: .stories)
        trendingHashtags = c.decodeLossyElementArray([TrendingHashtag].self, forKey: .trendingHashtags)
        suggestedUsers = c.decodeLossyElementArray([SocialFeedAuthor].self, forKey: .suggestedUsers)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
    }
}

struct TrendingHashtag: Codable, Identifiable, Equatable {
    let tag: String
    let postCount: Int
    var id: String { tag }
}

struct SocialAuthorLiveRadio: Codable, Equatable, Hashable {
    let technology: String?
    let updatedAt: Date?
}

struct SocialFeedAuthor: Codable, Identifiable, Equatable {
    let id: String
    let name: String?
    let handle: String?
    let avatarUrl: URL?
    let isFriend: Bool?
    let isFollowing: Bool?
    let liveRadio: SocialAuthorLiveRadio?

    var displayName: String {
        name ?? handle.map { "@\($0)" } ?? "Utilisateur"
    }

    enum CodingKeys: String, CodingKey { case id, name, handle, avatarUrl, isFriend, isFollowing, liveRadio }

    init(
        id: String,
        name: String?,
        handle: String?,
        avatarUrl: URL?,
        isFriend: Bool?,
        isFollowing: Bool?,
        liveRadio: SocialAuthorLiveRadio?
    ) {
        self.id = id
        self.name = name
        self.handle = handle
        self.avatarUrl = avatarUrl
        self.isFriend = isFriend
        self.isFollowing = isFollowing
        self.liveRadio = liveRadio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = c.decodeFlexibleString(forKey: .name)
        handle = c.decodeFlexibleString(forKey: .handle)
        avatarUrl = c.decodeLossyURL(forKey: .avatarUrl)
        isFriend = try c.decodeIfPresent(Bool.self, forKey: .isFriend)
        isFollowing = try c.decodeIfPresent(Bool.self, forKey: .isFollowing)
        liveRadio = try c.decodeIfPresent(SocialAuthorLiveRadio.self, forKey: .liveRadio)
    }
}

/// Hashable pour pouvoir pousser un profil via `navigationDestination(item:)`.
extension SocialFeedAuthor: Hashable {}

struct SocialPostAttachment: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let url: URL?
    let thumbnailUrl: URL?
    let altText: String?
    let metadata: [String: JSONValue]?
}

struct CreatePostAttachment: Codable, Equatable {
    let kind: String
    let url: URL?
    let thumbnailUrl: URL?
    let altText: String?
    let metadata: [String: JSONValue]?
}

struct SocialUploadResponse: Codable, Equatable {
    let upload: CreatePostAttachment
    let requestId: String?
}

struct SocialReactionSummary: Codable, Identifiable, Equatable {
    let emoji: String
    let count: Int
    let reactedByMe: Bool?
    var id: String { emoji }
}

struct SocialStory: Codable, Identifiable, Equatable {
    let id: String
    let author: SocialFeedAuthor
    let text: String?
    let mediaUrl: URL?
    let thumbnailUrl: URL?
    let mediaKind: String?
    let background: String?
    let metadata: [String: JSONValue]?
    let visibility: String?
    let status: String?
    let durationSeconds: Int?
    let createdAt: Date?
    let expiresAt: Date?
    let viewedByMe: Bool?
    let isMine: Bool?
}

/// Réponse de `GET /api/social/network-pulse` : agrégat réseau autour d'une
/// position (RSRP moyen, débit médian, meilleur opérateur de la zone).
struct NetworkPulse: Decodable, Equatable {
    let avgRsrpDbm: Int?
    let medianDownloadMbps: Int?
    let measurementsCount: Int
    let bestOperator: String?
    let radiusMeters: Int?

    /// Rien à afficher tant qu'aucune mesure n'a été agrégée dans la zone.
    var hasData: Bool { measurementsCount > 0 }

    init(avgRsrpDbm: Int?, medianDownloadMbps: Int?, measurementsCount: Int, bestOperator: String?, radiusMeters: Int?) {
        self.avgRsrpDbm = avgRsrpDbm
        self.medianDownloadMbps = medianDownloadMbps
        self.measurementsCount = measurementsCount
        self.bestOperator = bestOperator
        self.radiusMeters = radiusMeters
    }

    enum CodingKeys: String, CodingKey {
        case avgRsrpDbm, medianDownloadMbps, measurementsCount, bestOperator, radiusMeters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Le backend arrondit déjà, mais on tolère un nombre à virgule par sûreté.
        func intFlex(_ key: CodingKeys) -> Int? {
            if let i = try? c.decode(Int.self, forKey: key) { return i }
            if let d = try? c.decode(Double.self, forKey: key) { return Int(d.rounded()) }
            return nil
        }
        avgRsrpDbm = intFlex(.avgRsrpDbm)
        medianDownloadMbps = intFlex(.medianDownloadMbps)
        measurementsCount = intFlex(.measurementsCount) ?? 0
        // Tolérant comme les autres champs : un bestOperator renvoyé en nombre ne
        // doit pas faire échouer tout le décodage du pouls réseau (ROB-06).
        bestOperator = c.decodeFlexibleString(forKey: .bestOperator)
        radiusMeters = intFlex(.radiusMeters)
    }

    static let demo = NetworkPulse(avgRsrpDbm: -85, medianDownloadMbps: 120, measurementsCount: 42, bestOperator: "Orange", radiusMeters: 3000)
}

struct SocialSignalSummary: Codable, Equatable {
    let type: String?
    let technology: String?
    let rsrp: Double?
    let rsrq: Double?
    let sinr: Double?
    let band: String?
    let cellId: String?
    let pci: Int?
    let `operator`: String?
    let city: String?
    let capturedAt: Date?
    let downloadMbps: Double?
    let uploadMbps: Double?
    let pingMs: Double?
    let jitterMs: Double?
    let maxDownloadMbps: Double?
    let distanceMeters: Double?
    let durationSeconds: Double?
    let detectedTechs: [String]
    let averageSignalDbm: Double?
    let minSignalDbm: Double?
    let maxSignalDbm: Double?
    let pointsCount: Int?
    let siteLabel: String?
    let identifierType: String?
    let identifierValue: String?
    let identifierSource: String?
    let validationCount: Int?
    let frequency: String?
    let earfcn: Int?
    let arfcn: Int?
    let sectors: [Int]?
    let deviceModel: String?
    let serverName: String?
    let latitude: Double?
    let longitude: Double?

    enum CodingKeys: String, CodingKey {
        case type, technology, rsrp, rsrq, sinr, band, cellId, pci, city, capturedAt, downloadMbps, uploadMbps, pingMs, jitterMs, maxDownloadMbps, distanceMeters, durationSeconds, detectedTechs, averageSignalDbm, minSignalDbm, maxSignalDbm, pointsCount, siteLabel, identifierType, identifierValue, identifierSource, validationCount, frequency, earfcn, arfcn, sectors, deviceModel, serverName, latitude, longitude
        case `operator` = "operator"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        technology = try c.decodeIfPresent(String.self, forKey: .technology)
        rsrp = try c.decodeIfPresent(Double.self, forKey: .rsrp)
        rsrq = try c.decodeIfPresent(Double.self, forKey: .rsrq)
        sinr = try c.decodeIfPresent(Double.self, forKey: .sinr)
        band = c.decodeFlexibleString(forKey: .band)
        cellId = c.decodeFlexibleString(forKey: .cellId)
        pci = try c.decodeIfPresent(Int.self, forKey: .pci)
        `operator` = try c.decodeIfPresent(String.self, forKey: .operator)
        city = try c.decodeIfPresent(String.self, forKey: .city)
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt)
        downloadMbps = try c.decodeIfPresent(Double.self, forKey: .downloadMbps)
        uploadMbps = try c.decodeIfPresent(Double.self, forKey: .uploadMbps)
        pingMs = try c.decodeIfPresent(Double.self, forKey: .pingMs)
        jitterMs = try c.decodeIfPresent(Double.self, forKey: .jitterMs)
        maxDownloadMbps = try c.decodeIfPresent(Double.self, forKey: .maxDownloadMbps)
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        detectedTechs = c.decodeLossyArray([String].self, forKey: .detectedTechs)
        averageSignalDbm = try c.decodeIfPresent(Double.self, forKey: .averageSignalDbm)
        minSignalDbm = try c.decodeIfPresent(Double.self, forKey: .minSignalDbm)
        maxSignalDbm = try c.decodeIfPresent(Double.self, forKey: .maxSignalDbm)
        pointsCount = try c.decodeIfPresent(Int.self, forKey: .pointsCount)
        siteLabel = try c.decodeIfPresent(String.self, forKey: .siteLabel)
        identifierType = try c.decodeIfPresent(String.self, forKey: .identifierType)
        identifierValue = c.decodeFlexibleString(forKey: .identifierValue)
        identifierSource = try c.decodeIfPresent(String.self, forKey: .identifierSource)
        validationCount = try c.decodeIfPresent(Int.self, forKey: .validationCount)
        frequency = c.decodeFlexibleString(forKey: .frequency)
        earfcn = try c.decodeIfPresent(Int.self, forKey: .earfcn)
        arfcn = try c.decodeIfPresent(Int.self, forKey: .arfcn)
        sectors = try c.decodeIfPresent([Int].self, forKey: .sectors)
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel)
        serverName = try c.decodeIfPresent(String.self, forKey: .serverName)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
    }
}

struct UnifiedSocialFeedItem: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let sourceType: String?
    let sourceId: String?
    let createdAt: Date?
    let score: Double?
    let author: SocialFeedAuthor
    let text: String
    let visibility: String?
    let status: String?
    let targetType: String?
    let targetId: String?
    let placeLabel: String?
    let latitude: Double?
    let longitude: Double?
    let metadata: [String: JSONValue]?
    let attachments: [SocialPostAttachment]
    let signal: SocialSignalSummary?
    let hashtags: [String]
    var reactions: [SocialReactionSummary]
    var commentsCount: Int
    var repostsCount: Int
    var favoritesCount: Int
    var likedByMe: Bool
    var favoritedByMe: Bool
    var repostedByMe: Bool
    var notificationsMutedByMe: Bool?

    enum CodingKeys: String, CodingKey {
        case id, kind, sourceType, sourceId, createdAt, score, author, text, visibility, status, targetType, targetId, placeLabel, latitude, longitude, metadata, attachments, signal, hashtags, reactions, commentsCount, repostsCount, favoritesCount, likedByMe, favoritedByMe, repostedByMe, notificationsMutedByMe
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "post"
        sourceType = try c.decodeIfPresent(String.self, forKey: .sourceType)
        sourceId = c.decodeFlexibleString(forKey: .sourceId)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        author = try c.decode(SocialFeedAuthor.self, forKey: .author)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        targetType = try c.decodeIfPresent(String.self, forKey: .targetType)
        targetId = c.decodeFlexibleString(forKey: .targetId)
        placeLabel = try c.decodeIfPresent(String.self, forKey: .placeLabel)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        attachments = c.decodeLossyArray([SocialPostAttachment].self, forKey: .attachments)
        signal = try c.decodeIfPresent(SocialSignalSummary.self, forKey: .signal)
        hashtags = c.decodeLossyArray([String].self, forKey: .hashtags)
        reactions = c.decodeLossyArray([SocialReactionSummary].self, forKey: .reactions)
        commentsCount = (try? c.decode(Int.self, forKey: .commentsCount)) ?? 0
        repostsCount = (try? c.decode(Int.self, forKey: .repostsCount)) ?? 0
        favoritesCount = (try? c.decode(Int.self, forKey: .favoritesCount)) ?? 0
        likedByMe = (try? c.decode(Bool.self, forKey: .likedByMe)) ?? false
        favoritedByMe = (try? c.decode(Bool.self, forKey: .favoritedByMe)) ?? false
        repostedByMe = (try? c.decode(Bool.self, forKey: .repostedByMe)) ?? false
        notificationsMutedByMe = try c.decodeIfPresent(Bool.self, forKey: .notificationsMutedByMe)
    }
}

struct CreatePostRequest: Codable {
    let text: String
    let visibility: String
    let targetType: String?
    let targetId: String?
    let placeLabel: String?
    let latitude: Double?
    let longitude: Double?
    let metadata: [String: JSONValue]?
    let attachments: [CreatePostAttachment]?
    let attachRadio: Bool?
}

struct CreatePostResponse: Codable {
    let post: UnifiedSocialFeedItem?
    let requestId: String?
}

struct ReactionResponse: Codable {
    // Le backend renvoie : `reactions` (avec reactedByMe par emoji), et pour
    // favori/repost les clés `favorited`/`favoritesCount` et `reposted`/`repostsCount`.
    // Il N'envoie PAS likedByMe/favoritedByMe/repostedByMe → on dérive l'état de like
    // depuis `reactions`.
    let reactions: [SocialReactionSummary]?
    let favorited: Bool?
    let favoritesCount: Int?
    let reposted: Bool?
    let repostsCount: Int?
    let requestId: String?
}

extension UnifiedSocialFeedItem {
    /// Identifiant backend du post. Le feed unifié préfixe les ids ("post-…",
    /// "photo-…") alors que les routes d'action attendent l'id brut.
    var backendPostId: String {
        if sourceType == "post", let sourceId, !sourceId.isEmpty { return sourceId }
        if id.hasPrefix("post-") { return String(id.dropFirst("post-".count)) }
        return id
    }
}

// MARK: - Profil public

struct SocialUserProfileStats: Codable, Equatable {
    let points: Int?
    let gamificationPoints: Int?
    let level: Int?
    let validations: Int?
    let photos: Int?
    let speedtests: Int?
}

/// Profil public renvoyé par GET /api/users/[id]/profile.
/// `handle` et `bio` sont décodés si la route les expose un jour.
struct SocialUserProfile: Codable, Equatable {
    let id: String
    let name: String?
    let handle: String?
    let bio: String?
    let avatarUrl: URL?
    let createdAt: Date?
    let isSelf: Bool
    let isFriend: Bool
    var isFollowing: Bool
    var followersCount: Int
    let followingCount: Int
    let canMessage: Bool?
    let stats: SocialUserProfileStats?

    var displayName: String {
        name ?? handle.map { "@\($0)" } ?? "Utilisateur"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, handle, bio, avatarUrl, createdAt, isSelf, isFriend
        case isFollowing, followersCount, followingCount, canMessage, stats
    }

    init(
        id: String,
        name: String?,
        handle: String?,
        bio: String?,
        avatarUrl: URL?,
        createdAt: Date?,
        isSelf: Bool,
        isFriend: Bool,
        isFollowing: Bool,
        followersCount: Int,
        followingCount: Int,
        canMessage: Bool?,
        stats: SocialUserProfileStats?
    ) {
        self.id = id
        self.name = name
        self.handle = handle
        self.bio = bio
        self.avatarUrl = avatarUrl
        self.createdAt = createdAt
        self.isSelf = isSelf
        self.isFriend = isFriend
        self.isFollowing = isFollowing
        self.followersCount = followersCount
        self.followingCount = followingCount
        self.canMessage = canMessage
        self.stats = stats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.decodeFlexibleString(forKey: .name)
        handle = c.decodeFlexibleString(forKey: .handle)
        bio = c.decodeFlexibleString(forKey: .bio)
        avatarUrl = c.decodeLossyURL(forKey: .avatarUrl)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        isSelf = (try? c.decode(Bool.self, forKey: .isSelf)) ?? false
        isFriend = (try? c.decode(Bool.self, forKey: .isFriend)) ?? false
        isFollowing = (try? c.decode(Bool.self, forKey: .isFollowing)) ?? false
        followersCount = (try? c.decode(Int.self, forKey: .followersCount)) ?? 0
        followingCount = (try? c.decode(Int.self, forKey: .followingCount)) ?? 0
        canMessage = try? c.decodeIfPresent(Bool.self, forKey: .canMessage)
        stats = try? c.decodeIfPresent(SocialUserProfileStats.self, forKey: .stats)
    }
}

struct SocialUserProfileResponse: Codable {
    let profile: SocialUserProfile
}

/// Réponse du toggle POST /api/social/follows/[userId].
/// `followersCount` = abonnés du profil ciblé, `followingCount` = MES abonnements.
struct SocialFollowResult: Codable, Equatable {
    let following: Bool
    let followersCount: Int?
    let followingCount: Int?
    let requestId: String?
}

/// Résultat de GET /api/users/search (tableau JSON brut).
struct SocialUserSearchResult: Codable, Identifiable, Equatable {
    let id: String
    let name: String?
    let handle: String?
    let avatarUrl: URL?
    let isFriend: Bool?

    var displayName: String {
        name ?? handle.map { "@\($0)" } ?? "Utilisateur"
    }

    enum CodingKeys: String, CodingKey { case id, name, handle, avatarUrl, isFriend }

    init(id: String, name: String?, handle: String?, avatarUrl: URL?, isFriend: Bool?) {
        self.id = id
        self.name = name
        self.handle = handle
        self.avatarUrl = avatarUrl
        self.isFriend = isFriend
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.decodeFlexibleString(forKey: .name)
        handle = c.decodeFlexibleString(forKey: .handle)
        avatarUrl = c.decodeLossyURL(forKey: .avatarUrl)
        isFriend = try? c.decodeIfPresent(Bool.self, forKey: .isFriend)
    }
}

// MARK: - Speedtest partageable (composer)

/// Sous-ensemble de GET /api/user/speedtests utilisé pour joindre
/// le dernier speedtest à un post (targetType=speedtest).
struct SocialShareableSpeedtest: Codable, Identifiable, Equatable {
    let id: String
    let downloadSpeed: Double?
    let uploadSpeed: Double?
    let ping: Double?
    let networkType: String?
    let mobileOperator: String?
    let timestamp: Date?

    enum CodingKeys: String, CodingKey {
        case id, downloadSpeed, uploadSpeed, ping, networkType, mobileOperator, timestamp
    }

    init(
        id: String,
        downloadSpeed: Double?,
        uploadSpeed: Double?,
        ping: Double?,
        networkType: String?,
        mobileOperator: String?,
        timestamp: Date?
    ) {
        self.id = id
        self.downloadSpeed = downloadSpeed
        self.uploadSpeed = uploadSpeed
        self.ping = ping
        self.networkType = networkType
        self.mobileOperator = mobileOperator
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        downloadSpeed = try? c.decodeIfPresent(Double.self, forKey: .downloadSpeed)
        uploadSpeed = try? c.decodeIfPresent(Double.self, forKey: .uploadSpeed)
        ping = try? c.decodeIfPresent(Double.self, forKey: .ping)
        networkType = c.decodeFlexibleString(forKey: .networkType)
        mobileOperator = c.decodeFlexibleString(forKey: .mobileOperator)
        timestamp = try? c.decodeIfPresent(Date.self, forKey: .timestamp)
    }
}

struct UserSpeedtestsResponse: Codable {
    let speedtests: [SocialShareableSpeedtest]
}
