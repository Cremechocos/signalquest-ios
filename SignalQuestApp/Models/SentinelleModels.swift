import Foundation

/// Sentinelle — ce que l'application lit de la surveillance serveur.
///
/// La sonde tourne sur le serveur : l'app ne mesure rien, elle lit. C'est ce qui
/// permet à cet écran de tenir sans `BGTaskScheduler` ni tâche de fond.
///
/// La distinction BOX / ADRESSE structure tout ce fichier. Elle n'est pas
/// cosmétique : en IPv6 il n'y a pas de NAT, donc une box peut répondre
/// parfaitement en IPv4 pendant que son IPv6 est morte. Tant que les deux
/// familles sont fondues dans une moyenne unique, cette panne-là reste
/// invisible — d'où des agrégats calculés par famille ET une lecture « box »
/// distincte, qui ne déclare la connexion perdue que si TOUTES ont échoué.

// MARK: - Famille d'adresses

enum SentinelleFamily: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case v4
    case v6

    var id: String { rawValue }
    var label: String { self == .v6 ? "IPv6" : "IPv4" }
    var other: SentinelleFamily { self == .v6 ? .v4 : .v6 }
}

/// UNE adresse de la box, dans UNE famille.
struct SentinelleAddress: Identifiable, Hashable, Sendable {
    let family: SentinelleFamily
    let address: String
    /// Vraie quand l'adresse vient de la résolution du nom d'hôte : elle se
    /// consulte, elle ne se saisit pas — c'est le DNS qui en décide.
    let fromHostname: Bool

    var id: SentinelleFamily { family }
    var familyLabel: String { family.label }
}

// MARK: - Cible surveillée

struct SentinelleTarget: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    /// À qui appartient la connexion — « Moi », « Mes parents »… Facultatif.
    let ownerLabel: String?
    /// Emoji qui accompagne l'attribution, pour repérer la box dans une liste.
    let ownerEmoji: String?
    let hostname: String?
    let ipv4: String?
    let ipv6: String?
    /// Dernière résolution effective du nom d'hôte ; nul pour une cible en IP fixe.
    let resolvedIpv4: String?
    let resolvedIpv6: String?
    let status: String
    let statusSince: String?
    let lastProbeAt: String?
    let protocolName: String?
    let isActive: Bool?
    let suspendedReason: String?
    let operatorKey: String?
    /// Le lien de partage est actif : la box peut être suivie.
    let isPublic: Bool?
    let publicSlug: String?
    /// Échéance du lien, en ISO 8601. Nul = sans limite de durée.
    let publicExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, label, ownerLabel, ownerEmoji, hostname, ipv4, ipv6, resolvedIpv4, resolvedIpv6
        case isPublic, publicSlug, publicExpiresAt
        case status, statusSince, lastProbeAt
        // `protocol` est un mot réservé en Swift : on le renomme sans toucher au contrat serveur.
        case protocolName = "protocol"
        case isActive, suspendedReason, operatorKey
    }

    /// Adresse affichable : le nom d'hôte prime, il est plus parlant qu'une IP.
    var displayAddress: String { hostname ?? ipv4 ?? ipv6 ?? "—" }

    /// Les adresses effectivement sondées, une par famille. Pour une cible en
    /// nom d'hôte ce sont les adresses résolues.
    var addresses: [SentinelleAddress] {
        var result: [SentinelleAddress] = []
        if let value = ipv4 ?? resolvedIpv4 {
            result.append(SentinelleAddress(family: .v4, address: value, fromHostname: ipv4 == nil))
        }
        if let value = ipv6 ?? resolvedIpv6 {
            result.append(SentinelleAddress(family: .v6, address: value, fromHostname: ipv6 == nil))
        }
        return result
    }

    /// Famille manquante, quand il y a lieu d'en proposer une.
    ///
    /// Rien à proposer pour une cible en nom d'hôte : les deux familles y sont
    /// résolues à chaque cycle. Rien non plus si les deux sont déjà connues.
    var missingFamily: SentinelleFamily? {
        guard hostname == nil else { return nil }
        if ipv4 != nil && ipv6 == nil { return .v6 }
        if ipv6 != nil && ipv4 == nil { return .v4 }
        return nil
    }
}

struct SentinelleQuota: Decodable, Sendable {
    let used: Int
    let max: Int

    var isFull: Bool { used >= max }
}

// MARK: - Incidents

struct SentinelleIncident: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let kind: String
    /// Écrite telle quelle par le serveur. Une valeur inattendue vaut « pas de
    /// famille » au lieu de faire échouer le décodage de tout le journal.
    private let familyRaw: String?
    let startedAt: String
    let endedAt: String?
    let durationSec: Int?
    let cause: String?
    let hopIndex: Int?
    let correlatedUsers: Int?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case familyRaw = "family"
        case startedAt, endedAt, durationSec, cause, hopIndex, correlatedUsers
    }

    /// Famille touchée ; nul = l'incident concerne la box entière.
    var family: SentinelleFamily? { familyRaw.flatMap(SentinelleFamily.init(rawValue:)) }

    var isOutage: Bool { kind == "outage" }

    /// Un incident sans famille se rapporte à toute la connexion : le masquer
    /// sur la page d'une adresse ferait disparaître des coupures réelles.
    func concerns(_ family: SentinelleFamily) -> Bool {
        self.family == nil || self.family == family
    }
}

// MARK: - Séries de mesures

/// Fenêtre de lecture d'une série.
///
/// La granularité ne se demande pas : le serveur la déduit de la fenêtre (brut
/// jusqu'à 24 h, seaux de 5 min jusqu'à 30 j, horaires au-delà). Les valeurs
/// sont donc celles qu'il accepte, et rien d'autre.
enum SentinelleWindow: String, CaseIterable, Identifiable, Sendable {
    case h1 = "1h"
    case h24 = "24h"
    case d7 = "7d"
    case d30 = "30d"
    case d90 = "90d"

    var id: String { rawValue }

    /// Libellé court du sélecteur.
    var label: String {
        switch self {
        case .h1: return "1 h"
        case .h24: return "24 h"
        case .d7: return "7 j"
        case .d30: return "30 j"
        case .d90: return "90 j"
        }
    }

    /// Période écrite en toutes lettres, pour les titres de carte.
    var periodLabel: String {
        switch self {
        case .h1: return String(localized: "la dernière heure")
        case .h24: return String(localized: "24 heures")
        case .d7: return String(localized: "7 jours")
        case .d30: return String(localized: "30 jours")
        case .d90: return String(localized: "90 jours")
        }
    }

    /// Début de fenêtre, tel qu'il se lit sous l'axe du graphe.
    var startLabel: String {
        switch self {
        case .h1: return String(localized: "il y a 1 h")
        case .h24: return String(localized: "il y a 24 h")
        case .d7: return String(localized: "il y a 7 j")
        case .d30: return String(localized: "il y a 30 j")
        case .d90: return String(localized: "il y a 90 j")
        }
    }

    /// Vrai quand la fenêtre tient dans une journée : l'axe se date alors à
    /// l'heure, au-delà il se date au jour.
    var isIntraday: Bool { self == .h1 || self == .h24 }
}

/// Un point de mesure, tel que le renvoie la route `series`.
///
/// La latence est nulle quand rien n'a répondu : on garde le trou plutôt que
/// d'inventer un zéro, qui se dessinerait comme une latence excellente.
struct SentinelleSeriesPoint: Decodable, Identifiable, Sendable {
    let at: Date
    private let familyRaw: String?
    let lossPct: Double?
    let downSeconds: Int?
    let rttMinMs: Double?
    let rttAvgMs: Double?
    let rttP50Ms: Double?
    let rttP95Ms: Double?
    let rttMaxMs: Double?
    let jitterMs: Double?

    enum CodingKeys: String, CodingKey {
        case at
        case familyRaw = "family"
        case lossPct, downSeconds, rttMinMs, rttAvgMs, rttP50Ms, rttP95Ms, rttMaxMs, jitterMs
    }

    var id: String { "\(familyRaw ?? "?")-\(at.timeIntervalSince1970)" }

    var family: SentinelleFamily? { familyRaw.flatMap(SentinelleFamily.init(rawValue:)) }

    /// Le brut porte `rttAvgMs`, les seaux agrégés `rttP50Ms` : selon la fenêtre
    /// demandée, la même route sert l'un ou l'autre.
    var rttMs: Double? { rttAvgMs ?? rttP50Ms }

    var isLost: Bool { (lossPct ?? 0) >= 100 }
}

// MARK: - Relevé de chemin

struct SentinelleHopPoint: Decodable, Sendable {
    let t: Double?
    private let storedAvgMs: Double?
    let lossPct: Double?

    enum CodingKeys: String, CodingKey {
        case t
        case storedAvgMs = "avgMs"
        case lossPct
    }

    /// Latence du saut, ou `nil` quand rien n'est revenu à ce cycle.
    ///
    /// La sonde écrit `0` pour un saut qui n'a RIEN renvoyé : c'est une absence
    /// de mesure déguisée en valeur, et elle prétend que le saut a répondu
    /// instantanément — l'inverse de ce qui s'est produit. On la neutralise donc
    /// à la lecture, comme le fait `annotateHops` côté web : le saut muet et le
    /// saut sans mesure se lisent alors de la même façon, « — ».
    var avgMs: Double? { (lossPct ?? 0) >= 100 ? nil : storedAvgMs }
}

struct SentinelleHop: Decodable, Identifiable, Sendable {
    let key: String
    let idx: Int
    let host: String?
    let hostname: String?
    let operatorName: String?
    let points: [SentinelleHopPoint]
    /// Muet sur TOUTE la fenêtre : à afficher en sourdine, jamais en alerte.
    let alwaysQuiet: Bool
    /// Nombre de sauts repliés dans cette ligne.
    let collapsed: Int

    enum CodingKeys: String, CodingKey {
        case key, idx, host, hostname
        // `operator` est un mot réservé en Swift.
        case operatorName = "operator"
        case points, alwaysQuiet, collapsed
    }

    var id: String { key }

    /// Nom lisible. L'opérateur prime sur le nom inverse, qui prime sur
    /// l'adresse : « SFR » se lit, « 134.146.6.194.rev.sfr.net » beaucoup moins.
    var label: String {
        if collapsed > 1 { return String(localized: "réseau interne · \(collapsed) sauts") }
        if alwaysQuiet { return String(localized: "saut muet") }
        return operatorName ?? hostname ?? host ?? "—"
    }

    /// Dernière latence connue de ce maillon.
    var lastMs: Double? { points.last(where: { $0.avgMs != nil })?.avgMs }
}

// MARK: - Lectures longues

/// Relevé de chemin, avec la famille sur laquelle il a réellement été mesuré.
struct SentinelleDiagnostic: Decodable, Sendable {
    private let familyRaw: String?
    let windowHours: Int?
    let hops: [SentinelleHop]

    enum CodingKeys: String, CodingKey {
        case familyRaw = "family"
        case windowHours, hops
    }

    var family: SentinelleFamily? { familyRaw.flatMap(SentinelleFamily.init(rawValue:)) }
}

/// Saisonnalité, dérive et comparaison entre abonnés.
///
/// Chaque champ vaut `nil` quand l'agrégat n'a pas assez de mesures pour être
/// tenable : le serveur refuse de répondre plutôt que d'avancer un chiffre
/// fragile, et l'écran doit respecter ce silence.
struct SentinelleTrends: Decodable, Sendable {
    private let familyRaw: String?
    let seasonality: Seasonality?
    let drift: [DriftWeek]
    let peers: Peers?

    enum CodingKeys: String, CodingKey {
        case familyRaw = "family"
        case seasonality, drift, peers
    }

    var family: SentinelleFamily? { familyRaw.flatMap(SentinelleFamily.init(rawValue:)) }

    struct Seasonality: Decodable, Sendable {
        /// Créneau le plus lent, seulement s'il se détache franchement.
        let worst: Worst?

        struct Worst: Decodable, Sendable {
            /// 0 = lundi.
            let dow: Int
            let hour: Int
            let p50: Double
        }
    }

    struct DriftWeek: Decodable, Identifiable, Sendable {
        let start: String
        let p50: Double?
        let p95: Double?
        let lossPct: Double?

        var id: String { start }
    }

    struct Peers: Decodable, Sendable {
        let peerCount: Int
        /// Part des lignes comparables strictement plus lentes que celle-ci.
        let betterThanPct: Int?
        let operatorP50: Double?
        let departmentP50: Double?
    }
}

/// Journal opposable : disponibilité contractuelle et coupures datées.
struct SentinelleProof: Decodable, Sendable {
    private let familyRaw: String?
    let availability: Availability?
    let outageCount: Int
    let longestOutageSec: Int
    let incidents: [SentinelleIncident]
    let monitoredSince: String?

    enum CodingKeys: String, CodingKey {
        case familyRaw = "family"
        case availability, outageCount, longestOutageSec, incidents, monitoredSince
    }

    var family: SentinelleFamily? { familyRaw.flatMap(SentinelleFamily.init(rawValue:)) }

    struct Availability: Decodable, Sendable {
        let uptimePct: Double
        let downSeconds: Int
        /// Heures RÉELLEMENT couvertes par la mesure : le dénominateur n'est pas
        /// la fenêtre nominale, sinon « 99,9 % sur 30 jours » se dirait après
        /// trois jours de mesures.
        let coveredHours: Int
    }
}

// MARK: - Lectures dérivées

/// État d'UNE adresse, déduit de ses propres mesures.
enum SentinelleAddressState: Sendable {
    case up
    case degraded
    case down
    /// Pas de mesure = pas de verdict. C'est le cas d'une famille tout juste
    /// ajoutée, et celui d'une adresse que la sonde n'a jamais atteinte.
    case unknown
}

/// Les quatre nombres du bandeau. Chacun est nul plutôt que forcé : afficher
/// « 0 ms » pour une pile qu'on n'a jamais sondée serait un mensonge.
struct SentinelleMetrics: Sendable {
    let uptimePct: Double
    let rttMs: Double?
    let jitterMs: Double?
    let lossPct: Double?
}

extension Array where Element == SentinelleSeriesPoint {

    func inFamily(_ family: SentinelleFamily) -> [SentinelleSeriesPoint] {
        filter { $0.family == family }
    }

    /// État d'une adresse, lu sur ses dernières mesures.
    ///
    /// On regarde les trois derniers points plutôt que le seul dernier : un
    /// paquet perdu isolé est la respiration normale d'un réseau, pas une panne.
    var addressState: SentinelleAddressState {
        let recent = suffix(3)
        if recent.isEmpty { return .unknown }
        if recent.allSatisfy(\.isLost) { return .down }
        if recent.contains(where: { ($0.lossPct ?? 0) > 0 }) { return .degraded }
        if recent.contains(where: { $0.lossPct != nil }) { return .up }
        return .unknown
    }

    /// Agrégats d'UNE famille, sur ses seuls points.
    var addressMetrics: SentinelleMetrics? {
        guard !isEmpty else { return nil }
        let answered = filter { !$0.isLost }
        let losses = compactMap(\.lossPct)
        return SentinelleMetrics(
            uptimePct: Double(answered.count) * 100 / Double(count),
            // Latence et gigue ne se moyennent que sur ce qui a répondu.
            rttMs: answered.compactMap(\.rttMs).average,
            jitterMs: answered.compactMap(\.jitterMs).average,
            lossPct: losses.average
        )
    }

    /// Agrégats de la BOX, toutes familles confondues.
    ///
    /// Une box est joignable dès qu'UNE des deux familles répond. Les points
    /// arrivent une fois par famille et par instant : compter chaque échec IPv6
    /// comme de l'indisponibilité ferait tomber la disponibilité à 50 % alors
    /// que la ligne n'a jamais cessé de fonctionner en IPv4. On regroupe donc
    /// par instant, et l'instant n'est perdu que si TOUTES y ont échoué.
    var boxMetrics: SentinelleMetrics? {
        guard !isEmpty else { return nil }
        var bestLossByInstant: [Date: Double] = [:]
        for point in self {
            let loss = point.lossPct ?? 100
            if let previous = bestLossByInstant[point.at] {
                bestLossByInstant[point.at] = Swift.min(previous, loss)
            } else {
                bestLossByInstant[point.at] = loss
            }
        }
        guard !bestLossByInstant.isEmpty else { return nil }

        let answered = filter { !$0.isLost }
        return SentinelleMetrics(
            uptimePct: Double(bestLossByInstant.values.filter { $0 < 100 }.count) * 100
                / Double(bestLossByInstant.count),
            rttMs: answered.compactMap(\.rttMs).average,
            jitterMs: answered.compactMap(\.jitterMs).average,
            // La perte retenue est celle de la MEILLEURE famille, même raison.
            lossPct: compactMap(\.lossPct).min()
        )
    }
}

private extension Array where Element == Double {
    /// Moyenne, ou `nil` sur un tableau vide — jamais zéro, qui se lirait comme
    /// une mesure.
    var average: Double? {
        isEmpty ? nil : reduce(0, +) / Double(count)
    }
}


/// Réglages d'alerte du compte.
///
/// La route enveloppe sa charge utile dans `preferences`, comme `targets` le
/// fait pour la liste des cibles — lire la racine rendrait silencieusement des
/// valeurs par défaut, donc plausibles et fausses.
struct SentinellePreferencesResponse: Codable, Sendable {
    let preferences: SentinellePreferences
}

struct SentinellePreferences: Codable, Sendable {
    let notifyDown: Bool
    let notifyUp: Bool
    let downThresholdSec: Int
    let webhookUrl: String?
}

/// Modification partielle : seuls les champs présents sont écrits, d'où les
/// optionnels et l'encodage qui omet les absents.
struct SentinellePreferencesPatch: Encodable, Sendable {
    var notifyDown: Bool?
    var notifyUp: Bool?
    var downThresholdSec: Int?
    /// `.some(nil)` retire le webhook, `nil` le laisse tel quel — la nuance
    /// compte, un champ vidé n'est pas un champ absent.
    var webhookUrl: String??

    enum CodingKeys: String, CodingKey { case notifyDown, notifyUp, downThresholdSec, webhookUrl }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(notifyDown, forKey: .notifyDown)
        try container.encodeIfPresent(notifyUp, forKey: .notifyUp)
        try container.encodeIfPresent(downThresholdSec, forKey: .downThresholdSec)
        if let webhookUrl {
            try container.encode(webhookUrl, forKey: .webhookUrl)
        }
    }
}

/// Verdict d'un essai de webhook, avec le code rendu par le DESTINATAIRE.
struct SentinelleWebhookTest: Codable, Sendable {
    let ok: Bool
    let status: Int?
    let destination: String?
    let message: String
}


/// Quelqu'un qui suit une box partagée.
///
/// Les accès RETIRÉS sont conservés : savoir qui a suivi sa connexion par le
/// passé fait partie de ce que le propriétaire est en droit de consulter.
struct SentinelleFollower: Decodable, Identifiable, Sendable {
    let id: String
    let userId: String
    let name: String?
    let since: String
    let revokedAt: String?

    var isActive: Bool { revokedAt == nil }
}

struct SentinelleFollowersResponse: Decodable, Sendable {
    let followers: [SentinelleFollower]
}


/// Modification du partage d'une box.
///
/// `expiresInHours` distingue trois cas et non deux : absent laisse l'échéance
/// telle quelle, `.some(nil)` la retire, une valeur la fixe. Régler la durée ne
/// doit pas rallumer un partage éteint, ni l'inverse.
struct SentinelleSharingPatch: Encodable, Sendable {
    var isPublic: Bool?
    var publicExpiresInHours: Int??

    enum CodingKeys: String, CodingKey { case isPublic, publicExpiresInHours }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(isPublic, forKey: .isPublic)
        if let publicExpiresInHours {
            try container.encode(publicExpiresInHours, forKey: .publicExpiresInHours)
        }
    }
}

/// Une box qu'on SUIT sans en être propriétaire.
///
/// Elle ne porte aucune adresse et aucun relevé de chemin : le serveur les
/// retire (`buildFollowerTargetView`), et ce type n'a simplement pas de champ
/// pour les accueillir. Les piles se nomment — « IPv4 », « IPv6 » — sans se
/// montrer.
struct SentinelleFollowedBox: Decodable, Identifiable, Sendable {
    /// Identifiant de l'ABONNEMENT, pas de la cible : c'est lui qu'on retire.
    let followId: String
    let displayName: String
    let status: String
    let lastProbeAt: String?
    let lastRttMs: Double?
    let uptimePct: Double?
    let families: [String]
    let incidents: [SentinelleFollowedIncident]

    var id: String { followId }
    var outages: Int { incidents.count }
}

struct SentinelleFollowedIncident: Decodable, Sendable {
    let startedAt: String
    let endedAt: String?
    let durationSec: Int?
}

struct SentinelleFollowingResponse: Decodable, Sendable {
    let following: [SentinelleFollowedBox]
}

struct SentinelleTargetResponse: Decodable, Sendable {
    let target: SentinelleTarget
}

/// Durées proposées. 24 h en tête : un lien se donne le plus souvent pour une
/// occasion. « Sans limite » existe, mais en DERNIER — c'est un choix, pas le
/// réglage par défaut.
enum SentinelleShareDuration: CaseIterable, Identifiable, Sendable {
    case day, week, month, unlimited

    var id: String { label }

    var label: String {
        switch self {
        case .day: return "24 h"
        case .week: return "7 j"
        case .month: return "30 j"
        case .unlimited: return "sans limite"
        }
    }

    var hours: Int? {
        switch self {
        case .day: return 24
        case .week: return 24 * 7
        case .month: return 24 * 30
        case .unlimited: return nil
        }
    }

    /// Une échéance ne se compare pas à la seconde : elle a été posée il y a un
    /// moment et le temps a passé depuis. On retient l'option la plus proche, à
    /// une heure près, plutôt que de n'en surligner aucune.
    func matches(_ expiresAt: String?) -> Bool {
        guard let hours else { return expiresAt == nil }
        guard let expiresAt, let date = ISO8601DateFormatter().date(from: expiresAt) else { return false }
        let remaining = date.timeIntervalSinceNow / 3600
        return abs(remaining - Double(hours)) < 1
    }
}
