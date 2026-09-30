import CoreLocation
import XCTest
@testable import SignalQuest

/// Carte de partage d'un trajet (plan 3, vague 1).
@MainActor
final class DriveShareTests: XCTestCase {
    /// Trajet droit vers le nord, un point tous les ~111 m.
    private func straightTrip(points: Int = 41) -> DriveShareTrace {
        let route = (0..<points).map { CLLocationCoordinate2D(latitude: 45.0 + Double($0) * 0.001, longitude: 4.8) }
        let measures = [0, points / 2, points - 1].map { index in
            DriveShareTrace.Measure(coordinate: route[index], downloadMbps: 100, qualityRatio: 0.5)
        }
        return DriveShareTrace(route: route, measures: measures)
    }

    func testHidingTheEndsRemovesAboutHalfAKilometerAtEachEnd() {
        let trip = straightTrip()  // ~4,4 km
        let trimmed = trip.trimmingEnds()
        let first = CLLocation(latitude: trip.route[0].latitude, longitude: 4.8)
        let keptFirst = CLLocation(latitude: trimmed.route[0].latitude, longitude: 4.8)
        XCTAssertGreaterThanOrEqual(keptFirst.distance(from: first), DriveShareTrace.privacyTrimMeters)
        let last = CLLocation(latitude: trip.route.last!.latitude, longitude: 4.8)
        let keptLast = CLLocation(latitude: trimmed.route.last!.latitude, longitude: 4.8)
        XCTAssertGreaterThanOrEqual(keptLast.distance(from: last), DriveShareTrace.privacyTrimMeters)
        // Les mesures faites au départ et à l'arrivée partent avec eux.
        XCTAssertEqual(trimmed.measures.count, 1)
    }

    func testTooShortATripShowsNothingOnceItsEndsAreHidden() {
        let short = straightTrip(points: 8)  // ~780 m < 2 × 500 m
        XCTAssertTrue(short.trimmingEnds().route.isEmpty)
        XCTAssertTrue(short.trimmingEnds().measures.isEmpty)
    }

    func testThinningKeepsBothEnds() {
        let trip = straightTrip(points: 1_000)
        let thin = trip.thinned(to: 50)
        XCTAssertEqual(thin.route.count, 50)
        XCTAssertEqual(thin.route.first?.latitude, trip.route.first?.latitude)
        XCTAssertEqual(thin.route.last?.latitude, trip.route.last?.latitude)
    }

    func testNormalizedRouteFitsTheSquareWithNorthUp() {
        let normalized = straightTrip().normalized()
        let ys = normalized.route.map(\.y), xs = normalized.route.map(\.x)
        XCTAssertEqual(ys.min() ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(ys.max() ?? -1, 1, accuracy: 1e-9)
        // Vers le nord : le premier point est en bas, le dernier en haut.
        XCTAssertGreaterThan(ys.first ?? 0, ys.last ?? 1)
        // Trajet vertical : centré horizontalement, pas étiré.
        XCTAssertEqual(xs.first ?? 0, 0.5, accuracy: 1e-9)
    }

    private func recap(testCount: Int = 3) -> DriveTestViewModel.SessionRecap {
        DriveTestViewModel.SessionRecap(
            endedAt: Date(timeIntervalSince1970: 1_800_000_000), distanceMeters: 4_400, testCount: testCount,
            bytes: 1_000, stoppedByDataCap: false, vpnActive: false,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000 - 1_500),
            averageDownloadMbps: 175.9, maxDownloadMbps: 412.6, operatorLabel: "Orange"
        )
    }

    func testCardShowsTheTripFiguresAndHonoursTheOptions() {
        let full = DriveShareCardBuilder.model(recap: recap(), trace: straightTrip(),
                                               options: DriveShareOptions(), theme: .light)
        XCTAssertEqual(full.stats.count, 4)
        XCTAssertTrue(full.stats.contains { $0.value.contains("176") })
        XCTAssertTrue(full.stats.contains { $0.value.contains("413") })
        XCTAssertTrue(full.footer?.contains("Orange") == true)
        XCTAssertNil(full.routeCaption)
        XCTAssertFalse(full.route.isEmpty)

        var hidden = DriveShareOptions()
        hidden.showsRoute = false
        hidden.showsOperator = false
        let discreet = DriveShareCardBuilder.model(recap: recap(), trace: straightTrip(), options: hidden, theme: .light)
        XCTAssertTrue(discreet.route.isEmpty)
        XCTAssertTrue(discreet.measures.isEmpty)
        XCTAssertNotNil(discreet.routeCaption)
        XCTAssertFalse(discreet.footer?.contains("Orange") == true)
    }

    /// Relu depuis le disque, un résumé n'a pas de tracé : la carte le dit.
    func testRecapWithoutTraceStillMakesACard() {
        let model = DriveShareCardBuilder.model(recap: recap(), trace: nil, options: DriveShareOptions(), theme: .dark)
        XCTAssertTrue(model.route.isEmpty)
        XCTAssertNotNil(model.routeCaption)
        let image = DriveShareCardRenderer.render(model)
        XCTAssertEqual(image.size, CGSize(width: 2_160, height: 2_700))
    }

    /// Un résumé enregistré avant l'ajout des chiffres de partage se relit.
    func testOlderSavedRecapStillDecodes() throws {
        let older = #"{"endedAt":800000000,"distanceMeters":2140,"testCount":3,"bytes":612000000,"stoppedByDataCap":false,"vpnActive":false}"#
        let decoded = try JSONDecoder().decode(DriveTestViewModel.SessionRecap.self, from: Data(older.utf8))
        XCTAssertEqual(decoded.testCount, 3)
        XCTAssertNil(decoded.startedAt)
        XCTAssertNil(decoded.averageDownloadMbps)
    }
}
