import Foundation
import ActivityKit

/// Attributs de la Live Activity « speedtest en cours » (iOS 16.1+). Partagé
/// app ↔ widget (l'app démarre/met à jour, le widget affiche l'UI verrouillée +
/// Dynamic Island).
@available(iOS 16.1, *)
struct SpeedtestActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var phaseLabel: String
        public var downloadMbps: Double
        public var uploadMbps: Double
        public var pingMs: Double
        public var progress: Double
        /// Index 1-based du test courant dans une rafale (1 si test unique).
        public var runIndex: Int
        /// Nombre total de tests de la rafale (1 si test unique).
        public var runTotal: Int
        public var finished: Bool

        public init(
            phaseLabel: String,
            downloadMbps: Double,
            uploadMbps: Double,
            pingMs: Double = 0,
            progress: Double,
            runIndex: Int = 1,
            runTotal: Int = 1,
            finished: Bool = false
        ) {
            self.phaseLabel = phaseLabel
            self.downloadMbps = downloadMbps
            self.uploadMbps = uploadMbps
            self.pingMs = pingMs
            self.progress = progress
            self.runIndex = runIndex
            self.runTotal = runTotal
            self.finished = finished
        }

        /// Rafale en cours (plusieurs tests).
        public var isBurst: Bool { runTotal > 1 }
    }

    public var serverName: String
    public var network: String

    public init(serverName: String, network: String = "Réseau") {
        self.serverName = serverName
        self.network = network
    }
}

/// Identifiant de l'App Group partagé entre l'app et l'extension widget.
/// À activer sur l'App ID (portail Apple Developer) + entitlements des 2 cibles.
enum SQAppGroup {
    static let identifier = "group.fr.signalquest.ios"
}

/// Instantané compact d'un speedtest, partagé app → widget via l'App Group.
/// Volontairement minimal (pas de dépendance aux modèles de l'app) pour être
/// compilé tel quel dans la cible widget.
struct SpeedtestWidgetSnapshot: Codable, Equatable, Identifiable {
    var downloadMbps: Double
    var uploadMbps: Double?
    var pingMs: Double?
    var jitterMs: Double?
    var network: String
    var label: String
    var date: Date

    var id: Double { date.timeIntervalSince1970 }

    init(downloadMbps: Double, uploadMbps: Double?, pingMs: Double?, jitterMs: Double? = nil, network: String, label: String, date: Date) {
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.pingMs = pingMs
        self.jitterMs = jitterMs
        self.network = network
        self.label = label
        self.date = date
    }
}

/// Lecture/écriture des instantanés dans `UserDefaults(suiteName:)` de l'App Group.
/// Fonctionne dès que la capacité App Group est active sur les 2 cibles ; sinon
/// `UserDefaults(suiteName:)` est nil et les accès sont des no-op silencieux.
enum WidgetSharedStore {
    private static let speedtestKey = "sq.widget.lastSpeedtest.v1"
    private static let recentKey = "sq.widget.recentSpeedtests.v1"
    private static let maxRecent = 12

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SQAppGroup.identifier)
    }

    static func saveLastSpeedtest(_ snapshot: SpeedtestWidgetSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: speedtestKey)
        // Maintient une liste récente (la plus récente d'abord) pour les widgets
        // de tendance / historique.
        var recent = recentSpeedtests()
        recent.removeAll { abs($0.date.timeIntervalSince(snapshot.date)) < 0.5 }
        recent.insert(snapshot, at: 0)
        if recent.count > maxRecent { recent = Array(recent.prefix(maxRecent)) }
        if let recentData = try? JSONEncoder().encode(recent) {
            defaults.set(recentData, forKey: recentKey)
        }
    }

    static func lastSpeedtest() -> SpeedtestWidgetSnapshot? {
        guard let defaults, let data = defaults.data(forKey: speedtestKey) else { return nil }
        return try? JSONDecoder().decode(SpeedtestWidgetSnapshot.self, from: data)
    }

    static func recentSpeedtests() -> [SpeedtestWidgetSnapshot] {
        guard let defaults, let data = defaults.data(forKey: recentKey) else { return [] }
        return (try? JSONDecoder().decode([SpeedtestWidgetSnapshot].self, from: data)) ?? []
    }
}
