import Foundation

struct TwoFactorEnrollmentScope: Identifiable, Equatable, Sendable {
    let userID: String
    let account: LocalAccountSession
    let credentialSessionID: UUID
    var id: UUID { credentialSessionID }
}

protocol TwoFactorEnrollmentServicing: Sendable {
    var scope: TwoFactorEnrollmentScope { get }
    func isCurrent() -> Bool
    func setup() async throws -> TwoFactorSetupResponse
    func confirm(secret: String, code: String) async throws
    func profile() async throws -> AuthUser
}

enum TwoFactorEnrollmentError: Error, LocalizedError, Equatable {
    case sessionChanged
    case invalidSetup
    case invalidCode
    case expiredSetup
    case replacedSetup
    case alreadyEnabled
    case unconfirmedDisableResponse
    case unconfirmedResponse
    case profileNotReady

    var errorDescription: String? {
        switch self {
        case .sessionChanged: return String(localized: "La session a changé. Rouvre la configuration depuis les réglages du compte.")
        case .invalidSetup: return String(localized: "La configuration reçue est invalide. Réessaie pour obtenir un nouveau secret.")
        case .invalidCode: return String(localized: "Le code est incorrect. Saisis les six chiffres affichés dans ton application d’authentification.")
        case .expiredSetup: return String(localized: "Cette configuration a expiré. Génère un nouveau QR code avant de réessayer.")
        case .replacedSetup: return String(localized: "Cette configuration a été remplacée. Génère un nouveau QR code.")
        case .alreadyEnabled: return String(localized: "La double authentification est déjà activée pour ce compte. Actualise son état.")
        case .unconfirmedDisableResponse: return String(localized: "La désactivation n’a pas pu être confirmée. Actualise le compte avant de réessayer.")
        case .unconfirmedResponse: return String(localized: "L’activation n’a pas pu être confirmée. Réessaie avec un nouveau code.")
        case .profileNotReady: return String(localized: "Le profil ne reflète pas encore l’activation. Réessaie l’actualisation du compte.")
        }
    }
}

/// Captured at the opening gesture, not after the sheet's first suspension.
/// The secret never leaves the credential/account generation that requested it.
final class TwoFactorEnrollmentService: TwoFactorEnrollmentServicing, Identifiable {
    let scope: TwoFactorEnrollmentScope
    var id: UUID { scope.id }
    private let api: APIClient
    private let accountSnapshot: @Sendable () -> LocalAccountSession?

    init?(api: APIClient, userID: String,
          accountSnapshot: @escaping @Sendable () -> LocalAccountSession? = LocalAccountScope.sessionSnapshot) {
        let credentials = api.credentials.snapshot()
        guard let token = credentials.accessToken, let account = accountSnapshot(),
              account.ownerScopeId == "user:\(userID)", account.matchesAuthToken(token),
              api.credentials.isCurrent(credentials), accountSnapshot() == account else { return nil }
        self.scope = TwoFactorEnrollmentScope(userID: userID, account: account, credentialSessionID: credentials.sessionID)
        self.api = api
        self.accountSnapshot = accountSnapshot
    }

    func isCurrent() -> Bool {
        let credentials = api.credentials.snapshot()
        return accountSnapshot() == scope.account && credentials.sessionID == scope.credentialSessionID
            && credentials.accessToken.map(scope.account.matchesAuthToken) == true
    }

    private func requireCurrent() throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw TwoFactorEnrollmentError.sessionChanged }
    }

    func setup() async throws -> TwoFactorSetupResponse {
        let data = try await singleAttempt(path: "/api/auth/2fa/setup")
        let value: TwoFactorSetupResponse
        do { value = try JSONDecoder.signalQuest.decode(TwoFactorSetupResponse.self, from: data) }
        catch { throw TwoFactorEnrollmentError.invalidSetup }
        guard (16...128).contains(value.secret.count), value.secret.unicodeScalars.allSatisfy({
            (65...90).contains($0.value) || (50...55).contains($0.value)
        }) else { throw TwoFactorEnrollmentError.invalidSetup }
        try requireCurrent()
        return value
    }

    func confirm(secret: String, code: String) async throws {
        guard Self.validCode(code) else { throw TwoFactorEnrollmentError.invalidCode }
        let body = try JSONEncoder.signalQuest.encode(TwoFactorVerifySetupRequest(secret: secret, code: code))
        let data = try await singleAttempt(path: "/api/auth/2fa/verify-setup", body: body)
        guard let response = try? JSONDecoder.signalQuest.decode(SuccessResponse.self, from: data), response.isAcknowledged else {
            throw TwoFactorEnrollmentError.unconfirmedResponse
        }
        try requireCurrent()
    }

    func disable(code: String) async throws {
        guard Self.validCode(code) else { throw TwoFactorEnrollmentError.invalidCode }
        let body = try JSONEncoder.signalQuest.encode(TwoFactorDisableRequest(code: code))
        let data = try await singleAttempt(path: "/api/auth/2fa/disable", body: body)
        guard let response = try? JSONDecoder.signalQuest.decode(SuccessResponse.self, from: data), response.isAcknowledged else {
            throw TwoFactorEnrollmentError.unconfirmedDisableResponse
        }
        try requireCurrent()
    }

    func profile() async throws -> AuthUser {
        try requireCurrent()
        let value = try await api.request(APIEndpoint(path: "/api/auth/me", validateBeforeSend: { [weak self] in
            guard let self else { throw TwoFactorEnrollmentError.sessionChanged }
            try self.requireCurrent()
        }), as: AuthMeResponse.self, expectedSessionID: scope.credentialSessionID)
        try requireCurrent()
        guard let user = value.user, user.id == scope.userID else { throw TwoFactorEnrollmentError.sessionChanged }
        return user
    }

    /// Setup rotates a pending secret; confirmation consumes it. Neither mutation
    /// is replayed automatically after 401/503 or an ambiguous network failure.
    private func singleAttempt(path: String, body: Data? = nil) async throws -> Data {
        try requireCurrent()
        let (data, response) = try await api.performSingleAttempt(APIEndpoint(path: path, method: .post,
            headers: ["Content-Type": "application/json"], body: body, validateBeforeSend: { [weak self] in
                guard let self else { throw TwoFactorEnrollmentError.sessionChanged }
                try self.requireCurrent()
            }), expectedCredentialSessionID: scope.credentialSessionID)
        try requireCurrent()
        guard (200..<300).contains(response.statusCode) else {
            let failure = try? JSONDecoder.signalQuest.decode(FailureResponse.self, from: data)
            switch failure?.code {
            case "INVALID_2FA_CODE": throw TwoFactorEnrollmentError.invalidCode
            case "TWO_FACTOR_SETUP_EXPIRED", "TWO_FACTOR_SETUP_REQUIRED": throw TwoFactorEnrollmentError.expiredSetup
            case "INVALID_2FA_SETUP": throw TwoFactorEnrollmentError.replacedSetup
            case "TWO_FACTOR_ALREADY_ENABLED": throw TwoFactorEnrollmentError.alreadyEnabled
            default:
                throw APIError.http(status: response.statusCode, code: failure?.code,
                    message: "", requestId: response.value(forHTTPHeaderField: "X-Request-Id"),
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
            }
        }
        return data
    }

    static func validCode(_ code: String) -> Bool {
        code.count == 6 && code.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    private struct FailureResponse: Decodable { let code: String? }
}
