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

    /// AF-MSG-06 : un échec d'action est passager ; il ne remplace pas la liste
    /// par « Messagerie indisponible », et l'épingle revient à son état.
    @MainActor
    func testAFailedPinIsAnActionErrorAndKeepsTheList() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (response, Data(#"{"error":"boom"}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("pin-failure-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let model = MessagesViewModel(service: MessagesService(api: api))
        let original = conversation("conv-1", lastMessageAt: Date(timeIntervalSince1970: 1_790_000_000))
        model.conversations = [original]

        await model.setPinned(true, original)

        XCTAssertNil(model.errorMessage, "La liste reste affichée")
        XCTAssertNotNil(model.actionError)
        XCTAssertNil(model.conversations.first?.pinnedAt, "L'épingle revient à son état")
    }

    /// MSG-02 : une page suivante qui échoue le dit (« Réessayer »), sans effacer la liste ;
    /// le réessai qui aboutit retire l'échec.
    @MainActor
    func testAFailedNextPageIsFlaggedAndRetryClearsIt() async throws {
        var failSecondPage = true
        MockURLProtocol.requestHandler = { request in
            let isSecondPage = request.url?.query?.contains("cursor=next") == true
            let ok = !isSecondPage || !failSecondPage
            let json = isSecondPage
                ? #"{"conversations":[{"id":"b","isGroup":false,"participants":[]}],"hasMore":false}"#
                : #"{"conversations":[{"id":"a","isGroup":false,"participants":[]}],"hasMore":true,"nextCursor":"next"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 500, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (response, Data((ok ? json : #"{"error":"boom"}"#).utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("next-page-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let model = MessagesViewModel(service: MessagesService(api: api))

        await model.load()
        XCTAssertTrue(model.hasMoreConversations)
        XCTAssertFalse(model.loadMoreFailed)

        await model.loadMore()
        XCTAssertTrue(model.loadMoreFailed, "L'échec s'affiche au lieu d'un spinner sans fin")
        XCTAssertTrue(model.hasMoreConversations, "La suite reste à charger")
        XCTAssertEqual(model.conversations.map(\.id), ["a"])

        failSecondPage = false
        await model.loadMore()
        XCTAssertFalse(model.loadMoreFailed)
        XCTAssertFalse(model.hasMoreConversations)
        XCTAssertEqual(Set(model.conversations.map(\.id)), ["a", "b"])
    }

    func testDeliveredAndReceiptsUseTheServerRoutes() async throws {
        var calls: [(method: String?, path: String?, body: [String: Any])] = []
        MockURLProtocol.requestHandler = { request in
            let body = (try? JSONSerialization.jsonObject(with: Self.requestBody(request) ?? Data())) as? [String: Any] ?? [:]
            calls.append((request.httpMethod, request.url?.path, body))
            let json = request.url?.path.hasSuffix("/receipts") == true
                ? #"{"readReceipts":[],"deliveryReceipts":[{"userId":"u2","name":"Léa","lastDeliveredAt":"2026-10-18T10:00:00.000Z"}]}"#
                : #"{"ok":true,"deliveredAt":null}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (response, Data(json.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("delivered-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let service = MessagesService(api: api)

        try await service.markDelivered(conversationId: "conv-1", messageId: "m-9")
        let receipts = try await service.receipts(conversationId: "conv-1")

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].method, "POST")
        XCTAssertEqual(calls[0].path, "/api/messages/conversations/conv-1/delivered")
        XCTAssertEqual(calls[0].body["messageId"] as? String, "m-9")
        XCTAssertEqual(calls[1].method, "GET")
        XCTAssertEqual(calls[1].path, "/api/messages/conversations/conv-1/receipts")
        XCTAssertEqual(receipts.deliveryReceipts.map(\.userId), ["u2"])
        XCTAssertNotNil(receipts.deliveryReceipts.first?.lastDeliveredAt)
    }

    /// Un seul accusé par message, jamais d'id local, et un échec (route absente) reste silencieux.
    /// B08 : un accusé accepté n'est pas renvoyé ; un accusé refusé (réseau, serveur) n'est pas
    /// mémorisé, le passage suivant le rejoue. Un message local n'est jamais accusé.
    func testDeliveryAcknowledgerSendsEachAcceptedMessageOnceAndRetriesFailures() async throws {
        var bodies: [String] = []
        var status = 200
        MockURLProtocol.requestHandler = { request in
            let body = (try? JSONSerialization.jsonObject(with: Self.requestBody(request) ?? Data())) as? [String: Any] ?? [:]
            bodies.append("\(request.url?.path ?? "")|\(body["messageId"] as? String ?? "")")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (response, Data(status == 200 ? #"{"ok":true}"#.utf8 : #"{"error":"NOT_FOUND"}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("acknowledger-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let service = MessagesService(api: api)
        let acknowledger = DeliveryAcknowledger()

        status = 404
        await acknowledger.acknowledge(conversationId: "c1", messageId: "m1", using: service)
        status = 200
        await acknowledger.acknowledge(conversationId: "c1", messageId: "m1", using: service)
        await acknowledger.acknowledge(conversationId: "c1", messageId: "m1", using: service)
        await acknowledger.acknowledge(conversationId: "c1", messageId: "local-1", using: service)
        await acknowledger.acknowledge(conversationId: "c2", messageId: "m1", using: service)
        await acknowledger.acknowledge(conversationId: "c1", messageId: "m2", using: service)

        XCTAssertEqual(bodies, [
            "/api/messages/conversations/c1/delivered|m1",
            "/api/messages/conversations/c1/delivered|m1",
            "/api/messages/conversations/c2/delivered|m1",
            "/api/messages/conversations/c1/delivered|m2"
        ])
    }

    func testOnlyUnreadMessagesFromOthersAreAcknowledgedFromTheList() throws {
        let now = Date()
        let fromOther = conversation("a", lastMessageAt: now, senderId: "other")
        let alreadyRead = conversation("b", lastMessageAt: now, lastReadAt: now, senderId: "other")
        let mine = conversation("c", lastMessageAt: now, senderId: "me")
        let v2 = try JSONDecoder.signalQuest.decode(MessageConversation.self, from: Data(#"""
        {"id":"d","isGroup":false,"participants":[],"e2eeV2":{"lastMessage":{"envelopeId":"envelope_7","sequence":"4","senderUserId":"other","senderDeviceId":"device_1","serverTimeMs":"1791190800000"},"unreadCount":"1"}}
        """#.utf8))
        let list = [fromOther, alreadyRead, mine, v2]

        let acks = DeliveryAcknowledger.latestIncoming(in: list, currentUserId: "me")
        XCTAssertEqual(acks.map { "\($0.0)=\($0.1)" }, ["a=m-a", "d=envelope_7"])
        XCTAssertTrue(DeliveryAcknowledger.latestIncoming(in: list, currentUserId: nil).isEmpty)
    }

    // MARK: Messagerie, seconde passe (B01, B04, M05, M16)

    private func makeService(token: String) throws -> MessagesService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken(token)
        return MessagesService(api: APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration)))
    }

    private func json(_ request: URLRequest, _ body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
         Data(body.utf8))
    }

    private func queryValue(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// B01 : la liste suivait une seule page ; elle suit le curseur jusqu'à la dernière, sans doublon.
    func testConversationListFollowsTheCursorUntilTheLastPage() async throws {
        var cursors: [String?] = []
        MockURLProtocol.requestHandler = { [self] request in
            let cursor = queryValue(request, "cursor")
            cursors.append(cursor)
            return json(request, cursor == nil
                ? #"{"conversations":[{"id":"c1","isGroup":false,"participants":[]}],"hasMore":true,"nextCursor":"page-2"}"#
                : #"{"conversations":[{"id":"c2","isGroup":false,"participants":[]},{"id":"c1","isGroup":false,"participants":[]}],"hasMore":false}"#)
        }
        let all = try await makeService(token: "pages-access-token").conversations()

        XCTAssertEqual(all.map(\.id), ["c1", "c2"])
        XCTAssertEqual(cursors, [nil, "page-2"])
    }

    /// B04 : toutes les réponses d'un fil, page par page, au lieu de la première seulement.
    func testThreadRepliesAreReadPageByPage() async throws {
        func reply(_ id: String) -> String {
            #"{"id":"\#(id)","conversationId":"c1","senderId":"u1","kind":"TEXT","content":"réponse","createdAt":"2026-10-01T10:00:00.000Z"}"#
        }
        var cursors: [String?] = []
        MockURLProtocol.requestHandler = { [self] request in
            let cursor = queryValue(request, "cursor")
            cursors.append(cursor)
            return json(request, cursor == nil
                ? #"{"replies":[\#(reply("r1")),\#(reply("r2"))],"page":{"hasMore":true,"nextCursor":"after-r2"}}"#
                : #"{"replies":[\#(reply("r3"))],"page":{"hasMore":false}}"#)
        }
        let page = try await makeService(token: "thread-access-token").allThreadReplies(parentMessageId: "parent-1", pageSize: 2)

        XCTAssertEqual(page.replies.map(\.id), ["r1", "r2", "r3"])
        XCTAssertEqual(cursors, [nil, "after-r2"])
        XCTAssertEqual(page.hasMore, false)
    }

    /// M05 : le repère « N nouveaux messages » se pose sur le premier message reçu après la dernière lecture.
    func testUnreadDividerStartsAtTheFirstIncomingMessageAfterTheLastRead() {
        let read = Date(timeIntervalSince1970: 1_790_000_000)
        func message(_ id: String, from sender: String, after seconds: TimeInterval, deleted: Bool = false) -> MessageItem {
            MessageItem(
                id: id, conversationId: "c1", senderId: sender, kind: "TEXT", content: "x",
                e2eeVersion: nil, e2eeIvB64: nil, e2eeCiphertextB64: nil, e2eeAadB64: nil, metadata: nil,
                createdAt: read.addingTimeInterval(seconds), editedAt: nil,
                deletedAt: deleted ? read.addingTimeInterval(seconds) : nil, replyToId: nil, threadReplyCount: 0,
                sender: nil, attachments: [], reactions: []
            )
        }
        let thread = [
            message("old", from: "other", after: -60),
            message("mine", from: "me", after: 5),
            message("new-1", from: "other", after: 10),
            message("gone", from: "other", after: 15, deleted: true),
            message("local-pending", from: "other", after: 20),
            message("new-2", from: "other", after: 30)
        ]

        let divider = UnreadDivider.make(messages: thread, lastReadAt: read, currentUserId: "me")
        XCTAssertEqual(divider, UnreadDivider(messageId: "new-1", count: 2))
        XCTAssertNil(UnreadDivider.make(messages: thread, lastReadAt: nil, currentUserId: "me"), "Sans date de lecture, tout paraîtrait nouveau")
        XCTAssertNil(UnreadDivider.make(messages: Array(thread.prefix(2)), lastReadAt: read, currentUserId: "me"))
    }

    /// M16 : le badge de l'icône compte les conversations non lues du compte connecté, 0 sans session.
    func testIconBadgeCountsUnreadConversationsOfTheSignedInAccount() {
        XCTAssertEqual(AppServices.iconBadgeCount(unreadConversations: 3, isSignedIn: true), 3)
        XCTAssertEqual(AppServices.iconBadgeCount(unreadConversations: 3, isSignedIn: false), 0)
        XCTAssertEqual(AppServices.iconBadgeCount(unreadConversations: -2, isSignedIn: true), 0)
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
