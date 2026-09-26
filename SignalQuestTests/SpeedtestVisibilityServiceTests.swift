import XCTest
@testable import SignalQuest

@MainActor
final class SpeedtestVisibilityServiceTests: XCTestCase {
    private var folders: [URL] = []
    private var previousUserID: String?

    override func setUp() async throws {
        previousUserID = LocalAccountScope.currentUserId
        LocalAccountScope.activate(userId: "visibility-service-tests")
    }

    override func tearDown() async throws {
        MockURLProtocol.requestHandler = nil
        if let previousUserID { LocalAccountScope.activate(userId: previousUserID) }
        else { LocalAccountScope.deactivate() }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
    }

    private func makeService(hasReference: Bool = true, independentReference: Bool = false,
                             invalidatePublicMap: @escaping @Sendable () async -> Void = {}) async throws -> (
        service: SpeedtestService, credentials: CredentialStore,
        session: SpeedtestVisibilitySession, clientID: UUID, fixture: VisibilityHTTPFixture,
        api: APIClient, cache: DiskCache
    ) {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-visibility-token")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: config))
        let folder = "SpeedtestVisibilityServiceTests-\(UUID())"
        let cache = DiskCache(folderName: folder)
        folders.append(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(folder))
        let service = SpeedtestService(api: api, historyCache: cache, pendingCache: cache,
                                      guestReceiptStore: GuestSpeedtestReceiptStore(store: InMemoryTokenStore()),
                                      invalidatePublicMap: invalidatePublicMap)
        let session = try XCTUnwrap(service.visibilitySession)
        let clientID = UUID()
        if hasReference {
            let key = "serverIds-\(LocalAccountScope.storageNamespace(for: session.ownerScopeID))"
            if independentReference {
                try await cache.write("server-measurement", for: "\(key)-\(clientID.uuidString)")
                // An obsolete dictionary cannot override the independent durable mapping.
                try await cache.write([clientID.uuidString: "obsolete-measurement"], for: key)
            } else {
                try await cache.write([clientID.uuidString: "server-measurement"], for: key)
            }
        }
        let fixture = VisibilityHTTPFixture()
        MockURLProtocol.requestHandler = fixture.response
        return (service, credentials, session, clientID, fixture, api, cache)
    }

    func testOwnerGETAndMutationUseAuthenticationAndReadThePersistedState() async throws {
        let context = try await makeService()
        let events = VisibilityEventLog()
        let observer = NotificationCenter.default.addObserver(forName: .sqSpeedtestMapVisibilityChanged, object: nil, queue: nil) { notification in
            if let event = notification.object as? SpeedtestMapVisibilityChange { events.append(event) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let initial = try await context.service.visibility(forClientID: context.clientID, session: context.session)
        XCTAssertEqual(initial?.isOwner, true)
        XCTAssertEqual(initial?.isSharedOnMap, true)
        let hidden = try await context.service.setVisibility(serverID: "server-measurement", visible: false, session: context.session)
        XCTAssertFalse(hidden.isSharedOnMap)
        let persisted = try await context.service.visibility(forClientID: context.clientID, session: context.session)
        XCTAssertEqual(persisted?.isVisibleOnMap, false)
        _ = try await context.service.setVisibility(serverID: "server-measurement", visible: true, session: context.session)
        let published = try await context.service.visibility(forClientID: context.clientID, session: context.session)
        XCTAssertEqual(published?.isSharedOnMap, true)

        let requests = context.fixture.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "PATCH", "GET", "PATCH", "GET"])
        XCTAssertTrue(requests.allSatisfy { $0.cookie == "auth_token=synthetic-visibility-token" })
        XCTAssertTrue(requests.filter { $0.method == "GET" }.allSatisfy { $0.cacheControl == "no-cache" })
        let mutations = requests.filter { $0.method == "PATCH" }
        XCTAssertTrue(mutations.allSatisfy { $0.contentType == "application/json" })
        let bodies = try mutations.map { try JSONSerialization.jsonObject(with: $0.body) as? [String: Bool] }
        XCTAssertEqual(bodies[0]?["isVisibleOnMap"], false)
        XCTAssertEqual(bodies[1]?["isVisibleOnMap"], true)
        XCTAssertEqual(bodies[0], ["isVisibleOnMap": false])
        XCTAssertEqual(bodies[1], ["isVisibleOnMap": true])
        XCTAssertEqual(events.values.count, 2)
        XCTAssertEqual(events.values.map(\.isSharedOnMap), [false, true])
        XCTAssertTrue(events.values.allSatisfy { $0.serverID == "server-measurement" && $0.session == context.session })
    }

    func testMalformedOrFalseSuccessfulMutationDoesNotEmitConfirmedInvalidation() async throws {
        let context = try await makeService()
        let events = VisibilityEventLog()
        let observer = NotificationCenter.default.addObserver(forName: .sqSpeedtestMapVisibilityChanged, object: nil, queue: nil) { notification in
            if let event = notification.object as? SpeedtestMapVisibilityChange { events.append(event) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for mode in [VisibilityHTTPFixture.Mode.falseSuccess, .wrongID, .missingFields, .contradictorySharedState] {
            context.fixture.mode = mode
            do {
                _ = try await context.service.setVisibility(serverID: "server-measurement", visible: false, session: context.session)
                XCTFail("A malformed 2xx response must not confirm a change: \(mode)")
            } catch {}
        }
        XCTAssertTrue(events.values.isEmpty)
    }

    func testMissingOwnerFieldsDoesNotTurnPublicGETIntoOwnerControl() async throws {
        let context = try await makeService()
        context.fixture.mode = .missingOwnership
        do {
            _ = try await context.service.visibility(forClientID: context.clientID, session: context.session)
            XCTFail("Owner controls require an explicit isOwner value")
        } catch {
            XCTAssertEqual(error as? SpeedtestVisibilityError, .unconfirmedResponse)
        }
    }

    func testOldSessionCannotLookUpAnotherAccountsReferenceOrSubmitAMutation() async throws {
        let context = try await makeService()
        LocalAccountScope.activate(userId: "visibility-other-account")
        try context.credentials.setAccessToken("synthetic-other-token")
        do {
            _ = try await context.service.visibility(forClientID: context.clientID, session: context.session)
            XCTFail("Old owner lookup must be rejected")
        } catch {
            XCTAssertEqual(error as? SpeedtestVisibilityError, .sessionChanged)
        }
        do {
            _ = try await context.service.setVisibility(serverID: "server-measurement", visible: false, session: context.session)
            XCTFail("Old owner mutation must be rejected")
        } catch {
            XCTAssertEqual(error as? SpeedtestVisibilityError, .sessionChanged)
        }
        let newSession = try XCTUnwrap(context.service.visibilitySession)
        let unknownForB = try await context.service.visibility(forClientID: context.clientID, session: newSession)
        XCTAssertNil(unknownForB)
        XCTAssertTrue(context.fixture.requests.isEmpty)
    }

    func testMutationWaitsForCacheInvalidationBeforeReturningOrNotifying() async throws {
        let started = expectation(description: "cache invalidation started")
        let gate = VisibilityInvalidationGate(started: started)
        let context = try await makeService(invalidatePublicMap: { await gate.wait() })
        let events = VisibilityEventLog()
        let observer = NotificationCenter.default.addObserver(forName: .sqSpeedtestMapVisibilityChanged, object: nil, queue: nil) { notification in
            if let event = notification.object as? SpeedtestMapVisibilityChange { events.append(event) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var completed = false
        let task = Task {
            let response = try await context.service.setVisibility(serverID: "server-measurement", visible: false, session: context.session)
            completed = true
            return response
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(completed)
        XCTAssertTrue(events.values.isEmpty)
        await gate.resume()
        let response = try await task.value
        XCTAssertFalse(response.isSharedOnMap)
        XCTAssertTrue(completed)
        XCTAssertEqual(events.values.count, 1)
    }

    func testAccountChangeDuringInvalidationDoesNotNotifyTheNextOwner() async throws {
        let started = expectation(description: "cache invalidation started")
        let gate = VisibilityInvalidationGate(started: started)
        let context = try await makeService(invalidatePublicMap: { await gate.wait() })
        let events = VisibilityEventLog()
        let observer = NotificationCenter.default.addObserver(forName: .sqSpeedtestMapVisibilityChanged, object: nil, queue: nil) { notification in
            if let event = notification.object as? SpeedtestMapVisibilityChange { events.append(event) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let task = Task {
            try await context.service.setVisibility(serverID: "server-measurement", visible: false, session: context.session)
        }
        await fulfillment(of: [started], timeout: 2)
        LocalAccountScope.activate(userId: "visibility-other-account")
        try context.credentials.setAccessToken("synthetic-other-token")
        await gate.resume()
        do {
            _ = try await task.value
            XCTFail("Completion belongs to the old session")
        } catch {
            XCTAssertEqual(error as? SpeedtestVisibilityError, .sessionChanged)
        }
        XCTAssertTrue(events.values.isEmpty)
    }

    func testIndependentDurableReferenceWinsOverAnObsoleteDictionary() async throws {
        let context = try await makeService(independentReference: true)
        let visibility = try await context.service.visibility(forClientID: context.clientID, session: context.session)
        XCTAssertEqual(visibility?.id, "server-measurement")
        XCTAssertEqual(context.fixture.requests.map(\.method), ["GET"])
    }

    func testReadingHistoryNeverPublishesOrRewritesTheMeasurement() async throws {
        let context = try await makeService(independentReference: true)
        _ = try await context.service.setVisibility(serverID: "server-measurement", visible: false, session: context.session)
        let beforeReads = context.fixture.requests.count
        for _ in 0..<2 {
            let state = try await context.service.visibility(forClientID: context.clientID, session: context.session)
            XCTAssertEqual(state?.isVisibleOnMap, false)
        }
        XCTAssertEqual(Array(context.fixture.requests.dropFirst(beforeReads)).map(\.method), ["GET", "GET"])
    }

    func testCommittedMutationWithLostResponseIsReconciledByGETAfterServiceRecreation() async throws {
        let context = try await makeService(independentReference: true)
        context.fixture.mode = .commitThenLoseResponse
        do {
            _ = try await context.service.setVisibility(serverID: "server-measurement", visible: false, session: context.session)
            XCTFail("The committed mutation must still report its lost response")
        } catch {}
        context.fixture.mode = .normal
        let events = VisibilityEventLog()
        let invalidations = VisibilityInvalidationCounter()
        let observer = NotificationCenter.default.addObserver(forName: .sqSpeedtestMapVisibilityChanged, object: nil, queue: nil) {
            if let change = $0.object as? SpeedtestMapVisibilityChange { events.append(change) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let recreated = SpeedtestService(api: context.api, historyCache: context.cache, pendingCache: context.cache,
            guestReceiptStore: GuestSpeedtestReceiptStore(store: InMemoryTokenStore()),
            invalidatePublicMap: { await invalidations.increment() })
        let session = try XCTUnwrap(recreated.visibilitySession)
        let beforeReads = context.fixture.requests.count
        let hidden = try await recreated.visibility(forClientID: context.clientID, session: session)
        XCTAssertEqual(hidden?.isVisibleOnMap, false)
        XCTAssertEqual(events.values.map(\.isSharedOnMap), [false])
        XCTAssertEqual(events.values.first?.session, session)
        XCTAssertNil(events.values.first?.mapEpoch, "GET does not invent an epoch")
        _ = try await recreated.visibility(forClientID: context.clientID, session: session)
        let invalidationCount = await invalidations.value
        XCTAssertEqual(invalidationCount, 1, "The cleaned journal does not invalidate every subsequent history read")
        XCTAssertEqual(Array(context.fixture.requests.dropFirst(beforeReads)).map(\.method), ["GET", "GET"])
    }

    func testNormalPrivateHistoryReadWithoutUncertainMutationDoesNotPurgeTheMap() async throws {
        let invalidations = VisibilityInvalidationCounter()
        let context = try await makeService(invalidatePublicMap: { await invalidations.increment() })
        context.fixture.setVisible(false)
        for _ in 0..<2 {
            let state = try await context.service.visibility(forClientID: context.clientID, session: context.session)
            XCTAssertEqual(state?.isVisibleOnMap, false)
        }
        let invalidationCount = await invalidations.value
        XCTAssertEqual(invalidationCount, 0)
        XCTAssertEqual(context.fixture.requests.map(\.method), ["GET", "GET"])
    }

    func testAccountSwitchDuringRecoveryKeepsTheJournalWithoutNotifyingTheNewAccount() async throws {
        let context = try await makeService()
        context.fixture.mode = .commitThenLoseResponse
        do {
            _ = try await context.service.setVisibility(serverID: "server-measurement", visible: false, session: context.session)
            XCTFail("Expected lost response")
        } catch {}
        context.fixture.mode = .normal
        let events = VisibilityEventLog()
        let observer = NotificationCenter.default.addObserver(forName: .sqSpeedtestMapVisibilityChanged, object: nil, queue: nil) {
            if let change = $0.object as? SpeedtestMapVisibilityChange { events.append(change) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let started = expectation(description: "recovery invalidation started")
        let gate = VisibilityInvalidationGate(started: started)
        let recovering = SpeedtestService(api: context.api, historyCache: context.cache, pendingCache: context.cache,
            guestReceiptStore: GuestSpeedtestReceiptStore(store: InMemoryTokenStore()), invalidatePublicMap: { await gate.wait() })
        let recovery = Task { try await recovering.visibility(forClientID: context.clientID, session: context.session) }
        await fulfillment(of: [started], timeout: 2)
        LocalAccountScope.activate(userId: "visibility-other-account")
        try context.credentials.setAccessToken("synthetic-other-token")
        await gate.resume()
        do { _ = try await recovery.value; XCTFail("A's recovery cannot complete as B") }
        catch { XCTAssertEqual(error as? SpeedtestVisibilityError, .sessionChanged) }
        XCTAssertTrue(events.values.isEmpty)
        let bSession = try XCTUnwrap(context.service.visibilitySession)
        let unknownForB = try await context.service.visibility(forClientID: context.clientID, session: bSession)
        XCTAssertNil(unknownForB)
        XCTAssertTrue(events.values.isEmpty)
        LocalAccountScope.activate(userId: "visibility-service-tests")
        try context.credentials.setAccessToken("synthetic-visibility-token")
        let aNewSession = try XCTUnwrap(context.service.visibilitySession)
        let hidden = try await context.service.visibility(forClientID: context.clientID, session: aNewSession)
        XCTAssertEqual(hidden?.isVisibleOnMap, false)
        XCTAssertEqual(events.values.count, 1, "The old cleanup must preserve A's durable recovery marker")
        XCTAssertEqual(events.values.first?.session, aNewSession)
    }

    func testOlderCleanupCannotDeleteOrNotifyOverANewerUncertainIntention() async throws {
        let started = expectation(description: "older invalidation started")
        let gate = VisibilityInvalidationGate(started: started)
        let context = try await makeService(invalidatePublicMap: { await gate.wait() })
        let events = VisibilityEventLog()
        let observer = NotificationCenter.default.addObserver(forName: .sqSpeedtestMapVisibilityChanged, object: nil, queue: nil) {
            if let change = $0.object as? SpeedtestMapVisibilityChange { events.append(change) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let older = Task {
            try await context.service.setVisibility(serverID: "server-measurement", visible: false, session: context.session)
        }
        await fulfillment(of: [started], timeout: 2)
        // A distinct service exercises the shared generation queue, not only one instance's actor.
        let newer = SpeedtestService(api: context.api, historyCache: context.cache, pendingCache: context.cache,
            guestReceiptStore: GuestSpeedtestReceiptStore(store: InMemoryTokenStore()))
        context.fixture.mode = .commitThenLoseResponse
        do {
            _ = try await newer.setVisibility(serverID: "server-measurement", visible: true, session: context.session)
            XCTFail("Expected newer response loss")
        } catch {}
        await gate.resume()
        _ = try await older.value
        XCTAssertTrue(events.values.isEmpty, "An older hidden-state event must not overwrite the newer intention")
        context.fixture.mode = .normal
        let state = try await newer.visibility(forClientID: context.clientID, session: context.session)
        XCTAssertEqual(state?.isVisibleOnMap, true)
        XCTAssertEqual(events.values.map(\.isSharedOnMap), [true], "Newer journal survived older cleanup")
        XCTAssertEqual(context.fixture.requests.last?.method, "GET")
    }

    func testNoServerReferenceMakesNoHTTPRequest() async throws {
        let context = try await makeService(hasReference: false)
        let visibility = try await context.service.visibility(forClientID: context.clientID, session: context.session)
        XCTAssertNil(visibility)
        XCTAssertTrue(context.fixture.requests.isEmpty)
    }
}

private final class VisibilityEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SpeedtestMapVisibilityChange] = []
    var values: [SpeedtestMapVisibilityChange] { lock.withLock { events } }
    func append(_ event: SpeedtestMapVisibilityChange) { lock.withLock { events.append(event) } }
}

/// No XCTest closure or MainActor state is executed on the URLProtocol thread.
private final class VisibilityHTTPFixture: @unchecked Sendable {
    enum Mode { case normal, falseSuccess, wrongID, missingFields, contradictorySharedState, missingOwnership, commitThenLoseResponse }
    struct Request: Sendable {
        let method: String
        let cookie: String?
        let cacheControl: String?
        let contentType: String?
        let body: Data
    }
    private let lock = NSLock()
    private var currentMode = Mode.normal
    private var visible = true
    private var recorded: [Request] = []
    var mode: Mode {
        get { lock.withLock { currentMode } }
        set { lock.withLock { currentMode = newValue } }
    }
    var requests: [Request] { lock.withLock { recorded } }
    func setVisible(_ value: Bool) { lock.withLock { visible = value } }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url, url.path == "/api/speedtests/server-measurement" else { throw URLError(.unsupportedURL) }
        let body = try Self.body(request)
        return try lock.withLock {
            recorded.append(Request(method: request.httpMethod ?? "GET", cookie: request.value(forHTTPHeaderField: "Cookie"),
                                    cacheControl: request.value(forHTTPHeaderField: "Cache-Control"),
                                    contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body))
            var payload: [String: Any]
            if request.httpMethod == "PATCH" {
                let mutation = try JSONSerialization.jsonObject(with: body) as? [String: Bool]
                guard let requested = mutation?["isVisibleOnMap"] else { throw URLError(.cannotParseResponse) }
                if currentMode == .normal || currentMode == .commitThenLoseResponse { visible = requested }
                if currentMode == .commitThenLoseResponse { throw URLError(.networkConnectionLost) }
                payload = ["success": currentMode != .falseSuccess,
                           "id": currentMode == .wrongID ? "wrong-id" : "server-measurement",
                           "isVisibleOnMap": requested, "isPublic": true,
                           "isSharedOnMap": currentMode == .contradictorySharedState ? true : requested,
                           "changed": true, "mapEpoch": 1]
                if currentMode == .missingFields { payload = ["success": true] }
            } else {
                payload = ["id": "server-measurement", "isOwner": true, "isVisibleOnMap": visible,
                           "isPublic": true, "latitude": 48.85, "longitude": 2.35]
                if currentMode == .missingOwnership { payload.removeValue(forKey: "isOwner") }
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Cache-Control": "private, no-store"])!
            return (response, try JSONSerialization.data(withJSONObject: payload))
        }
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}


private actor VisibilityInvalidationGate {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private actor VisibilityInvalidationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
