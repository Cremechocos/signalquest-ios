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
        "mention", "typing", "reaction"
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
                            // Token expiré : un appel API standard rafraîchira le
                            // token ; on retente après le backoff.
                            throw APIError.http(status: 401, code: nil, message: "SSE non autorisé", requestId: nil, retryAfter: nil)
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            throw APIError.http(status: http.statusCode, code: nil, message: "SSE refusé", requestId: nil, retryAfter: nil)
                        }

                        backoff = 1.5
                        var eventName: String?
                        for try await line in bytes.lines {
                            if Task.isCancelled { break }
                            if line.lowercased().hasPrefix("event:") {
                                eventName = String(line.dropFirst("event:".count))
                                    .trimmingCharacters(in: .whitespaces)
                                    .lowercased()
                            } else if line.lowercased().hasPrefix("data:") {
                                let name = eventName ?? "update"
                                if Self.knownEvents.contains(name) {
                                    continuation.yield(name)
                                }
                            } else if line.isEmpty {
                                eventName = nil
                            }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
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
}
