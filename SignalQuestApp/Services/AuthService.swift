import Foundation

protocol AuthServicing: Sendable {
    func login(email: String, password: String) async throws -> LoginResponse
    func signup(email: String, password: String, name: String) async throws -> LoginResponse
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
    /// E2EE-WIPE-02 : purge les clés E2EE si l'utilisateur authentifié diffère du
    /// dernier connu sur cet appareil (changement de compte sans logout, ex.
    /// expiration de session). À appeler avant de passer en `.authenticated`.
    func wipeE2EEIfIdentityChanged(to userId: String) async
}

extension AuthServicing {
    func installAuthTokenForDebugQA(_ token: String) {}
    func clearLocalSessionForDebugQA() async {}
    func hasStoredCredentials() -> Bool { false }
    func wipeE2EEIfIdentityChanged(to userId: String) async {}
}

final class AuthService: AuthServicing {
    private let api: APIClient
    private let e2ee: E2EEServicing?

    init(api: APIClient, e2ee: E2EEServicing? = nil) {
        self.api = api
        self.e2ee = e2ee
    }

    // MARK: Login / signup

    func login(email: String, password: String) async throws -> LoginResponse {
        try await api.requestJSON(
            "/api/auth/login",
            body: LoginRequest(email: email, password: password),
            authenticated: false
        )
    }

    func signup(email: String, password: String, name: String) async throws -> LoginResponse {
        try await api.requestJSON(
            "/api/auth/signup",
            body: SignupRequest(email: email, password: password, name: name),
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
        _ = try? await api.request(
            APIEndpoint(path: "/api/auth/logout", method: .post),
            as: SuccessResponse.self
        )
        // Erase end-to-end encryption material before clearing the session so a
        // different account on this device can never reuse the keys.
        await e2ee?.wipeLocalKeys()
        api.credentials.clearAll()
    }

    func clearLocalSessionForDebugQA() async {
        // Même purge locale que `logout()`, sans l'appel serveur : le JWT reste
        // valide pour les autres passes QA (tours UI avec token injecté).
        await e2ee?.wipeLocalKeys()
        api.credentials.clearAll()
    }

    func wipeE2EEIfIdentityChanged(to userId: String) async {
        // `lastUserId` vit dans le Keychain AUTH ("fr.signalquest.ios"), distinct
        // du store E2EE wipé → il survit au wipe et aux redémarrages, ce qui permet
        // de détecter un changement de compte même après une expiration de session.
        let store = KeychainStore()
        let last = try? store.string(for: "lastUserId")
        if let last, last != userId {
            await e2ee?.wipeLocalKeys()
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

    init(service: AuthServicing) {
        self.service = service
        if AppEnvironment.usesDemoData {
            state = .authenticated(AuthUser.mock)
        }
    }

    /// E2EE-WIPE-02 : centralise tous les passages RÉELS en `.authenticated`. Purge
    /// les clés E2EE de l'ancien compte si l'identité a changé sur cet appareil
    /// (changement de compte sans logout, ex. expiration de session). No-op pour le
    /// même utilisateur → aucune ressaisie du mot de passe E2EE.
    private func setAuthenticated(_ user: AuthUser) async {
        await service.wipeE2EEIfIdentityChanged(to: user.id)
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
        do {
            let user = try await service.me()
            await setAuthenticated(user)
        } catch let error as APIError {
            switch error {
            case .http(let status, _, _, _, _) where status == 401 || status == 403:
                state = .loggedOut
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

    func signup(email: String, password: String, name: String) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let response = try await service.signup(email: email, password: password, name: name)
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
        // Revoke the push token (while the session is still valid) before the
        // service tears down credentials and E2EE keys.
        await AppDelegate.sharedPush?.unregister()
        // CALL-VOIP-05 : révoque aussi le token VoIP côté serveur pour qu'un autre
        // compte sur cet appareil ne reçoive pas les pushes VoIP de l'ancien
        // utilisateur (best-effort, session encore valide ici).
        await AppDelegate.sharedCallManager?.unregisterVoIPToken()
        try? await service.logout()
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
        notifyMessagesInApp: true,
        callsDoNotDisturb: false,
        appleLinked: false
    )
}
