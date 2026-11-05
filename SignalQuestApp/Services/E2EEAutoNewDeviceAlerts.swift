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

    // MARK: - Push `e2ee_device_added` (révision 21)

    /// Le push n'est qu'un réveil : ni son `deviceId` ni son `seq` ne sont crus.
    /// Son propre compte est relu et l'appareil ajouté vient du journal vérifié ;
    /// le `seq` reste attendu tant que la tête vérifiée ne l'a pas atteint.
    static let pushType = "e2ee_device_added"
    static let pushReceived = Notification.Name("SignalQuest.E2EEAuto.DeviceAddedPush.v1")

    static func pushSeq(_ info: [AnyHashable: Any]) -> Int64? {
        guard info["type"] as? String == pushType, let seq = info["seq"] as? String else { return nil }
        return E2EEAutoLog.decimal(seq, in: 1...E2EEV2Canonical.maxSafeInteger)
    }

    private func seqKey(_ ownerNamespace: String) -> String { "e2ee-auto-device-added-seq-v1:\(ownerNamespace)" }

    func awaitedSeq(ownerNamespace: String) -> Int64? {
        (defaults.object(forKey: seqKey(ownerNamespace)) as? NSNumber)?.int64Value
    }

    /// Le plus grand `seq` annoncé : l'atteindre couvre aussi les précédents.
    func expect(seq: Int64, ownerNamespace: String) {
        guard seq > awaitedSeq(ownerNamespace: ownerNamespace) ?? 0 else { return }
        defaults.set(NSNumber(value: seq), forKey: seqKey(ownerNamespace))
    }

    /// `lastSeq` du compte vérifié : au-delà du `seq` attendu, plus rien à relire.
    func reached(_ lastSeq: Int64, ownerNamespace: String) {
        guard let awaited = awaitedSeq(ownerNamespace: ownerNamespace), lastSeq >= awaited else { return }
        defaults.removeObject(forKey: seqKey(ownerNamespace))
    }
}
