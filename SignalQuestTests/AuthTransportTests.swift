import XCTest
@testable import SignalQuest

/// Contrat de transport de l'authentification.
///
/// Ces invariants étaient jusqu'ici tenus par accident : `URLSession.shared`
/// réémettait le cookie depuis `HTTPCookieStorage.shared`, y compris sur des
/// requêtes explicitement marquées non authentifiées. Le client possède
/// désormais sa session, sans cookie jar — l'identité ne circule plus que par
/// l'en-tête posé volontairement.
final class AuthTransportTests: XCTestCase {
    func testSSETransportDoesNotPersistCookiesOrCacheAcrossAccounts() {
        let configuration = SSEClient.makeSessionConfiguration()

        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testLocalAccountNamespacesAndOfflineOwnershipAreIsolated() {
        LocalAccountScope.deactivate()
        defer { LocalAccountScope.deactivate() }

        LocalAccountScope.activate(userId: "account-a")
        let accountANamespace = LocalAccountScope.storageNamespace
        LocalOfflineOwnership.claim(kind: "coverage", id: "session-1")
        XCTAssertTrue(LocalOfflineOwnership.belongsToCurrentScope(kind: "coverage", id: "session-1"))

        LocalAccountScope.activate(userId: "account-b")
        XCTAssertNotEqual(accountANamespace, LocalAccountScope.storageNamespace)
        XCTAssertFalse(LocalOfflineOwnership.belongsToCurrentScope(kind: "coverage", id: "session-1"))
    }


    private func makeClient(token: String?) -> (APIClient, RequestLog) {
        let store = InMemoryTokenStore()
        let credentials = CredentialStore(tokenStore: store)
        if let token { try? credentials.setAccessToken(token) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let log = RequestLog()
        MockURLProtocol.requestHandler = { request in
            log.append(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }
        let client = APIClient(
            config: .test,
            credentials: credentials,
            session: URLSession(configuration: configuration)
        )
        return (client, log)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// Le backend n'authentifie que par cookie ; le Bearer n'était lu que par
    /// `requireAdmin`. L'envoyer doublait la surface d'exposition du JWT.
    func testAuthenticatedRequestSendsCookieAndNoBearer() async throws {
        let (client, log) = makeClient(token: "jwt-123")
        try await client.request(APIEndpoint(path: "/api/user/profile"))

        let headers = try XCTUnwrap(log.last?.allHTTPHeaderFields)
        XCTAssertEqual(headers["Cookie"], "auth_token=jwt-123")
        XCTAssertNil(headers["Authorization"], "Le JWT utilisateur ne doit plus partir en Bearer")
    }

    /// Un endpoint non authentifié ne doit porter aucune identité — ce qui
    /// n'était pas vrai avec le cookie jar partagé.
    func testUnauthenticatedRequestCarriesNoIdentity() async throws {
        let (client, log) = makeClient(token: "jwt-123")
        try await client.request(APIEndpoint(path: "/api/android/markets", authenticated: false))

        let headers = try XCTUnwrap(log.last?.allHTTPHeaderFields)
        XCTAssertNil(headers["Cookie"])
        XCTAssertNil(headers["Authorization"])
    }

    /// Mode invité : `authenticated: true` sans token ne doit pas inventer
    /// d'en-tête vide, sinon les lectures publiques casseraient hors connexion.
    func testAuthenticatedRequestWithoutTokenDegradesGracefully() async throws {
        let (client, log) = makeClient(token: nil)
        try await client.request(APIEndpoint(path: "/api/photos"))

        let headers = try XCTUnwrap(log.last?.allHTTPHeaderFields)
        XCTAssertNil(headers["Cookie"], "Sans token, aucun en-tête d'identité")
    }

    /// La session du client ne doit pas puiser dans le cookie jar du processus.
    func testClientSessionHasNoCookieStorage() {
        let session = APIClient.makeSession()
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertTrue(
            session.configuration.waitsForConnectivity,
            "Une coupure brève ne doit pas se solder par un échec immédiat"
        )
    }

    /// Le cache HTTP reste actif : le backend renvoie un Cache-Control utile sur
    /// les lectures publiques, le neutraliser dégraderait carte et galerie.
    func testClientSessionKeepsProtocolCachePolicy() {
        XCTAssertEqual(APIClient.makeSession().configuration.requestCachePolicy, .useProtocolCachePolicy)
    }

    /// Les trois lectures photo portent bien l'identité : c'est d'elles que le
    /// backend dérive `likedByCurrentUser`. Sans cela, le cœur d'une photo aimée
    /// repassait à vide à chaque rechargement.
    func testPhotoReadsCarryTheSessionCookie() async throws {
        let (client, log) = makeClient(token: "jwt-abc")
        let service = PhotoService(api: client)

        _ = try? await service.listPhotos()
        _ = try? await service.photo(id: "p1")
        _ = try? await service.comments(photoId: "p1")

        XCTAssertEqual(log.count, 3)
        for request in log.all {
            XCTAssertEqual(
                request.allHTTPHeaderFields?["Cookie"], "auth_token=jwt-abc",
                "\(request.url?.path ?? "?") doit porter le cookie"
            )
        }
    }

    func testPhotoOperatorUpdateUsesAnAuthenticatedPatch() async throws {
        let (client, log) = makeClient(token: "jwt-abc")
        let service = PhotoService(api: client)

        try await service.updatePhotoOperator(photoId: "photo-1", operatorName: "VODAFONE")

        let request = try XCTUnwrap(log.last)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/photos/photo-1")
        XCTAssertEqual(request.allHTTPHeaderFields?["Cookie"], "auth_token=jwt-abc")
        XCTAssertEqual(request.allHTTPHeaderFields?["Content-Type"], "application/json")
    }

    /// URLSession peut remettre le corps dans un flux avant l'interception par
    /// `URLProtocol`; on vérifie donc son encodage à la frontière qui le crée.
    func testPhotoOperatorPatchPayloadIsEncodedInURLRequest() throws {
        let (client, _) = makeClient(token: "jwt-abc")
        let body = try JSONEncoder().encode(["operator": "VODAFONE"])
        let request = try client.makeURLRequest(
            APIEndpoint(
                path: "/api/photos/photo-1",
                method: .patch,
                headers: ["Content-Type": "application/json"],
                body: body
            )
        )

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(payload["operator"], "VODAFONE")
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }
    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    var last: URLRequest? { all.last }
    var count: Int { all.count }
}
