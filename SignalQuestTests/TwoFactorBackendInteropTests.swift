import Foundation
import XCTest
@testable import SignalQuest

/// Opt-in native URLSession → actual route handlers → isolated PostgreSQL.
@MainActor
final class TwoFactorBackendInteropTests: XCTestCase {
    func testEnrollmentConfirmationAccountChangeAndDisableAgainstRealBackend() async throws {
        let h = try await TwoFactorHTTPHarness.create()
        defer { h.close() }
        let operation = try h.operation()
        let setup = try await operation.setup()
        XCTAssertNotNil(setup.expiresAt)
        let code = try await h.code(setup.secret)
        try await operation.confirm(secret: setup.secret, code: code)
        let profile = try await operation.profile()
        XCTAssertEqual(profile.twoFactorEnabled, true)
        let active = try await h.state()
        XCTAssertEqual(active.users.first(where: { $0.id == h.scenario.A.userId })?.enabled, true)
        XCTAssertEqual(active.users.first(where: { $0.id == h.scenario.A.userId })?.pending, false)
        try h.activate(h.scenario.B)
        do { try await operation.disable(code: code); XCTFail("Stale operation accepted") } catch {}
        let unchanged = try await h.state()
        XCTAssertEqual(unchanged.events.count, active.events.count, "No request under the next account")
        let b = try await h.operation().profile()
        XCTAssertEqual(b.twoFactorEnabled, false)
        try h.activate(h.scenario.A)
        try await h.operation().disable(code: try await h.code(setup.secret))
        let after = try await h.state()
        XCTAssertTrue(after.users.allSatisfy { !$0.enabled && !$0.hasSecret && !$0.pending })
        let disabled = try await h.operation().profile()
        XCTAssertEqual(disabled.twoFactorEnabled, false)
    }

    func testReplacedExpiredAndMalformedSetupCannotActivateAccount() async throws {
        let h = try await TwoFactorHTTPHarness.create()
        defer { h.close() }
        let operation = try h.operation()
        let first = try await operation.setup()
        let replacement = try await operation.setup()
        do {
            try await operation.confirm(secret: first.secret, code: try await h.code(first.secret))
            XCTFail("Replaced enrollment accepted")
        } catch { XCTAssertEqual(error as? TwoFactorEnrollmentError, .replacedSetup) }
        try await h.mutate("expire")
        do {
            try await operation.confirm(secret: replacement.secret, code: try await h.code(replacement.secret))
            XCTFail("Expired enrollment accepted")
        } catch { XCTAssertEqual(error as? TwoFactorEnrollmentError, .expiredSetup) }
        let before = try await h.state()
        do { try await operation.confirm(secret: replacement.secret, code: "123"); XCTFail("Malformed code") } catch {}
        let after = try await h.state()
        XCTAssertEqual(after.events.count, before.events.count)
        XCTAssertTrue(after.users.allSatisfy { !$0.enabled && !$0.hasSecret })
    }

    func testCommittedActivationWithLostReplyIsNotReplayedAndProfileRecoversTruth() async throws {
        let h = try await TwoFactorHTTPHarness.create()
        defer { h.close() }
        let operation = try h.operation()
        let setup = try await operation.setup()
        try await h.mutate("drop", extra: ["enabled": .bool(true)])
        do {
            try await operation.confirm(secret: setup.secret, code: try await h.code(setup.secret))
            XCTFail("Lost response was acknowledged")
        } catch {}
        let state = try await h.state()
        XCTAssertEqual(state.events.filter { $0.path == "/api/auth/2fa/verify-setup" }.count, 1)
        XCTAssertEqual(state.users.first(where: { $0.id == h.scenario.A.userId })?.enabled, true)
        XCTAssertEqual(state.users.first(where: { $0.id == h.scenario.A.userId })?.pending, false)
        let actual = try await operation.profile()
        XCTAssertEqual(actual.twoFactorEnabled, true)
    }
}

private enum TwoFactorHTTPError: Error { case invalidFixture, invalidResponse }
private struct TwoFactorHTTPConfig: Decodable { let baseURL: URL; let controlKey: String; let database: String }
private struct TwoFactorHTTPActor: Decodable { let userId: String; let email: String; let token: String }
private struct TwoFactorHTTPScenario: Decodable { let id: String; let A: TwoFactorHTTPActor; let B: TwoFactorHTTPActor }
private struct TwoFactorHTTPState: Decodable {
    struct User: Decodable { let id: String; let enabled: Bool; let hasSecret: Bool; let pending: Bool }
    struct Event: Decodable { let path: String; let status: Int }
    let users: [User]; let events: [Event]
}
private struct TwoFactorHTTPAck: Decodable {}

@MainActor
private final class TwoFactorHTTPHarness {
    let scenario: TwoFactorHTTPScenario
    let config: TwoFactorHTTPConfig
    let session: URLSession
    let credentials: CredentialStore
    let api: APIClient
    let previousOwner: String?

    private init(config: TwoFactorHTTPConfig, scenario: TwoFactorHTTPScenario, session: URLSession) throws {
        self.config = config; self.scenario = scenario; self.session = session
        previousOwner = LocalAccountScope.currentUserId
        credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        api = APIClient(config: AppConfig(appBaseURL: config.baseURL, apiBaseURL: config.baseURL, debugLogsEnabled: false),
            credentials: credentials, session: session)
        try activate(scenario.A)
    }

    static func create() async throws -> TwoFactorHTTPHarness {
        let env = ProcessInfo.processInfo.environment
        guard env["SQ_TWO_FACTOR_INTEROP"] == "1" else { throw XCTSkip("Requires isolated 2FA HTTP/PostgreSQL fixture") }
        guard let encoded = env["SQ_TWO_FACTOR_INTEROP_FIXTURE_B64"], let data = Data(base64Encoded: encoded),
              let config = try? JSONDecoder().decode(TwoFactorHTTPConfig.self, from: data),
              config.baseURL.absoluteString == "http://127.0.0.1:4321",
              config.database == "sq_speedtest_interop_20260912_test", config.controlKey.count == 64 else {
            throw TwoFactorHTTPError.invalidFixture
        }
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil; settings.httpShouldSetCookies = false
        settings.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: settings, delegate: FavoritesInteropRedirectBlocker(), delegateQueue: nil)
        let scenario: TwoFactorHTTPScenario = try await control(config, session, "scenarios", body: [:])
        return try Self(config: config, scenario: scenario, session: session)
    }

    func activate(_ actor: TwoFactorHTTPActor) throws {
        guard actor.email.hasPrefix("twofactor-interop-"), actor.email.hasSuffix("@local.test") else {
            throw TwoFactorHTTPError.invalidFixture
        }
        LocalAccountScope.activate(userId: actor.userId)
        try credentials.setAccessToken(actor.token)
    }
    func operation() throws -> TwoFactorEnrollmentService {
        guard let id = LocalAccountScope.currentUserId,
              let operation = TwoFactorEnrollmentService(api: api, userID: id) else { throw TwoFactorHTTPError.invalidFixture }
        return operation
    }
    func code(_ secret: String) async throws -> String {
        struct Code: Decodable { let code: String }
        let value: Code = try await Self.control(config, session, "code", body: ["scenarioId": .string(scenario.id), "secret": .string(secret)])
        return value.code
    }
    func state() async throws -> TwoFactorHTTPState {
        try await Self.control(config, session, "state", scenarioID: scenario.id)
    }
    func mutate(_ name: String, extra: [String: JSONValue] = [:]) async throws {
        var body = extra; body["scenarioId"] = .string(scenario.id)
        let _: TwoFactorHTTPAck = try await Self.control(config, session, name, body: body)
    }
    func close() {
        session.invalidateAndCancel()
        if let previousOwner { LocalAccountScope.activate(userId: previousOwner) } else { LocalAccountScope.deactivate() }
    }
    private static func control<T: Decodable>(_ config: TwoFactorHTTPConfig, _ session: URLSession,
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
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try? JSONDecoder().decode(T.self, from: data) else { throw TwoFactorHTTPError.invalidResponse }
        return value
    }
}
