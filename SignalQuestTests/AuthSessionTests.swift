import XCTest
@testable import SignalQuest

/// TokenStore en mémoire pour tester le cache d'utilisateur (PERF-START-01) sans Keychain.
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    func string(for key: String) throws -> String? { storage[key] }
    func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws { storage[key] = value }
    func remove(_ key: String) throws { storage[key] = nil }
    func keys(withPrefix prefix: String) throws -> [String] {
        storage.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
    func removeAll() throws { storage.removeAll() }
}

/// Mock d'`AuthServicing` pour les tests du view model. Seules les méthodes exercées par
/// bootstrap/revalidation/session-expirée sont utiles ; le reste échoue (jamais appelé).
final class MockAuthService: AuthServicing, @unchecked Sendable {
    enum Unused: Error { case notImplemented }

    var meResult: Result<AuthUser, Error> = .success(.mock)
    var storedCredentials = false
    private(set) var cached: AuthUser?
    private(set) var clearLocalSessionCount = 0
    private(set) var cacheUserCalls: [AuthUser] = []
    private(set) var meCallCount = 0

    func me() async throws -> AuthUser {
        meCallCount += 1
        return try meResult.get()
    }
    func hasStoredCredentials() -> Bool { storedCredentials }
    func cacheUser(_ user: AuthUser) { cacheUserCalls.append(user); cached = user }
    func cachedUser() -> AuthUser? { cached }
    func clearLocalSession() async { clearLocalSessionCount += 1; cached = nil }
    func wipeE2EEIfIdentityChanged(to userId: String) async {}

    // Non exercées.
    func login(email: String, password: String) async throws -> LoginResponse { throw Unused.notImplemented }
    func signup(email: String, password: String, name: String, acceptedTerms: Bool) async throws -> LoginResponse { throw Unused.notImplemented }
    func verify2FA(tempToken: String, code: String) async throws -> LoginResponse { throw Unused.notImplemented }
    func signInWithApple(identityToken: String, fullName: String?) async throws -> LoginResponse { throw Unused.notImplemented }
    func linkApple(identityToken: String) async throws { throw Unused.notImplemented }
    func unlinkApple() async throws { throw Unused.notImplemented }
    func setup2FA() async throws -> TwoFactorSetupResponse { throw Unused.notImplemented }
    func confirm2FA(secret: String, code: String) async throws { throw Unused.notImplemented }
    func disable2FA(code: String) async throws { throw Unused.notImplemented }
    func forgotPassword(email: String) async throws { throw Unused.notImplemented }
    func resetPassword(token: String, newPassword: String) async throws { throw Unused.notImplemented }
    func changePassword(currentPassword: String, newPassword: String) async throws { throw Unused.notImplemented }
    func refresh() async throws { throw Unused.notImplemented }
    func logout() async throws { throw Unused.notImplemented }
}

@MainActor
final class AuthSessionTests: XCTestCase {

    private func makeSecondUser() -> AuthUser {
        AuthUser(
            id: "user-2", email: "second@signalquest.test", name: "Deux", handle: "deux",
            handleChangedAt: nil, avatarUrl: nil, bio: nil, role: "user",
            twoFactorEnabled: false, notifyMessagesPush: nil, notifySocialPush: nil,
            notifyMessagesInApp: nil,
            callsDoNotDisturb: nil, appleLinked: nil
        )
    }

    /// Attend qu'une condition devienne vraie (timeout de sûreté) pour les chemins asynchrones.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: PERF-START-01 — cache SWR

    func testCacheUserRoundTripAndClear() async {
        let store = InMemoryTokenStore()
        let service = AuthService(
            api: APIClient(config: .test),
            e2ee: nil,
            sessionStore: store
        )
        XCTAssertNil(service.cachedUser())

        service.cacheUser(.mock)
        let cached = service.cachedUser()
        XCTAssertEqual(cached?.id, AuthUser.mock.id)
        XCTAssertEqual(cached?.email, AuthUser.mock.email)

        await service.clearLocalSession()
        XCTAssertNil(service.cachedUser(), "clearLocalSession doit purger l'utilisateur en cache")
    }

    // MARK: PERF-START-01 — bootstrap optimiste

    func testBootstrapShowsCachedUserImmediately() async {
        let mock = MockAuthService()
        mock.storedCredentials = true
        mock.cacheUser(.mock)                 // utilisateur en cache
        mock.meResult = .success(.mock)       // revalidation OK
        let vm = AuthSessionViewModel(service: mock)

        await vm.bootstrap()

        // Affichage optimiste immédiat : authentifié dès le retour de bootstrap,
        // sans avoir attendu le réseau bloquant.
        XCTAssertEqual(vm.state, .authenticated(.mock))
    }

    func testBootstrapWithoutCacheUsesBlockingMe() async {
        let mock = MockAuthService()
        mock.storedCredentials = true         // token présent…
        // …mais AUCUN utilisateur en cache → chemin bloquant `me()`.
        mock.meResult = .success(.mock)
        let vm = AuthSessionViewModel(service: mock)

        await vm.bootstrap()

        XCTAssertEqual(vm.state, .authenticated(.mock))
        XCTAssertEqual(mock.meCallCount, 1, "sans cache, bootstrap appelle me() de façon bloquante")
    }

    func testOptimisticRevalidationLogsOutOnUnauthorized() async {
        let mock = MockAuthService()
        mock.storedCredentials = true
        mock.cacheUser(makeSecondUser())
        // Revalidation : session révoquée côté serveur.
        mock.meResult = .failure(APIError.http(status: 401, code: nil, message: "Non authentifié", requestId: nil, retryAfter: nil))
        let vm = AuthSessionViewModel(service: mock)

        await vm.bootstrap()
        // Affichage optimiste d'abord…
        XCTAssertEqual(vm.state, .authenticated(makeSecondUser()))

        // …puis la revalidation d'arrière-plan doit déconnecter proprement.
        await waitUntil { vm.state == .loggedOut && mock.clearLocalSessionCount >= 1 }
        XCTAssertEqual(vm.state, .loggedOut)
        XCTAssertGreaterThanOrEqual(mock.clearLocalSessionCount, 1)
    }

    // MARK: ROB-02 — signal global de session expirée

    func testSessionExpiredNotificationRoutesToLogin() async {
        let mock = MockAuthService()
        mock.storedCredentials = true
        mock.cacheUser(.mock)
        let vm = AuthSessionViewModel(service: mock)
        await vm.bootstrap()
        // Laisse la revalidation optimiste d'arrière-plan (meResult succès) se poser
        // AVANT de poster, pour isoler l'effet de la notification (sinon un
        // setAuthenticated tardif écraserait le .loggedOut — combinaison qui
        // n'arrive pas en prod, où une session morte fait aussi échouer me()).
        await waitUntil { mock.meCallCount >= 1 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(vm.state, .authenticated(.mock))

        NotificationCenter.default.post(name: .sqAuthSessionExpired, object: nil)

        await waitUntil { vm.state == .loggedOut && mock.clearLocalSessionCount >= 1 }
        XCTAssertEqual(vm.state, .loggedOut, "un 401 non récupérable doit re-router vers login (ROB-02)")
        XCTAssertNotNil(vm.infoMessage)
        XCTAssertGreaterThanOrEqual(mock.clearLocalSessionCount, 1)
    }

    func testSessionExpiredIgnoredWhenNotAuthenticated() async {
        let mock = MockAuthService()
        let vm = AuthSessionViewModel(service: mock)
        // État initial `.checking` (ni authentifié).
        NotificationCenter.default.post(name: .sqAuthSessionExpired, object: nil)
        await waitUntil(timeout: 0.3) { vm.state == .loggedOut }
        // Ne bascule PAS : rien à déconnecter, et surtout aucune boucle de nettoyage.
        XCTAssertEqual(mock.clearLocalSessionCount, 0)
    }
}

@MainActor
final class InboxBadgePresentationStateTests: XCTestCase {
    func testResetClearsAccountABadgeAndReopensThrottleForAccountB() throws {
        let sessionA = LocalAccountSession(ownerScopeId: "user:account-a", sessionId: UUID().uuidString)
        let sessionB = LocalAccountSession(ownerScopeId: "user:account-b", sessionId: UUID().uuidString)
        var currentSession: LocalAccountSession? = sessionA
        let state = InboxBadgePresentationState(sessionSnapshot: { currentSession })
        let firstRefresh = Date(timeIntervalSince1970: 100)

        let ticketA = try XCTUnwrap(state.beginRefresh(force: false, now: firstRefresh))
        XCTAssertTrue(state.publish(unreadCount: 7, for: ticketA, now: firstRefresh))
        XCTAssertEqual(state.unreadCount, 7)
        XCTAssertNil(state.beginRefresh(force: false, now: firstRefresh.addingTimeInterval(1)))

        state.reset()
        currentSession = sessionB

        XCTAssertEqual(state.unreadCount, 0)
        XCTAssertNotNil(
            state.beginRefresh(force: false, now: firstRefresh.addingTimeInterval(1)),
            "B doit pouvoir charger son badge immédiatement après la déconnexion de A"
        )
    }

    func testLateAccountAResponseCannotPublishUnderAccountB() throws {
        let sessionA = LocalAccountSession(ownerScopeId: "user:account-a", sessionId: UUID().uuidString)
        let sessionB = LocalAccountSession(ownerScopeId: "user:account-b", sessionId: UUID().uuidString)
        var currentSession: LocalAccountSession? = sessionA
        let state = InboxBadgePresentationState(sessionSnapshot: { currentSession })
        let ticketA = try XCTUnwrap(state.beginRefresh(force: true))

        state.reset()
        currentSession = sessionB

        XCTAssertFalse(state.publish(unreadCount: 9, for: ticketA))
        XCTAssertEqual(state.unreadCount, 0)
    }
}

@MainActor
final class PushLogoutSessionBoundaryTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        LocalAccountScope.deactivate()
        super.tearDown()
    }

    func testPushUnregisterPreservesSnapshotUntilAuthServiceClearsAccountA() async throws {
        LocalAccountScope.deactivate()
        let tokenStore = InMemoryTokenStore()
        let credentials = CredentialStore(tokenStore: tokenStore)
        try credentials.setAccessToken("token-a")
        let api = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        let push = PushNotificationService(
            api: api,
            router: AppRouter(),
            identity: InstallationIdentity(store: InMemoryTokenStore())
        )
        let auth = AuthService(api: api, e2ee: nil, sessionStore: tokenStore)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/auth/logout")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"success":true}"#.utf8))
        }

        LocalAccountScope.activate(userId: "account-a")
        let accountA = try XCTUnwrap(LocalAccountScope.sessionSnapshot())

        await push.unregister()
        XCTAssertEqual(LocalAccountScope.sessionSnapshot(), accountA)

        try await auth.logout()
        XCTAssertNil(LocalAccountScope.currentUserId)
        XCTAssertNil(LocalAccountScope.currentSessionId)
        XCTAssertNil(credentials.accessToken())
    }

    func testLateAccountALogoutResponseCannotClearAccountB() async throws {
        LocalAccountScope.deactivate()
        let tokenStore = InMemoryTokenStore()
        let credentials = CredentialStore(tokenStore: tokenStore)
        try credentials.setAccessToken("token-a")
        let api = APIClient(config: .test, credentials: credentials, session: Self.mockSession())
        let auth = AuthService(api: api, e2ee: nil, sessionStore: tokenStore)
        let requestStarted = expectation(description: "logout A parti")
        let releaseResponse = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 2)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"success":true}"#.utf8))
        }

        LocalAccountScope.activate(userId: "account-a")
        let logoutA = Task { try await auth.logout() }
        await fulfillment(of: [requestStarted], timeout: 1)

        LocalAccountScope.activate(userId: "account-b")
        let accountB = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        try credentials.setAccessToken("token-b")
        releaseResponse.signal()
        try await logoutA.value

        XCTAssertEqual(LocalAccountScope.sessionSnapshot(), accountB)
        XCTAssertEqual(LocalAccountScope.currentUserId, "account-b")
        XCTAssertEqual(credentials.accessToken(), "token-b")
    }

    func testBackgroundDeactivateCannotDeadlockForegroundSessionRead() async {
        LocalAccountScope.deactivate()
        LocalAccountScope.activate(userId: "account-lock-order")
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            _ = LocalAccountScope.sessionSnapshot()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let completed = expectation(description: "deactivate terminé")

        Task.detached {
            LocalAccountScope.deactivate()
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNil(LocalAccountScope.sessionSnapshot())
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
final class AppRouterAccountSwitchQATests: XCTestCase {
    func testDebugAccountSwitchTabsHaveDeterministicPriority() {
        XCTAssertEqual(AppRouter.qaInitialTab(profile: true, community: false), .profile)
        XCTAssertEqual(AppRouter.qaInitialTab(profile: false, community: true), .community)
        XCTAssertEqual(AppRouter.qaInitialTab(profile: true, community: true), .profile)
        XCTAssertNil(AppRouter.qaInitialTab(profile: false, community: false))
    }
}
