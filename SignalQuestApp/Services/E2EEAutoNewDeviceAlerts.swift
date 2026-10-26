import Foundation

/// Appareils ajoutés à son propre compte, vus dans le journal vérifié et pas
/// encore présentés (E2EE-AUTO §4.2). Le serveur n'envoie aucune alerte :
/// l'app la tire du journal, et la file survit à la fermeture de l'app.
struct E2EEAutoNewDeviceAlerts {
    static let didChange = Notification.Name("SignalQuest.E2EEAuto.NewDeviceAlerts.v1")
    /// Au-delà, les plus anciens tombent : l'écran Appareils montre de toute façon tout le compte.
    static let limit = 20

    var defaults: UserDefaults = .standard

    private func key(_ ownerNamespace: String) -> String { "e2ee-auto-new-devices-v1:\(ownerNamespace)" }

    /// Dans l'ordre où ils ont été vus.
    func pending(ownerNamespace: String) -> [String] {
        defaults.stringArray(forKey: key(ownerNamespace)) ?? []
    }

    func record(_ deviceIds: Set<String>, ownerNamespace: String) {
        let current = pending(ownerNamespace: ownerNamespace)
        let added = deviceIds.subtracting(current).sorted()
        guard !added.isEmpty else { return }
        defaults.set(Array((current + added).suffix(Self.limit)), forKey: key(ownerNamespace))
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func resolve(_ deviceId: String, ownerNamespace: String) {
        let rest = pending(ownerNamespace: ownerNamespace).filter { $0 != deviceId }
        if rest.isEmpty {
            defaults.removeObject(forKey: key(ownerNamespace))
        } else {
            defaults.set(rest, forKey: key(ownerNamespace))
        }
    }
}
