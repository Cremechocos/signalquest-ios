import Foundation
import os

/// Client Server-Sent Events minimal pour les flux temps réel du backend
/// (`/api/messages/conversations/{id}/events`). Parité avec le client Android
/// (`streamConversationEvents`) : on n'émet que le NOM de l'événement — le
/// payload n'est jamais appliqué directement, il déclenche un re-sync via le
/// polling delta, ce qui évite toute divergence d'état.
final class SSEClient: Sendable {
    private let api: APIClient
    private let session: URLSession
    private let logger = Logger(subsystem: "fr.signalquest.ios", category: "SSE")

    /// Événements relayés — même liste qu'Android.
    private static let knownEvents: Set<String> = [
        "update", "message", "read_state", "feature_sync", "thread_reply",
        "poll_created", "poll_voted", "poll_closed",
        "task_created", "task_updated", "task_completed",
        "mention", "typing", "viewing", "reaction"
    ]

    init(api: APIClient) {
        self.api = api
        self.session = URLSession(configuration: Self.makeSessionConfiguration())
    }

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        // Même frontière que APIClient : aucune persistance de cookies/cache entre
        // comptes. L'Authorization est portée explicitement par la requête signée.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Un flux SSE reste ouvert indéfiniment : pas de timeout de ressource,
        // mais un timeout de requête généreux pour détecter les connexions mortes.
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = .infinity
        return configuration
    }

    /// Flux des noms d'événements SSE pour une conversation. Se reconnecte
    /// automatiquement (backoff 1,5 s → 30 s). Se termine quand la Task qui le
    /// consomme est annulée.
    func events(path: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task { [api, session, logger] in
                var backoff: Double = 1.5
                while !Task.isCancelled {
                    do {
                        var request = try api.makeURLRequest(APIEndpoint(path: path))
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.timeoutInterval = 90

                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else { continue }
                        if http.statusCode == 401 {
                            // Token expiré : le flux SSE ne passe pas par
                            // `performWithRefresh`, donc on déclenche explicitement
                            // le refresh (coalescé) AVANT de reboucler. Sans cela la
                            // conversation cesserait de recevoir le temps réel
                            // jusqu'à ce qu'une autre requête API rafraîchisse le
                            // token. (SSE-API-07)
                            await api.refreshSession()
                            throw APIError.http(status: 401, code: nil, message: "SSE non autorisé", requestId: nil, retryAfter: nil)
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            throw APIError.http(status: http.statusCode, code: nil, message: "SSE refusé", requestId: nil, retryAfter: nil)
                        }

                        backoff = 1.5
                        var parser = SSEFrameParser()
                        for try await byte in bytes {
                            if Task.isCancelled { break }
                            if let frame = try parser.append(byte) {
                                let name = frame.event.lowercased()
                                if Self.knownEvents.contains(name) { continuation.yield(name) }
                            }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        // Refus DÉFINITIF (403 membre retiré, 404 ressource disparue) :
                        // inutile de reboucler toutes les 30 s vers un endpoint qui
                        // refusera toujours — on arrête proprement (ROB-10).
                        if case APIError.http(let status, _, _, _, _) = error, status == 403 || status == 404 {
                            logger.debug("SSE refusé (\(status, privacy: .public)) — arrêt de la reconnexion")
                            break
                        }
                        logger.debug("SSE interrompu: \(error.localizedDescription, privacy: .public)")
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 30)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Flux `(event, data)` d'un endpoint SSE qui transporte son ÉTAT dans le corps
    /// `data:` (ex. carte des amis `/api/social/map/stream`, event `snapshot`).
    /// Contrairement à `events(path:)` — calqué sur la messagerie et qui ne relaie
    /// que le NOM de l'événement — on accumule ici les lignes `data:` et on renvoie
    /// le payload complet. Ne relaie que les événements de `keep`. Ignore les lignes
    /// de commentaire SSE (`: heartbeat`). Reconnexion auto (backoff 1,5 s → 30 s) ;
    /// se termine à l'annulation de la Task consommatrice.
    func dataStream(
        path: String,
        query: [URLQueryItem] = [],
        keep: Set<String>,
        bufferingPolicy: AsyncStream<(event: String, data: String)>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<(event: String, data: String)> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let task = Task { [api, session, logger] in
                var backoff: Double = 1.5
                while !Task.isCancelled {
                    do {
                        var request = try api.makeURLRequest(APIEndpoint(path: path, query: query))
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.timeoutInterval = 90

                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else { continue }
                        if http.statusCode == 401 {
                            await api.refreshSession()
                            throw APIError.http(status: 401, code: nil, message: "SSE non autorisé", requestId: nil, retryAfter: nil)
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            throw APIError.http(status: http.statusCode, code: nil, message: "SSE refusé", requestId: nil, retryAfter: nil)
                        }

                        backoff = 1.5
                        var parser = SSEFrameParser()
                        for try await byte in bytes {
                            if Task.isCancelled { break }
                            if let frame = try parser.append(byte) {
                                let name = frame.event.lowercased()
                                if !frame.data.isEmpty, keep.contains(name) {
                                    continuation.yield((event: name, data: frame.data))
                                }
                            }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        // Refus définitif (403/404) : arrêt de la reconnexion (ROB-10).
                        if case APIError.http(let status, _, _, _, _) = error, status == 403 || status == 404 {
                            logger.debug("SSE data refusé (\(status, privacy: .public)) — arrêt de la reconnexion")
                            break
                        }
                        logger.debug("SSE data interrompu: \(error.localizedDescription, privacy: .public)")
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 30)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// SSE framing must retain empty lines; AsyncBytes.lines omits them.
/// The limit bounds both an unterminated line and accumulated event data.
struct SSEFrameParser {
    struct Frame: Equatable, Sendable { let event: String; let data: String }
    enum Failure: Error { case oversizedFrame }
    private var line: [UInt8] = []
    private var data: [String] = []
    private var event: String?
    private var wasCR = false
    private var firstLine = true
    private var size = 0
    private let limit: Int

    init(limit: Int = 1_048_576) { self.limit = limit }

    mutating func append(_ byte: UInt8) throws -> Frame? {
        if wasCR && byte == 10 { wasCR = false; return nil }
        wasCR = byte == 13
        size += 1
        guard size <= limit else { throw Failure.oversizedFrame }
        guard byte == 10 || byte == 13 else { line.append(byte); return nil }
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty {
            let result = data.isEmpty ? nil : Frame(event: event?.isEmpty == false ? event! : "message", data: data.joined(separator: "\n"))
            data.removeAll(keepingCapacity: true); event = nil; size = 0
            return result
        }
        if text.hasPrefix(":") { return nil }
        let colon = text.firstIndex(of: ":")
        let field = colon.map { String(text[..<$0]) } ?? text
        var value = colon.map { String(text[text.index(after: $0)...]) } ?? ""
        if value.first == " " { value.removeFirst() }
        if field == "event" { event = value }
        else if field == "data" { data.append(value) }
        return nil
    }
}
