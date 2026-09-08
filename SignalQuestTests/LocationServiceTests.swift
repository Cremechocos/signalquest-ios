import XCTest
import CoreLocation
@testable import SignalQuest

@MainActor
final class LocationServiceTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 2_000_000_000)

    private func fix(age: TimeInterval = 0, accuracy: Double = 12, latitude: Double = 48.85,
                     at now: Date? = nil) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 2.35),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                   timestamp: (now ?? epoch).addingTimeInterval(-age))
    }

    private func makeService(immediateTimeout: Bool = false) -> (LocationService, LocationTestDriver, LocationTestFactory, LocationTestClock) {
        let tracking = LocationTestDriver()
        let single = LocationTestFactory()
        let clock = LocationTestClock(epoch)
        let service = LocationService(manager: tracking, makeOneShotManager: { single.make() },
            now: { clock.value }, sleep: { nanoseconds in
                if !immediateTimeout { try await Task.sleep(nanoseconds: nanoseconds) }
            })
        return (service, tracking, single, clock)
    }

    func testFreshCachedFixIsReusedWithoutAOneShot() async {
        let (service, _, single, _) = makeService()
        let point = fix(age: 20)
        service.receiveLocations([point])
        let result = await service.currentLocation()
        XCTAssertEqual(result?.timestamp, point.timestamp)
        XCTAssertEqual(single.requests, 0)
    }

    func testHourOldFixIsNotReturnedAfterTimeout() async {
        let (service, _, single, _) = makeService(immediateTimeout: true)
        service.receiveLocations([fix(age: 3_600, accuracy: 1_000)])
        let result = await service.currentLocation(timeoutSeconds: 1, maxAge: 60)
        XCTAssertNil(result)
        XCTAssertEqual(single.requests, 1)
    }

    func testTrackingCannotBypassTheAgeLimit() async {
        let (service, tracking, single, clock) = makeService(immediateTimeout: true)
        service.receiveLocations([fix()])
        service.startTracking()
        clock.advance(3_600)
        let result = await service.currentLocation(timeoutSeconds: 1, maxAge: 60)
        XCTAssertNil(result)
        XCTAssertEqual(tracking.starts, 1)
        XCTAssertEqual(tracking.stops, 0)
        XCTAssertEqual(single.requests, 1)
    }

    func testForceFreshCannotUseCacheAtTheSameClockInstant() async {
        let (service, _, single, _) = makeService(immediateTimeout: true)
        service.receiveLocations([fix()])
        service.startTracking()
        let result = await service.currentLocation(timeoutSeconds: 1, maxAge: 0)
        XCTAssertNil(result)
        XCTAssertEqual(single.requests, 1)
    }

    func testPermissionIsRecheckedBeforeCachedReturn() async {
        let (service, tracking, _, _) = makeService()
        service.receiveLocations([fix()])
        service.startTracking()
        tracking.authorizationStatus = .denied
        let result = await service.currentLocation()
        XCTAssertNil(result)
        XCTAssertNil(service.lastLocation)
        XCTAssertEqual(service.authorizationStatus, .denied)
        XCTAssertGreaterThan(tracking.stops, 0)
        XCTAssertFalse(tracking.allowsBackgroundLocationUpdates)
    }

    func testAQueuedLocationAfterRevocationCannotRepopulateCacheOrObservers() {
        let (service, tracking, _, _) = makeService()
        var observed = 0
        let token = service.addLocationObserver { _ in observed += 1 }
        tracking.authorizationStatus = .denied
        service.receiveLocations([fix()])
        XCTAssertNil(service.lastLocation)
        XCTAssertNil(service.cachedLocation())
        XCTAssertEqual(observed, 0)
        service.removeLocationObserver(token)
    }

    func testInvalidNewestFixDoesNotHideAValidEarlierFixInTheBatch() {
        let (service, _, _, _) = makeService()
        service.receiveLocations([fix(age: 2), fix(accuracy: -1)])
        XCTAssertEqual(service.lastLocation?.timestamp, epoch.addingTimeInterval(-2))
        XCTAssertEqual(service.lastLocation?.horizontalAccuracy, 12)
    }

    func testApproximateFixKeepsItsRealAccuracyAndCanBeExplicitlyRejected() {
        let (service, _, _, _) = makeService()
        service.receiveLocations([fix(accuracy: 1_000)])
        XCTAssertEqual(service.cachedLocation()?.horizontalAccuracy, 1_000)
        XCTAssertNil(service.cachedLocation(maximumAccuracy: 100))
    }

    func testInvalidCoordinatesAndFutureTimestampAreRejected() {
        let policy = LocationFixPolicy(maxAge: 60, maximumAccuracy: nil)
        XCTAssertFalse(policy.accepts(fix(latitude: 91), now: epoch))
        XCTAssertFalse(policy.accepts(fix(age: -3_600), now: epoch))
        XCTAssertFalse(policy.accepts(fix(accuracy: -1), now: epoch))
        XCTAssertFalse(LocationFixPolicy(maxAge: .nan, maximumAccuracy: nil).isValid)
        XCTAssertFalse(LocationFixPolicy(maxAge: 60, maximumAccuracy: .infinity).isValid)
    }

    func testOutOfOrderFixDoesNotMoveTheTrackingObserverBackwards() {
        let (service, _, _, _) = makeService()
        var dates: [Date] = []
        let token = service.addLocationObserver { dates.append($0.timestamp) }
        service.receiveLocations([fix(age: 2)])
        service.receiveLocations([fix(age: 5)])
        XCTAssertEqual(dates, [epoch.addingTimeInterval(-2)])
        XCTAssertEqual(service.lastLocation?.timestamp, epoch.addingTimeInterval(-2))
        service.removeLocationObserver(token)
    }

    func testNewFixSatisfiesForceFreshWithoutStoppingTracking() async {
        let (service, tracking, single, clock) = makeService()
        service.startTracking()
        service.receiveLocations([fix()])
        let requested = expectation(description: "single request")
        single.onRequest = { requested.fulfill() }
        let waiting = Task { await service.currentLocation(maxAge: 0) }
        await fulfillment(of: [requested], timeout: 2)
        clock.advance(1)
        service.receiveLocations([fix(at: clock.value)], fromOneShot: true)
        let result = await waiting.value
        XCTAssertEqual(result?.timestamp, clock.value)
        XCTAssertEqual(tracking.starts, 1)
        XCTAssertEqual(tracking.stops, 0)
        XCTAssertTrue(tracking.allowsBackgroundLocationUpdates)
    }

    func testCancellationFinishesOnlyItsOwnRequest() async {
        let (service, _, single, clock) = makeService()
        let requested = expectation(description: "request starts")
        single.onRequest = { requested.fulfill() }
        let first = Task { await service.currentLocation() }
        await fulfillment(of: [requested], timeout: 2)
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(single.stops, 1)
        single.onRequest = nil
        let secondStarted = expectation(description: "second request")
        single.onRequest = { secondStarted.fulfill() }
        let second = Task { await service.currentLocation() }
        await fulfillment(of: [secondStarted], timeout: 2)
        clock.advance(1)
        service.receiveLocations([fix(at: clock.value)], fromOneShot: true)
        let received = await second.value
        XCTAssertNotNil(received)
    }

    func testOldAcquisitionErrorAndFixCannotFinishOrRewriteNewRequest() async {
        let (service, _, factory, clock) = makeService()
        let startedA = expectation(description: "A started")
        factory.onRequest = { startedA.fulfill() }
        let first = Task { await service.currentLocation() }
        await fulfillment(of: [startedA], timeout: 2)
        let oldDelegate = factory.drivers.last!.delegate as! LocationOneShotDelegate
        first.cancel()
        let firstResult = await first.value
        XCTAssertNil(firstResult)
        let startedB = expectation(description: "B started")
        factory.onRequest = { startedB.fulfill() }
        let second = Task { await service.currentLocation() }
        await fulfillment(of: [startedB], timeout: 2)
        let newDelegate = factory.drivers.last!.delegate as! LocationOneShotDelegate
        XCTAssertNotEqual(oldDelegate.generation, newDelegate.generation)
        service.receiveLocationFailure(CLError(.locationUnknown), generation: oldDelegate.generation)
        service.receiveLocations([fix(latitude: 44)], generation: oldDelegate.generation)
        XCTAssertNil(service.errorMessage)
        XCTAssertNil(service.cachedLocation())
        clock.advance(1)
        service.receiveLocations([fix(at: clock.value)], generation: newDelegate.generation)
        let result = await second.value
        XCTAssertEqual(result?.coordinate.latitude, 48.85)
        XCTAssertEqual(factory.requests, 2)
    }

    func testCancellingOneJoinedCallerKeepsAcquisitionForTheOther() async {
        let (service, _, factory, _) = makeService()
        let started = expectation(description: "acquisition started")
        factory.onRequest = { started.fulfill() }
        let first = Task { await service.currentLocation() }
        await fulfillment(of: [started], timeout: 2)
        let joined = expectation(description: "second joins")
        let second = Task { joined.fulfill(); return await service.currentLocation() }
        await fulfillment(of: [joined], timeout: 2)
        first.cancel()
        let firstResult = await first.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(factory.requests, 1)
        XCTAssertEqual(factory.stops, 0)
        let delegate = factory.drivers.last!.delegate as! LocationOneShotDelegate
        service.receiveLocations([fix()], generation: delegate.generation)
        let result = await second.value
        XCTAssertNotNil(result)
    }

    func testIndependentAccuracyPoliciesDoNotReceiveAnInadmissibleFix() async {
        let (service, _, single, _) = makeService()
        let requested = expectation(description: "request starts")
        single.onRequest = { requested.fulfill() }
        let precise = Task { await service.currentLocation(timeoutSeconds: 1, maximumAccuracy: 10) }
        await fulfillment(of: [requested], timeout: 2)
        single.onRequest = nil
        service.receiveLocations([fix(accuracy: 50)], fromOneShot: true)
        let coarse = await service.currentLocation(timeoutSeconds: 0, maximumAccuracy: 100)
        XCTAssertEqual(coarse?.horizontalAccuracy, 50)
        let preciseResult = await precise.value
        XCTAssertNil(preciseResult)
    }

    func testStricterJoinedRequestGetsABoundedSecondAcquisition() async {
        let (service, _, factory, _) = makeService()
        let started = expectation(description: "coarse acquisition")
        factory.onRequest = { started.fulfill() }
        let coarse = Task { await service.currentLocation(maximumAccuracy: 100) }
        await fulfillment(of: [started], timeout: 2)
        let joined = expectation(description: "precise caller joined")
        let precise = Task { joined.fulfill(); return await service.currentLocation(maximumAccuracy: 10) }
        await fulfillment(of: [joined], timeout: 2)
        factory.onRequest = nil
        let firstDelegate = factory.drivers.last!.delegate as! LocationOneShotDelegate
        service.receiveLocations([fix(accuracy: 50)], generation: firstDelegate.generation)
        let coarseResult = await coarse.value
        XCTAssertEqual(coarseResult?.horizontalAccuracy, 50)
        XCTAssertEqual(factory.requests, 2)
        XCTAssertEqual(factory.drivers.last?.desiredAccuracy, 10)
        let secondDelegate = factory.drivers.last!.delegate as! LocationOneShotDelegate
        service.receiveLocations([fix(accuracy: 5)], generation: secondDelegate.generation)
        let preciseResult = await precise.value
        XCTAssertEqual(preciseResult?.horizontalAccuracy, 5)
    }

    func testTrackingErrorDoesNotCancelTheIndependentOneShot() async {
        let (service, _, single, _) = makeService()
        service.startTracking()
        let requested = expectation(description: "request starts")
        single.onRequest = { requested.fulfill() }
        let waiting = Task { await service.currentLocation() }
        await fulfillment(of: [requested], timeout: 2)
        service.receiveLocationFailure(NSError(domain: kCLErrorDomain, code: CLError.Code.locationUnknown.rawValue), fromOneShot: false)
        service.receiveLocations([fix()], fromOneShot: true)
        let result = await waiting.value
        XCTAssertNotNil(result)
    }

    func testRevocationResolvesPendingRequestsWithoutAStaleFallback() async {
        let (service, tracking, single, _) = makeService()
        let requested = expectation(description: "request starts")
        single.onRequest = { requested.fulfill() }
        let waiting = Task { await service.currentLocation() }
        await fulfillment(of: [requested], timeout: 2)
        tracking.authorizationStatus = .denied
        service.refreshAuthorization()
        let result = await waiting.value
        XCTAssertNil(result)
        XCTAssertEqual(single.stops, 1)
    }

    func testAnExpiredAuthorizationRequestDoesNotStartGPSAfterLateGrant() async {
        let (service, tracking, single, _) = makeService(immediateTimeout: true)
        tracking.authorizationStatus = .notDetermined
        let result = await service.currentLocation(timeoutSeconds: 1)
        XCTAssertNil(result)
        XCTAssertEqual(tracking.authorizationRequests, 1)
        tracking.authorizationStatus = .authorizedWhenInUse
        service.refreshAuthorization()
        XCTAssertEqual(single.requests, 0)
    }
}

@MainActor
final class LocationTestDriver: LocationManagerDriving {
    weak var delegate: (any CLLocationManagerDelegate)?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var desiredAccuracy: CLLocationAccuracy = 100
    var distanceFilter: CLLocationDistance = 0
    var allowsBackgroundLocationUpdates = false
    var pausesLocationUpdatesAutomatically = true
    var headingFilter: CLLocationDegrees = 0
    var requests = 0
    var starts = 0
    var stops = 0
    var authorizationRequests = 0
    var onRequest: (() -> Void)?
    func requestWhenInUseAuthorization() { authorizationRequests += 1 }
    func requestLocation() { requests += 1; onRequest?() }
    func startUpdatingLocation() { starts += 1 }
    func stopUpdatingLocation() { stops += 1 }
    func startUpdatingHeading() {}
    func stopUpdatingHeading() {}
}

private final class LocationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

@MainActor
private final class LocationTestFactory {
    var drivers: [LocationTestDriver] = []
    var onRequest: (() -> Void)?
    var requests: Int { drivers.reduce(0) { $0 + $1.requests } }
    var stops: Int { drivers.reduce(0) { $0 + $1.stops } }
    func make() -> LocationTestDriver {
        let driver = LocationTestDriver()
        driver.onRequest = { [weak self] in self?.onRequest?() }
        drivers.append(driver)
        return driver
    }
}
