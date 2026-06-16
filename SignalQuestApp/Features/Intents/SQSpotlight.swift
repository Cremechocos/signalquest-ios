import CoreSpotlight
import UniformTypeIdentifiers
import Foundation

/// Indexation Spotlight : le dernier speedtest devient cherchable depuis la
/// recherche système (« speedtest », « signalquest »). Taper l'item ouvre l'app.
enum SQSpotlight {
    static func donateLastSpeedtest(_ snapshot: SpeedtestWidgetSnapshot) {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "Dernier Speedtest — \(Int(snapshot.downloadMbps.rounded())) Mbps"
        let ul = snapshot.uploadMbps.map { " · \(Int($0.rounded())) Mbps UL" } ?? ""
        attributes.contentDescription = "\(snapshot.network) · \(Int(snapshot.downloadMbps.rounded())) Mbps DL\(ul)"
        attributes.keywords = ["speedtest", "débit", "signalquest", "réseau"]
        let item = CSSearchableItem(
            uniqueIdentifier: "sq.speedtest.last",
            domainIdentifier: "fr.signalquest.speedtest",
            attributeSet: attributes
        )
        CSSearchableIndex.default().indexSearchableItems([item])
    }
}
