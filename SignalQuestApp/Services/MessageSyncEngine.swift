import Foundation
import os

enum MessageSyncLog {
    static let logger = Logger(subsystem: "fr.signalquest.ios", category: "MessageSync")
}

/// Déclencheur de synchronisation d'une conversation — parité Android
/// (`MessageSyncEngine.kt`). Le SSE ne porte jamais l'état : il signale qu'un
/// re-sync est nécessaire, le polling delta reste la source de vérité.
enum SyncTrigger: Sendable, Equatable {
    case polling
    case serverEvent
    /// Réaction, vote, accusé de lecture, édition ou suppression : le delta ne
    /// porte pas ces changements, la conversation relit sa dernière page (SOC-05).
    case stateEvent
    case typingEvent
    case viewingEvent

    /// Événements relayés par le flux de la conversation.
    static let relayedEvents: Set<String> = [
        "update", "message", "read_state", "feature_sync", "thread_reply",
        "poll_created", "poll_voted", "poll_closed",
        "task_created", "task_updated", "task_completed",
        "mention", "typing", "viewing", "reaction"
    ]

    /// Types d'événement (champ `type` du payload) qui changent l'état d'un
    /// message déjà affiché plutôt que d'en ajouter un.
    private static let stateTypes: Set<String> = [
        "message_updated", "message_reaction", "reaction", "message_edited", "message_deleted",
        "message_pinned", "message_unpinned", "poll_created", "poll_voted", "poll_closed", "read_state"
    ]

    /// Le serveur envoie un événement nommé (ex. `poll_voted`) PUIS un `update`
    /// générique portant le même `type` : on lit le `type` du payload pour ne pas
    /// traiter une réaction comme un nouveau message.
    static func from(event: String, data: String) -> SyncTrigger {
        let name = event.lowercased()
        if name == "typing" { return .typingEvent }
        if name == "viewing" { return .viewingEvent }
        if stateTypes.contains(name) { return .stateEvent }
        if let payload = data.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let type = (object["type"] as? String)?.lowercased(),
           stateTypes.contains(type) {
            return .stateEvent
        }
        return .serverEvent
    }
}

struct MessageSyncEngine: Sendable {
    private let sse: SSEClient
    private let pollInterval: Duration
    private static let minPollInterval: Duration = .seconds(5)
    /// Flux ouvert : un seul delta de sécurité par minute, au cas où un
    /// intermédiaire retiendrait des événements sans couper la connexion.
    static let connectedSafetyInterval: Duration = .seconds(60)

    init(sse: SSEClient, pollInterval: Duration = .seconds(12)) {
        self.sse = sse
        self.pollInterval = pollInterval < Self.minPollInterval ? Self.minPollInterval : pollInterval
    }

    /// Le ticker ne relance un delta que si rien n'a rafraîchi la conversation
    /// depuis l'intervalle : 12 s quand le flux est coupé, une minute quand il vit.
    /// Avant, il sondait toutes les 12 s une conversation calme, même avec un
    /// flux en bonne santé (SOC-43).
    static func shouldPoll(sinceLastRefresh: Duration, sseConnected: Bool, interval: Duration) -> Bool {
        sinceLastRefresh >= (sseConnected ? max(interval, connectedSafetyInterval) : interval)
    }

    /// Fusionne le flux SSE de la conversation et un ticker de polling de repli.
    /// Se termine à l'annulation de la Task consommatrice.
    func refreshEvents(conversationId: String) -> AsyncStream<SyncTrigger> {
        AsyncStream { continuation in
            let clock = ContinuousClock()
            // MSG-PERF-02 — Dernier rafraîchissement : événement serveur traité,
            // delta de rattrapage ou tick de repli.
            let lastRefresh = OSAllocatedUnfairLock<ContinuousClock.Instant>(initialState: clock.now)
            let sseConnected = OSAllocatedUnfairLock(initialState: false)
            let interval = pollInterval
            let sseTask = Task {
                // Le serveur double certains événements (`poll_voted` puis `update`) :
                // un même déclencheur reçu à moins d'une demi-seconde n'en fait qu'un.
                var lastYield: (trigger: SyncTrigger, at: ContinuousClock.Instant)?
                let frames = sse.dataStream(
                    path: "/api/messages/conversations/\(conversationId)/events",
                    keep: SyncTrigger.relayedEvents,
                    onConnectionChange: { connected in
                        sseConnected.withLock { $0 = connected }
                        // Le flux ne rejoue pas ce qui est arrivé pendant la coupure :
                        // un delta de rattrapage à chaque (re)connexion.
                        guard connected else { return }
                        lastRefresh.withLock { $0 = clock.now }
                        continuation.yield(.polling)
                    }
                )
                for await frame in frames {
                    let trigger = SyncTrigger.from(event: frame.event, data: frame.data)
                    // Seuls les événements serveur « rafraîchissent » le compteur de
                    // repli (pas typing/viewing).
                    if trigger == .serverEvent || trigger == .stateEvent {
                        lastRefresh.withLock { $0 = clock.now }
                    }
                    let now = clock.now
                    if let lastYield, lastYield.trigger == trigger, now - lastYield.at < .milliseconds(500) {
                        continue
                    }
                    lastYield = (trigger, now)
                    continuation.yield(trigger)
                }
                // Refus définitif (403/404) : le flux s'arrête, le repli reprend seul.
                sseConnected.withLock { $0 = false }
            }
            let pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    if Task.isCancelled { break }
                    let now = clock.now
                    let connected = sseConnected.withLock { $0 }
                    let due = lastRefresh.withLock { last -> Bool in
                        guard Self.shouldPoll(sinceLastRefresh: now - last, sseConnected: connected,
                                              interval: interval) else { return false }
                        last = now
                        return true
                    }
                    if due { continuation.yield(.polling) }
                }
            }
            continuation.onTermination = { _ in
                sseTask.cancel()
                pollTask.cancel()
            }
        }
    }
}
