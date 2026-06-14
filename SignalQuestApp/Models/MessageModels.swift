import Foundation

struct ConversationsResponse: Decodable {
    let conversations: [MessageConversation]
    let hasMore: Bool?
    let nextCursor: String?
}

struct MessageConversation: Decodable, Identifiable, Equatable {
    let id: String
    let title: String?
    let isGroup: Bool
    let e2eeEnabled: Bool?
    let groupPhotoUrl: URL?
    let createdAt: Date?
    let updatedAt: Date?
    let lastMessageAt: Date?
    let lastReadAt: Date?
    let pinnedAt: Date?
    let participants: [ConversationParticipant]
    let lastMessage: MessageItem?

    var displayTitle: String {
        displayTitle(excluding: nil)
    }

    /// Titre d'affichage en EXCLUANT l'utilisateur courant : une conversation 1:1
    /// montre le nom de l'autre, un groupe sans titre montre les noms des autres
    /// participants — jamais le sien.
    func displayTitle(excluding currentUserId: String?) -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        let others = participants
            .filter { currentUserId == nil || $0.userId != currentUserId }
            .map { $0.user.name ?? $0.user.email }
            .filter { !$0.isEmpty }
        let names = others.isEmpty
            ? participants.map { $0.user.name ?? $0.user.email }.filter { !$0.isEmpty }
            : others
        return names.joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case id, title, isGroup, e2eeEnabled, groupPhotoUrl, createdAt, updatedAt, lastMessageAt, lastReadAt, pinnedAt, participants, lastMessage
    }

    init(
        id: String,
        title: String?,
        isGroup: Bool,
        e2eeEnabled: Bool?,
        groupPhotoUrl: URL?,
        createdAt: Date?,
        updatedAt: Date?,
        lastMessageAt: Date?,
        lastReadAt: Date?,
        pinnedAt: Date?,
        participants: [ConversationParticipant],
        lastMessage: MessageItem?
    ) {
        self.id = id
        self.title = title
        self.isGroup = isGroup
        self.e2eeEnabled = e2eeEnabled
        self.groupPhotoUrl = groupPhotoUrl
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessageAt = lastMessageAt
        self.lastReadAt = lastReadAt
        self.pinnedAt = pinnedAt
        self.participants = participants
        self.lastMessage = lastMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = c.decodeFlexibleString(forKey: .title)
        isGroup = (try? c.decode(Bool.self, forKey: .isGroup)) ?? false
        e2eeEnabled = try c.decodeIfPresent(Bool.self, forKey: .e2eeEnabled)
        groupPhotoUrl = c.decodeLossyURL(forKey: .groupPhotoUrl)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        lastMessageAt = try c.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        lastReadAt = try c.decodeIfPresent(Date.self, forKey: .lastReadAt)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        participants = c.decodeLossyArray([ConversationParticipant].self, forKey: .participants)
        lastMessage = try c.decodeIfPresent(MessageItem.self, forKey: .lastMessage)
    }
}

struct ConversationParticipant: Decodable, Equatable, Identifiable {
    var id: String { userId }
    let userId: String
    let role: String?
    let joinedAt: Date?
    let lastReadAt: Date?
    let user: MessageUser
    let presence: SocialPresence?
}

struct MessageUser: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let email: String
    let avatarUrl: URL?

    var displayName: String { name ?? email.components(separatedBy: "@").first ?? "Utilisateur" }

    enum CodingKeys: String, CodingKey { case id, name, email, avatarUrl }

    init(id: String, name: String?, email: String, avatarUrl: URL?) {
        self.id = id
        self.name = name
        self.email = email
        self.avatarUrl = avatarUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = c.decodeFlexibleString(forKey: .name)
        email = c.decodeFlexibleString(forKey: .email) ?? ""
        avatarUrl = c.decodeLossyURL(forKey: .avatarUrl)
    }
}

struct MessageSearchUser: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let handle: String?
    let email: String
    let avatarUrl: URL?
    let isFriend: Bool?
    let hasPendingRequest: Bool?
    let blockedByMe: Bool?
    let blockedMe: Bool?

    var displayName: String { name ?? handle ?? email.components(separatedBy: "@").first ?? "Utilisateur" }

    enum CodingKeys: String, CodingKey { case id, name, handle, email, avatarUrl, isFriend, hasPendingRequest, blockedByMe, blockedMe }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = c.decodeFlexibleString(forKey: .name)
        handle = c.decodeFlexibleString(forKey: .handle)
        email = c.decodeFlexibleString(forKey: .email) ?? ""
        avatarUrl = c.decodeLossyURL(forKey: .avatarUrl)
        isFriend = try c.decodeIfPresent(Bool.self, forKey: .isFriend)
        hasPendingRequest = try c.decodeIfPresent(Bool.self, forKey: .hasPendingRequest)
        blockedByMe = try c.decodeIfPresent(Bool.self, forKey: .blockedByMe)
        blockedMe = try c.decodeIfPresent(Bool.self, forKey: .blockedMe)
    }
}

struct CreateConversationRequest: Encodable {
    let participantIds: [String]
    let title: String?
    let e2ee: Bool
}

struct CreateConversationResponse: Codable, Equatable {
    let conversationId: String
    let reused: Bool?
    let e2eePendingUserIds: [String]?
}

struct MessagesPageResponse: Decodable {
    let hasMore: Bool?
    let nextCursor: String?
    let readReceipts: [ReadReceipt]?
    let messages: [MessageItem]
}

struct ReadReceipt: Codable, Equatable {
    let userId: String
    let name: String?
    let lastReadAt: Date?
}

struct MessageAttachment: Decodable, Identifiable, Equatable {
    let id: String?
    let kind: String
    let url: URL?
    let fileName: String?
    let contentType: String?
    let size: Int?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey { case id, kind, url, fileName, contentType, size, width, height }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id)
        kind = c.decodeFlexibleString(forKey: .kind) ?? "FILE"
        url = c.decodeLossyURL(forKey: .url)
        fileName = c.decodeFlexibleString(forKey: .fileName)
        contentType = c.decodeFlexibleString(forKey: .contentType)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
    }
}

struct MessageReaction: Codable, Equatable {
    let emoji: String
    let userId: String
}

struct MessageItem: Decodable, Identifiable, Equatable {
    let id: String
    let conversationId: String?
    let senderId: String?
    let kind: String
    let content: String?
    let e2eeVersion: Int?
    let e2eeIvB64: String?
    let e2eeCiphertextB64: String?
    let e2eeAadB64: String?
    let metadata: String?
    let createdAt: Date?
    let editedAt: Date?
    let deletedAt: Date?
    let replyToId: String?
    let threadReplyCount: Int?
    let sender: MessageUser?
    let attachments: [MessageAttachment]
    let reactions: [MessageReaction]

    var isEncrypted: Bool {
        e2eeVersion != nil || e2eeCiphertextB64 != nil
    }

    enum CodingKeys: String, CodingKey {
        case id, conversationId, senderId, kind, content, e2eeVersion, e2eeIvB64, e2eeCiphertextB64, e2eeAadB64
        case metadata, createdAt, editedAt, deletedAt, replyToId, threadReplyCount, sender, attachments, reactions
    }

    init(
        id: String,
        conversationId: String?,
        senderId: String?,
        kind: String,
        content: String?,
        e2eeVersion: Int?,
        e2eeIvB64: String?,
        e2eeCiphertextB64: String?,
        e2eeAadB64: String?,
        metadata: String?,
        createdAt: Date?,
        editedAt: Date?,
        deletedAt: Date?,
        replyToId: String?,
        threadReplyCount: Int?,
        sender: MessageUser?,
        attachments: [MessageAttachment],
        reactions: [MessageReaction]
    ) {
        self.id = id
        self.conversationId = conversationId
        self.senderId = senderId
        self.kind = kind
        self.content = content
        self.e2eeVersion = e2eeVersion
        self.e2eeIvB64 = e2eeIvB64
        self.e2eeCiphertextB64 = e2eeCiphertextB64
        self.e2eeAadB64 = e2eeAadB64
        self.metadata = metadata
        self.createdAt = createdAt
        self.editedAt = editedAt
        self.deletedAt = deletedAt
        self.replyToId = replyToId
        self.threadReplyCount = threadReplyCount
        self.sender = sender
        self.attachments = attachments
        self.reactions = reactions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        conversationId = c.decodeFlexibleString(forKey: .conversationId)
        senderId = c.decodeFlexibleString(forKey: .senderId)
        kind = c.decodeFlexibleString(forKey: .kind) ?? "TEXT"
        content = c.decodeFlexibleString(forKey: .content)
        e2eeVersion = try c.decodeIfPresent(Int.self, forKey: .e2eeVersion)
        e2eeIvB64 = c.decodeFlexibleString(forKey: .e2eeIvB64)
        e2eeCiphertextB64 = c.decodeFlexibleString(forKey: .e2eeCiphertextB64)
        e2eeAadB64 = c.decodeFlexibleString(forKey: .e2eeAadB64)
        if let rawMetadata = c.decodeFlexibleString(forKey: .metadata) {
            // `/messages` renvoie metadata en chaîne JSON.
            metadata = rawMetadata
        } else if let json = try? c.decodeIfPresent(JSONValue.self, forKey: .metadata),
                  let data = try? JSONEncoder().encode(json),
                  let jsonString = String(data: data, encoding: .utf8) {
            // Certaines routes (création de sondage) renvoient metadata en OBJET :
            // on le ré-encode en vraie chaîne JSON pour rester parsable
            // (`String(describing:)` produirait une description Swift, pas du JSON).
            metadata = jsonString
        } else {
            metadata = nil
        }
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        replyToId = c.decodeFlexibleString(forKey: .replyToId)
        threadReplyCount = try c.decodeIfPresent(Int.self, forKey: .threadReplyCount)
        sender = try c.decodeIfPresent(MessageUser.self, forKey: .sender)
        attachments = c.decodeLossyArray([MessageAttachment].self, forKey: .attachments)
        reactions = c.decodeLossyArray([MessageReaction].self, forKey: .reactions)
    }
}

struct CreatedMessageResponse: Decodable {
    let message: MessageItem
}

struct SendMessageRequest: Encodable {
    let kind: String
    let content: String?
    let e2ee: E2EEPayload?
    let replyToId: String?
    let attachments: [UploadedAttachment]?
}

struct E2EEPayload: Codable, Equatable {
    let v: Int
    let ivB64: String
    let ciphertextB64: String
    let aadB64: String?
}

struct E2EEBootstrapResponse: Codable {
    let hasKey: Bool
    let key: E2EEBootstrapKey?
}

struct E2EEBootstrapKey: Codable, Equatable {
    let publicKeyJwk: String
    let encryptedPrivateJwk: String
    let kdfSaltB64: String
    let kdfIterations: Int
}

struct ConversationKeyResponse: Codable {
    let wrappedKeyB64: String
    let createdAt: Date?
}

// MARK: - Messagerie avancée (parité Android)

// MARK: Recherche

struct MessageSearchResponse: Decodable {
    let total: Int?
    let messages: [MessageSearchResult]
}

/// Résultat de recherche : un message enrichi du contexte de sa conversation
/// (id/titre/groupe) pour permettre la navigation depuis les résultats.
struct MessageSearchResult: Decodable, Identifiable, Equatable {
    let message: MessageItem
    let conversation: SearchConversationContext?

    var id: String { message.id }

    enum CodingKeys: String, CodingKey { case conversation }

    init(from decoder: Decoder) throws {
        // Le backend renvoie le message à plat (mêmes clés que MessageItem) avec
        // un objet `conversation` imbriqué — on décode les deux depuis le même
        // conteneur.
        message = try MessageItem(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decodeIfPresent(SearchConversationContext.self, forKey: .conversation)
    }
}

struct SearchConversationContext: Decodable, Equatable {
    let id: String
    let title: String?
    let isGroup: Bool?

    enum CodingKeys: String, CodingKey { case id, title, isGroup }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = c.decodeFlexibleString(forKey: .title)
        isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup)
    }
}

/// Filtres optionnels de recherche, repris des paramètres de `/api/messages/search`.
struct MessageSearchFilters: Equatable {
    var conversationId: String?
    var authorId: String?
    var kind: String?
    var hasAttachment: Bool?
    var hasLink: Bool?
    var hasMention: Bool?
    var isUnread: Bool?
    var from: Date?
    var to: Date?

    static let empty = MessageSearchFilters()
}

// MARK: Messages programmés

struct ScheduledMessagesResponse: Decodable {
    let scheduledMessages: [ScheduledMessage]
}

struct ScheduledMessageResponse: Decodable {
    let scheduledMessage: ScheduledMessage
}

struct ScheduledMessage: Decodable, Identifiable, Equatable {
    let id: String
    let conversationId: String?
    let senderId: String?
    let kind: String
    let content: String?
    let e2eeVersion: Int?
    let e2eeIvB64: String?
    let e2eeCiphertextB64: String?
    let e2eeAadB64: String?
    let metadata: String?
    let replyToId: String?
    let sendAt: Date?
    let status: String?
    let createdAt: Date?

    var isEncrypted: Bool { e2eeVersion != nil || e2eeCiphertextB64 != nil }

    enum CodingKeys: String, CodingKey {
        case id, conversationId, senderId, kind, content
        case e2eeVersion, e2eeIvB64, e2eeCiphertextB64, e2eeAadB64
        case metadata, replyToId, sendAt, status, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        conversationId = c.decodeFlexibleString(forKey: .conversationId)
        senderId = c.decodeFlexibleString(forKey: .senderId)
        kind = c.decodeFlexibleString(forKey: .kind) ?? "TEXT"
        content = c.decodeFlexibleString(forKey: .content)
        e2eeVersion = try c.decodeIfPresent(Int.self, forKey: .e2eeVersion)
        e2eeIvB64 = c.decodeFlexibleString(forKey: .e2eeIvB64)
        e2eeCiphertextB64 = c.decodeFlexibleString(forKey: .e2eeCiphertextB64)
        e2eeAadB64 = c.decodeFlexibleString(forKey: .e2eeAadB64)
        metadata = c.decodeFlexibleString(forKey: .metadata)
        replyToId = c.decodeFlexibleString(forKey: .replyToId)
        sendAt = try c.decodeIfPresent(Date.self, forKey: .sendAt)
        status = c.decodeFlexibleString(forKey: .status)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

// MARK: Messages épinglés

struct PinnedMessagesResponse: Decodable {
    let pinnedMessages: [PinnedMessage]
}

struct PinnedMessage: Decodable, Identifiable, Equatable {
    let messageId: String
    let pinnedAt: Date?
    let pinnedBy: MessageUser?
    let message: MessageItem?

    var id: String { messageId }

    enum CodingKeys: String, CodingKey { case messageId, pinnedAt, pinnedBy, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try c.decodeIfPresent(MessageItem.self, forKey: .message)
        message = nested
        messageId = c.decodeFlexibleString(forKey: .messageId) ?? nested?.id ?? UUID().uuidString
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        pinnedBy = try c.decodeIfPresent(MessageUser.self, forKey: .pinnedBy)
    }
}

// MARK: Rappels

struct MessageRemindersResponse: Decodable {
    let reminders: [MessageReminder]
}

struct MessageReminderResponse: Decodable {
    let reminder: MessageReminder
}

struct MessageReminder: Decodable, Identifiable, Equatable {
    let id: String
    let conversationId: String?
    let messageId: String?
    let reason: String?
    let remindAt: Date?
    let status: String?
    let message: MessageItem?

    enum CodingKeys: String, CodingKey {
        case id, conversationId, messageId, reason, remindAt, status, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        conversationId = c.decodeFlexibleString(forKey: .conversationId)
        messageId = c.decodeFlexibleString(forKey: .messageId)
        reason = c.decodeFlexibleString(forKey: .reason)
        remindAt = try c.decodeIfPresent(Date.self, forKey: .remindAt)
        status = c.decodeFlexibleString(forKey: .status)
        message = try c.decodeIfPresent(MessageItem.self, forKey: .message)
    }
}

// MARK: Threads

struct ThreadPage: Decodable {
    let parent: MessageItem?
    let replies: [MessageItem]
    let hasMore: Bool?
    let nextCursor: String?

    enum CodingKeys: String, CodingKey { case parent, replies, page }
    enum PageKeys: String, CodingKey { case hasMore, nextCursor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parent = try c.decodeIfPresent(MessageItem.self, forKey: .parent)
        replies = c.decodeLossyArray([MessageItem].self, forKey: .replies)
        if let page = try? c.nestedContainer(keyedBy: PageKeys.self, forKey: .page) {
            hasMore = try page.decodeIfPresent(Bool.self, forKey: .hasMore)
            nextCursor = page.decodeFlexibleString(forKey: .nextCursor)
        } else {
            hasMore = nil
            nextCursor = nil
        }
    }
}

// MARK: Sondages

struct PollVoteResponse: Decodable {
    let poll: MessagePoll
    let messageId: String?
}

struct PollCreateResponse: Decodable {
    let poll: MessagePoll
    let message: MessageItem?
}

/// Vue serveur d'un sondage (réponses de /polls, /vote, /close). Compteurs et
/// `votesByMe` déjà agrégés côté backend.
struct MessagePoll: Decodable, Equatable {
    let pollId: String
    let question: String
    let options: [PollOption]
    let multiSelect: Bool
    let createdById: String?
    let closedAt: Date?
    let endsAt: Date?
    let totalVotes: Int
    let votesByMe: [String]

    var isClosed: Bool { closedAt != nil }

    enum CodingKeys: String, CodingKey {
        case pollId, question, options, multiSelect, createdById, closedAt, endsAt, totalVotes, votesByMe
    }

    init(
        pollId: String,
        question: String,
        options: [PollOption],
        multiSelect: Bool,
        createdById: String?,
        closedAt: Date?,
        endsAt: Date?,
        totalVotes: Int,
        votesByMe: [String]
    ) {
        self.pollId = pollId
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.createdById = createdById
        self.closedAt = closedAt
        self.endsAt = endsAt
        self.totalVotes = totalVotes
        self.votesByMe = votesByMe
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pollId = c.decodeFlexibleString(forKey: .pollId) ?? UUID().uuidString
        question = c.decodeFlexibleString(forKey: .question) ?? ""
        options = c.decodeLossyArray([PollOption].self, forKey: .options)
        multiSelect = (try? c.decode(Bool.self, forKey: .multiSelect)) ?? false
        createdById = c.decodeFlexibleString(forKey: .createdById)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        endsAt = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        totalVotes = (try? c.decode(Int.self, forKey: .totalVotes)) ?? 0
        votesByMe = c.decodeLossyArray([String].self, forKey: .votesByMe)
    }
}

struct PollOption: Decodable, Identifiable, Equatable {
    let id: String
    let text: String
    let count: Int

    enum CodingKeys: String, CodingKey { case id, text, count }

    init(id: String, text: String, count: Int) {
        self.id = id
        self.text = text
        self.count = count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? ""
        text = c.decodeFlexibleString(forKey: .text) ?? ""
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
    }
}

// MARK: Transcription (notes vocales)

struct TranscriptionResponse: Decodable {
    let transcription: VoiceTranscription?
}

struct VoiceTranscription: Decodable, Equatable {
    let status: String?
    let language: String?
    let text: String?
    let provider: String?
    let confidence: Double?

    enum CodingKeys: String, CodingKey { case status, language, text, provider, confidence }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.decodeFlexibleString(forKey: .status)
        language = c.decodeFlexibleString(forKey: .language)
        text = c.decodeFlexibleString(forKey: .text)
        provider = c.decodeFlexibleString(forKey: .provider)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
    }
}

/// Sondage tel qu'il est lu depuis `message.metadata.poll`. Gère les DEUX
/// schémas de stockage des votes rencontrés côté backend :
/// 1. au niveau du sondage `votes: { userId: [optionId] }` (format autoritaire
///    de `_poll.ts`) ;
/// 2. par option `options[].votes: [userId]` (forme historique/web).
/// Sert au rendu initial d'une bulle de sondage avant tout vote (les réponses
/// de /vote et /close renvoient ensuite un `MessagePoll` agrégé).
struct PollMetadata: Equatable {
    let pollId: String
    let question: String
    let options: [PollMetadataOption]
    let multiSelect: Bool
    let createdById: String?
    let closedAt: Date?
    let endsAt: Date?

    struct PollMetadataOption: Equatable {
        let id: String
        let text: String
        let voterIds: [String]
    }

    /// Convertit en `MessagePoll` agrégé pour un rendu homogène avec les réponses
    /// d'API. `currentUserId` permet de calculer `votesByMe`.
    func toPoll(currentUserId: String?) -> MessagePoll {
        let voterSet = Set(options.flatMap { $0.voterIds })
        let summaryOptions = options.map { PollOption(id: $0.id, text: $0.text, count: $0.voterIds.count) }
        let votesByMe = currentUserId.map { uid in
            options.filter { $0.voterIds.contains(uid) }.map { $0.id }
        } ?? []
        return MessagePoll(
            pollId: pollId,
            question: question,
            options: summaryOptions,
            multiSelect: multiSelect,
            createdById: createdById,
            closedAt: closedAt,
            endsAt: endsAt,
            totalVotes: voterSet.count,
            votesByMe: votesByMe
        )
    }

    /// Décode un sondage depuis la chaîne JSON `message.metadata`. Renvoie nil si
    /// la clé `poll` est absente ou invalide.
    static func parse(fromMetadataJSON json: String?) -> PollMetadata? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let poll = root["poll"] as? [String: Any],
            let pollId = poll["pollId"] as? String, !pollId.isEmpty
        else { return nil }

        let question = (poll["question"] as? String) ?? ""
        let multiSelect = (poll["multiSelect"] as? Bool) ?? false
        let createdById = poll["createdById"] as? String
        let closedAtRaw = poll["closedAt"] as? String
        let endsAtRaw = poll["endsAt"] as? String

        // Votes possibles au niveau du sondage : { userId: [optionId] }.
        let pollLevelVotes = poll["votes"] as? [String: [String]] ?? [:]
        // Inverse en { optionId: [userId] } pour fusion avec le schéma par option.
        var votersByOption: [String: [String]] = [:]
        for (userId, optionIds) in pollLevelVotes {
            for optionId in optionIds {
                votersByOption[optionId, default: []].append(userId)
            }
        }

        let rawOptions = poll["options"] as? [[String: Any]] ?? []
        let options: [PollMetadataOption] = rawOptions.compactMap { opt in
            guard let id = opt["id"] as? String, !id.isEmpty else { return nil }
            let text = (opt["text"] as? String) ?? ""
            // Schéma par option : options[].votes = [userId].
            let perOptionVoters = opt["votes"] as? [String] ?? []
            let merged = Array(Set(perOptionVoters + (votersByOption[id] ?? [])))
            return PollMetadataOption(id: id, text: text, voterIds: merged)
        }
        guard options.count >= 2 else { return nil }

        return PollMetadata(
            pollId: pollId,
            question: question,
            options: options,
            multiSelect: multiSelect,
            createdById: createdById,
            closedAt: PollMetadata.parseDate(closedAtRaw),
            endsAt: PollMetadata.parseDate(endsAtRaw)
        )
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let noFraction = ISO8601DateFormatter()
        noFraction.formatOptions = [.withInternetDateTime]
        return noFraction.date(from: raw)
    }
}

/// Texte chiffré d'un sondage E2EE (`poll_v1`) : question + textes d'options,
/// déchiffré côté client puis fusionné dans le `MessagePoll` (dont le metadata
/// en clair ne porte que les identifiants d'options).
enum PollEncryptedContent {
    /// Renvoie (question, [optionId: text]) depuis le JSON déchiffré, ou nil.
    static func parse(_ decryptedText: String?) -> (question: String, texts: [String: String])? {
        guard
            let decryptedText,
            let data = decryptedText.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (root["type"] as? String) == "poll_v1"
        else { return nil }
        let question = (root["question"] as? String) ?? ""
        var texts: [String: String] = [:]
        if let options = root["options"] as? [[String: Any]] {
            for option in options {
                if let id = option["id"] as? String, let text = option["text"] as? String {
                    texts[id] = text
                }
            }
        }
        return (question, texts)
    }
}

extension MessagePoll {
    /// Fusionne la question et les textes d'options déchiffrés (cas E2EE) dans un
    /// sondage dont le serveur ne renvoie que les identifiants d'options.
    func mergingDecryptedTexts(_ decryptedText: String?) -> MessagePoll {
        guard let parsed = PollEncryptedContent.parse(decryptedText) else { return self }
        let mergedOptions = options.map { option -> PollOption in
            let text = parsed.texts[option.id] ?? option.text
            return PollOption(id: option.id, text: text, count: option.count)
        }
        return MessagePoll(
            pollId: pollId,
            question: question.isEmpty ? parsed.question : question,
            options: mergedOptions,
            multiSelect: multiSelect,
            createdById: createdById,
            closedAt: closedAt,
            endsAt: endsAt,
            totalVotes: totalVotes,
            votesByMe: votesByMe
        )
    }
}
