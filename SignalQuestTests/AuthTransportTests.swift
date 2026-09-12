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
    func testSingleAttemptJSONRejects307WithoutReplayingTheBody() async throws {
        try await verifyRealHTTPSRedirectIsRejected(status: 307)
    }

    func testSingleAttemptJSONRejects308WithoutReplayingTheBody() async throws {
        try await verifyRealHTTPSRedirectIsRejected(status: 308)
    }

    func testSingleAttemptDataReturns307WithoutFollowingIt() async throws {
        try await verifyRealHTTPSRedirectIsRejected(status: 307, mode: .data)
    }

    func testSingleAttemptFileReturns308WithoutReplayingTheUpload() async throws {
        try await verifyRealHTTPSRedirectIsRejected(status: 308, mode: .file)
    }

    private enum SingleAttemptMode { case json, data, file }

    private func verifyRealHTTPSRedirectIsRejected(status: Int, mode: SingleAttemptMode = .json) async throws {
        let env = ProcessInfo.processInfo.environment
        guard (env["SQ_WK_CHALLENGE_QA"] ?? env["TEST_RUNNER_SQ_WK_CHALLENGE_QA"]) == "1" else {
            throw XCTSkip("Recette URLSession HTTPS locale non demandée")
        }
        let origin = try XCTUnwrap(URL(string: "https://127.0.0.1:4325"))
        let config = AppConfig(appBaseURL: origin, apiBaseURL: origin, debugLogsEnabled: false)
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let client = APIClient(config: config, credentials: credentials)
        let id = UUID().uuidString
        struct Body: Encodable { let token = "synthetic-one-time-token"; let password = "synthetic-password" }
        struct Reply: Decodable { let ok: Bool }
        let path = "/qa/redirect-start/\(status)/\(id)"
        if mode == .json {
            do {
                let _: Reply = try await client.requestJSONSingleAttempt(path, body: Body(), authenticated: false)
                XCTFail("A one-time mutation must expose the redirect instead of following it")
            } catch APIError.http(let actual, _, _, _, _) {
                XCTAssertEqual(actual, status)
            } catch { XCTFail("Expected the original HTTP redirect, got \(error)") }
        } else if mode == .data {
            let (_, response) = try await client.performSingleAttempt(APIEndpoint(path: path, method: .post,
                body: try JSONEncoder().encode(Body()), authenticated: false))
            XCTAssertEqual(response.statusCode, status)
        } else {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-redirect-\(id).json")
            try JSONEncoder().encode(Body()).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let (_, response) = try await client.uploadFileSingleAttempt(
                APIEndpoint(path: path, method: .post, authenticated: false), fromFile: file)
            XCTAssertEqual(response.statusCode, status)
        }
        struct Stats: Decodable {
            let starts: Int
            let targets: Int
            let startCookie: Bool
            let targetCookie: Bool
            let startBody: Bool
            let targetBody: Bool
        }
        let stats: Stats = try await client.request(APIEndpoint(path: "/qa/redirect-stats/\(id)", authenticated: false), as: Stats.self)
        XCTAssertEqual(stats.starts, 1)
        XCTAssertEqual(stats.targets, 0, "URLSession must never reach the other origin")
        XCTAssertTrue(stats.startBody)
        XCTAssertFalse(stats.targetBody)
        XCTAssertFalse(stats.startCookie)
        XCTAssertFalse(stats.targetCookie)
        XCTAssertNil(credentials.accessToken(), "A redirect target cannot install its credentials")
    }

    func testSignupReturnsTheGenerationCapturedWithItsCookieAndAllowsTokenRotation() async throws {
        let (client, _) = makeClient(token: nil)
        let before = client.credentials.snapshot().sessionID
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "auth_token=synthetic-signup; Path=/"])!,
             Data("{\"requires2FA\":false}".utf8))
        }
        let service = AuthService(api: client, sessionStore: InMemoryTokenStore())
        let received = try await service.signup(email: "synthetic@example.invalid", password: "synthetic-password",
                                                name: "Test", acceptedTerms: true)
        XCTAssertNotEqual(received.credentialSessionID, before)
        XCTAssertEqual(received.credentialSessionID, service.credentialSessionID())
        let accepted = client.credentials.snapshot()
        let rotated = try XCTUnwrap(HTTPURLResponse(url: client.config.apiBaseURL, statusCode: 200,
            httpVersion: nil, headerFields: ["Set-Cookie": "auth_token=synthetic-rotation; Path=/"]))
        try client.credentials.captureFromResponse(rotated, for: accepted)
        XCTAssertEqual(received.credentialSessionID, service.credentialSessionID(), "Refresh may rotate a token within this connection")
        XCTAssertEqual(client.credentials.accessToken(), "synthetic-rotation")
        client.credentials.clearAll()
        XCTAssertNotEqual(received.credentialSessionID, service.credentialSessionID(), "The receipt must not adopt a later generation")
    }

    func testSingleAttemptJSONRejectsCredentialsChangedDuringDecoding() async throws {
        let decoder = JSONDecoder.signalQuest
        let (client, _) = makeClient(token: nil, decoder: decoder)
        decoder.userInfo[CredentialsChangedDuringDecoding.key] = client.credentials
        do {
            let _: CredentialsChangedDuringDecoding = try await client.requestJSONSingleAttempt(
                "/synthetic", body: ["token": "synthetic-token"], authenticated: false)
            XCTFail("Decoded values cannot outlive the credential generation of their transport response")
        } catch APIError.cancelled {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private struct CredentialsChangedDuringDecoding: Decodable {
        static let key = CodingUserInfoKey(rawValue: "synthetic-credentials")!
        init(from decoder: Decoder) throws {
            let credentials = try XCTUnwrap(decoder.userInfo[Self.key] as? CredentialStore)
            credentials.clearAll()
        }
    }

    func testPublicAuthErrorsUseLocalizedCopyInsteadOfTheServerLanguage() {
        let raw = "server supplied unlocalized recovery message"
        for code in ["CAPTCHA_FAILED", "INVALID_RESET_LINK", "RESET_LINK_ALREADY_USED", "RESET_LINK_EXPIRED", "EMAIL_ALREADY_USED"] {
            let shown = APIError.userFacingMessage(status: code == "CAPTCHA_FAILED" ? 403 : 400, code: code, serverMessage: raw)
            XCTAssertNotEqual(shown, raw, code)
            XCTAssertFalse(shown.isEmpty, code)
            XCTAssertFalse(shown.contains(code), code)
        }
    }

    func testSignupSendsTheChallengeOnlyInJSONAndPreservesConsent() async throws {
        let (client, log) = makeClient(token: "synthetic-existing-session")
        MockURLProtocol.requestHandler = { request in
            log.append(request)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.bodyData(request)) as? [String: Any])
            XCTAssertEqual(payload["turnstileToken"] as? String, "synthetic-signup-challenge")
            XCTAssertEqual(payload["email"] as? String, "signup@example.invalid")
            XCTAssertEqual(payload["acceptedTerms"] as? Bool, true)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.url?.query)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, Data("{\"requires2FA\":false}".utf8))
        }
        let service = AuthService(api: client, sessionStore: InMemoryTokenStore())
        _ = try await service.signup(email: "signup@example.invalid", password: "synthetic-password", name: "Test",
                                     acceptedTerms: true, turnstileToken: "synthetic-signup-challenge")
        XCTAssertEqual(log.count, 1)
    }

    func testForgotPasswordSendsTheChallengeOnlyInItsRequestBody() async throws {
        let (client, log) = makeClient(token: "synthetic-existing-session")
        MockURLProtocol.requestHandler = { request in
            log.append(request)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.bodyData(request)) as? [String: Any])
            XCTAssertEqual(payload["turnstileToken"] as? String, "synthetic-reset-challenge")
            XCTAssertEqual(payload["email"] as? String, "reset@example.invalid")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.url?.query)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, Data("{\"ok\":true}".utf8))
        }
        let service = AuthService(api: client, sessionStore: InMemoryTokenStore())
        try await service.forgotPassword(email: "reset@example.invalid", turnstileToken: "synthetic-reset-challenge")
        XCTAssertEqual(log.count, 1)
    }

    private static func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if read == 0 { return result }
            result.append(contentsOf: buffer.prefix(read))
        }
    }

    func testSignupDoesNotReplayAfterAnUncertainServerFailure() async throws {
        let (client, log) = makeClient(token: nil)
        rejectEveryAttempt(log: log, status: 503)
        let service = AuthService(api: client, sessionStore: InMemoryTokenStore())
        do {
            _ = try await service.signup(email: "signup@example.invalid", password: "synthetic-password", name: "Test", acceptedTerms: true)
            XCTFail("A failed signup must not be reported as success")
        } catch { XCTAssertTrue(error is APIError) }
        XCTAssertEqual(log.count, 1, "A challenge token or account creation must not be replayed automatically")
    }

    func testForgotPasswordDoesNotSendAnotherRequestAfterBackpressure() async throws {
        let (client, log) = makeClient(token: nil)
        rejectEveryAttempt(log: log, status: 429)
        let service = AuthService(api: client, sessionStore: InMemoryTokenStore())
        do {
            try await service.forgotPassword(email: "reset@example.invalid")
            XCTFail("Backpressure is not an acknowledged email request")
        } catch { XCTAssertTrue(error is APIError) }
        XCTAssertEqual(log.count, 1, "The next attempt requires a new explicit verification")
    }

    func testResetPasswordDoesNotReplayTheOneTimeResetToken() async throws {
        let (client, log) = makeClient(token: nil)
        rejectEveryAttempt(log: log, status: 503)
        let service = AuthService(api: client, sessionStore: InMemoryTokenStore())
        do {
            try await service.resetPassword(token: "synthetic-reset-token", newPassword: "synthetic-new-password")
            XCTFail("A server failure is not an acknowledged reset")
        } catch { XCTAssertTrue(error is APIError) }
        XCTAssertEqual(log.count, 1)
    }

    func testForgotPasswordRequiresAnExplicitSuccessAcknowledgement() async throws {
        let (client, _) = makeClient(token: nil) // Real transport returns {}.
        let service = AuthService(api: client, sessionStore: InMemoryTokenStore())
        do {
            try await service.forgotPassword(email: "reset@example.invalid")
            XCTFail("An empty response must not claim that the email request succeeded")
        } catch { XCTAssertTrue(error is APIError) }
    }

    func testResetPasswordRequiresAnExplicitSuccessAcknowledgement() async throws {
        let (client, _) = makeClient(token: nil)
        let service = AuthService(api: client, sessionStore: InMemoryTokenStore())
        do {
            try await service.resetPassword(token: "synthetic-reset-token", newPassword: "synthetic-new-password")
            XCTFail("An empty response must not claim that the password changed")
        } catch { XCTAssertTrue(error is APIError) }
    }

    private func rejectEveryAttempt(log: RequestLog, status: Int) {
        MockURLProtocol.requestHandler = { request in
            log.append(request)
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "Retry-After": "0"])!,
                Data("{\"error\":\"synthetic-unavailable\"}".utf8))
        }
    }

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


    private func makeClient(token: String?, decoder: JSONDecoder = .signalQuest) -> (APIClient, RequestLog) {
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
            session: URLSession(configuration: configuration),
            decoder: decoder
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
