import Foundation

protocol AuthServicing: Sendable {
    func login(email: String, password: String) async throws -> LoginResponse
    func signup(email: String, password: String, name: String) async throws -> LoginResponse
    func verify2FA(tempToken: String, code: String) async throws -> LoginResponse
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
}

extension AuthServicing {
    func installAuthTokenForDebugQA(_ token: String) {}
    func hasStoredCredentials() -> Bool { false }
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

    func bootstrap() async {
        if case .authenticated = state { return }
        guard !AppEnvironment.usesDemoData else { return }
        if let injectedAuthToken = AppEnvironment.injectedAuthToken {
            service.installAuthTokenForDebugQA(injectedAuthToken)
        }
        if AppEnvironment.resetsAuthOnLaunch {
            try? await service.logout()
            state = .loggedOut
            return
        }
        do {
            let user = try await service.me()
            state = .authenticated(user)
        } catch let error as APIError {
            switch error {
            case .http(let status, _, _, _, _) where status == 401 || status == 403:
                state = .loggedOut
            case .transport, .cancelled:
                // Network problem at launch — keep the session and offer a retry
                // instead of bouncing a logged-in user to the login screen.
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
                state = .authenticated(user)
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
                state = .authenticated(user)
            } else if response.requires2FA == true, let tempToken = response.tempToken {
                state = .requires2FA(tempToken: tempToken)
            } else {
                errorMessage = "Compte créé mais session non initialisée"
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
                state = .authenticated(user)
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
        role: "user",
        twoFactorEnabled: false,
        notifyMessagesPush: false,
        notifyMessagesInApp: true,
        callsDoNotDisturb: false
    )
}
