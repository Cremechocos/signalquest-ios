import XCTest
import Combine
@testable import SignalQuest

@MainActor
final class FavoriteAntennasTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    func testFailedInitialReadCannotWriteEmptyFavoritesFromNotificationChange() async throws {
        let fixture = try Fixture(initial: [Self.a])
        fixture.server.setReadFailure(true)
        await fixture.service.setNotifyOnIssues(false)
        XCTAssertEqual(fixture.server.favorites(for: "a"), [Self.a])
        XCTAssertTrue(fixture.server.mutations.isEmpty)
        XCTAssertFalse(fixture.service.hasLoaded)
        XCTAssertNotNil(fixture.service.errorMessage)
    }

    func testFailedRefreshKeepsLastConfirmedListAndPreference() async throws {
        let fixture = try Fixture(initial: [Self.a])
        await fixture.service.load()
        fixture.server.setReadFailure(true)
        await fixture.service.load()
        XCTAssertEqual(fixture.service.favorites, [Self.a])
        XCTAssertTrue(fixture.service.notifyOnIssues)
        XCTAssertTrue(fixture.service.hasLoaded)
        XCTAssertNotNil(fixture.service.errorMessage)
    }

    func testNotificationPatchPersistsWithoutSendingFavorites() async throws {
        let fixture = try Fixture(initial: [Self.a])
        await fixture.service.load()
        await fixture.service.setNotifyOnIssues(false)
        XCTAssertFalse(fixture.service.notifyOnIssues)
        XCTAssertEqual(fixture.server.favorites(for: "a"), [Self.a])
        XCTAssertEqual(fixture.server.mutations.map(\.operation), [.preferences])
        XCTAssertNil(fixture.server.mutations.first?.favorite)
        let reopened = fixture.makeService()
        await reopened.load()
        XCTAssertFalse(reopened.notifyOnIssues)
        XCTAssertEqual(reopened.favorites, [Self.a])
    }

    func testTwoAddsRemainVisibleWhileFirstPatchIsInFlightAndAreSentSerially() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        let started = expectation(description: "Premier PATCH en vol")
        let release = DispatchSemaphore(value: 0)
        fixture.server.holdNextPatch(started: started, release: release)
        let first = Task { await fixture.service.toggle(Self.a) }
        await fulfillment(of: [started], timeout: 1)
        let second = Task { await fixture.service.toggle(Self.b) }
        await waitUntil { fixture.service.favorites.count == 2 }
        XCTAssertEqual(fixture.server.mutations.count, 1, "Un seul PATCH réseau à la fois")
        release.signal()
        _ = await (first.value, second.value)
        XCTAssertEqual(Set(fixture.service.favorites.map(\.id)), Set([Self.a.id, Self.b.id]))
        XCTAssertEqual(Set(fixture.server.favorites(for: "a").map(\.id)), Set([Self.a.id, Self.b.id]))
        XCTAssertEqual(fixture.service.pendingCount, 0)
    }

    func testLaterRemovalOfSameFavoriteSurvivesOlderAddResponse() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        let started = expectation(description: "Ajout A en vol")
        let release = DispatchSemaphore(value: 0)
        fixture.server.holdNextPatch(started: started, release: release)
        let add = Task { await fixture.service.toggle(Self.a) }
        await fulfillment(of: [started], timeout: 1)
        let remove = Task { await fixture.service.remove(Self.a) }
        await waitUntil { fixture.service.favorites.isEmpty }
        release.signal()
        _ = await (add.value, remove.value)
        XCTAssertTrue(fixture.service.favorites.isEmpty)
        XCTAssertTrue(fixture.server.favorites(for: "a").isEmpty)
        XCTAssertEqual(fixture.server.mutations.map(\.operation), [.upsert, .remove])
    }

    func testOtherDeviceFavoriteIsNotLostDuringLocalAdd() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.setFavorites([Self.b], for: "a")
        _ = await fixture.service.toggle(Self.a)
        XCTAssertEqual(Set(fixture.service.favorites.map(\.id)), Set([Self.a.id, Self.b.id]))
        XCTAssertEqual(fixture.server.mutations.map(\.operation), [.upsert])
    }

    func testExplicitRemovalNeverReaddsFavoriteAlreadyRemovedByAnotherDevice() async throws {
        let fixture = try Fixture(initial: [Self.a])
        await fixture.service.load()
        fixture.server.setFavorites([], for: "a")
        await fixture.service.remove(Self.a)
        XCTAssertTrue(fixture.service.favorites.isEmpty)
        XCTAssertEqual(fixture.server.mutations.map(\.operation), [.remove])
    }

    func testOfflineIntentPersistsAndRetriesWithSameRequestIdAfterReopening() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.setWriteFailure(true)
        _ = await fixture.service.toggle(Self.a)
        XCTAssertEqual(fixture.service.favorites, [Self.a])
        XCTAssertEqual(fixture.service.pendingCount, 1)
        XCTAssertNotNil(fixture.service.errorMessage)
        let firstID = try XCTUnwrap(fixture.server.mutations.first?.requestId)
        let durable = await fixture.store.state(for: "user:a")
        XCTAssertEqual(durable?.pending.first?.requestId, firstID)
        fixture.server.setWriteFailure(false)
        let reopened = fixture.makeService()
        await reopened.load()
        XCTAssertEqual(reopened.favorites, [Self.a])
        XCTAssertEqual(reopened.pendingCount, 0)
        XCTAssertEqual(fixture.server.mutations.last?.requestId, firstID)
    }

    func testReceiptReplayDoesNotResurrectFavoriteRemovedAfterLostResponse() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.dropNextCommittedResponse()
        _ = await fixture.service.toggle(Self.a)
        XCTAssertEqual(fixture.service.pendingCount, 1)
        fixture.server.setFavorites([Self.b], for: "a")
        let reopened = fixture.makeService()
        await reopened.load()
        XCTAssertEqual(reopened.favorites, [Self.b])
        XCTAssertEqual(fixture.server.favorites(for: "a"), [Self.b])
        XCTAssertEqual(reopened.pendingCount, 0)
        XCTAssertEqual(fixture.server.mutations.first?.requestId, fixture.server.mutations.last?.requestId)
    }

    func testInverseIntentWaitsForReceiptOfEarlierAmbiguousWrite() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.setWriteFailure(true)
        _ = await fixture.service.toggle(Self.a)
        let ambiguousID = try XCTUnwrap(fixture.server.mutations.first?.requestId)
        fixture.server.setWriteFailure(false)
        await fixture.service.remove(Self.a)
        XCTAssertEqual(fixture.server.mutations.map(\.operation), [.upsert, .upsert, .remove])
        XCTAssertEqual(fixture.server.mutations[1].requestId, ambiguousID,
            "Le reçu de l'ancien ajout doit précéder le retrait, même après une erreur réseau")
        XCTAssertTrue(fixture.server.favorites(for: "a").isEmpty)
        XCTAssertEqual(fixture.service.pendingCount, 0)
    }

    func testTerminalCapacityRejectionRequiresNewIntentInsteadOfRetryingSameUUID() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.rejectNextAddAtCapacity()
        _ = await fixture.service.toggle(Self.a)
        XCTAssertEqual(fixture.service.pendingCount, 0)
        XCTAssertFalse(fixture.service.isFavorite(siteId: Self.a.siteId, market: Self.a.market))
        let rejectedID = try XCTUnwrap(fixture.server.mutations.first?.requestId)
        _ = await fixture.service.toggle(Self.a)
        XCTAssertEqual(fixture.server.mutations.map(\.operation), [.upsert, .upsert])
        XCTAssertNotEqual(fixture.server.mutations.last?.requestId, rejectedID)
        XCTAssertEqual(fixture.server.favorites(for: "a"), [Self.a])
        XCTAssertEqual(fixture.service.pendingCount, 0)
    }

    func testCapacityErrorWithoutMatchingTerminalReceiptKeepsAmbiguousIntent() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        fixture.server.rejectNextAddAtCapacity(terminal: false)
        _ = await fixture.service.toggle(Self.a)
        XCTAssertEqual(fixture.service.pendingCount, 1)
        let firstID = try XCTUnwrap(fixture.server.mutations.first?.requestId)
        let durable = await fixture.store.state(for: "user:a")
        XCTAssertTrue(durable?.attemptedRequestIDs.contains(firstID) == true)
        await fixture.service.remove(Self.a)
        XCTAssertEqual(fixture.server.mutations.map(\.operation), [.upsert, .upsert, .remove])
        XCTAssertEqual(fixture.server.mutations[1].requestId, firstID)
        XCTAssertTrue(fixture.server.favorites(for: "a").isEmpty)
    }

    func testLatestNotificationIntentIsNotRolledBackByEarlierReply() async throws {
        let fixture = try Fixture(initial: [Self.a])
        await fixture.service.load()
        let started = expectation(description: "Préférence en vol")
        let release = DispatchSemaphore(value: 0)
        fixture.server.holdNextPatch(started: started, release: release)
        let disable = Task { await fixture.service.setNotifyOnIssues(false) }
        await fulfillment(of: [started], timeout: 1)
        let enable = Task { await fixture.service.setNotifyOnIssues(true) }
        await waitUntil { fixture.service.notifyOnIssues }
        release.signal()
        _ = await (disable.value, enable.value)
        XCTAssertTrue(fixture.service.notifyOnIssues)
        XCTAssertEqual(fixture.server.mutations.map(\.operation), [.preferences, .preferences])
        XCTAssertEqual(fixture.server.favorites(for: "a"), [Self.a])
        XCTAssertEqual(fixture.service.pendingCount, 0)
    }

    func testStorageFailurePreventsRemoteMutationAndCanBeRetried() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        await fixture.store.failWrites(true)
        _ = await fixture.service.toggle(Self.a)
        XCTAssertTrue(fixture.server.mutations.isEmpty)
        XCTAssertEqual(fixture.service.pendingCount, 1)
        XCTAssertNotNil(fixture.service.errorMessage)
        await fixture.store.failWrites(false)
        await fixture.service.load()
        XCTAssertEqual(fixture.server.favorites(for: "a"), [Self.a])
        XCTAssertEqual(fixture.service.pendingCount, 0)
    }

    func testCorruptLocalStateIsNotReplacedByServerOrEmptyData() async throws {
        let fixture = try Fixture(initial: [Self.a])
        await fixture.store.failReads(true)
        await fixture.service.load()
        await fixture.service.setNotifyOnIssues(false)
        XCTAssertEqual(fixture.server.readCount, 0)
        XCTAssertTrue(fixture.server.mutations.isEmpty)
        XCTAssertFalse(fixture.service.hasLoaded)
        XCTAssertNotNil(fixture.service.errorMessage)
    }

    func testAccountSwitchHidesOldDataAndDoesNotSendOldIntentsAsNewUser() async throws {
        let fixture = try Fixture(initial: [Self.a])
        await fixture.service.load()
        fixture.server.setWriteFailure(true)
        await fixture.service.setNotifyOnIssues(false)
        fixture.owner.session = LocalAccountSession(ownerScopeId: "user:b", sessionId: "b-session")
        try fixture.credentials.setAccessToken("b")
        XCTAssertTrue(fixture.service.favorites.isEmpty, "Le getter ne révèle pas A avant le reset UI")
        XCTAssertNil(fixture.service.errorMessage)
        fixture.server.setFavorites([Self.b], for: "b")
        fixture.server.setWriteFailure(false)
        fixture.service.resetForAccountChange()
        await fixture.service.load()
        XCTAssertEqual(fixture.service.favorites, [Self.b])
        XCTAssertEqual(fixture.server.mutationOwners, ["a"])
        XCTAssertEqual(fixture.service.pendingCount, 0)
        let previous = await fixture.store.state(for: "user:a")
        XCTAssertEqual(previous?.pending.count, 1)
    }

    func testGestureCapturedBeforeAccountSwitchCannotStartMutationAfterTaskDelay() async throws {
        let fixture = try Fixture()
        await fixture.service.load()
        let scope = try XCTUnwrap(fixture.service.captureActionScope())
        fixture.owner.session = .init(ownerScopeId: "user:b", sessionId: "b-session")
        try fixture.credentials.setAccessToken("b")
        _ = await fixture.service.toggle(Self.a, matching: scope)
        await fixture.service.setNotifyOnIssues(false, matching: scope)
        XCTAssertTrue(fixture.server.mutations.isEmpty)
        XCTAssertTrue(fixture.service.favorites.isEmpty)
    }

    func testTerminalRejectionDoesNotLeaveOtherQueuedTargetWaiting() async throws {
        let fixture = try Fixture(initial: [Self.b])
        await fixture.service.load()
        let started = expectation(description: "Ajout bientôt refusé")
        let release = DispatchSemaphore(value: 0)
        fixture.server.rejectNextAddAtCapacity()
        fixture.server.holdNextPatch(started: started, release: release)
        let add = Task { await fixture.service.toggle(Self.a) }
        await fulfillment(of: [started], timeout: 1)
        let remove = Task { await fixture.service.remove(Self.b) }
        await waitUntil { !fixture.service.isFavorite(siteId: Self.b.siteId, market: Self.b.market) }
        release.signal()
        _ = await (add.value, remove.value)
        XCTAssertEqual(fixture.server.mutations.map(\.operation), [.upsert, .remove])
        XCTAssertTrue(fixture.server.favorites(for: "a").isEmpty)
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
        XCTAssertEqual(Set(fixture.server.favorites(for: "a").map(\.id)), Set([Self.a.id, Self.b.id]))
        XCTAssertEqual(fixture.service.pendingCount, 0)
    }

    func testCanonicalIdentityMatchesCaseAndSpacingAcrossClients() async throws {
        let fixture = try Fixture(initial: [FavoriteAntenna(siteId: "AB 123", market: "FR", operator: nil)])
        await fixture.service.load()
        XCTAssertTrue(fixture.service.isFavorite(siteId: "ab123", market: " fr "))
        await fixture.service.remove(FavoriteAntenna(siteId: "ab123", market: "fr", operator: nil))
        XCTAssertTrue(fixture.server.favorites(for: "a").isEmpty)
    }

    private static let a = FavoriteAntenna(siteId: "a", market: "FR", operator: "ORANGE", name: "Site A")
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
        let server: FavoriteHTTPDriver
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let api: APIClient
        let service: FavoriteAntennasService
        init(initial: [FavoriteAntenna] = []) throws {
            server = FavoriteHTTPDriver(initial: initial)
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

/// Contrat de transport synthétique. Les tests backend exercent séparément le
/// vrai handler et ses reçus ; ici le vrai client HTTP est testé sans réseau.
private final class FavoriteHTTPDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [FavoriteAntenna]]
    private var notificationValues: [String: Bool] = [:]
    private var receipts: Set<String> = []
    private var recorded: [FavoriteAntennaIntent] = []
    private var owners: [String] = []
    private var reads = 0
    private var readFailure = false
    private var writeFailure = false
    private var loseCommittedResponse = false
    private var capacityRejection = false
    private var terminalCapacityReceipt = true
    private var gate: (XCTestExpectation, DispatchSemaphore)?
    init(initial: [FavoriteAntenna]) { values = ["a": initial] }
    var mutations: [FavoriteAntennaIntent] { lock.withLock { recorded } }
    var mutationOwners: [String] { lock.withLock { owners } }
    var readCount: Int { lock.withLock { reads } }
    func favorites(for owner: String) -> [FavoriteAntenna] { lock.withLock { values[owner] ?? [] } }
    func setFavorites(_ favorites: [FavoriteAntenna], for owner: String) { lock.withLock { values[owner] = favorites } }
    func setReadFailure(_ value: Bool) { lock.withLock { readFailure = value } }
    func setWriteFailure(_ value: Bool) { lock.withLock { writeFailure = value } }
    func dropNextCommittedResponse() { lock.withLock { loseCommittedResponse = true } }
    func rejectNextAddAtCapacity(terminal: Bool = true) {
        lock.withLock { capacityRejection = true; terminalCapacityReceipt = terminal }
    }
    func holdNextPatch(started: XCTestExpectation, release: DispatchSemaphore) { lock.withLock { gate = (started, release) } }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        XCTAssertEqual(request.url?.path, "/api/android/favorite-antennas")
        let owner = (request.value(forHTTPHeaderField: "Cookie") ?? "").replacingOccurrences(of: "auth_token=", with: "")
        if request.httpMethod == "GET" {
            return try lock.withLock {
                reads += 1
                if readFailure { throw URLError(.notConnectedToInternet) }
                return try response(request, owner: owner)
            }
        }
        XCTAssertEqual(request.httpMethod, "PATCH", "Le client iOS ne doit jamais remplacer une liste par PUT")
        let data = try XCTUnwrap(Self.body(request))
        let intent = try JSONDecoder.signalQuest.decode(FavoriteAntennaIntent.self, from: data)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), intent.requestId)
        let pendingGate = lock.withLock { () -> (XCTestExpectation, DispatchSemaphore)? in
            recorded.append(intent); owners.append(owner)
            let result = gate; gate = nil; return result
        }
        if let (started, release) = pendingGate { started.fulfill(); _ = release.wait(timeout: .now() + 5) }
        return try lock.withLock {
            if writeFailure { throw URLError(.notConnectedToInternet) }
            if capacityRejection, intent.operation == .upsert, !receipts.contains(owner + ":" + intent.requestId) {
                capacityRejection = false
                var body: [String: Any] = ["error": "Limit reached", "code": "TOO_MANY_FAVORITES"]
                if terminalCapacityReceipt { body["details"] = ["requestId": intent.requestId, "mutationOutcome": "rejected"] }
                return (HTTPURLResponse(url: request.url!, statusCode: 413, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: body))
            }
            let replay = !receipts.insert(owner + ":" + intent.requestId).inserted
            if !replay {
                var favorites = values[owner] ?? []
                switch intent.operation {
                case .upsert:
                    let favorite = try XCTUnwrap(intent.favorite)
                    favorites.removeAll { $0.id == favorite.id }; favorites.append(favorite)
                case .remove: favorites.removeAll { $0.id == intent.targetKey }
                case .preferences:
                    notificationValues[owner] = try XCTUnwrap(intent.notifyFavoriteAntennaIssuesPush)
                }
                values[owner] = favorites
            }
            if loseCommittedResponse { loseCommittedResponse = false; throw URLError(.networkConnectionLost) }
            return try response(request, owner: owner, replay: replay)
        }
    }

    private func response(_ request: URLRequest, owner: String, replay: Bool? = nil) throws -> (HTTPURLResponse, Data) {
        struct Payload: Encodable {
            let favorites: [FavoriteAntenna]
            let notifyFavoriteAntennaIssuesPush: Bool
            let revision: String
            let success: Bool?
            let idempotent: Bool?
        }
        let payload = Payload(favorites: values[owner] ?? [], notifyFavoriteAntennaIssuesPush: notificationValues[owner] ?? true,
            revision: "opaque-\(reads)-\(recorded.count)", success: replay == nil ? nil : true, idempotent: replay)
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Cache-Control": "no-store"])!,
            try JSONEncoder.signalQuest.encode(payload))
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
}
