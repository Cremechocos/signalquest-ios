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

/// Configuration partagée entre l'app et l'extension. Les valeurs proviennent
/// des xcconfig afin que Beta ne lise jamais l'App Group ni le schéma URL de
/// production.
enum SQSharedConfiguration {
    private static func value(_ key: String, fallback: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.isEmpty,
              !raw.contains("$(") else { return fallback }
        return raw
    }

    static var appGroupIdentifier: String {
        value("SQ_APP_GROUP", fallback: "group.fr.signalquest.ios")
    }

    static var urlScheme: String {
        value("SQ_URL_SCHEME", fallback: "signalquest")
    }

    static func deepLink(_ host: String) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = host
        // The configured scheme and static host are programmer-controlled.
        return components.url ?? URL(string: "signalquest://\(host)")!
    }
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

/// Instantané « réseau autour de moi » (F8), partagé app → widget : opérateur
/// résolu, génération, antenne la plus proche connue, dernier débit. Écrit
/// pendant le Drive Test (où opérateur + antenne proche sont tous deux connus).
struct NetworkGlanceSnapshot: Codable, Equatable {
    var operatorLabel: String?
    var generation: String?
    var nearestDistanceMeters: Double?
    var nearestOperator: String?
    var lastDownloadMbps: Double?
    var date: Date

    init(operatorLabel: String?, generation: String?, nearestDistanceMeters: Double?, nearestOperator: String?, lastDownloadMbps: Double?, date: Date) {
        self.operatorLabel = operatorLabel
        self.generation = generation
        self.nearestDistanceMeters = nearestDistanceMeters
        self.nearestOperator = nearestOperator
        self.lastDownloadMbps = lastDownloadMbps
        self.date = date
    }
}

/// Lecture/écriture des instantanés dans `UserDefaults(suiteName:)` de l'App Group.
/// Fonctionne dès que la capacité App Group est active sur les 2 cibles ; sinon
/// `UserDefaults(suiteName:)` est nil et les accès sont des no-op silencieux.
enum WidgetSharedStore {
    private static let speedtestKey = "sq.widget.lastSpeedtest.v1"
    private static let recentKey = "sq.widget.recentSpeedtests.v1"
    private static let networkGlanceKey = "sq.widget.networkGlance.v1"
    private static let maxRecent = 12

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SQSharedConfiguration.appGroupIdentifier)
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

    static func saveNetworkGlance(_ snapshot: NetworkGlanceSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: networkGlanceKey)
    }

    static func networkGlance() -> NetworkGlanceSnapshot? {
        guard let defaults, let data = defaults.data(forKey: networkGlanceKey) else { return nil }
        return try? JSONDecoder().decode(NetworkGlanceSnapshot.self, from: data)
    }
}
