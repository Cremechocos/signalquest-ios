import MapKit
import XCTest
@testable import SignalQuest

/// Verrouille `SQMapProjection`, la projection zoom ↔ région de la carte iPhone
/// (extraite à l'origine pour l'ancienne carte CarPlay).
@MainActor
final class SQMapProjectionTests: XCTestCase {

    /// Si l'aller-retour zoom → région → zoom diverge, la carte demande des
    /// tuiles d'un autre niveau que celui affiché et des antennes manquent,
    /// sans erreur visible.
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
}
