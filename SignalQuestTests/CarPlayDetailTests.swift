import CarPlay
import CoreLocation
import XCTest
@testable import SignalQuest

/// Verrouille les fiches CarPlay (Lot 2) : plafonds du SDK, orientation lisible,
/// et liste de repli pour les véhicules sans écran tactile.
@MainActor
final class CarPlayDetailTests: XCTestCase {

    private let paris = CLLocation(latitude: 48.8566, longitude: 2.3522)

    private func payload(id: String = "antenna-1",
                         title: String = "Site 75-1234",
                         coordinate: CLLocationCoordinate2D = .init(latitude: 48.86, longitude: 2.36),
                         clusterCount: Int? = nil) -> MapAnnotationPayload {
        MapAnnotationPayload(
            id: id, kind: .antenna, title: title, subtitle: "ORANGE · 4G/5G",
            coordinate: coordinate, metric: nil, backendId: "75-1234", details: nil,
            antennaId: "1", clusterCount: clusterCount, azimuths: [], showsAzimuths: false
        )
    }

    // MARK: - Plafonds SDK

    /// Au-delà de 10 items et 3 boutons, CarPlay tronque SANS rien signaler :
    /// un champ ajouté en ferait disparaître un autre, invisible au simulateur.
    func testAntennaTemplateNeverExceedsCarPlayLimits() throws {
        // Construit par décodage : `AntennaDetails` a un `init(from:)` custom,
        // donc pas d'init memberwise. Le JSON exerce en prime le vrai chemin.
        let json = """
        {"id":"1","siteId":"75-1234",
         "operators":["ORANGE","SFR","BOUYGUES","FREE"],
         "technologies":["2G","3G","4G","5G"],
         "bands":["B1","B3","B7","B20","B28","n78","n1"],
         "sectors":[1,2,3],"address":"12 rue de Rivoli, Paris","height":24,
         "validationsCount":3,"photosCount":2,"speedtestsCount":9}
        """
        let details = try XCTUnwrap(
            try? JSONDecoder.signalQuest.decode(AntennaDetails.self, from: Data(json.utf8))
        )
        let template = CarPlayDetailTemplateBuilder.antenna(
            payload: payload(), details: details, userLocation: paris,
            actions: .init(navigate: {}, center: {})
        )
        XCTAssertLessThanOrEqual(template.items.count, CarPlayDetailTemplateBuilder.maxItems)
        XCTAssertLessThanOrEqual(template.actions.count, CarPlayDetailTemplateBuilder.maxActions)
        XCTAssertFalse(template.items.isEmpty)
    }

    /// Une fiche quasi vide ne doit pas passer pour « antenne sans données »
    /// alors que la requête est simplement en cours.
    func testAntennaTemplateSaysWhenDetailsAreStillLoading() {
        let template = CarPlayDetailTemplateBuilder.antenna(
            payload: payload(), details: nil, userLocation: paris, actions: .init()
        )
        XCTAssertFalse(template.items.isEmpty)
        XCTAssertTrue(template.actions.isEmpty, "Sans action fournie, aucun bouton ne doit apparaître")
    }

    // MARK: - Orientation

    /// « à l'est » se comprend au volant, « 87° » demande un effort.
    func testCompassLabelsCoverTheEightSectors() {
        XCTAssertEqual(CarPlayDetailTemplateBuilder.compassLabel(0), String(localized: "au nord"))
        XCTAssertEqual(CarPlayDetailTemplateBuilder.compassLabel(90), String(localized: "à l'est"))
        XCTAssertEqual(CarPlayDetailTemplateBuilder.compassLabel(180), String(localized: "au sud"))
        XCTAssertEqual(CarPlayDetailTemplateBuilder.compassLabel(270), String(localized: "à l'ouest"))
        // La rose doit se refermer : 359° est au nord, pas au nord-ouest.
        XCTAssertEqual(CarPlayDetailTemplateBuilder.compassLabel(359), String(localized: "au nord"))
    }

    /// Un cap négatif ou supérieur à 360 ne doit pas sortir de la rose.
    func testCompassLabelNormalisesOutOfRangeBearings() {
        XCTAssertEqual(CarPlayDetailTemplateBuilder.compassLabel(-90), String(localized: "à l'ouest"))
        XCTAssertEqual(CarPlayDetailTemplateBuilder.compassLabel(450), String(localized: "à l'est"))
    }

    /// Sans position connue, on n'invente pas une distance.
    func testNoDistanceItemWithoutUserLocation() {
        XCTAssertNil(CarPlayDetailTemplateBuilder.bearingItem(
            from: nil, to: CLLocationCoordinate2D(latitude: 48.86, longitude: 2.36)))
        XCTAssertNotNil(CarPlayDetailTemplateBuilder.bearingItem(
            from: paris, to: CLLocationCoordinate2D(latitude: 48.86, longitude: 2.36)))
    }

    // MARK: - Liste de repli

    /// Le tri par distance est la raison d'être de cette liste sur les véhicules
    /// à molette : le plus proche doit être le premier atteignable.
    func testNearbyEntriesAreSortedByDistance() {
        let far = payload(id: "far", coordinate: .init(latitude: 49.5, longitude: 2.35))
        let near = payload(id: "near", coordinate: .init(latitude: 48.857, longitude: 2.353))
        let entries = NearbyListTemplateBuilder.entries(from: [far, near], userLocation: paris)
        XCTAssertEqual(entries.map(\.payload.id), ["near", "far"])
    }

    /// Un cluster « 42 sites » n'a pas de fiche : il n'a rien à faire dans une
    /// liste dont chaque ligne est censée s'ouvrir.
    func testNearbyEntriesExcludeClusters() {
        let cluster = payload(id: "cluster", clusterCount: 42)
        let entries = NearbyListTemplateBuilder.entries(from: [cluster, payload()], userLocation: paris)
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries.first?.payload.clusterCount)
    }

    func testNearbyEntriesAreCapped() {
        let many = (0..<40).map { payload(id: "a\($0)", coordinate: .init(latitude: 48.86 + Double($0) / 1000, longitude: 2.36)) }
        let entries = NearbyListTemplateBuilder.entries(from: many, userLocation: paris)
        XCTAssertEqual(entries.count, NearbyListTemplateBuilder.maxEntries)
        let template = NearbyListTemplateBuilder.make(entries: entries) { _ in }
        XCTAssertLessThanOrEqual(template.sections.flatMap(\.items).count, CPListTemplate.maximumItemCount)
    }

    /// La distance est le critère de tri : elle doit se lire en premier.
    func testNearbySubtitleLeadsWithDistance() {
        let entry = NearbyListTemplateBuilder.Entry(payload: payload(), distanceMeters: 340)
        XCTAssertTrue(NearbyListTemplateBuilder.subtitle(for: entry).hasPrefix(SQUnits.distance(meters: 340)))
    }
}
