import Foundation

/// Fond de carte sélectionnable par l'utilisateur (parité Android `MapBackdropType`).
/// Le choix est stocké **en local** sous la clé `map_backdrop_type` (même clé qu'Android,
/// stockage distinct par plateforme). `applePlan` = Apple Plan natif (défaut) ;
/// `satellite` = imagerie Apple native ; `osm`/`topo` = tuiles raster (CDN tiers).
/// `carto` reste décodable pour les anciennes préférences mais ne charge plus de tuiles CARTO.
enum MapBackdrop: String, CaseIterable, Identifiable {
    case carto
    case applePlan
    case osm
    case topo
    case satellite

    var id: String { rawValue }

    static let storageKey = "map_backdrop_type"

    static let allCases: [MapBackdrop] = [.applePlan, .osm, .topo, .satellite]

    static func resolve(_ rawValue: String?) -> MapBackdrop {
        let stored = MapBackdrop(rawValue: rawValue ?? "") ?? .applePlan
        return stored == .carto ? .applePlan : stored
    }

    /// Migration idempotente, sans effacer les autres réglages ni changer leur clé.
    static func migrateLegacyPreference(in defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: storageKey) == MapBackdrop.carto.rawValue else { return }
        defaults.set(MapBackdrop.applePlan.rawValue, forKey: storageKey)
    }

    /// Valeur courante lue depuis UserDefaults (repli `.applePlan` = Apple Plan natif).
    static func current(in defaults: UserDefaults = .standard) -> MapBackdrop {
        resolve(defaults.string(forKey: storageKey))
    }

    var label: String {
        switch self {
        case .carto: return "Plan Apple"
        case .applePlan: return "Plan Apple"
        case .osm: return "OpenStreetMap"
        case .topo: return "Relief (OpenTopoMap)"
        case .satellite: return "Satellite"
        }
    }

    var subtitle: String {
        switch self {
        case .carto: return String(localized: "Carte Apple Plan native (par défaut)")
        case .applePlan: return String(localized: "Carte Apple Plan native (par défaut)")
        case .osm: return String(localized: "Cartographie communautaire détaillée")
        case .topo: return String(localized: "Courbes de niveau et relief")
        case .satellite: return String(localized: "Imagerie aérienne Apple (native)")
        }
    }

    var systemImage: String {
        switch self {
        case .carto: return "map.fill"
        case .applePlan: return "map.fill"
        case .osm: return "globe.europe.africa.fill"
        case .topo: return "mountain.2.fill"
        case .satellite: return "globe.americas.fill"
        }
    }

    /// Tuiles servies par un tiers hors `signalquest.fr` (donc non couvert par le
    /// pinning ATS) : la zone consultée est transmise au fournisseur. Les fonds
    /// Apple utilisent MapKit, sans overlay HTTP personnalisé.
    var usesThirdPartyTiles: Bool {
        switch self {
        case .carto, .applePlan, .satellite: return false
        case .osm, .topo: return true
        }
    }

    /// Rendu MapKit (migration moteur unique) : Apple Plan & imagerie en NATIF ;
    /// les autres fonds en tuiles raster (`MKTileOverlay`, ordre standard {z}/{x}/{y}).
    enum MapKitKind: Equatable {
        case applePlan
        case imagery
        case raster(template: String, maxZoom: Int)
    }

    var mapKitKind: MapKitKind {
        switch self {
        case .applePlan: return .applePlan
        case .satellite: return .imagery
        case .carto: return .applePlan
        case .osm: return .raster(template: "https://tile.openstreetmap.org/{z}/{x}/{y}.png", maxZoom: 19)
        case .topo: return .raster(template: "https://a.tile.opentopomap.org/{z}/{x}/{y}.png", maxZoom: 17)
        }
    }

}
