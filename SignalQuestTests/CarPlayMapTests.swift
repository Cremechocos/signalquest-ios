import CarPlay
import MapKit
import XCTest
@testable import SignalQuest

/// Verrouille la carte CarPlay (Lot 1) : projection partagée avec l'iPhone,
/// conversion des tuiles en marqueurs, et grille des couches.
@MainActor
final class CarPlayMapTests: XCTestCase {

    // MARK: - Projection

    /// La carte du véhicule et celle de l'iPhone DOIVENT cadrer pareil : si les
    /// formules divergent, CarPlay demande des tuiles d'un autre niveau que
    /// celui affiché et des antennes manquent, sans erreur visible.
    func testProjectionRoundTripsBetweenZoomAndSpan() {
        for zoom in [8.0, 11.0, 13.0, 14.0, 16.0] {
            let span = SQMapProjection.span(forZoom: zoom, width: 390)
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35),
                span: span
            )
            XCTAssertEqual(SQMapProjection.zoom(forRegion: region, width: 390), zoom, accuracy: 0.001)
        }
    }

    /// L'extraction ne doit rien avoir changé pour la carte iPhone.
    func testMapKitMapViewDelegatesToSharedProjection() {
        let span = MapKitMapView.Coordinator.span(forZoom: 14, width: 390)
        XCTAssertEqual(span.longitudeDelta,
                       SQMapProjection.span(forZoom: 14, width: 390).longitudeDelta,
                       accuracy: 0.000001)
    }

    /// En dessous de z9 les lobes se chevauchent en une tache illisible : ils
    /// doivent disparaître, pas rétrécir.
    func testAzimuthReachVanishesWhenZoomedOut() {
        XCTAssertEqual(SQMapProjection.azimuthReach(forZoom: 8), 0)
        XCTAssertGreaterThan(SQMapProjection.azimuthReach(forZoom: 14), 0)
    }

    func testBoundsCoverTheWholeRegion() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 48.0, longitude: 2.0),
            span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.6)
        )
        let bounds = SQMapProjection.bounds(of: region)
        XCTAssertEqual(bounds.north, 48.2, accuracy: 0.0001)
        XCTAssertEqual(bounds.south, 47.8, accuracy: 0.0001)
        XCTAssertEqual(bounds.east, 2.3, accuracy: 0.0001)
        XCTAssertEqual(bounds.west, 1.7, accuracy: 0.0001)
    }

    // MARK: - Couches

    /// Les tuiles se recouvrent en bordure : sans dédoublonnage, un même site
    /// apparaît deux fois et son marqueur clignote à chaque rafraîchissement.
    func testAntennaPayloadsDeduplicateAcrossOverlappingTiles() throws {
        let tile = try decodeAntennaTile(markerIds: ["A", "B"])
        let neighbour = try decodeAntennaTile(markerIds: ["B", "C"])
        let payloads = CarPlayLayerController.antennaPayloads(from: [tile, neighbour], zoom: 14)
        XCTAssertEqual(payloads.count, 3)
        XCTAssertEqual(Set(payloads.map(\.id)).count, 3)
    }

    /// Même seuil que la carte iPhone : au-dessous de z13, pas de lobes.
    func testAzimuthsOnlyShowWhenZoomedIn() throws {
        let tile = try decodeAntennaTile(markerIds: ["A"])
        XCTAssertFalse(CarPlayLayerController.antennaPayloads(from: [tile], zoom: 11)[0].showsAzimuths)
        XCTAssertTrue(CarPlayLayerController.antennaPayloads(from: [tile], zoom: 14)[0].showsAzimuths)
    }

    /// Une mesure sans RSRP ne vaut pas une mesure relevée : elle doit être
    /// atténuée, pas affichée comme un point fiable.
    func testCoveragePointsWithoutRsrpAreDimmed() throws {
        let json = """
        {"tile":{"z":14,"x":8000,"y":5600},
         "points":[{"id":"p1","lat":48.85,"lng":2.35,"rsrp":-95},
                   {"id":"p2","lat":48.86,"lng":2.36}],
         "clusters":[]}
        """
        let tile = try JSONDecoder.signalQuest.decode(AndroidCoverageTileResponse.self,
                                                     from: Data(json.utf8))
        let features = CarPlayLayerController.coverageFeatures(from: [tile])
        XCTAssertEqual(features.count, 2)
        XCTAssertFalse(features[0].dimmed)
        XCTAssertTrue(features[1].dimmed)
    }

    // MARK: - Grille des couches

    /// Dépasser le plafond CarPlay tronque SILENCIEUSEMENT la grille : le défaut
    /// ne se verrait qu'en voiture.
    func testLayersGridStaysWithinCarPlayLimit() {
        let grid = LayersGridBuilder.make(current: [.antenna]) { _ in }
        XCTAssertLessThanOrEqual(grid.gridButtons.count, Int(CPGridTemplateMaximumItems))
        XCTAssertFalse(grid.gridButtons.isEmpty)
    }

    /// Une couleur seule ne se lit pas en roulant : l'état actif doit être écrit.
    func testActiveLayerIsMarkedInTheTitle() {
        XCTAssertTrue(LayersGridBuilder.title(for: .antenna, active: true).hasPrefix("✓"))
        XCTAssertFalse(LayersGridBuilder.title(for: .antenna, active: false).hasPrefix("✓"))
    }

    /// Amis, photos et validations n'ont rien à faire sur l'écran d'un véhicule.
    func testGridOnlyOffersDrivingRelevantLayers() {
        XCTAssertFalse(LayersGridBuilder.offered.contains(.friend))
        XCTAssertFalse(LayersGridBuilder.offered.contains(.photo))
        XCTAssertTrue(LayersGridBuilder.offered.contains(.antenna))
    }

    // MARK: - Fixtures

    private func decodeAntennaTile(markerIds: [String]) throws -> AndroidAntennaTileResponse {
        let markers = markerIds.map { id in
            """
            {"id":"\(id)","lat":48.85,"lng":2.35,"operators":["ORANGE"],
             "technologies":["4G","5G"],"azimuts":[0,120,240],"bands":[],
             "operators5G":[],"isZTD":false}
            """
        }.joined(separator: ",")
        let json = """
        {"tile":{"z":14,"x":8000,"y":5600},"clusters":[],"markers":[\(markers)]}
        """
        return try JSONDecoder.signalQuest.decode(AndroidAntennaTileResponse.self, from: Data(json.utf8))
    }
}
