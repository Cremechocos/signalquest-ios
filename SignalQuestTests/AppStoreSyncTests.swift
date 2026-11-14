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
            productId: SignalQuestSubscriptionProduct.premiumAnnual.rawValue,
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

    /// C2 : une preuve refusée répondait 401, que le client lisait comme une
    /// session expirée (rafraîchissement, nouvel essai, puis déconnexion de
    /// l'acheteur). La route ne déclenche plus aucun rafraîchissement : un seul
    /// appel part, et l'erreur remonte telle quelle à l'`EntitlementsStore`, qui
    /// garde la transaction ouverte.
    func testVerifyRefusalNeverTriggersASessionRefresh() async {
        let client = APIClient(
            config: .test,
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
            session: Self.mockSession()
        )
        let paths = LockedPaths()
        MockURLProtocol.requestHandler = { request in
            paths.append(request.url?.path ?? "")
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"Transaction refusée","code":"APPLE_VERIFY_FAILED"}"#.utf8))
        }

        let synchronizer = AppStoreTransactionSynchronizer(api: client)
        let proof = AppStoreTransactionProof(
            signedTransaction: "jws", productId: SignalQuestSubscriptionProduct.premiumMonthly.rawValue,
            transactionId: "txn-401", originalTransactionId: "txn-401"
        )
        do {
            _ = try await synchronizer.synchronize(proof)
            XCTFail("Un refus doit lever une erreur")
        } catch APIError.http(let status, let code, _, _, _) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(code, "APPLE_VERIFY_FAILED")
            XCTAssertEqual(AppStoreDeliveryFailure(APIError.http(status: status, code: code, message: "", requestId: nil, retryAfter: nil)),
                           .keepForRetry)
        } catch {
            XCTFail("Erreur inattendue : \(error)")
        }
        XCTAssertEqual(paths.values, ["/api/billing/apple/verify"], "Aucun rafraîchissement de session ne doit partir")
    }

    /// Dès le lot 1b de Backend, `/verify` sert la charge §3 en plus de l'ancienne
    /// forme : le snapshot la lit.
    func testSynchronizeReadsTheContractPayload() async throws {
        let client = APIClient(
            config: .test,
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
            session: Self.mockSession()
        )
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"""
            {
              "version": 1,
              "tier": "premium",
              "purchases": [{ "id": "p1", "provider": "app_store", "tier": "premium", "status": "active",
                              "cancelAtPeriodEnd": false, "currentPeriodEnd": "2026-12-21T10:00:00Z",
                              "expiresAt": null, "startsAt": null }],
              "subscription": { "channel": "app_store", "state": "trialing", "tier": "premium", "period": "year",
                                "autoRenew": true, "currentPeriodEnd": "2026-12-21T10:00:00Z",
                                "trialEndsAt": "2026-11-21T10:00:00Z", "environment": "sandbox" },
              "trial": { "eligible": false, "days": 7 },
              "purchaseAccountToken": "0b6f8f62-5a0e-4c62-9d36-8a4f1f4a7c11"
            }
            """#
            return (response, Data(json.utf8))
        }

        let snapshot = try await AppStoreTransactionSynchronizer(api: client).synchronize(AppStoreTransactionProof(
            signedTransaction: "jws", productId: SignalQuestSubscriptionProduct.premiumAnnual.rawValue,
            transactionId: "txn-3", originalTransactionId: "txn-3"
        ))
        XCTAssertEqual(snapshot.tier, .premium)
        XCTAssertEqual(snapshot.source, .appStore)
        XCTAssertEqual(snapshot.period, .annual)
        XCTAssertEqual(snapshot.subscription?.state, .trialing)
        XCTAssertEqual(snapshot.subscription?.isSandbox, true)
        XCTAssertNotNil(snapshot.subscription?.trialEndsAt)
        XCTAssertNotNil(snapshot.purchaseAccountToken)
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

/// Chemins reçus par `MockURLProtocol`, appelé hors du fil du test.
private final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ path: String) { lock.withLock { stored.append(path) } }
    var values: [String] { lock.withLock { stored } }
}
