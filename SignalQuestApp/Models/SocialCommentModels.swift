import Foundation

struct SocialComment: Decodable, Identifiable, Equatable {
    let id: String
    let postId: String?
    let parentId: String?
    let author: SocialFeedAuthor
    let text: String
    let createdAt: Date?
    let likes: Int?
    let likedByMe: Bool?
    let repliesCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, postId, parentId, author, text, content, body, createdAt
        case likes, likedByMe, repliesCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        postId = c.decodeFlexibleString(forKey: .postId)
        parentId = c.decodeFlexibleString(forKey: .parentId)
        author = (try? c.decode(SocialFeedAuthor.self, forKey: .author))
            ?? SocialFeedAuthor(id: "?", name: "Utilisateur", handle: nil, avatarUrl: nil, isFriend: nil, isFollowing: nil, liveRadio: nil)
        text = (try? c.decode(String.self, forKey: .text))
            ?? (try? c.decode(String.self, forKey: .content))
            ?? (try? c.decode(String.self, forKey: .body))
            ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        likes = try c.decodeIfPresent(Int.self, forKey: .likes)
        likedByMe = try c.decodeIfPresent(Bool.self, forKey: .likedByMe)
        repliesCount = try c.decodeIfPresent(Int.self, forKey: .repliesCount)
    }
}

struct SocialCommentsResponse: Decodable {
    let comments: [SocialComment]
    let nextCursor: String?
    let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case comments, items, results
        case nextCursor, cursor
        case totalCount, total
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        comments = (try? c.decode([SocialComment].self, forKey: .comments))
            ?? (try? c.decode([SocialComment].self, forKey: .items))
            ?? (try? c.decode([SocialComment].self, forKey: .results))
            ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? c.decodeIfPresent(String.self, forKey: .cursor)
        totalCount = try c.decodeIfPresent(Int.self, forKey: .totalCount)
            ?? c.decodeIfPresent(Int.self, forKey: .total)
    }
}

struct CreateCommentRequest: Codable {
    /// Le backend (zod) exige la clé JSON `text` (et NON `content`) — un mismatch
    /// ici renvoie 400 INVALID_COMMENT et l'app croit que l'envoi a échoué.
    let text: String
    let parentId: String?
}

struct CreateCommentResponse: Decodable {
    let comment: SocialComment

    enum CodingKeys: String, CodingKey { case comment, data, result, item }

    // DEC-COMMENT-WRAPPER-01 : tolère un commentaire renvoyé enveloppé
    // (`{ comment }`, le format actuel web/Android) OU à plat / sous data/result/
    // item — sinon un commentaire bel et bien créé fait croire à un échec d'envoi
    // et l'utilisateur poste un doublon. Repli final : décodage à plat depuis la
    // racine. `SocialComment.init` reste exigeant sur l'id → aucune régression.
    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            if let v = try? c.decode(SocialComment.self, forKey: .comment) { comment = v; return }
            if let v = try? c.decode(SocialComment.self, forKey: .data) { comment = v; return }
            if let v = try? c.decode(SocialComment.self, forKey: .result) { comment = v; return }
            if let v = try? c.decode(SocialComment.self, forKey: .item) { comment = v; return }
        }
        comment = try SocialComment(from: decoder)
    }
}
