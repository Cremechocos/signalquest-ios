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
            return "Adresse invalide. Réessaie plus tard."
        case .transport:
            return "Connexion impossible. Vérifie ta connexion puis réessaie."
        case .http(let status, let code, let message, _, _):
            return APIError.userFacingMessage(status: status, code: code, serverMessage: message)
        case .decoding:
            return "Réponse inattendue du serveur. Réessaie plus tard."
        case .missingAuthToken:
            return "Authentification requise."
        case .cancelled:
            return "Requête annulée."
        }
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
    static func userFacingMessage(status: Int, code: String?, serverMessage: String) -> String {
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
        if !trimmed.isEmpty, !looksLikeRawCode(trimmed) {
            return trimmed
        }
        return statusFallback(status)
    }

    /// Détecte un identifiant technique renvoyé tel quel (ex. `INVALID_OPERATOR`)
    /// pour ne pas l'afficher brut à l'utilisateur.
    private static func looksLikeRawCode(_ value: String) -> Bool {
        !value.contains(" ") && value == value.uppercased() && value.contains("_")
    }

    /// Repli localisé quand aucun message lisible n'est disponible.
    static func statusFallback(_ status: Int) -> String {
        switch status {
        case 400: return "Requête invalide."
        case 401: return "Session expirée. Reconnecte-toi."
        case 403: return "Action non autorisée."
        case 404: return "Élément introuvable."
        case 408: return "Délai dépassé. Réessaie."
        case 409: return "Conflit : l'élément a déjà été modifié ailleurs."
        case 413: return "Le fichier est trop volumineux."
        case 429: return "Trop de requêtes. Patiente un instant avant de réessayer."
        case 500...599: return "Service momentanément indisponible. Réessaie plus tard."
        default: return "Une erreur est survenue. Réessaie."
        }
    }

    /// Libellés localisés pour les codes d'erreur sémantiques connus du backend.
    /// (Le backend renvoie le plus souvent déjà un message FR ; cette table couvre
    /// les cas où il n'expose qu'un code.)
    private static let localizedMessages: [String: String] = [
        "HANDLE_LOCKED": "Ton identifiant ne peut pas encore être modifié.",
        "NAME_TOO_LONG": "Ce nom est trop long.",
        "EMPTY_NAME": "Le nom ne peut pas être vide.",
        "INVALID_OPERATOR": "Opérateur invalide.",
        "RATE_LIMITED": "Trop de requêtes. Patiente un instant avant de réessayer.",
        "UNAUTHORIZED": "Session expirée. Reconnecte-toi.",
    ]
}

struct BackendErrorResponse: Codable {
    let error: String?
    let code: String?
    let requestId: String?
    let details: [String: JSONValue]?
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
}

