import XCTest
@testable import SignalQuest

@MainActor
final class SpeedtestPublicationDefaultsTests: XCTestCase {
    private struct Fixture {
        let service: SpeedtestService
        let store: DiskCacheSpeedtestPendingStore
        let cache: DiskCache
        let credentials: CredentialStore
        let session: URLSession
        let recorder: PublicationRequestRecorder

        func recreatedService() -> SpeedtestService {
            SpeedtestService(api: APIClient(config: .test, credentials: credentials, session: session),
                historyCache: cache, pendingCache: cache,
                guestReceiptStore: GuestSpeedtestReceiptStore(store: InMemoryTokenStore()), pendingStore: store, vpnIsActive: { false })
        }
    }

    private func fixture(user: String? = nil, vpn: Bool = false) throws -> Fixture {
        let previous = LocalAccountScope.currentUserId
        if let user { LocalAccountScope.activate(userId: user) } else { LocalAccountScope.deactivate() }
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        if let user { try credentials.setAccessToken(token(user: user)) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let cache = DiskCache(folderName: "PublicationDefaults-\(UUID())", evicts: false)
        let store = DiskCacheSpeedtestPendingStore(cache: cache, key: "pending")
        let recorder = PublicationRequestRecorder()
        MockURLProtocol.requestHandler = recorder.respond
        let service = SpeedtestService(api: APIClient(config: .test, credentials: credentials, session: session),
            historyCache: cache, pendingCache: cache,
            guestReceiptStore: GuestSpeedtestReceiptStore(store: InMemoryTokenStore()), pendingStore: store, vpnIsActive: { vpn })
        addTeardownBlock {
            session.invalidateAndCancel()
            MockURLProtocol.requestHandler = nil
            if let previous { LocalAccountScope.activate(userId: previous) } else { LocalAccountScope.deactivate() }
            await cache.removeAll(withPrefix: "")
        }
        return Fixture(service: service, store: store, cache: cache, credentials: credentials,
                       session: session, recorder: recorder)
    }

    private func token(user: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["userId": user, "exp": Int(Date().timeIntervalSince1970) + 3600])
        let body = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(body).signature"
    }

    private func result(coordinate: Coordinates? = Coordinates(latitude: 45.1876543, longitude: 5.7245678)) -> SpeedtestRunResult {
        SpeedtestRunResult(label: "Synthetic publication", downloadMbps: 100, downloadAverageMbps: 100,
            downloadMaxMbps: 110, durationSeconds: 10, connectionType: .cellular,
            coordinate: coordinate, methodologyVersion: 6, ownerScopeId: LocalAccountScope.currentOwnerScopeId)
    }

    private func requireQueuedFailure(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("The controlled HTTP failure must leave the save queued") }
        catch { guard case APIError.http(status: 500, _, _, _, _) = error else { return XCTFail("Unexpected error: \(error)") } }
    }

    func testNewGuestSaveRequestsPublicationAndExactCoordinatesByDefault() async throws {
        let f = try fixture()
        let value = result()
        await requireQueuedFailure { try await f.service.save(value) }
        let pending = await f.store.loadAll()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.isVisibleOnMap, true)
        XCTAssertEqual(pending.first?.shareExactLocation, true)
        XCTAssertEqual(pending.first?.ownerScopeId, "guest")
        let body = try f.recorder.lastBody()
        XCTAssertEqual(body["isVisibleOnMap"] as? Bool, true)
        XCTAssertEqual(body["shareExactLocation"] as? Bool, true)
        let point = try XCTUnwrap(body["coordinates"] as? [String: Double])
        XCTAssertEqual(point["latitude"], value.coordinate?.latitude)
        XCTAssertEqual(point["longitude"], value.coordinate?.longitude)
    }

    func testNewAccountSaveWithStreamsRequestsPublicationByDefault() async throws {
        let f = try fixture(user: "publication-owner-a")
        await requireQueuedFailure { try await f.service.save(result(), streams: 7) }
        let body = try f.recorder.lastBody()
        XCTAssertEqual(body["isVisibleOnMap"] as? Bool, true)
        XCTAssertEqual(body["shareExactLocation"] as? Bool, true)
        XCTAssertEqual(body["streams"] as? Int, 7)
        let pending = await f.store.loadAll()
        XCTAssertEqual(pending.first?.ownerScopeId, "user:publication-owner-a")
    }

    func testLegacyPrivateQueueKeepsItsChoiceAfterServiceRecreation() async throws {
        let f = try fixture()
        for oldChoice: Bool? in [nil, false] {
            let value = result()
            let pending = PendingSpeedtestSave(id: value.id.uuidString, result: value, streams: 4,
                deviceModel: "Synthetic", createdAt: Date(), isVisibleOnMap: oldChoice,
                shareExactLocation: oldChoice, guestDeleteToken: nil, driveSessionId: nil, ownerScopeId: "guest")
            try await f.store.upsert(pending)
            let baseline = await f.store.loadAll().first { $0.id == pending.id }
            let recreated = f.recreatedService()
            await requireQueuedFailure { try await recreated.save(value, streams: 8) }
            let body = try f.recorder.lastBody()
            XCTAssertEqual(body["isVisibleOnMap"] as? Bool, false)
            XCTAssertEqual(body["shareExactLocation"] as? Bool, false)
            XCTAssertEqual(body["streams"] as? Int, 4, "A retry must preserve the recorded measurement settings")
            let retained = await f.store.loadAll().first { $0.id == pending.id }
            XCTAssertEqual(retained, baseline)
        }
    }

    func testExplicitPrivateSaveDoesNotBecomePublicOnDefaultRetry() async throws {
        let f = try fixture()
        let value = result()
        await requireQueuedFailure { try await f.service.save(value, streams: 4, publishToMap: false, shareExactLocation: false) }
        await requireQueuedFailure { try await f.recreatedService().save(value) }
        let body = try f.recorder.lastBody()
        XCTAssertEqual(body["isVisibleOnMap"] as? Bool, false)
        XCTAssertEqual(body["shareExactLocation"] as? Bool, false)
    }

    func testVPNBlocksNewPublicationEvenWhenTheCallerRequestsIt() async throws {
        let f = try fixture(vpn: true)
        await requireQueuedFailure { try await f.service.save(result(), streams: 4, publishToMap: true, shareExactLocation: true) }
        let body = try f.recorder.lastBody()
        XCTAssertEqual(body["isVisibleOnMap"] as? Bool, false)
        XCTAssertEqual(body["shareExactLocation"] as? Bool, false)
    }

    func testResultFromPreviousAccountNeverReachesPublicationTransport() async throws {
        let f = try fixture(user: "publication-owner-a")
        let value = result()
        LocalAccountScope.activate(userId: "publication-owner-b")
        try f.credentials.setAccessToken(token(user: "publication-owner-b"))
        do { try await f.service.save(value); XCTFail("A result crossed accounts") }
        catch { XCTAssertTrue(error.isCancellation) }
        XCTAssertEqual(f.recorder.count, 0)
        let pending = await f.store.loadAll()
        XCTAssertTrue(pending.isEmpty)
    }

    func testMissingPositionIsNotInventedByAutomaticPublication() async throws {
        let f = try fixture()
        await requireQueuedFailure { try await f.service.save(result(coordinate: nil)) }
        let body = try f.recorder.lastBody()
        XCTAssertNil(body["coordinates"])
    }
}

private final class PublicationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Data] = []
    var count: Int { lock.withLock { requests.count } }
    func lastBody() throws -> [String: Any] {
        let data = try XCTUnwrap(lock.withLock { requests.last })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func respond(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        guard url.path == "/api/speedtests" else { throw URLError(.unsupportedURL) }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        lock.withLock { requests.append(data) }
        return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("{\"error\":\"synthetic-unavailable\"}".utf8))
    }
}
