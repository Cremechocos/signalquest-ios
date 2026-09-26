import Foundation
import XCTest
@testable import SignalQuest

/// Opt-in HTTP/PostgreSQL regression tests. APIClient and CredentialStore are
/// the application's real implementations; only the loopback server injects
/// bounded response barriers. No production account or URL is accepted.
@MainActor
final class TransportBackendInteropTests: XCTestCase {
    func test401FromAccountACannotRefreshOrWriteForAccountB() async throws {
        try await rejectedResponseCannotCrossAccounts(.hold401)
    }

    func test503FromAccountACannotRetryOrWriteForAccountB() async throws {
        try await rejectedResponseCannotCrossAccounts(.hold503)
    }

    func testLateRealRefreshCannotInstallAccountACookieOrReplayAsAccountB() async throws {
        try await scenario { harness, client in
            let mutation = TransportMutation(siteId: "A-LATE-REFRESH")
            try await harness.arm(.holdRefresh, mutation: mutation)
            let pending = Task { try await client.mutate(mutation) }
            defer { pending.cancel() }
            let barrier = try await harness.waitForBarrier(kind: "refresh")

            // The real refresh handler has created A's managed session, but its
            // actual Set-Cookie has not reached the native client yet.
            let before = try await harness.state()
            XCTAssertEqual(try before.account(harness.scenario.A).sessionCount, 1)
            XCTAssertEqual(try before.account(harness.scenario.B).sessionCount, 0)
            try client.switchAccount(to: harness.scenario.B)
            try await harness.release(barrier)
            await assertCancelled(pending)
            XCTAssertTrue(client.hasToken(of: harness.scenario.B), "A late cookie must not replace B")

            let events = try await harness.events()
            let writes = events.filter { $0.path == TransportClient.mutationPath }
            XCTAssertEqual(writes.count, 1)
            XCTAssertEqual(writes.first?.status, 401)
            XCTAssertEqual(writes.first?.actor, "A")
            let refreshes = events.filter { $0.path == "/api/auth/refresh" }
            XCTAssertEqual(refreshes.count, 1)
            XCTAssertEqual(refreshes.first?.actor, "A")
            XCTAssertEqual(refreshes.first?.status, 200)
            XCTAssertEqual(refreshes.first?.source, "handler")
            XCTAssertTrue(refreshes.first?.cookieIssued == true)
            try await assertEmptyMutations(harness)
            try await assertNewBOperationWorks(harness, client: client, forbidden: mutation)
        }
    }

    func testSuccessfulRefreshKeepsTheMutationAndReceiptOwnedByAccountA() async throws {
        try await scenario { harness, client in
            let mutation = TransportMutation(siteId: "A-POSITIVE-REFRESH")
            try await harness.arm(.refreshOnce, mutation: mutation)
            let response = try await client.mutate(mutation)
            XCTAssertTrue(response.success)
            XCTAssertFalse(response.idempotent)
            XCTAssertFalse(client.hasToken(of: harness.scenario.A), "The real refresh must issue a managed-session cookie")
            let currentID = try await client.currentUserID()
            XCTAssertEqual(currentID, harness.scenario.A.userId)

            let events = try await harness.events()
            let writes = events.filter { $0.path == TransportClient.mutationPath }
            XCTAssertEqual(writes.map(\.status), [401, 200])
            XCTAssertEqual(writes.map(\.actor), ["A", "A"])
            XCTAssertTrue(writes.allSatisfy { $0.mutationId == mutation.requestId })
            XCTAssertTrue(writes.allSatisfy { $0.idempotencyKey == mutation.requestId })
            let refreshes = events.filter { $0.path == "/api/auth/refresh" }
            XCTAssertEqual(refreshes.count, 1)
            XCTAssertTrue(refreshes.first?.cookieIssued == true)
            let state = try await harness.state()
            let accountA = try state.account(harness.scenario.A)
            let accountB = try state.account(harness.scenario.B)
            XCTAssertEqual(accountA.favoriteKeys, [mutation.favorite.key])
            XCTAssertEqual(accountA.receipts.map(\.requestId), [mutation.requestId])
            XCTAssertTrue(accountA.receipts.allSatisfy { $0.outcome == "applied" })
            XCTAssertEqual(accountA.sessionCount, 1)
            XCTAssertTrue(accountB.favorites.isEmpty && accountB.receipts.isEmpty)
            XCTAssertEqual(accountB.sessionCount, 0)
            XCTAssertFalse(state.barrierTimedOut)

            // A second explicit delivery of the same logical mutation finds its
            // real SQL receipt, rather than creating another row.
            let replay = try await client.mutate(mutation)
            XCTAssertTrue(replay.success && replay.idempotent)
            let replayed = try await harness.state().account(harness.scenario.A)
            XCTAssertEqual(replayed.receipts.map(\.requestId), [mutation.requestId])
            try client.switchAccount(to: harness.scenario.B)
            try await assertNewBOperationWorks(harness, client: client, forbidden: mutation)
        }
    }

    private func rejectedResponseCannotCrossAccounts(_ mode: TransportFaultMode) async throws {
        try await scenario { harness, client in
            let mutation = TransportMutation(siteId: "A-REJECTED-\(mode.rawValue.uppercased())")
            try await harness.arm(mode, mutation: mutation)
            let pending = Task { try await client.mutate(mutation) }
            defer { pending.cancel() }
            let barrier = try await harness.waitForBarrier(kind: "rejection")
            try client.switchAccount(to: harness.scenario.B)
            try await harness.release(barrier)
            await assertCancelled(pending)
            XCTAssertTrue(client.hasToken(of: harness.scenario.B))
            let events = try await harness.events()
            XCTAssertEqual(events.count, 1, "A rejected operation must not refresh or replay under B")
            XCTAssertEqual(events.first?.path, TransportClient.mutationPath)
            XCTAssertEqual(events.first?.actor, "A")
            XCTAssertEqual(events.first?.status, mode == .hold401 ? 401 : 503)
            XCTAssertEqual(events.first?.source, "injected")
            try await assertEmptyMutations(harness)
            try await assertNewBOperationWorks(harness, client: client, forbidden: mutation)
        }
    }

    private func assertCancelled(_ pending: Task<TransportMutationResponse, Error>) async {
        do {
            _ = try await pending.value
            XCTFail("The operation belonging to A unexpectedly succeeded after switching to B")
        } catch APIError.cancelled {
            // Expected terminal outcome; do not print credentials or response bodies.
        } catch {
            XCTFail("Expected the native session cancellation, not a transport/harness failure")
        }
    }

    private func assertEmptyMutations(_ harness: TransportHarness) async throws {
        let state = try await harness.state()
        for profile in [harness.scenario.A, harness.scenario.B] {
            let account = try state.account(profile)
            XCTAssertTrue(account.favorites.isEmpty && account.receipts.isEmpty)
        }
        XCTAssertFalse(state.barrierTimedOut)
    }

    private func assertNewBOperationWorks(
        _ harness: TransportHarness, client: TransportClient, forbidden: TransportMutation
    ) async throws {
        let accountID = try await client.currentUserID()
        XCTAssertEqual(accountID, harness.scenario.B.userId)
        let explicitB = TransportMutation(siteId: "B-EXPLICIT")
        let response = try await client.mutate(explicitB)
        XCTAssertTrue(response.success && !response.idempotent)
        let state = try await harness.state()
        let accountB = try state.account(harness.scenario.B)
        XCTAssertEqual(accountB.favoriteKeys, [explicitB.favorite.key])
        XCTAssertEqual(accountB.receipts.map(\.requestId), [explicitB.requestId])
        XCTAssertFalse(accountB.receipts.contains { $0.requestId == forbidden.requestId })
        XCTAssertTrue(accountB.receipts.allSatisfy { $0.outcome == "applied" })
        XCTAssertFalse(state.barrierTimedOut)
        let events = try await harness.events()
        XCTAssertFalse(events.contains { $0.actor == "B" && $0.mutationId == forbidden.requestId })
        XCTAssertTrue(events.contains { $0.actor == "B" && $0.mutationId == explicitB.requestId && $0.status == 200 })
    }

    private func scenario(_ body: (TransportHarness, TransportClient) async throws -> Void) async throws {
        let harness = try await TransportHarness.create()
        let client = try TransportClient(profile: harness.scenario.A, baseURL: harness.configuration.baseURL)
        do {
            try await body(harness, client)
            client.close()
            try await harness.close()
        } catch {
            client.close()
            try? await harness.close()
            throw error
        }
    }
}

private enum TransportInteropFailure: Error {
    case invalidFixture, invalidProfile, invalidResponse, controlRejected, barrierTimeout
}

private enum TransportFaultMode: String, Encodable, Sendable {
    case hold401 = "hold_401"
    case hold503 = "hold_503"
    case holdRefresh = "hold_refresh"
    case refreshOnce = "refresh_once"
}

private struct TransportConfiguration: Decodable, Sendable {
    let schemaVersion: Int
    let baseURL: URL
    let database: String
    let controlKey: String
    let serverRunID: String

    static func load() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { environment[key] ?? environment["TEST_RUNNER_" + key] }
        guard value("SQ_TRANSPORT_INTEROP") == "1" else {
            throw XCTSkip("Local HTTP/PostgreSQL transport recipe is not enabled")
        }
        guard let path = value("SQ_TRANSPORT_INTEROP_FIXTURE_PATH") else { throw TransportInteropFailure.invalidFixture }
        let bytes: Data
        do { bytes = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw TransportInteropFailure.invalidFixture }
        guard bytes.count < 32 * 1024,
              let config = try? JSONDecoder().decode(Self.self, from: bytes),
              config.schemaVersion == 1, config.database == "sq_transport_interop_test",
              config.baseURL.scheme == "http", config.baseURL.host == "127.0.0.1", config.baseURL.port == 4319,
              config.baseURL.user == nil, config.baseURL.password == nil,
              config.baseURL.query == nil, config.baseURL.fragment == nil,
              config.baseURL.path.isEmpty || config.baseURL.path == "/",
              config.controlKey.count >= 32, UUID(uuidString: config.serverRunID) != nil else {
            throw TransportInteropFailure.invalidFixture
        }
        return config
    }
}

private struct TransportProfile: Decodable, Sendable {
    let userId: String
    let email: String
    let token: String

    func validate() throws {
        guard !userId.isEmpty, email.hasPrefix("transport-interop-"), email.hasSuffix("@local.test"),
              !token.isEmpty else { throw TransportInteropFailure.invalidProfile }
    }
}

private struct TransportScenario: Decodable, Sendable {
    let id: String
    let serverRunID: String
    let A: TransportProfile
    let B: TransportProfile
}

private struct TransportMutation: Encodable, Sendable {
    struct Favorite: Encodable, Sendable {
        let siteId: String
        let market = "FR"
        var key: String { "\(market):\(siteId)" }
    }
    let requestId = UUID().uuidString.lowercased()
    let operation = "upsert"
    let favorite: Favorite
    init(siteId: String) { favorite = Favorite(siteId: siteId) }
}

private struct TransportMutationResponse: Decodable, Sendable {
    let success: Bool
    let idempotent: Bool
}

private struct TransportDatabaseState: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        struct Favorite: Decodable, Sendable { let market: String; let siteId: String }
        struct Receipt: Decodable, Sendable { let requestId: String; let outcome: String }
        let userId: String
        let favorites: [Favorite]
        let receipts: [Receipt]
        let sessionCount: Int
        var favoriteKeys: Set<String> { Set(favorites.map { "\($0.market):\($0.siteId)" }) }
    }
    let accounts: [Account]
    let barrierTimedOut: Bool
    func account(_ profile: TransportProfile) throws -> Account {
        guard let account = accounts.first(where: { $0.userId == profile.userId }) else {
            throw TransportInteropFailure.invalidResponse
        }
        return account
    }
}

private struct TransportEvent: Decodable, Sendable {
    let path: String
    let actor: String
    let status: Int
    let mutationId: String?
    let idempotencyKey: String?
    let cookieIssued: Bool
    let source: String
}

private struct TransportBarrier: Decodable, Sendable { let id: String; let kind: String }
private struct TransportAcknowledgement: Decodable {}
private struct TransportControlBody: Encodable {
    var scenarioId: String?
    var label: String?
    var mode: TransportFaultMode?
    var mutationId: String?
    var barrierId: String?
}

private final class TransportRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class TransportTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: String] = [:]
    func string(for key: String) throws -> String? { lock.withLock { entries[key] } }
    func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws { lock.withLock { entries[key] = value } }
    func remove(_ key: String) throws { _ = lock.withLock { entries.removeValue(forKey: key) } }
    func keys(withPrefix prefix: String) throws -> [String] { lock.withLock { entries.keys.filter { $0.hasPrefix(prefix) } } }
    func removeAll() throws { lock.withLock { entries.removeAll() } }
}

private func transportURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    return URLSession(configuration: configuration, delegate: TransportRedirectBlocker(), delegateQueue: nil)
}

@MainActor
private final class TransportClient {
    static let mutationPath = "/api/android/favorite-antennas"
    private let session: URLSession
    private let credentials: CredentialStore
    private let api: APIClient

    init(profile: TransportProfile, baseURL: URL) throws {
        try profile.validate()
        credentials = CredentialStore(tokenStore: TransportTokenStore())
        try credentials.setAccessToken(profile.token)
        session = transportURLSession()
        api = APIClient(config: AppConfig(appBaseURL: baseURL, apiBaseURL: baseURL, debugLogsEnabled: false),
                        credentials: credentials, session: session)
    }

    func switchAccount(to profile: TransportProfile) throws {
        try profile.validate()
        try credentials.setAccessToken(profile.token)
    }
    func hasToken(of profile: TransportProfile) -> Bool { credentials.accessToken() == profile.token }
    func close() { session.invalidateAndCancel() }
    func mutate(_ mutation: TransportMutation) async throws -> TransportMutationResponse {
        try await api.requestJSON(Self.mutationPath, method: .patch, body: mutation, idempotencyKey: mutation.requestId)
    }
    func currentUserID() async throws -> String {
        struct Response: Decodable { struct User: Decodable { let id: String }; let user: User? }
        let result: Response = try await api.request(APIEndpoint(path: "/api/auth/me"), as: Response.self)
        guard let user = result.user else { throw TransportInteropFailure.invalidResponse }
        return user.id
    }
}

@MainActor
private final class TransportHarness {
    let configuration: TransportConfiguration
    let scenario: TransportScenario
    private let session: URLSession

    private init(configuration: TransportConfiguration, scenario: TransportScenario, session: URLSession) {
        self.configuration = configuration
        self.scenario = scenario
        self.session = session
    }

    static func create() async throws -> TransportHarness {
        let configuration = try TransportConfiguration.load() // Gate before creating any network task.
        let session = transportURLSession()
        do {
            struct Health: Decodable { let ready: Bool; let synthetic: Bool; let serverRunID: String }
            let health: Health = try await request(session, configuration, path: "/__qa/health")
            guard health.ready, health.synthetic, health.serverRunID == configuration.serverRunID else {
                throw TransportInteropFailure.invalidFixture
            }
            let scenario: TransportScenario = try await request(session, configuration, path: "/__qa/scenarios",
                body: TransportControlBody(label: "ios-transport-\(UUID().uuidString.lowercased())"))
            try scenario.A.validate()
            try scenario.B.validate()
            guard UUID(uuidString: scenario.id) != nil, scenario.A.userId != scenario.B.userId,
                  scenario.serverRunID == configuration.serverRunID else { throw TransportInteropFailure.invalidProfile }
            return TransportHarness(configuration: configuration, scenario: scenario, session: session)
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    func arm(_ mode: TransportFaultMode, mutation: TransportMutation) async throws {
        let _: TransportAcknowledgement = try await Self.request(session, configuration, path: "/__qa/fault",
            body: TransportControlBody(scenarioId: scenario.id, mode: mode, mutationId: mutation.requestId))
    }
    func state() async throws -> TransportDatabaseState {
        try await Self.request(session, configuration, path: "/__qa/state", scenarioId: scenario.id)
    }
    func events() async throws -> [TransportEvent] {
        struct Response: Decodable { let events: [TransportEvent] }
        let response: Response = try await Self.request(session, configuration, path: "/__qa/events", scenarioId: scenario.id)
        return response.events
    }
    func waitForBarrier(kind: String) async throws -> TransportBarrier {
        struct Response: Decodable { let barriers: [TransportBarrier] }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            let response: Response = try await Self.request(session, configuration, path: "/__qa/barriers", scenarioId: scenario.id)
            if let barrier = response.barriers.first(where: { $0.kind == kind }) { return barrier }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TransportInteropFailure.barrierTimeout
    }
    func release(_ barrier: TransportBarrier) async throws {
        struct Response: Decodable { let released: Bool }
        let response: Response = try await Self.request(session, configuration, path: "/__qa/release",
            body: TransportControlBody(scenarioId: scenario.id, barrierId: barrier.id))
        guard response.released else { throw TransportInteropFailure.controlRejected }
    }
    func close() async throws {
        defer { session.invalidateAndCancel() }
        // Only releases this test's barriers. Rows remain as synthetic evidence.
        let _: TransportAcknowledgement = try await Self.request(session, configuration, path: "/__qa/close",
            body: TransportControlBody(scenarioId: scenario.id))
    }

    private static func request<T: Decodable>(
        _ session: URLSession, _ configuration: TransportConfiguration, path: String,
        scenarioId: String? = nil, body: TransportControlBody? = nil
    ) async throws -> T {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw TransportInteropFailure.invalidFixture
        }
        components.path = path
        if let scenarioId { components.queryItems = [URLQueryItem(name: "scenarioId", value: scenarioId)] }
        guard let url = components.url else { throw TransportInteropFailure.invalidFixture }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue(configuration.controlKey, forHTTPHeaderField: "X-SQ-QA-Key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count < 1024 * 1024 else {
            throw TransportInteropFailure.controlRejected
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw TransportInteropFailure.invalidResponse }
        return value
    }
}
