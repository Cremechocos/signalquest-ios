import CoreLocation
import Foundation

/// Un accusé radio ne confirme pas une publication GPS, et inversement.
/// Chaque destination conserve donc sa propre fenêtre de retransmission.
struct LiveTelemetryDeliveryState {
    enum Channel: Hashable { case location, radio }
    /// `fix` vaut `nil` pour un relevé radio parti sans position (SOC-35).
    private struct Receipt { let fix: CLLocation?; let receivedAt: Date }
    private var receipts: [Channel: Receipt] = [:]

    /// Sans position d'un côté ou de l'autre, seul le silence déclenche un renvoi.
    func shouldSend(_ fix: CLLocation?, channel: Channel, now: Date,
                    minDistance: CLLocationDistance, maxSilence: TimeInterval) -> Bool {
        guard let receipt = receipts[channel] else { return true }
        if now.timeIntervalSince(receipt.receivedAt) >= maxSilence { return true }
        guard let fix, let previous = receipt.fix else { return false }
        return fix.distance(from: previous) >= minDistance
    }

    mutating func acknowledge(_ fix: CLLocation?, channel: Channel, accepted: Bool, now: Date) {
        guard accepted else { return }
        receipts[channel] = Receipt(fix: fix, receivedAt: now)
    }

    mutating func reset(_ channel: Channel) { receipts.removeValue(forKey: channel) }
}
