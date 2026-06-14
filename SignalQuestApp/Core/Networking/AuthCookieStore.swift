import Foundation

/// Legacy facade kept for source-level compatibility. New code should use
/// `CredentialStore` directly.
final class AuthCookieStore: @unchecked Sendable {
    let credentials: CredentialStore

    init(credentials: CredentialStore = CredentialStore()) {
        self.credentials = credentials
    }

    convenience init(tokenStore: TokenStore) {
        self.init(credentials: CredentialStore(tokenStore: tokenStore))
    }

    func authToken() -> String? { credentials.accessToken() }
    func cookieHeader() -> String? { credentials.accessToken().map { "auth_token=\($0)" } }
    func store(token: String) throws { try credentials.setAccessToken(token) }
    func clear() { credentials.clearAll() }

    @discardableResult
    func captureAuthToken(from response: URLResponse) -> String? {
        credentials.captureFromResponse(response)
    }

    static func parseAuthToken(from setCookie: String?) -> String? {
        CredentialStore.parseAuthToken(from: setCookie)
    }
}
