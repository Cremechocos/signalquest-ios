import Foundation

struct AuthUser: Codable, Identifiable, Equatable {
    let id: String
    let email: String
    let name: String?
    let handle: String?
    let avatarUrl: URL?
    let role: String
    let twoFactorEnabled: Bool?
    let notifyMessagesPush: Bool?
    let notifyMessagesInApp: Bool?
    let callsDoNotDisturb: Bool?

    var displayName: String {
        name ?? handle.map { "@\($0)" } ?? email.components(separatedBy: "@").first ?? "Utilisateur"
    }
}

// MARK: - Login / signup

struct LoginRequest: Codable {
    let email: String
    let password: String
}

struct SignupRequest: Codable {
    let email: String
    let password: String
    let name: String
}

struct LoginResponse: Codable {
    let user: AuthUser?
    let requires2FA: Bool?
    let tempToken: String?
}

// MARK: - 2FA

struct TwoFactorVerifyRequest: Codable {
    let tempToken: String
    let code: String
}

struct TwoFactorSetupResponse: Codable {
    /// Base32 TOTP secret returned by the server, ready for an authenticator app.
    let secret: String
    /// `otpauth://totp/...` URI que l'on rend en QR code. Le backend renvoie la
    /// clé JSON `uri` (et NON `otpauthUrl`) — un mauvais nom laissait le QR vide.
    let uri: String?
}

struct TwoFactorVerifySetupRequest: Codable {
    let secret: String
    let code: String
}

struct TwoFactorDisableRequest: Codable {
    let code: String
}

// MARK: - Password

struct ForgotPasswordRequest: Codable {
    let email: String
}

struct ResetPasswordRequest: Codable {
    let token: String
    let password: String
}

struct ChangePasswordRequest: Codable {
    let currentPassword: String
    let newPassword: String
}

// MARK: - Common

struct AuthMeResponse: Codable {
    /// Optionnel : le backend renvoie `{ user: null }` (HTTP 200) quand la session
    /// est invalide — décoder en non-optionnel faisait planter le bootstrap.
    let user: AuthUser?
}

struct SuccessResponse: Codable {
    let success: Bool?
    let ok: Bool?
    let requestId: String?
}
