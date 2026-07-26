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

private final class RequestBox: @unchecked Sendable {
    var method = ""
    var path = ""
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
