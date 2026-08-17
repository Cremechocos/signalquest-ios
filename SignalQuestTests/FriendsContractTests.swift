import XCTest
@testable import SignalQuest

/// Contrats des routes « amis » qui étaient soit absentes, soit silencieusement
/// tronquées côté iOS.
final class FriendsContractTests: XCTestCase {

    private var service: FriendsService!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        service = FriendsService(
            api: APIClient(
                config: .test,
                credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                session: URLSession(configuration: config)
            )
        )
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        service = nil
        super.tearDown()
    }

    private func respond(_ json: String, capture box: RequestBox? = nil) {
        MockURLProtocol.requestHandler = { request in
            box?.method = request.httpMethod ?? ""
            box?.path = request.url?.path ?? ""
            box?.body = request.sq_bodyData
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }

    /// Régression : `requests()` décodait `{ received, sent }` puis faisait
    /// `return r.received ?? []`. Les demandes ENVOYÉES étaient donc décodées
    /// puis jetées — invisibles et non annulables, alors que le backend les
    /// renvoie et expose la route de suppression.
    func testRequestsExposesBothDirections() async throws {
        respond("""
        {
          "received": [{ "id": "r1", "sender": { "id": "u1", "name": "Alice" } }],
          "sent": [{ "id": "s1", "receiver": { "id": "u2", "name": "Bob" } }]
        }
        """)
        let requests = try await service.requests()
        XCTAssertEqual(requests.received.map(\.id), ["r1"])
        XCTAssertEqual(requests.sent.map(\.id), ["s1"], "Les demandes envoyées ne doivent plus être jetées")
        XCTAssertFalse(requests.isEmpty)
    }

    /// Pour une demande envoyée, la personne à afficher est le DESTINATAIRE :
    /// `user` (= sender ?? receiver) montrerait l'utilisateur courant.
    func testSentRequestShowsRecipientNotSender() async throws {
        respond("""
        { "received": [], "sent": [{ "id": "s1", "sender": { "id": "me", "name": "Moi" },
                                     "receiver": { "id": "u2", "name": "Bob" } }] }
        """)
        let sent = try await service.requests().sent
        XCTAssertEqual(sent.first?.recipient?.name, "Bob")
        XCTAssertEqual(sent.first?.user?.name, "Moi", "`user` reste l'expéditeur, d'où l'accesseur dédié")
    }

    /// Une demande malformée ne doit pas vider la liste entière.
    func testMalformedRequestIsSkippedNotFatal() async throws {
        respond("""
        { "received": [{ "id": "r1", "sender": { "id": "u1", "name": "Alice" } }, 42], "sent": [] }
        """)
        let requests = try await service.requests()
        XCTAssertEqual(requests.received.map(\.id), ["r1"])
    }

    func testRequestsToleratesMissingKeys() async throws {
        respond("{}")
        let requests = try await service.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    /// Régression : `unblock` n'existait pas, un blocage était irréversible
    /// depuis l'app. Le backend lit `userId` dans le CORPS d'un DELETE.
    func testUnblockSendsDeleteWithUserIdInBody() async throws {
        let box = RequestBox()
        respond(#"{"success":true}"#, capture: box)
        try await service.unblock(userId: "u-9")
        XCTAssertEqual(box.method, "DELETE")
        XCTAssertEqual(box.path, "/api/users/blocks")
        let json = (try? JSONSerialization.jsonObject(with: box.body ?? Data())) as? [String: Any]
        XCTAssertEqual(json?["userId"] as? String, "u-9",
                       "userId doit être dans le corps, pas en paramètre d'URL")
    }

    /// Bloquer reste un POST sur la même route : les deux ne doivent pas être
    /// confondus.
    func testBlockRemainsAPost() async throws {
        let box = RequestBox()
        respond(#"{"success":true}"#, capture: box)
        try await service.block(userId: "u-9")
        XCTAssertEqual(box.method, "POST")
        XCTAssertEqual(box.path, "/api/users/blocks")
    }

    /// Annuler une demande envoyée : l'identifiant est porté par le chemin.
    func testCancelRequestUsesPathIdentifier() async throws {
        let box = RequestBox()
        respond(#"{"success":true}"#, capture: box)
        try await service.cancelRequest(requestId: "s-1")
        XCTAssertEqual(box.method, "DELETE")
        XCTAssertEqual(box.path, "/api/friends/requests/s-1")
    }

    /// Accepter/refuser restent des POST sur des sous-chemins distincts, pour
    /// qu'un futur remaniement ne les confonde pas avec l'annulation.
    func testAcceptAndDeclineKeepTheirSubpaths() async throws {
        let accept = RequestBox()
        respond(#"{"success":true}"#, capture: accept)
        try await service.accept(requestId: "r-1")
        XCTAssertEqual(accept.method, "POST")
        XCTAssertEqual(accept.path, "/api/friends/requests/r-1/accept")

        let decline = RequestBox()
        respond(#"{"success":true}"#, capture: decline)
        try await service.decline(requestId: "r-1")
        XCTAssertEqual(decline.path, "/api/friends/requests/r-1/decline")
    }
}

/// Contrats iOS des routes live-share déjà consommées par Android. Ces tests
/// verrouillent surtout les noms de champs sensibles (offerShare, PLMN, payload)
/// et les sous-chemins d'action.
final class LiveShareContractTests: XCTestCase {
    private var service: MessagesService!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        service = MessagesService(
            api: APIClient(
                config: .test,
                credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                session: URLSession(configuration: config)
            )
        )
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        service = nil
        super.tearDown()
    }

    func testCreateLiveShareSendsTargetsAndPLMN() async throws {
        let box = RequestBox()
        respond(
            """
            {
              "mode":"broadcast","createdCount":1,"skippedCount":0,
              "sessions":[{
                "id":"ls-1","conversationId":"c-1","requesterId":"u-2",
                "sharerId":"me","status":"active","message":"Route"
              }]
            }
            """,
            capture: box
        )

        let response = try await service.createLiveShare(
            conversationId: "c-1",
            offerShare: true,
            message: " Route ",
            mode: "broadcast",
            targetUserId: nil,
            targetUserIds: ["u-3", "u-2", "u-2"],
            mobileCountryCode: 208,
            mobileNetworkCode: 10
        )

        XCTAssertEqual(response.sessions.map(\.id), ["ls-1"])
        XCTAssertEqual(box.path, "/api/live-share/requests")
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: box.body ?? Data()) as? [String: Any]
        )
        XCTAssertEqual(body["offerShare"] as? Bool, true)
        XCTAssertEqual(body["mobileCountryCode"] as? Int, 208)
        XCTAssertEqual(body["mobileNetworkCode"] as? Int, 10)
        XCTAssertEqual(body["message"] as? String, "Route")
        XCTAssertEqual(body["targetUserIds"] as? [String], ["u-2", "u-3"])
    }

    func testLiveShareListUsesConversationQueryAndDecodesStoredPayload() async throws {
        let box = RequestBox()
        respond(
            #"{"sessions":[{"id":"ls-2","conversationId":"c/2","requesterId":"me","sharerId":"u-2","status":"active","lastPayload":"{\"location\":{\"latitude\":48.85,\"longitude\":2.35},\"radio\":{\"technology\":\"5G NSA\",\"mcc\":208,\"mnc\":10}}","lastUpdateAt":"2026-08-17T10:00:00.000Z"}]}"#,
            capture: box
        )

        let sessions = try await service.liveShareSessions(conversationId: "c/2")
        XCTAssertEqual(box.path, "/api/live-share/sessions")
        XCTAssertEqual(box.query, "conversationId=c/2")
        XCTAssertEqual(sessions.first?.decodedPayload?.location?.latitude, 48.85)
        XCTAssertEqual(sessions.first?.decodedPayload?.radio?.technology, "5G NSA")
    }

    func testLiveShareUpdateKeepsPayloadEnvelopeAndActionPath() async throws {
        let box = RequestBox()
        respond(
            #"{"session":{"id":"ls-3","conversationId":"c-1","requesterId":"u-2","sharerId":"me","status":"active"}}"#,
            capture: box
        )
        let payload = LiveSharePayload(
            radio: LiveShareRadio(connectionType: "4G", operatorName: "SFR", mcc: 208, mnc: 10),
            location: LiveShareLocation(
                latitude: 48.8,
                longitude: 2.3,
                accuracy: 6,
                altitude: nil,
                speed: nil,
                heading: nil
            ),
            at: "2026-08-17T10:00:00Z"
        )

        _ = try await service.updateLiveShare(sessionId: "ls-3", payload: payload)
        XCTAssertEqual(box.path, "/api/live-share/sessions/ls-3/update")
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: box.body ?? Data()) as? [String: Any]
        )
        let encodedPayload = try XCTUnwrap(body["payload"] as? [String: Any])
        XCTAssertEqual((encodedPayload["radio"] as? [String: Any])?["operator"] as? String, "SFR")
        XCTAssertEqual((encodedPayload["location"] as? [String: Any])?["accuracy"] as? Double, 6)
    }

    private func respond(_ json: String, capture box: RequestBox) {
        MockURLProtocol.requestHandler = { request in
            box.method = request.httpMethod ?? ""
            box.path = request.url?.path ?? ""
            box.query = request.url?.query
            box.body = request.sq_bodyData
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }
}

private final class RequestBox: @unchecked Sendable {
    var method = ""
    var path = ""
    var query: String?
    var body: Data?
}

private extension URLRequest {
    /// `URLProtocol` déplace le corps dans un flux : lire les deux sources.
    var sq_bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
