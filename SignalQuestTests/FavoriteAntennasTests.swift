import XCTest
import Combine
@testable import SignalQuest

/// Les antennes suivies reposent sur `/api/me/follows` (FAV-1) : un suivi par site ET par
/// opérateur. Les intentions de l'ancienne passerelle déjà en file se vident encore par
/// `/api/android/favorite-antennas`, sans qu'aucun geste n'écrive dans les deux modèles.
@MainActor
final class FavoriteAntennasTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    // MARK: Lecture

    func testListIsReadFromSiteFollowsAndNeverFromTheLegacyGateway() async throws {
        let fixture = try Fixture(initial: [Self.a, Self.b])
        await fixture.service.load()
        XCTAssertTrue(fixture.service.hasLoaded)
        XCTAssertEqual(Set(fixture.service.favorites.map(\.followKey)), Set([Self.a.followKey, Self.b.followKey]))
        XCTAssertEqual(fixture.service.favorites.first { $0.siteId == "a" }?.name, "Site A")
        XCTAssertEqual(fixture.server.requests, ["GET /api/me/follows"])
    }

    func testFailedInitialReadCannotWriteAFollow() async throws {
        let fixture = try Fixture(initial: [Self.a])
        fixture.server.setReadFailure(true)
        _ = await fixture.service.toggle(Self.b)
        XCTAssertEqual(fixture.server.followKeys(for: "a"), [Self.a.followKey])
        XCTAssertTrue(fixture.server.writes.isEmpty)
        XCTAssertFalse(fixture.service.hasLoaded)
        XCTAssertNotNil(fixture.service.errorMessage)
    }

    func testFailedRefreshKeepsLastConfirmedList() async throws {
        let fixture = try Fixture(initial: [Self.a])
        await fixture.service.load()
        fixture.server.setReadFailure(true)
        await fixture.service.load()
        XCTAssertEqual(fixture.service.favorites.map(\.followKey), [Self.a.followKey])
        XCTAssertTrue(fixture.service.hasLoaded)
        XCTAssertNotNil(fixture.service.errorMessage)
    }

    // MARK: Suivre et ne plus suivre

    func testFollowSendsTheDisplayedOperatorOnly() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        let following = await fixture.service.toggle(Self.a)
        XCTAssertTrue(following)
        XCTAssertEqual(fixture.server.writes, ["POST FR|ORANGE|a"])
        XCTAssertEqual(fixture.server.followKeys(for: "a"), [Self.a.followKey])
        XCTAssertTrue(fixture.service.isFavorite(siteId: "a", market: "FR", operator: "ORANGE"))
        XCTAssertFalse(fixture.service.isFavorite(siteId: "a", market: "FR", operator: "SFR"),
                       "Un autre opérateur du même pylône se suit depuis sa propre fiche")
        XCTAssertTrue(fixture.service.isFavorite(siteId: "a", market: "FR"))
        XCTAssertEqual(fixture.service.pendingCount, 0)
        XCTAssertTrue(fixture.server.gatewayMutations.isEmpty, "Aucune écriture double vers l'ancienne passerelle")
    }

    func testUnfollowDeletesTheIdReadByStatusForTheDisplayedOperatorOnly() async throws {
        let fixture = try Fixture(initial: [Self.a, Self.aSFR, Self.b])
        await fixture.service.load()
        await fixture.service.remove(Self.a)
        XCTAssertEqual(fixture.server.writes, ["DELETE FR|ORANGE|a"])
        XCTAssertEqual(fixture.server.followKeys(for: "a"), [Self.aSFR.followKey, Self.b.followKey])
        XCTAssertEqual(Set(fixture.service.favorites.map(\.followKey)), [Self.aSFR.followKey, Self.b.followKey])
        XCTAssertTrue(fixture.server.requests.contains("GET /api/me/follows/status"))
    }

    func testStarOffOnAFollowedSiteDeletesItsFollow() async throws {
        let fixture = try Fixture(initial: [Self.a, Self.b])
        await fixture.service.load()
        let following = await fixture.service.toggle(Self.a)
        XCTAssertFalse(following)
        XCTAssertEqual(fixture.server.writes, ["DELETE FR|ORANGE|a"])
        XCTAssertEqual(fixture.service.favorites.map(\.followKey), [Self.b.followKey])
    }

    func testNoStarWithoutAKnownOperator() async throws {
        XCTAssertFalse(FavoriteAntenna.isFollowableOperator(nil))
        XCTAssertFalse(FavoriteAntenna.isFollowableOperator(" "))
        XCTAssertFalse(FavoriteAntenna.isFollowableOperator("ALL"))
        XCTAssertFalse(FavoriteAntenna.isFollowableOperator(" all "))
        XCTAssertTrue(FavoriteAntenna.isFollowableOperator("Bouygues Telecom"))
        let fixture = try Fixture()
        await fixture.service.load()
        let all = await fixture.service.toggle(FavoriteAntenna(siteId: "c", market: "FR", operator: "ALL"))
        let none = await fixture.service.toggle(FavoriteAntenna(siteId: "c", market: "FR", operator: nil))
        XCTAssertFalse(all || none)
        XCTAssertTrue(fixture.server.writes.isEmpty)
        XCTAssertNotNil(fixture.service.errorMessage)
    }

    func testTwoFollowsRemainVisibleWhileFirstRequestIsInFlightAndAreSentSerially() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        let started = expectation(description: "Premier POST en vol")
        let release = DispatchSemaphore(value: 0)
        fixture.server.holdNextWrite(started: started, release: release)
        let first = Task { await fixture.service.toggle(Self.a) }
        await fulfillment(of: [started], timeout: 1)
        let second = Task { await fixture.service.toggle(Self.b) }
        await waitUntil { fixture.service.favorites.count == 2 }
        XCTAssertEqual(fixture.server.writes.count, 1, "Une seule écriture réseau à la fois")
        release.signal()
        _ = await (first.value, second.value)
        XCTAssertEqual(Set(fixture.service.favorites.map(\.followKey)), Set([Self.a.followKey, Self.b.followKey]))
        XCTAssertEqual(fixture.server.followKeys(for: "a"), Set([Self.a.followKey, Self.b.followKey]))
        XCTAssertEqual(fixture.service.pendingCount, 0)
    }

    func testLaterUnfollowOfSameSiteSurvivesOlderFollowResponse() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        let started = expectation(description: "Suivi A en vol")
        let release = DispatchSemaphore(value: 0)
        fixture.server.holdNextWrite(started: started, release: release)
        let add = Task { await fixture.service.toggle(Self.a) }
        await fulfillment(of: [started], timeout: 1)
        let remove = Task { await fixture.service.remove(Self.a) }
        await waitUntil { fixture.service.favorites.isEmpty }
        release.signal()
        _ = await (add.value, remove.value)
        XCTAssertTrue(fixture.service.favorites.isEmpty)
        XCTAssertTrue(fixture.server.followKeys(for: "a").isEmpty)
        XCTAssertEqual(fixture.server.writes, ["POST FR|ORANGE|a", "DELETE FR|ORANGE|a"])
    }

    func testOtherDeviceFollowIsNotLostDuringLocalFollow() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.setFollows([Self.b], for: "a")
        _ = await fixture.service.toggle(Self.a)
        XCTAssertEqual(Set(fixture.service.favorites.map(\.followKey)), Set([Self.a.followKey, Self.b.followKey]))
        XCTAssertEqual(fixture.server.writes, ["POST FR|ORANGE|a"])
    }

    func testExplicitRemovalNeverReaddsAFollowAlreadyRemovedByAnotherDevice() async throws {
        let fixture = try Fixture(initial: [Self.a])
        await fixture.service.load()
        fixture.server.setFollows([], for: "a")
        await fixture.service.remove(Self.a)
        XCTAssertTrue(fixture.service.favorites.isEmpty)
        XCTAssertTrue(fixture.server.writes.isEmpty, "Le statut dit que le suivi n'existe plus : rien à supprimer, rien à recréer")
    }

    // MARK: Hors ligne et erreurs

    func testOfflineFollowPersistsAndIsSentAgainAfterReopening() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.setWriteFailure(true)
        _ = await fixture.service.toggle(Self.a)
        XCTAssertEqual(fixture.service.favorites.map(\.followKey), [Self.a.followKey])
        XCTAssertEqual(fixture.service.pendingCount, 1)
        XCTAssertNotNil(fixture.service.errorMessage)
        let durable = await fixture.store.state(for: "user:a")
        XCTAssertEqual(durable?.pending.map(\.operation), [.follow])
        fixture.server.setWriteFailure(false)
        let reopened = fixture.makeService()
        await reopened.load()
        XCTAssertEqual(reopened.favorites.map(\.followKey), [Self.a.followKey])
        XCTAssertEqual(reopened.pendingCount, 0)
        XCTAssertEqual(fixture.server.followKeys(for: "a"), [Self.a.followKey])
    }

    func testLostResponseOnFollowIsReplayedWithoutDuplicate() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.dropNextCommittedResponse()
        _ = await fixture.service.toggle(Self.a)
        XCTAssertEqual(fixture.service.pendingCount, 1)
        let reopened = fixture.makeService()
        await reopened.load()
        XCTAssertEqual(reopened.pendingCount, 0)
        XCTAssertEqual(reopened.favorites.map(\.followKey), [Self.a.followKey])
        XCTAssertEqual(fixture.server.followKeys(for: "a"), [Self.a.followKey])
        XCTAssertEqual(fixture.server.writes, ["POST FR|ORANGE|a", "POST FR|ORANGE|a"])
    }

    func testInverseIntentWaitsForEarlierAmbiguousFollow() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.setWriteFailure(true)
        _ = await fixture.service.toggle(Self.a)
        fixture.server.setWriteFailure(false)
        await fixture.service.remove(Self.a)
        XCTAssertEqual(fixture.server.writes, ["POST FR|ORANGE|a", "POST FR|ORANGE|a", "DELETE FR|ORANGE|a"],
                       "Le suivi incertain est rejoué avant le retrait")
        XCTAssertTrue(fixture.server.followKeys(for: "a").isEmpty)
        XCTAssertEqual(fixture.service.pendingCount, 0)
    }

    func testRejectedFollowIsDroppedAndNotRetried() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.failNextWrite(status: 404, code: "SITE_NOT_FOUND", message: "Site introuvable pour cet opérateur")
        _ = await fixture.service.toggle(Self.a)
        XCTAssertEqual(fixture.service.pendingCount, 0)
        XCTAssertFalse(fixture.service.isFavorite(siteId: "a", market: "FR", operator: "ORANGE"))
        XCTAssertNotNil(fixture.service.errorMessage)
        await fixture.service.load()
        XCTAssertEqual(fixture.server.writes.count, 1, "Un refus définitif n'est pas rejoué")
    }

    func testServerErrorKeepsTheFollowPendingForARetry() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.failNextWrite(status: 500, code: nil, message: "")
        _ = await fixture.service.toggle(Self.a)
        XCTAssertEqual(fixture.service.pendingCount, 1)
        XCTAssertNotNil(fixture.service.errorMessage)
        await fixture.service.load()
        XCTAssertEqual(fixture.service.pendingCount, 0)
        XCTAssertEqual(fixture.server.followKeys(for: "a"), [Self.a.followKey])
        XCTAssertEqual(fixture.server.writes.count, 2)
    }

    func testStorageFailurePreventsRemoteWriteAndCanBeRetried() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        await fixture.store.failWrites(true)
        _ = await fixture.service.toggle(Self.a)
        XCTAssertTrue(fixture.server.writes.isEmpty)
        XCTAssertEqual(fixture.service.pendingCount, 1)
        XCTAssertNotNil(fixture.service.errorMessage)
        await fixture.store.failWrites(false)
        await fixture.service.load()
        XCTAssertEqual(fixture.server.followKeys(for: "a"), [Self.a.followKey])
        XCTAssertEqual(fixture.service.pendingCount, 0)
    }

    func testCorruptLocalStateIsNotReplacedByServerOrEmptyData() async throws {
        let fixture = try Fixture(initial: [Self.a])
        await fixture.store.failReads(true)
        await fixture.service.load()
        _ = await fixture.service.toggle(Self.b)
        XCTAssertEqual(fixture.server.readCount, 0)
        XCTAssertTrue(fixture.server.writes.isEmpty)
        XCTAssertFalse(fixture.service.hasLoaded)
        XCTAssertNotNil(fixture.service.errorMessage)
    }

    func testAccountSwitchHidesOldDataAndDoesNotSendOldIntentsAsNewUser() async throws {
        let fixture = try Fixture(initial: [Self.a])
        await fixture.service.load()
        fixture.server.setWriteFailure(true)
        _ = await fixture.service.toggle(Self.b)
        fixture.owner.session = LocalAccountSession(ownerScopeId: "user:b", sessionId: "b-session")
        try fixture.credentials.setAccessToken("b")
        XCTAssertTrue(fixture.service.favorites.isEmpty, "Le getter ne révèle pas A avant le reset UI")
        XCTAssertNil(fixture.service.errorMessage)
        fixture.server.setFollows([Self.aSFR], for: "b")
        fixture.server.setWriteFailure(false)
        fixture.service.resetForAccountChange()
        await fixture.service.load()
        XCTAssertEqual(fixture.service.favorites.map(\.followKey), [Self.aSFR.followKey])
        XCTAssertEqual(fixture.server.writeOwners, ["a"])
        XCTAssertEqual(fixture.service.pendingCount, 0)
        let previous = await fixture.store.state(for: "user:a")
        XCTAssertEqual(previous?.pending.count, 1)
    }

    func testGestureCapturedBeforeAccountSwitchCannotStartWriteAfterTaskDelay() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        let scope = try XCTUnwrap(fixture.service.captureActionScope())
        fixture.owner.session = .init(ownerScopeId: "user:b", sessionId: "b-session")
        try fixture.credentials.setAccessToken("b")
        _ = await fixture.service.toggle(Self.a, matching: scope)
        await fixture.service.remove(Self.a, matching: scope)
        XCTAssertTrue(fixture.server.writes.isEmpty)
        XCTAssertTrue(fixture.service.favorites.isEmpty)
    }

    func testRejectionDoesNotLeaveOtherQueuedTargetWaiting() async throws {
        let fixture = try Fixture(initial: [Self.b])
        await fixture.service.load()
        let started = expectation(description: "Suivi bientôt refusé")
        let release = DispatchSemaphore(value: 0)
        fixture.server.failNextWrite(status: 404, code: "SITE_NOT_FOUND", message: "Site introuvable")
        fixture.server.holdNextWrite(started: started, release: release)
        let add = Task { await fixture.service.toggle(Self.a) }
        await fulfillment(of: [started], timeout: 1)
        let remove = Task { await fixture.service.remove(Self.b) }
        await waitUntil { !fixture.service.isFavorite(siteId: Self.b.siteId, market: Self.b.market) }
        release.signal()
        _ = await (add.value, remove.value)
        XCTAssertEqual(fixture.server.writes, ["POST FR|ORANGE|a", "DELETE CA|BELL|b"])
        XCTAssertTrue(fixture.server.followKeys(for: "a").isEmpty)
        XCTAssertEqual(fixture.service.pendingCount, 0)
        XCTAssertNotNil(fixture.service.errorMessage, "Le refus de A reste expliqué même si B réussit")
    }

    func testIntentQueuedAtWorkerCompletionStartsAnotherSynchronization() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        let secondFinished = expectation(description: "Intention créée à la clôture synchronisée")
        let observer = fixture.service.$isSynchronizing.dropFirst().filter { !$0 }.prefix(1).sink { _ in
            Task {
                _ = await fixture.service.toggle(Self.b)
                secondFinished.fulfill()
            }
        }
        defer { observer.cancel() }
        _ = await fixture.service.toggle(Self.a)
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertEqual(fixture.server.followKeys(for: "a"), Set([Self.a.followKey, Self.b.followKey]))
        XCTAssertEqual(fixture.service.pendingCount, 0)
    }

    func testCanonicalIdentityMatchesCaseAndSpacingAcrossClients() async throws {
        let fixture = try Fixture(initial: [FavoriteAntenna(siteId: "AB 123", market: "FR", operator: "BOUYGUES_TELECOM")])
        await fixture.service.load()
        XCTAssertTrue(fixture.service.isFavorite(siteId: "ab123", market: " fr ", operator: "bouygues telecom"))
        await fixture.service.remove(FavoriteAntenna(siteId: "ab123", market: "fr", operator: "Bouygues Telecom"))
        XCTAssertTrue(fixture.server.followKeys(for: "a").isEmpty)
    }

    func testServerSiteKeyMatchesAnAliasOfTheSameSupport() async throws {
        let fixture = try Fixture(initial: [FavoriteAntenna(siteId: "alias-1", market: "FR", operator: "ORANGE", siteKey: "0381234")])
        await fixture.service.load()
        XCTAssertTrue(fixture.service.isFavorite(siteId: "0381234", market: "FR", operator: "ORANGE"))
        XCTAssertTrue(fixture.service.isFavorite(siteId: "alias-1", market: "FR", operator: "ORANGE"))
        XCTAssertFalse(fixture.service.isFavorite(siteId: "0381234", market: "FR", operator: "SFR"))
    }

    // MARK: Intentions de l'ancienne passerelle déjà en file

    func testLegacyIntentsAreDrainedByTheGatewayThenListIsReadFromFollows() async throws {
        let fixture = try Fixture()
        var legacy = FavoriteAntennasLocalState(ownerScopeID: "user:a")
        legacy.enqueue(.favorite(Self.a, present: true))
        legacy.enqueue(.notifications(false))
        await fixture.store.seed(legacy)
        await fixture.service.load()
        XCTAssertEqual(Set(fixture.server.gatewayMutations.map(\.operation)), [.upsert, .preferences])
        XCTAssertEqual(fixture.server.gatewayMutations.count, 2)
        XCTAssertTrue(fixture.server.writes.isEmpty, "Une intention ancienne ne s'écrit pas aussi dans les suivis")
        XCTAssertEqual(fixture.service.favorites.map(\.followKey), [Self.a.followKey])
        XCTAssertEqual(fixture.service.pendingCount, 0)
        XCTAssertTrue(fixture.service.hasLoaded)
        XCTAssertFalse(fixture.server.requests.contains { $0.contains("GET /api/android") })
        XCTAssertEqual(fixture.server.requests.last, "GET /api/me/follows")
    }

    func testLegacyRemovalCarriesNoOperatorAndRemovesTheSiteFollows() async throws {
        let fixture = try Fixture(initial: [Self.a, Self.aSFR, Self.b])
        var legacy = FavoriteAntennasLocalState(ownerScopeID: "user:a")
        legacy.enqueue(.favorite(Self.a, present: false))
        await fixture.store.seed(legacy)
        let intent = try XCTUnwrap(legacy.pending.first)
        XCTAssertNil(intent.favorite)
        XCTAssertEqual(intent.siteId, "a")
        await fixture.service.load()
        XCTAssertEqual(fixture.server.gatewayMutations.map(\.operation), [.remove])
        XCTAssertTrue(fixture.server.writes.isEmpty)
        XCTAssertEqual(fixture.service.favorites.map(\.followKey), [Self.b.followKey])
        XCTAssertEqual(fixture.service.pendingCount, 0)
    }

    func testLegacyIntentOfAnOldFileStaysVisibleWhileOffline() async throws {
        let fixture = try Fixture()
        var legacy = FavoriteAntennasLocalState(ownerScopeID: "user:a")
        legacy.enqueue(.favorite(Self.b, present: true))
        await fixture.store.seed(legacy)
        fixture.server.setReadFailure(true)
        fixture.server.setWriteFailure(true)
        await fixture.service.load()
        XCTAssertEqual(fixture.service.favorites.map(\.followKey), [Self.b.followKey])
        XCTAssertEqual(fixture.service.pendingCount, 1, "L'intention n'est pas perdue")
        XCTAssertFalse(fixture.service.hasLoaded)
        let durable = await fixture.store.state(for: "user:a")
        XCTAssertEqual(durable?.pending.map(\.operation), [.upsert])
    }

    private static let a = FavoriteAntenna(siteId: "a", market: "FR", operator: "ORANGE", name: "Site A")
    private static let aSFR = FavoriteAntenna(siteId: "a", market: "FR", operator: "SFR", name: "Site A")
    private static let b = FavoriteAntenna(siteId: "b", market: "CA", operator: "BELL", name: "Site B")

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(1)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate())
    }

    @MainActor
    private final class Fixture {
        let owner = FavoriteOwnerBox()
        let store = FavoriteMemoryStore()
        let server: FollowHTTPDriver
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let api: APIClient
        let service: FavoriteAntennasService
        init(initial: [FavoriteAntenna] = []) throws {
            server = FollowHTTPDriver(initial: initial)
            let server = self.server
            MockURLProtocol.requestHandler = { try server.handle($0) }
            try credentials.setAccessToken("a")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.protocolClasses = [MockURLProtocol.self]
            api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
            let owner = self.owner
            service = FavoriteAntennasService(api: api, store: store, sessionSnapshot: { owner.session })
        }
        func makeService() -> FavoriteAntennasService {
            let owner = self.owner
            return FavoriteAntennasService(api: api, store: store, sessionSnapshot: { owner.session })
        }
    }
}

@MainActor
private final class FavoriteOwnerBox {
    var session: LocalAccountSession? = .init(ownerScopeId: "user:a", sessionId: "a-session")
}

private actor FavoriteMemoryStore: FavoriteAntennasStoring {
    private var snapshots: [String: FavoriteAntennasLocalState] = [:]
    private var readFailure = false
    private var writeFailure = false
    func failReads(_ value: Bool) { readFailure = value }
    func failWrites(_ value: Bool) { writeFailure = value }
    func seed(_ state: FavoriteAntennasLocalState) { snapshots[state.ownerScopeID] = state }
    func state(for owner: String) -> FavoriteAntennasLocalState? { snapshots[owner] }
    func load(ownerScopeID: String) throws -> FavoriteAntennasLocalState? {
        if readFailure { throw APIError.decoding("synthetic-corruption") }
        return snapshots[ownerScopeID]
    }
    func save(_ state: FavoriteAntennasLocalState) throws {
        if writeFailure { throw APIError.transport("synthetic-storage") }
        guard state.localRevision >= (snapshots[state.ownerScopeID]?.localRevision ?? 0) else { return }
        snapshots[state.ownerScopeID] = state
    }
    func remove(ownerScopeID: String) { snapshots.removeValue(forKey: ownerScopeID) }
}

/// Contrat de transport synthétique : `/api/me/follows` (liste, statut, création, retrait) et la
/// passerelle `/api/android/favorite-antennas` pour les anciennes intentions, qui écrit dans les
/// mêmes suivis, comme le serveur. Le vrai client HTTP est testé sans réseau.
private final class FollowHTTPDriver: @unchecked Sendable {
    private struct Follow: Equatable {
        let id: String
        let market: String
        let `operator`: String
        let siteId: String
        let label: String?
        var siteKey: String? = nil
        var followKey: String { FavoriteAntenna.followKey(siteId: siteId, market: market, operator: `operator`) }
        var line: String { "\(market)|\(`operator`)|\(siteId)" }
    }
    private let lock = NSLock()
    private var follows: [String: [Follow]] = [:]
    private var serial = 0
    private var receipts: Set<String> = []
    private var notificationValues: [String: Bool] = [:]
    private var requestLines: [String] = []
    private var writeLines: [String] = []
    private var writeOwnerList: [String] = []
    private var gateway: [FavoriteAntennaIntent] = []
    private var reads = 0
    private var readFailure = false
    private var writeFailure = false
    private var loseCommittedResponse = false
    private var injectedFailure: (status: Int, code: String?, message: String)?
    private var gate: (XCTestExpectation, DispatchSemaphore)?

    init(initial: [FavoriteAntenna]) { follows["a"] = initial.map { makeFollow($0) } }

    var requests: [String] { lock.withLock { requestLines } }
    var writes: [String] { lock.withLock { writeLines } }
    var writeOwners: [String] { lock.withLock { writeOwnerList } }
    var gatewayMutations: [FavoriteAntennaIntent] { lock.withLock { gateway } }
    var readCount: Int { lock.withLock { reads } }
    func followKeys(for owner: String) -> Set<String> { lock.withLock { Set((follows[owner] ?? []).map(\.followKey)) } }
    func setFollows(_ items: [FavoriteAntenna], for owner: String) { lock.withLock { follows[owner] = items.map { makeFollow($0) } } }
    func setReadFailure(_ value: Bool) { lock.withLock { readFailure = value } }
    func setWriteFailure(_ value: Bool) { lock.withLock { writeFailure = value } }
    func dropNextCommittedResponse() { lock.withLock { loseCommittedResponse = true } }
    func failNextWrite(status: Int, code: String?, message: String) { lock.withLock { injectedFailure = (status, code, message) } }
    func holdNextWrite(started: XCTestExpectation, release: DispatchSemaphore) { lock.withLock { gate = (started, release) } }

    private func makeFollow(_ item: FavoriteAntenna) -> Follow {
        serial += 1
        return Follow(id: "f\(serial)", market: item.market, operator: item.operator ?? "ORANGE", siteId: item.siteId,
                      label: item.name, siteKey: item.siteKey)
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let owner = (request.value(forHTTPHeaderField: "Cookie") ?? "").replacingOccurrences(of: "auth_token=", with: "")
        lock.withLock { requestLines.append("\(method) \(path)") }
        if path == "/api/android/favorite-antennas" { return try handleGateway(request, method: method, owner: owner) }
        switch (method, path) {
        case ("GET", "/api/me/follows"):
            return try lock.withLock {
                if readFailure { throw URLError(.notConnectedToInternet) }
                reads += 1
                let sites = (follows[owner] ?? []).map(Self.siteJSON)
                return try Self.reply(request, 200, ["sites": sites, "operators": [], "zones": [],
                                                      "limits": ["sites": 500, "operators": 10]])
            }
        case ("GET", "/api/me/follows/status"):
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
            return try lock.withLock {
                if readFailure { throw URLError(.notConnectedToInternet) }
                let match = (follows[owner] ?? []).first {
                    $0.followKey == FavoriteAntenna.followKey(siteId: value("siteId"), market: value("market"), operator: value("operator"))
                }
                let followId: Any = match.map { $0.id as Any } ?? NSNull()
                return try Self.reply(request, 200, ["following": match != nil, "followId": followId, "notify": match != nil])
            }
        case ("POST", "/api/me/follows"):
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Self.body(request))) as? [String: String])
            XCTAssertEqual(Set(body.keys), ["kind", "market", "operator", "siteId"], "Corps strict de la création")
            XCTAssertEqual(body["kind"], "site")
            let created = Follow(id: "", market: body["market"] ?? "", operator: body["operator"] ?? "", siteId: body["siteId"] ?? "", label: nil)
            record("POST \(created.line)", owner: owner)
            return try lock.withLock {
                if let failure = try takeFailure(request) { return failure }
                var rows = follows[owner] ?? []
                let existing = rows.first { $0.followKey == created.followKey }
                if existing == nil {
                    serial += 1
                    rows.append(Follow(id: "f\(serial)", market: created.market, operator: created.operator, siteId: created.siteId, label: nil))
                    follows[owner] = rows
                }
                if loseCommittedResponse { loseCommittedResponse = false; throw URLError(.networkConnectionLost) }
                let row = rows.first { $0.followKey == created.followKey }!
                return try Self.reply(request, existing == nil ? 201 : 200, ["follow": Self.siteJSON(row)])
            }
        case ("DELETE", _) where path.hasPrefix("/api/me/follows/"):
            let id = String(path.dropFirst("/api/me/follows/".count))
            let row = lock.withLock { (follows[owner] ?? []).first { $0.id == id } }
            record("DELETE \(row?.line ?? id)", owner: owner)
            return try lock.withLock {
                if let failure = try takeFailure(request) { return failure }
                guard row != nil else { return try Self.reply(request, 404, ["error": "Suivi introuvable", "code": "NOT_FOUND"]) }
                follows[owner]?.removeAll { $0.id == id }
                return try Self.reply(request, 200, ["ok": true])
            }
        default:
            XCTFail("Route inattendue : \(method) \(path)")
            return try Self.reply(request, 404, [:])
        }
    }

    /// Les anciennes intentions : écrites comme le fait la passerelle, c'est-à-dire dans les suivis.
    private func handleGateway(_ request: URLRequest, method: String, owner: String) throws -> (HTTPURLResponse, Data) {
        XCTAssertEqual(method, "PATCH", "Le client iOS ne lit ni ne remplace jamais la liste par la passerelle")
        let data = try XCTUnwrap(Self.body(request))
        let intent = try JSONDecoder.signalQuest.decode(FavoriteAntennaIntent.self, from: data)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), intent.requestId)
        lock.withLock { gateway.append(intent) }
        return try lock.withLock {
            if writeFailure { throw URLError(.notConnectedToInternet) }
            let replay = !receipts.insert(owner + ":" + intent.requestId).inserted
            if !replay {
                switch intent.operation {
                case .upsert:
                    if let favorite = intent.favorite, let operatorName = favorite.operator, !operatorName.isEmpty {
                        var rows = follows[owner] ?? []
                        if !rows.contains(where: { $0.followKey == favorite.followKey }) {
                            serial += 1
                            rows.append(Follow(id: "f\(serial)", market: favorite.market, operator: operatorName,
                                               siteId: favorite.siteId, label: favorite.name))
                            follows[owner] = rows
                        }
                    }
                case .remove:
                    follows[owner]?.removeAll { FavoriteAntenna.key(siteId: $0.siteId, market: $0.market) == intent.targetKey }
                case .preferences:
                    notificationValues[owner] = intent.notifyFavoriteAntennaIssuesPush
                case .follow, .unfollow:
                    XCTFail("Un geste d'aujourd'hui ne passe jamais par la passerelle")
                }
            }
            struct Payload: Encodable {
                let favorites: [FavoriteAntenna]
                let notifyFavoriteAntennaIssuesPush: Bool
                let revision: String
                let success: Bool
                let idempotent: Bool
            }
            var seen = Set<String>()
            let favorites = (follows[owner] ?? []).filter {
                seen.insert(FavoriteAntenna.key(siteId: $0.siteId, market: $0.market)).inserted
            }.map { FavoriteAntenna(siteId: $0.siteId, market: $0.market, operator: $0.operator, name: $0.label) }
            let payload = Payload(favorites: favorites, notifyFavoriteAntennaIssuesPush: notificationValues[owner] ?? true,
                                  revision: "opaque-\(gateway.count)", success: true, idempotent: replay)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!,
                    try JSONEncoder.signalQuest.encode(payload))
        }
    }

    /// Note l'écriture, puis attend que le test la libère si elle est retenue.
    private func record(_ line: String, owner: String) {
        let held = lock.withLock { () -> (XCTestExpectation, DispatchSemaphore)? in
            writeLines.append(line); writeOwnerList.append(owner)
            let result = gate; gate = nil; return result
        }
        if let (started, release) = held { started.fulfill(); _ = release.wait(timeout: .now() + 5) }
    }

    private func takeFailure(_ request: URLRequest) throws -> (HTTPURLResponse, Data)? {
        if writeFailure { throw URLError(.notConnectedToInternet) }
        guard let failure = injectedFailure else { return nil }
        injectedFailure = nil
        var body: [String: Any] = ["error": failure.message]
        if let code = failure.code { body["code"] = code }
        return try Self.reply(request, failure.status, body)
    }

    private static func siteJSON(_ row: Follow) -> [String: Any] {
        let label: Any = row.label.map { $0 as Any } ?? NSNull()
        return ["id": row.id, "kind": "site", "market": row.market, "operator": row.operator, "siteId": row.siteId,
                "siteKey": row.siteKey ?? row.siteId.filter { !$0.isWhitespace }.uppercased(), "label": label,
                "lat": NSNull(), "lon": NSNull(), "notify": true, "createdAt": "2026-10-19T12:00:00.000Z"]
    }

    private static func reply(_ request: URLRequest, _ status: Int, _ object: [String: Any]) throws -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!,
         try JSONSerialization.data(withJSONObject: object))
    }

    private static func body(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

final class FavoriteAntennasStorageTests: XCTestCase {
    func testSameUserInDifferentAPIEnvironmentsDoesNotShareJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prod = FavoriteAntennasLocalStore(directory: directory, environmentID: "https://api.example.test:443/")
        let staging = FavoriteAntennasLocalStore(directory: directory, environmentID: "https://staging.example.test/")
        let sameProd = FavoriteAntennasLocalStore(directory: directory, environmentID: "https://API.example.test")
        var state = FavoriteAntennasLocalState(ownerScopeID: "user:a")
        state.enqueue(.notifications(false))
        try await prod.save(state)
        let anotherEnvironment = try await staging.load(ownerScopeID: "user:a")
        let normalizedAlias = try await sameProd.load(ownerScopeID: "user:a")
        XCTAssertNil(anotherEnvironment)
        XCTAssertEqual(normalizedAlias, state)
    }
    func testPersistenceSurvivesNewStoreAndStaysScopedToItsOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FavoriteAntennasLocalStore(directory: directory)
        var state = FavoriteAntennasLocalState(ownerScopeID: "user:a")
        state.enqueue(.favorite(FavoriteAntenna(siteId: "a", market: "FR", operator: nil), present: true))
        try await first.save(state)
        let reopened = FavoriteAntennasLocalStore(directory: directory)
        let restored = try await reopened.load(ownerScopeID: "user:a")
        let another = try await reopened.load(ownerScopeID: "user:b")
        XCTAssertEqual(restored, state)
        XCTAssertNil(another)
    }

    func testOlderPersistenceCannotOverwriteNewerIntentState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoriteAntennasLocalStore(directory: directory)
        var old = FavoriteAntennasLocalState(ownerScopeID: "user:a")
        old.enqueue(.notifications(true))
        var latest = old; latest.enqueue(.notifications(false))
        try await store.save(latest)
        try await store.save(old)
        let restored = try await store.load(ownerScopeID: "user:a")
        XCTAssertEqual(restored, latest)
    }

    func testCorruptionIsReportedWithoutDeletingOrResettingLocalFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoriteAntennasLocalStore(directory: directory)
        try await store.save(FavoriteAntennasLocalState(ownerScopeID: "user:a"))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let invalid = Data("synthetic-corruption".utf8)
        try invalid.write(to: file)
        do { _ = try await store.load(ownerScopeID: "user:a"); XCTFail("La corruption doit être remontée") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    func testAccountErasureRejectsLateSaveThatWouldResurrectLocalData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FavoriteAntennasLocalStore(directory: directory)
        let state = FavoriteAntennasLocalState(ownerScopeID: "user:a")
        try await store.save(state)
        try await store.remove(ownerScopeID: "user:a")
        do { try await store.save(state); XCTFail("Une ancienne tâche ne doit pas ressusciter le compte supprimé") }
        catch APIError.cancelled {} catch { XCTFail("Erreur inattendue : \(error)") }
        let restored = try await store.load(ownerScopeID: "user:a")
        XCTAssertNil(restored)
    }

    /// Un fichier écrit avant la bascule (favoris de la passerelle, intention en file) se relit tel quel :
    /// la liste reste affichée, l'intention part encore, et la liste des suivis sera relue.
    func testFileWrittenBeforeTheFollowsSwitchStillDecodesWithItsPendingIntent() throws {
        let json = """
        {"version":1,"ownerScopeID":"user:a","localRevision":4,
         "confirmedFavorites":[{"siteId":"0381234","market":"FR","operator":"SFR","name":"Lyon"}],
         "confirmedNotifications":true,"serverRevision":"r1",
         "pending":[{"requestId":"6f1c2b7e-0a43-4f6e-9a3d-4d1f1c0a9b11","operation":"remove","siteId":"0381234","market":"FR"}],
         "attemptedRequestIDs":["6f1c2b7e-0a43-4f6e-9a3d-4d1f1c0a9b11"]}
        """
        let state = try JSONDecoder.signalQuest.decode(FavoriteAntennasLocalState.self, from: Data(json.utf8))
        try state.validate(owner: "user:a")
        XCTAssertNil(state.followsConfirmed)
        XCTAssertFalse(state.hasSnapshot, "La liste des suivis n'a pas encore été relue")
        XCTAssertTrue(state.favorites.isEmpty, "Le retrait en file masque déjà le site")
        XCTAssertEqual(state.nextIntent?.operation, .remove)
        XCTAssertEqual(state.nextIntent?.siteKey, "FR:0381234")
    }

    func testUnfollowHidesOnlyItsOperatorWhileALegacyRemovalHidesEveryOperatorOfTheSite() {
        let orange = FavoriteAntenna(siteId: "a", market: "FR", operator: "ORANGE")
        let sfr = FavoriteAntenna(siteId: "a", market: "FR", operator: "SFR")
        let other = FavoriteAntenna(siteId: "b", market: "FR", operator: "ORANGE")
        var state = FavoriteAntennasLocalState(ownerScopeID: "user:a")
        state.receive(follows: [orange, sfr, other])
        XCTAssertTrue(state.hasSnapshot)
        var unfollowing = state
        unfollowing.enqueue(.follow(orange, present: false))
        XCTAssertEqual(Set(unfollowing.favorites.map(\.followKey)), [sfr.followKey, other.followKey])
        var legacy = state
        legacy.enqueue(.favorite(orange, present: false))
        XCTAssertEqual(legacy.favorites.map(\.followKey), [other.followKey])
        var following = state
        following.enqueue(.follow(FavoriteAntenna(siteId: "c", market: "FR", operator: "FREE"), present: true))
        XCTAssertEqual(following.favorites.count, 4)
    }

    func testFollowIntentsNeedAnOperatorToBeStoredLocally() {
        var state = FavoriteAntennasLocalState(ownerScopeID: "user:a")
        state.enqueue(.follow(FavoriteAntenna(siteId: "a", market: "FR", operator: nil), present: true))
        XCTAssertThrowsError(try state.validate(owner: "user:a"))
        var valid = FavoriteAntennasLocalState(ownerScopeID: "user:a")
        valid.enqueue(.follow(FavoriteAntenna(siteId: "a", market: "FR", operator: "ORANGE"), present: true))
        XCTAssertNoThrow(try valid.validate(owner: "user:a"))
    }

    /// `GET /api/me/follows` : la forme servie par `serializeSiteFollow`, activité comprise, et des
    /// opérateurs ou zones que l'écran ne lit pas.
    func testDecodesTheFollowsListIgnoringActivityOperatorsAndZones() throws {
        let json = """
        {"sites":[{"id":"c1","kind":"site","market":"FR","operator":"ORANGE","siteId":"0381234","siteKey":"0381234",
                   "label":"Lyon 3e","lat":45.76,"lon":4.85,"notify":true,"createdAt":"2026-10-19T12:00:00.000Z",
                   "activity":{"since":"2026-10-19T12:00:00.000Z","newCount":2,"comments":1,"photos":0,"activated":0,"newBands":1,"outage":null}},
                  {"id":"c2","kind":"site","market":"FR","operator":"SFR","siteId":"0381234","siteKey":"0381234",
                   "label":null,"lat":null,"lon":null,"notify":false,"createdAt":"2026-10-18T08:00:00.000Z"}],
         "operators":[{"id":"o1","kind":"operator","market":"FR","operator":"FREE","department":null,"createdAt":"2026-10-01T00:00:00.000Z"}],
         "zones":[],"limits":{"sites":500,"operators":10},"requestId":"r"}
        """
        let list = try JSONDecoder.signalQuest.decode(SiteFollowsResponse.self, from: Data(json.utf8))
        try list.validate()
        XCTAssertEqual(list.antennas.map(\.operator), ["ORANGE", "SFR"])
        XCTAssertEqual(list.antennas.first?.name, "Lyon 3e")
        XCTAssertEqual(list.antennas.first?.latitude, 45.76)
        XCTAssertEqual(list.antennas.first?.siteKey, "0381234")
        XCTAssertEqual(Set(list.antennas.map(\.followKey)).count, 2, "Un pylône suivi chez deux opérateurs donne deux lignes")
    }
}
