import XCTest
import MapKit
@testable import SignalQuest

final class MapViewportProjectionTests: XCTestCase {
    func testThe1024PointMapUsesTheSameZoomAsTheTileProjection() throws {
        let delta = try MapViewportProjection.longitudeDelta(zoom: 14, widthPoints: 1024)
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35),
                                        span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta))
        let measured = try MapViewportProjection.measured(region: region, widthPoints: 1024, heightPoints: 768)
        let legacy = log2(360 / region.span.longitudeDelta)
        XCTAssertEqual(measured.zoom, 14, accuracy: 1e-10)
        XCTAssertEqual(measured.zoom - legacy, 2, accuracy: 1e-10)
        XCTAssertEqual(measured.widthPoints, 1024)
    }

    func testZoomAndSpanRoundTripAtActualPhoneAndSplitViewWidths() throws {
        for width in [320.0, 390, 540, 768, 1024, 1366] {
            for zoom in [6.0, 10.99, 11, 13, 14.5, 16, 20] {
                let delta = try MapViewportProjection.longitudeDelta(zoom: zoom, widthPoints: width)
                XCTAssertEqual(try MapViewportProjection.zoom(longitudeDelta: delta, widthPoints: width), zoom, accuracy: 1e-10)
            }
        }
    }

    func testWorldSpanSaturatesAtTheWorldWithoutClaimingTheRequestedScaleWasKept() throws {
        XCTAssertEqual(try MapViewportProjection.longitudeDelta(zoom: 0, widthPoints: 1024), 360)
        XCTAssertEqual(try MapViewportProjection.zoom(longitudeDelta: 360, widthPoints: 1024), 2, accuracy: 1e-10)
        let snapshot = try MapViewportProjection.measured(mapRect: .world, widthPoints: 1024, heightPoints: 768)
        let plan = try MapTilePlanner.plan(bounds: snapshot.bounds, zoom: snapshot.zoom)
        XCTAssertEqual(plan.selectedZoom, 2)
        XCTAssertEqual(plan.tiles.count, 16)
        XCTAssertFalse(plan.clipsPolarArea)
    }

    func testMapRectPreservesTheViewportAcrossTheAntimeridian() throws {
        let origin = MKMapPoint(CLLocationCoordinate2D(latitude: 2, longitude: 179.8))
        let width = MKMapRect.world.width * 0.4 / 360
        let bottom = MKMapPoint(CLLocationCoordinate2D(latitude: -2, longitude: 179.8))
        let rect = MKMapRect(x: origin.x, y: origin.y, width: width, height: bottom.y - origin.y)
        let snapshot = try MapViewportProjection.measured(mapRect: rect, widthPoints: 390, heightPoints: 844)
        XCTAssertEqual(snapshot.bounds.west, 179.8, accuracy: 1e-8)
        XCTAssertEqual(snapshot.bounds.east, 180.2, accuracy: 1e-8)
        XCTAssertEqual(snapshot.bounds.north, 2, accuracy: 1e-8)
        XCTAssertEqual(snapshot.bounds.south, -2, accuracy: 1e-8)
        let plan = try MapTilePlanner.plan(bounds: snapshot.bounds, zoom: snapshot.zoom)
        XCTAssertEqual(plan.longitudeRanges.count, 2)
        XCTAssertLessThanOrEqual(plan.tiles.count, 24)
    }

    func testResizeChangesTheMeasuredZoomEvenWhenTheMapRectHasNotChanged() throws {
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35))
        let rect = MKMapRect(x: center.x - 4000, y: center.y - 3000, width: 8000, height: 6000)
        let phone = try MapViewportProjection.measured(mapRect: rect, widthPoints: 390, heightPoints: 844)
        let tablet = try MapViewportProjection.measured(mapRect: rect, widthPoints: 1024, heightPoints: 768)
        XCTAssertEqual(phone.bounds, tablet.bounds)
        XCTAssertEqual(tablet.zoom - phone.zoom, log2(1024.0 / 390.0), accuracy: 1e-10)
        XCTAssertNotEqual(phone, tablet, "A layout-size observer can detect a new geometry even without a region callback")
    }

    func testPortraitTabletKeepsCameraScaleButCanRequestCoarserDataToFitTheBudget() throws {
        let physicalZoom = 14.0
        let width = 1024.0, height = 1366.0
        let unitsPerPoint = MKMapRect.world.width / (256 * pow(2, physicalZoom))
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35))
        let rect = MKMapRect(x: center.x - width * unitsPerPoint / 2,
                             y: center.y - height * unitsPerPoint / 2,
                             width: width * unitsPerPoint, height: height * unitsPerPoint)
        let snapshot = try MapViewportProjection.measured(mapRect: rect, widthPoints: width, heightPoints: height)
        XCTAssertEqual(snapshot.zoom, physicalZoom, accuracy: 1e-10)
        let plan = try MapTilePlanner.plan(bounds: snapshot.bounds, zoom: snapshot.zoom)
        XCTAssertLessThanOrEqual(plan.tiles.count, 24)
        XCTAssertLessThan(plan.selectedZoom, Int(physicalZoom))
        XCTAssertEqual(snapshot.zoom, physicalZoom, "Planning data must not move the camera")
    }

    func testInvalidLayoutDoesNotSupplyAReferenceWidthOrAZeroCoordinate() {
        for size in [(0.0, 800.0), (390.0, 0.0), (.nan, 800.0), (390.0, .infinity), (-1.0, 800.0)] {
            XCTAssertThrowsError(try MapViewportProjection.measured(mapRect: .world, widthPoints: size.0, heightPoints: size.1)) {
                XCTAssertEqual($0 as? MapViewportProjectionError, .invalidViewportSize)
            }
        }
        XCTAssertThrowsError(try MapViewportProjection.zoom(longitudeDelta: 0, widthPoints: 390))
        XCTAssertThrowsError(try MapViewportProjection.zoom(longitudeDelta: .infinity, widthPoints: 390))
        XCTAssertThrowsError(try MapViewportProjection.longitudeDelta(zoom: .nan, widthPoints: 390))
    }

    func testInvalidMapRectIsNotPublishedAsGeometry() {
        for rect in [MKMapRect.null, MKMapRect(x: 0, y: 0, width: 0, height: 20),
                     MKMapRect(x: .nan, y: 0, width: 20, height: 20),
                     MKMapRect(x: 0, y: 0, width: .infinity, height: 20),
                     MKMapRect(x: .greatestFiniteMagnitude, y: 0, width: 20, height: 20)] {
            XCTAssertThrowsError(try MapViewportProjection.measured(mapRect: rect, widthPoints: 390, heightPoints: 844))
        }
    }

    func testInvalidRegionDoesNotTriggerAFalseEmptyMap() {
        for region in [
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 91, longitude: 2), span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)),
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48, longitude: 2), span: MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 1)),
            MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48, longitude: 2), span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: .nan)),
        ] {
            XCTAssertThrowsError(try MapViewportProjection.measured(region: region, widthPoints: 390, heightPoints: 844))
        }
    }
}
