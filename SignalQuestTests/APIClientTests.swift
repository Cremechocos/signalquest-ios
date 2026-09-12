import XCTest
@testable import SignalQuest

final class APIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testExpectedSessionRejectsARequestPreparedBeforeAccountChanged() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("account-a")
        let expected = credentials.snapshot().sessionID
        try credentials.setAccessToken("account-b")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        MockURLProtocol.requestHandler = { _ in throw URLError(.unsupportedURL) }
        do {
            _ = try await client.request(APIEndpoint(path: "/api/owner"), as: SuccessResponse.self, expectedSessionID: expected)
            XCTFail("A request crossed the prepared session")
        } catch { XCTAssertEqual(error as? APIError, .cancelled) }
        do {
            _ = try await client.requestData(APIEndpoint(path: "/api/owner"), expectedSessionID: expected)
            XCTFail("A raw request crossed the prepared session")
        } catch { XCTAssertEqual(error as? APIError, .cancelled) }
    }

    func testSingleAttemptRejectsChangedOrReconnectedCredentialSessionBeforeTransport() async throws {
        for nextToken in ["account-b", "account-a"] {
            let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
            try credentials.setAccessToken("account-a")
            let expected = credentials.snapshot().sessionID
            credentials.clearAll()
            try credentials.setAccessToken(nextToken)
            XCTAssertNotEqual(credentials.snapshot().sessionID, expected)
            let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
            MockURLProtocol.requestHandler = { _ in
                XCTFail("Une intention de l’ancienne session ne doit pas atteindre le transport")
                throw URLError(.unsupportedURL)
            }
            do {
                _ = try await client.performSingleAttempt(
                    APIEndpoint(path: "/api/android/favorite-antennas", method: .patch),
                    expectedCredentialSessionID: expected
                )
                XCTFail("Une intention a franchi un changement ou une reconnexion de session")
            } catch { XCTAssertEqual(error as? APIError, .cancelled) }
        }
    }

    func testSingleAttemptAllowsCookieRotationWithinExpectedCredentialSession() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("account-a")
        let expected = credentials.snapshot()
        let rotation = HTTPURLResponse(
            url: URL(string: "https://api.signalquest.test/api/auth/refresh")!,
            statusCode: 200, httpVersion: nil,
            headerFields: ["Set-Cookie": "auth_token=account-a-rotated; Path=/; HttpOnly"]
        )!
        let rotated = try credentials.captureFromResponse(rotation, for: expected)
        XCTAssertEqual(rotated.sessionID, expected.sessionID)
        XCTAssertNotEqual(rotated.revision, expected.revision)
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth_token=account-a-rotated")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"success":true}"#.utf8))
        }
        let (data, response) = try await client.performSingleAttempt(
            APIEndpoint(path: "/api/android/favorite-antennas", method: .patch),
            expectedCredentialSessionID: expected.sessionID
        )
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(SuccessResponse.self, from: data).success, true)
    }

    func testNetworkFreshnessHeadersBypassTheURLCacheLayer() async throws {
        let client = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()), session: Self.mockSession())
        MockURLProtocol.requestHandler = { request in
            guard request.cachePolicy == .reloadIgnoringLocalCacheData else { throw URLError(.cannotLoadFromNetwork) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"success":true}"#.utf8))
        }
        for directive in ["no-cache", "private, no-store", "max-age=0"] {
            let result = try await client.request(APIEndpoint(path: "/api/map", headers: ["cache-control": directive]), as: SuccessResponse.self)
            XCTAssertEqual(result.success, true, directive)
        }
    }

    func testExpectedCurrentSessionAllowsTheRequest() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("account-a")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"success":true}"#.utf8))
        }
        let response = try await client.request(APIEndpoint(path: "/api/owner"), as: SuccessResponse.self,
                                                expectedSessionID: credentials.snapshot().sessionID)
        XCTAssertEqual(response.success, true)
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

    func testAuthenticatedResponseFailsClosedWhenCookieCannotBePersisted() async throws {
        let credentials = CredentialStore(tokenStore: RejectingAuthTokenStore())
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        let lookupOnlyResponse = HeaderLookupOnlyHTTPURLResponse(
            url: URL(string: "https://api.signalquest.test/api/auth/login")!,
            setCookie: "auth_token=lookup-only; Path=/; HttpOnly"
        )
        XCTAssertThrowsError(try credentials.captureFromResponse(lookupOnlyResponse)) { error in
            guard case RejectingAuthTokenStore.Failure.writeRejected = error else {
                return XCTFail("La recherche insensible à la casse n'a pas atteint le TokenStore")
            }
        }

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Set-Cookie": "auth_token=never-persisted; Path=/; HttpOnly"]
            )!
            return (response, Data(#"{"success":true}"#.utf8))
        }

        do {
            let _: SuccessResponse = try await client.request(
                APIEndpoint(path: "/api/auth/login", method: .post),
                as: SuccessResponse.self
            )
            XCTFail("Une réponse auth ne doit pas réussir sans persistance du JWT")
        } catch RejectingAuthTokenStore.Failure.writeRejected {
            // Attendu : aucune publication de session authentifiée possible.
        } catch {
            XCTFail("Erreur inattendue : \(error)")
        }
        XCTAssertNil(credentials.accessToken())
    }

    func testSignedSimulatorHostCanRoundTripAuthKeychain() throws {
        let store = KeychainStore(service: "fr.signalquest.ios.qa.auth-cookie")
        try? store.removeAll()
        defer { try? store.removeAll() }

        try store.set("synthetic-auth-token", for: "auth_token")
        XCTAssertEqual(try store.string(for: "auth_token"), "synthetic-auth-token")
        try store.remove("auth_token")
        XCTAssertNil(try store.string(for: "auth_token"))
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
        // Comparé au REPLI, pas à sa traduction : figer la copie française ferait
        // tomber ce test le jour de l'ajout d'une langue, sans qu'aucune fuite
        // n'ait eu lieu — ce qui s'est produit.
        XCTAssertEqual(
            APIError.http(status: 500, code: nil, message: "Invalid `prisma.$queryRaw()` invocation: ...", requestId: "r1", retryAfter: nil).errorDescription,
            APIError.statusFallback(500)
        )
        // Un code connu reste prioritaire, même en 5xx. Ce qui compte est que la
        // prose du serveur ne ressorte pas, pas le libellé exact du remplacement.
        let rateLimited = APIError.userFacingMessage(status: 503, code: "RATE_LIMITED", serverMessage: "peu importe")
        XCTAssertFalse(rateLimited.contains("peu importe"))
        XCTAssertFalse(rateLimited.isEmpty)
        XCTAssertNotEqual(rateLimited, APIError.statusFallback(503))
        // Un 4xx avec message FR lisible passe toujours (comportement inchangé).
        XCTAssertEqual(
            APIError.userFacingMessage(status: 400, code: nil, serverMessage: "Le nom est déjà pris."),
            "Le nom est déjà pris."
        )
    }

    // MARK: - Sprint 1 : idempotence & throttling (429/503)

    func testAccountSwitchCancels401AndThrottleRetriesBeforeTheyCanUseAccountB() async throws {
        for status in [401, 429, 503] {
            let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
            try credentials.setAccessToken("account-a")
            let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
            var cookies: [String?] = []
            MockURLProtocol.requestHandler = { request in
                cookies.append(request.value(forHTTPHeaderField: "Cookie"))
                try credentials.setAccessToken("account-b")
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                    httpVersion: nil, headerFields: ["Retry-After": "0"])!
                return (response, Data(#"{"error":"retry"}"#.utf8))
            }

            do {
                let _: SuccessResponse = try await client.requestJSON("/api/speedtests", body: ["owner": "a"])
                XCTFail("La requête de A doit être annulée sur \(status)")
            } catch APIError.cancelled {} catch { XCTFail("Erreur inattendue : \(error)") }
            XCTAssertEqual(cookies, ["auth_token=account-a"])
            XCTAssertEqual(credentials.accessToken(), "account-b")
        }
    }

    func testLateSuccessCannotPublishAccountADataOrOverwriteAccountBCookie() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("account-a")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        MockURLProtocol.requestHandler = { request in
            try credentials.setAccessToken("account-b")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "auth_token=account-a-late; Path=/"])!
            return (response, Data(#"{"success":true}"#.utf8))
        }

        do {
            let _: SuccessResponse = try await client.request(APIEndpoint(path: "/api/auth/refresh", method: .post), as: SuccessResponse.self)
            XCTFail("Une réponse de A ne doit pas être publiée sous B")
        } catch APIError.cancelled {} catch { XCTFail("Erreur inattendue : \(error)") }
        XCTAssertEqual(credentials.accessToken(), "account-b")
    }

    func testLateLoginCannotReplaceAnotherLoginThatAlreadyCompleted() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            try credentials.setAccessToken("account-b")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "auth_token=account-a-late; Path=/"])!
            return (response, Data(#"{"success":true}"#.utf8))
        }

        do {
            let _: SuccessResponse = try await client.request(
                APIEndpoint(path: "/api/auth/login", method: .post, authenticated: false), as: SuccessResponse.self)
            XCTFail("La connexion concurrente terminée est propriétaire du magasin")
        } catch APIError.cancelled {} catch { XCTFail("Erreur inattendue : \(error)") }
        XCTAssertEqual(credentials.accessToken(), "account-b")
    }

    func testLogoutAndSameTokenReloginStillInvalidateOldResponse() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("same-account")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        MockURLProtocol.requestHandler = { request in
            credentials.clearAll()
            try credentials.setAccessToken("same-account")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"success":true}"#.utf8))
        }

        do {
            _ = try await client.requestData(APIEndpoint(path: "/api/user/privacy"))
            XCTFail("La génération de connexion doit compter même si le token est identique")
        } catch APIError.cancelled {} catch { XCTFail("Erreur inattendue : \(error)") }
    }

    func testSingleAttemptCannotCaptureLateCookieAfterAccountSwitch() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("account-a")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        MockURLProtocol.requestHandler = { request in
            try credentials.setAccessToken("account-b")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "auth_token=account-a-late; Path=/"])!
            return (response, Data("{}".utf8))
        }
        do {
            _ = try await client.performSingleAttempt(APIEndpoint(path: "/api/e2ee/v2/test", method: .post))
            XCTFail("Une tentative signée garde également sa session propriétaire")
        } catch APIError.cancelled {} catch { XCTFail("Erreur inattendue : \(error)") }
        XCTAssertEqual(credentials.accessToken(), "account-b")
    }

    func testConcurrentRefreshRotationCannotBeRolledBackByAnOlderCookie() throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("old")
        let sent = credentials.snapshot()
        let url = URL(string: "https://api.signalquest.test/api/auth/refresh")!
        let fresh = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Set-Cookie": "auth_token=fresh; Path=/"])!
        let late = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Set-Cookie": "auth_token=late; Path=/"])!

        try credentials.captureFromResponse(fresh, for: sent)
        try credentials.captureFromResponse(late, for: sent)
        XCTAssertTrue(credentials.isCurrent(sent), "Le refresh conserve la connexion")
        XCTAssertFalse(credentials.isCurrent(sent, matchingRevision: true))
        XCTAssertEqual(credentials.accessToken(), "fresh")

        try credentials.setAccessToken("account-b")
        XCTAssertThrowsError(try credentials.captureFromResponse(late, for: sent)) { error in
            guard case APIError.cancelled = error else { return XCTFail("Erreur inattendue : \(error)") }
        }
        XCTAssertEqual(credentials.accessToken(), "account-b")
    }

    func testRefreshNetworkServerAndCancellationFailuresPreserveSession() async throws {
        for mode in ["offline", "cancelled", "429", "503"] {
            let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
            try credentials.setAccessToken("account-a")
            let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
            let unexpectedExpiration = expectation(description: "Pas d'expiration pour \(mode)")
            unexpectedExpiration.isInverted = true
            let observer = NotificationCenter.default.addObserver(forName: .sqAuthSessionExpired,
                object: nil, queue: nil) { _ in unexpectedExpiration.fulfill() }
            MockURLProtocol.requestHandler = { request in
                let status: Int
                if request.url?.path == "/api/auth/refresh" {
                    if mode == "offline" { throw URLError(.notConnectedToInternet) }
                    if mode == "cancelled" { throw URLError(.cancelled) }
                    status = Int(mode)!
                } else { status = 401 }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"error":"synthetic"}"#.utf8))
            }

            do {
                try await client.request(APIEndpoint(path: "/api/auth/me"))
                XCTFail("L'erreur de refresh doit être remontée")
            } catch let error as APIError {
                switch (mode, error) {
                case ("offline", .transport), ("cancelled", .cancelled), ("429", .http(status: 429, code: _, message: _, requestId: _, retryAfter: _)), ("503", .http(status: 503, code: _, message: _, requestId: _, retryAfter: _)): break
                default: XCTFail("Le type de panne a été perdu : \(error)")
                }
            } catch { XCTFail("Erreur inattendue : \(error)") }
            await fulfillment(of: [unexpectedExpiration], timeout: 0.03)
            NotificationCenter.default.removeObserver(observer)
            XCTAssertEqual(credentials.accessToken(), "account-a")
        }
    }

    func testRejectedRefreshEmitsExpirationScopedToTheRejectedCredential() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("account-a")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        let expirationReceived = expectation(description: "Session A refusée")
        let observer = NotificationCenter.default.addObserver(forName: .sqAuthSessionExpired,
            object: nil, queue: nil) { notification in
                guard let expiration = notification.object as? AuthSessionExpiration else {
                    return XCTFail("L'expiration doit porter son propriétaire")
                }
                XCTAssertTrue(expiration.isCurrent)
                XCTAssertEqual(expiration.snapshot.accessToken, "account-a")
                expirationReceived.fulfill()
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        do { try await client.request(APIEndpoint(path: "/api/auth/me")) } catch {}
        await fulfillment(of: [expirationReceived], timeout: 1)
    }

    func testAlreadyRefreshedTokenRetriesWithoutRedundantRefresh() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("stale")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(request.url!.path)
            if paths.count == 1 {
                let refresh = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Set-Cookie": "auth_token=fresh; Path=/"])!
                try credentials.captureFromResponse(refresh, for: credentials.snapshot())
                return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth_token=fresh")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"success":true}"#.utf8))
        }
        let _: SuccessResponse = try await client.request(APIEndpoint(path: "/api/feed"), as: SuccessResponse.self)
        XCTAssertEqual(paths, ["/api/feed", "/api/feed"])
    }

    func testConcurrent401RequestsShareOneRefreshAndKeepTheSameAccount() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("account-a-stale")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        let lock = NSLock()
        var refreshCount = 0
        var successfulRequests = 0
        MockURLProtocol.requestHandler = { request in
            lock.withLock {
                let isRefresh = request.url?.path == "/api/auth/refresh"
                let fresh = request.value(forHTTPHeaderField: "Cookie") == "auth_token=account-a-fresh"
                if isRefresh { refreshCount += 1 }
                if !isRefresh && fresh { successfulRequests += 1 }
                let status = isRefresh || fresh ? 200 : 401
                let headers = isRefresh ? ["Set-Cookie": "auth_token=account-a-fresh; Path=/"] : nil
                return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: headers)!, Data(#"{"success":true}"#.utf8))
            }
        }

        async let first: Void = client.request(APIEndpoint(path: "/api/feed"))
        async let second: Void = client.request(APIEndpoint(path: "/api/user/privacy"))
        async let third: Void = client.request(APIEndpoint(path: "/api/notifications"))
        _ = try await (first, second, third)

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(successfulRequests, 3)
        XCTAssertEqual(credentials.accessToken(), "account-a-fresh")
    }

    func testAccountSwitchDuringRefreshCannotCaptureCookieOrRetryOriginalMutation() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("account-a")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        var calls: [String] = []
        MockURLProtocol.requestHandler = { request in
            calls.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth_token=account-a")
            let isRefresh = request.url?.path == "/api/auth/refresh"
            if isRefresh { try credentials.setAccessToken("account-b") }
            let response = HTTPURLResponse(url: request.url!, statusCode: isRefresh ? 200 : 401,
                httpVersion: nil, headerFields: isRefresh ? ["Set-Cookie": "auth_token=account-a-refreshed; Path=/"] : nil)!
            return (response, Data(#"{"success":true}"#.utf8))
        }

        do {
            let _: SuccessResponse = try await client.requestJSON("/api/speedtests", body: ["owner": "a"])
            XCTFail("La mutation de A doit être abandonnée")
        } catch APIError.cancelled {} catch { XCTFail("Erreur inattendue : \(error)") }
        XCTAssertEqual(calls, ["/api/speedtests", "/api/auth/refresh"])
        XCTAssertEqual(credentials.accessToken(), "account-b")
    }

    func testAccountSwitchDuringThrottleBackoffCancelsTheDelayedReplay() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("account-a")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        let firstResponse = expectation(description: "Backoff demandé")
        var calls = 0
        MockURLProtocol.requestHandler = { request in
            calls += 1
            firstResponse.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "1"])!, Data("{}".utf8))
        }
        let requestA = Task { try await client.request(APIEndpoint(path: "/api/speedtests", method: .post)) }
        await fulfillment(of: [firstResponse], timeout: 1)
        // Le transport a terminé ; le rejeu attend le Retry-After serveur.
        try await Task.sleep(nanoseconds: 50_000_000)
        try credentials.setAccessToken("account-b")
        do {
            try await requestA.value
            XCTFail("Le rejeu différé ne doit pas franchir une connexion")
        } catch APIError.cancelled {} catch { XCTFail("Erreur inattendue : \(error)") }
        XCTAssertEqual(calls, 1)
    }

    func testSingleAttemptHTTPFailureDoesNotInstallItsCookie() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("account-a")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil,
                headerFields: ["Set-Cookie": "auth_token=error-response; Path=/"])!, Data("{}".utf8))
        }
        let (_, response) = try await client.performSingleAttempt(APIEndpoint(path: "/api/e2ee/v2/test"))
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(credentials.accessToken(), "account-a")
    }

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

    func testSingleAttemptReturnsHTTPFailureWithoutRefreshOrRetry() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("stale")
        let client = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        var hits = 0
        MockURLProtocol.requestHandler = { request in
            hits += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"error":"unavailable","code":"TEMPORARY"}"#.utf8))
        }

        let (data, response) = try await client.performSingleAttempt(
            APIEndpoint(path: "/api/e2ee/v2/test", method: .post, body: Data("{}".utf8))
        )

        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(hits, 1, "Une preuve signée ne doit jamais être rejouée automatiquement")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("TEMPORARY"))
    }

    func testRequestSpecificProtocolHeadersOverrideGlobalV1Contract() throws {
        let client = APIClient(
            config: .test,
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
            session: Self.mockSession()
        )
        let request = try client.makeURLRequest(
            APIEndpoint(
                path: "/api/e2ee/v2/test",
                method: .post,
                headers: [
                    ClientProtocolContract.protocolVersionHeader: "2",
                    ClientProtocolContract.capabilitiesHeaderName: E2EEV2ActivationPolicy.contractPreviewCapability,
                ],
                body: Data("{}".utf8)
            )
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: ClientProtocolContract.protocolVersionHeader), "2")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: ClientProtocolContract.capabilitiesHeaderName),
            E2EEV2ActivationPolicy.contractPreviewCapability
        )
        XCTAssertEqual(ClientProtocolContract.currentProtocolVersion, 1)
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

    func testPushRegistrationSecretsAreScopedAndDurable() throws {
        let store = InMemoryTokenStore()
        let identity = InstallationIdentity(store: store)
        let ownerA = PushOwnerScope.id(for: "account-a")
        let ownerB = PushOwnerScope.id(for: "account-b")
        let record = PushRegistrationRecord(
            ownerScopeId: ownerA,
            token: "fcm-a",
            deviceID: "device-a",
            revocationSecret: "secret-a",
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertTrue(identity.saveRegistration(record))
        XCTAssertEqual(identity.registration(ownerScopeId: ownerA), record)
        XCTAssertNil(identity.registration(ownerScopeId: ownerB))

        identity.enqueuePendingRevocation(record)
        XCTAssertEqual(identity.pendingRevocations(), [record])
        identity.completePendingRevocation(record)
        XCTAssertTrue(identity.pendingRevocations().isEmpty)
    }

    func testPushRecipientPolicyRejectsCrossAccountAndLegacyPrivatePayloads() {
        let ownerA = PushOwnerScope.id(for: "account-a")
        let ownerB = PushOwnerScope.id(for: "account-b")

        XCTAssertEqual(
            PushRecipientPolicy.evaluate(["type": "message_new", "recipientOwnerScope": ownerA], currentOwnerScopeId: ownerA),
            .acceptTargeted
        )
        XCTAssertEqual(
            PushRecipientPolicy.evaluate(["type": "message_new", "recipientOwnerScope": ownerA], currentOwnerScopeId: ownerB),
            .rejectWrongAccount
        )
        XCTAssertEqual(
            PushRecipientPolicy.evaluate(["type": "message_new"], currentOwnerScopeId: ownerA),
            .rejectMissingTarget
        )
        XCTAssertEqual(
            PushRecipientPolicy.evaluate(["type": "e2ee_v2_device_approval"], currentOwnerScopeId: ownerA),
            .rejectMissingTarget
        )
        XCTAssertEqual(
            PushRecipientPolicy.evaluate(["type": "e2ee_v2_envelope"], currentOwnerScopeId: ownerA),
            .rejectMissingTarget
        )
        XCTAssertEqual(
            PushRecipientPolicy.evaluate(
                ["type": "e2ee_v2_envelope", "recipientOwnerScope": ownerA],
                currentOwnerScopeId: ownerA
            ),
            .acceptTargeted
        )
        XCTAssertEqual(
            PushRecipientPolicy.evaluate(
                ["type": "e2ee_v2_device_approval", "recipientOwnerScope": ownerA],
                currentOwnerScopeId: ownerA
            ),
            .acceptTargeted
        )
        XCTAssertEqual(
            PushRecipientPolicy.evaluate(["type": "anfr_update"], currentOwnerScopeId: nil),
            .acceptPublic
        )
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

private final class HeaderLookupOnlyHTTPURLResponse: HTTPURLResponse, @unchecked Sendable {
    private let setCookie: String

    init(url: URL, setCookie: String) {
        self.setCookie = setCookie
        super.init(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allHeaderFields: [AnyHashable: Any] { [:] }

    override func value(forHTTPHeaderField field: String) -> String? {
        field.caseInsensitiveCompare("Set-Cookie") == .orderedSame ? setCookie : nil
    }
}

private final class RejectingAuthTokenStore: TokenStore, @unchecked Sendable {
    enum Failure: Error { case writeRejected }

    func string(for key: String) throws -> String? { nil }
    func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws {
        throw Failure.writeRejected
    }
    func remove(_ key: String) throws {}
    func keys(withPrefix prefix: String) throws -> [String] { [] }
    func removeAll() throws {}
}
