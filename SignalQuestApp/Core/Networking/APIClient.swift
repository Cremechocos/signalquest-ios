import Foundation
import os

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
    private let refreshState = OSAllocatedUnfairLock<Task<Void, Error>?>(initialState: nil)

    init(
        config: AppConfig = .current,
        credentials: CredentialStore = CredentialStore(),
        session: URLSession = .shared,
        decoder: JSONDecoder = .signalQuest,
        encoder: JSONEncoder = .signalQuest
    ) {
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
        session: URLSession = .shared,
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
        let (data, response) = try await performWithRefresh(endpoint)
        credentials.captureFromResponse(response)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    func request(_ endpoint: APIEndpoint) async throws {
        let (_, response) = try await performWithRefresh(endpoint)
        credentials.captureFromResponse(response)
    }

    /// Variante brute : renvoie le corps de réponse tel quel. Utilisée par les
    /// caches (tuiles) qui stockent les octets et décodent ensuite.
    func requestData(_ endpoint: APIEndpoint) async throws -> Data {
        let (data, response) = try await performWithRefresh(endpoint)
        credentials.captureFromResponse(response)
        return data
    }

    func requestJSON<T: Decodable, Body: Encodable>(
        _ path: String,
        method: HTTPMethod = .post,
        body: Body,
        authenticated: Bool = true
    ) async throws -> T {
        let data = try encoder.encode(body)
        return try await request(
            APIEndpoint(
                path: path,
                method: method,
                headers: ["Content-Type": "application/json"],
                body: data,
                authenticated: authenticated
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

    /// En-têtes d'identité client (X-Client-*) joints à chaque requête 1re partie,
    /// pour que le registre des sessions affiche « iPhone15,3 · iOS 18 » au lieu de
    /// « Navigateur ». Calculés une seule fois (valeurs constantes). On évite UIKit
    /// (`UIDevice` est `@MainActor`) au profit de `ProcessInfo`/`uname`, sûrs hors
    /// du main actor et compatibles concurrence stricte.
    private static let clientInfoHeaders: [String: String] = {
        var headers = ["X-Client-Platform": "ios"]
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        var osLabel = "iOS \(osVersion.majorVersion).\(osVersion.minorVersion)"
        if osVersion.patchVersion > 0 { osLabel += ".\(osVersion.patchVersion)" }
        headers["X-Client-Os"] = osLabel
        if let model = hardwareModelIdentifier(), !model.isEmpty {
            headers["X-Client-Model"] = model
        }
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
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
        if let idempotencyKey = endpoint.idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if endpoint.authenticated, let token = credentials.accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

    private func performWithRefresh(_ endpoint: APIEndpoint, attempt: Int = 0) async throws -> (Data, URLResponse) {
        do {
            return try await perform(endpoint)
        } catch APIError.http(let status, let code, let message, let requestId, let retryAfter) where status == 401 && endpoint.authenticated && !endpoint.skipsAutoRefresh {
            // Try a refresh once, then retry the original request. The endpoint's
            // idempotency key is unchanged, so a replayed POST won't duplicate.
            do {
                try await ensureRefreshed()
            } catch {
                throw APIError.http(status: status, code: code, message: message, requestId: requestId, retryAfter: retryAfter)
            }
            return try await perform(endpoint)
        } catch APIError.http(let status, let code, let message, let requestId, let retryAfter)
            where (status == 429 || status == 503) && attempt < Self.maxThrottleRetries {
            // Rate-limited / unavailable: back off (honoring a reasonable Retry-After)
            // instead of hammering. Long Retry-After → surface the error to the caller.
            guard let delaySeconds = Self.throttleDelaySeconds(retryAfter: retryAfter, attempt: attempt) else {
                throw APIError.http(status: status, code: code, message: message, requestId: requestId, retryAfter: retryAfter)
            }
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            return try await performWithRefresh(endpoint, attempt: attempt + 1)
        }
    }

    private func ensureRefreshed() async throws {
        let task: Task<Void, Error> = refreshState.withLock { existing in
            if let existing { return existing }
            let newTask = Task<Void, Error> { [weak self] in
                guard let self else { return }
                let endpoint = APIEndpoint(
                    path: "/api/auth/refresh",
                    method: .post,
                    authenticated: true,
                    skipsAutoRefresh: true
                )
                let (_, response) = try await self.perform(endpoint)
                self.credentials.captureFromResponse(response)
            }
            existing = newTask
            return newTask
        }
        defer {
            refreshState.withLock { state in
                // Clear the cached task once the in-flight refresh has resolved
                // so the next 401 triggers a fresh attempt.
                state = nil
            }
        }
        try await task.value
    }

    private func perform(_ endpoint: APIEndpoint) async throws -> (Data, URLResponse) {
        let request = try makeURLRequest(endpoint)
        if config.debugLogsEnabled {
            logger.debug("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.absoluteString ?? "-", privacy: .public)")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return (data, response) }
            if (200..<300).contains(http.statusCode) {
                return (data, response)
            }
            throw decodeHTTPError(data: data, response: http)
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
        let message = String(data: data, encoding: .utf8)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        return .http(status: response.statusCode, code: nil, message: message, requestId: headerRequestId, retryAfter: retryAfter)
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }
}
