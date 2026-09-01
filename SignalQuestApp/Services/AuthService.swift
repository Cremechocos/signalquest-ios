import Foundation
import CryptoKit
import UserNotifications

struct LocalAccountSession: Codable, Equatable, Sendable {
    let ownerScopeId: String
    let sessionId: String
    var ownerNamespace: String { LocalAccountScope.storageNamespace(for: ownerScopeId) }
    var isCurrent: Bool { LocalAccountScope.sessionSnapshot() == self }
    func matchesAuthToken(_ token: String) -> Bool {
        guard ownerScopeId.hasPrefix("user:") else { return false }
        return E2EEV2NotificationSessionClaims.expirationMs(token: token,
            expectedUserId: String(ownerScopeId.dropFirst(5)), now: Date()) != nil
    }
}

/// Portée locale active des caches et files privées. Les anciennes données sans
/// propriétaire restent dans leur ancien namespace et ne sont jamais attribuées
/// automatiquement au compte qui se connecte ensuite.
enum LocalAccountScope {
    /// Les lectures UI ne doivent jamais attendre une écriture `UserDefaults` :
    /// celle-ci notifie SwiftUI synchronement et peut reprendre le main thread.
    /// `stateLock` ne protège donc que l'état mémoire, tandis que `mutationLock`
    /// sérialise mutations + persistance sans être acquis par les lecteurs.
    private static let stateLock = NSLock()
    private static let mutationLock = NSRecursiveLock()
    private static let userKey = "SignalQuest.LocalAccountScope.userId.v1"
    private static let sessionKey = "SignalQuest.LocalAccountScope.sessionId.v1"

    private struct State {
        var userId: String?
        var sessionId: String?
    }

    // Accès exclusivement sous `stateLock` ; l'annotation documente cette
    // synchronisation explicite pour Swift 6.
    nonisolated(unsafe) private static var state: State = {
        let defaults = UserDefaults.standard
        let rawUser = defaults.string(forKey: userKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userId = rawUser?.isEmpty == false ? rawUser : nil
        let rawSession = defaults.string(forKey: sessionKey)
        let sessionId = userId != nil && rawSession.flatMap(UUID.init(uuidString:)) != nil
            ? rawSession
            : nil
        return State(userId: userId, sessionId: sessionId)
    }()

    static var currentUserId: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return state.userId
    }

    static var currentOwnerScopeId: String {
        guard let userId = currentUserId else {
            return "guest"
        }
        return "user:\(userId)"
    }

    static var currentSessionId: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard state.userId != nil else { return nil }
        return state.sessionId
    }

    static var storageNamespace: String {
        storageNamespace(for: currentOwnerScopeId)
    }

    static func storageNamespace(for ownerScopeId: String) -> String {
        SHA256.hash(data: Data(ownerScopeId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func activate(userId: String) {
        if currentUserId != userId { E2EEV2NotificationContextEvents.revoke() }
        mutationLock.lock(); defer { mutationLock.unlock() }
        stateLock.lock()
        if state.userId != userId || state.sessionId == nil {
            state.sessionId = UUID().uuidString.lowercased()
        }
        state.userId = userId
        let snapshot = state
        stateLock.unlock()
        persist(snapshot)
    }

    static func invalidateNotificationSession() {
        mutationLock.lock(); defer { mutationLock.unlock() }
        stateLock.lock()
        state.sessionId = nil
        let snapshot = state
        stateLock.unlock()
        persist(snapshot)
    }

    static func deactivate() {
        mutationLock.lock()
        stateLock.lock()
        state = State(userId: nil, sessionId: nil)
        let snapshot = state
        stateLock.unlock()
        persist(snapshot)
        mutationLock.unlock()
        E2EEV2NotificationContextEvents.revoke()
    }

    static func sessionSnapshot() -> LocalAccountSession? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let userId = state.userId, let sessionId = state.sessionId else { return nil }
        return .init(ownerScopeId: "user:\(userId)", sessionId: sessionId)
    }

    /// Préparer réseau, crypto et données hors verrou ; publier seulement les écritures locales prêtes.
    static func publish<T>(for session: LocalAccountSession, _ commit: () throws -> T) throws -> T {
        try publishIfUnchanged(session, commit)
    }

    static func publishIfUnchanged<T>(_ session: LocalAccountSession?, _ commit: () throws -> T) throws -> T {
        mutationLock.lock(); defer { mutationLock.unlock() }
        stateLock.lock()
        let current = state.userId.flatMap { userId in
            state.sessionId.map { LocalAccountSession(ownerScopeId: "user:\(userId)", sessionId: $0) }
        }
        stateLock.unlock()
        guard current == session else { throw CancellationError() }
        return try commit()
    }

    private static func persist(_ snapshot: State) {
        let defaults = UserDefaults.standard
        if let userId = snapshot.userId {
            defaults.set(userId, forKey: userKey)
        } else {
            defaults.removeObject(forKey: userKey)
        }
        if let sessionId = snapshot.sessionId {
            defaults.set(sessionId, forKey: sessionKey)
        } else {
            defaults.removeObject(forKey: sessionKey)
        }
    }
}

enum LocalOfflineOwnership {
    private static func key(kind: String, id: String) -> String {
        "SignalQuest.OfflineOwner.v1.\(kind).\(id)"
    }

    static func claim(kind: String, id: String) {
        UserDefaults.standard.set(LocalAccountScope.currentOwnerScopeId, forKey: key(kind: kind, id: id))
    }

    static func belongsToCurrentScope(kind: String, id: String) -> Bool {
        UserDefaults.standard.string(forKey: key(kind: kind, id: id)) == LocalAccountScope.currentOwnerScopeId
    }

    static func release(kind: String, id: String) {
        UserDefaults.standard.removeObject(forKey: key(kind: kind, id: id))
    }
}

protocol AuthServicing: Sendable {
    func login(email: String, password: String) async throws -> LoginResponse
    func signup(email: String, password: String, name: String, acceptedTerms: Bool) async throws -> LoginResponse
    func verify2FA(tempToken: String, code: String) async throws -> LoginResponse
    /// Sign in with Apple : envoie le jeton d'identité Apple (JWT) + le nom
    /// (1re autorisation) ; le backend vérifie le jeton et crée/connecte l'utilisateur.
    func signInWithApple(identityToken: String, fullName: String?) async throws -> LoginResponse
    /// Associe un Apple ID au compte authentifié courant (depuis les Réglages).
    func linkApple(identityToken: String) async throws
    /// Dissocie l'Apple ID du compte authentifié courant.
    func unlinkApple() async throws
    func setup2FA() async throws -> TwoFactorSetupResponse
    func confirm2FA(secret: String, code: String) async throws
    func disable2FA(code: String) async throws
    func forgotPassword(email: String) async throws
    func resetPassword(token: String, newPassword: String) async throws
    func changePassword(currentPassword: String, newPassword: String) async throws
    func refresh() async throws
    func logout() async throws
    func me() async throws -> AuthUser
    func hasStoredCredentials() -> Bool
    func installAuthTokenForDebugQA(_ token: String)
    /// QA `--reset-auth` : efface la session LOCALE (credentials + clés E2EE)
    /// sans révoquer le token côté serveur — contrairement à `logout()`.
    func clearLocalSessionForDebugQA() async
    /// Efface la session LOCALE (credentials + clés E2EE + utilisateur en cache)
    /// SANS appel réseau. Utilisé sur session expirée (ROB-02) : pas de POST logout
    /// (qui re-échouerait en 401 et boucherait), juste le nettoyage local.
    func clearLocalSession() async
    /// Only after the server has acknowledged deletion of this exact account.
    func eraseDeletedAccountVault(ownerScopeId: String) async
    /// PERF-START-01 : mémorise le dernier utilisateur authentifié pour un démarrage
    /// à froid optimiste (affichage immédiat + revalidation en arrière-plan).
    func cacheUser(_ user: AuthUser)
    /// Dernier utilisateur authentifié connu (Keychain), ou `nil`.
    func cachedUser() -> AuthUser?
    /// E2EE-WIPE-02 : purge les clés E2EE si l'utilisateur authentifié diffère du
    /// dernier connu sur cet appareil (changement de compte sans logout, ex.
    /// expiration de session). À appeler avant de passer en `.authenticated`.
    func wipeE2EEIfIdentityChanged(to userId: String) async
}

extension AuthServicing {
    func installAuthTokenForDebugQA(_ token: String) {}
    func clearLocalSessionForDebugQA() async {}
    func clearLocalSession() async {}
    func eraseDeletedAccountVault(ownerScopeId: String) async {}
    func cacheUser(_ user: AuthUser) {}
    func cachedUser() -> AuthUser? { nil }
    func hasStoredCredentials() -> Bool { false }
    func wipeE2EEIfIdentityChanged(to userId: String) async {}
}

final class AuthService: AuthServicing {
    private let api: APIClient
    private let e2ee: E2EEServicing?
    /// Keychain AUTH (`fr.signalquest.ios`, `afterFirstUnlock`) : même service que le
    /// token, donc lisible au cold start dans les mêmes conditions.
    private let sessionStore: TokenStore
    private static let cachedUserKey = "cachedAuthUser"

    init(api: APIClient, e2ee: E2EEServicing? = nil, sessionStore: TokenStore = KeychainStore()) {
        self.api = api
        self.e2ee = e2ee
        self.sessionStore = sessionStore
    }

    // MARK: Login / signup

    func login(email: String, password: String) async throws -> LoginResponse {
        try await api.requestJSON(
            "/api/auth/login",
            body: LoginRequest(email: email, password: password),
            authenticated: false
        )
    }

    func signup(email: String, password: String, name: String, acceptedTerms: Bool) async throws -> LoginResponse {
        try await api.requestJSON(
            "/api/auth/signup",
            body: SignupRequest(email: email, password: password, name: name, acceptedTerms: acceptedTerms),
            authenticated: false
        )
    }

    func signInWithApple(identityToken: String, fullName: String?) async throws -> LoginResponse {
        struct AppleSignInRequest: Encodable {
            let identityToken: String
            let fullName: String?
        }
        return try await api.requestJSON(
            "/api/auth/apple",
            body: AppleSignInRequest(identityToken: identityToken, fullName: fullName),
            authenticated: false
        )
    }

    func linkApple(identityToken: String) async throws {
        struct AppleLinkRequest: Encodable { let identityToken: String }
        let _: AppleLinkResponse = try await api.requestJSON(
            "/api/auth/apple/link",
            body: AppleLinkRequest(identityToken: identityToken)
        )
    }

    func unlinkApple() async throws {
        let _: AppleLinkResponse = try await api.request(
            APIEndpoint(path: "/api/auth/apple/unlink", method: .post),
            as: AppleLinkResponse.self
        )
    }

    // MARK: 2FA

    func verify2FA(tempToken: String, code: String) async throws -> LoginResponse {
        try await api.requestJSON(
            "/api/auth/2fa/verify",
            body: TwoFactorVerifyRequest(tempToken: tempToken, code: code),
            authenticated: false
        )
    }

    func setup2FA() async throws -> TwoFactorSetupResponse {
        try await api.request(
            APIEndpoint(path: "/api/auth/2fa/setup", method: .post),
            as: TwoFactorSetupResponse.self
        )
    }

    func confirm2FA(secret: String, code: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/auth/2fa/verify-setup",
            body: TwoFactorVerifySetupRequest(secret: secret, code: code)
        )
    }

    func disable2FA(code: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/auth/2fa/disable",
            body: TwoFactorDisableRequest(code: code)
        )
    }

    // MARK: Password

    func forgotPassword(email: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/auth/forgot-password",
            body: ForgotPasswordRequest(email: email),
            authenticated: false
        )
    }

    func resetPassword(token: String, newPassword: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/auth/reset-password",
            body: ResetPasswordRequest(token: token, password: newPassword),
            authenticated: false
        )
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {
        let _: SuccessResponse = try await api.requestJSON(
            "/api/user/change-password",
            body: ChangePasswordRequest(currentPassword: currentPassword, newPassword: newPassword)
        )
    }

    // MARK: Session lifecycle

    func refresh() async throws {
        _ = try await api.request(
            APIEndpoint(path: "/api/auth/refresh", method: .post, skipsAutoRefresh: true),
            as: SuccessResponse.self
        )
    }

    func logout() async throws {
        let closing = LocalAccountScope.sessionSnapshot()
        let token = api.credentials.accessToken()
        if let closing, let token {
            _ = try? await api.performSingleAttempt(APIEndpoint(path: "/api/auth/logout", method: .post),
                fixedAuthToken: token, expectedSession: closing)
        }
        guard LocalAccountScope.sessionSnapshot() == closing, api.credentials.accessToken() == token else { return }
        // Révoquer l'accès avant de quitter la session ; le coffre v2 propriétaire reste chiffré.
        await e2ee?.lockLocalKeys(expectedSession: closing)
        if e2ee == nil {
            try? LocalAccountScope.publishIfUnchanged(closing) { LocalAccountScope.invalidateNotificationSession() }
        }
        guard LocalAccountScope.currentSessionId == nil,
              LocalAccountScope.currentOwnerScopeId == (closing?.ownerScopeId ?? "guest"),
              api.credentials.accessToken() == token else { return }
        if let ownerScopeId = closing?.ownerScopeId {
            OutageReportDraftStore.purge(ownerScopeId: ownerScopeId)
        }
        LocalAccountScope.deactivate()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        api.credentials.clearAll()
        try? sessionStore.remove(Self.cachedUserKey)
    }

    func clearLocalSession() async {
        // Verrouillage local, sans appel réseau : l'expiration ne détruit pas l'identité v2 approuvée.
        let closing = LocalAccountScope.sessionSnapshot()
        let token = api.credentials.accessToken()
        await e2ee?.lockLocalKeys(expectedSession: closing)
        guard LocalAccountScope.currentSessionId == nil || LocalAccountScope.sessionSnapshot() == closing else { return }
        guard LocalAccountScope.currentOwnerScopeId == (closing?.ownerScopeId ?? "guest"),
              api.credentials.accessToken() == token else { return }
        if let ownerScopeId = closing?.ownerScopeId {
            OutageReportDraftStore.purge(ownerScopeId: ownerScopeId)
        }
        LocalAccountScope.deactivate()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        api.credentials.clearAll()
        try? sessionStore.remove(Self.cachedUserKey)
    }

    func clearLocalSessionForDebugQA() async {
        // Même purge locale que `logout()`, sans l'appel serveur : le JWT reste
        // valide pour les autres passes QA (tours UI avec token injecté).
        await clearLocalSession()
    }

    func eraseDeletedAccountVault(ownerScopeId: String) async {
        await e2ee?.eraseLocalVault(ownerScopeId: ownerScopeId)
    }

    func cacheUser(_ user: AuthUser) {
        let previousUserId = LocalAccountScope.currentUserId
        if let previousUserId, previousUserId != user.id {
            OutageReportDraftStore.purge(ownerScopeId: "user:\(previousUserId)")
        }
        LocalAccountScope.activate(userId: user.id)
        if previousUserId != user.id {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
        guard
            let data = try? JSONEncoder.signalQuest.encode(user),
            let json = String(data: data, encoding: .utf8)
        else { return }
        try? sessionStore.set(json, for: Self.cachedUserKey)
    }

    func cachedUser() -> AuthUser? {
        guard
            let json = try? sessionStore.string(for: Self.cachedUserKey),
            let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder.signalQuest.decode(AuthUser.self, from: data)
    }

    func wipeE2EEIfIdentityChanged(to userId: String) async {
        // API conservée : le changement de propriétaire verrouille désormais le coffre,
        // sans effacer son identité approuvée ni ses époques historiques.
        let store = KeychainStore()
        let last = try? store.string(for: "lastUserId")
        if let last, last != userId {
            await e2ee?.lockLocalKeys(expectedSession: LocalAccountScope.sessionSnapshot())
        }
        try? store.set(userId, for: "lastUserId")
    }

    func me() async throws -> AuthUser {
        let response: AuthMeResponse = try await api.request(
            APIEndpoint(path: "/api/auth/me"),
            as: AuthMeResponse.self
        )
        guard let user = response.user else {
            // `{ user: null }` en 200 = session invalide → traiter comme un 401
            // pour que le bootstrap bascule proprement en déconnecté.
            throw APIError.http(status: 401, code: nil, message: "Non authentifié", requestId: nil, retryAfter: nil)
        }
        return user
    }

    func hasStoredCredentials() -> Bool {
        api.credentials.accessToken() != nil
    }

    func installAuthTokenForDebugQA(_ token: String) {
        #if DEBUG
        try? api.credentials.setAccessToken(token)
        #endif
    }
}

@MainActor
final class AuthSessionViewModel: ObservableObject {
    enum State: Equatable {
        case checking
        case loggedOut
        /// We hold a session token but couldn't reach the server at launch.
        case offline
        case requires2FA(tempToken: String)
        case authenticated(AuthUser)
    }

    @Published private(set) var state: State = .checking
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var isBusy = false

    private let service: AuthServicing
    // Écrit une seule fois (init, MainActor), lu une seule fois (deinit, quand plus
    // aucune autre référence n'existe) → `nonisolated(unsafe)` sûr pour permettre le
    // retrait de l'observateur depuis le deinit nonisolé.
    private nonisolated(unsafe) var sessionExpiredObserver: NSObjectProtocol?

    init(service: AuthServicing) {
        self.service = service
        if AppEnvironment.usesDemoData {
            state = .authenticated(AuthUser.mock)
        }
        // ROB-02 : une requête authentifiée dont le 401 n'a pas pu être récupéré
        // par le refresh diffuse `sqAuthSessionExpired`. On rebascule alors
        // globalement vers l'écran de login au lieu de laisser des écritures
        // échouer en silence.
        sessionExpiredObserver = NotificationCenter.default.addObserver(
            forName: .sqAuthSessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSessionExpired() }
        }
    }

    deinit {
        if let sessionExpiredObserver {
            NotificationCenter.default.removeObserver(sessionExpiredObserver)
        }
    }

    /// ROB-02 : bascule vers login sur session expirée. `.loggedOut` est posé AVANT
    /// le nettoyage asynchrone pour qu'une notification ré-entrante (autres requêtes
    /// 401 concurrentes) voie déjà l'état déconnecté et devienne un no-op (pas de
    /// boucle, pas de POST logout qui re-échouerait).
    private func handleSessionExpired() {
        // Mode démo / QA : la session est un utilisateur mock SANS vrai token — tout
        // appel authentifié renvoie 401, ce qui déclencherait à tort une déconnexion.
        // On ne réagit jamais au signal dans ce mode (parité avec le guard de bootstrap).
        guard !AppEnvironment.usesDemoData else { return }
        guard case .authenticated = state else { return }
        state = .loggedOut
        infoMessage = "Ta session a expiré. Reconnecte-toi pour continuer."
        Task {
            // La session HTTP est peut-être déjà invalide, mais le secret de révocation
            // push reste disponible dans le Trousseau et rend la suppression rejouable.
            await AppDelegate.sharedPush?.unregister()
            await service.clearLocalSession()
        }
    }

    /// E2EE-WIPE-02 : centralise tous les passages RÉELS en `.authenticated`. Purge
    /// les clés E2EE de l'ancien compte si l'identité a changé sur cet appareil
    /// (changement de compte sans logout, ex. expiration de session). No-op pour le
    /// même utilisateur → aucune ressaisie du mot de passe E2EE.
    private func setAuthenticated(_ user: AuthUser) async {
        await service.wipeE2EEIfIdentityChanged(to: user.id)
        // Active d'abord le namespace local. Les observers de `state` peuvent lancer
        // immédiatement l'enregistrement push et des reprises de files ; ils doivent
        // tous voir le nouveau propriétaire, jamais le précédent.
        service.cacheUser(user)
        state = .authenticated(user)
    }

    func bootstrap() async {
        if case .authenticated = state { return }
        guard !AppEnvironment.usesDemoData else { return }
        if let injectedAuthToken = AppEnvironment.injectedAuthToken {
            service.installAuthTokenForDebugQA(injectedAuthToken)
        }
        if AppEnvironment.resetsAuthOnLaunch {
            // QA `--reset-auth` : purge LOCALE uniquement (credentials + E2EE).
            // Surtout pas de POST /api/auth/logout : le flag sert aux tours de
            // test UI, et invalider le JWT côté serveur casserait les autres
            // passes QA qui réutilisent le même token injecté.
            await service.clearLocalSessionForDebugQA()
            state = .loggedOut
            return
        }
        // PERF-START-01 : démarrage à froid optimiste. Si on a un token ET un
        // utilisateur en cache, afficher l'app IMMÉDIATEMENT puis revalider
        // `/api/auth/me` en arrière-plan (stale-while-revalidate) au lieu de bloquer
        // l'UI jusqu'à 30 s sur le réseau. La revalidation corrige l'utilisateur
        // affiché et déconnecte proprement si la session a été révoquée.
        if service.hasStoredCredentials(), let cached = service.cachedUser() {
            // Active le namespace local avant que les services lisent leurs caches.
            service.cacheUser(cached)
            state = .authenticated(cached)
            Task { await revalidateSession() }
            return
        }
        do {
            let user = try await service.me()
            await setAuthenticated(user)
        } catch let error as APIError {
            switch error {
            case .http(let status, _, _, _, _) where status == 401 || status == 403:
                state = .loggedOut
                await AppDelegate.sharedPush?.unregister()
                await service.clearLocalSession()
            case .transport, .cancelled:
                // Network problem at launch — keep the session and offer a retry
                // instead of bouncing a logged-in user to the login screen.
                state = service.hasStoredCredentials() ? .offline : .loggedOut
            case .http(let status, _, _, _, _) where status >= 500 || status == 429:
                // Panne / backpressure serveur au lancement : ne pas déconnecter un
                // utilisateur authentifié (le login échouerait aussi). Proposer un
                // réessai via l'écran « offline » plutôt que l'écran de login (ROB-03).
                state = service.hasStoredCredentials() ? .offline : .loggedOut
            default:
                state = .loggedOut
            }
        } catch {
            state = .loggedOut
        }
    }

    /// Revalidation d'arrière-plan après un affichage optimiste (PERF-START-01).
    /// Succès → rafraîchit l'utilisateur affiché ; 401/403 → déconnexion propre ;
    /// réseau/serveur → on conserve l'affichage optimiste (déjà `.authenticated`).
    private func revalidateSession() async {
        do {
            let user = try await service.me()
            await setAuthenticated(user)
        } catch let error as APIError {
            if case .http(let status, _, _, _, _) = error, status == 401 || status == 403 {
                state = .loggedOut
                await AppDelegate.sharedPush?.unregister()
                await service.clearLocalSession()
            }
            // transport / 5xx / annulation : garder l'affichage optimiste.
        } catch {
            // garder l'affichage optimiste.
        }
    }

    func retryBootstrap() async {
        state = .checking
        await bootstrap()
    }

    /// Recharge l'utilisateur courant (/api/auth/me) sans repasser par l'écran de chargement.
    /// Utilisé après un changement de @handle pour rafraîchir l'état (et fermer la modale de
    /// choix de handle). Conserve la session en cas d'échec réseau.
    func refreshUser() async {
        guard case .authenticated = state else { return }
        if let user = try? await service.me() {
            state = .authenticated(user)
            service.cacheUser(user)
        }
    }

    func login(email: String, password: String) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let response = try await service.login(email: email, password: password)
            if response.requires2FA == true, let tempToken = response.tempToken {
                state = .requires2FA(tempToken: tempToken)
            } else if let user = response.user {
                await setAuthenticated(user)
            } else {
                errorMessage = "Réponse auth invalide"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signup(email: String, password: String, name: String, acceptedTerms: Bool) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let response = try await service.signup(
                email: email, password: password, name: name, acceptedTerms: acceptedTerms
            )
            if let user = response.user {
                await setAuthenticated(user)
            } else if response.requires2FA == true, let tempToken = response.tempToken {
                state = .requires2FA(tempToken: tempToken)
            } else {
                errorMessage = "Compte créé mais session non initialisée"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signInWithApple(identityToken: String, fullName: String?) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let response = try await service.signInWithApple(identityToken: identityToken, fullName: fullName)
            if response.requires2FA == true, let tempToken = response.tempToken {
                state = .requires2FA(tempToken: tempToken)
            } else if let user = response.user {
                await setAuthenticated(user)
            } else {
                errorMessage = "Réponse Apple invalide"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func verify2FA(code: String) async {
        guard case .requires2FA(let tempToken) = state else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let response = try await service.verify2FA(tempToken: tempToken, code: code)
            if let user = response.user {
                await setAuthenticated(user)
            } else {
                errorMessage = "Code 2FA accepté mais utilisateur absent"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forgotPassword(email: String) async {
        isBusy = true
        errorMessage = nil
        infoMessage = nil
        defer { isBusy = false }
        do {
            try await service.forgotPassword(email: email)
            infoMessage = "Si l’adresse existe, un lien de réinitialisation t’a été envoyé."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetPassword(token: String, newPassword: String) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await service.resetPassword(token: token, newPassword: newPassword)
            infoMessage = "Mot de passe mis à jour. Connecte-toi avec le nouveau mot de passe."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func enterDemoMode() {
        state = .authenticated(.mock)
    }

    func cancelTwoFactor() {
        state = .loggedOut
    }

    func logout() async {
        let closing = LocalAccountScope.sessionSnapshot()
        // Revoke the push token (while the session is still valid) before the
        // service tears down credentials and E2EE keys.
        await AppDelegate.sharedPush?.unregister()
        guard LocalAccountScope.sessionSnapshot() == closing else { return }
        // CALL-VOIP-05 : révoque aussi le token VoIP côté serveur pour qu'un autre
        // compte sur cet appareil ne reçoive pas les pushes VoIP de l'ancien
        // utilisateur (best-effort, session encore valide ici).
        await AppDelegate.sharedCallManager?.unregisterVoIPToken()
        guard LocalAccountScope.sessionSnapshot() == closing else { return }
        try? await service.logout()
        guard LocalAccountScope.currentUserId == nil else { return }
        state = .loggedOut
    }
}

extension AuthUser {
    static let mock = AuthUser(
        id: "mock-user",
        email: "ios@signalquest.fr",
        name: "SignalQuest iOS",
        handle: "ios",
        handleChangedAt: nil,
        avatarUrl: nil,
        bio: nil,
        role: "user",
        twoFactorEnabled: false,
        notifyMessagesPush: false,
        notifySocialPush: true,
        notifyMessagesInApp: true,
        callsDoNotDisturb: false,
        appleLinked: false
    )
}
