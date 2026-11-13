import Foundation

struct AuthUser: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let email: String
    /// `nil` = ancienne API sans ce champ ; ne jamais l'interpréter comme un
    /// compte non confirmé pendant le déploiement progressif du backend.
    var emailVerified: Bool? = nil
    private(set) var name: String?
    private(set) var handle: String?
    /// Horodatage ISO du dernier changement de @handle (null = jamais changé). Sert au
    /// cooldown de 30 j côté UI. Décodé en String pour rester indépendant de la stratégie
    /// de dates du décodeur.
    private(set) var handleChangedAt: String?
    /// Identité membre v1 : `nil` tant que le membre n'a ni gardé ni choisi son nom
    /// d'utilisateur depuis l'écran d'explication. Le changement est alors gratuit.
    var handleConfirmedAt: String? = nil
    let avatarUrl: URL?
    /// Bio de profil. Peut être absente de `/api/auth/me` ; rechargée via
    /// `/api/user/profile` pour préremplir l'édition sans l'écraser (EDITPROFILE-BUG-01).
    let bio: String?
    let role: String
    private(set) var twoFactorEnabled: Bool?
    let notifyMessagesPush: Bool?
    /// Interactions du fil PUBLIC : commentaires, réponses, mentions, réactions, abonnements.
    /// Séparé de `notifyMessagesPush`, qui les portait toutes sous un libellé ne parlant que des
    /// messages privés — 150 des 169 porteurs de jeton les avaient ainsi coupées sans le savoir.
    let notifySocialPush: Bool?
    let notifyMessagesInApp: Bool?
    let callsDoNotDisturb: Bool?
    /// Vrai si un Apple ID est associé à ce compte (Sign in with Apple).
    let appleLinked: Bool?

    func withConfirmedTwoFactor(enabled: Bool) -> AuthUser {
        var copy = self
        copy.twoFactorEnabled = enabled
        return copy
    }

    /// Identité renvoyée par `PUT /api/user/profile` : nom affiché, nom d'utilisateur et
    /// confirmation repris ; le reste (2FA, e-mail vérifié) gardé, cette réponse pouvant ne pas
    /// le porter.
    func withIdentity(of updated: AuthUser) -> AuthUser {
        var copy = self
        copy.name = updated.name
        copy.handle = updated.handle
        copy.handleChangedAt = updated.handleChangedAt
        copy.handleConfirmedAt = updated.handleConfirmedAt
        return copy
    }

    /// Nom affiché, sinon @nom d'utilisateur, sinon « Quelqu'un » : jamais l'e-mail, ce nom
    /// pouvant être montré à d'autres membres.
    var displayName: String { MemberIdentity.displayName(name, handle: handle) }

    var isEmailVerificationPending: Bool { emailVerified == false }

    /// L'écran « Ton nom d'utilisateur » est dû : nom d'utilisateur ni gardé ni choisi.
    var needsHandleConfirmation: Bool {
        handleConfirmedAt?.isEmpty != false || (handle ?? "").isEmpty
    }
}

extension AuthUser {
    private enum Keys: String, CodingKey {
        case id, email, emailVerified, name, handle, handleChangedAt, handleConfirmedAt, avatarUrl, bio, role
        case twoFactorEnabled, notifyMessagesPush, notifySocialPush, notifyMessagesInApp
        case callsDoNotDisturb, appleLinked
    }

    /// Seul `id` est indispensable : une URL d'avatar vide ou invalide, un champ
    /// absent ou d'un autre type ne doivent pas bloquer la connexion ni le démarrage.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func optional<T: Decodable>(_ type: T.Type, _ key: Keys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        id = try c.decode(String.self, forKey: .id)
        email = optional(String.self, .email) ?? ""
        emailVerified = optional(Bool.self, .emailVerified)
        name = optional(String.self, .name)
        handle = optional(String.self, .handle)
        handleChangedAt = optional(String.self, .handleChangedAt)
        handleConfirmedAt = optional(String.self, .handleConfirmedAt)
        avatarUrl = c.decodeLossyURL(forKey: .avatarUrl)
        bio = optional(String.self, .bio)
        role = optional(String.self, .role) ?? "user"
        twoFactorEnabled = optional(Bool.self, .twoFactorEnabled)
        notifyMessagesPush = optional(Bool.self, .notifyMessagesPush)
        notifySocialPush = optional(Bool.self, .notifySocialPush)
        notifyMessagesInApp = optional(Bool.self, .notifyMessagesInApp)
        callsDoNotDisturb = optional(Bool.self, .callsDoNotDisturb)
        appleLinked = optional(Bool.self, .appleLinked)
    }
}

// MARK: - Login / signup

/// Identité membre v1 : `identifier` est un e-mail ou un nom d'utilisateur (`email` reste un
/// alias côté serveur, pour les anciennes versions).
struct LoginRequest: Codable {
    let identifier: String
    let password: String
}

struct SignupRequest: Codable {
    let email: String
    let password: String
    /// Nom d'utilisateur, obligatoire dans l'app ; le serveur le vérifie libre avant de créer le
    /// compte. Le nom affiché, facultatif, se propose plus tard.
    let handle: String
    /// Consentement clickwrap aux CGU et à la politique de confidentialité.
    ///
    /// Le backend n'écrit `acceptedTermsVersion` / `acceptedTermsAt` QUE si ce
    /// champ est présent. Il ne l'était pas : aucun compte créé depuis iOS ne
    /// portait de trace de consentement, alors que la case était bien affichée
    /// et bloquait le bouton. Exigence RGPD, et attendu par la revue App Store
    /// sur la guideline EULA.
    let acceptedTerms: Bool
    var turnstileToken: String? = nil
}

struct AppleLinkResponse: Decodable {
    let appleLinked: Bool?
}

struct LoginResponse: Codable, Sendable {
    let user: AuthUser?
    let requires2FA: Bool?
    let tempToken: String?
}

// MARK: - 2FA

struct TwoFactorVerifyRequest: Codable {
    let tempToken: String
    let code: String
}

struct TwoFactorSetupResponse: Codable, Sendable {
    /// Base32 TOTP secret returned by the server, ready for an authenticator app.
    let secret: String
    /// `otpauth://totp/...` URI que l'on rend en QR code. Le backend renvoie la
    /// clé JSON `uri` (et NON `otpauthUrl`) — un mauvais nom laissait le QR vide.
    let uri: String?
    /// Le challenge serveur est limité dans le temps. Absent sur un ancien backend.
    let expiresAt: Date?

    init(secret: String, uri: String? = nil, expiresAt: Date? = nil) {
        self.secret = secret
        self.uri = uri
        self.expiresAt = expiresAt
    }
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
    var turnstileToken: String? = nil
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

struct AuthMeResponse: Codable, Sendable {
    /// Optionnel : le backend renvoie `{ user: null }` (HTTP 200) quand la session
    /// est invalide — décoder en non-optionnel faisait planter le bootstrap.
    let user: AuthUser?
}

struct SuccessResponse: Codable, Sendable {
    let success: Bool?
    let ok: Bool?
    let requestId: String?

    /// Un corps vide ou contradictoire n'est pas un accusé de mutation.
    var isAcknowledged: Bool {
        (success == true || ok == true) && success != false && ok != false
    }
}
