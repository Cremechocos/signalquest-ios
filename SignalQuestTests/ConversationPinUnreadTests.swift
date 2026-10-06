import XCTest
@testable import SignalQuest

/// Plan 3, vague 2 : épingler une conversation et la marquer non lue, avec les
/// routes déjà servies par le serveur.
final class ConversationPinUnreadTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testPinnedConversationsComeFirstThenTheOthersByDate() {
        let now = Date()
        let list = [
            conversation("ancienne", lastMessageAt: now.addingTimeInterval(-3_600)),
            conversation("épinglée-avant", lastMessageAt: now.addingTimeInterval(-86_400), pinnedAt: now.addingTimeInterval(-600)),
            conversation("récente", lastMessageAt: now),
            conversation("épinglée-dernière", lastMessageAt: now.addingTimeInterval(-7_200), pinnedAt: now),
            conversation("sans-message", lastMessageAt: nil, updatedAt: now.addingTimeInterval(-60))
        ]

        XCTAssertEqual(
            list.inDisplayOrder().map(\.id),
            ["épinglée-dernière", "épinglée-avant", "récente", "sans-message", "ancienne"]
        )
    }

    func testEqualDatesKeepTheServerOrder() {
        let date = Date()
        let list = ["a", "b", "c"].map { conversation($0, lastMessageAt: date) }
        XCTAssertEqual(list.inDisplayOrder().map(\.id), ["a", "b", "c"])
    }

    func testUnpinnedConversationFindsItsPlaceByDate() {
        let now = Date()
        let pinned = conversation("x", lastMessageAt: now.addingTimeInterval(-7_200), pinnedAt: now)
        let list = [pinned, conversation("y", lastMessageAt: now), conversation("z", lastMessageAt: now.addingTimeInterval(-86_400))]
        let unpinned = list.map { $0.id == "x" ? $0.with(pinnedAt: nil) : $0 }
        XCTAssertEqual(unpinned.inDisplayOrder().map(\.id), ["y", "x", "z"])
    }

    func testMarkingUnreadIsOfferedOnlyOnAReadMessageFromSomeoneElse() {
        let now = Date()
        let read = conversation("c", lastMessageAt: now, lastReadAt: now, senderId: "other")
        XCTAssertTrue(read.canMarkUnread(currentUserId: "me"))
        XCTAssertFalse(read.isUnread(currentUserId: "me"))

        // Le serveur ramène la lecture au 1er janvier 1970 : la pastille revient.
        let unread = read.with(lastReadAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(unread.isUnread(currentUserId: "me"))
        XCTAssertFalse(unread.canMarkUnread(currentUserId: "me"), "Déjà non lue : c'est « Lu » qui se propose")

        let mine = conversation("c", lastMessageAt: now, lastReadAt: now, senderId: "me")
        XCTAssertFalse(mine.canMarkUnread(currentUserId: "me"), "Son propre message ne compte jamais comme non lu")
        XCTAssertFalse(conversation("c", lastMessageAt: nil).canMarkUnread(currentUserId: "me"))
    }

    /// Lot serveur A7 : `e2eeV2` lu de façon tolérante ; le non-lu d'une
    /// conversation v2 vient de son dernier message v2 ; les copies le gardent.
    func testV2ListStateDrivesUnreadAndSurvivesCopies() throws {
        func decode(_ e2eeV2: String) throws -> MessageConversation {
            let json = #"{"id":"conversation_v2","isGroup":false,"participants":[],"lastReadAt":"2026-10-05T08:00:00.000Z","directPeerUserId":"peer","e2eeV2":"# + e2eeV2 + "}"
            return try JSONDecoder.signalQuest.decode(MessageConversation.self, from: Data(json.utf8))
        }
        // 1790000000000 ms = 2026-09-21, avant la lecture ; 1791190800000 = 2026-10-05 09:00 UTC, après.
        let unread = try decode(#"{"lastMessage":{"envelopeId":"envelope_1","sequence":"4","senderUserId":"other","senderDeviceId":"device_1","serverTimeMs":"1791190800000"},"unreadCount":"2"}"#)
        XCTAssertEqual(unread.e2eeV2?.unreadCount, 2)
        XCTAssertTrue(unread.isUnread(currentUserId: "me"))
        XCTAssertFalse(unread.isUnread(currentUserId: "other"), "Son propre message v2 ne compte pas")
        XCTAssertFalse(unread.with(lastReadAt: Date(timeIntervalSince1970: 1_791_190_900)).isUnread(currentUserId: "me"))
        let read = try decode(#"{"lastMessage":{"envelopeId":"envelope_1","sequence":"4","senderUserId":"other","senderDeviceId":"device_1","serverTimeMs":"1790000000000"},"unreadCount":"0"}"#)
        XCTAssertFalse(read.isUnread(currentUserId: "me"))

        let pinned = unread.with(pinnedAt: Date())
        XCTAssertEqual(pinned.e2eeV2, unread.e2eeV2)
        XCTAssertEqual(pinned.directPeerUserId, "peer")

        // Formes inattendues : la liste se lit quand même, sans état v2 utile.
        XCTAssertNil(try decode("null").e2eeV2)
        XCTAssertNil(try decode(#""surprise""#).e2eeV2?.lastMessage)
        XCTAssertEqual(try decode(#"{"lastMessage":null,"unreadCount":7}"#).e2eeV2?.unreadCount, 0)
    }

    /// P2-46 : `pinLimit` est lu de façon tolérante, en nombre ou en chaîne, et
    /// son absence ou une forme inattendue ne fait pas échouer la liste.
    func testPinLimitIsReadLeniently() throws {
        func decode(_ extra: String) throws -> ConversationsResponse {
            try JSONDecoder.signalQuest.decode(ConversationsResponse.self, from: Data(#"{"conversations":[]\#(extra)}"#.utf8))
        }
        XCTAssertEqual(try decode(#","pinLimit":5"#).pinLimit, 5)
        XCTAssertEqual(try decode(#","pinLimit":"5""#).pinLimit, 5)
        XCTAssertNil(try decode("").pinLimit)
        XCTAssertNil(try decode(#","pinLimit":{"x":1}"#).pinLimit)
    }

    func testCopiesKeepEverythingElse() {
        let original = conversation("c", lastMessageAt: Date(), lastReadAt: Date(), senderId: "other")
        let pinned = original.with(pinnedAt: Date())
        XCTAssertEqual(pinned.id, original.id)
        XCTAssertEqual(pinned.lastReadAt, original.lastReadAt)
        XCTAssertEqual(pinned.lastMessage, original.lastMessage)
        XCTAssertEqual(pinned.participants, original.participants)
        XCTAssertEqual(pinned.with(pinnedAt: nil), original)
    }

    /// Sourdine (#354) : clés additives lues de façon tolérante, gardées par
    /// les copies d'épinglage et de lecture.
    func testMuteIsReadLenientlyAndSurvivesTheOtherCopies() throws {
        func decode(_ extra: String) throws -> MessageConversation {
            try JSONDecoder.signalQuest.decode(MessageConversation.self, from: Data(#"{"id":"c","isGroup":false\#(extra)}"#.utf8))
        }
        let muted = try decode(#","muted":true,"mentionsMuted":true"#)
        XCTAssertTrue(muted.muted)
        XCTAssertTrue(muted.mentionsMuted)
        XCTAssertFalse(try decode("").muted)
        XCTAssertFalse(try decode(#","muted":"true""#).muted)
        XCTAssertFalse(try decode(#","muted":null"#).muted)

        let pinned = muted.with(pinnedAt: Date()).with(lastReadAt: nil)
        XCTAssertTrue(pinned.muted && pinned.mentionsMuted, "Épingler ou lire ne lève pas la sourdine")
        let unmuted = muted.with(muted: false, mentionsMuted: true)
        XCTAssertFalse(unmuted.muted)
        XCTAssertFalse(unmuted.mentionsMuted, "Les mentions ne sont coupées que sous sourdine")
    }

    func testMuteUsesTheServerRoute() async throws {
        var bodies: [[String: Any]] = []
        var paths: [String?] = []
        MockURLProtocol.requestHandler = { request in
            let body = (try? JSONSerialization.jsonObject(with: Self.requestBody(request) ?? Data())) as? [String: Any] ?? [:]
            bodies.append(body)
            paths.append(request.url?.path)
            XCTAssertEqual(request.httpMethod, "PATCH")
            let json = #"{"success":true,"muted":true,"mentionsMuted":false}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (response, Data(json.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("mute-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let service = MessagesService(api: api)

        let saved = try await service.setConversationMuted(true, mentionsMuted: nil, conversationId: "conv-1")
        _ = try await service.setConversationMuted(true, mentionsMuted: true, conversationId: "conv-1")

        XCTAssertTrue(saved.muted)
        XCTAssertFalse(saved.mentionsMuted)
        XCTAssertEqual(paths, ["/api/messages/conversations/conv-1/mute", "/api/messages/conversations/conv-1/mute"])
        XCTAssertEqual(bodies[0]["muted"] as? Bool, true)
        XCTAssertNil(bodies[0]["mentionsMuted"], "Absent : le serveur garde sa valeur")
        XCTAssertEqual(bodies[1]["mentionsMuted"] as? Bool, true)
    }

    func testPinAndUnreadUseTheServerRoutes() async throws {
        var calls: [(method: String?, path: String?, body: [String: Any])] = []
        MockURLProtocol.requestHandler = { request in
            let body = (try? JSONSerialization.jsonObject(with: Self.requestBody(request) ?? Data())) as? [String: Any] ?? [:]
            calls.append((request.httpMethod, request.url?.path, body))
            let json = request.url?.path.hasSuffix("/pin") == true
                ? #"{"success":true,"pinned":true,"pinnedAt":"2026-09-30T16:12:03.512Z"}"#
                : #"{"success":true,"state":"unread","lastReadAt":"1970-01-01T00:00:00.000Z","changed":true}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("pin-unread-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let service = MessagesService(api: api)

        let pinnedAt = try await service.setConversationPinned(true, conversationId: "conv-1")
        try await service.markUnread(conversationId: "conv-1")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try XCTUnwrap(formatter.date(from: "2026-09-30T16:12:03.512Z"))
        XCTAssertEqual(try XCTUnwrap(pinnedAt).timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].method, "PATCH")
        XCTAssertEqual(calls[0].path, "/api/messages/conversations/conv-1/pin")
        XCTAssertEqual(calls[0].body["pinned"] as? Bool, true)
        XCTAssertEqual(calls[1].method, "PATCH")
        XCTAssertEqual(calls[1].path, "/api/messages/conversations/conv-1/read-state")
        XCTAssertEqual(calls[1].body["state"] as? String, "unread")
        XCTAssertNil(calls[1].body["lastMessageId"], "Sans état explicite, le serveur comprendrait « lu »")
    }

    private func conversation(
        _ id: String,
        lastMessageAt: Date?,
        updatedAt: Date? = nil,
        lastReadAt: Date? = nil,
        pinnedAt: Date? = nil,
        senderId: String = "other"
    ) -> MessageConversation {
        let message = lastMessageAt.map { date in
            MessageItem(
                id: "m-\(id)", conversationId: id, senderId: senderId, kind: "TEXT", content: "Salut",
                e2eeVersion: nil, e2eeIvB64: nil, e2eeCiphertextB64: nil, e2eeAadB64: nil, metadata: nil,
                createdAt: date, editedAt: nil, deletedAt: nil, replyToId: nil, threadReplyCount: 0,
                sender: nil, attachments: [], reactions: []
            )
        }
        return MessageConversation(
            id: id, title: id, isGroup: false, e2eeEnabled: false, groupPhotoUrl: nil,
            createdAt: nil, updatedAt: updatedAt, lastMessageAt: lastMessageAt,
            lastReadAt: lastReadAt, pinnedAt: pinnedAt, participants: [], lastMessage: message
        )
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
