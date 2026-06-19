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
    case viewingEvent
}

struct MessageSyncEngine: Sendable {
    private let sse: SSEClient
    private let pollInterval: Duration
    private static let minPollInterval: Duration = .seconds(5)

    init(sse: SSEClient, pollInterval: Duration = .seconds(12)) {
        self.sse = sse
        self.pollInterval = pollInterval < Self.minPollInterval ? Self.minPollInterval : pollInterval
    }

    /// Fusionne le flux SSE de la conversation et un ticker de polling de repli.
    /// Se termine à l'annulation de la Task consommatrice.
    func refreshEvents(conversationId: String) -> AsyncStream<SyncTrigger> {
        AsyncStream { continuation in
            let clock = ContinuousClock()
            // MSG-PERF-02 — Instant du dernier `serverEvent` SSE traité. Le polling
            // ne déclenche `refreshDelta` que si aucun event SSE n'est arrivé depuis
            // l'intervalle : en régime nominal (SSE vivant) on ne double plus les
            // requêtes ; si le SSE meurt, le repli reprend exactement comme avant.
            let lastServerEvent = OSAllocatedUnfairLock<ContinuousClock.Instant>(initialState: clock.now)
            let interval = pollInterval
            let sseTask = Task {
                for await eventName in sse.events(path: "/api/messages/conversations/\(conversationId)/events") {
                    let trigger: SyncTrigger = eventName == "typing"
                        ? .typingEvent
                        : (eventName == "viewing" ? .viewingEvent : .serverEvent)
                    // Seuls les serverEvent déclenchent un refreshDelta : ce sont eux
                    // qui « rafraîchissent » le compteur de repli (pas typing/viewing).
                    if case .serverEvent = trigger {
                        lastServerEvent.withLock { $0 = clock.now }
                    }
                    continuation.yield(trigger)
                }
            }
            let pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    if Task.isCancelled { break }
                    let recentlyActive = lastServerEvent.withLock { clock.now - $0 < interval }
                    if recentlyActive { continue }
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
