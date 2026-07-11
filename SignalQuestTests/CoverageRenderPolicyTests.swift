import XCTest
@testable import SignalQuest

/// Vérrouille la politique de rendu de la couche couverture (Lot M1) : rendu piloté
/// par la donnée (points si présents, sinon clusters), caps relevés, seuil de fetch.
final class CoverageRenderPolicyTests: XCTestCase {

    func testRendersPointsWhenPresent() {
        let m = CoverageRenderPolicy.mode(hasPoints: true, hasClusters: false, hasBandFilter: false)
        XCTAssertTrue(m.useRawPoints)
        XCTAssertFalse(m.useClusters)
    }

    func testRendersClustersWhenOnlyClusters() {
        let m = CoverageRenderPolicy.mode(hasPoints: false, hasClusters: true, hasBandFilter: false)
        XCTAssertTrue(m.useClusters)
        XCTAssertFalse(m.useRawPoints)
    }

    func testPointsPreferredOverClusters() {
        // Une tuile contenant les deux : on privilégie les points (vérité détaillée).
        let m = CoverageRenderPolicy.mode(hasPoints: true, hasClusters: true, hasBandFilter: false)
        XCTAssertTrue(m.useRawPoints)
        XCTAssertFalse(m.useClusters)
    }

    func testBandFilterForcesPoints() {
        // Le filtre bande s'applique côté client sur les points bruts → jamais de clusters.
        let m = CoverageRenderPolicy.mode(hasPoints: false, hasClusters: true, hasBandFilter: true)
        XCTAssertTrue(m.useRawPoints)
        XCTAssertFalse(m.useClusters)
    }

    func testEmptyTileRendersNothing() {
        let m = CoverageRenderPolicy.mode(hasPoints: false, hasClusters: false, hasBandFilter: false)
        XCTAssertFalse(m.useRawPoints)
        XCTAssertFalse(m.useClusters)
    }

    func testModesAreMutuallyExclusive() {
        for hasPoints in [true, false] {
            for hasClusters in [true, false] {
                for hasBand in [true, false] {
                    let m = CoverageRenderPolicy.mode(hasPoints: hasPoints, hasClusters: hasClusters, hasBandFilter: hasBand)
                    XCTAssertFalse(m.useClusters && m.useRawPoints,
                                   "clusters et points ne doivent jamais être actifs ensemble")
                }
            }
        }
    }

    func testFetchThresholdIsCityZoom() {
        // Le client demande les points bruts dès le zoom ville (z11).
        XCTAssertEqual(CoverageRenderPolicy.rawPointsFromZoom, 11)
    }

    func testCapsRaisedFromOldDefaults() {
        // Garde-fou anti-régression : les anciens plafonds (900/250/1200) sont relevés.
        XCTAssertGreaterThanOrEqual(CoverageRenderPolicy.pointCapPerTile, 2000)
        XCTAssertGreaterThanOrEqual(CoverageRenderPolicy.fallbackCap, 5000)
    }

    func testRSRPGuardRejectsImpossibleValues() {
        // Un RSRP « 0 » (pas de mesure, ex. couverture iOS sans RSRP) ou > -44 dBm
        // (max théorique 3GPP) → Inconnu, jamais Excellent : sinon un point sans
        // vrai signal s'afficherait en vert vif sur la carte Signal.
        XCTAssertEqual(CoverageQualityBand.band(for: 0), .unknown)
        XCTAssertEqual(CoverageQualityBand.band(for: -20), .unknown)
        XCTAssertEqual(CoverageQualityBand.band(for: nil), .unknown)
        // Les vraies valeurs restent classées normalement.
        XCTAssertEqual(CoverageQualityBand.band(for: -44), .excellent)
        XCTAssertEqual(CoverageQualityBand.band(for: -75), .excellent)
        XCTAssertEqual(CoverageQualityBand.band(for: -95), .fair)
        XCTAssertEqual(CoverageQualityBand.band(for: -120), .poor)
    }
}

/// Verrouille la durabilité et l'identité du lot Drive Test iOS. Ces tests
/// utilisent un fichier temporaire réel pour couvrir le scénario kill/relaunch.
final class CoverageSessionQueueTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testInterruptedRecordingIsRecoveredFromAtomicFile() throws {
        let fileURL = try makeTemporaryQueueURL()
        let sessionId = UUID()
        let firstPoint = makePoint(timestamp: 1_000)
        let secondPoint = makePoint(timestamp: 2_000)
        XCTAssertNotEqual(firstPoint.localId, secondPoint.localId)

        let draft = makeSession(
            id: sessionId,
            startTime: 900,
            endTime: 900,
            showOnMap: false,
            points: [firstPoint, secondPoint]
        )
        try CoverageSessionQueue(fileURL: fileURL).upsert(draft, state: .recording)

        // Nouvelle instance = nouveau lancement du processus, sans état mémoire.
        let relaunchedQueue = CoverageSessionQueue(fileURL: fileURL)
        try relaunchedQueue.recoverInterruptedRecordings()
        let recovered = try XCTUnwrap(relaunchedQueue.allPending().first)

        XCTAssertEqual(recovered.state, .queued)
        XCTAssertEqual(recovered.upload.sessionId, sessionId)
        XCTAssertEqual(recovered.upload.endTime, secondPoint.timestamp)
        XCTAssertEqual(recovered.upload.points.map(\.localId), [firstPoint.localId, secondPoint.localId])
        XCTAssertFalse(recovered.upload.showOnMap, "Le choix privé doit survivre au relaunch")
    }

    func testFailedUploadKeepsQueueAndRetryReusesStableIdentity() async throws {
        let fileURL = try makeTemporaryQueueURL()
        let upload = makeSession(
            id: UUID(),
            startTime: 1_000,
            endTime: 2_000,
            showOnMap: false,
            points: [makePoint(timestamp: 1_000), makePoint(timestamp: 2_000)]
        )
        let service = SessionsService(api: makeAPIClient(), queueFileURL: fileURL)
        try service.finalizeCoverageDraft(upload)

        var firstKey: String?
        var firstBody: Data?
        MockURLProtocol.requestHandler = { request in
            firstKey = request.value(forHTTPHeaderField: "Idempotency-Key")
            firstBody = Self.requestBody(request)
            throw URLError(.notConnectedToInternet)
        }
        await service.retryPendingCoverageSessions()

        XCTAssertEqual(firstKey, upload.idempotencyKey)
        XCTAssertEqual(try CoverageSessionQueue(fileURL: fileURL).allPending().count, 1)

        var retryKey: String?
        var retryBody: Data?
        MockURLProtocol.requestHandler = { request in
            retryKey = request.value(forHTTPHeaderField: "Idempotency-Key")
            retryBody = Self.requestBody(request)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"ok":true}"#.utf8)
            )
        }
        await service.retryPendingCoverageSessions()

        XCTAssertEqual(retryKey, firstKey)
        XCTAssertEqual(try bodySessionId(firstBody), upload.sessionId.uuidString)
        XCTAssertEqual(try bodySessionId(retryBody), upload.sessionId.uuidString)
        XCTAssertEqual(try bodyShowOnMap(retryBody), false)
        XCTAssertTrue(try CoverageSessionQueue(fileURL: fileURL).allPending().isEmpty)
    }

    func testFinalizedSnapshotCannotBeDowngradedByOlderDraft() throws {
        let fileURL = try makeTemporaryQueueURL()
        let id = UUID()
        let points = [makePoint(timestamp: 1_000), makePoint(timestamp: 2_000)]
        let queue = CoverageSessionQueue(fileURL: fileURL)
        let final = makeSession(id: id, startTime: 1_000, endTime: 2_000, showOnMap: true, points: points)
        try queue.upsert(final, state: .queued)

        let stale = makeSession(id: id, startTime: 1_000, endTime: 1_000, showOnMap: true, points: [points[0]])
        try queue.upsert(stale, state: .recording)

        let pending = try XCTUnwrap(queue.allPending().first)
        XCTAssertEqual(pending.state, .queued)
        XCTAssertEqual(pending.upload.points.count, 2)
        XCTAssertEqual(pending.upload.endTime, 2_000)
    }

    private func makePoint(timestamp: Int) -> CoveragePointUpload {
        CoveragePointUpload(
            latitude: 48.8566,
            longitude: 2.3522,
            timestamp: timestamp,
            technology: "5G SA"
        )
    }

    private func makeSession(
        id: UUID,
        startTime: Int,
        endTime: Int,
        showOnMap: Bool,
        points: [CoveragePointUpload]
    ) -> CoverageSessionUpload {
        CoverageSessionUpload(
            sessionId: id,
            startTime: startTime,
            endTime: endTime,
            operatorKey: "SFR",
            marketCode: "FR",
            showOnMap: showOnMap,
            points: points
        )
    }

    private func makeTemporaryQueueURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverageSessionQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("pending.json")
    }

    private func makeAPIClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            config: .test,
            cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()),
            session: URLSession(configuration: configuration)
        )
    }

    private func bodySessionId(_ body: Data?) throws -> String? {
        let data = try XCTUnwrap(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return json["sessionId"] as? String
    }

    private func bodyShowOnMap(_ body: Data?) throws -> Bool? {
        let data = try XCTUnwrap(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return json["showOnMap"] as? Bool
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
