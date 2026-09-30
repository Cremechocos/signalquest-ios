import Foundation

/// Renvoi groupé des envois en attente (speedtests, publications, messages,
/// pièces jointes, sites) : au retour du réseau et au retour au premier plan,
/// plus seulement à l'ouverture de l'écran concerné.
///
/// Un seul passage à la fois : un second appel pendant un passage ne relance
/// rien, pour qu'un même envoi ne parte pas deux fois en parallèle. Chaque file
/// garde ses propres règles (abandon des refus définitifs, ordre par
/// conversation, session courante).
@MainActor
final class PendingQueueFlusher {
    typealias Step = @MainActor () async -> Void

    private let steps: [Step]
    private var running: Task<Void, Never>?

    init(steps: [Step]) {
        self.steps = steps
    }

    var isRunning: Bool { running != nil }

    /// Lance un passage s'il n'y en a pas déjà un ; rend le passage en cours.
    @discardableResult
    func flush() -> Task<Void, Never> {
        if let running { return running }
        // La tâche hérite de l'acteur principal : elle ne démarre qu'après ce
        // retour, donc après l'affectation de `running`.
        let task = Task { [weak self, steps] in
            for step in steps {
                if Task.isCancelled { break }
                await step()
            }
            self?.running = nil
        }
        running = task
        return task
    }
}
