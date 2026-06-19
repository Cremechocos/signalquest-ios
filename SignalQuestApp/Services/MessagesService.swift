import Foundation

protocol MessagesServicing: Sendable {
    func conversations() async throws -> [MessageConversation]
    func createConversation(participantIds: [String], title: String?, e2ee: Bool) async throws -> CreateConversationResponse
    func searchUsers(query: String) async throws -> [MessageSearchUser]
    func messages(conversationId: String, cursor: String?) async throws -> MessagesPageResponse
    func messagesDelta(conversationId: String, since: Date) async throws -> [MessageItem]
    func sendText(_ text: String, in conversation: MessageConversation, replyToId: String?, e2ee: E2EEServicing?) async throws -> MessageItem
    func sendAttachments(
        _ attachments: [UploadedAttachment],
        caption: String,
        in conversation: MessageConversation,
        replyToId: String?,
        e2ee: E2EEServicing?
    ) async throws -> MessageItem
    func markRead(conversationId: String, lastMessageId: String) async throws
    func react(messageId: String, emoji: String) async throws
    func removeReaction(messageId: String, emoji: String) async throws
    func editMessage(messageId: String, text: String, in conversation: MessageConversation, e2ee: E2EEServicing?) async throws
    func deleteMessage(messageId: String, forEveryone: Bool) async throws
    func setTyping(conversationId: String) async
    func setConversationActive(conversationId: String, active: Bool) async
    func conversationViewers(conversationId: String) async -> [String]
    func uploadAttachment(conversationId: String, data: Data, filename: String, mimeType: String) async throws -> UploadedAttachment
    // Groupes
    func updateConversation(id: String, title: String?, addUserIds: [String], removeUserIds: [String]) async throws
    func leaveConversation(id: String) async throws
    func changeRole(conversationId: String, userId: String, role: String) async throws
    @discardableResult
    func uploadGroupPhoto(conversationId: String, data: Data) async throws -> URL?
    // Messagerie avancée (parité Android)
    func searchMessages(query: String, filters: MessageSearchFilters, take: Int) async throws -> [MessageSearchResult]
    func scheduledMessages(conversationId: String) async throws -> [ScheduledMessage]
    func createScheduledMessage(sendAt: Date, text: String, in conversation: MessageConversation, replyToId: String?, senderId: String?, e2ee: E2EEServicing?) async throws -> ScheduledMessage
    func deleteScheduledMessage(conversationId: String, scheduledId: String) async throws
    func pinnedMessages(conversationId: String) async throws -> [PinnedMessage]
    func pin(conversationId: String, messageId: String) async throws
    func unpin(conversationId: String, messageId: String) async throws
    func reminders(conversationId: String) async throws -> [MessageReminder]
    func createReminder(conversationId: String, messageId: String, reason: String?, remindAt: Date) async throws -> MessageReminder
    func deleteReminder(conversationId: String, reminderId: String) async throws
    func thread(parentMessageId: String, take: Int, cursor: String?) async throws -> ThreadPage
    func sendThreadReply(parentMessageId: String, text: String, in conversation: MessageConversation, e2ee: E2EEServicing?) async throws -> MessageItem
    func createPoll(conversationId: String, question: String, options: [String], multiSelect: Bool, endsAt: Date?, in conversation: MessageConversation, e2ee: E2EEServicing?) async throws -> PollCreateResponse
    func votePoll(pollId: String, optionIds: [String]) async throws -> MessagePoll
    func closePoll(pollId: String) async throws -> MessagePoll
    func transcription(messageId: String) async throws -> VoiceTranscription?
}

/// Pièce jointe déjà uploadée via `/api/messages/attachments`, prête à être
/// référencée dans un message (format Android `sendAttachmentMessage`).
struct UploadedAttachment: Codable, Equatable, Sendable {
    let kind: String
    let url: String
    let fileName: String?
    let contentType: String?
    let size: Int?
    let width: Int?
    let height: Int?
}

final class MessagesService: MessagesServicing {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func conversations() async throws -> [MessageConversation] {
        try await api.request(APIEndpoint(path: "/api/messages/conversations"), as: ConversationsResponse.self).conversations
    }

    func createConversation(participantIds: [String], title: String?, e2ee: Bool = true) async throws -> CreateConversationResponse {
        try await api.requestJSON(
            "/api/messages/conversations",
            body: CreateConversationRequest(participantIds: participantIds, title: title, e2ee: e2ee)
        )
    }

    func searchUsers(query: String) async throws -> [MessageSearchUser] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return try await api.request(
            APIEndpoint(
                path: "/api/users/search",
                query: [
                    URLQueryItem(name: "q", value: q),
                    URLQueryItem(name: "limit", value: "20")
                ]
            ),
            as: [MessageSearchUser].self
        )
    }

    func messages(conversationId: String, cursor: String? = nil) async throws -> MessagesPageResponse {
        var query = [URLQueryItem(name: "take", value: "80")]
        // Curseur de pagination ascendante : charge la page de messages PLUS ANCIENS
        // (le backend renvoie nextCursor/hasMore). Permet de remonter au-delà des 80
        // derniers (cf. audit COMPLETENESS-04).
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await api.request(
            APIEndpoint(path: "/api/messages/conversations/\(conversationId)/messages",
                        query: query),
            as: MessagesPageResponse.self
        )
    }

    func messagesDelta(conversationId: String, since: Date) async throws -> [MessageItem] {
        // Le backend exige `since` (date ISO) et renvoie les messages créés,
        // édités OU supprimés après cette date.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let query = [
            URLQueryItem(name: "take", value: "100"),
            URLQueryItem(name: "since", value: formatter.string(from: since))
        ]
        return try await api.request(
            APIEndpoint(path: "/api/messages/conversations/\(conversationId)/messages/delta", query: query),
            as: MessagesPageResponse.self
        ).messages
    }

    func sendText(_ text: String, in conversation: MessageConversation, replyToId: String? = nil, e2ee: E2EEServicing?) async throws -> MessageItem {
        let payload: SendMessageRequest
        if conversation.e2eeEnabled == true {
            guard let e2ee else { throw E2EEError.locked }
            let encrypted = try await e2ee.encryptText(conversationId: conversation.id, text: text)
            // Partage la clé de conversation aux participants qui ne l'ont pas
            // encore (ex. un destinataire Android ayant configuré son E2EE APRÈS
            // la dernière ouverture de la conversation) — sinon il voit le message
            // verrouillé et ne peut jamais le déchiffrer. Best-effort : n'échoue
            // pas l'envoi. (Le chiffrement ci-dessus garantit qu'on détient bien
            // la clé localement.)
            await e2ee.shareConversationKeyIfNeeded(conversationId: conversation.id)
            payload = SendMessageRequest(kind: "TEXT", content: nil, e2ee: encrypted, replyToId: replyToId, attachments: nil)
        } else {
            payload = SendMessageRequest(kind: "TEXT", content: text, e2ee: nil, replyToId: replyToId, attachments: nil)
        }
        let response: CreatedMessageResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversation.id)/messages",
            body: payload
        )
        return response.message
    }

    func sendAttachments(
        _ attachments: [UploadedAttachment],
        caption: String,
        in conversation: MessageConversation,
        replyToId: String? = nil,
        e2ee: E2EEServicing?
    ) async throws -> MessageItem {
        // Les pièces jointes voyagent en clair dans `attachments` (URLs serveur),
        // seul le texte d'accompagnement est chiffré — même comportement
        // qu'Android `sendAttachmentMessage`.
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        var encrypted: E2EEPayload?
        var content: String?
        if conversation.e2eeEnabled == true {
            guard let e2ee else { throw E2EEError.locked }
            // Cf. sendText : garantir que les participants récemment configurés
            // reçoivent la clé de conversation (best-effort).
            await e2ee.shareConversationKeyIfNeeded(conversationId: conversation.id)
            if !trimmedCaption.isEmpty {
                encrypted = try await e2ee.encryptText(conversationId: conversation.id, text: trimmedCaption)
            }
        } else if !trimmedCaption.isEmpty {
            content = trimmedCaption
        }
        let payload = SendMessageRequest(
            kind: attachments.isEmpty ? "TEXT" : "ATTACHMENT",
            content: content,
            e2ee: encrypted,
            replyToId: replyToId,
            attachments: attachments
        )
        let response: CreatedMessageResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversation.id)/messages",
            body: payload
        )
        return response.message
    }

    func markRead(conversationId: String, lastMessageId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversationId)/read-state",
            method: .patch,
            body: ["lastMessageId": lastMessageId]
        )
    }

    func react(messageId: String, emoji: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/messages/\(messageId)/reactions",
            body: ["emoji": emoji]
        )
    }

    func removeReaction(messageId: String, emoji: String) async throws {
        try await api.request(
            APIEndpoint(
                path: "/api/messages/messages/\(messageId)/reactions",
                method: .delete,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder.signalQuest.encode(["emoji": emoji])
            )
        )
    }

    func editMessage(messageId: String, text: String, in conversation: MessageConversation, e2ee: E2EEServicing?) async throws {
        struct EditRequest: Encodable {
            let action = "edit"
            let content: String?
            let e2ee: E2EEPayload?
        }
        let body: EditRequest
        if conversation.e2eeEnabled == true {
            guard let e2ee else { throw E2EEError.locked }
            let encrypted = try await e2ee.encryptText(conversationId: conversation.id, text: text)
            body = EditRequest(content: nil, e2ee: encrypted)
        } else {
            body = EditRequest(content: text, e2ee: nil)
        }
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/messages/\(messageId)",
            method: .patch,
            body: body
        )
    }

    func deleteMessage(messageId: String, forEveryone: Bool) async throws {
        struct DeleteRequest: Encodable {
            let action = "delete"
            let scope: String
        }
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/messages/\(messageId)",
            method: .patch,
            body: DeleteRequest(scope: forEveryone ? "all" : "me")
        )
    }

    func setTyping(conversationId: String) async {
        // Signal éphémère best-effort — l'échec est silencieux comme sur Android.
        try? await api.requestJSON(
            "/api/messages/conversations/\(conversationId)/typing",
            body: [String: String]()
        )
    }

    func setConversationActive(conversationId: String, active: Bool) async {
        // Présence « actif sur la conversation » — best-effort, échec silencieux
        // (parité Android). POST = je regarde (ping 30 s) ; DELETE = je quitte.
        let path = "/api/messages/conversations/\(conversationId)/active"
        if active {
            try? await api.requestJSON(path, body: [String: String]())
        } else {
            try? await api.request(APIEndpoint(path: path, method: .delete))
        }
    }

    func conversationViewers(conversationId: String) async -> [String] {
        struct ViewersResponse: Decodable { let viewers: [String] }
        let response: ViewersResponse? = try? await api.request(
            APIEndpoint(path: "/api/messages/conversations/\(conversationId)/active"),
            as: ViewersResponse.self
        )
        return response?.viewers ?? []
    }

    func uploadAttachment(conversationId: String, data: Data, filename: String, mimeType: String) async throws -> UploadedAttachment {
        struct Response: Decodable { let attachment: UploadedAttachment }
        let response: Response = try await api.uploadMultipart(
            path: "/api/messages/attachments",
            fields: ["conversationId": conversationId],
            fileField: "file",
            fileName: filename,
            mimeType: mimeType,
            data: data,
            as: Response.self
        )
        return response.attachment
    }

    // MARK: Groupes

    func updateConversation(id: String, title: String?, addUserIds: [String], removeUserIds: [String]) async throws {
        struct UpdateRequest: Encodable {
            let title: String?
            let addUserIds: [String]?
            let removeUserIds: [String]?
        }
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/conversations/\(id)",
            method: .patch,
            body: UpdateRequest(
                title: title,
                addUserIds: addUserIds.isEmpty ? nil : addUserIds,
                removeUserIds: removeUserIds.isEmpty ? nil : removeUserIds
            )
        )
    }

    func leaveConversation(id: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/conversations/\(id)",
            method: .patch,
            body: ["leave": true]
        )
    }

    func changeRole(conversationId: String, userId: String, role: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversationId)/members/\(userId)/role",
            method: .patch,
            body: ["role": role]
        )
    }

    @discardableResult
    func uploadGroupPhoto(conversationId: String, data: Data) async throws -> URL? {
        struct Response: Decodable { let success: Bool?; let groupPhotoUrl: String? }
        let response: Response = try await api.uploadMultipart(
            path: "/api/messages/conversations/\(conversationId)/photo",
            fields: [:],
            fileField: "photo",
            fileName: "group-photo.jpg",
            mimeType: "image/jpeg",
            data: data,
            as: Response.self
        )
        return response.groupPhotoUrl.flatMap(URL.init(string:))
    }

    // MARK: Messagerie avancée

    /// Encode une date au format ISO 8601 attendu par le backend (mêmes options
    /// que le delta sync : date complète + secondes fractionnaires).
    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func searchMessages(query: String, filters: MessageSearchFilters = .empty, take: Int = 50) async throws -> [MessageSearchResult] {
        var items: [URLQueryItem] = [URLQueryItem(name: "take", value: String(take))]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }
        if let v = filters.conversationId { items.append(URLQueryItem(name: "conversationId", value: v)) }
        if let v = filters.authorId { items.append(URLQueryItem(name: "authorId", value: v)) }
        if let v = filters.kind { items.append(URLQueryItem(name: "kind", value: v)) }
        if let v = filters.hasAttachment { items.append(URLQueryItem(name: "hasAttachment", value: v ? "true" : "false")) }
        if let v = filters.hasLink { items.append(URLQueryItem(name: "hasLink", value: v ? "true" : "false")) }
        if let v = filters.hasMention { items.append(URLQueryItem(name: "hasMention", value: v ? "true" : "false")) }
        if let v = filters.isUnread { items.append(URLQueryItem(name: "isUnread", value: v ? "true" : "false")) }
        if let v = filters.from { items.append(URLQueryItem(name: "from", value: Self.iso(v))) }
        if let v = filters.to { items.append(URLQueryItem(name: "to", value: Self.iso(v))) }
        return try await api.request(
            APIEndpoint(path: "/api/messages/search", query: items),
            as: MessageSearchResponse.self
        ).messages
    }

    func scheduledMessages(conversationId: String) async throws -> [ScheduledMessage] {
        try await api.request(
            APIEndpoint(path: "/api/messages/conversations/\(conversationId)/scheduled"),
            as: ScheduledMessagesResponse.self
        ).scheduledMessages
    }

    func createScheduledMessage(
        sendAt: Date,
        text: String,
        in conversation: MessageConversation,
        replyToId: String? = nil,
        senderId: String? = nil,
        e2ee: E2EEServicing?
    ) async throws -> ScheduledMessage {
        let sendAtISO = Self.iso(sendAt)
        if conversation.e2eeEnabled == true {
            // Planifié E2EE : le backend valide à la livraison une AAD = JSON
            // base64 portant {conversationId, senderId, scheduleId, kind, nonce,
            // sendAt, replyToId}. On génère donc l'id (scheduleId) côté client et
            // on chiffre en authentifiant exactement ce JSON.
            guard let e2ee else { throw E2EEError.locked }
            guard let senderId else { throw E2EEError.unsupported("Identité requise pour planifier un message chiffré") }
            let scheduleId = UUID().uuidString
            let nonce = UUID().uuidString
            struct ScheduledAAD: Encodable {
                let conversationId: String
                let senderId: String
                let scheduleId: String
                let kind: String
                let nonce: String
                let sendAt: String
                let replyToId: String?
            }
            let aadData = try JSONEncoder().encode(ScheduledAAD(
                conversationId: conversation.id, senderId: senderId, scheduleId: scheduleId,
                kind: "TEXT", nonce: nonce, sendAt: sendAtISO, replyToId: replyToId
            ))
            let encrypted = try await e2ee.encryptText(conversationId: conversation.id, text: text, aad: aadData)
            struct E2EEScheduledRequest: Encodable {
                let id: String
                let sendAt: String
                let kind = "TEXT"
                let replyToId: String?
                let nonce: String
                let e2ee: E2EEPayload
            }
            let response: ScheduledMessageResponse = try await api.requestJSON(
                "/api/messages/conversations/\(conversation.id)/scheduled",
                body: E2EEScheduledRequest(id: scheduleId, sendAt: sendAtISO, replyToId: replyToId, nonce: nonce, e2ee: encrypted)
            )
            return response.scheduledMessage
        }
        struct ScheduledRequest: Encodable {
            let sendAt: String
            let kind = "TEXT"
            let content: String
            let replyToId: String?
        }
        let response: ScheduledMessageResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversation.id)/scheduled",
            body: ScheduledRequest(sendAt: sendAtISO, content: text, replyToId: replyToId)
        )
        return response.scheduledMessage
    }

    func deleteScheduledMessage(conversationId: String, scheduledId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversationId)/scheduled/\(scheduledId)",
            method: .delete,
            body: [String: String]()
        )
    }

    func pinnedMessages(conversationId: String) async throws -> [PinnedMessage] {
        try await api.request(
            APIEndpoint(path: "/api/messages/conversations/\(conversationId)/pinned-messages"),
            as: PinnedMessagesResponse.self
        ).pinnedMessages
    }

    func pin(conversationId: String, messageId: String) async throws {
        struct PinResponse: Decodable {}
        let _: PinResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversationId)/pinned-messages",
            body: ["messageId": messageId]
        )
    }

    func unpin(conversationId: String, messageId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversationId)/pinned-messages/\(messageId)",
            method: .delete,
            body: [String: String]()
        )
    }

    func reminders(conversationId: String) async throws -> [MessageReminder] {
        try await api.request(
            APIEndpoint(path: "/api/messages/conversations/\(conversationId)/reminders"),
            as: MessageRemindersResponse.self
        ).reminders
    }

    func createReminder(conversationId: String, messageId: String, reason: String?, remindAt: Date) async throws -> MessageReminder {
        struct ReminderRequest: Encodable {
            let messageId: String
            let reason: String?
            let remindAt: String
        }
        let response: MessageReminderResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversationId)/reminders",
            body: ReminderRequest(messageId: messageId, reason: reason, remindAt: Self.iso(remindAt))
        )
        return response.reminder
    }

    func deleteReminder(conversationId: String, reminderId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversationId)/reminders/\(reminderId)",
            method: .delete,
            body: [String: String]()
        )
    }

    func thread(parentMessageId: String, take: Int = 50, cursor: String? = nil) async throws -> ThreadPage {
        var query = [URLQueryItem(name: "take", value: String(take))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await api.request(
            APIEndpoint(path: "/api/messages/messages/\(parentMessageId)/thread", query: query),
            as: ThreadPage.self
        )
    }

    func sendThreadReply(parentMessageId: String, text: String, in conversation: MessageConversation, e2ee: E2EEServicing?) async throws -> MessageItem {
        struct ThreadReplyRequest: Encodable {
            let kind = "TEXT"
            let content: String?
            let e2ee: E2EEPayload?
        }
        let body: ThreadReplyRequest
        if conversation.e2eeEnabled == true {
            guard let e2ee else { throw E2EEError.locked }
            let encrypted = try await e2ee.encryptText(conversationId: conversation.id, text: text)
            body = ThreadReplyRequest(content: nil, e2ee: encrypted)
        } else {
            body = ThreadReplyRequest(content: text, e2ee: nil)
        }
        let response: CreatedMessageResponse = try await api.requestJSON(
            "/api/messages/messages/\(parentMessageId)/thread-replies",
            body: body
        )
        return response.message
    }

    func createPoll(
        conversationId: String,
        question: String,
        options: [String],
        multiSelect: Bool,
        endsAt: Date?,
        in conversation: MessageConversation,
        e2ee: E2EEServicing?
    ) async throws -> PollCreateResponse {
        let cleanOptions = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let endsAtISO = endsAt.map(Self.iso)

        if conversation.e2eeEnabled == true {
            // Cas E2EE : on n'envoie que les identifiants d'options en clair
            // (opt_1, opt_2, …) ; la question et les textes d'options voyagent
            // chiffrés dans `e2ee` sous forme d'un JSON `poll_v1`, déchiffré
            // ensuite côté client (même format que le web).
            guard let e2ee else { throw E2EEError.locked }
            let optionIds = cleanOptions.indices.map { "opt_\($0 + 1)" }
            let encoded = PollEncryptedPayload(
                type: "poll_v1",
                question: question,
                options: zip(optionIds, cleanOptions).map { PollEncryptedPayload.Option(id: $0.0, text: $0.1) },
                multiSelect: multiSelect
            )
            let json = String(decoding: try JSONEncoder.signalQuest.encode(encoded), as: UTF8.self)
            let encrypted = try await e2ee.encryptText(conversationId: conversationId, text: json)
            struct E2EEPollRequest: Encodable {
                let optionIds: [String]
                let multiSelect: Bool
                let content: String
                let endsAt: String?
                let e2ee: E2EEPayload
            }
            let response: PollCreateResponse = try await api.requestJSON(
                "/api/messages/conversations/\(conversationId)/polls",
                body: E2EEPollRequest(
                    optionIds: optionIds,
                    multiSelect: multiSelect,
                    content: "📊 Sondage",
                    endsAt: endsAtISO,
                    e2ee: encrypted
                )
            )
            // Le serveur ne stocke que les identifiants d'options (E2EE) : on
            // réinjecte localement la question + les textes connus pour un
            // affichage immédiat et correct du sondage créé.
            return PollCreateResponse(poll: response.poll.mergingDecryptedTexts(json), message: response.message)
        } else {
            struct PollRequest: Encodable {
                let question: String
                let options: [String]
                let multiSelect: Bool
                let endsAt: String?
            }
            let response: PollCreateResponse = try await api.requestJSON(
                "/api/messages/conversations/\(conversationId)/polls",
                body: PollRequest(question: question, options: cleanOptions, multiSelect: multiSelect, endsAt: endsAtISO)
            )
            return response
        }
    }

    func votePoll(pollId: String, optionIds: [String]) async throws -> MessagePoll {
        let response: PollVoteResponse = try await api.requestJSON(
            "/api/messages/polls/\(pollId)/vote",
            body: ["optionIds": optionIds]
        )
        return response.poll
    }

    func closePoll(pollId: String) async throws -> MessagePoll {
        let response: PollVoteResponse = try await api.requestJSON(
            "/api/messages/polls/\(pollId)/close",
            body: [String: String]()
        )
        return response.poll
    }

    func transcription(messageId: String) async throws -> VoiceTranscription? {
        try await api.request(
            APIEndpoint(path: "/api/messages/messages/\(messageId)/transcription"),
            as: TranscriptionResponse.self
        ).transcription
    }
}

/// Payload chiffré d'un sondage E2EE (question + textes d'options), sérialisé en
/// JSON puis chiffré via `encryptText`. Décodé côté client après déchiffrement.
private struct PollEncryptedPayload: Encodable {
    let type: String
    let question: String
    let options: [Option]
    let multiSelect: Bool

    struct Option: Encodable {
        let id: String
        let text: String
    }
}
