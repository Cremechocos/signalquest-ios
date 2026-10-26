import CryptoKit
import Foundation

/// Alerte de fourche ou de retour en arrière gardée par le lecteur du journal
/// (E2EE-AUTO §3.5, §3.7). Elle ne se lève jamais seule : seule une
/// réinitialisation demandée par l'utilisateur, après un signalement à
/// l'équipe, oublie le journal gardé ici.
struct E2EEAutoLogAlerts {
    static let didChange = Notification.Name("SignalQuest.E2EEAuto.LogAlert.v1")

    var store = E2EEAutoLogStore()
    var defaults: UserDefaults = .standard

    func current(ownerScopeId: String) -> E2EEAutoLogStore.Alert? {
        (try? store.anchor(ownerScopeId: ownerScopeId))?.alert
    }

    /// Le signalement envoyé pour cette alerte-ci, pas pour une précédente.
    func reportId(for alert: E2EEAutoLogStore.Alert, ownerScopeId: String) -> String? {
        guard let stored = defaults.dictionary(forKey: key(ownerScopeId)) as? [String: String],
              stored["alert"] == Self.tag(alert) else { return nil }
        return stored["reportId"]
    }

    func setReported(_ reportId: String, for alert: E2EEAutoLogStore.Alert, ownerScopeId: String) {
        defaults.set(["alert": Self.tag(alert), "reportId": reportId], forKey: key(ownerScopeId))
    }

    /// Oublie le journal gardé ici : la prochaine lecture repart du maillon 1 et
    /// accepte la tête que le serveur montre alors.
    func reset(ownerScopeId: String) throws {
        try store.purge(ownerScopeId: ownerScopeId)
        defaults.removeObject(forKey: key(ownerScopeId))
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Ce qui part à l'équipe : l'écart, son maillon et l'appareil, comme tout
    /// signalement. Aucun message, contact ni identifiant d'appareil du journal.
    static func submission(_ alert: E2EEAutoLogStore.Alert, device: BugReportDevice) -> BugReportSubmission {
        BugReportSubmission(
            category: .data,
            title: String(localized: "Alerte du journal des appareils (\(alert.error))"),
            description: "E2EE-AUTO log alert: \(alert.error) at seq \(alert.seq)",
            severity: .critical,
            steps: nil, expectedResult: nil, images: [], device: device,
            speedtest: nil, location: nil
        )
    }

    private static func tag(_ alert: E2EEAutoLogStore.Alert) -> String { "\(alert.error):\(alert.seq)" }

    private func key(_ ownerScopeId: String) -> String {
        let digest = SHA256.hash(data: Data(ownerScopeId.utf8)).map { String(format: "%02x", $0) }.joined()
        return "e2ee-auto-log-alert-report-v1:\(digest)"
    }
}
