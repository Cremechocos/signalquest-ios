import Foundation
import XCTest
@testable import SignalQuest

/// Real URLSession → route handlers → isolated PostgreSQL. No throughput is run.
@MainActor
final class SpeedtestBackendInteropTests: XCTestCase {
    func testExactV6PublicationHideAndExplicitRestorePreserveTraceAndOwner() async throws {
        let h = try await SpeedtestHTTPHarness.create()
        defer { h.close() }
        let result = h.result()
        try await h.service.save(result)
        let serverID = try await h.requireServerID(result)
        let session = try XCTUnwrap(h.service.visibilitySession)
        let published = try await h.service.visibility(forClientID: result.id, session: session)
        XCTAssertEqual(published?.isSharedOnMap, true)
        let original = try await h.row(serverID)
        XCTAssertEqual(original.userId, h.scenario.A.userId)
        XCTAssertEqual(original.latitude, result.coordinate?.latitude)
        XCTAssertEqual(original.longitude, result.coordinate?.longitude)
        XCTAssertEqual(original.methodologyVersion, 6)
        XCTAssertEqual(original.averageSpeed, 100)
        XCTAssertEqual(original.measurementTrace?.payload, result.measurementTrace)

        _ = try await h.service.setVisibility(serverID: serverID, visible: false, session: session)
        let hidden = try await h.service.visibility(forClientID: result.id, session: session)
        XCTAssertEqual(hidden?.isSharedOnMap, false)
        try h.activate(h.scenario.B)
        let bSession = try XCTUnwrap(h.service.visibilitySession)
        let unknown = try await h.service.visibility(forClientID: result.id, session: bSession)
        XCTAssertNil(unknown)
        do {
            _ = try await h.service.setVisibility(serverID: serverID, visible: true, session: bSession)
            XCTFail("The real backend accepted another account's mutation")
        } catch { Self.expectHTTP(error, status: 403) }
        let stillHidden = try await h.row(serverID)
        XCTAssertFalse(stillHidden.isVisibleOnMap)
        try h.activate(h.scenario.A)
        let restored = try await h.service.setVisibility(serverID: serverID, visible: true,
            session: try XCTUnwrap(h.service.visibilitySession))
        XCTAssertTrue(restored.isSharedOnMap)
        let after = try await h.row(serverID)
        XCTAssertEqual(after.measurementTrace, original.measurementTrace)
        XCTAssertEqual(after.userId, original.userId)
        XCTAssertEqual(after.latitude, original.latitude)
        XCTAssertEqual(after.longitude, original.longitude)
    }

    func testPrivateZoneBlocksNewPublicationAndRestoreOnlyForItsOwner() async throws {
        let h = try await SpeedtestHTTPHarness.create()
        defer { h.close() }
        try await h.controlMutation("zone")
        let result = h.result()
        try await h.service.save(result)
        let id = try await h.requireServerID(result)
        let row = try await h.row(id)
        XCTAssertTrue(row.isPublic)
        XCTAssertFalse(row.isVisibleOnMap)
        XCTAssertEqual(row.measurementTrace?.payload, result.measurementTrace)
        let state = try await h.service.visibility(forClientID: result.id,
            session: try XCTUnwrap(h.service.visibilitySession))
        XCTAssertEqual(state?.isSharedOnMap, false)
        do {
            _ = try await h.service.setVisibility(serverID: id, visible: true,
                session: try XCTUnwrap(h.service.visibilitySession))
            XCTFail("Private-zone measurement became visible")
        } catch { Self.expectHTTP(error, status: 409) }
        try h.activate(h.scenario.B)
        let bResult = h.result()
        try await h.service.save(bResult)
        let bID = try await h.requireServerID(bResult)
        let bRow = try await h.row(bID)
        XCTAssertTrue(bRow.isPublic && bRow.isVisibleOnMap)
        XCTAssertEqual(bRow.userId, h.scenario.B.userId)
        let aAfter = try await h.row(id)
        XCTAssertFalse(aAfter.isVisibleOnMap)
    }

    func testRealCommittedPatchWithLostHTTPResponseReconcilesAfterServiceRecreation() async throws {
        let h = try await SpeedtestHTTPHarness.create()
        defer { h.close() }
        let result = h.result()
        try await h.service.save(result)
        let id = try await h.requireServerID(result)
        try await h.controlMutation("fault", extra: ["dropPatch": .bool(true)])
        do {
            _ = try await h.service.setVisibility(serverID: id, visible: false,
                session: try XCTUnwrap(h.service.visibilitySession))
            XCTFail("The dropped HTTP response must remain unconfirmed")
        } catch {
            XCTAssertFalse(error.isCancellation)
        }
        let committed = try await h.row(id)
        XCTAssertFalse(committed.isVisibleOnMap, "Independent SQL read must prove the commit")
        try await h.controlMutation("fault", extra: ["dropPatch": .bool(false)])
        let before = try await h.state().events.filter { $0.method == "PATCH" }.count
        let counter = SpeedtestHTTPInvalidations()
        let recreated = h.recreate { await counter.increment() }
        let current = try XCTUnwrap(recreated.visibilitySession)
        let readback = try await recreated.visibility(forClientID: result.id, session: current)
        XCTAssertEqual(readback?.isSharedOnMap, false)
        _ = try await recreated.visibility(forClientID: result.id, session: current)
        let count = await counter.count
        XCTAssertEqual(count, 1)
        let after = try await h.state()
        XCTAssertEqual(after.events.filter { $0.method == "PATCH" }.count, before)
        XCTAssertTrue(after.events.contains { $0.responseDropped })
        XCTAssertEqual(try XCTUnwrap(after.measurements.first).measurementTrace?.payload, result.measurementTrace)
    }

    private static func expectHTTP(_ error: Error, status: Int) {
        guard case APIError.http(let actual, _, _, _, _) = error else {
            return XCTFail("Expected a scoped HTTP rejection")
        }
        XCTAssertEqual(actual, status)
    }
}

private actor SpeedtestHTTPInvalidations {
    var count = 0
    func increment() { count += 1 }
}

private struct SpeedtestHTTPConfiguration: Decodable {
    let baseURL: URL
    let controlKey: String
    let database: String
    static func load() throws -> Self {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { env[key] ?? env["TEST_RUNNER_" + key] }
        guard value("SQ_SPEEDTEST_INTEROP") == "1" else { throw XCTSkip("Isolated Speedtest HTTP recipe not requested") }
        guard let encoded = value("SQ_SPEEDTEST_INTEROP_FIXTURE_B64"), let data = Data(base64Encoded: encoded),
              data.count < 4096, let config = try? JSONDecoder().decode(Self.self, from: data),
              config.baseURL.absoluteString == "http://127.0.0.1:4321",
              config.database == "sq_speedtest_interop_20260912_test", config.controlKey.count >= 32 else {
            throw SpeedtestHTTPError.invalidFixture
        }
        return config
    }
}
private enum SpeedtestHTTPError: Error { case invalidFixture, invalidResponse, controlFailed(Int) }
private struct SpeedtestHTTPProfile: Decodable {
    let userId: String
    let email: String
    let token: String
}
private struct SpeedtestHTTPScenario: Decodable {
    let id: String
    let A: SpeedtestHTTPProfile
    let B: SpeedtestHTTPProfile
}
private struct SpeedtestHTTPRow: Decodable {
    struct Trace: Decodable, Equatable { let payload: SpeedtestMeasurementTrace }
    let id: String
    let userId: String
    let isPublic: Bool
    let isVisibleOnMap: Bool
    let latitude: Double?
    let longitude: Double?
    let methodologyVersion: Int?
    let averageSpeed: Double
    let measurementTrace: Trace?
}
private struct SpeedtestHTTPState: Decodable {
    struct Event: Decodable { let method: String; let status: Int; let responseDropped: Bool }
    let measurements: [SpeedtestHTTPRow]
    let events: [Event]
}
private struct SpeedtestHTTPAck: Decodable {}

@MainActor
private final class SpeedtestHTTPHarness {
    let scenario: SpeedtestHTTPScenario
    let service: SpeedtestService
    private let config: SpeedtestHTTPConfiguration
    private let session: URLSession
    private let cache: DiskCache
    private let api: APIClient
    private let credentials: CredentialStore
    private let previousOwner: String?

    private init(config: SpeedtestHTTPConfiguration, scenario: SpeedtestHTTPScenario, session: URLSession) throws {
        self.config = config; self.scenario = scenario; self.session = session
        previousOwner = LocalAccountScope.currentUserId
        credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        api = APIClient(config: AppConfig(appBaseURL: config.baseURL, apiBaseURL: config.baseURL, debugLogsEnabled: false),
            credentials: credentials, session: session)
        cache = DiskCache(folderName: "SpeedtestHTTP-\(UUID())", evicts: false)
        service = SpeedtestService(api: api, historyCache: cache, pendingCache: cache,
            guestReceiptStore: GuestSpeedtestReceiptStore(store: InMemoryTokenStore()),
            pendingStore: DiskCacheSpeedtestPendingStore(cache: cache, key: "pending"), vpnIsActive: { false })
        try activate(scenario.A)
    }

    static func create() async throws -> SpeedtestHTTPHarness {
        let config = try SpeedtestHTTPConfiguration.load()
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil; settings.httpShouldSetCookies = false
        settings.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: settings, delegate: FavoritesInteropRedirectBlocker(), delegateQueue: nil)
        let scenario: SpeedtestHTTPScenario = try await control(config, session, "scenarios", body: [:])
        return try Self(config: config, scenario: scenario, session: session)
    }

    func activate(_ profile: SpeedtestHTTPProfile) throws {
        guard profile.email.hasPrefix("speedtest-interop-"), profile.email.hasSuffix("@local.test"),
              !profile.userId.isEmpty, !profile.token.isEmpty else { throw SpeedtestHTTPError.invalidFixture }
        LocalAccountScope.activate(userId: profile.userId)
        try credentials.setAccessToken(profile.token)
    }

    func result() -> SpeedtestRunResult {
        let recorder = SpeedtestTraceRecorder()
        recorder.retain(phase: "download", id: "synthetic-download", start: recorder.origin,
            baseline: recorder.origin, end: recorder.origin + 2, measuredBytes: 25_000_000,
            totalBytes: 25_000_000, source: "client-received",
            samples: [.init(startMs: 0, endMs: 1000, bytes: 12_500_000), .init(startMs: 1000, endMs: 2000, bytes: 12_500_000)])
        return SpeedtestRunResult(id: recorder.runId, label: "Synthetic HTTP interop", downloadMbps: 100,
            downloadAverageMbps: 100, downloadMaxMbps: 100, downloadP90Mbps: 100, downloadP95Mbps: 100,
            durationSeconds: 2, connectionType: .cellular,
            networkOperatorMcc: 208, networkOperatorMnc: 10, observedPlmn: "20810", marketCode: "FR", operatorKey: "SFR",
            coordinate: Coordinates(latitude: 45.1876543, longitude: 5.7245678),
            measurementTrace: recorder.snapshot(), methodologyVersion: 6, ownerScopeId: LocalAccountScope.currentOwnerScopeId)
    }

    func requireServerID(_ result: SpeedtestRunResult) async throws -> String {
        guard let id = await service.serverId(forClientId: result.id) else { throw SpeedtestHTTPError.invalidResponse }
        return id
    }
    func recreate(_ invalidate: @escaping @Sendable () async -> Void) -> SpeedtestService {
        SpeedtestService(api: api, historyCache: cache, pendingCache: cache,
            guestReceiptStore: GuestSpeedtestReceiptStore(store: InMemoryTokenStore()), invalidatePublicMap: invalidate, vpnIsActive: { false })
    }
    func state() async throws -> SpeedtestHTTPState {
        try await Self.control(config, session, "state", scenarioID: scenario.id)
    }
    func row(_ id: String) async throws -> SpeedtestHTTPRow {
        let state = try await state()
        guard let row = state.measurements.first(where: { $0.id == id }) else { throw SpeedtestHTTPError.invalidResponse }
        return row
    }
    func controlMutation(_ name: String, extra: [String: JSONValue] = [:]) async throws {
        var body = extra; body["scenarioId"] = .string(scenario.id)
        let _: SpeedtestHTTPAck = try await Self.control(config, session, name, body: body)
    }
    func close() {
        session.invalidateAndCancel()
        if let previousOwner { LocalAccountScope.activate(userId: previousOwner) } else { LocalAccountScope.deactivate() }
    }
    private static func control<T: Decodable>(_ config: SpeedtestHTTPConfiguration, _ session: URLSession,
        _ name: String, scenarioID: String? = nil, body: [String: JSONValue]? = nil) async throws -> T {
        var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/__qa/" + name
        if let scenarioID { components.queryItems = [.init(name: "scenarioId", value: scenarioID)] }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue(config.controlKey, forHTTPHeaderField: "X-SQ-QA-Key")
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpeedtestHTTPError.invalidResponse }
        guard http.statusCode == 200 else { throw SpeedtestHTTPError.controlFailed(http.statusCode) }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw SpeedtestHTTPError.invalidResponse }
        return value
    }
}
