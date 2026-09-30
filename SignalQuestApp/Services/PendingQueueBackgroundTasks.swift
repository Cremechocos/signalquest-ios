import BackgroundTasks
import Foundation
import OSLog

/// Envois en attente relancés en arrière-plan (plan 3, vague 1) : iOS réveille
/// l'app quand le réseau est là, sans attendre qu'on la rouvre.
///
/// Deux tâches, déclarées dans l'Info.plist (`BGTaskSchedulerPermittedIdentifiers`,
/// modes `fetch` et `processing`) :
/// - un rafraîchissement court, qu'iOS place selon l'usage de l'app ;
/// - un traitement qui attend le réseau, pour les envois plus longs (photos).
///
/// Les deux vident les mêmes files que le retour au premier plan, avec les
/// mêmes règles (`PendingQueueFlusher`).
enum PendingQueueBackgroundTasks {
    static let refreshIdentifier = "fr.signalquest.ios.pending.refresh"
    static let processingIdentifier = "fr.signalquest.ios.pending.processing"
    static let identifiers = [refreshIdentifier, processingIdentifier]
    /// Identifiant de tâche et issue seulement : jamais de contenu envoyé.
    private static let logger = Logger(subsystem: "fr.signalquest.ios", category: "background-tasks")

    /// Avant la fin du lancement, comme iOS l'exige. Un identifiant absent de
    /// l'Info.plist ferait planter l'app : un test garde les deux listes alignées.
    static func register() {
        for identifier in identifiers {
            _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                // Appelé sur la file principale (`using: .main`) : la tâche ne
                // quitte jamais l'acteur principal.
                nonisolated(unsafe) let task = task
                MainActor.assumeIsolated { run(task) }
            }
        }
    }

    /// Au passage en arrière-plan. Une demande remplace la précédente de même
    /// identifiant : les réarmer à chaque fois ne les accumule pas.
    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: processingIdentifier)
        processing.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(processing)
    }

    @MainActor
    private static func run(_ task: BGTask) {
        schedule()
        let flush = AppServicesHolder.services.pendingQueues.flush()
        // Temps écoulé : les files s'arrêtent entre deux envois, rien n'est perdu.
        task.expirationHandler = { flush.cancel() }
        let identifier = task.identifier
        logger.info("début \(identifier, privacy: .public)")
        Task { @MainActor in
            await flush.value
            task.setTaskCompleted(success: !flush.isCancelled)
            logger.info("fin \(identifier, privacy: .public) interrompue=\(flush.isCancelled, privacy: .public)")
        }
    }
}
