import Foundation
import os

extension Notification.Name {
    /// Émis quand une requête AUTHENTIFIÉE reçoit un 401 que le refresh n'a PAS pu
    /// récupérer (session réellement expirée : cookie JWT périmé, pas de refresh
    /// glissant). `AuthSessionViewModel` l'observe pour re-router globalement vers
    /// l'écran de login au lieu de laisser des écritures échouer en silence (ROB-02).
    static let sqAuthSessionExpired = Notification.Name("fr.signalquest.ios.authSessionExpired")
}

/// Le contexte est vérifié à l'émission ET lorsque le main actor traite le
/// signal. Une notification déjà en file ne doit jamais déconnecter le compte B.
struct AuthSessionExpiration: Sendable {
    let credentials: CredentialStore
    let snapshot: CredentialStore.Snapshot
    let localSession: LocalAccountSession?

    var isCurrent: Bool {
        credentials.isCurrent(snapshot, matchingRevision: true)
            && LocalAccountScope.sessionSnapshot() == localSession
    }
}

protocol APIClientProtocol: Sendable {
    func request<T: Decodable>(_ endpoint: APIEndpoint, as type: T.Type) async throws -> T
    func request(_ endpoint: APIEndpoint) async throws
    func uploadMultipart<T: Decodable>(
        path: String,
        fields: [String: String],
        fileField: String,
        fileName: String,
        mimeType: String,
        data: Data,
        as type: T.Type
    ) async throws -> T
}

final class APIClient: APIClientProtocol, @unchecked Sendable {
    let config: AppConfig
    let credentials: CredentialStore
    let cookieStore: AuthCookieStore
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "APIClient")
    /// Coalesces concurrent refresh attempts so we hit /api/auth/refresh once
    /// even if several requests 401 at the same time.
    private struct RefreshAttempt {
        let sessionID: UUID
        let task: Task<Void, Error>
    }
    private let refreshState = OSAllocatedUnfairLock<RefreshAttempt?>(initialState: nil)
    private struct Response {
        let data: Data
        let context: CredentialStore.Snapshot
    }
    private struct SingleAttemptResponse {
        let data: Data
        let response: HTTPURLResponse
        let context: CredentialStore.Snapshot
    }

    /// Session propriétaire du client.
    ///
    /// `URLSession.shared` partageait `HTTPCookieStorage.shared` avec tout le
    /// processus : l'authentification dépendait alors d'un cookie ambiant plutôt
    /// que de l'en-tête posé explicitement, ce qui rendait le comportement
    /// difficile à raisonner (un appel marqué non authentifié partait quand même
    /// avec le cookie) et laissait un cookie survivre à un `clearAll()`.
    ///
    /// `httpCookieStorage = nil` supprime structurellement ce risque. La
    /// politique de cache reste `.useProtocolCachePolicy` : le backend renvoie
    /// un `Cache-Control` utile sur les lectures publiques (photos, tuiles), le
    /// désactiver globalement dégraderait la carte et la galerie.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    init(
        config: AppConfig = .current,
        credentials: CredentialStore = CredentialStore(),
        session: URLSession? = nil,
        decoder: JSONDecoder = .signalQuest,
        encoder: JSONEncoder = .signalQuest
    ) {
        let session = session ?? Self.makeSession()
        self.config = config
        self.credentials = credentials
        self.cookieStore = AuthCookieStore(credentials: credentials)
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
    }

    /// Legacy initializer used by tests that still pass `AuthCookieStore`.
    convenience init(
        config: AppConfig = .current,
        cookieStore: AuthCookieStore,
        session: URLSession? = nil,
        decoder: JSONDecoder = .signalQuest,
        encoder: JSONEncoder = .signalQuest
    ) {
        self.init(
            config: config,
            credentials: cookieStore.credentials,
            session: session,
            decoder: decoder,
            encoder: encoder
        )
    }

    // MARK: Public surface

    func request<T: Decodable>(_ endpoint: APIEndpoint, as type: T.Type) async throws -> T {
        let expected = credentials.snapshot().sessionID
        return try await request(endpoint, as: type, expectedSessionID: expected)
    }

    func request<T: Decodable>(_ endpoint: APIEndpoint, as type: T.Type, expectedSessionID: UUID?) async throws -> T {
        let context = credentials.snapshot()
        guard expectedSessionID == nil || context.sessionID == expectedSessionID else { throw APIError.cancelled }
        let result = try await performWithRefresh(endpoint, context: context)
        guard credentials.isCurrent(result.context) else { throw APIError.cancelled }
        let decoded: T
        do {
            decoded = try decoder.decode(T.self, from: result.data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
        guard credentials.isCurrent(result.context) else { throw APIError.cancelled }
        return decoded
    }

    func request(_ endpoint: APIEndpoint) async throws {
        let result = try await performWithRefresh(endpoint, context: credentials.snapshot())
        guard credentials.isCurrent(result.context) else { throw APIError.cancelled }
    }

    /// Variante brute : renvoie le corps de réponse tel quel. Utilisée par les
    /// caches (tuiles) qui stockent les octets et décodent ensuite.
    func requestData(_ endpoint: APIEndpoint, expectedSessionID: UUID? = nil) async throws -> Data {
        let context = credentials.snapshot()
        guard expectedSessionID == nil || context.sessionID == expectedSessionID else { throw APIError.cancelled }
        let result = try await performWithRefresh(endpoint, context: context)
        guard credentials.isCurrent(result.context) else { throw APIError.cancelled }
        return result.data
    }

    /// Tentative réseau brute et unique. Contrairement à `request`, cette voie
    /// ne rafraîchit pas la session, ne rejoue pas les 429/503 et ne transforme
    /// pas les statuts HTTP non-2xx en erreur. Elle est réservée aux requêtes
    /// signées dont le nonce ne doit jamais être réutilisé par un retry opaque.
    func performSingleAttempt(
        _ endpoint: APIEndpoint,
        fixedAuthToken: String? = nil,
        expectedSession: LocalAccountSession? = nil,
        expectedCredentialSessionID: UUID? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard expectedSession?.isCurrent != false else { throw APIError.cancelled }
        let context = credentials.snapshot()
        guard expectedCredentialSessionID == nil || context.sessionID == expectedCredentialSessionID else { throw APIError.cancelled }
        try await validateTransmissionAdmission(endpoint, context: context)
        guard expectedSession?.isCurrent != false else { throw APIError.cancelled }
        var request = try makeURLRequest(endpoint, credentials: context)
        if let fixedAuthToken {
            request.setValue("auth_token=\(fixedAuthToken)", forHTTPHeaderField: "Cookie")
            request.httpShouldHandleCookies = false
        }
        guard expectedSession?.isCurrent != false else { throw APIError.cancelled }
        let result = try await performSingleAttempt(request, context: context,
            captureCredentials: expectedSession == nil, startsNewSession: !endpoint.authenticated) { request in
            try await self.session.data(for: request)
        }
        guard expectedSession?.isCurrent != false else { throw APIError.cancelled }
        guard credentials.isCurrent(result.context) else { throw APIError.cancelled }
        return (result.data, result.response)
    }

    /// Variante fichier de la tentative unique. Le corps doit être absent de
    /// l'endpoint : URLSession lit le fichier fourni sans le charger intégralement
    /// en mémoire, ce qui convient aux parties média E2EE déjà chiffrées.
    func uploadFileSingleAttempt(
        _ endpoint: APIEndpoint,
        fromFile fileURL: URL
    ) async throws -> (Data, HTTPURLResponse) {
        guard endpoint.body == nil else {
            throw APIError.transport("single-attempt-upload-body-must-be-file")
        }
        let context = credentials.snapshot()
        try await validateTransmissionAdmission(endpoint, context: context)
        let request = try makeURLRequest(endpoint, credentials: context)
        let result = try await performSingleAttempt(request, context: context,
            startsNewSession: !endpoint.authenticated) { request in
            try await self.session.upload(for: request, fromFile: fileURL)
        }
        guard credentials.isCurrent(result.context) else { throw APIError.cancelled }
        return (result.data, result.response)
    }

    func requestJSON<T: Decodable, Body: Encodable>(
        _ path: String,
        method: HTTPMethod = .post,
        body: Body,
        authenticated: Bool = true,
        idempotencyKey: String? = nil
    ) async throws -> T {
        let data = try encoder.encode(body)
        return try await request(
            APIEndpoint(
                path: path,
                method: method,
                headers: ["Content-Type": "application/json"],
                body: data,
                authenticated: authenticated,
                idempotencyKey: idempotencyKey
            ),
            as: T.self
        )
    }

    func requestJSON<Body: Encodable>(
        _ path: String,
        method: HTTPMethod = .post,
        body: Body,
        authenticated: Bool = true
    ) async throws {
        let data = try encoder.encode(body)
        try await request(
            APIEndpoint(
                path: path,
                method: method,
                headers: ["Content-Type": "application/json"],
                body: data,
                authenticated: authenticated
            )
        )
    }

    func uploadMultipart<T: Decodable>(
        path: String,
        fields: [String: String],
        fileField: String,
        fileName: String,
        mimeType: String,
        data: Data,
        as type: T.Type
    ) async throws -> T {
        let boundary = "SignalQuest-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")

        return try await request(
            APIEndpoint(
                path: path,
                method: .post,
                headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
                body: body,
                authenticated: true
            ),
            as: T.self
        )
    }

    // MARK: URL building

    static func appVersionLabel(shortVersion: String?, build: String?) -> String? {
        guard let version = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else { return nil }
        guard let build = build?.trimmingCharacters(in: .whitespacesAndNewlines),
              !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    /// En-têtes d'identité client (X-Client-*) joints à chaque requête 1re partie,
    /// pour que le registre des sessions affiche « iPhone15,3 · iOS 18 » au lieu de
    /// « Navigateur ». Calculés une seule fois (valeurs constantes). On évite UIKit
    /// (`UIDevice` est `@MainActor`) au profit de `ProcessInfo`/`uname`, sûrs hors
    /// du main actor et compatibles concurrence stricte.
    private static let clientInfoHeaders: [String: String] = {
        var headers = [
            "X-Client-Platform": "ios",
            ClientProtocolContract.protocolVersionHeader: String(ClientProtocolContract.currentProtocolVersion),
            ClientProtocolContract.capabilitiesHeaderName: ClientProtocolContract.capabilitiesHeader,
        ]
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        var osLabel = "iOS \(osVersion.majorVersion).\(osVersion.minorVersion)"
        if osVersion.patchVersion > 0 { osLabel += ".\(osVersion.patchVersion)" }
        headers["X-Client-Os"] = osLabel
        if let model = hardwareModelIdentifier(), !model.isEmpty {
            headers["X-Client-Model"] = model
        }
        if let version = appVersionLabel(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ) {
            headers["X-Client-App-Version"] = version
        }
        return headers
    }()

    /// Identifiant matériel (ex. « iPhone15,3 »), via `uname` — sûr hors main actor.
    private static func hardwareModelIdentifier() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { result, element in
            if let value = element.value as? Int8, value != 0 {
                result.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
        return identifier.isEmpty ? nil : identifier
    }

    func makeURLRequest(_ endpoint: APIEndpoint) throws -> URLRequest {
        try makeURLRequest(endpoint, credentials: credentials.snapshot())
    }

    private func makeURLRequest(_ endpoint: APIEndpoint, credentials snapshot: CredentialStore.Snapshot) throws -> URLRequest {
        let base = endpoint.baseURL ?? config.apiBaseURL
        guard var components = URLComponents(
            url: base.appendingPathComponent(endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidURL(endpoint.path)
        }
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query
        }
        guard let url = components.url else { throw APIError.invalidURL(endpoint.path) }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.httpBody = endpoint.body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SignalQuest-iOS/1", forHTTPHeaderField: "User-Agent")
        for (key, value) in Self.clientInfoHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        endpoint.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let cacheDirectives = endpoint.headers.first {
            $0.key.caseInsensitiveCompare("Cache-Control") == .orderedSame
        }?.value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        if cacheDirectives.contains("no-cache") || cacheDirectives.contains("no-store") || cacheDirectives.contains("max-age=0") {
            // Les caches métier décident déjà de leur fraîcheur. Une lecture
            // réseau demandée ne doit pas recycler un ancien 200 de URLCache.
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        if let idempotencyKey = endpoint.idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        request.httpShouldHandleCookies = false
        if endpoint.authenticated, let token = snapshot.accessToken {
            // Le backend n'authentifie QUE par le cookie `auth_token`
            // (`extractAuthToken` dans packages/db/auth.ts) ; l'en-tête
            // Authorization n'est lu que par `requireAdmin` et le secret
            // interne. Envoyer le JWT utilisateur en Bearer n'apportait rien et
            // doublait sa surface d'exposition (journaux de proxy, APM, traces).
            request.setValue("auth_token=\(token)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    // MARK: Throttling (429/503)

    /// Nombre maximal de rejeux automatiques sur rate-limit.
    static let maxThrottleRetries = 1
    /// Plafond de délai qu'on accepte d'attendre automatiquement. Au-delà, on ne
    /// rejoue pas (on remonte l'erreur) pour ne pas bloquer un appel UI plusieurs
    /// dizaines de secondes : c'est au code appelant de décider.
    static let maxAutoRetryDelaySeconds: Double = 3.0

    /// Délai d'attente avant rejeu sur 429/503, ou `nil` si l'on ne doit pas
    /// rejouer automatiquement. Respecte `Retry-After` quand il est raisonnable,
    /// sinon applique un backoff exponentiel borné avec gigue (anti thundering-herd).
    static func throttleDelaySeconds(retryAfter: Int?, attempt: Int) -> Double? {
        if let retryAfter {
            let seconds = Double(max(0, retryAfter))
            return seconds <= maxAutoRetryDelaySeconds ? seconds : nil
        }
        let base = 0.25 * pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...0.25)
        return min(base + jitter, maxAutoRetryDelaySeconds)
    }

    // MARK: Internals

    private func performWithRefresh(
        _ endpoint: APIEndpoint,
        context: CredentialStore.Snapshot,
        attempt: Int = 0
    ) async throws -> Response {
        let sent = try credentials.snapshot(forSession: context)
        do {
            return try await perform(endpoint, context: sent)
        } catch APIError.http(let status, _, _, _, _) where status == 401 && endpoint.authenticated && !endpoint.skipsAutoRefresh {
            // Try a refresh once, then retry the original request. The endpoint's
            // idempotency key is unchanged, so a replayed POST won't duplicate.
            do {
                try await ensureRefreshed(after: sent)
            } catch {
                // Seul un refus d'authentification du refresh prouve l'expiration.
                // Réseau coupé, 429, 5xx et annulation gardent leur nature : les
                // appelants ne doivent pas transformer une panne en déconnexion.
                guard credentials.isCurrent(sent) else { throw APIError.cancelled }
                if case APIError.http(let refreshStatus, _, _, _, _) = error,
                   refreshStatus == 401 || refreshStatus == 403 {
                    guard credentials.isCurrent(sent, matchingRevision: true) else { throw APIError.cancelled }
                    notifySessionExpired(for: sent)
                }
                throw error
            }
            let retryContext = try credentials.snapshot(forSession: sent)
            do {
                return try await perform(endpoint, context: retryContext)
            } catch APIError.http(let retryStatus, let retryCode, let retryMessage, let retryRequestId, let retryRetryAfter) where retryStatus == 401 {
                // Refresh « réussi » mais le token reste rejeté → session morte.
                guard credentials.isCurrent(retryContext, matchingRevision: true) else { throw APIError.cancelled }
                notifySessionExpired(for: retryContext)
                throw APIError.http(status: retryStatus, code: retryCode, message: retryMessage, requestId: retryRequestId, retryAfter: retryRetryAfter)
            }
        } catch APIError.http(let status, let code, let message, let requestId, let retryAfter)
            where (status == 429 || status == 503) && attempt < Self.maxThrottleRetries {
            // Rate-limited / unavailable: back off (honoring a reasonable Retry-After)
            // instead of hammering. Long Retry-After → surface the error to the caller.
            guard let delaySeconds = Self.throttleDelaySeconds(retryAfter: retryAfter, attempt: attempt) else {
                throw APIError.http(status: status, code: code, message: message, requestId: requestId, retryAfter: retryAfter)
            }
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            return try await performWithRefresh(endpoint, context: context, attempt: attempt + 1)
        }
    }

    /// Force un rafraîchissement du token d'accès (coalescé avec tout refresh en
    /// cours via `refreshState`). Le flux SSE ne passe pas par
    /// `performWithRefresh` : après un 401 il appelle ceci pour réactualiser le
    /// token avant de rouvrir le flux (SSE-API-07). Silencieux : un échec de
    /// refresh laisse simplement la reconnexion suivante échouer puis reboucler.
    func refreshSession() async {
        try? await ensureRefreshed(after: credentials.snapshot())
    }

    /// Diffuse « session expirée » (ROB-02). `NotificationCenter` est thread-safe ;
    /// l'observateur (AuthSessionViewModel) rebascule sur le main actor. Idempotent :
    /// plusieurs posts rapprochés se résolvent en un seul passage `.loggedOut`.
    private func notifySessionExpired(for snapshot: CredentialStore.Snapshot) {
        guard snapshot.accessToken != nil else { return }
        let expiration = AuthSessionExpiration(credentials: credentials, snapshot: snapshot,
            localSession: LocalAccountScope.sessionSnapshot())
        guard expiration.isCurrent else { return }
        NotificationCenter.default.post(name: .sqAuthSessionExpired, object: expiration)
    }

    private func ensureRefreshed(after rejected: CredentialStore.Snapshot) async throws {
        let current = try credentials.snapshot(forSession: rejected)
        // Une autre requête a déjà renouvelé le token rejeté : utiliser ce token
        // pour le rejeu sans lancer un deuxième refresh.
        guard current.revision == rejected.revision else { return }
        let task: Task<Void, Error> = refreshState.withLock { existing in
            if let existing, existing.sessionID == rejected.sessionID { return existing.task }
            let newTask = Task<Void, Error> { [weak self] in
                guard let self else { throw APIError.cancelled }
                let latest = try self.credentials.snapshot(forSession: rejected)
                guard latest.revision == rejected.revision else { return }
                let endpoint = APIEndpoint(
                    path: "/api/auth/refresh",
                    method: .post,
                    authenticated: true,
                    skipsAutoRefresh: true
                )
                _ = try await self.perform(endpoint, context: latest)
            }
            existing = RefreshAttempt(sessionID: rejected.sessionID, task: newTask)
            return newTask
        }
        defer {
            refreshState.withLock { state in
                // Ne purger QUE si le slot contient encore NOTRE tâche.
                //
                // Le `defer` s'exécute pour chaque appelant, y compris ceux qui
                // ont simplement rejoint un refresh déjà en vol. Scénario de
                // casse : A et B rejoignent T1 ; T1 se termine ; A purge ; C
                // arrive et installe T2 ; B exécute alors SON defer et purge T2
                // alors qu'elle est encore en vol ; D lance T3 → deux refresh
                // concurrents. Sur un backend qui fait tourner la session, cela
                // se solde par une déconnexion.
                if state?.task == task { state = nil }
            }
        }
        try await task.value
        guard credentials.isCurrent(rejected) else { throw APIError.cancelled }
    }

    /// La politique peut attendre un autre acteur : contrôler de nouveau la
    /// session et l'annulation avant de construire la requête. Un refus local
    /// n'est jamais un HTTP 503 susceptible de déclencher un retry automatique.
    private func validateTransmissionAdmission(_ endpoint: APIEndpoint,
                                               context: CredentialStore.Snapshot) async throws {
        guard !Task.isCancelled else { throw APIError.cancelled }
        guard credentials.isCurrent(context) else { throw APIError.cancelled }
        if let admission = endpoint.validateBeforeSend {
            do { try await admission() } catch { throw APIError.cancelled }
            guard !Task.isCancelled else { throw APIError.cancelled }
            guard credentials.isCurrent(context) else { throw APIError.cancelled }
        }
    }

    private func perform(_ endpoint: APIEndpoint, context: CredentialStore.Snapshot) async throws -> Response {
        try await validateTransmissionAdmission(endpoint, context: context)
        let request = try makeURLRequest(endpoint, credentials: context)
        if config.debugLogsEnabled {
            logger.debug("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.absoluteString ?? "-", privacy: .public)")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard credentials.isCurrent(context) else { throw APIError.cancelled }
        } catch is CancellationError {
            throw APIError.cancelled
        } catch let error as APIError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession lève `URLError(.cancelled)` (et NON `CancellationError`)
            // quand une requête est annulée (pan de carte, changement d'onglet,
            // rechargement). On la normalise en `.cancelled` pour qu'elle soit
            // filtrée par `isCancellation` et JAMAIS affichée comme un échec.
            throw APIError.cancelled
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return Response(data: data, context: context)
        }
        guard (200..<300).contains(http.statusCode) else { throw decodeHTTPError(data: data, response: http) }
        // L'échec de persistance du token reste une erreur de stockage, pas un
        // faux succès auth ni une panne réseau (contrat de connexion existant).
        let captured = try credentials.captureFromResponse(response, for: context, startsNewSession: !endpoint.authenticated)
        return Response(data: data, context: captured)
    }

    private func performSingleAttempt(
        _ request: URLRequest,
        context: CredentialStore.Snapshot,
        captureCredentials: Bool = true,
        startsNewSession: Bool = false,
        operation: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> SingleAttemptResponse {
        if config.debugLogsEnabled {
            logger.debug("single-attempt \(request.httpMethod ?? "GET", privacy: .public) \(request.url?.absoluteString ?? "-", privacy: .public)")
        }
        do {
            try Task.checkCancellation()
            guard credentials.isCurrent(context) else { throw APIError.cancelled }
            let (data, response) = try await operation(request)
            try Task.checkCancellation()
            guard credentials.isCurrent(context) else { throw APIError.cancelled }
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("non-http-response")
            }
            let captured = captureCredentials && (200..<300).contains(http.statusCode)
                ? try credentials.captureFromResponse(response, for: context, startsNewSession: startsNewSession)
                : context
            return SingleAttemptResponse(data: data, response: http, context: captured)
        } catch is CancellationError {
            throw APIError.cancelled
        } catch let error as APIError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw APIError.cancelled
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    private func decodeHTTPError(data: Data, response: HTTPURLResponse) -> APIError {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
        let headerRequestId = response.value(forHTTPHeaderField: "X-Request-Id")
        if let decoded = try? decoder.decode(BackendErrorResponse.self, from: data) {
            return .http(
                status: response.statusCode,
                code: decoded.code,
                message: decoded.error ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                requestId: decoded.requestId ?? headerRequestId,
                retryAfter: retryAfter
            )
        }
        // SEC-ERR-03 : la réponse n'est pas un BackendErrorResponse structuré
        // (ex. page HTML d'un proxy, 502 brut). On NE propage PAS le corps brut —
        // `message` vide → APIError.userFacingMessage repliera sur un libellé FR par
        // statut (statusFallback) au lieu d'exposer du contenu serveur arbitraire.
        return .http(status: response.statusCode, code: nil, message: "", requestId: headerRequestId, retryAfter: retryAfter)
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }
}
