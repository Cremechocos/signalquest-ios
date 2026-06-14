import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case put = "PUT"
    case delete = "DELETE"
}

struct APIEndpoint: Sendable {
    var path: String
    var method: HTTPMethod = .get
    var query: [URLQueryItem] = []
    var headers: [String: String] = [:]
    var body: Data?
    var authenticated: Bool = true
    var baseURL: URL?
    /// When true, the client will NOT attempt an automatic refresh + retry on
    /// 401 responses. Used by the refresh endpoint itself to avoid loops.
    var skipsAutoRefresh: Bool = false
    /// Clé d'idempotence envoyée en en-tête `Idempotency-Key`. Auto-générée pour
    /// les POST (créations) afin qu'un rejeu automatique (retry après refresh 401
    /// ou backoff 429) ne crée pas de doublon côté serveur. Comme elle est portée
    /// par la valeur de l'endpoint, elle reste identique sur tous les rejeux d'une
    /// même requête logique.
    var idempotencyKey: String?

    init(
        path: String,
        method: HTTPMethod = .get,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        authenticated: Bool = true,
        baseURL: URL? = nil,
        skipsAutoRefresh: Bool = false,
        idempotencyKey: String? = nil
    ) {
        self.path = path
        self.method = method
        self.query = query
        self.headers = headers
        self.body = body
        self.authenticated = authenticated
        self.baseURL = baseURL
        self.skipsAutoRefresh = skipsAutoRefresh
        self.idempotencyKey = idempotencyKey ?? (method == .post ? UUID().uuidString : nil)
    }
}
