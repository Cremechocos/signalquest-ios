import CoreLocation

/// Territoire DROM (département) — miroir iOS de `DromRegion` d'Android
/// (`MapModels.kt`). Sert à **séparer les opérateurs par territoire** : les
/// opérateurs DROM sont géographiquement disjoints (la Martinique n'expose pas
/// SRR/Zeop de La Réunion, et inversement). Les clés opérateur sont celles du
/// registre iOS (`market_registry_fallback.json`, marché DROM).
///
/// Saint-Pierre-et-Miquelon (975) n'a pas d'opérateur mobile modélisé → pas de
/// case ici : `fromLocation`/`fromDepartment` renvoient `nil` et aucun filtre
/// n'est appliqué (tous les opérateurs DROM restent visibles).
enum DromRegion: String, CaseIterable, Equatable, Sendable {
    case guadeloupe = "971"
    case martinique = "972"
    case guyane = "973"
    case reunion = "974"
    case mayotte = "976"

    var department: String { rawValue }

    var displayName: String {
        switch self {
        case .guadeloupe: return "Guadeloupe"
        case .martinique: return "Martinique"
        case .guyane: return "Guyane"
        case .reunion: return "La Réunion"
        case .mayotte: return "Mayotte"
        }
    }

    /// Nom court pour les contrôles carte (« Réunion » plutôt que « La Réunion »).
    var shortName: String {
        self == .reunion ? "Réunion" : displayName
    }

    /// Drapeau régional (parité `MapTopControls.kt`).
    var flag: String {
        switch self {
        case .guadeloupe: return "🇬🇵"
        case .martinique: return "🇲🇶"
        case .guyane: return "🇬🇫"
        case .reunion: return "🇷🇪"
        case .mayotte: return "🇾🇹"
        }
    }

    var center: CLLocationCoordinate2D {
        switch self {
        case .guadeloupe: return CLLocationCoordinate2D(latitude: 16.265, longitude: -61.551)
        case .martinique: return CLLocationCoordinate2D(latitude: 14.6415, longitude: -61.0242)
        case .guyane: return CLLocationCoordinate2D(latitude: 4.0, longitude: -53.0)
        case .reunion: return CLLocationCoordinate2D(latitude: -21.115, longitude: 55.536)
        case .mayotte: return CLLocationCoordinate2D(latitude: -12.8275, longitude: 45.166)
        }
    }

    /// Clés opérateur (registre) exposées dans ce territoire — « ALL » implicite.
    var operatorKeys: Set<String> {
        switch self {
        case .guadeloupe, .martinique, .guyane:
            return ["ORANGE", "FREE_CARAIBES", "DIGICEL", "OUTREMER_TELECOM"]
        case .reunion:
            return ["ORANGE", "SRR", "TELCO_OI", "ZEOP"]
        case .mayotte:
            return ["ORANGE", "SRR", "TELCO_OI", "MAORE_MOBILE"]
        }
    }

    /// `true` si l'opérateur (clé registre) appartient à ce territoire, ou est un
    /// catch-all jamais filtré (« ALL » / « DROM_OTHER »).
    func allows(operatorKey: String) -> Bool {
        let key = operatorKey.uppercased()
        return key == "ALL" || key == "DROM_OTHER" || operatorKeys.contains(key)
    }

    static func fromDepartment(_ raw: String?) -> DromRegion? {
        guard let digits = raw?.filter(\.isNumber), !digits.isEmpty else { return nil }
        return DromRegion(rawValue: digits)
    }

    /// Territoire couvrant une position (mêmes emprises qu'Android `fromLocation`,
    /// Saint-Martin/Saint-Barthélemy rattachés à la Guadeloupe).
    static func from(latitude: Double, longitude: Double) -> DromRegion? {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        switch (latitude, longitude) {
        case (15.75...16.60, (-61.90)...(-61.00)),
             (17.80...18.20, (-63.25)...(-62.75)):
            return .guadeloupe
        case (14.35...14.95, (-61.25)...(-60.75)):
            return .martinique
        case (2.00...5.95, (-54.70)...(-51.45)):
            return .guyane
        case ((-21.45)...(-20.85), 55.15...55.95):
            return .reunion
        case ((-13.10)...(-12.55), 44.90...45.35):
            return .mayotte
        default:
            return nil
        }
    }

    static func from(_ coordinate: CLLocationCoordinate2D) -> DromRegion? {
        from(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Territoire par défaut pour un couple MCC/MNC (SIM DROM) — parité Android
    /// `defaultForMccMnc` (340 → Antilles, 647/1 → Mayotte, 647/* → Réunion).
    static func fromMccMnc(_ raw: String?) -> DromRegion? {
        let code = raw?.filter(\.isNumber) ?? ""
        guard code.count >= 3 else { return nil }
        let mcc = String(code.prefix(3))
        let mncTrimmed = String(code.dropFirst(3)).drop(while: { $0 == "0" })
        let mnc = mncTrimmed.isEmpty ? "0" : String(mncTrimmed)
        switch mcc {
        case "340": return .guadeloupe
        case "647": return mnc == "1" ? .mayotte : .reunion
        default: return nil
        }
    }
}
