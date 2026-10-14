import CoreSpotlight
import UniformTypeIdentifiers
import Foundation

/// Indexation Spotlight : le dernier speedtest devient cherchable depuis la
/// recherche système (« speedtest », « signalquest »). Taper l'item ouvre l'app.
enum SQSpotlight {
    static func donateLastSpeedtest(_ snapshot: SpeedtestWidgetSnapshot) {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        let download = rate(snapshot.downloadMbps)
        attributes.title = String(localized: "Dernier Speedtest — \(download)")
        if let upload = snapshot.uploadMbps {
            attributes.contentDescription = String(localized: "\(snapshot.network) · \(download) en réception · \(rate(upload)) en envoi")
        } else {
            attributes.contentDescription = String(localized: "\(snapshot.network) · \(download) en réception")
        }
        attributes.keywords = ["speedtest", "débit", "signalquest", "réseau"]
        let item = CSSearchableItem(
            uniqueIdentifier: "sq.speedtest.last",
            domainIdentifier: "fr.signalquest.speedtest",
            attributeSet: attributes
        )
        CSSearchableIndex.default().indexSearchableItems([item])
    }

    private static func rate(_ mbps: Double) -> String {
        "\(Int(mbps.rounded())) \(SQUnits.throughputUnit(mbps: mbps))"
    }

    /// Retire les éléments indexés par l'app. Appelé à la déconnexion : le
    /// dernier speedtest restait sinon cherchable depuis Spotlight (MES-13).
    static func removeAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["fr.signalquest.speedtest"])
    }
}
