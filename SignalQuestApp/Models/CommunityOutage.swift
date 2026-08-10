import Foundation

/// Gravité d'une panne communautaire. Détermine la COULEUR partout où elle s'affiche.
///
/// Énumération et non chaîne libre : l'interface s'y branche pour la teinte, l'icône et le
/// libellé, et une comparaison de chaîne qui rate ne se voit pas — elle produit un état neutre
/// que personne ne remarque.
enum OutageSeverity: String, Codable, Equatable {
    case down
    case degraded

    /// Tolérant : une valeur inconnue du serveur retombe sur la plus grave, jamais sur rien.
    init(rawServerValue: String?) {
        self = rawServerValue?.lowercased() == "degraded" ? .degraded : .down
    }
}

/// État d'une panne communautaire.
///
/// ⚠️ `reported` est VISIBLE : la décision produit du chantier est qu'une panne s'affiche dès le
/// premier signalement, marquée non confirmée. Le seuil ne gouverne que le passage à `confirmed`,
/// les notifications et le gros des points.
enum OutageState: String, Codable, Equatable {
    case reported
    case confirmed
    case dormant
    case resolved
    case rejected

    init(rawServerValue: String?) {
        self = OutageState(rawValue: rawServerValue?.lowercased() ?? "") ?? .reported
    }

    /// Détient encore le verrou côté serveur. `dormant` en fait partie : mise en veille ≠ close.
    var isOpen: Bool { self == .reported || self == .confirmed || self == .dormant }

    /// Affichée sur la carte et dans la fiche.
    var isVisible: Bool { self == .reported || self == .confirmed }
}

/// Une panne signalée par la communauté.
///
/// ⚠️ Type DISTINCT d'`OutageSiteLive`, et c'est délibéré — le plan proposait d'étendre ce
/// dernier. `OutageSiteLive` porte les incidents publiés dans les CSV des opérateurs ; celui-ci
/// porte ce que des utilisateurs déclarent. Les fusionner ferait perdre la distinction que toute
/// la fonctionnalité cherche à établir : qui affirme quoi. Android a fait la même séparation.
struct CommunityOutage: Decodable, Identifiable, Equatable {
    let id: String
    let targetKind: String
    let targetId: String
    let marketCode: String
    let operatorKey: String
    let latitude: Double
    let longitude: Double
    let siteName: String?

    let state: OutageState
    let severity: OutageSeverity
    let affectsData: Bool
    let affectsVoice: Bool
    let affectsSms: Bool

    let confirmCount: Int
    let disputeCount: Int
    /// Voix encore attendues avant confirmation. 0 dès qu'elle est confirmée.
    let confirmationsRemaining: Int
    let confirmThreshold: Int

    /// Le fichier de l'opérateur a fini par reconnaître l'incident.
    let operatorConfirmed: Bool
    let operatorRaison: String?

    let startedAt: String?
    let reporterName: String?

    /// `report`, `confirm`, `dispute`, `repaired` — ou `nil` si on ne s'est pas prononcé.
    let myVote: String?
    /// Ni auteur, ni déjà positionné, et la panne est ouverte.
    let canVote: Bool

    /// Services touchés, tels qu'on les lit — pas trois icônes à décoder.
    var affectedServicesLabel: String {
        var parts: [String] = []
        if affectsData { parts.append("Internet") }
        if affectsVoice { parts.append("Voix") }
        if affectsSms { parts.append("SMS") }
        return parts.joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case id, targetKind, targetId, marketCode, operatorKey
        case latitude, longitude, lat, lng
        case siteName, state, severity
        case affectsData, affectsVoice, affectsSms
        case confirmCount, disputeCount, confirmationsRemaining, confirmThreshold
        case operatorConfirmed, operatorRaison, startedAt
        case reporter, myVote, canVote
    }

    private struct Reporter: Decodable { let displayName: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        targetKind = (try? c.decode(String.self, forKey: .targetKind)) ?? "anfr"
        targetId = (try? c.decode(String.self, forKey: .targetId)) ?? ""
        marketCode = (try? c.decode(String.self, forKey: .marketCode)) ?? ""
        operatorKey = (try? c.decode(String.self, forKey: .operatorKey)) ?? ""
        // La fiche REST rend `latitude`/`longitude`, la tuile carte `lat`/`lng`. On accepte les
        // deux plutôt que d'imposer au serveur une convention qu'il n'a pas.
        latitude = (try? c.decode(Double.self, forKey: .latitude))
            ?? (try? c.decode(Double.self, forKey: .lat)) ?? 0
        longitude = (try? c.decode(Double.self, forKey: .longitude))
            ?? (try? c.decode(Double.self, forKey: .lng)) ?? 0
        siteName = try? c.decodeIfPresent(String.self, forKey: .siteName)

        state = OutageState(rawServerValue: try? c.decodeIfPresent(String.self, forKey: .state))
        severity = OutageSeverity(rawServerValue: try? c.decodeIfPresent(String.self, forKey: .severity))
        affectsData = (try? c.decode(Bool.self, forKey: .affectsData)) ?? false
        affectsVoice = (try? c.decode(Bool.self, forKey: .affectsVoice)) ?? false
        affectsSms = (try? c.decode(Bool.self, forKey: .affectsSms)) ?? false

        confirmCount = (try? c.decode(Int.self, forKey: .confirmCount)) ?? 0
        disputeCount = (try? c.decode(Int.self, forKey: .disputeCount)) ?? 0
        confirmationsRemaining = (try? c.decode(Int.self, forKey: .confirmationsRemaining)) ?? 0
        confirmThreshold = (try? c.decode(Int.self, forKey: .confirmThreshold)) ?? 3

        operatorConfirmed = (try? c.decode(Bool.self, forKey: .operatorConfirmed)) ?? false
        operatorRaison = try? c.decodeIfPresent(String.self, forKey: .operatorRaison)
        startedAt = try? c.decodeIfPresent(String.self, forKey: .startedAt)
        reporterName = (try? c.decodeIfPresent(Reporter.self, forKey: .reporter))??.displayName

        myVote = try? c.decodeIfPresent(String.self, forKey: .myVote)
        canVote = (try? c.decode(Bool.self, forKey: .canVote)) ?? false
    }
}

struct CommunityOutagesResponse: Decodable, Equatable {
    let outages: [CommunityOutage]
}

// MARK: - Écriture

/// Corps d'un signalement.
///
/// ⚠️ La CIBLE est un identifiant, jamais des coordonnées de site : le serveur résout lui-même la
/// position depuis son référentiel. Si le client fournissait à la fois sa position et celle du
/// site, il tiendrait les deux bouts de la comparaison de proximité et l'éligibilité ne vaudrait
/// plus rien.
struct OutageReportRequest: Encodable {
    let targetKind: String
    let targetId: String?
    let marketCode: String
    let operatorKey: String
    let severity: String
    let affectsData: Bool
    let affectsVoice: Bool
    let affectsSms: Bool
    let latitude: Double?
    let longitude: Double?
    let accuracyMeters: Double?
}

struct OutageVoteRequest: Encodable {
    /// `confirm`, `dispute` ou `repaired` — les trois valent le même geste et le même gain.
    let kind: String
    let latitude: Double?
    let longitude: Double?
    let accuracyMeters: Double?
}

/// Réponse d'écriture. Le gain arrive au format universel de l'app, donc l'affichage des points
/// et des badges suit sans code spécifique.
struct OutageWriteResponse: Decodable {
    let outage: CommunityOutage?
    let award: OutageAward?
    let awards: [OutageAward]?

    struct OutageAward: Decodable {
        let type: String?
        let gamification: GamificationAwardPayload?
    }

    struct GamificationAwardPayload: Decodable {
        let pointsAwarded: Int?
        let levelUp: Bool?
        let capped: Bool?
    }

    /// Tous les gains de la réponse, que le serveur en ait rendu un ou plusieurs.
    ///
    /// Un vote peut en créditer DEUX d'un coup : la voix, et les points de l'auteur si c'est ce
    /// vote qui franchit le seuil et qu'on est cet auteur.
    var allAwards: [OutageAward] {
        if let awards, !awards.isEmpty { return awards }
        if let award { return [award] }
        return []
    }
}
