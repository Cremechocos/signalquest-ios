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
        XCTAssertEqual(english.localizedString(forKey: "Couches", value: nil, table: nil), "Layers")
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

    func testSymbolPinHasLightAndDarkVariants() {
        let pin = CarPlayImageFactory.symbolPin(color: UIColor(SQColor.warning), symbol: "hammer.fill")
        let dark = pin.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertNotNil(dark)
        XCTAssertGreaterThan(pin.size.width, 0)
    }

    // MARK: - Écran « Couches »

    func testLayerListChecksTheCurrentLayerAndReportsTheChoice() {
        var chosen: CarPlayMapLayer?
        let template = CarPlayMapLayersTemplateBuilder.make(
            current: .planned, available: CarPlayMapLayer.allCases
        ) { chosen = $0 }

        let items = template.sections.flatMap(\.items).compactMap { $0 as? CPListItem }
        XCTAssertEqual(items.map { $0.userInfo as? CarPlayMapLayer }, CarPlayMapLayer.allCases)
        XCTAssertEqual(items.filter { $0.accessoryImage != nil }.count, 1)
        XCTAssertNotNil(items.first { ($0.userInfo as? CarPlayMapLayer) == .planned }?.accessoryImage)
        XCTAssertTrue(items.allSatisfy { $0.image != nil })

        items.last?.handler?(items[3], {})
        XCTAssertEqual(chosen, .outages)
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

    private func outage(id: String, lat: Double?, lon: Double?, operatorName: String, commune: String) throws -> OutageSiteLive {
        let position = [lat.map { "\"lat\": \($0)" }, lon.map { "\"lon\": \($0)" }].compactMap { $0 }
        let fields = (["\"id\": \"\(id)\"", "\"code_site_op\": \"\(id)\"", "\"issueType\": \"down\"",
                       "\"operator\": \"\(operatorName)\"", "\"commune\": \"\(commune)\""] + position)
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
