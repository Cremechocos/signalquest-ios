import CarPlay
import CoreLocation
import SwiftUI

/// Couches de l'onglet Carte, affichées UNE à la fois (choix d'Alexandre, 12/11).
///
/// Une carte de points d'intérêt ne montre que 12 épingles : mélanger antennes,
/// pannes et projets en ferait douze points illisibles, dont aucun ne répond à
/// la question qu'on se pose. Une couche à la fois, ce sont les 12 plus proches
/// de CE qu'on cherche.
enum CarPlayMapLayer: CaseIterable, Equatable {
    case antennas, changes, planned, outages

    /// Rayon au-delà duquel un point n'est plus « autour » : pannes, projets et
    /// relevés ANFR arrivent pour tout le pays, pas pour la zone affichée.
    static let radiusMeters: CLLocationDistance = 50_000

    /// Couches servies dans un pays. Pannes, projets et relevés ANFR n'existent
    /// qu'en France : les proposer ailleurs ouvrirait une carte toujours vide.
    static func available(market: String) -> [CarPlayMapLayer] {
        market.uppercased() == "FR" ? allCases : [.antennas]
    }

    var menuTitle: String {
        switch self {
        case .antennas: return String(localized: "Antennes")
        case .changes: return String(localized: "Évolutions ANFR")
        case .planned: return String(localized: "Sites prévus")
        case .outages: return String(localized: "Pannes")
        }
    }

    var menuDetail: String {
        switch self {
        case .antennas: return String(localized: "Supports et opérateurs à proximité")
        case .changes: return String(localized: "Dernier relevé hebdomadaire de l'ANFR")
        case .planned: return String(localized: "Projets déclarés par les opérateurs")
        case .outages: return String(localized: "Incidents déclarés par les opérateurs")
        }
    }

    /// Ce que dit la carte quand la couche est réellement vide autour : sans
    /// vue vide dans ce template, une carte sans épingle laisserait douter.
    var emptyTitle: String {
        switch self {
        case .antennas: return String(localized: "Aucune antenne à proximité")
        case .changes: return String(localized: "Aucune évolution à proximité")
        case .planned: return String(localized: "Aucun site prévu à proximité")
        case .outages: return String(localized: "Aucune panne à proximité")
        }
    }

    /// Titre de la carte, la date du relevé pour les évolutions : « nouveau »
    /// ne veut rien dire sans dire depuis quand.
    func title(snapshotDate: String? = nil) -> String {
        guard self == .changes, let date = Self.shortDate(snapshotDate) else { return menuTitle }
        return String(localized: "Évolutions du \(date)")
    }

    /// Rayon du compte affiché dans la liste des couches. Les antennes arrivent
    /// par une zone de ±0,045° (5 km en latitude, 3,5 km en longitude) : seul
    /// un rayon de 3 km y tient entier.
    var countRadiusMeters: CLLocationDistance {
        self == .antennas ? 3_000 : Self.radiusMeters
    }

    var symbol: String {
        switch self {
        case .antennas: return "antenna.radiowaves.left.and.right"
        case .changes: return "clock.arrow.circlepath"
        case .planned: return "hammer.fill"
        case .outages: return "exclamationmark.triangle.fill"
        }
    }

    @MainActor var tint: UIColor {
        switch self {
        case .antennas: return CarPlayImageFactory.brandColor
        case .changes: return UIColor(SQColor.info)
        case .planned: return UIColor(SQColor.warning)
        case .outages: return UIColor(SQColor.danger)
        }
    }

    /// « 10 nov. » depuis « 2026-11-10 ».
    static func shortDate(_ raw: String?) -> String? {
        guard let raw, raw.count >= 10 else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "Europe/Paris")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(raw.prefix(10))) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Convertit les flux de chaque couche en marqueurs, bornés autour d'un point.
///
/// Pure, donc vérifiable sans réseau ni véhicule.
@MainActor
enum CarPlayMapLayerPoints {
    static func outageId(_ site: OutageSiteLive) -> String { "outage-\(site.id)" }
    static func plannedId(_ site: PlannedSiteLive) -> String { "planned-\(site.id)" }

    static func outages(_ sites: [OutageSiteLive], around center: CLLocation) -> [MapAnnotationPayload] {
        sites.compactMap { site in
            guard let coordinate = nearby(site.lat, site.lon, center) else { return nil }
            return MapAnnotationPayload(
                id: outageId(site),
                kind: .outage,
                // La nature de l'incident d'abord : c'est ce qu'on lit sur la fiche.
                title: CarPlayDetailTemplateBuilder.outageStatusLabel(site) ?? String(localized: "Site en panne"),
                subtitle: [operatorName(site.operator), site.commune]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                coordinate: coordinate,
                metric: nil,
                backendId: site.id,
                details: nil,
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                tint: SQColor.danger,
                glyphOverride: CarPlayMapLayer.outages.symbol
            )
        }
    }

    static func planned(_ sites: [PlannedSiteLive], around center: CLLocation) -> [MapAnnotationPayload] {
        sites.compactMap { site in
            guard let coordinate = nearby(site.lat, site.lon, center) else { return nil }
            let status = site.activation?.status ?? .planned
            return MapAnnotationPayload(
                id: plannedId(site),
                kind: .planned,
                title: CarPlayDetailTemplateBuilder.statusLabel(status),
                subtitle: [operatorName(site.operator),
                           NearestAntennaTemplateBuilder.generations(site.technologies),
                           site.commune ?? ""]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                coordinate: coordinate,
                metric: nil,
                backendId: site.codeSite ?? site.id,
                details: nil,
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                tint: SQColor.warning,
                plannedStatus: status,
                glyphOverride: CarPlayMapLayer.planned.symbol
            )
        }
    }

    /// Un support du dernier relevé ANFR, sous son changement dominant
    /// (« Mise en service », « Nouveau support »…), à la couleur et au glyphe
    /// de la carte des évolutions de l'iPhone.
    ///
    /// Marqueur de genre `.antenna` sans `antennaId` : la couche n'ouvre pas de
    /// fiche, tout tient dans la carte du point (titre, sous-titre, distance).
    static func changes(_ sites: [ANFRMapSite], around center: CLLocation) -> [MapAnnotationPayload] {
        sites.compactMap { site in
            guard site.hasValidCoordinate,
                  let coordinate = nearby(site.latitude, site.longitude, center) else { return nil }
            let type = dominantChange(site)
            let operators = site.antennas.isEmpty
                ? (site.summary?.operators ?? []).map(\.label)
                : site.antennas.compactMap { $0.operator?.label }
            return MapAnnotationPayload(
                id: "anfr-\(site.supId)",
                kind: .antenna,
                title: type.label,
                subtitle: [NearestAntennaTemplateBuilder.operatorNames(operators),
                           NearestAntennaTemplateBuilder.generations(site.antennas.map(\.generationRaw)),
                           site.city]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                coordinate: coordinate,
                metric: nil,
                backendId: site.supId,
                details: nil,
                antennaId: nil,
                clusterCount: nil,
                azimuths: [],
                showsAzimuths: false,
                tint: type.color,
                glyphOverride: type.glyph
            )
        }
    }

    /// Le changement qui résume le support, dans l'ordre de priorité du web.
    static func dominantChange(_ site: ANFRMapSite) -> ANFRModType {
        let types = site.antennas.isEmpty ? (site.summary?.presentTypes ?? []) : site.antennas.map(\.modType)
        return types.max { $0.priority < $1.priority } ?? .added
    }

    private static func operatorName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return SQBrand.operatorName(raw) ?? raw
    }

    private static func nearby(_ lat: Double?, _ lon: Double?, _ center: CLLocation) -> CLLocationCoordinate2D? {
        guard let lat, let lon, lat.isFinite, lon.isFinite else { return nil }
        let distance = center.distance(from: CLLocation(latitude: lat, longitude: lon))
        guard distance <= CarPlayMapLayer.radiusMeters else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// Racine de l'onglet Carte : une rangée par couche, avec ce qu'il y a autour.
///
/// La carte de points d'intérêt placée dans un onglet n'affiche pas ses boutons
/// de barre (iOS 27.3, CarPlay Simulator, 12/11) : le bouton « Couches » ne
/// s'y voyait jamais. Alexandre a choisi la liste : une touche ouvre la carte
/// de la couche, un retour y ramène.
@MainActor
enum CarPlayMapLayersTemplateBuilder {
    /// Ce qu'on sait du nombre de points d'une couche autour du véhicule.
    enum Count: Equatable {
        case loading
        case failed
        case value(Int)
    }

    static func make(available: [CarPlayMapLayer],
                     counts: [CarPlayMapLayer: Count] = [:],
                     onSelect: @escaping (CarPlayMapLayer) -> Void) -> CPListTemplate {
        CPListTemplate(title: String(localized: "Carte"),
                       sections: sections(available: available, counts: counts, onSelect: onSelect))
    }

    static func sections(available: [CarPlayMapLayer],
                         counts: [CarPlayMapLayer: Count],
                         onSelect: @escaping (CarPlayMapLayer) -> Void) -> [CPListSection] {
        let items = available.map { layer -> CPListItem in
            let item = CPListItem(
                text: layer.menuTitle,
                detailText: detail(for: layer, count: counts[layer]),
                image: CarPlayImageFactory.badge(fill: layer.tint, symbol: layer.symbol),
                accessoryImage: nil,
                accessoryType: .disclosureIndicator
            )
            item.userInfo = layer
            item.handler = { _, completion in
                onSelect(layer)
                completion()
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    /// « 2 pannes à moins de 50 km » ; ce que montre la couche tant que le
    /// compte n'est pas connu. Zéro se dit en toutes lettres.
    static func detail(for layer: CarPlayMapLayer, count: Count?) -> String {
        switch count {
        case nil, .loading?: return layer.menuDetail
        case .failed?: return String(localized: "Impossible de charger pour le moment.")
        case .value(let total)?:
            guard total > 0 else { return layer.emptyTitle }
            let radius = SQUnits.distanceCompact(meters: layer.countRadiusMeters)
            switch layer {
            case .antennas: return String(localized: "\(total) antennes à moins de \(radius)")
            case .changes: return String(localized: "\(total) évolutions à moins de \(radius)")
            case .planned: return String(localized: "\(total) sites prévus à moins de \(radius)")
            case .outages: return String(localized: "\(total) pannes à moins de \(radius)")
            }
        }
    }
}
