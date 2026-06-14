import Foundation
import os

enum MessageSyncLog {
    static let logger = Logger(subsystem: "fr.signalquest.ios", category: "MessageSync")
}

/// Déclencheur de synchronisation d'une conversation — parité Android
/// (`MessageSyncEngine.kt`). Le SSE ne porte jamais l'état : il signale qu'un
/// re-sync est nécessaire, le polling delta reste la source de vérité.
enum SyncTrigger: Sendable {
    case polling
    case serverEvent
    case typingEvent
}

struct MessageSyncEngine: Sendable {
    private let sse: SSEClient
    private let pollInterval: Duration
    private static let minPollInterval: Duration = .seconds(5)

    init(sse: SSEClient, pollInterval: Duration = .seconds(12)) {
        self.sse = sse
        self.pollInterval = pollInterval < Self.minPollInterval ? Self.minPollInterval : pollInterval
    }

    /// Fusionne le flux SSE de la conversation et un ticker de polling.
    /// Se termine à l'annulation de la Task consommatrice.
    func refreshEvents(conversationId: String) -> AsyncStream<SyncTrigger> {
        AsyncStream { continuation in
            let sseTask = Task {
                for await eventName in sse.events(path: "/api/messages/conversations/\(conversationId)/events") {
                    continuation.yield(eventName == "typing" ? .typingEvent : .serverEvent)
                }
            }
            let pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: pollInterval)
                    if Task.isCancelled { break }
                    continuation.yield(.polling)
                }
            }
            continuation.onTermination = { _ in
                sseTask.cancel()
                pollTask.cancel()
            }
        }
    }
}
