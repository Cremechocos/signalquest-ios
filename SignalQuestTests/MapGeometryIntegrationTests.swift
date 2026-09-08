import XCTest
import MapKit
@testable import SignalQuest

final class MapGeometryIntegrationTests: XCTestCase {
    func testViewportAdmissionWaitsForConfigurationAndMeasuredGeometry() throws {
        var gate = MapViewportLoadGate()
        gate.configure()
        XCTAssertNil(gate.admitted)
        gate.pause()
        let measured = try MapViewportProjection.measured(mapRect: .world, widthPoints: 1024, heightPoints: 768)
        gate.record(measured)
        XCTAssertNil(gate.admitted)
        gate.configure()
        XCTAssertEqual(gate.admitted, measured)
        XCTAssertEqual(gate.admitted?.zoom, 2)
    }

    func testFiltersReuseTheMeasuredViewportAndAResizeReplacesIt() throws {
        var gate = MapViewportLoadGate()
        let narrow = try MapViewportProjection.measured(mapRect: .world, widthPoints: 390, heightPoints: 844)
        let wide = try MapViewportProjection.measured(mapRect: .world, widthPoints: 1024, heightPoints: 768)
        gate.record(narrow)
        gate.configure()
        let filterReload = gate.admitted
        XCTAssertEqual(filterReload, narrow)
        gate.record(wide)
        XCTAssertEqual(gate.admitted, wide)
        XCTAssertNotEqual(filterReload?.zoom, gate.admitted?.zoom)
        gate.invalidateCamera()
        XCTAssertNil(gate.admitted, "An old region must not race a new camera intent")
        gate.record(wide)
        XCTAssertEqual(gate.admitted, wide)
        gate.pause()
        XCTAssertNil(gate.admitted)
    }

    func testBoundsContainmentAndRESTSegmentsAreCircular() throws {
        for bounds in [MapBounds(north: 5, south: -5, east: -179, west: 179),
                       MapBounds(north: 5, south: -5, east: 181, west: 179)] {
            XCTAssertTrue(bounds.contains(lat: 0, lon: 179.5))
            XCTAssertTrue(bounds.contains(lat: 0, lon: -179.5))
            XCTAssertTrue(bounds.contains(lat: 0, lon: 180))
            XCTAssertTrue(bounds.contains(lat: 0, lon: -180))
            XCTAssertFalse(bounds.contains(lat: 0, lon: 0))
            XCTAssertFalse(bounds.contains(lat: 6, lon: 179.5))
            let segments = try bounds.canonicalSegments
            XCTAssertEqual(segments.count, 2)
            XCTAssertTrue(segments.allSatisfy { $0.west <= $0.east && $0.west >= -180 && $0.east <= 180 })
            XCTAssertEqual(segments[0], MapBounds(north: 5, south: -5, east: 180, west: 179))
            XCTAssertEqual(segments[1], MapBounds(north: 5, south: -5, east: -179, west: -180))
        }
        XCTAssertFalse(MapBounds(north: .nan, south: 0, east: 1, west: 0).contains(lat: 0, lon: 0))
    }

    func testSingleNonNormalizedRESTViewportIsCanonicalizedWithoutExpandingItsArea() throws {
        let bounds = MapBounds(north: 2, south: 1, east: 370, west: 368)
        XCTAssertEqual(try bounds.canonicalSegments, [MapBounds(north: 2, south: 1, east: 10, west: 8)])
        XCTAssertThrowsError(try MapBounds(north: 1, south: 2, east: 10, west: 8).canonicalSegments)
    }

    func testLightweightMergeNeverDoublesGlobalSocialCounts() throws {
        let a = snapshot(globalCount: 7, coverageCount: 2, speedCount: 3)
        let b = snapshot(globalCount: 8, coverageCount: 4, speedCount: 5)
        let merged = try MapSnapshotMerging.social([a, b], lightweight: true)
        XCTAssertEqual(merged.photosCount, 8)
        XCTAssertEqual(merged.validationsCount, 8)
        XCTAssertEqual(merged.sessionsCount, 8)
        XCTAssertEqual(merged.coveragePointsCount, 6)
        XCTAssertEqual(merged.speedtestsCount, 8)
        XCTAssertEqual(merged.rawCoveragePointsCount, 6)
        XCTAssertEqual(merged.logicalCoveragePointsCount, 6)
    }

    func testHeavyMergeDeduplicatesReturnedIDsWithoutInventingDatasetTotals() throws {
        let a = snapshot(globalCount: 100, coverageCount: 0, speedCount: 100, speedIDs: ["a", "shared"])
        let b = snapshot(globalCount: 100, coverageCount: 0, speedCount: 100, speedIDs: ["shared", "b"])
        let merged = try MapSnapshotMerging.social([a, b], lightweight: false)
        XCTAssertEqual(merged.speedtests.map(\.id), ["a", "shared", "b"])
        XCTAssertEqual(merged.speedtestsCount, 3)
        XCTAssertEqual(merged.photosCount, 0)
    }

    func testLatestGlobalFriendsListCanRemoveAPreviouslySharedFriend() throws {
        let friend = SocialFriendLive(id: "friend", name: nil, avatarUrl: nil, presence: nil, location: nil, radio: nil, privacy: nil)
        let a = snapshot(globalCount: 0, coverageCount: 0, speedCount: 0, friends: [friend])
        let b = snapshot(globalCount: 0, coverageCount: 0, speedCount: 0)
        XCTAssertTrue(try MapSnapshotMerging.social([a, b], lightweight: true).friends.isEmpty)
    }

    func testCountOverflowIsRejectedInsteadOfCrashingOrFabricatingATotal() {
        let a = snapshot(globalCount: 0, coverageCount: Int.max, speedCount: 0)
        let b = snapshot(globalCount: 0, coverageCount: 1, speedCount: 0)
        XCTAssertThrowsError(try MapSnapshotMerging.social([a, b], lightweight: true))
        XCTAssertThrowsError(try MapSnapshotMerging.social([], lightweight: true))
    }

    func testDataLimitsRemainVisibleEvenWhenATileReturnsNoMarkers() throws {
        let speed = try JSONDecoder.signalQuest.decode(AndroidSpeedtestTileResponse.self, from: Data(#"{"tile":{"z":2,"x":1,"y":1},"markers":[],"clusters":[],"stats":{"hasMore":true,"nextOffset":20000,"truncated":true}}"#.utf8))
        XCTAssertTrue(MapDataLimits.speedtests([speed]))
        let coverage = try JSONDecoder.signalQuest.decode(AndroidCoverageTileResponse.self, from: Data(#"{"tile":{"z":2,"x":1,"y":1},"points":[],"clusters":[],"stats":{"sampleCount":10,"truncated":true}}"#.utf8))
        XCTAssertTrue(MapDataLimits.coverage([coverage]))
    }

    private func snapshot(globalCount: Int, coverageCount: Int, speedCount: Int,
                          speedIDs: [String] = [], friends: [SocialFriendLive] = []) -> SocialMapSnapshot {
        SocialMapSnapshot(timestamp: Date(timeIntervalSince1970: 100), friends: friends, photos: [], validations: [], sessions: [],
            coveragePoints: [], speedtests: speedIDs.map {
                SocialSpeedtestLive(id: $0, userId: nil, latitude: 0, longitude: 179.5, averageSpeed: 100,
                                    uploadAvg: nil, pingAvg: nil, timestamp: nil, networkType: nil, mobileOperator: nil)
            }, photosCount: globalCount, validationsCount: globalCount, sessionsCount: globalCount,
            coveragePointsCount: coverageCount, speedtestsCount: speedCount,
            rawCoveragePointsCount: coverageCount, logicalCoveragePointsCount: coverageCount)
    }
}
