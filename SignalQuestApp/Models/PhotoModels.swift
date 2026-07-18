import Foundation

struct PhotoListResponse: Codable {
    let photos: [Photo]
    let meta: PhotoPaginationMeta?
}

extension PhotoListResponse {
    private enum CodingKeys: String, CodingKey { case photos, meta }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Décodage par élément : une photo à URL/champ malformé est ignorée au lieu
        // de faire échouer toute la liste (ROB-04).
        photos = c.decodeLossyElementArray([Photo].self, forKey: .photos)
        meta = try? c.decodeIfPresent(PhotoPaginationMeta.self, forKey: .meta)
    }
}

struct PhotoPaginationMeta: Codable, Equatable {
    let page: Int?
    let limit: Int?
    let total: Int?
    let hasMore: Bool?
}

struct Photo: Codable, Identifiable, Equatable {
    let id: String
    let siteId: String?
    let enb: String?
    let imageUrl: URL?
    let thumbnailUrl: URL?
    let ogImageUrl: URL?
    let uploadedAt: Date?
    let createdAt: Date?
    let description: String?
    let caption: String?
    let likes: Int?
    let likeCount: Int?
    let socialPostId: String?
    let approved: Bool?
    let `operator`: String?
    let commentCount: Int?
    let repostsCount: Int?
    let favoritesCount: Int?
    let reactions: [SocialReactionSummary]?
    let likedByCurrentUser: Bool?
    let isLikedByMe: Bool?
    let userReaction: String?
    let authorId: String?
    let authorName: String?
    let authorAvatar: URL?
    let siteAddress: String?
    let latitude: Double?
    let longitude: Double?

    enum CodingKeys: String, CodingKey {
        case id, siteId, enb, imageUrl, thumbnailUrl, ogImageUrl, uploadedAt, createdAt, description, caption, likes, likeCount, socialPostId, approved, commentCount, repostsCount, favoritesCount, reactions, likedByCurrentUser, isLikedByMe, userReaction, authorId, authorName, authorAvatar, siteAddress, latitude, longitude
        case `operator` = "operator"
    }

    var displayCaption: String {
        caption ?? description ?? siteAddress ?? siteId ?? "Photo SignalQuest"
    }
}

struct PhotoComment: Codable, Identifiable, Equatable {
    let id: String
    let photoId: String?
    let userId: String?
    let userName: String?
    let content: String?
    let createdAt: Date?
    let updatedAt: Date?
    let parentId: String?
    let avatarUrl: URL?
}

struct PhotoCommentsResponse: Codable {
    let socialPostId: String?
    let comments: [PhotoComment]
}

struct PhotoLikeResponse: Codable {
    let success: Bool?
    let socialPostId: String?
    let liked: Bool?
    let reaction: String?
    let likes: Int?
    let reactions: [SocialReactionSummary]?
}

