import Foundation

enum APIError: Error, LocalizedError, Equatable {
    case invalidURL(String)
    case transport(String)
    case http(status: Int, code: String?, message: String, requestId: String?, retryAfter: Int?)
    case decoding(String)
    case missingAuthToken
    case cancelled

    /// Message présenté à l'utilisateur. On n'affiche JAMAIS le `code` technique ni
    /// le `requestId` (réservés aux logs via `diagnosticDescription`), ni les chaînes
    /// système brutes d'URLSession (souvent en anglais). On privilégie un libellé
    /// localisé pour les codes connus, sinon le message serveur (déjà en français),
    /// sinon un repli clair par statut HTTP.
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Adresse invalide. Réessaie plus tard.")
        case .transport:
            if isOffline { return SQOfflineText.message }
            if isTimeout { return String(localized: "Le réseau est absent ou trop lent. Réessaie quand tu as du réseau.") }
            if isServerUnreachable { return SQOfflineText.serverUnreachable }
            return String(localized: "Connexion impossible. Vérifie ta connexion puis réessaie.")
        case .http(let status, let code, let message, _, _):
            return APIError.userFacingMessage(status: status, code: code, serverMessage: message)
        case .decoding:
            return String(localized: "Réponse inattendue du serveur. Réessaie plus tard.")
        case .missingAuthToken:
            return String(localized: "Authentification requise.")
        case .cancelled:
            return String(localized: "Requête annulée.")
        }
    }

    // Le code `URLError` reste dans le détail du transport : les écrans d'erreur
    // distinguent ainsi « hors ligne » (rechargement au retour du réseau) d'une
    // panne quelconque, sans changer la forme du cas `.transport`.
    private static let offlineTag = "offline"
    private static let timeoutTag = "timeout"
    private static let unreachableTag = "unreachable"

    static func transport(from error: Error) -> APIError {
        guard let url = error as? URLError else { return .transport(error.localizedDescription) }
        switch url.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .transport("\(offlineTag): \(url.localizedDescription)")
        case .timedOut:
            return .transport("\(timeoutTag): \(url.localizedDescription)")
        case .cannotConnectToHost:
            return .transport("\(unreachableTag): \(url.localizedDescription)")
        default:
            return .transport(url.localizedDescription)
        }
    }

    /// Le réseau est absent (et non une panne du serveur ou un délai dépassé).
    var isOffline: Bool {
        if case .transport(let detail) = self { return detail.hasPrefix(Self.offlineTag) }
        return false
    }

    /// Aucune réponse dans le délai : réseau absent ou trop lent.
    var isTimeout: Bool {
        if case .transport(let detail) = self { return detail.hasPrefix(Self.timeoutTag) }
        return false
    }

    /// L'appareil a du réseau, mais le serveur refuse ou ignore la connexion :
    /// « hors ligne » accuserait à tort le réseau du membre (lot F, F-32).
    var isServerUnreachable: Bool {
        if case .transport(let detail) = self { return detail.hasPrefix(Self.unreachableTag) }
        return false
    }

    /// Détail technique complet pour les logs — jamais affiché tel quel à l'utilisateur.
    var diagnosticDescription: String {
        switch self {
        case .http(let status, let code, let message, let requestId, let retryAfter):
            return ["HTTP \(status)", code, message,
                    requestId.map { "requestId=\($0)" },
                    retryAfter.map { "retryAfter=\($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
        case .invalidURL(let value):
            return "invalidURL: \(value)"
        case .transport(let value):
            return "transport: \(value)"
        case .decoding(let value):
            return "decoding: \(value)"
        default:
            return errorDescription ?? "\(self)"
        }
    }

    /// Construit le message utilisateur : code connu → libellé localisé ; sinon le
    /// message serveur s'il est lisible (déjà FR) ; sinon repli par statut.
    static func userFacingMessage(status: Int, code: String?, serverMessage: String,
                                  appIsFrench: Bool = appLanguageIsFrench) -> String {
        if let code, let mapped = localizedMessages[code.uppercased()] {
            return mapped
        }
        // Erreurs serveur (5xx) : le corps expose souvent une trace interne (ORM/SQL,
        // stack, ex. « Invalid `prisma.$queryRaw()` invocation »). Ce message n'a aucun
        // sens pour l'utilisateur et ne doit JAMAIS s'afficher : on ignore le message
        // serveur et on retombe sur un repli neutre. Le détail reste dans les logs via
        // `diagnosticDescription`.
        if status >= 500 {
            return statusFallback(status)
        }
        let trimmed = serverMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // Le serveur n'écrit qu'en français : en anglais, son message s'affichait
        // tel quel au milieu d'une app traduite (lot F, F-37).
        if !trimmed.isEmpty, !looksLikeRawCode(trimmed), appIsFrench {
            return trimmed
        }
        return statusFallback(status)
    }

    /// Langue retenue pour l'app, pas celle de la région.
    static var appLanguageIsFrench: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("fr") ?? true
    }

    /// Détecte un identifiant technique renvoyé tel quel (ex. `INVALID_OPERATOR`)
    /// pour ne pas l'afficher brut à l'utilisateur.
    private static func looksLikeRawCode(_ value: String) -> Bool {
        !value.contains(" ") && value == value.uppercased() && value.contains("_")
    }

    /// Repli localisé quand aucun message lisible n'est disponible.
    static func statusFallback(_ status: Int) -> String {
        switch status {
        case 400: return String(localized: "Requête invalide.")
        case 401: return String(localized: "Session expirée. Reconnecte-toi.")
        case 403: return String(localized: "Action non autorisée.")
        case 404: return String(localized: "Élément introuvable.")
        case 408: return String(localized: "Délai dépassé. Réessaie.")
        case 409: return String(localized: "Conflit : l'élément a déjà été modifié ailleurs.")
        case 413: return String(localized: "Le fichier est trop volumineux.")
        case 429: return String(localized: "Trop de requêtes. Patiente un instant avant de réessayer.")
        case 500...599: return String(localized: "Service momentanément indisponible. Réessaie plus tard.")
        default: return String(localized: "Une erreur est survenue. Réessaie.")
        }
    }

    /// Libellés localisés pour les codes d'erreur sémantiques connus du backend.
    /// (Le backend renvoie le plus souvent déjà un message FR ; cette table couvre
    /// les cas où il n'expose qu'un code.)
    private static let localizedMessages: [String: String] = [
        "HANDLE_LOCKED": String(localized: "Ton nom d’utilisateur ne peut pas encore être modifié."),
        "NAME_TOO_LONG": String(localized: "Ce nom est trop long."),
        "EMPTY_NAME": String(localized: "Le nom ne peut pas être vide."),
        "INVALID_OPERATOR": String(localized: "Opérateur invalide."),
        "RATE_LIMITED": String(localized: "Trop de requêtes. Patiente un instant avant de réessayer."),
        "UNAUTHORIZED": String(localized: "Session expirée. Reconnecte-toi."),
        "CAPTCHA_FAILED": String(localized: "La vérification a été refusée. Recommence-la pour continuer."),
        "INVALID_RESET_LINK": String(localized: "Ce lien est invalide ou déjà utilisé. Demande un nouveau lien."),
        "RESET_LINK_ALREADY_USED": String(localized: "Ce lien est invalide ou déjà utilisé. Demande un nouveau lien."),
        "RESET_LINK_EXPIRED": String(localized: "Ce lien a expiré. Demande un nouveau lien."),
        "INVALID_2FA_CODE": String(localized: "Le code est incorrect. Saisis les six chiffres affichés dans ton application d’authentification."),
        "EMAIL_ALREADY_USED": String(localized: "Cette adresse est déjà utilisée. Connecte-toi ou réinitialise ton mot de passe."),
        "ACCOUNT_SUSPENDED": String(localized: "Ton compte est suspendu. Contacte le support SignalQuest pour en savoir plus."),
        // Demandes de message (DM-REQ-1).
        "MESSAGE_REQUEST_PENDING": String(localized: "Ta demande de message n’a pas encore été acceptée."),
        "MESSAGE_REQUEST_LIMIT": String(localized: "Un compte récent peut envoyer 5 demandes de message par jour. Tu pourras écrire demain, ou dès maintenant si la personne t’ajoute en ami."),
        "MESSAGE_REQUEST_NOT_FOUND": String(localized: "Cette demande n’existe plus."),
        "MESSAGE_REQUEST_ALREADY_ACCEPTED": String(localized: "Cette demande a déjà été acceptée."),
        "EMAIL_NOT_VERIFIED": String(localized: "Confirme ton adresse e-mail pour publier ou contacter la communauté. Ouvre le lien reçu ou demande-en un nouveau depuis Profil."),
        // Post écrit par le serveur (lot F) : seule sa visibilité change.
        "GENERATED_POST_READ_ONLY": String(localized: "Cette publication est créée automatiquement : son contenu ne se modifie pas."),

        // Identification d'un site (`/api/android/map/identify/direct`). Le serveur
        // renvoie déjà un message FR pour la plupart ; ceux-ci n'en portent qu'un
        // code, ou un libellé trop technique pour être montré tel quel.
        "MISSING_PLMN": String(localized: "Opérateur du relevé inconnu : impossible de rattacher cette identification."),
        "MISSING_SITE_ID": String(localized: "Aucun site sélectionné."),
        "MISSING_CELL_IDENTIFIERS": String(localized: "Ce relevé ne porte aucun identifiant radio (eNB, gNB ou PCI)."),
        "OPERATOR_NOT_ALLOWED": String(localized: "Ton compte ne peut pas identifier de site chez cet opérateur."),
        "IDENTIFY_SITE_NOT_FOUND": String(localized: "Site introuvable : aucune antenne connue pour cet identifiant."),
        // Correction d'une identification vers un support qui n'existe pas (edit-site, 404).
        "TARGET_SITE_NOT_FOUND": String(localized: "Support introuvable : vérifie son numéro."),
        "VALIDATION_SITE_NOT_FOUND": String(localized: "Site introuvable : aucune antenne connue pour cet identifiant."),
        // Registre officiel (ISED…) momentanément injoignable : le serveur demande
        // d'attendre une quinzaine de secondes, plus que le rejeu automatique.
        "OFFICIAL_ANTENNA_SOURCE_UNAVAILABLE": String(localized: "La source officielle des antennes ne répond pas. Réessaie dans quelques secondes."),
        "IDENTIFY_MARKET_MISMATCH": String(localized: "Ce relevé et cette antenne ne sont pas dans le même pays."),
        "IDENTIFY_OPERATOR_MISMATCH": String(localized: "Ce relevé et cette antenne ne sont pas du même opérateur."),
        "VALIDATION_NODE_SITE_MISMATCH": String(localized: "L'identifiant radio ne correspond pas au site choisi."),
        // Vote sur les identifiants d'un site : on ne rejette pas sa propre identification.
        "CANNOT_REJECT_OWN_IDENTIFICATION": String(localized: "Tu ne peux pas rejeter ta propre identification."),
        // Ces deux-là ne peuvent pas tomber sur les routes en politique `session`
        // (le cookie suffit) : ils sont mappés pour les routes qui, elles, exigent
        // une clé ou une attestation.
        "API_KEY_REQUIRED": String(localized: "Accès refusé : clé d'API requise."),
        "ATTESTATION_FAILED": String(localized: "Application non vérifiée. Mets-la à jour puis réessaie."),
        "FIRST_PARTY_TOKEN_REQUIRED": String(localized: "Application non vérifiée. Mets-la à jour puis réessaie."),

        // Fonction réservée (journal radio synchronisé, durée de story…) : le
        // message reste neutre, chaque écran nomme sa fonction s'il le peut.
        "PREMIUM_REQUIRED": String(localized: "Cette fonction est réservée aux membres Premium."),

        // Routes d'achat (contrat abonnements v1 §3). Un libellé local par code,
        // car un 5xx n'affiche jamais le texte du serveur : sans lui, un achat payé
        // mais pas encore activé ne disait que « Service momentanément indisponible ».
        "PURCHASE_ALREADY_LINKED": String(localized: "Cet abonnement App Store est déjà rattaché à un autre compte SignalQuest. Connecte-toi avec le compte qui l’a souscrit."),
        "SUBSCRIPTION_ALREADY_ACTIVE": String(localized: "Un abonnement est déjà actif sur ton compte : aucun nouvel achat n’est nécessaire."),
        "BILLING_TESTERS_ONLY": String(localized: "Pendant la phase de test, les achats sont réservés aux testeurs. Ton achat sera activé dès l’ouverture des achats, sans nouveau paiement."),
        "BILLING_UNCONFIGURED": String(localized: "Ton achat est bien enregistré par Apple, mais son activation est momentanément impossible. Elle sera retentée automatiquement, sans nouveau paiement."),
        // Ancien nom du même refus, servi par la production jusqu'au lot 1b de Backend.
        "APPLE_BILLING_UNCONFIGURED": String(localized: "Ton achat est bien enregistré par Apple, mais son activation est momentanément impossible. Elle sera retentée automatiquement, sans nouveau paiement."),
        "STORE_UNAVAILABLE": String(localized: "L’App Store ne répond pas pour le moment. Ton achat sera vérifié de nouveau automatiquement, sans nouveau paiement."),
        "PURCHASE_PROOF_INVALID": String(localized: "L’App Store n’a pas pu confirmer cet achat. Il sera vérifié de nouveau automatiquement, sans nouveau paiement."),
        // Ancien nom de la preuve refusée (avec un 401 avant le lot 1b de Backend).
        "APPLE_VERIFY_FAILED": String(localized: "L’App Store n’a pas pu confirmer cet achat. Il sera vérifié de nouveau automatiquement, sans nouveau paiement."),
        "UNKNOWN_PRODUCT": String(localized: "Cette offre n’est pas encore reconnue par SignalQuest. Ton achat sera vérifié de nouveau automatiquement, sans nouveau paiement."),

        // Journal radio synchronisé.
        "TOO_MANY_ITEMS": String(localized: "Trop d'éléments envoyés d'un coup. Réessaie."),

        // Stories (`POST /api/social/stories`) : le serveur ne renvoie que ces
        // codes, sans détail (confirmé le 30/09).
        "EMPTY_STORY": String(localized: "Ajoute un texte, une photo ou ton relevé radio à ta story."),
        "INVALID_STORY_EXPIRATION": String(localized: "Cette durée n'est pas disponible pour une story."),
        "INVALID_STORY": String(localized: "Cette story n'a pas pu être publiée. Vérifie son texte et réessaie."),

        // Discussion d'un site (`/api/site-threads/comments`) : limites des comptes récents.
        "LINKS_NOT_ALLOWED_YET": String(localized: "Les liens sont possibles une fois ton compte âgé de 7 jours. Retire le lien pour publier."),
        "NEW_ACCOUNT_DAILY_LIMIT": String(localized: "Pendant les 7 premiers jours, un compte publie au plus 3 messages par jour. Réessaie demain."),

        // Réseau mobile non pris en charge (SUPPORTED_NETWORK_REQUIRED, 403), par fonction.
        "SUPPORTED_NETWORK_REQUIRED": String(localized: "Cette fonction demande une carte SIM d'un opérateur pris en charge."),
        "SUPPORTED_NETWORK_REQUIRED.LIVE_SHARE": String(localized: "Le partage en direct demande une carte SIM d'un opérateur pris en charge."),
        "SUPPORTED_NETWORK_REQUIRED.SESSION_SHARE": String(localized: "Le partage d'une session demande une carte SIM d'un opérateur pris en charge."),
        "SUPPORTED_NETWORK_REQUIRED.COVERAGE": String(localized: "L'envoi de la couverture demande une carte SIM d'un opérateur pris en charge."),
        "SUPPORTED_NETWORK_REQUIRED.COVERAGE_IMPORT": String(localized: "L'import d'une session de couverture demande une carte SIM d'un opérateur pris en charge."),
        "SUPPORTED_NETWORK_REQUIRED.IDENTIFY": String(localized: "L'identification d'un site demande une carte SIM d'un opérateur pris en charge."),
    ]
}

struct BackendErrorResponse: Codable {
    let error: String?
    let code: String?
    let requestId: String?
    let details: [String: JSONValue]?
    /// Raison d'un `403 E2EE_DEVICE_REVOKED` (E2EE-AUTO §4.3), au premier niveau.
    let reason: String?
    /// Fonction refusée d'un `403 SUPPORTED_NETWORK_REQUIRED`
    /// (`contracts/errors/supported-network-required-v1.json`).
    let feature: String?

    /// Code retenu par l'app. Un refus « réseau non pris en charge » porte la
    /// fonction concernée (`SUPPORTED_NETWORK_REQUIRED.LIVE_SHARE`) pour que le
    /// message la nomme ; une fonction inconnue garde le code nu, donc le
    /// message générique. À ne pas confondre avec `OPERATOR_REQUIRED` (FAV-1).
    var appCode: String? {
        // CONV-MEMBERSHIP r1 : un 403 « plus membre » d'une conversation dit sa cause
        // (`details.membership`) ; l'app la porte dans le code, `FORBIDDEN.MEMBERSHIP.left`.
        if code == "FORBIDDEN", case .string(let membership)? = details?["membership"], !membership.isEmpty {
            let returns = membership == "deleted_for_self" && details?["returnsOnNewMessage"] == .bool(true)
            return Self.membershipPrefix + membership + (returns ? Self.membershipReturnsSuffix : "")
        }
        guard code == Self.supportedNetworkRequired,
              let feature = feature?.lowercased(),
              Self.supportedNetworkFeatures.contains(feature) else { return code }
        return "\(Self.supportedNetworkRequired).\(feature.uppercased())"
    }

    static let membershipPrefix = "FORBIDDEN.MEMBERSHIP."
    static let membershipReturnsSuffix = ".returns"
    static let supportedNetworkRequired = "SUPPORTED_NETWORK_REQUIRED"
    static let supportedNetworkFeatures: Set<String> = ["live_share", "session_share", "coverage", "coverage_import", "identify"]
}

extension Error {
    /// Vrai si l'erreur est une annulation de tâche/requête. Ces erreurs
    /// surviennent quand un chargement est REMPLACÉ (pan de carte, changement de
    /// filtre, changement d'onglet) et ne doivent JAMAIS être affichées comme un
    /// échec à l'utilisateur (sinon : « Requête annulée », « Feed indisponible »…).
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let api = self as? APIError, api == .cancelled { return true }
        if let url = self as? URLError, url.code == .cancelled { return true }
        return false
    }

    /// Vrai si le serveur a refusé la requête pour de bon : la rejouer à
    /// l'identique échouera toujours (droits retirés, conversation supprimée,
    /// contenu invalide…). Une file d'envoi doit alors retirer l'élément au lieu
    /// de le garder en tête et de bloquer tout ce qui suit (SOC-02, SOC-04).
    ///
    /// Restent temporaires : 401 (session à renouveler), 408 (délai), 425 et
    /// 429 (trop tôt, trop de requêtes), et toute erreur réseau ou 5xx.
    /// `409 E2EE_AUTO_REQUIRED` : après la bascule, le serveur refuse un texte en clair
    /// ou v1. La conversation doit passer en auto et le texte repartir en v2 (E2EE-AUTO §7.2).
    var isAutoEncryptionRequired: Bool {
        guard let api = self as? APIError, case .http(409, let code, _, _, _) = api else { return false }
        return code == "E2EE_AUTO_REQUIRED"
    }

    var isPermanentRequestFailure: Bool {
        guard let api = self as? APIError, case .http(let status, let code, _, _, _) = api else { return false }
        // DM-REQ-1 : le plafond quotidien de demandes est une décision du serveur, pas une panne passagère.
        if status == 429, code == MessageRequestLimitError.code { return true }
        return (400..<500).contains(status) && ![401, 408, 425, 429].contains(status)
    }

    /// Message à montrer pour n'importe quelle erreur. Celles qui savent se dire
    /// (API, speedtest, réglages…) gardent leur texte ; une erreur interne sans
    /// description affichait sinon « L’opération n’a pas pu s’achever.
    /// (SignalQuest.E2EEV2MessageCryptoError erreur 3.) » (TRX-26, SOC-29).
    var userFacingMessage: String {
        if let url = self as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return SQOfflineText.message
            case .timedOut:
                return String(localized: "Le serveur met trop de temps à répondre. Réessaie.")
            case .cannotConnectToHost:
                return SQOfflineText.serverUnreachable
            default:
                return String(localized: "Connexion impossible. Vérifie ta connexion puis réessaie.")
            }
        }
        if let described = (self as? LocalizedError)?.errorDescription, !described.isEmpty {
            return described
        }
        // Erreurs système (Photos, Keychain, CallKit…) : leur texte est déjà
        // traduit par iOS, on le garde.
        let bridged = self as NSError
        if bridged.userInfo[NSLocalizedDescriptionKey] is String {
            return bridged.localizedDescription
        }
        if self is E2EEV2MessageCryptoError || self is E2EEV2EpochCryptoError
            || self is E2EEV2BlobCryptoError || self is E2EEV2SignedRequestError {
            return String(localized: "Le chiffrement n’a pas abouti. Réessaie dans un instant.")
        }
        return String(localized: "Une erreur inattendue est survenue. Réessaie.")
    }
}

/// Texte unique d'une panne de connexion : `ErrorStateView` le reconnaît pour
/// présenter l'état hors ligne plutôt qu'une erreur (TRX-10).
enum SQOfflineText {
    static var message: String { String(localized: "Pas de connexion Internet. Vérifie ton réseau puis réessaie.") }
    static var serverUnreachable: String { String(localized: "SignalQuest ne répond pas pour le moment. Ta connexion fonctionne : réessaie dans un instant.") }
}
