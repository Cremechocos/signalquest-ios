import CoreLocation
import Foundation

/// Un accusé radio ne confirme pas une publication GPS, et inversement.
/// Chaque destination conserve donc sa propre fenêtre de retransmission.
struct LiveTelemetryDeliveryState {
    enum Channel: Hashable { case location, radio }
    private struct Receipt { let fix: CLLocation; let receivedAt: Date }
    private var receipts: [Channel: Receipt] = [:]

    func shouldSend(_ fix: CLLocation, channel: Channel, now: Date,
                    minDistance: CLLocationDistance, maxSilence: TimeInterval) -> Bool {
        guard let receipt = receipts[channel] else { return true }
        return fix.distance(from: receipt.fix) >= minDistance
            || now.timeIntervalSince(receipt.receivedAt) >= maxSilence
    }

    mutating func acknowledge(_ fix: CLLocation, channel: Channel, accepted: Bool, now: Date) {
        guard accepted else { return }
        receipts[channel] = Receipt(fix: fix, receivedAt: now)
    }

    mutating func reset(_ channel: Channel) { receipts.removeValue(forKey: channel) }
}
