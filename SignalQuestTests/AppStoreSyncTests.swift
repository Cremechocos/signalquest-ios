import XCTest
@testable import SignalQuest

final class AppStoreSyncTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testVerifyEndpointIsCanonical() {
        XCTAssertEqual(AppStoreTransactionSynchronizer.verifyEndpoint, "/api/billing/apple/verify")
    }

    /// Le synchroniseur POST la preuve JWS sur l'endpoint de validation, porte une
    /// clé d'idempotence = transactionId, et mappe la réponse canonique du backend
    /// en `EntitlementSnapshot`.
    func testSynchronizePostsProofAndMapsBackendSnapshot() async throws {
        let client = APIClient(
            config: .test,
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
            session: Self.mockSession()
        )

        var capturedPath: String?
        var capturedMethod: String?
        var capturedIdempotencyKey: String?
        var capturedBody: [String: Any] = [:]

        MockURLProtocol.requestHandler = { request in
            capturedPath = request.url?.path
            capturedMethod = request.httpMethod
            capturedIdempotencyKey = request.value(forHTTPHeaderField: "Idempotency-Key")
            if let body = Self.requestBody(request) {
                capturedBody = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"""
            {
              "tier": "premium",
              "purchases": [{
                "id": "txn-1",
                "provider": "apple_appstore",
                "tier": "premium",
                "status": "active",
                "cancelAtPeriodEnd": false,
                "currentPeriodEnd": "2026-09-10T10:00:00.000Z",
                "expiresAt": "2026-09-10T10:00:00.000Z",
                "startsAt": "2026-08-10T10:00:00.000Z"
              }]
            }
            """#
            return (response, Data(json.utf8))
        }

        let synchronizer = AppStoreTransactionSynchronizer(api: client)
        let proof = AppStoreTransactionProof(
            signedTransaction: "jws.payload.signature",
            productId: SignalQuestSubscriptionProduct.premiumMonthly.rawValue,
            transactionId: "txn-1",
            originalTransactionId: "orig-1"
        )

        let snapshot = try await synchronizer.synchronize(proof)

        XCTAssertEqual(capturedPath, "/api/billing/apple/verify")
        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertEqual(capturedIdempotencyKey, "txn-1", "L'idempotence doit être portée par le transactionId")
        XCTAssertEqual(capturedBody["signedTransaction"] as? String, "jws.payload.signature")
        XCTAssertEqual(capturedBody["productId"] as? String, SignalQuestSubscriptionProduct.premiumMonthly.rawValue)
        XCTAssertEqual(capturedBody["transactionId"] as? String, "txn-1")
        XCTAssertEqual(capturedBody["originalTransactionId"] as? String, "orig-1")

        XCTAssertEqual(snapshot.tier, .premium)
        XCTAssertEqual(snapshot.source, .appStore)
        XCTAssertEqual(snapshot.status, .active)
        XCTAssertNotNil(snapshot.expiresAt)
    }

    /// Un échec serveur (JWS rejeté, 4xx) doit se propager en erreur — jamais
    /// octroyer un droit silencieusement.
    func testSynchronizePropagatesBackendFailure() async {
        let client = APIClient(
            config: .test,
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
            session: Self.mockSession()
        )
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"invalid transaction","code":"APPLE_JWS_INVALID"}"#.utf8))
        }

        let synchronizer = AppStoreTransactionSynchronizer(api: client)
        let proof = AppStoreTransactionProof(
            signedTransaction: "bad",
            productId: SignalQuestSubscriptionProduct.basicMonthly.rawValue,
            transactionId: "txn-2",
            originalTransactionId: "txn-2"
        )

        do {
            _ = try await synchronizer.synchronize(proof)
            XCTFail("Un JWS rejeté doit lever une erreur")
        } catch {
            // Attendu : APIError.http(400, …)
        }
    }

    private static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
