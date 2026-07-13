import XCTest
@testable import SignalQuest

final class APIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testDecodesSuccessAndStoresAuthCookie() async throws {
        let session = Self.mockSession()
        let cookieStore = AuthCookieStore(tokenStore: InMemoryTokenStore())
        let client = APIClient(config: .test, cookieStore: cookieStore, session: session)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), nil)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Set-Cookie": "auth_token=abc123; Path=/; HttpOnly"]
            )!
            return (response, Data(#"{"success":true,"requestId":"req-ok"}"#.utf8))
        }

        let response = try await client.request(APIEndpoint(path: "/api/auth/refresh", method: .post), as: SuccessResponse.self)
        XCTAssertEqual(response.success, true)
        XCTAssertEqual(cookieStore.cookieHeader(), "auth_token=abc123")
    }

    func testDecodesBackendErrorRequestIdAndRetryAfter() async {
        let client = APIClient(config: .test, cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()), session: Self.mockSession())

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "42", "X-Request-Id": "header-id"]
            )!
            return (response, Data(#"{"error":"Too many requests","code":"RATE_LIMIT","requestId":"body-id"}"#.utf8))
        }

        do {
            let _: SuccessResponse = try await client.request(APIEndpoint(path: "/api/test"), as: SuccessResponse.self)
            XCTFail("Expected APIError")
        } catch let error as APIError {
            if case .http(let status, let code, let message, let requestId, let retryAfter) = error {
                XCTAssertEqual(status, 429)
                XCTAssertEqual(code, "RATE_LIMIT")
                XCTAssertEqual(message, "Too many requests")
                XCTAssertEqual(requestId, "body-id")
                XCTAssertEqual(retryAfter, 42)
            } else {
                XCTFail("Unexpected error \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    /// Un message serveur brut (trace ORM/SQL) sur un 5xx ne doit JAMAIS être affiché :
    /// on retombe sur le repli neutre. Régression du leak « Invalid `prisma.$queryRaw()` ».
    func testServerErrorMessageIsNotLeakedToUser() {
        // 5xx : la prose brute du serveur est masquée par le repli neutre.
        XCTAssertEqual(
            APIError.userFacingMessage(status: 500, code: nil, serverMessage: "Invalid `prisma.$queryRaw()` invocation: ..."),
            APIError.statusFallback(500)
        )
        XCTAssertEqual(
            APIError.http(status: 500, code: nil, message: "Invalid `prisma.$queryRaw()` invocation: ...", requestId: "r1", retryAfter: nil).errorDescription,
            "Service momentanément indisponible. Réessaie plus tard."
        )
        // Un code connu reste prioritaire, même en 5xx.
        XCTAssertEqual(
            APIError.userFacingMessage(status: 503, code: "RATE_LIMITED", serverMessage: "peu importe"),
            "Trop de requêtes. Patiente un instant avant de réessayer."
        )
        // Un 4xx avec message FR lisible passe toujours (comportement inchangé).
        XCTAssertEqual(
            APIError.userFacingMessage(status: 400, code: nil, serverMessage: "Le nom est déjà pris."),
            "Le nom est déjà pris."
        )
    }

    // MARK: - Sprint 1 : idempotence & throttling (429/503)

    /// Un POST porte une clé d'idempotence et REJOUE la même clé après un
    /// refresh 401, pour qu'un retry transparent ne crée pas de doublon.
    func testPostReusesIdempotencyKeyAcrossRefreshRetry() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("stale")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())

        var createKeys: [String] = []
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.contains("/api/auth/refresh") {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Set-Cookie": "auth_token=fresh; Path=/; HttpOnly"]
                )!
                return (response, Data(#"{"success":true}"#.utf8))
            }
            createKeys.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "<none>")
            if createKeys.count == 1 {
                let r = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (r, Data(#"{"error":"unauthorized"}"#.utf8))
            }
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, Data(#"{"success":true}"#.utf8))
        }

        let _: SuccessResponse = try await client.requestJSON("/api/social/v2/posts", body: ["text": "hi"])
        XCTAssertEqual(createKeys.count, 2, "Le POST doit être rejoué une fois après refresh")
        XCTAssertNotEqual(createKeys.first, "<none>", "Un POST doit porter une clé d'idempotence")
        XCTAssertEqual(createKeys[0], createKeys[1], "La même clé doit être renvoyée sur le rejeu post-refresh")
    }

    /// Un GET ne doit pas porter de clé d'idempotence.
    func testGetCarriesNoIdempotencyKey() async throws {
        let client = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()), session: Self.mockSession())
        var hadKey = true
        MockURLProtocol.requestHandler = { request in
            hadKey = request.value(forHTTPHeaderField: "Idempotency-Key") != nil
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, Data(#"{"success":true}"#.utf8))
        }
        let _: SuccessResponse = try await client.request(APIEndpoint(path: "/api/feed"), as: SuccessResponse.self)
        XCTAssertFalse(hadKey)
    }

    /// Un 429 sans Retry-After déclenche un seul rejeu après un court backoff,
    /// puis réussit.
    func testThrottleRetriesOnceThenSucceeds() async throws {
        let client = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()), session: Self.mockSession())
        var hits = 0
        MockURLProtocol.requestHandler = { request in
            hits += 1
            let status = hits == 1 ? 429 : 200
            let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (r, Data(#"{"success":true}"#.utf8))
        }
        let resp: SuccessResponse = try await client.request(APIEndpoint(path: "/api/feed"), as: SuccessResponse.self)
        XCTAssertEqual(resp.success, true)
        XCTAssertEqual(hits, 2)
    }

    /// Un Retry-After long ne doit PAS bloquer l'appel : on remonte l'erreur sans rejeu.
    func testThrottleDoesNotRetryOnLongRetryAfter() async {
        let client = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()), session: Self.mockSession())
        var hits = 0
        MockURLProtocol.requestHandler = { request in
            hits += 1
            let r = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "42"])!
            return (r, Data(#"{"error":"slow down"}"#.utf8))
        }
        do {
            let _: SuccessResponse = try await client.request(APIEndpoint(path: "/api/feed"), as: SuccessResponse.self)
            XCTFail("Expected throttling error")
        } catch {
            XCTAssertEqual(hits, 1, "Un Retry-After long doit remonter immédiatement, sans rejeu automatique")
        }
    }

    func testThrottleDelayHonorsShortRetryAfterAndCapsLong() {
        XCTAssertEqual(APIClient.throttleDelaySeconds(retryAfter: 2, attempt: 0), 2.0)
        XCTAssertNil(APIClient.throttleDelaySeconds(retryAfter: 42, attempt: 0))
        let backoff = try? XCTUnwrap(APIClient.throttleDelaySeconds(retryAfter: nil, attempt: 0))
        XCTAssertNotNil(backoff)
        XCTAssertLessThanOrEqual(backoff ?? 99, APIClient.maxAutoRetryDelaySeconds)
    }

    func testStagingConfigDetectsProductionServices() {
        let config = AppConfig(
            environment: .staging,
            appBaseURL: URL(string: "https://signalquest.fr")!,
            apiBaseURL: URL(string: "https://api.signalquest.fr")!,
            speedtestBaseURL: URL(string: "https://speedtest.signalquest.fr")!,
            speedtestDownloadURL: URL(string: "https://speedtest.signalquest.fr/download")!,
            speedtestCloudFrontDownloadURL: URL(string: "https://d2d31ihf1e95ah.cloudfront.net/1000MB.bin")!,
            speedtestCloudflareDownloadURL: URL(string: "https://dl.signalquest.fr/speedtest/300MB.bin")!,
            debugLogsEnabled: false
        )

        XCTAssertTrue(config.usesProductionServicesOutsideProduction)
        XCTAssertFalse(config.hasPlaceholderServices)
    }

    func testStagingConfigDetectsSafePlaceholderServices() {
        let config = AppConfig(
            environment: .staging,
            appBaseURL: URL(string: "https://app.staging.invalid")!,
            apiBaseURL: URL(string: "https://api.staging.invalid")!,
            speedtestBaseURL: URL(string: "https://speedtest.staging.invalid")!,
            speedtestDownloadURL: URL(string: "https://speedtest.staging.invalid/download")!,
            speedtestCloudFrontDownloadURL: URL(string: "https://cdn.staging.invalid/1000MB.bin")!,
            speedtestCloudflareDownloadURL: URL(string: "https://dl.staging.invalid/speedtest/300MB.bin")!,
            debugLogsEnabled: false
        )

        XCTAssertFalse(config.usesProductionServicesOutsideProduction)
        XCTAssertTrue(config.hasPlaceholderServices)
    }

    func testUserServicesUseCanonicalApiPrefixedRoutes() async throws {
        let client = APIClient(
            config: .test,
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
            session: Self.mockSession()
        )
        var requestedPaths: [String] = []
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            requestedPaths.append(path)
            let body: String
            switch path {
            case "/api/users/blocks" where request.httpMethod == "GET":
                body = #"{"blocks":[]}"#
            case "/api/users/blocks":
                body = #"{"success":true}"#
            default:
                body = "[]"
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        _ = try await MessagesService(api: client).searchUsers(query: "alex")
        _ = try await SocialFeedService(api: client).searchUsers(query: "alex", limit: 10)
        try await FriendsService(api: client).block(userId: "user-2")
        _ = try await FriendsService(api: client).blocks()

        XCTAssertEqual(requestedPaths, [
            "/api/users/search",
            "/api/users/search",
            "/api/users/blocks",
            "/api/users/blocks",
        ])
    }

    func testPrivacyServiceDecodesAndPersistsCanonicalContract() async throws {
        let client = APIClient(
            config: .test,
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
            session: Self.mockSession()
        )
        var patchBody: [String: Any] = [:]
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "PATCH", let body = Self.requestBody(request) {
                patchBody = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            }
            let settings = request.httpMethod == "PATCH"
                ? #"{"shareLiveLocationWithFriends":true,"shareRadioDataWithFriends":true,"shareSessionsWithFriends":true,"sharePhotosOnFriendMap":true,"shareExactMeasurements":true,"lastSeenVisibility":"friends","messageRequestPolicy":"everyone"}"#
                : #"{"shareLiveLocationWithFriends":false,"shareRadioDataWithFriends":false,"shareSessionsWithFriends":false,"sharePhotosOnFriendMap":false,"shareExactMeasurements":false,"lastSeenVisibility":"none","messageRequestPolicy":"friends_only"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"settings\":\(settings)}".utf8))
        }

        let service = PrivacyService(api: client)
        let initial = try await service.get()
        XCTAssertFalse(initial.shareLiveLocationWithFriends)
        XCTAssertEqual(initial.lastSeenVisibility, .none)
        XCTAssertEqual(initial.messageRequestPolicy, .friendsOnly)

        let updated = try await service.update(UpdatePrivacyRequest(
            shareLiveLocationWithFriends: true,
            shareRadioDataWithFriends: true,
            shareSessionsWithFriends: true,
            sharePhotosOnFriendMap: true,
            shareExactMeasurements: true,
            lastSeenVisibility: .friends,
            messageRequestPolicy: .everyone
        ))
        XCTAssertTrue(updated.shareLiveLocationWithFriends)
        XCTAssertEqual(updated.lastSeenVisibility, .friends)
        XCTAssertEqual(patchBody["messageRequestPolicy"] as? String, "everyone")
        XCTAssertEqual(patchBody["sharePhotosOnFriendMap"] as? Bool, true)
        XCTAssertEqual(patchBody["shareExactMeasurements"] as? Bool, true)
    }

    func testInstallationIdentityPersistsDeviceAndPushTokenSeparately() throws {
        let store = InMemoryTokenStore()
        let identity = InstallationIdentity(store: store)

        let firstID = identity.deviceID()
        XCTAssertEqual(identity.deviceID(), firstID)

        identity.saveFCMToken("fcm-device-a")
        XCTAssertEqual(identity.storedFCMToken(), "fcm-device-a")
        identity.clearFCMToken()
        XCTAssertNil(identity.storedFCMToken())
        XCTAssertEqual(identity.deviceID(), firstID, "Logout must not rotate the installation identity")
    }

    func testAccountDeletionUsesServerPreviewAndSupportedReauthenticationProofs() async throws {
        let client = APIClient(
            config: .test,
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
            session: Self.mockSession()
        )
        var deleteBodies: [[String: Any]] = []
        MockURLProtocol.requestHandler = { request in
            let method = request.httpMethod ?? "GET"
            let body: String
            switch method {
            case "GET":
                body = #"{"confirmationText":"SUPPRIMER MON COMPTE","reauthMethods":{"password":true,"apple":true,"email":true},"maskedEmail":"a***@example.com","willBeDeleted":{"account":"Compte"},"willBeAnonymized":{"speedtests":"2 speedtests"},"warning":"Irréversible"}"#
            case "POST":
                let requestBody = try XCTUnwrap(Self.requestBody(request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
                XCTAssertEqual(json["method"] as? String, "email")
                body = #"{"success":true,"method":"email","challengeId":"challenge-1","maskedEmail":"a***@example.com","expiresAt":"2026-07-10T12:10:00.000Z"}"#
            case "DELETE":
                let requestBody = try XCTUnwrap(Self.requestBody(request))
                deleteBodies.append(try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any]))
                body = #"{"success":true,"reauthMethod":"password","message":"Compte supprimé"}"#
            default:
                throw URLError(.badServerResponse)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let service = UserService(api: client)
        let preview = try await service.accountDeletionPreview()
        XCTAssertEqual(preview.maskedEmail, "a***@example.com")
        XCTAssertTrue(preview.reauthMethods.apple)
        XCTAssertEqual(preview.willBeAnonymized["speedtests"], "2 speedtests")

        let challenge = try await service.requestAccountDeletionEmailCode()
        XCTAssertEqual(challenge.challengeId, "challenge-1")

        _ = try await service.deleteAccount(using: .password("secret"))
        _ = try await service.deleteAccount(using: .apple(identityToken: "apple.jwt"))
        _ = try await service.deleteAccount(using: .email(challengeId: "challenge-1", code: "123456"))

        XCTAssertEqual(deleteBodies.count, 3)
        XCTAssertEqual(deleteBodies[0]["password"] as? String, "secret")
        XCTAssertEqual(deleteBodies[1]["appleIdentityToken"] as? String, "apple.jwt")
        XCTAssertEqual(deleteBodies[2]["challengeId"] as? String, "challenge-1")
        XCTAssertEqual(deleteBodies[2]["emailCode"] as? String, "123456")
        XCTAssertTrue(deleteBodies.allSatisfy { $0["confirmation"] as? String == "SUPPRIMER MON COMPTE" })
    }

    private static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
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
