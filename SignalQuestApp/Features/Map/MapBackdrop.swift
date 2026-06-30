import Foundation

/// Fond de carte sélectionnable par l'utilisateur (parité Android `MapBackdropType`).
/// Le choix est stocké **en local** sous la clé `map_backdrop_type` (même clé qu'Android,
/// stockage distinct par plateforme). `applePlan` = Apple Plan natif (défaut) ;
/// `satellite` = imagerie Apple native ; `carto`/`osm`/`topo` = tuiles raster (CDN tiers).
enum MapBackdrop: String, CaseIterable, Identifiable {
    case carto
    case applePlan
    case osm
    case topo
    case satellite

    var id: String { rawValue }

    static let storageKey = "map_backdrop_type"

    /// Valeur courante lue depuis UserDefaults (repli `.applePlan` = Apple Plan natif).
    static func current() -> MapBackdrop {
        MapBackdrop(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .applePlan
    }

    var label: String {
        switch self {
        case .carto: return "Plan (Carto)"
        case .applePlan: return "Plan Apple"
        case .osm: return "OpenStreetMap"
        case .topo: return "Relief (OpenTopoMap)"
        case .satellite: return "Satellite"
        }
    }

    var subtitle: String {
        switch self {
        case .carto: return "Tuiles Carto Positron (raster, clair)"
        case .applePlan: return "Carte Apple Plan native (par défaut)"
        case .osm: return "Cartographie communautaire détaillée"
        case .topo: return "Courbes de niveau et relief"
        case .satellite: return "Imagerie aérienne Apple (native)"
        }
    }

    var systemImage: String {
        switch self {
        case .carto: return "map"
        case .applePlan: return "map.fill"
        case .osm: return "globe.europe.africa.fill"
        case .topo: return "mountain.2.fill"
        case .satellite: return "globe.americas.fill"
        }
    }

    /// Tuiles servies par un tiers hors `signalquest.fr` (donc non couvert par le
    /// pinning ATS) : la zone consultée est transmise au fournisseur. Apple Plan &
    /// imagerie Apple sont natifs (pas de tiers).
    var usesThirdPartyTiles: Bool {
        switch self {
        case .applePlan, .satellite: return false
        case .carto, .osm, .topo: return true
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
        case .carto: return .raster(template: "https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png", maxZoom: 20)
        case .osm: return .raster(template: "https://tile.openstreetmap.org/{z}/{x}/{y}.png", maxZoom: 19)
        case .topo: return .raster(template: "https://a.tile.opentopomap.org/{z}/{x}/{y}.png", maxZoom: 17)
        }
    }

}
