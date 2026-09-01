import XCTest
import UIKit
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

    func testEveryFirstPartyRequestDeclaresProtocolAndCapabilities() async throws {
        let (client, log) = makeClient(token: nil)
        try await client.request(APIEndpoint(path: "/api/app/version-policy", authenticated: false))

        let headers = try XCTUnwrap(log.last?.allHTTPHeaderFields)
        XCTAssertEqual(
            headers[ClientProtocolContract.protocolVersionHeader],
            String(ClientProtocolContract.currentProtocolVersion)
        )
        XCTAssertEqual(
            headers[ClientProtocolContract.capabilitiesHeaderName],
            ClientProtocolContract.capabilitiesHeader
        )
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

// MARK: - Cache des médias privés A → logout → B

@MainActor
final class ImagePipelineAccountScopeTests: XCTestCase {
    private let url = URL(string: "https://cdn.signalquest.test/private/same-image")!

    func testPrivateTransportHasNoSharedURLCacheOrCookieJar() {
        let configuration = ImagePipeline.makePrivateSessionConfiguration()

        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testSamePrivateURLIsLoadedSeparatelyForAccountsAAndB() async throws {
        LocalAccountScope.deactivate()
        defer { LocalAccountScope.deactivate() }
        let red = Self.png(.red)
        let blue = Self.png(.blue)
        let loader = ScopedImageFixtureLoader(valuesByOwner: [
            "user:account-a": red,
            "user:account-b": blue,
        ])
        let pipeline = ImagePipeline { url, scope in
            try await loader.load(url: url, scope: scope)
        }

        let sessionA = activate("account-a")
        let imageA = try await pipeline.image(
            for: url,
            maxPixel: 32,
            scope: .privateAccount(sessionA)
        )

        LocalAccountScope.deactivate()
        let sessionB = activate("account-b")
        let imageB = try await pipeline.image(
            for: url,
            maxPixel: 32,
            scope: .privateAccount(sessionB)
        )

        let calls = await loader.callCount()
        XCTAssertEqual(calls, 2, "B doit réellement recharger la même URL")
        XCTAssertNotEqual(imageA.pngData(), imageB.pngData(), "B ne doit jamais recevoir les pixels de A")
    }

    func testLatePrivateResponseIsRejectedAfterAccountSwitch() async throws {
        LocalAccountScope.deactivate()
        defer { LocalAccountScope.deactivate() }
        let gate = SuspendedImageFixtureLoader()
        let pipeline = ImagePipeline { url, scope in
            try await gate.load(url: url, scope: scope)
        }
        let sessionA = activate("account-a")

        let pending = Task {
            try await pipeline.image(
                for: url,
                maxPixel: 32,
                scope: .privateAccount(sessionA)
            )
        }
        await gate.waitUntilStarted()
        LocalAccountScope.deactivate()
        _ = activate("account-b")
        await gate.succeed(with: Self.png(.red))

        do {
            _ = try await pending.value
            XCTFail("Une réponse de A arrivée sous B devait être rejetée")
        } catch ImagePipelineError.privateSessionChanged {
            // Attendu.
        } catch {
            XCTFail("Erreur inattendue : \(error)")
        }
        XCTAssertNil(
            pipeline.cachedImage(for: url, maxPixel: 32, scope: .privateAccount(sessionA)),
            "Une réponse tardive ne doit pas être publiée dans le cache"
        )
    }

    func testLogoutOfflineCannotReadPreviousPrivateMemoryEntry() async throws {
        LocalAccountScope.deactivate()
        defer { LocalAccountScope.deactivate() }
        let loader = ScopedImageFixtureLoader(valuesByOwner: ["user:account-a": Self.png(.red)])
        let pipeline = ImagePipeline { url, scope in
            try await loader.load(url: url, scope: scope)
        }
        let sessionA = activate("account-a")
        _ = try await pipeline.image(
            for: url,
            maxPixel: 32,
            scope: .privateAccount(sessionA)
        )
        await loader.setOffline(true)
        LocalAccountScope.deactivate()

        do {
            _ = try await pipeline.image(
                for: url,
                maxPixel: 32,
                scope: .privateAccount(sessionA)
            )
            XCTFail("Le cache mémoire privé ne doit pas rester lisible après logout")
        } catch ImagePipelineError.privateSessionChanged {
            // Attendu avant même une tentative réseau hors ligne.
        } catch {
            XCTFail("Erreur inattendue : \(error)")
        }
        let calls = await loader.callCount()
        XCTAssertEqual(calls, 1, "Le scope périmé ne doit pas atteindre le transport")
    }

    func testPublicImageKeepsSharedMemoryCache() async throws {
        let loader = ScopedImageFixtureLoader(publicValue: Self.png(.green))
        let pipeline = ImagePipeline { url, scope in
            try await loader.load(url: url, scope: scope)
        }

        let first = try await pipeline.image(for: url, maxPixel: 32, scope: .publicContent)
        let second = try await pipeline.image(for: url, maxPixel: 32, scope: .publicContent)

        let calls = await loader.callCount()
        XCTAssertEqual(calls, 1, "Le comportement de cache des images publiques doit rester inchangé")
        XCTAssertEqual(first.pngData(), second.pngData())
    }

    private func activate(_ userId: String) -> LocalAccountSession {
        LocalAccountScope.activate(userId: userId)
        return LocalAccountScope.sessionSnapshot()!
    }

    private static func png(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }
}

private actor ScopedImageFixtureLoader {
    enum FixtureError: Error { case offline, missingFixture }

    private let valuesByOwner: [String: Data]
    private let publicValue: Data?
    private var calls = 0
    private var offline = false

    init(valuesByOwner: [String: Data] = [:], publicValue: Data? = nil) {
        self.valuesByOwner = valuesByOwner
        self.publicValue = publicValue
    }

    func load(url: URL, scope: ImageCacheScope) throws -> Data {
        calls += 1
        guard !offline else { throw FixtureError.offline }
        switch scope {
        case .publicContent:
            guard let publicValue else { throw FixtureError.missingFixture }
            return publicValue
        case .privateAccount(let session):
            guard let value = valuesByOwner[session.ownerScopeId] else {
                throw FixtureError.missingFixture
            }
            return value
        }
    }

    func setOffline(_ value: Bool) { offline = value }
    func callCount() -> Int { calls }
}

private actor SuspendedImageFixtureLoader {
    private var continuation: CheckedContinuation<Data, Error>?

    func load(url: URL, scope: ImageCacheScope) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }

    func succeed(with data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}
