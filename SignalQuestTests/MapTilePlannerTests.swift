import XCTest
import MapKit
@testable import SignalQuest

final class MapTilePlannerTests: XCTestCase {
    func testLargeViewportIncludesEveryCornerUnlikeTheLegacyPrefix() throws {
        let bounds = MapBounds(north: 48.95, south: 48.75, east: 2.55, west: 2.15)
        let plan = try MapTilePlanner.plan(bounds: bounds, zoom: 14)
        XCTAssertLessThanOrEqual(plan.tiles.count, 24)
        XCTAssertTrue(plan.usesReducedDetail)
        assertSamplesCovered(plan, original: bounds)
        let old = LegacySelection.visibleTiles(bounds: bounds, zoom: 14)
        XCTAssertFalse(contains(old, latitude: bounds.north, longitude: bounds.east))
        XCTAssertFalse(contains(old, latitude: bounds.south, longitude: bounds.east))
    }

    func testNarrowViewportKeepsItsRequestedDetail() throws {
        let bounds = MapBounds(north: 48.8568, south: 48.8564, east: 2.3524, west: 2.3520)
        let plan = try MapTilePlanner.plan(bounds: bounds, zoom: 15.8)
        XCTAssertEqual(plan.selectedZoom, 15)
        XCTAssertFalse(plan.usesReducedDetail)
        assertSamplesCovered(plan, original: bounds)
    }

    func testNormalizedAndUnwrappedAntimeridianBoundsHaveTheSameTiles() throws {
        let normalized = MapBounds(north: 2, south: -2, east: -179, west: 179)
        let unwrapped = MapBounds(north: 2, south: -2, east: 181, west: 179)
        let a = try MapTilePlanner.plan(bounds: normalized, zoom: 14)
        let b = try MapTilePlanner.plan(bounds: unwrapped, zoom: 14)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.longitudeRanges.count, 2)
        XCTAssertFalse(a.coversWholeWorldLongitude)
        assertSamplesCovered(a, original: normalized)
        assertSamplesCovered(b, original: unwrapped)
    }

    func testWesternWorldCopyMatchesTheEasternCrossing() throws {
        let west = MapBounds(north: 3, south: 1, east: -179, west: -181)
        let east = MapBounds(north: 3, south: 1, east: 181, west: 179)
        XCTAssertEqual(try MapTilePlanner.plan(bounds: west, zoom: 13),
                       try MapTilePlanner.plan(bounds: east, zoom: 13))
    }

    func testWorldViewportLowersZoomBeforeEnumerating() throws {
        let bounds = MapBounds(north: 90, south: -90, east: 180, west: -180)
        let plan = try MapTilePlanner.plan(bounds: bounds, zoom: 20, maximumZoom: 20)
        XCTAssertEqual(plan.selectedZoom, 2)
        XCTAssertEqual(plan.tiles.count, 16)
        XCTAssertEqual(Set(plan.tiles).count, 16)
        XCTAssertTrue(plan.coversWholeWorldLongitude)
        XCTAssertTrue(plan.clipsPolarArea)
        assertSamplesCovered(plan, original: bounds)
    }

    func testSingleTileBudgetCoversTheProjectedWorld() throws {
        let bounds = MapBounds(north: 85, south: -85, east: 180, west: -180)
        let plan = try MapTilePlanner.plan(bounds: bounds, zoom: 16, tileBudget: 1)
        XCTAssertEqual(plan.tiles, [AndroidMapTile(z: 0, x: 0, y: 0)])
        assertSamplesCovered(plan, original: bounds)
    }

    func testPolarClippingIsExplicitAndDoesNotInventAPolarTile() throws {
        for bounds in [MapBounds(north: 90, south: 80, east: 12, west: 8),
                       MapBounds(north: -80, south: -90, east: 12, west: 8)] {
            let plan = try MapTilePlanner.plan(bounds: bounds, zoom: 16)
            XCTAssertTrue(plan.clipsPolarArea)
            XCTAssertLessThanOrEqual(plan.north, MapTilePlanner.mercatorLatitudeLimit)
            XCTAssertGreaterThanOrEqual(plan.south, -MapTilePlanner.mercatorLatitudeLimit)
            assertSamplesCovered(plan, original: bounds)
        }
        for bounds in [MapBounds(north: 90, south: 89, east: 12, west: 8),
                       MapBounds(north: -89, south: -90, east: 12, west: 8)] {
            XCTAssertThrowsError(try MapTilePlanner.plan(bounds: bounds, zoom: 10)) {
                XCTAssertEqual($0 as? MapTilePlanningError, .outsideMercatorProjection)
            }
        }
    }

    func testBothAliasesOfTheAntimeridianBoundaryAreRequested() throws {
        for bounds in [MapBounds(north: 1, south: -1, east: 180, west: 179),
                       MapBounds(north: 1, south: -1, east: -179, west: -180),
                       MapBounds(north: 1, south: -1, east: 180, west: 180)] {
            let plan = try MapTilePlanner.plan(bounds: bounds, zoom: 8)
            XCTAssertTrue(plan.tiles.contains { $0.x == 0 })
            XCTAssertTrue(plan.tiles.contains { $0.x == (1 << plan.selectedZoom) - 1 })
            XCTAssertTrue(contains(plan.tiles, latitude: 0, longitude: 180))
            XCTAssertTrue(contains(plan.tiles, latitude: 0, longitude: -180))
        }
    }

    func testInvalidInputIsAnErrorRatherThanASuccessfulEmptySelection() {
        let valid = MapBounds(north: 50, south: 49, east: 3, west: 2)
        for bounds in [MapBounds(north: .nan, south: 49, east: 3, west: 2),
                       MapBounds(north: 50, south: 49, east: .infinity, west: 2),
                       MapBounds(north: 49, south: 50, east: 3, west: 2),
                       MapBounds(north: 91, south: 49, east: 3, west: 2),
                       MapBounds(north: 50, south: -91, east: 3, west: 2)] {
            XCTAssertThrowsError(try MapTilePlanner.plan(bounds: bounds, zoom: 10))
        }
        for zoom in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try MapTilePlanner.plan(bounds: valid, zoom: zoom))
        }
        for budget in [0, -1, 41, Int.max] { XCTAssertThrowsError(try MapTilePlanner.plan(bounds: valid, zoom: 10, tileBudget: budget)) }
        for cap in [-1, 21] { XCTAssertThrowsError(try MapTilePlanner.plan(bounds: valid, zoom: 10, maximumZoom: cap)) }
    }

    func testHugeFiniteZoomCannotTrapOnIntConversion() throws {
        let bounds = MapBounds(north: 1, south: -1, east: 1, west: -1)
        let plan = try MapTilePlanner.plan(bounds: bounds, zoom: .greatestFiniteMagnitude, detailBoost: .max)
        XCTAssertLessThanOrEqual(plan.tiles.count, 24)
        assertSamplesCovered(plan, original: bounds)
    }

    func testCoverageDetailBoostStillHonorsItsBudget() throws {
        let bounds = MapBounds(north: 53, south: 44, east: 9, west: -5)
        let plan = try MapTilePlanner.plan(bounds: bounds, zoom: 10.7, detailBoost: 1, tileBudget: 40)
        XCTAssertEqual(plan.desiredZoom, 11)
        XCTAssertLessThanOrEqual(plan.tiles.count, 40)
        XCTAssertTrue(plan.usesReducedDetail)
        assertSamplesCovered(plan, original: bounds)
    }

    func testSelectionUsesTheHighestDetailThatFitsTheBudget() throws {
        // Independent count oracle: count every intersecting native MapKit tile
        // at the next zoom, rather than recalculate the planner's range arithmetic.
        let bounds = MapBounds(north: 48.95, south: 48.75, east: 2.55, west: 2.15)
        let plan = try MapTilePlanner.plan(bounds: bounds, zoom: 14)
        let next = plan.selectedZoom + 1
        let rect = MKMapRect(
            x: MKMapPoint(CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west)).x,
            y: MKMapPoint(CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west)).y,
            width: MKMapPoint(CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.east)).x
                - MKMapPoint(CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west)).x,
            height: MKMapPoint(CLLocationCoordinate2D(latitude: bounds.south, longitude: bounds.east)).y
                - MKMapPoint(CLLocationCoordinate2D(latitude: bounds.north, longitude: bounds.west)).y
        )
        let size = MKMapRect.world.width / Double(1 << next)
        var count = 0
        for x in 0..<(1 << next) where Double(x) * size <= rect.maxX && Double(x + 1) * size >= rect.minX {
            for y in 0..<(1 << next) where Double(y) * size <= rect.maxY && Double(y + 1) * size >= rect.minY {
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 24)
    }

    func testSweptViewportsRemainCoveredAndBoundedAcrossLatitudesAndWorldCopies() throws {
        var checked = 0
        for latitude in [-80.0, -45, 0, 45, 80] {
            for longitude in [-540.0, -179.5, 0, 179.5, 540] {
                for span in [0.001, 0.4, 30, 360] {
                    let bounds = MapBounds(north: min(90, latitude + min(span, 20) / 2),
                                           south: max(-90, latitude - min(span, 20) / 2),
                                           east: longitude + span / 2, west: longitude - span / 2)
                    for budget in [1, 4, 24, 40] {
                        let plan = try MapTilePlanner.plan(bounds: bounds, zoom: 16, tileBudget: budget)
                        XCTAssertLessThanOrEqual(plan.tiles.count, budget)
                        XCTAssertEqual(plan.tiles.count, Set(plan.tiles).count)
                        XCTAssertTrue(plan.tiles.allSatisfy {
                            $0.z == plan.selectedZoom && (0..<(1 << $0.z)).contains($0.x) && (0..<(1 << $0.z)).contains($0.y)
                        })
                        assertSamplesCovered(plan, original: bounds)
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 400)
    }

    func testReturningToTheSameViewportProducesTheSameTileIDsAndOrder() throws {
        let a = MapBounds(north: 49, south: 48.7, east: 2.6, west: 2.1)
        let b = MapBounds(north: 50, south: 49.7, east: 3.6, west: 3.1)
        let initial = try MapTilePlanner.plan(bounds: a, zoom: 14)
        _ = try MapTilePlanner.plan(bounds: b, zoom: 14)
        XCTAssertEqual(try MapTilePlanner.plan(bounds: a, zoom: 14), initial)
    }

    private func assertSamplesCovered(_ plan: MapTilePlan, original: MapBounds, file: StaticString = #filePath, line: UInt = #line) {
        let delta = original.east - original.west
        let span = abs(delta) >= 360 ? 360 : delta < 0 ? delta + 360 : delta
        let south = max(-MapTilePlanner.mercatorLatitudeLimit, original.south)
        let north = min(MapTilePlanner.mercatorLatitudeLimit, original.north)
        for row in 0...4 {
            for column in 0...4 {
                let latitude = south + (north - south) * Double(row) / 4
                let rawLongitude = original.west + span * Double(column) / 4
                // Independent circular oracle, not the implementation's modulo helper.
                let radians = rawLongitude * .pi / 180
                let longitude = atan2(sin(radians), cos(radians)) * 180 / .pi
                XCTAssertTrue(contains(plan.tiles, latitude: latitude, longitude: longitude),
                              "Missing viewport sample \(latitude),\(longitude) at z\(plan.selectedZoom)", file: file, line: line)
            }
        }
    }

    private func contains(_ tiles: [AndroidMapTile], latitude: Double, longitude: Double) -> Bool {
        let point = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        let world = MKMapRect.world.width
        return tiles.contains { tile in
            let size = world / Double(1 << tile.z)
            let minX = Double(tile.x) * size, maxX = Double(tile.x + 1) * size
            let minY = Double(tile.y) * size, maxY = Double(tile.y + 1) * size
            // Borders are inclusive in the server bbox SQL. A small map-point
            // tolerance accounts only for projection roundoff at exact seams.
            let epsilon = 0.0001
            return point.x >= minX - epsilon && point.x <= maxX + epsilon
                && point.y >= minY - epsilon && point.y <= maxY + epsilon
        }
    }
}
