import Foundation

/// Fond de carte sélectionnable par l'utilisateur (parité Android `MapBackdropType`).
/// Le choix est stocké **en local** sous la clé `map_backdrop_type` (même clé qu'Android,
/// stockage distinct par plateforme). `carto` = style vectoriel sobre suivant le thème
/// clair/sombre (défaut) ; `osm`/`topo`/`satellite` = tuiles raster de CDN tiers.
enum MapBackdrop: String, CaseIterable, Identifiable {
    case carto
    case osm
    case topo
    case satellite

    var id: String { rawValue }

    static let storageKey = "map_backdrop_type"

    /// Valeur courante lue depuis UserDefaults (repli `.carto`).
    static func current() -> MapBackdrop {
        MapBackdrop(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .carto
    }

    var label: String {
        switch self {
        case .carto: return "Plan (Carto)"
        case .osm: return "OpenStreetMap"
        case .topo: return "Relief (OpenTopoMap)"
        case .satellite: return "Satellite"
        }
    }

    var subtitle: String {
        switch self {
        case .carto: return "Vectoriel sobre, suit le thème clair/sombre"
        case .osm: return "Cartographie communautaire détaillée"
        case .topo: return "Courbes de niveau et relief"
        case .satellite: return "Imagerie aérienne (ESRI)"
        }
    }

    var systemImage: String {
        switch self {
        case .carto: return "map"
        case .osm: return "globe.europe.africa.fill"
        case .topo: return "mountain.2.fill"
        case .satellite: return "globe.americas.fill"
        }
    }

    /// Tuiles servies par un tiers hors `signalquest.fr` (donc non couvert par le
    /// pinning ATS) : la zone consultée est transmise au fournisseur.
    var usesThirdPartyTiles: Bool { self != .carto }

    /// URL de style MapLibre à appliquer. Pour `carto`, l'URL vectorielle distante
    /// (thème-aware). Pour les fonds raster, un style JSON minimal est écrit dans un
    /// fichier de cache (MLNMapView iOS ne charge pas de JSON inline) puis renvoyé.
    func styleURL(dark: Bool) -> URL {
        switch self {
        case .carto:
            let style = dark ? "dark-matter-gl-style" : "positron-gl-style"
            if let url = URL(string: "https://basemaps.cartocdn.com/gl/\(style)/style.json") { return url }
            if let bundled = Bundle.main.url(forResource: "MapLibreStyle", withExtension: "json") { return bundled }
            return URL(string: "https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json") ?? URL(fileURLWithPath: "/")
        case .osm:
            return Self.rasterStyleURL(
                id: "osm",
                tiles: ["https://a.tile.openstreetmap.org/{z}/{x}/{y}.png",
                        "https://b.tile.openstreetmap.org/{z}/{x}/{y}.png",
                        "https://c.tile.openstreetmap.org/{z}/{x}/{y}.png"],
                maxZoom: 19,
                attribution: "© OpenStreetMap contributors"
            )
        case .topo:
            return Self.rasterStyleURL(
                id: "topo",
                tiles: ["https://a.tile.opentopomap.org/{z}/{x}/{y}.png",
                        "https://b.tile.opentopomap.org/{z}/{x}/{y}.png",
                        "https://c.tile.opentopomap.org/{z}/{x}/{y}.png"],
                maxZoom: 17,
                attribution: "© OpenTopoMap (CC-BY-SA)"
            )
        case .satellite:
            return Self.rasterStyleURL(
                id: "satellite",
                tiles: ["https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"],
                maxZoom: 19,
                attribution: "© Esri, Maxar, Earthstar Geographics"
            )
        }
    }

    /// Style MapLibre v8 raster minimal (une source + une couche), écrit une fois dans
    /// le dossier de cache et réutilisé. L'attribution est portée par la source (affichée
    /// via le bouton d'attribution de MapLibre).
    private static func rasterStyleURL(id: String, tiles: [String], maxZoom: Int, attribution: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("sq-basemap-\(id).json")
        if !FileManager.default.fileExists(atPath: url.path) {
            let tilesJSON = tiles.map { "\"\($0)\"" }.joined(separator: ",")
            let json = """
            {
              "version": 8,
              "sources": {
                "raster-\(id)": {
                  "type": "raster",
                  "tiles": [\(tilesJSON)],
                  "tileSize": 256,
                  "maxzoom": \(maxZoom),
                  "attribution": "\(attribution)"
                }
              },
              "layers": [
                { "id": "raster-\(id)-bg", "type": "background", "paint": { "background-color": "#0b0f14" } },
                { "id": "raster-\(id)-layer", "type": "raster", "source": "raster-\(id)" }
              ]
            }
            """
            try? json.data(using: .utf8)?.write(to: url, options: .atomic)
        }
        return url
    }
}
