import CarPlay
import CoreLocation
import MapKit
import XCTest
@testable import SignalQuest

/// Carte à couches (lot 2 de la refonte CarPlay, 12/11) : une couche à la fois,
/// les 12 points les plus proches, bornés à 50 km.
@MainActor
final class CarPlayMapLayersTests: XCTestCase {
    private let grenoble = CLLocation(latitude: 45.19, longitude: 5.72)

    // MARK: - Couches disponibles

    /// Pannes, projets et relevés ANFR n'existent qu'en France : ailleurs,
    /// les proposer ouvrirait une carte toujours vide.
    func testOnlyFranceOffersEveryLayer() {
        XCTAssertEqual(CarPlayMapLayer.available(market: "FR"), [.antennas, .changes, .planned, .outages])
        XCTAssertEqual(CarPlayMapLayer.available(market: "fr").count, 4)
        XCTAssertEqual(CarPlayMapLayer.available(market: "BE"), [.antennas])
        XCTAssertEqual(CarPlayMapLayer.available(market: "CA"), [.antennas])
    }

    func testEveryLayerHasItsOwnWording() {
        let layers = CarPlayMapLayer.allCases
        XCTAssertEqual(Set(layers.map(\.menuTitle)).count, layers.count)
        XCTAssertEqual(Set(layers.map(\.emptyTitle)).count, layers.count)
        XCTAssertEqual(Set(layers.map(\.symbol)).count, layers.count)
        for layer in layers {
            XCTAssertNotNil(UIImage(systemName: layer.symbol), "symbole introuvable : \(layer.symbol)")
            XCTAssertLessThanOrEqual(layer.menuDetail.count, 40, "coupé au-delà de ~40 caractères : \(layer.menuDetail)")
        }
    }

    /// « Évolutions » sans date ne dit pas depuis quand.
    func testChangesTitleCarriesTheSnapshotDate() {
        let dated = CarPlayMapLayer.changes.title(snapshotDate: "2026-11-10")
        XCTAssertNotEqual(dated, CarPlayMapLayer.changes.menuTitle)
        XCTAssertTrue(dated.contains("10"), dated)
        XCTAssertEqual(CarPlayMapLayer.changes.title(snapshotDate: nil), CarPlayMapLayer.changes.menuTitle)
        XCTAssertEqual(CarPlayMapLayer.changes.title(snapshotDate: "bientôt"), CarPlayMapLayer.changes.menuTitle)
        XCTAssertEqual(CarPlayMapLayer.outages.title(snapshotDate: "2026-11-10"), CarPlayMapLayer.outages.menuTitle,
                       "seules les évolutions portent une date")
    }

    func testNewStringsAreTranslated() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(english.localizedString(forKey: "Évolutions du %@", value: nil, table: nil), "Changes on %@")
        XCTAssertEqual(english.localizedString(forKey: "Aucune panne à proximité", value: nil, table: nil), "No outages nearby")
    }

    // MARK: - Pannes

    func testOutagesAreBoundedToTheRadius() throws {
        let near = try outage(id: "near", lat: 45.20, lon: 5.73, operatorName: "BOUYGUES", commune: "Meylan")
        let far = try outage(id: "far", lat: 48.85, lon: 2.35, operatorName: "SFR", commune: "Paris")
        let noPosition = try outage(id: "none", lat: nil, lon: nil, operatorName: "SFR", commune: "Nulle part")

        let payloads = CarPlayMapLayerPoints.outages([near, far, noPosition], around: grenoble)

        XCTAssertEqual(payloads.map(\.id), [CarPlayMapLayerPoints.outageId(near)])
        let point = try XCTUnwrap(payloads.first)
        XCTAssertEqual(point.kind, .outage)
        XCTAssertEqual(point.title, CarPlayDetailTemplateBuilder.outageStatusLabel(near))
        XCTAssertEqual(point.subtitle, "Bouygues Telecom · Meylan", "nom complet, puis la commune")
        XCTAssertEqual(point.glyphOverride, CarPlayMapLayer.outages.symbol)
    }

    /// Captures du 13/11 : « INT » et « CHINDRIEUX » s'affichaient tels quels.
    /// La voiture lit désormais l'incident comme la fiche de l'iPhone.
    func testOutageReadsTheIncidentLikeTheIPhoneSheet() throws {
        let interrupted = try outage(id: "int", lat: 45.20, lon: 5.73, operatorName: "BOUYGUES",
                                     commune: "CHINDRIEUX", raison: "INT")
        let point = try XCTUnwrap(CarPlayMapLayerPoints.outages([interrupted], around: grenoble).first)
        XCTAssertEqual(point.title, String(localized: "Interruption de service"))
        XCTAssertEqual(point.subtitle, "Bouygues Telecom · Chindrieux")

        let card = CarPlayDetailTemplateBuilder.outage(interrupted, userLocation: grenoble, actions: .init())
        let details = card.items.compactMap(\.detail)
        XCTAssertTrue(details.contains(String(localized: "Interruption de service")), "\(details)")
        XCTAssertTrue(details.contains("Bouygues Telecom"), "\(details)")
        XCTAssertTrue(details.contains("Chindrieux"), "\(details)")
        XCTAssertFalse(details.contains("INT"), "\(details)")

        let maintenance = try outage(id: "m", lat: 45.20, lon: 5.73, operatorName: "SFR", commune: "Meylan",
                                     raison: "maint")
        XCTAssertEqual(CarPlayDetailTemplateBuilder.outageStatusLabel(maintenance),
                       String(localized: "Maintenance programmée"))
    }

    /// Un code inconnu laisse parler le détail de l'opérateur, affiché une seule fois.
    func testUnknownOutageCodeFallsBackToTheOperatorDetail() throws {
        let explained = try outage(id: "x", lat: 45.20, lon: 5.73, operatorName: "SFR", commune: "Meylan",
                                   raison: "XYZ", detail: "Coupure électrique")
        XCTAssertEqual(CarPlayDetailTemplateBuilder.outageStatusLabel(explained), "Coupure électrique")
        let card = CarPlayDetailTemplateBuilder.outage(explained, userLocation: nil, actions: .init())
        XCTAssertEqual(card.items.compactMap(\.detail).filter { $0 == "Coupure électrique" }.count, 1)

        let bare = try outage(id: "y", lat: 45.20, lon: 5.73, operatorName: "SFR", commune: "Meylan", raison: "XYZ")
        XCTAssertEqual(CarPlayDetailTemplateBuilder.outageStatusLabel(bare), "XYZ")
    }

    /// Seule une commune tout en capitales est remise en forme : « La Tour-du-Pin »
    /// deviendrait « La Tour-Du-Pin ».
    func testCommuneLabelOnlyFixesAllCaps() {
        XCTAssertEqual(CarPlayDetailTemplateBuilder.communeLabel("CHINDRIEUX"), "Chindrieux")
        XCTAssertEqual(CarPlayDetailTemplateBuilder.communeLabel("La Tour-du-Pin"), "La Tour-du-Pin")
        XCTAssertEqual(CarPlayDetailTemplateBuilder.communeLabel("Meylan"), "Meylan")
        XCTAssertNil(CarPlayDetailTemplateBuilder.communeLabel(""))
        XCTAssertNil(CarPlayDetailTemplateBuilder.communeLabel(nil))
    }

    // MARK: - Sites prévus

    func testPlannedSitesShowStatusOperatorAndGenerations() throws {
        let site = try planned(key: "p1", lat: 45.18, lon: 5.70, operatorName: "SFR",
                               technologies: ["4G", "5G NR"], commune: "Seyssinet")
        let payloads = CarPlayMapLayerPoints.planned([site], around: grenoble)

        let point = try XCTUnwrap(payloads.first)
        XCTAssertEqual(point.id, CarPlayMapLayerPoints.plannedId(site))
        XCTAssertEqual(point.kind, .planned)
        XCTAssertEqual(point.title, CarPlayDetailTemplateBuilder.statusLabel(.planned))
        XCTAssertEqual(point.subtitle, "SFR · 5G, 4G · Seyssinet")
        XCTAssertEqual(point.glyphOverride, CarPlayMapLayer.planned.symbol)
    }

    // MARK: - Évolutions ANFR

    /// Un support aux changements mêlés se résume par le plus marquant, dans
    /// l'ordre du web : un nouveau support passe avant une mise en service.
    func testChangesUseTheDominantChange() throws {
        let site = ANFRMapSite(supId: "123", latitude: 45.19, longitude: 5.73, city: "Grenoble", antennas: [
            antenna(id: "a", operatorRaw: "ORANGE", generation: "4G", modType: "activated"),
            antenna(id: "b", operatorRaw: "BOUYGUES TELECOM", generation: "5G", modType: "new"),
        ])
        let far = ANFRMapSite(supId: "999", latitude: 43.6, longitude: 1.44, city: "Toulouse", antennas: [
            antenna(id: "c", operatorRaw: "SFR", generation: "5G", modType: "new"),
        ])

        let payloads = CarPlayMapLayerPoints.changes([site, far], around: grenoble)

        XCTAssertEqual(payloads.count, 1, "Toulouse est hors du rayon de 50 km")
        let point = try XCTUnwrap(payloads.first)
        XCTAssertEqual(CarPlayMapLayerPoints.dominantChange(site), .new)
        XCTAssertEqual(point.title, ANFRModType.new.label)
        XCTAssertEqual(point.glyphOverride, ANFRModType.new.glyph)
        XCTAssertNil(point.antennaId, "une évolution n'ouvre pas de fiche d'antenne")
        XCTAssertTrue(point.subtitle.hasPrefix("Orange / Bouygues Telecom"), point.subtitle)
        XCTAssertTrue(point.subtitle.hasSuffix("Grenoble"), point.subtitle)
    }

    func testChangesWithoutValidCoordinatesAreDropped() {
        let broken = ANFRMapSite(supId: "0", latitude: .nan, longitude: .nan, city: "", antennas: [])
        XCTAssertTrue(CarPlayMapLayerPoints.changes([broken], around: grenoble).isEmpty)
    }

    // MARK: - Choix des points

    /// Carte déplacée : les 12 points se choisissent autour de la zone
    /// affichée, mais la distance lue part toujours du véhicule.
    func testEntriesAreChosenAroundTheMapButMeasuredFromTheVehicle() {
        let vehicle = CLLocation(latitude: 45.19, longitude: 5.72)
        let mapCenter = CLLocation(latitude: 45.30, longitude: 5.72)
        let payloads = (0..<20).map { index in
            payload(id: "p\(index)", latitude: 45.19 + Double(index) * 0.01, longitude: 5.72)
        }

        let entries = CarPlayPOIBuilder.entries(from: payloads, userLocation: vehicle, around: mapCenter)

        XCTAssertEqual(entries.count, CarPlayPOIBuilder.maxPoints)
        XCTAssertEqual(entries.first?.payload.id, "p11", "le plus proche du centre de la carte vient en premier")
        XCTAssertEqual(entries.first?.distanceMeters ?? -1,
                       vehicle.distance(from: CLLocation(latitude: 45.30, longitude: 5.72)), accuracy: 1,
                       "distance mesurée depuis le véhicule")
    }

    func testLayerPointsCarryTheirSymbolPinAndOptionalDetails() {
        var marked = payload(id: "o", latitude: 45.2, longitude: 5.7)
        marked.glyphOverride = CarPlayMapLayer.outages.symbol
        let entries = [CarPlayPOIBuilder.Entry(payload: marked, distanceMeters: 800)]

        let withDetails = CarPlayPOIBuilder.points(from: entries, userLocation: grenoble,
                                                   actions: .init(details: { _ in }))
        let withoutDetails = CarPlayPOIBuilder.points(from: entries, userLocation: grenoble, actions: .init())

        XCTAssertNotNil(withDetails.first?.pinImage)
        XCTAssertNotNil(withDetails.first?.selectedPinImage)
        XCTAssertNotNil(withDetails.first?.primaryButton)
        XCTAssertNil(withoutDetails.first?.primaryButton, "les évolutions n'ont pas de bouton Détails")
    }

    // MARK: - Onglet Carte : liste des couches

    /// Le bouton de barre ne s'affiche pas sur une carte en onglet : la liste
    /// des couches est la racine, chaque rangée ouvre sa carte.
    func testLayerListOpensTheChosenLayer() {
        var chosen: CarPlayMapLayer?
        let template = CarPlayMapLayersTemplateBuilder.make(available: CarPlayMapLayer.allCases) { chosen = $0 }

        let items = template.sections.flatMap(\.items).compactMap { $0 as? CPListItem }
        XCTAssertEqual(template.title, String(localized: "Carte"))
        XCTAssertEqual(items.map { $0.userInfo as? CarPlayMapLayer }, CarPlayMapLayer.allCases)
        XCTAssertTrue(items.allSatisfy { $0.image != nil && $0.accessoryType == .disclosureIndicator })
        XCTAssertEqual(items.map(\.detailText), CarPlayMapLayer.allCases.map(\.menuDetail),
                       "tant que le compte n'est pas connu, la rangée dit ce que montre la couche")

        items[3].handler?(items[3], {})
        XCTAssertEqual(chosen, .outages)
    }

    /// Zéro se dit en toutes lettres ; un échec n'est pas un « aucune ».
    func testLayerRowSaysWhatIsAround() {
        typealias Builder = CarPlayMapLayersTemplateBuilder
        XCTAssertEqual(Builder.detail(for: .outages, count: .value(0)), CarPlayMapLayer.outages.emptyTitle)
        XCTAssertEqual(Builder.detail(for: .outages, count: .failed),
                       String(localized: "Impossible de charger pour le moment."))
        XCTAssertEqual(Builder.detail(for: .planned, count: .loading), CarPlayMapLayer.planned.menuDetail)
        let two = Builder.detail(for: .outages, count: .value(2))
        XCTAssertTrue(two.hasPrefix("2 "), two)
        XCTAssertTrue(two.contains(SQUnits.distanceCompact(meters: 50_000)), two)
        XCTAssertTrue(Builder.detail(for: .antennas, count: .value(12))
            .contains(SQUnits.distanceCompact(meters: 3_000)), "les antennes se comptent dans 3 km")
    }

    func testLayerCountsArePluralized() throws {
        func bundle(_ language: String) throws -> Bundle {
            try XCTUnwrap(Bundle(path: try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))))
        }
        let french = try bundle("fr"), english = try bundle("en")
        let cases: [(String, String, String, String, String)] = [
            ("%lld pannes à moins de %@", "1 panne à moins de 50 km", "3 pannes à moins de 50 km",
             "1 outage within 50 km", "3 outages within 50 km"),
            ("%lld sites prévus à moins de %@", "1 site prévu à moins de 50 km", "3 sites prévus à moins de 50 km",
             "1 planned site within 50 km", "3 planned sites within 50 km"),
            ("%lld évolutions à moins de %@", "1 évolution à moins de 50 km", "3 évolutions à moins de 50 km",
             "1 change within 50 km", "3 changes within 50 km"),
            ("%lld antennes à moins de %@", "1 antenne à moins de 50 km", "3 antennes à moins de 50 km",
             "1 antenna within 50 km", "3 antennas within 50 km"),
        ]
        for (key, fr1, fr3, en1, en3) in cases {
            let fr = french.localizedString(forKey: key, value: nil, table: nil)
            let en = english.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertEqual(String.localizedStringWithFormat(fr, 1, "50 km"), fr1)
            XCTAssertEqual(String.localizedStringWithFormat(fr, 3, "50 km"), fr3)
            XCTAssertEqual(String.localizedStringWithFormat(en, 1, "50 km"), en1)
            XCTAssertEqual(String.localizedStringWithFormat(en, 3, "50 km"), en3)
        }
    }

    /// Le recompte toutes les 2 minutes ne repasse plus par la phrase d'attente
    /// (captures du 13/11 : la liste clignotait) ; un échec ou une couche jamais
    /// comptée attend, et une couche qui n'est plus servie disparaît.
    func testRecountKeepsKnownCounts() {
        let previous: [CarPlayMapLayer: CarPlayMapLayersTemplateBuilder.Count] = [
            .antennas: .value(0), .outages: .value(6), .planned: .failed,
        ]
        let reloading = CarPlayMapLayersTemplateBuilder.reloading(previous, layers: [.antennas, .changes, .planned, .outages])
        XCTAssertEqual(reloading, [.antennas: .value(0), .changes: .loading, .planned: .loading, .outages: .value(6)])
        XCTAssertEqual(CarPlayMapLayersTemplateBuilder.reloading(previous, layers: [.antennas]), [.antennas: .value(0)])
    }

    // MARK: - « Y aller »

    func testDirectionsOpenPlansToThePoint() throws {
        let url = try XCTUnwrap(CarPlayPOIBuilder.directionsURL(
            to: CLLocationCoordinate2D(latitude: 45.19, longitude: 5.72)))
        XCTAssertEqual(url.absoluteString, "maps://?daddr=45.19,5.72&dirflg=d")
        XCTAssertNil(CarPlayPOIBuilder.directionsURL(to: CLLocationCoordinate2D(latitude: 200, longitude: 0)))
    }

    /// CarPlay ne publie pas le handler d'un `CPTextButton` : on vérifie que le
    /// bouton existe, le chemin vers Plans l'est par `directionsURL`.
    func testNavigateAddsAGoThereButton() {
        let entries = [CarPlayPOIBuilder.Entry(payload: payload(id: "a", latitude: 45.2, longitude: 5.7),
                                               distanceMeters: 800)]
        let points = CarPlayPOIBuilder.points(from: entries, userLocation: grenoble,
                                              actions: .init(navigate: { _ in }))
        XCTAssertEqual(points.first?.secondaryButton?.title, String(localized: "Y aller"))
        XCTAssertNil(points.first?.primaryButton, "sans fiche possible, pas de bouton Détails")
    }

    // MARK: - Icônes

    /// Pastille douce : le symbole garde la couleur du sens, assombrie ou
    /// éclaircie jusqu'à 4,5:1. Le jaune « Moyen » ne se lirait pas tel quel.
    func testSoftBadgeGlyphsStayReadable() {
        let tints: [UIColor] = [
            SQQualityScale.Signal.good.uiColor, SQQualityScale.Signal.fair.uiColor,
            SQQualityScale.Signal.poor.uiColor, SQNetworkColors.unknownUIColor,
            SQQualityScale.Generation.fiveG.uiColor, CarPlayImageFactory.brandColor,
            UIColor(SQColor.warning), UIColor(SQColor.danger), UIColor(SQColor.info),
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            for tint in tints {
                let glyph = CarPlayImageFactory.glyphColor(for: tint, style: style)
                let backdrop = CarPlayImageFactory.softBackdrop(for: tint, style: style)
                XCTAssertGreaterThanOrEqual(CarPlayImageFactory.contrast(glyph, backdrop), 4.5,
                                            "\(tint) en \(style == .dark ? "sombre" : "clair")")
            }
        }
    }

    func testPinsHaveLightAndDarkVariants() {
        let shared = [UIColor(SQBrand.operatorColor("SFR")), UIColor(SQBrand.operatorColor("BOUYGUES"))]
        for pin in [CarPlayImageFactory.antennaPin(fills: shared, fiveG: true),
                    CarPlayImageFactory.antennaPin(fills: [], selected: true),
                    CarPlayImageFactory.symbolPin(color: UIColor(SQColor.warning), symbol: "hammer.fill")] {
            XCTAssertNotNil(pin.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .dark)))
            XCTAssertGreaterThan(pin.size.width, 0)
        }
        XCTAssertGreaterThan(CarPlayImageFactory.antennaPin(fills: shared, selected: true).size.width,
                             CarPlayImageFactory.antennaPin(fills: shared).size.width,
                             "le point mis en avant est plus grand")
    }

    // MARK: - Rythme des rechargements

    /// Un déplacement pendant l'intervalle n'est pas perdu : il se charge à
    /// son terme, une seule fois, sur la DERNIÈRE zone demandée.
    func testRegionChangesAreThrottledAndCaughtUp() {
        var loaded: [CLLocationCoordinate2D] = []
        let caughtUp = expectation(description: "rattrapage")
        let controller = CarPlayPOIController(minimumInterval: 0.3) { region in
            loaded.append(region.center)
            caughtUp.fulfill()
        }
        controller.noteLoaded(center: CLLocationCoordinate2D(latitude: 45.19, longitude: 5.72))

        let template = CPPointOfInterestTemplate(title: "Antennes", pointsOfInterest: [], selectedIndex: NSNotFound)
        controller.pointOfInterestTemplate(template, didChangeMapRegion: region(latitude: 45.21))
        controller.pointOfInterestTemplate(template, didChangeMapRegion: region(latitude: 45.25))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(loaded.isEmpty, "pas de rechargement avant l'échéance")
        controller.pointOfInterestTemplate(template, didChangeMapRegion: region(latitude: 45.30))

        wait(for: [caughtUp], timeout: 2)
        // Un second rattrapage au même endroit serait un appel réseau pour rien.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(loaded.count, 1, "un seul chargement, à l'échéance")
        XCTAssertEqual(loaded.first?.latitude ?? 0, 45.30, accuracy: 0.0001, "la DERNIÈRE zone demandée")
    }

    func testInvalidateAllowsAnImmediateReload() {
        let reloaded = expectation(description: "rechargement immédiat")
        let controller = CarPlayPOIController(minimumInterval: 60) { _ in reloaded.fulfill() }
        controller.noteLoaded(center: CLLocationCoordinate2D(latitude: 45.19, longitude: 5.72))
        controller.invalidate()

        let template = CPPointOfInterestTemplate(title: "Antennes", pointsOfInterest: [], selectedIndex: NSNotFound)
        controller.pointOfInterestTemplate(template, didChangeMapRegion: region(latitude: 45.19))
        wait(for: [reloaded], timeout: 1)
    }

    // MARK: - Fabriques

    private func region(latitude: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: 5.72),
                           latitudinalMeters: 1_000, longitudinalMeters: 1_000)
    }

    private func payload(id: String, latitude: Double, longitude: Double) -> MapAnnotationPayload {
        MapAnnotationPayload(
            id: id, kind: .antenna, title: "Site \(id)", subtitle: "Orange · 4G",
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            metric: nil, backendId: id, details: nil, antennaId: id, clusterCount: nil,
            azimuths: [], showsAzimuths: false
        )
    }

    private func outage(id: String, lat: Double?, lon: Double?, operatorName: String, commune: String,
                        raison: String? = nil, detail: String? = nil) throws -> OutageSiteLive {
        let position = [lat.map { "\"lat\": \($0)" }, lon.map { "\"lon\": \($0)" }].compactMap { $0 }
        let incident = [raison.map { "\"raison\": \"\($0)\"" }, detail.map { "\"detail\": \"\($0)\"" }].compactMap { $0 }
        let fields = (["\"id\": \"\(id)\"", "\"code_site_op\": \"\(id)\"", "\"issueType\": \"down\"",
                       "\"operator\": \"\(operatorName)\"", "\"commune\": \"\(commune)\""] + position + incident)
            .joined(separator: ", ")
        return try JSONDecoder.signalQuest.decode(OutageSiteLive.self, from: Data("{\(fields)}".utf8))
    }

    private func planned(key: String, lat: Double, lon: Double, operatorName: String,
                         technologies: [String], commune: String) throws -> PlannedSiteLive {
        let techs = technologies.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {"plannedKey": "\(key)", "lat": \(lat), "lon": \(lon), "operator": "\(operatorName)",
         "technologies": [\(techs)], "commune": "\(commune)"}
        """
        return try JSONDecoder.signalQuest.decode(PlannedSiteLive.self, from: Data(json.utf8))
    }

    private func antenna(id: String, operatorRaw: String, generation: String, modType: String) -> ANFRMapAntenna {
        ANFRMapAntenna(id: id, supId: "123", operatorRaw: operatorRaw, system: "LTE 1800",
                       generationRaw: generation, modTypeRaw: modType, statut: "En service",
                       dateMaj: "2026-11-10", latitude: 45.19, longitude: 5.73, city: "Grenoble", address: nil)
    }
}
