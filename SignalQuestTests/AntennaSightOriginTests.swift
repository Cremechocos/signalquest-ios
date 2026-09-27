import CoreLocation
import XCTest
@testable import SignalQuest

final class AntennaSightOriginTests: XCTestCase {
    func testSelectedAddressWinsOverDeviceLocation() throws {
        let origin = AntennaSightOrigin.resolve(query: "", latitudeText: "48.85", longitudeText: "2.35", title: "Paris")
        let coordinate = try XCTUnwrap(origin.coordinate(deviceLocation: CLLocation(latitude: 43.3, longitude: 5.4)))
        XCTAssertEqual(coordinate.latitude, 48.85)
        XCTAssertEqual(coordinate.longitude, 2.35)
        XCTAssertFalse(origin.isDevice)
    }

    func testUnresolvedNewSearchDoesNotReusePreviousAddressOrGPS() {
        let origin = AntennaSightOrigin.resolve(query: "Nouvelle adresse", latitudeText: "48.85", longitudeText: "2.35", title: "Paris")
        XCTAssertEqual(origin, .unresolved)
        XCTAssertNil(origin.coordinate(deviceLocation: CLLocation(latitude: 43.3, longitude: 5.4)))
    }

    func testClearingSearchRestoresOnlyAdmittedDeviceLocation() throws {
        let origin = AntennaSightOrigin.resolve(query: "", latitudeText: "", longitudeText: "", title: "")
        XCTAssertEqual(origin, .device)
        XCTAssertNil(origin.coordinate(deviceLocation: nil))
        XCTAssertEqual(try XCTUnwrap(origin.coordinate(deviceLocation: CLLocation(latitude: 43.3, longitude: 5.4))).latitude, 43.3)
    }

    func testInvalidStoredAddressNeverFallsBackToGPS() {
        for latitude in ["not a coordinate", "nan", "91", ""] {
            let origin = AntennaSightOrigin.resolve(query: "", latitudeText: latitude, longitudeText: "2.35", title: "Paris")
            XCTAssertEqual(origin, .unresolved)
            XCTAssertNil(origin.coordinate(deviceLocation: CLLocation(latitude: 43.3, longitude: 5.4)))
        }
    }

    func testReplacingAddressChangesOriginEvenWithinOldRoundedCacheCell() {
        let old = AntennaSightOrigin.resolve(query: "", latitudeText: "48.85001", longitudeText: "2.35", title: "A")
        let new = AntennaSightOrigin.resolve(query: "", latitudeText: "48.85002", longitudeText: "2.35", title: "B")
        XCTAssertNotEqual(old, new)
    }
}

final class AntennaSightGPSSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = LocationFixPolicy(maxAge: 60, maximumAccuracy: nil)

    private func fix(northMeters: Double = 0, timestamp: Date) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: northMeters / 110_574, longitude: 0),
                   altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: timestamp)
    }

    func testJitterRetainsExactOriginalFixAndRevision() throws {
        var snapshot = AntennaSightGPSSnapshot()
        let first = fix(timestamp: now)
        snapshot.update(current: first, policy: policy, now: now)
        let revision = snapshot.revision
        for meters in [1.0, 10, 30, 60, 99] {
            snapshot.update(current: fix(northMeters: meters, timestamp: now.addingTimeInterval(1)), policy: policy, now: now.addingTimeInterval(1))
            XCTAssertEqual(snapshot.revision, revision)
            XCTAssertEqual(snapshot.location?.coordinate.latitude, first.coordinate.latitude)
            XCTAssertEqual(snapshot.location?.timestamp, now)
        }
    }

    func testMovementAtLeastHundredMetersReplacesSnapshot() {
        var snapshot = AntennaSightGPSSnapshot()
        snapshot.update(current: fix(timestamp: now), policy: policy, now: now)
        let revision = snapshot.revision
        let next = fix(northMeters: 101, timestamp: now.addingTimeInterval(1))
        snapshot.update(current: next, policy: policy, now: now.addingTimeInterval(1))
        XCTAssertNotEqual(snapshot.revision, revision)
        XCTAssertEqual(snapshot.location, next)
    }

    func testExpirationDoesNotRenewOldFixWithNewTimestamp() {
        var snapshot = AntennaSightGPSSnapshot()
        snapshot.update(current: fix(timestamp: now), policy: policy, now: now)
        let revision = snapshot.revision
        let next = fix(northMeters: 1, timestamp: now.addingTimeInterval(59))
        snapshot.update(current: next, policy: policy, now: now.addingTimeInterval(60))
        XCTAssertNotEqual(snapshot.revision, revision)
        XCTAssertEqual(snapshot.location, next)
        XCTAssertEqual(snapshot.expiresAt(maxAge: 60), next.timestamp.addingTimeInterval(60))
    }

    func testNoFreshFixAtExpirationClearsSnapshot() {
        var snapshot = AntennaSightGPSSnapshot()
        let first = fix(timestamp: now)
        snapshot.update(current: first, policy: policy, now: now)
        snapshot.update(current: first, policy: policy, now: now.addingTimeInterval(60))
        XCTAssertNil(snapshot.location)
    }

    func testExplicitRefreshReplacesSnapshotDespiteSmallMovement() {
        var snapshot = AntennaSightGPSSnapshot()
        snapshot.update(current: fix(timestamp: now), policy: policy, now: now)
        let revision = snapshot.revision
        let next = fix(northMeters: 1, timestamp: now.addingTimeInterval(1))
        snapshot.update(current: next, policy: policy, now: now.addingTimeInterval(1), force: true)
        XCTAssertNotEqual(snapshot.revision, revision)
        XCTAssertEqual(snapshot.location, next)
    }

    func testCurrentGPSCrossingBoundaryExcludesOtherwiseStableProfile() {
        XCTAssertTrue(AntennaSightGPSSnapshot.permitsProfile(snapshotDistance: 29_999, currentDistance: 30_000))
        XCTAssertFalse(AntennaSightGPSSnapshot.permitsProfile(snapshotDistance: 29_999, currentDistance: 30_001))
        XCTAssertFalse(AntennaSightGPSSnapshot.permitsProfile(snapshotDistance: 30_001, currentDistance: 29_999))
        XCTAssertFalse(AntennaSightGPSSnapshot.permitsProfile(snapshotDistance: 1_000, currentDistance: nil))
    }
}

@MainActor
final class AntennaSightViewModelTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)
    private let antenna = CLLocationCoordinate2D(latitude: 48.86, longitude: 2.35)

    func testThirtyKilometreBoundaryBeforeBothServices() async {
        for distance in [29_999.0, 30_000, 30_001, 1_000_000, .infinity, .nan] {
            let terrain = SightTerrainSpy()
            let model = AntennaSightViewModel(terrain: terrain)
            await model.load(user: origin, antenna: antenna, distanceMeters: distance)
            let calls = await terrain.counts()
            let admitted = distance.isFinite && distance <= 30_000
            XCTAssertEqual(calls.0, admitted ? 1 : 0, "terrain, distance \(distance)")
            XCTAssertEqual(calls.1, admitted ? 1 : 0, "clutter, distance \(distance)")
            XCTAssertEqual(model.profile.isEmpty, !admitted)
        }
    }

    func testOutOfRangeClearsCachedProfileBeforeGeometryRebuild() async {
        let terrain = SightTerrainSpy()
        let model = AntennaSightViewModel(terrain: terrain)
        await model.load(user: origin, antenna: antenna, distanceMeters: 29_999)
        XCTAssertFalse(model.profile.isEmpty)
        await model.load(user: origin, antenna: antenna, distanceMeters: 30_001)
        model.setGeometry(antennaHeightMeters: 40, frequencyMhz: 700)
        XCTAssertTrue(model.profile.isEmpty)
        XCTAssertNil(model.verdict)
        let calls = await terrain.counts()
        XCTAssertEqual(calls.0, 1)
        XCTAssertEqual(calls.1, 1)
    }

    func testInvalidCoordinateMakesNoRequests() async {
        let terrain = SightTerrainSpy()
        let model = AntennaSightViewModel(terrain: terrain)
        await model.load(user: CLLocationCoordinate2D(latitude: .nan, longitude: 0), antenna: antenna, distanceMeters: 1_000)
        let calls = await terrain.counts()
        XCTAssertEqual(calls.0, 0)
        XCTAssertEqual(calls.1, 0)
        XCTAssertTrue(model.profile.isEmpty)
    }

    func testLateResponseCannotRestoreInvalidatedOrigin() async {
        let terrain = SightTerrainSpy(suspendsElevation: true)
        let model = AntennaSightViewModel(terrain: terrain)
        let task = Task { await model.load(user: origin, antenna: antenna, distanceMeters: 1_000) }
        await terrain.waitForElevation()
        model.invalidate()
        await terrain.releaseElevation()
        await task.value
        XCTAssertTrue(model.profile.isEmpty)
        XCTAssertNil(model.verdict)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.failed)
    }

    func testLateResponseCannotReplaceNewAntennaProfile() async {
        let terrain = SightTerrainSpy(suspendsElevation: true)
        let model = AntennaSightViewModel(terrain: terrain)
        let old = Task { await model.load(user: origin, antenna: antenna, distanceMeters: 1_000) }
        await terrain.waitForElevation()
        let nextAntenna = CLLocationCoordinate2D(latitude: 48.87, longitude: 2.35)
        await model.load(user: origin, antenna: nextAntenna, distanceMeters: 2_000)
        XCTAssertEqual(model.profile.last?.distanceMeters, 2_000)
        await terrain.releaseElevation()
        await old.value
        XCTAssertEqual(model.profile.last?.distanceMeters, 2_000)
        XCTAssertFalse(model.isLoading)
    }

    func testLateBuildingsCannotEnrichReplacementOrigin() async {
        let terrain = SightTerrainSpy(suspendsBuildings: true)
        let model = AntennaSightViewModel(terrain: terrain)
        let old = Task { await model.load(user: origin, antenna: antenna, distanceMeters: 1_000) }
        await terrain.waitForBuildings()
        let nextOrigin = CLLocationCoordinate2D(latitude: 48.85001, longitude: 2.35)
        await model.load(user: nextOrigin, antenna: antenna, distanceMeters: 999)
        await terrain.releaseBuildings()
        await old.value
        XCTAssertEqual(model.profile.last?.distanceMeters, 999)
        XCTAssertEqual(model.verdict?.includesBuildings, false)
    }

    func testNewContextAtSameCoordinatesReplacesCachedRequest() async {
        let terrain = SightTerrainSpy()
        let model = AntennaSightViewModel(terrain: terrain)
        await model.load(user: origin, antenna: antenna, distanceMeters: 1_000, contextKey: "address-A|site-1")
        await model.load(user: origin, antenna: antenna, distanceMeters: 1_000, contextKey: "address-B|site-2")
        let calls = await terrain.counts()
        XCTAssertEqual(calls.0, 2)
        XCTAssertEqual(calls.1, 2)
    }

    func testChangingHeightRebuildsAdmittedProfileWithoutNewRequests() async {
        let terrain = SightTerrainSpy()
        let model = AntennaSightViewModel(terrain: terrain)
        await model.load(user: origin, antenna: antenna, distanceMeters: 1_000)
        model.setGeometry(antennaHeightMeters: 50, frequencyMhz: 700)
        XCTAssertEqual(model.profile.last?.sightLineMeters, 150)
        let calls = await terrain.counts()
        XCTAssertEqual(calls.0, 1)
        XCTAssertEqual(calls.1, 1)
    }

    func testPresentedSnapshotSurvivesModelInvalidation() async throws {
        let model = AntennaSightViewModel(terrain: SightTerrainSpy())
        await model.load(user: origin, antenna: antenna, distanceMeters: 1_000)
        let presented = try XCTUnwrap(model.snapshot())
        model.invalidate()
        XCTAssertFalse(presented.profile.isEmpty)
        XCTAssertEqual(presented.distanceMeters, 1_000)
        XCTAssertNotNil(presented.verdict)
        XCTAssertNil(model.snapshot())
    }

    func testJitterTriggersOnlyOnePairOfServiceRequests() async {
        let terrain = SightTerrainSpy()
        let model = AntennaSightViewModel(terrain: terrain)
        var snapshot = AntennaSightGPSSnapshot()
        let now = Date()
        let policy = LocationFixPolicy(maxAge: 60, maximumAccuracy: nil)
        for step in 0...30 {
            let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 48.85 + Double(step) * 0.000001, longitude: 2.35),
                                 altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: now)
            snapshot.update(current: fix, policy: policy, now: now)
            guard let selected = snapshot.location else { return XCTFail("Expected usable GPS") }
            await model.load(user: selected.coordinate, antenna: antenna, distanceMeters: 1_000, contextKey: snapshot.revision.uuidString)
        }
        let calls = await terrain.counts()
        XCTAssertEqual(calls.0, 1)
        XCTAssertEqual(calls.1, 1)
    }

    func testCancelledRequestDoesNotPublishFailureOrRelief() async {
        let terrain = SightTerrainSpy(suspendsElevation: true)
        let model = AntennaSightViewModel(terrain: terrain)
        let task = Task { await model.load(user: origin, antenna: antenna, distanceMeters: 1_000) }
        await terrain.waitForElevation()
        task.cancel()
        await terrain.releaseElevation()
        await task.value
        XCTAssertTrue(model.profile.isEmpty)
        XCTAssertFalse(model.failed)
        XCTAssertFalse(model.isLoading)
    }
}

private actor SightTerrainSpy: TerrainServicing {
    private var elevationCalls = 0
    private var buildingCalls = 0
    private let suspendsElevation: Bool
    private let suspendsBuildings: Bool
    private var pendingBuildings: CheckedContinuation<Void, Never>?
    private var waitingForBuildings: CheckedContinuation<Void, Never>?
    private var pendingElevation: CheckedContinuation<Void, Never>?
    private var waitingForElevation: CheckedContinuation<Void, Never>?

    init(suspendsElevation: Bool = false, suspendsBuildings: Bool = false) {
        self.suspendsElevation = suspendsElevation
        self.suspendsBuildings = suspendsBuildings
    }

    func elevations(for points: [CLLocationCoordinate2D]) async throws -> [Double?] {
        elevationCalls += 1
        if suspendsElevation && elevationCalls == 1 {
            await withCheckedContinuation { continuation in
                pendingElevation = continuation
                waitingForElevation?.resume()
                waitingForElevation = nil
            }
        }
        return Array(repeating: 100, count: points.count)
    }

    func buildingHeights(for points: [CLLocationCoordinate2D]) async throws -> [Double?] {
        buildingCalls += 1
        if suspendsBuildings && buildingCalls == 1 {
            await withCheckedContinuation { continuation in
                pendingBuildings = continuation
                waitingForBuildings?.resume()
                waitingForBuildings = nil
            }
            return Array(repeating: 80, count: points.count)
        }
        return Array(repeating: 0, count: points.count)
    }

    func waitForBuildings() async {
        if pendingBuildings != nil { return }
        await withCheckedContinuation { waitingForBuildings = $0 }
    }
    func releaseBuildings() {
        pendingBuildings?.resume()
        pendingBuildings = nil
    }
    func counts() -> (Int, Int) { (elevationCalls, buildingCalls) }
    func waitForElevation() async {
        if pendingElevation != nil { return }
        await withCheckedContinuation { waitingForElevation = $0 }
    }
    func releaseElevation() {
        pendingElevation?.resume()
        pendingElevation = nil
    }
}
