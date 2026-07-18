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
        let configuration = URLSessionConfiguration.default
        // Un flux SSE reste ouvert indéfiniment : pas de timeout de ressource,
        // mais un timeout de requête généreux pour détecter les connexions mortes.
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = .infinity
        self.session = URLSession(configuration: configuration)
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
                        var eventName: String?
                        var sawData = false
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            if line.lowercased().hasPrefix("event:") {
                                eventName = String(line.dropFirst("event:".count))
                                    .trimmingCharacters(in: .whitespaces)
                                    .lowercased()
                            } else if line.lowercased().hasPrefix("data:") {
                                // On mémorise seulement qu'un payload est présent ;
                                // l'émission a lieu à la fin de l'événement, pas ici.
                                sawData = true
                            } else if line.isEmpty {
                                // Fin d'événement SSE (ligne vide) : on émet le nom
                                // UNE fois, quel que soit l'ordre event:/data: ou le
                                // nombre de lignes data:, et seulement si un payload a
                                // été reçu. Robuste aux variations de format. (SSE-BUG-08)
                                if sawData {
                                    let name = eventName ?? "update"
                                    if Self.knownEvents.contains(name) {
                                        continuation.yield(name)
                                    } else {
                                        logger.debug("SSE événement hors contrat: \(name, privacy: .public)")
                                    }
                                }
                                eventName = nil
                                sawData = false
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
        keep: Set<String>
    ) -> AsyncStream<(event: String, data: String)> {
        AsyncStream { continuation in
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
                        var eventName: String?
                        var dataBuffer = ""
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            if line.hasPrefix(":") {
                                continue // commentaire SSE (heartbeat) : ignoré
                            } else if line.lowercased().hasPrefix("event:") {
                                eventName = String(line.dropFirst("event:".count))
                                    .trimmingCharacters(in: .whitespaces)
                                    .lowercased()
                            } else if line.lowercased().hasPrefix("data:") {
                                let chunk = String(line.dropFirst("data:".count))
                                    .trimmingCharacters(in: .whitespaces)
                                dataBuffer = dataBuffer.isEmpty ? chunk : dataBuffer + "\n" + chunk
                            } else if line.isEmpty {
                                let name = eventName ?? "message"
                                if !dataBuffer.isEmpty, keep.contains(name) {
                                    continuation.yield((event: name, data: dataBuffer))
                                }
                                eventName = nil
                                dataBuffer = ""
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
