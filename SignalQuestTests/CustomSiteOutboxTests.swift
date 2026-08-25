import Foundation
import XCTest
@testable import SignalQuest

final class CustomSiteOutboxTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testEncryptedOutboxSurvivesRestartAndIsolatesAccounts() async throws {
        let root = temporaryRoot()
        let keys = InMemoryTokenStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let firstStore = CustomSiteOutboxStore(rootURL: root, keyStore: keys)
        let staged = try await firstStore.stage(userId: "alice@example.test", draft: fixture())

        let encryptedFile = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first(where: { $0.lastPathComponent == "pending.json.enc" })
        )
        let encryptedBytes = try Data(contentsOf: encryptedFile)
        XCTAssertFalse(String(decoding: encryptedBytes, as: UTF8.self).contains("Toronto roaming node"))
        XCTAssertFalse(String(decoding: encryptedBytes, as: UTF8.self).contains("alice"))

        // Nouvelle instance = nouveau processus logique, même fichier et même Keychain.
        let relaunchedStore = CustomSiteOutboxStore(rootURL: root, keyStore: keys)
        let alicePending = try await relaunchedStore.pending(userId: "alice@example.test")
        let bobPending = try await relaunchedStore.pending(userId: "bob@example.test")
        XCTAssertEqual(alicePending, [staged])
        XCTAssertTrue(bobPending.isEmpty)
    }

    func testStagingSameDraftKeepsOneStableRequest() async throws {
        let root = temporaryRoot()
        let store = CustomSiteOutboxStore(rootURL: root, keyStore: InMemoryTokenStore())
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let first = try await store.stage(userId: "owner", draft: fixture())
        let replay = try await store.stage(userId: "owner", draft: fixture())

        XCTAssertEqual(first.requestId, replay.requestId)
        let pending = try await store.pending(userId: "owner")
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(first.requestId.hasPrefix("site:"))
        XCTAssertFalse(first.ownerScopeId.contains("owner"))
    }

    func testTransientFailureQueuesThenReplayUsesSameBodyRequestId() async throws {
        let root = temporaryRoot()
        let store = CustomSiteOutboxStore(rootURL: root, keyStore: InMemoryTokenStore())
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("test-token")
        let client = APIClient(config: .test, credentials: credentials, session: mockSession())
        let capture = RequestCapture()
        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(request.httpBodyData)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            capture.append(
                bodyRequestId: try XCTUnwrap(json["clientRequestId"] as? String),
                headerRequestId: try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key"))
            )
            let status = capture.count <= 2 ? 503 : 200
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = status == 200
                ? Data(#"{"site":{"id":"site-server-1","slug":"toronto"}}"#.utf8)
                : Data(#"{"error":"temporarily unavailable"}"#.utf8)
            return (response, data)
        }

        let service = CustomSitesService(
            api: client,
            currentUserId: { "owner@example.test" },
            outbox: store
        )
        let firstResult = try await service.create(fixture())
        XCTAssertTrue(firstResult.isPending)
        let queued = try await store.pending(userId: "owner@example.test")
        XCTAssertEqual(queued.count, 1)

        await service.retryPending()

        let afterReplay = try await store.pending(userId: "owner@example.test")
        XCTAssertTrue(afterReplay.isEmpty)
        XCTAssertEqual(capture.count, 3)
        XCTAssertEqual(Set(capture.bodyRequestIds).count, 1)
        XCTAssertEqual(capture.bodyRequestIds, capture.headerRequestIds)
    }

    func testRetryPolicyKeepsOnlyUncertainFailures() {
        XCTAssertTrue(CustomSiteOutboxRetryPolicy.isRetryable(APIError.transport("offline")))
        XCTAssertTrue(CustomSiteOutboxRetryPolicy.isRetryable(APIError.decoding("lost acknowledgement")))
        XCTAssertTrue(CustomSiteOutboxRetryPolicy.isRetryable(
            APIError.http(status: 503, code: nil, message: "", requestId: nil, retryAfter: nil)
        ))
        XCTAssertFalse(CustomSiteOutboxRetryPolicy.isRetryable(
            APIError.http(status: 409, code: nil, message: "", requestId: nil, retryAfter: nil)
        ))
        XCTAssertFalse(CustomSiteOutboxRetryPolicy.isRetryable(APIError.missingAuthToken))
    }

    private func fixture() -> CustomSiteDraft {
        CustomSiteDraft(
            latitude: 43.6532,
            longitude: -79.3832,
            name: "Toronto roaming node",
            type: "PYLONE",
            description: "Foreign NSA observation",
            infraOwnerOperator: "ROGERS_CA",
            hostedOperators: ["ROGERS_CA"],
            operatorRadios: [
                CustomSiteOperatorRadio(
                    operator: "ROGERS_CA",
                    enb: "12197",
                    gnb: nil,
                    cellId: "3112966",
                    pci: 0,
                    tac: "1234",
                    earfcn: 1_300,
                    nrarfcn: 636_666,
                    band: 78,
                    mcc: 302,
                    mnc: 720,
                    technology: "NR_NSA"
                )
            ]
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CustomSiteOutboxTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(body: String, header: String)] = []

    func append(bodyRequestId: String, headerRequestId: String) {
        lock.lock()
        defer { lock.unlock() }
        requests.append((bodyRequestId, headerRequestId))
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var bodyRequestIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map(\.body)
    }

    var headerRequestIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map(\.header)
    }
}

private extension URLRequest {
    var httpBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
