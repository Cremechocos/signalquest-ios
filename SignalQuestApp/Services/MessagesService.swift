import CryptoKit
import Foundation

protocol MessagesServicing: Sendable {
    func conversations() async throws -> [MessageConversation]
    func createConversation(participantIds: [String], title: String?, e2ee: Bool) async throws -> CreateConversationResponse
    func searchUsers(query: String) async throws -> [MessageSearchUser]
    func messages(conversationId: String, cursor: String?) async throws -> MessagesPageResponse
    func messagesDelta(conversationId: String, since: Date) async throws -> [MessageItem]
    func sendText(_ text: String, in conversation: MessageConversation, replyToId: String?, e2ee: E2EEServicing?, idempotencyKey: String?, ttlSeconds: Int) async throws -> MessageItem
    func retryPendingTextMessages() async
    /// Partage une position (kind LOCATION). Refusé par le backend en conversation
    /// E2EE (allowedKinds) → l'appelant ne le propose qu'en conversation non chiffrée.
    func sendLocation(latitude: Double, longitude: Double, place: String?, in conversation: MessageConversation) async throws -> MessageItem
    // Partage GPS/radio en direct
    func liveShareSessions(conversationId: String) async throws -> [LiveShareSession]
    func activeLiveShareSessions() async throws -> [LiveShareSession]
    func createLiveShare(
        conversationId: String,
        e2eeEnabled: Bool,
        offerShare: Bool,
        message: String?,
        mode: String?,
        targetUserId: String?,
        targetUserIds: [String],
        mobileCountryCode: Int?,
        mobileNetworkCode: Int?
    ) async throws -> LiveShareCreateResponse
    func acceptLiveShare(
        sessionId: String,
        e2eeV2Required: Bool
    ) async throws -> LiveShareSession
    func declineLiveShare(sessionId: String) async throws -> LiveShareSession
    func stopLiveShare(sessionId: String) async throws
    func updateLiveShare(sessionId: String, payload: LiveSharePayload) async throws -> LiveShareSession
    func liveShareEvents(sessionId: String) -> AsyncStream<LiveShareStreamEvent>
    func updateE2eeLiveShare(session: LiveShareSession, payload: LiveSharePayload) async throws
    func e2eeLiveShareEvents(session: LiveShareSession) -> AsyncStream<LiveShareStreamEvent>
    func sendAttachments(
        _ attachments: [UploadedAttachment],
        caption: String,
        in conversation: MessageConversation,
        replyToId: String?,
        e2ee: E2EEServicing?
    ) async throws -> MessageItem
    func sendAttachmentData(
        _ data: Data,
        filename: String,
        mimeType: String,
        kind: String,
        caption: String,
        width: Int?,
        height: Int?,
        in conversation: MessageConversation,
        replyToId: String?,
        e2ee: E2EEServicing?
    ) async throws -> MessageItem
    func retryPendingAttachments() async
    func markRead(conversationId: String, lastMessageId: String) async throws
    func react(messageId: String, emoji: String, in conversation: MessageConversation) async throws
    func removeReaction(messageId: String, emoji: String, in conversation: MessageConversation) async throws
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
    func votePoll(pollId: String, optionIds: [String], in conversation: MessageConversation) async throws -> MessagePoll
    func closePoll(pollId: String, in conversation: MessageConversation) async throws -> MessagePoll
    func transcription(messageId: String) async throws -> VoiceTranscription?
    // Messages enregistrés (favoris)
    func savedMessages() async throws -> [SavedMessageEntry]
    func saveMessage(messageId: String) async throws
    func unsaveMessage(messageId: String) async throws
}

extension MessagesServicing {
    func activeLiveShareSessions() async throws -> [LiveShareSession] { [] }
    func retryPendingTextMessages() async {}
    func retryPendingAttachments() async {}

    func sendAttachmentData(
        _ data: Data,
        filename: String,
        mimeType: String,
        kind: String,
        caption: String,
        width: Int?,
        height: Int?,
        in conversation: MessageConversation,
        replyToId: String?,
        e2ee: E2EEServicing?
    ) async throws -> MessageItem {
        let uploaded = try await uploadAttachment(
            conversationId: conversation.id,
            data: data,
            filename: filename,
            mimeType: mimeType
        )
        let attachment = UploadedAttachment(
            kind: kind,
            url: uploaded.url,
            fileName: uploaded.fileName ?? filename,
            contentType: uploaded.contentType ?? mimeType,
            size: uploaded.size ?? data.count,
            width: uploaded.width ?? width,
            height: uploaded.height ?? height
        )
        return try await sendAttachments(
            [attachment],
            caption: caption,
            in: conversation,
            replyToId: replyToId,
            e2ee: e2ee
        )
    }
}

enum LegacyE2EEWriteFeature: CaseIterable, Sendable {
    case text
    case attachment
    case location
    case liveShare
    case poll
    case reaction
}

enum LegacyE2EEWritePolicy {
    static let v2RequiredMessage =
        "Cette action nécessite E2EE v2 vérifié. Rien n’a été envoyé au serveur."

    static func isAllowed(e2eeEnabled: Bool, feature: LegacyE2EEWriteFeature) -> Bool {
        !e2eeEnabled || feature == .text
    }

    static func requireAllowed(
        e2eeEnabled: Bool,
        feature: LegacyE2EEWriteFeature
    ) throws {
        guard isAllowed(e2eeEnabled: e2eeEnabled, feature: feature) else {
            throw E2EEError.unsupported(v2RequiredMessage)
        }
    }
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
    private let sse: SSEClient
    private let e2eeV2LiveShare: E2EEV2LiveShareTransportClient
    private let e2eeV2LiveShareRuntime: E2EEV2LiveShareRuntimeCoordinator
    private let e2eeV2LiveShareEventsClient: E2EEV2LiveShareEventClient
    private let textOutbox: MessageTextOutboxStore
    private let attachmentOutbox: MessageAttachmentOutboxStore

    init(
        api: APIClient,
        sse: SSEClient? = nil,
        textOutbox: MessageTextOutboxStore = MessageTextOutboxStore(),
        attachmentOutbox: MessageAttachmentOutboxStore = MessageAttachmentOutboxStore()
    ) {
        self.api = api
        self.sse = sse ?? SSEClient(api: api)
        self.textOutbox = textOutbox
        self.attachmentOutbox = attachmentOutbox
        let liveShareClient = E2EEV2LiveShareTransportClient(api: api)
        e2eeV2LiveShare = liveShareClient
        e2eeV2LiveShareRuntime = E2EEV2LiveShareRuntimeCoordinator(client: liveShareClient)
        e2eeV2LiveShareEventsClient = E2EEV2LiveShareEventClient(api: api)
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

    func sendText(_ text: String, in conversation: MessageConversation, replyToId: String? = nil, e2ee: E2EEServicing?, idempotencyKey: String? = nil, ttlSeconds: Int = 0) async throws -> MessageItem {
        if conversation.e2eeEnabled == true, e2ee == nil { throw E2EEError.locked }
        guard let accountSession = LocalAccountScope.sessionSnapshot() else {
            throw CancellationError()
        }
        let suppliedRequestId = idempotencyKey?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clientRequestId = suppliedRequestId.isEmpty
            ? "ios-message-\(UUID().uuidString.lowercased())"
            : suppliedRequestId
        if let existing = try await textOutbox.record(
            session: accountSession,
            clientRequestId: clientRequestId
        ) {
            guard existing.conversationId == conversation.id else {
                throw MessageTextOutboxError.requestConflict
            }
            return try await submitPreparedText(existing, session: accountSession)
        }

        // Messages éphémères : ttlSeconds > 0 → le backend pose expiresAt (le TTL
        // s'applique aussi en E2EE, c'est une métadonnée, pas le contenu).
        let ttl: Int? = ttlSeconds > 0 ? ttlSeconds : nil
        let payload: SendMessageRequest
        var shareConversationKey = false
        if conversation.e2eeEnabled == true {
            guard let e2ee else { throw E2EEError.locked }
            let encrypted = try await e2ee.encryptText(
                conversationId: conversation.id,
                text: text,
                contentType: .text,
                operationId: clientRequestId
            )
            shareConversationKey = true
            payload = SendMessageRequest(
                kind: "TEXT",
                content: nil,
                e2ee: encrypted,
                replyToId: replyToId,
                attachments: nil,
                ttlSeconds: ttl,
                clientRequestId: clientRequestId
            )
        } else {
            payload = SendMessageRequest(
                kind: "TEXT",
                content: text,
                e2ee: nil,
                replyToId: replyToId,
                attachments: nil,
                ttlSeconds: ttl,
                clientRequestId: clientRequestId
            )
        }
        let record = MessageTextOutboxRecord(
            ownerScopeId: accountSession.ownerScopeId,
            sessionId: accountSession.sessionId,
            conversationId: conversation.id,
            clientRequestId: clientRequestId,
            request: payload,
            createdAt: Date()
        )
        try await textOutbox.stage(record, session: accountSession)

        if shareConversationKey, let e2ee {
            // Best effort APRES la persistance : un kill pendant le partage de cle ne perd plus
            // l'intention de message ni son ciphertext exact.
            await e2ee.shareConversationKeyIfNeeded(conversationId: conversation.id)
        }
        return try await submitPreparedText(record, session: accountSession)
    }

    func retryPendingTextMessages() async {
        guard let session = LocalAccountScope.sessionSnapshot(), session.isCurrent else { return }
        guard let records = try? await textOutbox.pending(session: session) else { return }
        for record in records {
            guard session.isCurrent else { return }
            do {
                _ = try await submitPreparedText(record, session: session)
            } catch {
                // Conserver l'ordre : ne pas depasser un message dont l'issue est inconnue.
                return
            }
        }
    }

    private func submitPreparedText(
        _ record: MessageTextOutboxRecord,
        session: LocalAccountSession
    ) async throws -> MessageItem {
        guard session.isCurrent,
              record.ownerScopeId == session.ownerScopeId,
              record.sessionId == session.sessionId else {
            throw CancellationError()
        }
        let response: CreatedMessageResponse = try await api.requestJSON(
            "/api/messages/conversations/\(record.conversationId)/messages",
            body: record.request,
            idempotencyKey: record.clientRequestId
        )
        try await textOutbox.acknowledge(
            session: session,
            clientRequestId: record.clientRequestId
        )
        return response.message
    }

    func sendLocation(latitude: Double, longitude: Double, place: String?, in conversation: MessageConversation) async throws -> MessageItem {
        try LegacyE2EEWritePolicy.requireAllowed(
            e2eeEnabled: conversation.e2eeEnabled == true,
            feature: .location
        )
        struct LocationRequest: Encodable {
            let kind = "LOCATION"
            let content: String
            let metadata: Meta
            struct Meta: Encodable {
                let location: Loc
                struct Loc: Encodable { let lat: Double; let lng: Double; let place: String? }
            }
        }
        let cleanPlace = place?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = LocationRequest(
            content: cleanPlace ?? "",
            metadata: .init(location: .init(lat: latitude, lng: longitude, place: (cleanPlace?.isEmpty == false) ? cleanPlace : nil))
        )
        let response: CreatedMessageResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversation.id)/messages",
            body: body
        )
        return response.message
    }

    // MARK: Partage live

    func liveShareSessions(conversationId: String) async throws -> [LiveShareSession] {
        try await api.request(
            APIEndpoint(
                path: "/api/live-share/sessions",
                query: [URLQueryItem(name: "conversationId", value: conversationId)]
            ),
            as: LiveShareSessionsEnvelope.self
        ).sessions
    }

    func activeLiveShareSessions() async throws -> [LiveShareSession] {
        try await api.request(
            APIEndpoint(path: "/api/live-share/sessions"),
            as: LiveShareSessionsEnvelope.self
        ).sessions
    }

    func createLiveShare(
        conversationId: String,
        e2eeEnabled: Bool,
        offerShare: Bool,
        message: String?,
        mode: String?,
        targetUserId: String?,
        targetUserIds: [String],
        mobileCountryCode: Int?,
        mobileNetworkCode: Int?
    ) async throws -> LiveShareCreateResponse {
        let cleanMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = LiveShareCreateRequest(
            conversationId: conversationId,
            offerShare: offerShare,
            message: cleanMessage?.isEmpty == false ? cleanMessage : nil,
            mode: mode,
            targetUserId: targetUserId,
            targetUserIds: Array(Set(targetUserIds.filter { !$0.isEmpty })).sorted(),
            mobileCountryCode: mobileCountryCode,
            mobileNetworkCode: mobileNetworkCode
        )
        if !e2eeEnabled {
            return try await api.requestJSON("/api/live-share/requests", body: request)
        }
        guard E2EEV2RuntimeWriteGate.enabled,
              LocalAccountScope.currentUserId != nil else {
            throw E2EEError.unsupported(LegacyE2EEWritePolicy.v2RequiredMessage)
        }
        let ownerScopeId = LocalAccountScope.currentOwnerScopeId
        let body = try JSONEncoder().encode(request)
        switch await e2eeV2LiveShare.createSessionRuntime(
            ownerScopeId: ownerScopeId,
            conversationId: conversationId,
            body: body
        ) {
        case .failure(let failure): throw failure
        case .success(let sessions, let responseData):
            let response = try JSONDecoder.signalQuest.decode(
                LiveShareCreateResponse.self,
                from: responseData
            )
            guard response.sessions.map(\.id) == sessions.map(\.id),
                  response.sessions.allSatisfy({ session in
                    session.e2eeV2Required == true
                        && session.lastPayload == nil
                        && session.lastLocation == nil
                  }) else {
                throw E2EEV2TransportFailure(
                    kind: .localState,
                    message: "invalid-e2ee-v2-live-share-creation-response"
                )
            }
            return response
        }
    }

    func acceptLiveShare(
        sessionId: String,
        e2eeV2Required: Bool
    ) async throws -> LiveShareSession {
        if e2eeV2Required {
            guard E2EEV2RuntimeWriteGate.enabled,
                  LocalAccountScope.currentUserId != nil else {
                throw E2EEError.unsupported(LegacyE2EEWritePolicy.v2RequiredMessage)
            }
            switch await e2eeV2LiveShare.acceptSessionRuntime(
                ownerScopeId: LocalAccountScope.currentOwnerScopeId,
                sessionId: sessionId
            ) {
            case .failure(let failure): throw failure
            case .success(let sessions, _):
                guard let data = sessions.first?.valueData,
                      let session = try? JSONDecoder.signalQuest.decode(
                        LiveShareSession.self,
                        from: data
                      ),
                      session.e2eeV2Required == true,
                      session.lastPayload == nil,
                      session.lastLocation == nil else {
                    throw E2EEV2TransportFailure(
                        kind: .localState,
                        message: "invalid-e2ee-v2-live-share-acceptance-response"
                    )
                }
                return session
            }
        }
        let response: LiveShareSessionEnvelope = try await api.requestJSON(
            "/api/live-share/sessions/\(sessionId)/accept",
            body: [String: String]()
        )
        return response.session
    }

    func declineLiveShare(sessionId: String) async throws -> LiveShareSession {
        let response: LiveShareSessionEnvelope = try await api.requestJSON(
            "/api/live-share/sessions/\(sessionId)/decline",
            body: [String: String]()
        )
        return response.session
    }

    func stopLiveShare(sessionId: String) async throws {
        let _: LiveShareSessionEnvelope = try await api.requestJSON(
            "/api/live-share/sessions/\(sessionId)/stop",
            body: [String: String]()
        )
    }

    func updateLiveShare(sessionId: String, payload: LiveSharePayload) async throws -> LiveShareSession {
        let response: LiveShareSessionEnvelope = try await api.requestJSON(
            "/api/live-share/sessions/\(sessionId)/update",
            body: LiveShareUpdateRequest(payload: payload)
        )
        return response.session
    }

    func updateE2eeLiveShare(
        session: LiveShareSession,
        payload: LiveSharePayload
    ) async throws {
        guard LocalAccountScope.currentUserId != nil else { throw E2EEError.locked }
        try await e2eeV2LiveShareRuntime.publish(
            session: session,
            payload: payload,
            ownerScopeId: LocalAccountScope.currentOwnerScopeId
        )
    }

    func e2eeLiveShareEvents(
        session: LiveShareSession
    ) -> AsyncStream<LiveShareStreamEvent> {
        AsyncStream { continuation in
            let task = Task { [e2eeV2LiveShareRuntime, e2eeV2LiveShareEventsClient] in
                guard LocalAccountScope.currentUserId != nil else {
                    continuation.finish()
                    return
                }
                let ownerScopeId = LocalAccountScope.currentOwnerScopeId
                var lastEventId: String?
                var lastUpdateId: String?
                while !Task.isCancelled {
                    do {
                        var terminal = false
                        for try await event in e2eeV2LiveShareEventsClient.eventsRuntime(
                            ownerScopeId: ownerScopeId,
                            sessionId: session.id,
                            lastEventId: lastEventId
                        ) {
                            switch event {
                            case .status(let status, let eventId):
                                lastEventId = eventId ?? lastEventId
                                continuation.yield(.status(status))
                                terminal = ["stopped", "expired", "declined", "revoked"]
                                    .contains(status)
                            case .encryptedUpdate(let updateId, _, _, let eventId):
                                lastEventId = eventId ?? lastEventId
                                guard updateId != lastUpdateId else { continue }
                                if let received = try await e2eeV2LiveShareRuntime.fetchLatest(
                                    session: session,
                                    ownerScopeId: ownerScopeId
                                ) {
                                    lastUpdateId = received.updateId
                                    continuation.yield(.update(
                                        status: "active",
                                        lastUpdateAt: received.payload.at.flatMap(Self.parseLiveShareInstant),
                                        payload: received.payload
                                    ))
                                }
                            }
                        }
                        if terminal { break }
                    } catch is CancellationError {
                        break
                    } catch APIError.http(let status, _, _, _, _)
                        where status == 403 || status == 404 || status == 410 {
                        break
                    } catch {
                        // Reconnexion bornée ci-dessous ; aucune interrogation périodique.
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func parseLiveShareInstant(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    func liveShareEvents(sessionId: String) -> AsyncStream<LiveShareStreamEvent> {
        let source = sse.dataStream(
            path: "/api/live-share/sessions/\(sessionId)/stream",
            keep: ["status", "update"]
        )
        return AsyncStream { continuation in
            let task = Task {
                for await item in source {
                    guard !Task.isCancelled,
                          let data = item.data.data(using: .utf8) else { continue }
                    switch item.event {
                    case "status":
                        if let decoded = try? JSONDecoder.signalQuest.decode(LiveShareStatusEvent.self, from: data),
                           !decoded.status.isEmpty {
                            continuation.yield(.status(decoded.status))
                        }
                    case "update":
                        guard let decoded = try? JSONDecoder.signalQuest.decode(LiveShareUpdateEvent.self, from: data) else {
                            continue
                        }
                        continuation.yield(
                            .update(
                                status: decoded.status,
                                lastUpdateAt: decoded.lastUpdateAt,
                                payload: decoded.payload
                            )
                        )
                    default:
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func sendAttachments(
        _ attachments: [UploadedAttachment],
        caption: String,
        in conversation: MessageConversation,
        replyToId: String? = nil,
        e2ee: E2EEServicing?
    ) async throws -> MessageItem {
        // Ne jamais joindre une URL/métadonnée en clair à une conversation E2EE.
        // Le chiffrement binaire interopérable sera réactivé avec l'enveloppe média
        // V2 ; jusque-là on échoue explicitement avant la création du message.
        try LegacyE2EEWritePolicy.requireAllowed(
            e2eeEnabled: conversation.e2eeEnabled == true,
            feature: .attachment
        )
        guard let session = LocalAccountScope.sessionSnapshot() else {
            throw CancellationError()
        }
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientRequestId = "attachment-message-\(UUID().uuidString.lowercased())"
        let payload = SendMessageRequest(
            kind: attachments.isEmpty ? "TEXT" : "ATTACHMENT",
            content: trimmedCaption.isEmpty ? nil : trimmedCaption,
            e2ee: nil,
            replyToId: replyToId,
            attachments: attachments,
            ttlSeconds: nil,
            clientRequestId: clientRequestId
        )
        let record = MessageTextOutboxRecord(
            ownerScopeId: session.ownerScopeId,
            sessionId: session.sessionId,
            conversationId: conversation.id,
            clientRequestId: clientRequestId,
            request: payload,
            createdAt: Date()
        )
        try await textOutbox.stage(record, session: session)
        return try await submitPreparedText(record, session: session)
    }

    func sendAttachmentData(
        _ data: Data,
        filename: String,
        mimeType: String,
        kind: String,
        caption: String,
        width: Int?,
        height: Int?,
        in conversation: MessageConversation,
        replyToId: String?,
        e2ee: E2EEServicing?
    ) async throws -> MessageItem {
        try LegacyE2EEWritePolicy.requireAllowed(
            e2eeEnabled: conversation.e2eeEnabled == true,
            feature: .attachment
        )
        guard !data.isEmpty, let session = LocalAccountScope.sessionSnapshot() else {
            throw CancellationError()
        }
        let requestId = "attachment-\(UUID().uuidString.lowercased())"
        let record = MessageAttachmentOutboxRecord(
            ownerScopeId: session.ownerScopeId,
            sessionId: session.sessionId,
            conversationId: conversation.id,
            clientRequestId: requestId,
            filename: filename,
            mimeType: mimeType,
            kind: kind.uppercased(),
            caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
            replyToId: replyToId,
            width: width,
            height: height,
            contentSha256: Self.sha256Hex(data),
            uploadedAttachment: nil,
            createdAt: Date()
        )
        try await attachmentOutbox.stage(record, source: data, session: session)
        return try await submitPreparedAttachment(record, session: session)
    }

    func retryPendingAttachments() async {
        guard let session = LocalAccountScope.sessionSnapshot(), session.isCurrent else { return }
        guard let records = try? await attachmentOutbox.pending(session: session) else { return }
        for record in records {
            guard session.isCurrent else { return }
            do {
                _ = try await submitPreparedAttachment(record, session: session)
            } catch {
                return
            }
        }
    }

    private func submitPreparedAttachment(
        _ stagedRecord: MessageAttachmentOutboxRecord,
        session: LocalAccountSession
    ) async throws -> MessageItem {
        guard session.isCurrent,
              stagedRecord.ownerScopeId == session.ownerScopeId,
              stagedRecord.sessionId == session.sessionId else {
            throw CancellationError()
        }
        var record = try await attachmentOutbox.record(
            session: session,
            clientRequestId: stagedRecord.clientRequestId
        ) ?? stagedRecord
        let attachment: UploadedAttachment
        if let uploaded = record.uploadedAttachment {
            attachment = uploaded
        } else {
            let source = try await attachmentOutbox.sourceData(record, session: session)
            struct Response: Decodable { let attachment: UploadedAttachment }
            let response: Response = try await api.uploadMultipart(
                path: "/api/messages/attachments",
                fields: [
                    "conversationId": record.conversationId,
                    "clientRequestId": record.clientRequestId,
                    "attachmentSlot": "primary",
                    "contentSha256": record.contentSha256,
                ],
                fileField: "file",
                fileName: record.filename,
                mimeType: record.mimeType,
                data: source,
                as: Response.self
            )
            attachment = UploadedAttachment(
                kind: record.kind,
                url: response.attachment.url,
                fileName: response.attachment.fileName ?? record.filename,
                contentType: response.attachment.contentType ?? record.mimeType,
                size: response.attachment.size ?? source.count,
                width: response.attachment.width ?? record.width,
                height: response.attachment.height ?? record.height
            )
            try await attachmentOutbox.markUploaded(
                session: session,
                clientRequestId: record.clientRequestId,
                attachment: attachment
            )
            record = MessageAttachmentOutboxRecord(
                ownerScopeId: record.ownerScopeId,
                sessionId: record.sessionId,
                conversationId: record.conversationId,
                clientRequestId: record.clientRequestId,
                filename: record.filename,
                mimeType: record.mimeType,
                kind: record.kind,
                caption: record.caption,
                replyToId: record.replyToId,
                width: record.width,
                height: record.height,
                contentSha256: record.contentSha256,
                uploadedAttachment: attachment,
                createdAt: record.createdAt
            )
        }
        let payload = SendMessageRequest(
            kind: "ATTACHMENT",
            content: record.caption.isEmpty ? nil : record.caption,
            e2ee: nil,
            replyToId: record.replyToId,
            attachments: [attachment],
            ttlSeconds: nil,
            clientRequestId: record.clientRequestId
        )
        let response: CreatedMessageResponse = try await api.requestJSON(
            "/api/messages/conversations/\(record.conversationId)/messages",
            body: payload,
            idempotencyKey: record.clientRequestId
        )
        try await attachmentOutbox.acknowledge(
            session: session,
            clientRequestId: record.clientRequestId
        )
        return response.message
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func markRead(conversationId: String, lastMessageId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/conversations/\(conversationId)/read-state",
            method: .patch,
            body: ["lastMessageId": lastMessageId]
        )
    }

    func react(messageId: String, emoji: String, in conversation: MessageConversation) async throws {
        try LegacyE2EEWritePolicy.requireAllowed(
            e2eeEnabled: conversation.e2eeEnabled == true,
            feature: .reaction
        )
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/messages/\(messageId)/reactions",
            body: ["emoji": emoji]
        )
    }

    func removeReaction(messageId: String, emoji: String, in conversation: MessageConversation) async throws {
        try LegacyE2EEWritePolicy.requireAllowed(
            e2eeEnabled: conversation.e2eeEnabled == true,
            feature: .reaction
        )
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
            let encrypted = try await e2ee.encryptText(
                conversationId: conversation.id,
                text: text,
                contentType: .edit,
                operationId: messageId
            )
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
            let encrypted = try await e2ee.encryptText(
                conversationId: conversation.id,
                text: text,
                contentType: .threadReply,
                operationId: parentMessageId
            )
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
        try LegacyE2EEWritePolicy.requireAllowed(
            e2eeEnabled: conversation.e2eeEnabled == true,
            feature: .poll
        )
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
            let encrypted = try await e2ee.encryptText(
                conversationId: conversationId,
                text: json,
                contentType: .poll,
                operationId: nil
            )
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

    func votePoll(pollId: String, optionIds: [String], in conversation: MessageConversation) async throws -> MessagePoll {
        try LegacyE2EEWritePolicy.requireAllowed(
            e2eeEnabled: conversation.e2eeEnabled == true,
            feature: .poll
        )
        let response: PollVoteResponse = try await api.requestJSON(
            "/api/messages/polls/\(pollId)/vote",
            body: ["optionIds": optionIds]
        )
        return response.poll
    }

    func closePoll(pollId: String, in conversation: MessageConversation) async throws -> MessagePoll {
        try LegacyE2EEWritePolicy.requireAllowed(
            e2eeEnabled: conversation.e2eeEnabled == true,
            feature: .poll
        )
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

    // MARK: Messages enregistrés (favoris)

    func savedMessages() async throws -> [SavedMessageEntry] {
        try await api.request(
            APIEndpoint(path: "/api/messages/saved"),
            as: SavedMessagesResponse.self
        ).savedMessages
    }

    func saveMessage(messageId: String) async throws {
        struct SaveResponse: Decodable {}
        let _: SaveResponse = try await api.requestJSON(
            "/api/messages/saved",
            body: ["messageId": messageId]
        )
    }

    func unsaveMessage(messageId: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/messages/saved/\(messageId)",
            method: .delete,
            body: [String: String]()
        )
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

private struct LiveShareSessionsEnvelope: Decodable {
    let sessions: [LiveShareSession]
}

private struct LiveShareSessionEnvelope: Decodable {
    let session: LiveShareSession
}

private struct LiveShareCreateRequest: Encodable {
    let conversationId: String
    let offerShare: Bool
    let message: String?
    let mode: String?
    let targetUserId: String?
    let targetUserIds: [String]
    let mobileCountryCode: Int?
    let mobileNetworkCode: Int?
}

private struct LiveShareUpdateRequest: Encodable {
    let payload: LiveSharePayload
}

private struct LiveShareStatusEvent: Decodable {
    let status: String
}

private struct LiveShareUpdateEvent: Decodable {
    let status: String?
    let lastUpdateAt: Date?
    let lastPayload: String?
    let lastLocation: String?

    var payload: LiveSharePayload? {
        if let lastPayload,
           let data = lastPayload.data(using: .utf8),
           let payload = try? JSONDecoder.signalQuest.decode(LiveSharePayload.self, from: data) {
            return payload
        }
        if let lastLocation,
           let data = lastLocation.data(using: .utf8),
           let location = try? JSONDecoder.signalQuest.decode(LiveShareLocation.self, from: data) {
            return LiveSharePayload(radio: nil, location: location, at: nil)
        }
        return nil
    }
}

enum MessageTextOutboxError: Error, Equatable {
    case requestConflict
    case sessionChanged
}

struct MessageTextOutboxRecord: Codable, Equatable, Sendable {
    let ownerScopeId: String
    let sessionId: String
    let conversationId: String
    let clientRequestId: String
    let request: SendMessageRequest
    let createdAt: Date
}

/// File texte durable, exacte et liee a la session. Une reconnexion cree une nouvelle session et
/// abandonne les mutations privees precedentes au lieu de les attribuer au nouveau contexte.
actor MessageTextOutboxStore {
    typealias CurrentSession = @Sendable (LocalAccountSession) -> Bool
    typealias Publisher = @Sendable (
        LocalAccountSession,
        @Sendable () throws -> Void
    ) throws -> Void

    private let root: URL
    private let currentSession: CurrentSession
    private let publisher: Publisher
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest

    init(
        baseDirectory: URL? = nil,
        currentSession: @escaping CurrentSession = { $0.isCurrent },
        publisher: @escaping Publisher = { session, write in
            try LocalAccountScope.publish(for: session, write)
        }
    ) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        root = base.appendingPathComponent("SignalQuestMessageOutbox", isDirectory: true)
        self.currentSession = currentSession
        self.publisher = publisher
    }

    func stage(_ record: MessageTextOutboxRecord, session: LocalAccountSession) throws {
        guard currentSession(session),
              record.ownerScopeId == session.ownerScopeId,
              record.sessionId == session.sessionId else {
            throw MessageTextOutboxError.sessionChanged
        }
        var records = try activeRecords(session: session)
        if let existing = records.first(where: { $0.clientRequestId == record.clientRequestId }) {
            guard existing == record else { throw MessageTextOutboxError.requestConflict }
            return
        }
        records.append(record)
        try persist(records, session: session)
    }

    func record(
        session: LocalAccountSession,
        clientRequestId: String
    ) throws -> MessageTextOutboxRecord? {
        try activeRecords(session: session)
            .first { $0.clientRequestId == clientRequestId }
    }

    func pending(session: LocalAccountSession) throws -> [MessageTextOutboxRecord] {
        try activeRecords(session: session).sorted {
            if $0.createdAt == $1.createdAt { return $0.clientRequestId < $1.clientRequestId }
            return $0.createdAt < $1.createdAt
        }
    }

    func acknowledge(session: LocalAccountSession, clientRequestId: String) throws {
        var records = try activeRecords(session: session)
        let previousCount = records.count
        records.removeAll { $0.clientRequestId == clientRequestId }
        if records.count != previousCount { try persist(records, session: session) }
    }

    private func activeRecords(session: LocalAccountSession) throws -> [MessageTextOutboxRecord] {
        guard currentSession(session) else { throw MessageTextOutboxError.sessionChanged }
        let all = try load(ownerNamespace: session.ownerNamespace)
        let active = all.filter {
            $0.ownerScopeId == session.ownerScopeId && $0.sessionId == session.sessionId
        }
        if active.count != all.count { try persist(active, session: session) }
        return active
    }

    private func load(ownerNamespace: String) throws -> [MessageTextOutboxRecord] {
        let url = fileURL(ownerNamespace: ownerNamespace)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([MessageTextOutboxRecord].self, from: Data(contentsOf: url))
    }

    private func persist(
        _ records: [MessageTextOutboxRecord],
        session: LocalAccountSession
    ) throws {
        let directory = root
        let url = fileURL(ownerNamespace: session.ownerNamespace)
        let data = try encoder.encode(records)
        try publisher(session) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if records.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
    }

    private func fileURL(ownerNamespace: String) -> URL {
        root.appendingPathComponent("\(ownerNamespace).json", isDirectory: false)
    }
}

enum MessageAttachmentOutboxError: Error, Equatable {
    case requestConflict
    case sessionChanged
    case sourceMissing
    case sourceCorrupted
    case sourceTooLarge
}

struct MessageAttachmentOutboxRecord: Codable, Equatable, Sendable {
    let ownerScopeId: String
    let sessionId: String
    let conversationId: String
    let clientRequestId: String
    let filename: String
    let mimeType: String
    let kind: String
    let caption: String
    let replyToId: String?
    let width: Int?
    let height: Int?
    let contentSha256: String
    let uploadedAttachment: UploadedAttachment?
    let createdAt: Date
}

actor MessageAttachmentOutboxStore {
    private static let maximumSourceBytes = 10 * 1_024 * 1_024
    private let root: URL
    private let currentSession: MessageTextOutboxStore.CurrentSession
    private let publisher: MessageTextOutboxStore.Publisher
    private let encoder = JSONEncoder.signalQuest
    private let decoder = JSONDecoder.signalQuest

    init(
        baseDirectory: URL? = nil,
        currentSession: @escaping MessageTextOutboxStore.CurrentSession = { $0.isCurrent },
        publisher: @escaping MessageTextOutboxStore.Publisher = { session, write in
            try LocalAccountScope.publish(for: session, write)
        }
    ) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        root = base.appendingPathComponent("SignalQuestMessageAttachmentOutbox", isDirectory: true)
        self.currentSession = currentSession
        self.publisher = publisher
    }

    func stage(
        _ record: MessageAttachmentOutboxRecord,
        source: Data,
        session: LocalAccountSession
    ) throws {
        guard currentSession(session),
              record.ownerScopeId == session.ownerScopeId,
              record.sessionId == session.sessionId else {
            throw MessageAttachmentOutboxError.sessionChanged
        }
        guard !source.isEmpty else { throw MessageAttachmentOutboxError.sourceMissing }
        guard source.count <= Self.maximumSourceBytes else {
            throw MessageAttachmentOutboxError.sourceTooLarge
        }
        guard Self.sha256Hex(source) == record.contentSha256 else {
            throw MessageAttachmentOutboxError.sourceCorrupted
        }
        if let existing = try self.record(
            session: session,
            clientRequestId: record.clientRequestId
        ) {
            guard existing == record else { throw MessageAttachmentOutboxError.requestConflict }
            _ = try sourceData(existing, session: session)
            return
        }

        let directory = ownerDirectory(session.ownerNamespace)
        let metadataURL = self.metadataURL(record.clientRequestId, ownerNamespace: session.ownerNamespace)
        let sourceURL = self.sourceURL(record.clientRequestId, ownerNamespace: session.ownerNamespace)
        let metadata = try encoder.encode(record)
        try publisher(session) {
            try Self.prepareDirectory(directory)
            do {
                try source.write(to: sourceURL, options: [.atomic])
                try metadata.write(to: metadataURL, options: [.atomic])
                Self.protect(sourceURL)
                Self.protect(metadataURL)
            } catch {
                try? FileManager.default.removeItem(at: sourceURL)
                try? FileManager.default.removeItem(at: metadataURL)
                throw error
            }
        }
    }

    func pending(session: LocalAccountSession) throws -> [MessageAttachmentOutboxRecord] {
        guard currentSession(session) else { throw MessageAttachmentOutboxError.sessionChanged }
        let directory = ownerDirectory(session.ownerNamespace)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let metadataFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        var active: [MessageAttachmentOutboxRecord] = []
        for metadataURL in metadataFiles {
            let value = try decoder.decode(
                MessageAttachmentOutboxRecord.self,
                from: Data(contentsOf: metadataURL)
            )
            if value.ownerScopeId == session.ownerScopeId && value.sessionId == session.sessionId {
                active.append(value)
            } else {
                try remove(value, session: session)
            }
        }
        return active.sorted {
            if $0.createdAt == $1.createdAt { return $0.clientRequestId < $1.clientRequestId }
            return $0.createdAt < $1.createdAt
        }
    }

    func record(
        session: LocalAccountSession,
        clientRequestId: String
    ) throws -> MessageAttachmentOutboxRecord? {
        try pending(session: session).first { $0.clientRequestId == clientRequestId }
    }

    func sourceData(
        _ record: MessageAttachmentOutboxRecord,
        session: LocalAccountSession
    ) throws -> Data {
        guard currentSession(session),
              record.ownerScopeId == session.ownerScopeId,
              record.sessionId == session.sessionId else {
            throw MessageAttachmentOutboxError.sessionChanged
        }
        let url = sourceURL(record.clientRequestId, ownerNamespace: session.ownerNamespace)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MessageAttachmentOutboxError.sourceMissing
        }
        let data = try Data(contentsOf: url)
        guard Self.sha256Hex(data) == record.contentSha256 else {
            throw MessageAttachmentOutboxError.sourceCorrupted
        }
        return data
    }

    func markUploaded(
        session: LocalAccountSession,
        clientRequestId: String,
        attachment: UploadedAttachment
    ) throws {
        guard let current = try record(session: session, clientRequestId: clientRequestId) else {
            throw MessageAttachmentOutboxError.sourceMissing
        }
        let updated = MessageAttachmentOutboxRecord(
            ownerScopeId: current.ownerScopeId,
            sessionId: current.sessionId,
            conversationId: current.conversationId,
            clientRequestId: current.clientRequestId,
            filename: current.filename,
            mimeType: current.mimeType,
            kind: current.kind,
            caption: current.caption,
            replyToId: current.replyToId,
            width: current.width,
            height: current.height,
            contentSha256: current.contentSha256,
            uploadedAttachment: attachment,
            createdAt: current.createdAt
        )
        let url = metadataURL(clientRequestId, ownerNamespace: session.ownerNamespace)
        let data = try encoder.encode(updated)
        try publisher(session) {
            try data.write(to: url, options: [.atomic])
            Self.protect(url)
        }
    }

    func acknowledge(session: LocalAccountSession, clientRequestId: String) throws {
        guard currentSession(session) else { throw MessageAttachmentOutboxError.sessionChanged }
        if let value = try record(session: session, clientRequestId: clientRequestId) {
            try remove(value, session: session)
        }
    }

    private func remove(
        _ record: MessageAttachmentOutboxRecord,
        session: LocalAccountSession
    ) throws {
        let metadata = metadataURL(record.clientRequestId, ownerNamespace: session.ownerNamespace)
        let source = sourceURL(record.clientRequestId, ownerNamespace: session.ownerNamespace)
        try publisher(session) {
            if FileManager.default.fileExists(atPath: metadata.path) {
                try FileManager.default.removeItem(at: metadata)
            }
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.removeItem(at: source)
            }
        }
    }

    private func ownerDirectory(_ namespace: String) -> URL {
        root.appendingPathComponent(namespace, isDirectory: true)
    }

    private func metadataURL(_ requestId: String, ownerNamespace: String) -> URL {
        ownerDirectory(ownerNamespace)
            .appendingPathComponent(Self.fileStem(requestId))
            .appendingPathExtension("json")
    }

    private func sourceURL(_ requestId: String, ownerNamespace: String) -> URL {
        ownerDirectory(ownerNamespace)
            .appendingPathComponent(Self.fileStem(requestId))
            .appendingPathExtension("blob")
    }

    private static func fileStem(_ requestId: String) -> String {
        sha256Hex(Data(requestId.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    private static func protect(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}
