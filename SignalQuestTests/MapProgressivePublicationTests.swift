import Combine
import XCTest
@testable import SignalQuest

/// Exercises the real ViewModel with independently suspended service responses.
/// A publication expectation observes the render invalidation, not a timed delay.
@MainActor
final class MapProgressivePublicationTests: XCTestCase {
    private let bounds = MapBounds(north: 48.86, south: 48.85, east: 2.36, west: 2.35)

    func testFriendRemovedBySSECannotReappearAfterCoverageOnlyAndFailedFriendReload() async throws {
        let (model, service) = makeModel()
        let now = Date()
        let friend = SocialFriendLive(id: "synthetic-removed-friend", name: "Synthetic friend",
            avatarUrl: nil, presence: nil,
            location: SocialLiveLocation(lat: 48.855, lng: 2.355, accuracy: 10,
                                         heading: nil, speed: nil, updatedAt: now),
            radio: nil, privacy: nil)
        let snapshot = SocialMapSnapshot(timestamp: now, friends: [friend], photos: [],
            validations: [], sessions: [], coveragePoints: [], speedtests: [],
            photosCount: 0, validationsCount: 0, sessionsCount: 0,
            coveragePointsCount: 0, speedtestsCount: 0,
            rawCoveragePointsCount: nil, logicalCoveragePointsCount: nil)
        await service.snapshots.release("snapshot", result: .success(snapshot))
        await model.load(bounds: bounds, zoom: 14, filters: [.friend])
        XCTAssertEqual(model.liveFriends.map(\.id), [friend.id])
        XCTAssertFalse(friend.hasStaleLocation(now: now))

        // The authoritative live feed removes F, then the user disables Friends.
        model.applyLiveFriends([])
        XCTAssertTrue(model.liveFriends.isEmpty)
        model.deactivateFriendsStream()
        let snapshotRequests = await service.snapshots.requestCount
        await model.load(bounds: bounds, zoom: 14, filters: [.coverage])
        let requestsAfterCoverage = await service.snapshots.requestCount
        XCTAssertEqual(requestsAfterCoverage, snapshotRequests,
                       "Coverage-only browsing must not request the private snapshot")
        XCTAssertTrue(model.snapshot.friends.isEmpty,
                      "A disabled social layer must discard its obsolete snapshot seed")

        // Neither the bounded reload nor the REST fallback can supply a fresh F.
        await service.snapshots.release("snapshot", result: .failure(APIError.transport("synthetic snapshot unavailable")))
        model.beginFriendsStream()
        await model.load(bounds: bounds, zoom: 14, filters: [.friend])
        model.friendsFallbackDidFail(APIError.transport("synthetic fallback unavailable"))
        XCTAssertTrue(model.liveFriends.isEmpty,
                      "Re-enabling Friends must not resurrect a location removed by SSE")
        XCTAssertTrue(model.snapshot.friends.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testAntennasPublishBeforeOperatorAndCommunityOutagesFinish() async throws {
        let (model, service) = makeModel()
        let tile = try antennaTile("first-antenna")
        let started = await holdLayers(service, operatorName: "SFR")
        let published = expectation(description: "Antenna render invalidated while outage feeds are pending")
        let observation = observePublication(model, antennaID: "first-antenna", expectation: published)
        defer { observation.cancel() }
        let initialVersion = model.dataVersion
        let loading = Task { await model.load(bounds: bounds, zoom: 14, filters: [.antenna]) }
        await fulfillment(of: started, timeout: 2)

        await service.antennas.release("SFR", result: .success([tile]))
        await fulfillment(of: [published], timeout: 2)

        XCTAssertEqual(model.antennas.map(\.id), ["first-antenna"])
        XCTAssertGreaterThan(model.dataVersion, initialVersion)
        XCTAssertTrue(model.isLoading, "Secondary feeds still belong to the active load")
        XCTAssertFalse(model.hasCurrentResponse, "A first layer is not a complete map response")
        XCTAssertNil(model.errorMessage)

        // Always drain both continuations, including when the RED expectation times out.
        await service.operatorOutages.release("SFR", result: .success([]))
        await service.communityOutages.release("SFR", result: .success([]))
        await loading.value
        XCTAssertEqual(model.antennas.map(\.id), ["first-antenna"])
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.hasCurrentResponse)
    }

    func testReservationAfterFirstPublicationRejectsOldSecondaryResponses() async throws {
        try await assertReservationRejectsOldResponses(replaceAccount: false)
    }

    func testAccountReservationAfterFirstPublicationRejectsOldSecondaryResponses() async throws {
        try await assertReservationRejectsOldResponses(replaceAccount: true)
    }

    func testOldSecondaryResponsesCannotMutateNewPartiallyPublishedLoad() async throws {
        let (model, service) = makeModel()
        let aTile = try antennaTile("A")
        let bTile = try antennaTile("B")
        let lateOutage = try communityOutage("late-A")
        let aStarted = await holdLayers(service, operatorName: "SFR")
        let aPublished = expectation(description: "A first publication")
        let aObservation = observePublication(model, antennaID: "A", expectation: aPublished)
        defer { aObservation.cancel() }
        let a = Task { await model.load(bounds: bounds, zoom: 14, filters: [.antenna]) }
        await fulfillment(of: aStarted, timeout: 2)
        await service.antennas.release("SFR", result: .success([aTile]))
        await fulfillment(of: [aPublished], timeout: 2)
        aObservation.cancel()

        model.operatorFilter = "ORANGE"
        let reserved = model.prepareLoad(filters: [.antenna])
        let bStarted = await holdLayers(service, operatorName: "ORANGE")
        let bPublished = expectation(description: "B first publication")
        let bObservation = observePublication(model, antennaID: "B", expectation: bPublished)
        defer { bObservation.cancel() }
        let b = Task { await model.load(bounds: bounds, zoom: 14, filters: [.antenna], requestID: reserved) }
        await fulfillment(of: bStarted, timeout: 2)
        await service.antennas.release("ORANGE", result: .success([bTile]))
        await fulfillment(of: [bPublished], timeout: 2)
        bObservation.cancel()
        let version = model.dataVersion
        let error = model.errorMessage
        let limits = model.displayLimitMessages

        await service.operatorOutages.release("SFR", result: .failure(APIError.transport("obsolete outage failure")))
        await service.communityOutages.release("SFR", result: .success([lateOutage]))
        await a.value

        XCTAssertEqual(model.antennas.map(\.id), ["B"])
        XCTAssertEqual(model.dataVersion, version)
        XCTAssertEqual(model.errorMessage, error)
        XCTAssertEqual(model.displayLimitMessages, limits)
        XCTAssertTrue(model.communityOutages.isEmpty)
        XCTAssertTrue(model.isLoading, "A must not stop B's spinner")
        XCTAssertFalse(model.hasCurrentResponse)

        await service.operatorOutages.release("ORANGE", result: .success([]))
        await service.communityOutages.release("ORANGE", result: .success([]))
        await b.value
        XCTAssertEqual(model.antennas.map(\.id), ["B"])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.hasCurrentResponse)
    }

    private func assertReservationRejectsOldResponses(replaceAccount: Bool) async throws {
        let (model, service) = makeModel()
        let aTile = try antennaTile("A")
        let bTile = try antennaTile("B")
        let lateOutage = try communityOutage("late-A")
        let started = await holdLayers(service, operatorName: "SFR")
        let published = expectation(description: "A publishes before the new context is reserved")
        let observation = observePublication(model, antennaID: "A", expectation: published)
        defer { observation.cancel() }
        let a = Task { await model.load(bounds: bounds, zoom: 14, filters: [.antenna]) }
        await fulfillment(of: started, timeout: 2)
        await service.antennas.release("SFR", result: .success([aTile]))
        await fulfillment(of: [published], timeout: 2)
        observation.cancel()

        let oldSession = service.sessionIdentifier
        if replaceAccount {
            try service.credentials.setAccessToken("synthetic-progressive-B")
            XCTAssertNotEqual(service.sessionIdentifier, oldSession)
        } else {
            model.operatorFilter = "ORANGE"
        }
        let reserved = model.prepareLoad(filters: [.antenna])
        let version = model.dataVersion
        let error = model.errorMessage
        let limits = model.displayLimitMessages
        XCTAssertTrue(model.antennas.isEmpty, "The new context must clear incompatible A data immediately")

        // B is reserved but has not started its debounced request yet.
        await service.operatorOutages.release("SFR", result: .failure(APIError.transport("obsolete outage failure")))
        await service.communityOutages.release("SFR", result: .success([lateOutage]))
        await a.value

        XCTAssertTrue(model.antennas.isEmpty)
        XCTAssertTrue(model.communityOutages.isEmpty)
        XCTAssertTrue(model.snapshot.friends.isEmpty)
        XCTAssertTrue(model.liveFriends.isEmpty)
        XCTAssertEqual(model.dataVersion, version)
        XCTAssertEqual(model.errorMessage, error)
        XCTAssertEqual(model.displayLimitMessages, limits)
        XCTAssertTrue(model.tileLoadIssues.isEmpty)
        XCTAssertTrue(model.isLoading, "A must not finish the reserved B load")
        XCTAssertFalse(model.hasCurrentResponse)

        let nextOperator = model.operatorFilter
        await service.antennas.release(nextOperator, result: .success([bTile]))
        await service.operatorOutages.release(nextOperator, result: .success([]))
        await service.communityOutages.release(nextOperator, result: .success([]))
        await model.load(bounds: bounds, zoom: 14, filters: [.antenna], requestID: reserved)
        XCTAssertEqual(model.antennas.map(\.id), ["B"])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    private func observePublication(_ model: MapExplorerViewModel, antennaID: String,
                                    expectation: XCTestExpectation) -> AnyCancellable {
        model.$dataVersion.dropFirst().filter { _ in
            model.antennas.map(\.id) == [antennaID]
        }.prefix(1).sink { _ in expectation.fulfill() }
    }

    private func holdLayers(_ service: ProgressiveMapService, operatorName: String) async -> [XCTestExpectation] {
        let antenna = expectation(description: "\(operatorName) antenna request suspended")
        let outage = expectation(description: "\(operatorName) operator outage request suspended")
        let community = expectation(description: "\(operatorName) community outage request suspended")
        await service.antennas.hold(operatorName, started: antenna)
        await service.operatorOutages.hold(operatorName, started: outage)
        await service.communityOutages.hold(operatorName, started: community)
        return [antenna, outage, community]
    }

    private func makeModel() -> (MapExplorerViewModel, ProgressiveMapService) {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let api = APIClient(config: .test, credentials: credentials)
        let service = ProgressiveMapService(credentials: credentials)
        let model = MapExplorerViewModel(map: service, antennas: AntennasService(api: api),
                                        markets: MarketRegistryService(api: api), communityOutages: service)
        model.marketFilter = "FR"
        model.operatorFilter = "SFR"
        return (model, service)
    }

    private func antennaTile(_ id: String) throws -> AndroidAntennaTileResponse {
        try JSONDecoder.signalQuest.decode(AndroidAntennaTileResponse.self, from: Data("""
        {"tile":{"z":14,"x":1,"y":1},"clusters":[],"markers":[{"id":"\(id)","lat":48.855,"lng":2.355,"operators":["SFR"],"technologies":["4G"]}]}
        """.utf8))
    }

    private func communityOutage(_ id: String) throws -> CommunityOutage {
        try JSONDecoder.signalQuest.decode(CommunityOutage.self, from: Data("""
        {"id":"\(id)","targetId":"A","marketCode":"FR","operatorKey":"SFR","latitude":48.855,"longitude":2.355}
        """.utf8))
    }
}

/// Results can be released before entry too, so a failed start expectation never
/// leaves a late-arriving request suspended during test cleanup.
private actor ProgressiveResponseGate<Value: Sendable> {
    private(set) var requestCount = 0
    private var starts: [String: XCTestExpectation] = [:]
    private var continuations: [String: CheckedContinuation<Value, Error>] = [:]
    private var results: [String: Result<Value, Error>] = [:]

    func hold(_ key: String, started: XCTestExpectation) {
        starts[key] = started
        results.removeValue(forKey: key)
    }

    func response(_ key: String, default value: Value) async throws -> Value {
        requestCount += 1
        let started = starts.removeValue(forKey: key)
        if let result = results[key] {
            started?.fulfill()
            return try result.get()
        }
        guard let started else { return value }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[key] = continuation
            started.fulfill()
        }
    }

    func release(_ key: String, result: Result<Value, Error>) {
        results[key] = result
        continuations.removeValue(forKey: key)?.resume(with: result)
    }
}

private final class ProgressiveMapService: MapSnapshotServicing, CommunityOutageServicing, Sendable {
    let credentials: CredentialStore
    var sessionIdentifier: UUID { credentials.snapshot().sessionID }
    let antennas = ProgressiveResponseGate<[AndroidAntennaTileResponse]>()
    let operatorOutages = ProgressiveResponseGate<[OutageSiteLive]>()
    let communityOutages = ProgressiveResponseGate<[CommunityOutage]>()
    let snapshots = ProgressiveResponseGate<SocialMapSnapshot>()

    init(credentials: CredentialStore) { self.credentials = credentials }
    func invalidateTiles() async {}
    func snapshot(bounds: MapBounds, zoom: Double, lightweight: Bool) async throws -> SocialMapSnapshot {
        try await snapshots.response("snapshot", default: .empty)
    }
    func friendsStream(sse: SSEClient) -> AsyncStream<[SocialFriendLive]> { AsyncStream { $0.finish() } }
    func friendsSnapshot() async throws -> [SocialFriendLive] { [] }
    func plannedSites(market: String, operatorName: String, territory: String?, bands: Set<Int>) async throws -> [PlannedSiteLive] { [] }
    func outageSites(market: String, operatorName: String, territory: String?, bands: Set<Int>) async throws -> [OutageSiteLive] {
        try await operatorOutages.response(operatorName, default: [])
    }
    func operatorIncidents(forSiteId siteId: String?, market: String, operatorName: String?, latitude: Double, longitude: Double, territory: String?) async throws -> SiteOperatorIncidentsResponse { throw APIError.cancelled }
    func coveragePoints(bounds: MapBounds, market: String, operatorName: String, technology: String?, bands: Set<Int>) async throws -> [CoverageHeatPoint] { [] }
    func publicPhotos(bounds: MapBounds, zoom: Double, market: String, operatorName: String, friendsOnly: Bool) async throws -> [MapPublicPhoto] { [] }
    func antennaTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, withAzimuth: Bool, bands: Set<Int>) async throws -> [AndroidAntennaTileResponse] {
        try await antennas.response(operatorName, default: [])
    }
    func speedtestTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int, bands: Set<Int>, maxAge: TimeInterval?) async throws -> [AndroidSpeedtestTileResponse] { [] }
    func coverageTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int, bands: Set<Int>, maxAge: TimeInterval?) async throws -> [AndroidCoverageTileResponse] { [] }
    func coverageTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, days: Int, bands: Set<Int>, maxAge: TimeInterval?, focus: AntennaCoverageFocus?) async throws -> [AndroidCoverageTileResponse] { [] }
    func communitySiteTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String, includeObserved: Bool, bands: Set<Int>) async throws -> [AndroidCommunitySiteTileResponse] { [] }
    func customSiteTiles(bounds: MapBounds, zoom: Double, market: String, operatorName: String) async throws -> [AndroidCustomSiteTileResponse] { [] }
    func outages(in bounds: MapBounds, marketCode: String, operatorKey: String?) async throws -> [CommunityOutage] {
        try await communityOutages.response(operatorKey ?? "ALL", default: [])
    }
    func outages(forSiteId siteId: String, targetKind: String, marketCode: String, operatorKey: String?) async throws -> [CommunityOutage] { [] }
    func feed(scope: OutageFeedScope, offset: Int, limit: Int) async throws -> (outages: [CommunityOutage], hasMore: Bool) { ([], false) }
    func detail(outageId: String) async throws -> CommunityOutage { throw APIError.cancelled }
    func report(_ request: OutageReportRequest) async throws -> OutageWriteResponse { throw APIError.cancelled }
    func vote(outageId: String, kind: String, latitude: Double?, longitude: Double?, accuracyMeters: Double?) async throws -> OutageWriteResponse { throw APIError.cancelled }
    func close(outageId: String) async throws -> OutageWriteResponse { throw APIError.cancelled }
}
