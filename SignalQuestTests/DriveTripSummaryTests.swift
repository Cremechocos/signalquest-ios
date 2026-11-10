import XCTest
@testable import SignalQuest

/// MES-14 : le récap d'un trajet Drive Test part vers « Mes trajets »
/// (`POST /api/coverage/session/drive-summary`, contrat v1 du 05/11).
final class DriveTripSummaryTests: XCTestCase {
    private var suiteName = ""
    private var previousUserId: String?

    override func setUp() {
        super.setUp()
        suiteName = "drive-summary-\(UUID().uuidString)"
        previousUserId = LocalAccountScope.currentUserId
        LocalAccountScope.activate(userId: "drive-summary-user")
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        if let previousUserId { LocalAccountScope.activate(userId: previousUserId) } else { LocalAccountScope.deactivate() }
        super.tearDown()
    }

    private func draft(testIds: [UUID] = [], tests: Int = 2, endedAt: Date = Date(timeIntervalSince1970: 1_793_000_000),
                       market: String? = "FR", operatorKey: String? = "orange") -> DriveTripSummaryDraft {
        DriveTripSummaryDraft(
            clientTripId: "ios-drive-0f3a9c2e-1b2c-4d5e-8f90-a1b2c3d4e5f6",
            ownerScopeId: LocalAccountScope.currentOwnerScopeId,
            startedAt: endedAt.addingTimeInterval(-2_384.5), endedAt: endedAt,
            distanceMeters: 18_450.4, testCount: tests, bytesUsed: 412_000_000,
            stoppedByDataCap: false, vpnActive: false,
            downloadAvgMbps: tests > 0 ? 182.4 : nil, downloadMaxMbps: tests > 0 ? 401 : nil,
            marketCode: market, operatorKey: operatorKey, speedtestClientIds: testIds,
            deviceModel: "iPhone16,2", osVersion: "27.0", appVersion: "1.0 (185)"
        )
    }

    func testBodyFollowsTheContract() throws {
        let body = draft().body(serverSpeedtestIds: ["st_1"])
        let data = try JSONSerialization.data(withJSONObject: body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["clientTripId"] as? String, "ios-drive-0f3a9c2e-1b2c-4d5e-8f90-a1b2c3d4e5f6")
        XCTAssertEqual(json["endedAt"] as? String, "2026-10-26T07:33:20.000Z", "UTC « Z », millisecondes")
        XCTAssertEqual(json["startedAt"] as? String, "2026-10-26T06:53:35.500Z")
        XCTAssertEqual(json["distanceMeters"] as? Int, 18_450)
        XCTAssertEqual(json["testCount"] as? Int, 2)
        XCTAssertEqual(json["bytesUsed"] as? Int, 412_000_000)
        XCTAssertEqual(json["downloadAvgMbps"] as? Double, 182.4)
        XCTAssertEqual(json["speedtestIds"] as? [String], ["st_1"])
        XCTAssertEqual(json["operator"] as? [String: String], ["marketCode": "FR", "operatorKey": "orange"])
        XCTAssertEqual(json["deviceModel"] as? String, "iPhone16,2")
        XCTAssertNil(json["ownerScopeId"], "Rien de local ne part")
        XCTAssertNil(json["speedtestClientIds"])

        let empty = try JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: draft(tests: 0, market: nil, operatorKey: nil).body(serverSpeedtestIds: []))
        ) as? [String: Any]
        XCTAssertTrue(empty?["downloadAvgMbps"] is NSNull, "Sans test, débit null")
        XCTAssertTrue(empty?["downloadMaxMbps"] is NSNull)
        XCTAssertNil(empty?["operator"], "Réseau inconnu : omis")
    }

    func testTripNetworkIsSentOnlyWhenEveryTestSawTheSameOne() {
        XCTAssertEqual(DriveTestViewModel.tripNetwork(["FR|orange", "FR|orange"])?.operatorKey, "orange")
        XCTAssertNil(DriveTestViewModel.tripNetwork(["FR|orange", "FR|sfr"]), "Deux réseaux : on n'en choisit pas un")
        XCTAssertNil(DriveTestViewModel.tripNetwork(["FR|orange", nil]), "Un test sans réseau connu")
        XCTAssertNil(DriveTestViewModel.tripNetwork([]))
    }

    func testFlushSendsResolvedIdsAndResendsWhenMoreTestsGetTheirId() async throws {
        let first = UUID(), second = UUID()
        let ids = IdMap([first: "st_1"])
        let api = SummaryAPI()
        let service = DriveTripSummaryService(api: api, serverId: { await ids.id(for: $0) }, defaults: UserDefaults(suiteName: suiteName)!,
                                              now: { Date(timeIntervalSince1970: 1_793_000_600) })
        await service.enqueue(draft(testIds: [first, second]))
        await service.flush()
        var sent = await api.sentIds()
        XCTAssertEqual(sent, [["st_1"]])
        let kept = await service.queued()
        XCTAssertEqual(kept.count, 1, "Un test attend encore son id : le récap reste")

        await service.flush()
        sent = await api.sentIds()
        XCTAssertEqual(sent.count, 1, "Rien de neuf : pas de renvoi")

        await ids.set(second, "st_2")
        await service.flush()
        sent = await api.sentIds()
        XCTAssertEqual(sent.last, ["st_1", "st_2"])
        let remaining = await service.queued()
        XCTAssertTrue(remaining.isEmpty, "Tous les tests liés : le récap quitte la file")
    }

    func testTransientFailureKeepsTheTripAndRefusalDropsIt() async {
        let api = SummaryAPI()
        let service = DriveTripSummaryService(api: api, serverId: { _ in nil }, defaults: UserDefaults(suiteName: suiteName)!,
                                              now: { Date(timeIntervalSince1970: 1_793_000_600) })
        await service.enqueue(draft())
        await api.fail(with: .transport("offline"))
        await service.flush()
        var queued = await service.queued()
        XCTAssertEqual(queued.count, 1)

        await api.fail(with: .http(status: 400, code: "DRIVE_SUMMARY_INVALID", message: "", requestId: nil, retryAfter: nil))
        await service.flush()
        queued = await service.queued()
        XCTAssertTrue(queued.isEmpty, "Un 400 ne passera jamais : abandonné")
    }

    func testOldTripsAndGuestsAreNotSent() async {
        let api = SummaryAPI()
        let late = DriveTripSummaryService(api: api, serverId: { _ in nil }, defaults: UserDefaults(suiteName: suiteName)!,
                                           now: { Date(timeIntervalSince1970: 1_793_000_000 + 8 * 86_400) })
        await late.enqueue(draft())
        await late.flush()
        var sent = await api.sentIds()
        XCTAssertTrue(sent.isEmpty)
        let afterAge = await late.queued()
        XCTAssertTrue(afterAge.isEmpty, "Au-delà de 7 jours, le récap est oublié")

        LocalAccountScope.deactivate()
        let guest = DriveTripSummaryService(api: api, serverId: { _ in nil }, defaults: UserDefaults(suiteName: suiteName)!)
        await guest.enqueue(draft())
        await guest.flush()
        sent = await api.sentIds()
        XCTAssertTrue(sent.isEmpty, "Sans compte, la route répondrait 401")
    }

    func testSessionListReadsTheDriveSummary() throws {
        let json = #"""
        {"id":"ios-drive-1","source":"drive_test","totalPoints":0,"distance":18.45,"duration":2384,
         "driveSummary":{"testCount":7,"bytesUsed":412000000,"stoppedByDataCap":false,"vpnActive":false,
                         "downloadAvgMbps":182.4,"downloadMaxMbps":401}}
        """#
        let session = try JSONDecoder.signalQuest.decode(CoverageSession.self, from: Data(json.utf8))
        XCTAssertTrue(session.isSummaryOnly)
        XCTAssertEqual(session.driveSummary?.testCount, 7)
        XCTAssertEqual(session.driveSummary?.downloadMaxMbps, 401)

        let android = try JSONDecoder.signalQuest.decode(
            CoverageSession.self, from: Data(#"{"id":"a","source":"drive_test","totalPoints":240,"driveSummary":null}"#.utf8)
        )
        XCTAssertFalse(android.isSummaryOnly)
        XCTAssertNil(android.driveSummary)
    }
}

private actor IdMap {
    private var ids: [UUID: String]
    init(_ ids: [UUID: String]) { self.ids = ids }
    func id(for clientId: UUID) -> String? { ids[clientId] }
    func set(_ clientId: UUID, _ id: String) { ids[clientId] = id }
}

private actor SummaryRecorder {
    var sentIds: [[String]] = []
    var failure: APIError?
    func record(_ ids: [String]) { sentIds.append(ids) }
    func setFailure(_ error: APIError?) { failure = error }
}

private final class SummaryAPI: APIClientProtocol, @unchecked Sendable {
    private let recorder = SummaryRecorder()

    func fail(with error: APIError?) async { await recorder.setFailure(error) }
    func sentIds() async -> [[String]] { await recorder.sentIds }

    func request<T: Decodable>(_ endpoint: APIEndpoint, as type: T.Type) async throws -> T {
        XCTAssertEqual(endpoint.path, "/api/coverage/session/drive-summary")
        XCTAssertEqual(endpoint.method, .post)
        if let failure = await recorder.failure { throw failure }
        let body = try XCTUnwrap(endpoint.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        await recorder.record(body["speedtestIds"] as? [String] ?? [])
        let response = #"{"sessionId":"ios-drive-1","created":true,"linkedSpeedtests":1,"ignoredSpeedtests":0}"#
        return try JSONDecoder.signalQuest.decode(T.self, from: Data(response.utf8))
    }
    func request(_ endpoint: APIEndpoint) async throws {}
    func uploadMultipart<T: Decodable>(
        path: String, fields: [String: String], fileField: String,
        fileName: String, mimeType: String, data: Data, as type: T.Type
    ) async throws -> T {
        throw APIError.cancelled
    }
}
