import Foundation
import XCTest
@testable import SignalQuest

/// Recette opt-in uniquement. Aucune adresse/identité de production et aucun
/// jeton dans les sources ou diagnostics ; chaque test crée ses propres A/B.
struct FavoritesInteropConfiguration: Decodable, Sendable {
    let baseURL: URL
    let controlKey: String
    let database: String

    static func load() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String? { environment[key] ?? environment["TEST_RUNNER_" + key] }
        guard value("SQ_FAVORITES_INTEROP") == "1" else {
            throw XCTSkip("Interop favoris locale non demandée ; définir SQ_FAVORITES_INTEROP=1 avec sa fixture synthétique")
        }
        let data: Data
        if let encoded = value("SQ_FAVORITES_INTEROP_FIXTURE_B64"), let decoded = Data(base64Encoded: encoded) {
            data = decoded
        } else if let path = value("SQ_FAVORITES_INTEROP_FIXTURE_PATH") {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else { throw FavoritesInteropError.invalidFixture }
        guard data.count < 512 * 1024,
              let fixture = try? JSONDecoder().decode(Self.self, from: data),
              fixture.baseURL.scheme == "http", fixture.baseURL.host == "127.0.0.1", fixture.baseURL.port == 4317,
              fixture.baseURL.user == nil, fixture.baseURL.password == nil,
              fixture.baseURL.query == nil, fixture.baseURL.fragment == nil,
              fixture.baseURL.path.isEmpty || fixture.baseURL.path == "/",
              fixture.database == "signalquest_favorites_interop_test", fixture.controlKey.count >= 32 else {
            throw FavoritesInteropError.invalidFixture
        }
        return fixture
    }
}

enum FavoritesInteropError: Error {
    case invalidFixture, invalidSyntheticProfile, invalidResponse, controlFailed(Int), conditionTimedOut
}

struct FavoritesInteropProfile: Decodable, Sendable {
    let userId: String
    let email: String
    let token: String
    func validate() throws {
        guard !userId.isEmpty, email.hasPrefix("favorites-interop-"), email.hasSuffix("@local.test"), !token.isEmpty else {
            throw FavoritesInteropError.invalidSyntheticProfile
        }
    }
}

struct FavoritesInteropScenario: Decodable, Sendable {
    let id: String
    let A: FavoritesInteropProfile
    let B: FavoritesInteropProfile
}

struct FavoritesInteropDatabaseState: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        struct Favorite: Decodable, Sendable { let market: String; let siteId: String }
        struct Receipt: Decodable, Sendable { let requestId: String; let outcome: String }
        struct Preferences: Decodable, Sendable { let notifyFavoriteAntennaIssuesPush: Bool }
        let userId: String
        let favorites: [Favorite]
        let receipts: [Receipt]
        let preferences: Preferences
        var favoriteKeys: Set<String> { Set(favorites.map { FavoriteAntenna.key(siteId: $0.siteId, market: $0.market) }) }
    }
    let state: [Account]
    func account(_ profile: FavoritesInteropProfile) throws -> Account {
        guard let account = state.first(where: { $0.userId == profile.userId }) else { throw FavoritesInteropError.invalidResponse }
        return account
    }
}

struct FavoritesInteropEvents: Decodable {
    struct Event: Decodable {
        let method: String?
        let path: String?
        let mutationId: String?
        let userId: String?
        let status: Int?
        let fault: String?
    }
    let events: [Event]
}

private struct FavoritesInteropAcknowledgement: Decodable {}
private struct FavoritesInteropHealth: Decodable { let ready: Bool; let synthetic: Bool }
private struct FavoritesInteropRelease: Decodable { let released: Bool }

final class FavoritesInteropRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class FavoritesInteropMemoryTokens: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: String] = [:]
    func string(for key: String) throws -> String? { lock.withLock { entries[key] } }
    func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws { lock.withLock { entries[key] = value } }
    func remove(_ key: String) throws { _ = lock.withLock { entries.removeValue(forKey: key) } }
    func keys(withPrefix prefix: String) throws -> [String] { lock.withLock { entries.keys.filter { $0.hasPrefix(prefix) } } }
    func removeAll() throws { lock.withLock { entries.removeAll() } }
}

@MainActor
final class FavoritesInteropClient {
    private final class Owner { var value: LocalAccountSession? }
    private let owner = Owner()
    private let session: URLSession
    let credentials: CredentialStore
    let api: APIClient
    let store: FavoriteAntennasLocalStore
    let service: FavoriteAntennasService

    init(profile: FavoritesInteropProfile, baseURL: URL, directory: URL) throws {
        try profile.validate()
        credentials = CredentialStore(tokenStore: FavoritesInteropMemoryTokens())
        try credentials.setAccessToken(profile.token)
        owner.value = LocalAccountSession(ownerScopeId: "user:" + profile.userId, sessionId: UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: FavoritesInteropRedirectBlocker(), delegateQueue: nil)
        api = APIClient(config: AppConfig(appBaseURL: baseURL, apiBaseURL: baseURL, debugLogsEnabled: false),
                        credentials: credentials, session: session)
        store = FavoriteAntennasLocalStore(directory: directory, environmentID: baseURL.absoluteString)
        service = FavoriteAntennasService(api: api, store: store, sessionSnapshot: { [owner] in owner.value })
    }

    func switchAccount(to profile: FavoritesInteropProfile) throws {
        try profile.validate()
        owner.value = LocalAccountSession(ownerScopeId: "user:" + profile.userId, sessionId: UUID().uuidString)
        try credentials.setAccessToken(profile.token)
        service.resetForAccountChange()
    }

    func close() { session.invalidateAndCancel() }

    func patchNotificationSettings(_ fields: [String: Bool]) async throws {
        _ = try await api.requestData(APIEndpoint(path: "/api/user/notification-preferences", method: .patch,
            headers: ["Content-Type":"application/json"], body: try JSONEncoder.signalQuest.encode(fields)),
            expectedSessionID: credentials.snapshot().sessionID)
    }

    func notificationSettings() async throws -> [String: Bool] {
        try await api.request(APIEndpoint(path: "/api/user/notification-preferences", headers: ["Cache-Control":"no-cache"]),
                              as: [String: Bool].self, expectedSessionID: credentials.snapshot().sessionID)
    }
}

@MainActor
final class FavoritesInteropHarness {
    let configuration: FavoritesInteropConfiguration
    let scenario: FavoritesInteropScenario
    private let controlSession: URLSession
    private let directory: URL
    private var clients: [FavoritesInteropClient] = []
    private var heldRequestIDs: Set<String> = []

    private init(configuration: FavoritesInteropConfiguration, scenario: FavoritesInteropScenario, controlSession: URLSession) {
        self.configuration = configuration
        self.scenario = scenario
        self.controlSession = controlSession
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sq-favorites-interop-\(UUID())", isDirectory: true)
    }

    static func create() async throws -> FavoritesInteropHarness {
        let fixture = try FavoritesInteropConfiguration.load()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: FavoritesInteropRedirectBlocker(), delegateQueue: nil)
        let health: FavoritesInteropHealth = try await control(session: session, fixture: fixture, path: "/__qa/health")
        guard health.ready, health.synthetic else { throw FavoritesInteropError.invalidFixture }
        let scenario: FavoritesInteropScenario = try await control(session: session, fixture: fixture, path: "/__qa/scenarios",
            body: ["label": JSONValue.string("ios-xcode-\(UUID().uuidString.lowercased())")])
        try scenario.A.validate()
        try scenario.B.validate()
        return FavoritesInteropHarness(configuration: fixture, scenario: scenario, controlSession: session)
    }

    static func openExisting(_ scenario: FavoritesInteropScenario) async throws -> FavoritesInteropHarness {
        let fixture = try FavoritesInteropConfiguration.load()
        try scenario.A.validate()
        try scenario.B.validate()
        guard !scenario.id.isEmpty, scenario.A.userId != scenario.B.userId else { throw FavoritesInteropError.invalidFixture }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: FavoritesInteropRedirectBlocker(), delegateQueue: nil)
        let health: FavoritesInteropHealth = try await control(session: session, fixture: fixture, path: "/__qa/health")
        guard health.ready, health.synthetic else { session.invalidateAndCancel(); throw FavoritesInteropError.invalidFixture }
        return FavoritesInteropHarness(configuration: fixture, scenario: scenario, controlSession: session)
    }

    func client(_ profile: FavoritesInteropProfile, directoryName: String) throws -> FavoritesInteropClient {
        let client = try FavoritesInteropClient(profile: profile, baseURL: configuration.baseURL,
            directory: directory.appendingPathComponent(directoryName, isDirectory: true))
        clients.append(client)
        return client
    }

    func reset(capacity: Bool = false) async throws {
        let _: FavoritesInteropAcknowledgement = try await Self.control(session: controlSession, fixture: configuration, path: "/__qa/reset",
            body: ["scenarioId": .string(scenario.id), "capacity": .bool(capacity)])
    }

    func fault(_ mode: String, actor: String = "A") async throws {
        let _: FavoritesInteropAcknowledgement = try await Self.control(session: controlSession, fixture: configuration, path: "/__qa/fault",
            body: ["scenarioId": .string(scenario.id), "actor": .string(actor), "mode": .string(mode)])
    }

    func databaseState() async throws -> FavoritesInteropDatabaseState {
        try await Self.control(session: controlSession, fixture: configuration, path: "/__qa/state", scenarioID: scenario.id)
    }

    func databaseStateJSON() async throws -> JSONValue {
        try await Self.control(session: controlSession, fixture: configuration, path: "/__qa/state", scenarioID: scenario.id)
    }

    func events() async throws -> [FavoritesInteropEvents.Event] {
        let response: FavoritesInteropEvents = try await Self.control(session: controlSession, fixture: configuration, path: "/__qa/events")
        return response.events.filter { $0.userId == scenario.A.userId || $0.userId == scenario.B.userId }
    }

    func waitForHeldMutation() async throws -> String {
        for _ in 0..<100 {
            if let id = try await events().last(where: { $0.fault == "hold_after_commit" })?.mutationId {
                heldRequestIDs.insert(id)
                return id
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw FavoritesInteropError.conditionTimedOut
    }

    func release(_ requestID: String) async throws {
        // L'événement du commit peut être visible juste avant l'installation
        // de la barrière HTTP dans le serveur. Attendre son vrai acquittement.
        for _ in 0..<100 {
            let result: FavoritesInteropRelease = try await Self.control(session: controlSession, fixture: configuration, path: "/__qa/release",
                body: ["requestId": .string(requestID)])
            if result.released {
                heldRequestIDs.remove(requestID)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw FavoritesInteropError.conditionTimedOut
    }

    func cleanUp(resetScenario: Bool = true) async {
        for id in Array(heldRequestIDs) { try? await release(id) }
        clients.forEach { $0.close() }
        if resetScenario { try? await reset() }
        controlSession.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func control<T: Decodable>(session: URLSession, fixture: FavoritesInteropConfiguration,
        path: String, scenarioID: String? = nil, body: [String: JSONValue]? = nil) async throws -> T {
        var components = URLComponents(url: fixture.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if let scenarioID { components.queryItems = [.init(name: "scenarioId", value: scenarioID)] }
        guard let url = components.url else { throw FavoritesInteropError.invalidFixture }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue(fixture.controlKey, forHTTPHeaderField: "X-SQ-QA-Key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw FavoritesInteropError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw FavoritesInteropError.controlFailed(response.statusCode) }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw FavoritesInteropError.invalidResponse }
        return value
    }
}
