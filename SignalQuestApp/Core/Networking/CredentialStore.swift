import Foundation

/// Holds the JWT credentials used to authenticate against signalquest.fr.
/// The backend currently reads the token from the `auth_token` cookie, but we
/// keep an abstraction that lets us also emit an `Authorization: Bearer …`
/// header and add a refresh-token slot for when the backend gains support.
final class CredentialStore: @unchecked Sendable {
    private enum Key {
        static let accessToken = "auth_token"
        static let refreshToken = "refresh_token"
        static let tempToken = "temp_token"
    }

    private let tokenStore: TokenStore
    private let lock = NSLock()

    /// Une connexion/déconnexion explicite ouvre une nouvelle génération, même
    /// si le même compte se reconnecte. Un renouvellement HTTP ne la change pas.
    struct Snapshot: Equatable, Sendable {
        let sessionID: UUID
        let revision: UUID
        let accessToken: String?
    }
    private var sessionID = UUID()
    private var revision = UUID()

    init(tokenStore: TokenStore = KeychainStore()) {
        self.tokenStore = tokenStore
    }

    // MARK: Access token

    // PERF-KEY-02 : cache mémoire du token d'accès. `accessToken()` est appelé pour
    // CHAQUE requête authentifiée (des dizaines par pan de carte) ; sans cache, chaque
    // appel faisait une lecture Keychain (IPC securityd). Le Keychain reste la source
    // persistante ; le cache est tenu à jour sur TOUS les chemins d'écriture.
    private var _cachedAccessToken: String?
    func accessToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        return accessTokenLocked()
    }

    private func accessTokenLocked() -> String? {
        // Fast path : ne sert QUE un token présent depuis le cache. Un cache vide/nil
        // relit toujours le Keychain (source de vérité) — on ne fige jamais un « nil »
        // (sinon un token écrit après un premier accès resterait invisible). PERF-KEY-02.
        if let cached = _cachedAccessToken { return cached }
        let token = try? tokenStore.string(for: Key.accessToken)
        _cachedAccessToken = token
        return token
    }

    func setAccessToken(_ token: String) throws {
        try lock.withLock {
            try tokenStore.set(token, for: Key.accessToken)
            _cachedAccessToken = token
            sessionID = UUID()
            revision = UUID()
        }
        E2EEV2NotificationContextEvents.requestRefresh(.credentials)
    }

    func clearAccessToken() {
        lock.withLock {
            try? tokenStore.remove(Key.accessToken)
            _cachedAccessToken = nil
            sessionID = UUID()
            revision = UUID()
        }
        E2EEV2NotificationContextEvents.revoke()
    }

    func snapshot() -> Snapshot {
        lock.withLock { snapshotLocked() }
    }

    private func snapshotLocked() -> Snapshot {
        Snapshot(sessionID: sessionID, revision: revision, accessToken: accessTokenLocked())
    }

    func isCurrent(_ snapshot: Snapshot, matchingRevision: Bool = false) -> Bool {
        lock.withLock {
            sessionID == snapshot.sessionID && (!matchingRevision || revision == snapshot.revision)
        }
    }

    /// Autorise la rotation du token, jamais le passage à une autre connexion.
    func snapshot(forSession expected: Snapshot) throws -> Snapshot {
        try lock.withLock {
            guard sessionID == expected.sessionID else { throw APIError.cancelled }
            return snapshotLocked()
        }
    }

    // MARK: Refresh token (reserved)

    func refreshToken() -> String? {
        try? tokenStore.string(for: Key.refreshToken)
    }

    func setRefreshToken(_ token: String) throws {
        try tokenStore.set(token, for: Key.refreshToken)
    }

    // MARK: Temp 2FA token (in-memory only)

    private var _tempToken: String?

    var tempToken: String? {
        lock.lock(); defer { lock.unlock() }
        return _tempToken
    }

    func setTempToken(_ token: String?) {
        lock.lock(); defer { lock.unlock() }
        _tempToken = token
    }

    // MARK: Bulk

    func clearAll() {
        lock.withLock {
            try? tokenStore.remove(Key.accessToken)
            try? tokenStore.remove(Key.refreshToken)
            _cachedAccessToken = nil
            _tempToken = nil
            sessionID = UUID()
            revision = UUID()
        }
        // SEC-AUTH-02 : URLSession.shared stocke aussi le cookie `auth_token` reçu
        // en Set-Cookie dans HTTPCookieStorage.shared et le ré-émet automatiquement.
        // Sans cette purge, le cookie survit au logout (le token Keychain est
        // pourtant effacé) et peut ré-authentifier des requêtes.
        Self.purgeAuthCookies()
        E2EEV2NotificationContextEvents.revoke()
    }

    /// Supprime les cookies du domaine signalquest.fr de HTTPCookieStorage.shared.
    /// Match STRICT du domaine (un `cookie.domain` peut débuter par un point) pour
    /// ne pas confondre avec un domaine malveillant type `evil-signalquest.fr.x.com`.
    static func purgeAuthCookies() {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if domain == "signalquest.fr" || domain.hasSuffix(".signalquest.fr") {
                storage.deleteCookie(cookie)
            }
        }
    }

    // MARK: Capture from response

    /// Captures `auth_token` from any `Set-Cookie` header on the response and
    /// stores it as the access token.
    @discardableResult
    func captureFromResponse(_ response: URLResponse) throws -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        // `allHeaderFields` conserve une casse dépendante du transport/runtime
        // (`Set-Cookie`, `Set-cookie`, etc.). L'accesseur Foundation est le seul
        // contrat réellement insensible à la casse.
        let setCookie = http.value(forHTTPHeaderField: "Set-Cookie")
        guard let token = Self.parseAuthToken(from: setCookie) else { return nil }
        // Ne jamais annoncer une session authentifiée si le JWT n'a pas pu être
        // persisté : la première requête parallèle partirait sans cookie, ferait
        // 401 et déconnecterait aussitôt l'utilisateur.
        try setAccessToken(token)
        return token
    }

    /// Comparaison ET persistance sous le même verrou : une réponse tardive ne
    /// peut pas écraser le token d'une nouvelle connexion. Une ancienne rotation
    /// de la même session est ignorée si un token plus récent a déjà été reçu.
    @discardableResult
    func captureFromResponse(
        _ response: URLResponse,
        for expected: Snapshot,
        startsNewSession: Bool = false
    ) throws -> Snapshot {
        let token = (response as? HTTPURLResponse).flatMap {
            Self.parseAuthToken(from: $0.value(forHTTPHeaderField: "Set-Cookie"))
        }
        let (changed, captured): (Bool, Snapshot) = try lock.withLock {
            guard sessionID == expected.sessionID else { throw APIError.cancelled }
            guard let token else { return (false, snapshotLocked()) }
            guard revision == expected.revision else {
                if startsNewSession { throw APIError.cancelled }
                return (false, snapshotLocked())
            }
            try tokenStore.set(token, for: Key.accessToken)
            _cachedAccessToken = token
            revision = UUID()
            if startsNewSession { sessionID = UUID() }
            return (true, snapshotLocked())
        }
        if changed { E2EEV2NotificationContextEvents.requestRefresh(.credentials) }
        return captured
    }

    static func parseAuthToken(from setCookie: String?) -> String? {
        guard let setCookie else { return nil }
        for part in setCookie.components(separatedBy: ",") {
            let segments = part.components(separatedBy: ";")
            guard let first = segments.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if first.hasPrefix("auth_token=") {
                let value = String(first.dropFirst("auth_token=".count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
