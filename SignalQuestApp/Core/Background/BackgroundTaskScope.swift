import UIKit

/// Maintient l'app vivante un court instant après le passage en arrière-plan, le
/// temps de terminer un travail réseau court (ex. un speedtest ou une rafale).
/// Utilise l'API publique `beginBackgroundTask` — aucun mode d'arrière-plan
/// dédié n'est requis, et iOS accorde un sursis borné (le système reste maître).
@MainActor
final class BackgroundTaskScope {
    private var taskId: UIBackgroundTaskIdentifier = .invalid

    /// Démarre une assertion d'arrière-plan (idempotent).
    func begin(name: String) {
        guard taskId == .invalid else { return }
        taskId = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard taskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskId)
        taskId = .invalid
    }

    /// Redémarre l'assertion entre deux unités de travail. iOS reste maître du
    /// temps accordé, mais cela évite de continuer une rafale avec une assertion
    /// déjà expirée après un premier test long.
    func renew(name: String) {
        end()
        begin(name: name)
    }

    /// Temps d'arrière-plan restant accordé par le système (≈∞ au premier plan).
    var remainingSeconds: TimeInterval { UIApplication.shared.backgroundTimeRemaining }
}
