import XCTest
@testable import SignalQuest

/// Le registre des marchés ne fait jamais attendre le réseau : la carte choisit
/// son pays avec lui avant son premier chargement (TRX-18). Le réseau rafraîchit
/// en arrière-plan et son résultat est mis en cache pour le lancement suivant.
final class MarketRegistryLoadingTests: XCTestCase {
    private var folder = ""

    override func setUp() {
        super.setUp()
        folder = "MarketRegistryLoadingTests-\(UUID())"
        RegistryURLProtocol.reset()
    }

    override func tearDown() {
        RegistryURLProtocol.reset()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: root.appendingPathComponent(folder))
        super.tearDown()
    }

    func testFirstCallServesTheBundledRegistryWithoutWaitingForASlowNetwork() async {
        RegistryURLProtocol.delay = 5
        let service = makeService()
        let started = Date()
        let payload = await service.registry()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Le premier appel ne doit pas attendre le réseau")
        XCTAssertNotNil(payload.market(forCode: "FR"))
    }

    func testBackgroundRefreshIsServedNextAndCachedForTheNextLaunch() async throws {
        let marker = "2099-01-01T00:00:00Z"
        RegistryURLProtocol.body = try bundledRegistry(generatedAt: marker)
        let service = makeService()
        var payload = await service.registry()
        for _ in 0..<50 where payload.generatedAt != marker {
            try await Task.sleep(nanoseconds: 100_000_000)
            payload = await service.registry()
        }
        XCTAssertEqual(payload.generatedAt, marker)
        XCTAssertEqual(RegistryURLProtocol.requestCount, 1)

        // Lancement suivant : le cache disque récent sert tout de suite, sans réseau.
        RegistryURLProtocol.body = nil
        let cached = await makeService().registry()
        XCTAssertEqual(cached.generatedAt, marker)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(RegistryURLProtocol.requestCount, 1, "Un cache récent ne relance pas le réseau")
    }

    private func makeService() -> MarketRegistryService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RegistryURLProtocol.self]
        let api = APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                            session: URLSession(configuration: config))
        return MarketRegistryService(api: api, cache: DiskCache(folderName: folder))
    }

    private func bundledRegistry(generatedAt: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "market_registry_fallback", withExtension: "json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["generatedAt"] = generatedAt
        return try JSONSerialization.data(withJSONObject: json)
    }
}

/// Répond `body` (200) ou une erreur serveur non rejouée (500), après `delay`.
private final class RegistryURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: Data?
    nonisolated(unsafe) static var delay: TimeInterval = 0
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        body = nil
        delay = 0
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let body = Self.body
        let respond: @Sendable () -> Void = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 500 : 200,
                                           httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}
}
