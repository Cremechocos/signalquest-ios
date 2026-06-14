import Foundation

enum APIError: Error, LocalizedError, Equatable {
    case invalidURL(String)
    case transport(String)
    case http(status: Int, code: String?, message: String, requestId: String?, retryAfter: Int?)
    case decoding(String)
    case missingAuthToken
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "URL invalide: \(value)"
        case .transport(let value):
            return value
        case .http(_, let code, let message, let requestId, _):
            return [code, message, requestId.map { "requestId=\($0)" }].compactMap { $0 }.joined(separator: " - ")
        case .decoding(let value):
            return "Decodage impossible: \(value)"
        case .missingAuthToken:
            return "Authentification requise"
        case .cancelled:
            return "Requete annulee"
        }
    }
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

