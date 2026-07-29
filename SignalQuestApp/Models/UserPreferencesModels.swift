import Foundation

/// Préférences de compte (`GET/PATCH /api/user/preferences`).
///
/// Elles existaient côté serveur depuis longtemps — le web et Android les
/// réglaient, iOS ne les lisait même pas. Décodage tolérant : le serveur ne
/// renvoie pas toujours `showHypothesisSystem` selon la version déployée.
struct UserPreferences: Codable, Equatable, Sendable {
    var unitsSystem: SQUnitsSystem
    /// Marché par défaut de la carte (« FR », « CA »…). `nil` = déduit.
    var defaultMarket: String?
    /// Afficher son identifiant `@` à la place de son nom dans les classements.
    var showHandleOnLeaderboard: Bool
    /// Afficher le système d'hypothèses d'identification.
    var showHypothesisSystem: Bool

    enum CodingKeys: String, CodingKey {
        case unitsSystem, defaultMarket, showHandleOnLeaderboard, showHypothesisSystem
    }

    init(
        unitsSystem: SQUnitsSystem = .metric,
        defaultMarket: String? = nil,
        showHandleOnLeaderboard: Bool = false,
        showHypothesisSystem: Bool = true
    ) {
        self.unitsSystem = unitsSystem
        self.defaultMarket = defaultMarket
        self.showHandleOnLeaderboard = showHandleOnLeaderboard
        self.showHypothesisSystem = showHypothesisSystem
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unitsSystem = c.decodeFlexibleString(forKey: .unitsSystem)
            .flatMap(SQUnitsSystem.init(rawValue:)) ?? .metric
        defaultMarket = c.decodeFlexibleString(forKey: .defaultMarket)
        showHandleOnLeaderboard = (try? c.decodeIfPresent(Bool.self, forKey: .showHandleOnLeaderboard)) ?? false
        showHypothesisSystem = (try? c.decodeIfPresent(Bool.self, forKey: .showHypothesisSystem)) ?? true
    }
}

/// Une zone privée (`GET/POST/PATCH /api/user/zones`).
///
/// C'est un réglage de VIE PRIVÉE : autour d'une zone déclarée, les speedtests
/// peuvent être masqués de la carte publique. Le compte de test en avait une
/// (« Domicile ») réglée depuis le web, qu'iOS n'affichait nulle part.
struct PrivacyZone: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    /// `home`, `work`, `custom`… — libre côté serveur.
    var type: String?
    var latitude: Double?
    var longitude: Double?
    /// Rayon en mètres.
    var radius: Double?
    var isActive: Bool
    /// Masquer les speedtests réalisés dans cette zone sur la carte publique.
    var hideSpeedtestsOnMap: Bool
    var visitCount: Int?
    var isAutoDetected: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, type, latitude, longitude, radius, isActive
        case hideSpeedtestsOnMap, visitCount, isAutoDetected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        name = c.decodeFlexibleString(forKey: .name) ?? String(localized: "Zone")
        type = c.decodeFlexibleString(forKey: .type)
        latitude = try? c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .longitude)
        radius = try? c.decodeIfPresent(Double.self, forKey: .radius)
        isActive = (try? c.decodeIfPresent(Bool.self, forKey: .isActive)) ?? true
        hideSpeedtestsOnMap = (try? c.decodeIfPresent(Bool.self, forKey: .hideSpeedtestsOnMap)) ?? false
        visitCount = try? c.decodeIfPresent(Int.self, forKey: .visitCount)
        isAutoDetected = (try? c.decodeIfPresent(Bool.self, forKey: .isAutoDetected)) ?? false
    }

    /// `Domicile · 121 m · 344 visites` — la ligne de résumé.
    var summary: String {
        var parts: [String] = []
        if let radius { parts.append(SQUnits.radius(meters: radius)) }
        if let visitCount, visitCount > 0 {
            parts.append(visitCount <= 1 ? "\(visitCount) visite" : "\(visitCount) visites")
        }
        if isAutoDetected { parts.append(String(localized: "détectée")) }
        return parts.joined(separator: " · ")
    }

    var typeLabel: String {
        switch (type ?? "").lowercased() {
        case "home": return String(localized: "Domicile")
        case "work": return String(localized: "Travail")
        default: return String(localized: "Personnalisée")
        }
    }

    var typeIcon: String {
        switch (type ?? "").lowercased() {
        case "home": return "house.fill"
        case "work": return "briefcase.fill"
        default: return "mappin.circle.fill"
        }
    }
}

struct PrivacyZonesResponse: Decodable {
    let zones: [PrivacyZone]

    enum CodingKeys: String, CodingKey { case zones }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zones = c.decodeLossyArray([PrivacyZone].self, forKey: .zones)
    }
}
