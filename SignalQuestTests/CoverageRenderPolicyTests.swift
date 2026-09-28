import XCTest
@testable import SignalQuest

/// Vérrouille la politique de rendu de la couche couverture (Lot M1) : rendu piloté
/// par la donnée (points si présents, sinon clusters), caps relevés, seuil de fetch.
final class CoverageRenderPolicyTests: XCTestCase {

    func testVerifiedBandOverviewRemainsRenderableAtRegionalZoom() throws {
        let bytes = Data(#"{"tile":{"z":8,"x":130,"y":87},"points":[],"clusters":[{"id":"lte-band7","lat":50.5,"lng":4.4,"count":4,"avgRsrp":-90,"tech":"4G"}],"stats":{"sampleCount":4,"representation":"overview","appliedBandFilter":{"version":1,"bands":[7],"match":"any"}}}"#.utf8)
        let tile = try JSONDecoder.signalQuest.decode(AndroidCoverageTileResponse.self, from: bytes)
        let mode = CoverageRenderPolicy.mode(for: tile, selectedBands: [7])
        let visibleIDs = mode.useClusters ? tile.clusters.map(\.id) : []
        // L'identifiant serveur (« lte-band7 », répété dans chaque tuile) est préfixé par sa tuile.
        XCTAssertEqual(visibleIDs, ["8/130/87:lte-band7"], "A verified overview must not disappear when its band is selected")
    }

    func testAggregatedPointKeepsItsSecondaryBandAndExcludesAnAbsentBand() throws {
        let bytes = Data(#"{"id":"aggregate","lat":48.8,"lng":2.3,"band":3,"bands":[3,7],"tech":"4G"}"#.utf8)
        let point = try JSONDecoder.signalQuest.decode(AndroidCoveragePoint.self, from: bytes)
        XCTAssertTrue(CoverageRenderPolicy.matches(point, selectedBands: [7]))
        XCTAssertFalse(CoverageRenderPolicy.matches(point, selectedBands: [17]))
        let legacy = try JSONDecoder.signalQuest.decode(AndroidCoveragePoint.self,
            from: Data(#"{"id":"legacy","lat":48.8,"lng":2.3,"band":7}"#.utf8))
        XCTAssertTrue(CoverageRenderPolicy.matches(legacy, selectedBands: [7]))
    }

    func testCoverageImportResponseDecodesLegacyMinimalShape() throws {
        let response = try JSONDecoder.signalQuest.decode(
            CoverageImportResponse.self,
            from: Data(#"{"ok":true}"#.utf8)
        )
        XCTAssertTrue(response.ok)
        XCTAssertNil(response.plmnResolved)
        XCTAssertNil(response.mvnoKey)
    }

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

/// Le préflight Drive Test est une interface d'exception : les contrôles sains
/// restent exécutés mais ne produisent aucune ligne visible.
final class DriveTestPreflightPolicyTests: XCTestCase {
    func testNominalSessionStartsWithoutVisiblePreflight() {
        let report = DriveTestPreflightPolicy.evaluate(snapshot())

        XCTAssertTrue(report.isReady)
        XCTAssertFalse(report.isBlocked)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testHealthyPermissionsStorageAndBatteryNeverAppear() {
        let report = DriveTestPreflightPolicy.evaluate(
            snapshot(connection: .wifi)
        )

        XCTAssertEqual(report.issues.map(\.id), [.wifi])
        XCTAssertFalse(report.issues.contains { $0.id == .locationPermission })
        XCTAssertFalse(report.issues.contains { $0.id == .storage })
        XCTAssertFalse(report.issues.contains { $0.id == .battery })
    }

    func testUnknownBatteryAndStorageDoNotBecomeFalseFailures() {
        let report = DriveTestPreflightPolicy.evaluate(
            snapshot(availableStorageBytes: nil, batteryPercent: nil)
        )

        XCTAssertTrue(report.isReady)
    }

    func testDeniedLocationAndInsufficientStorageBlockStart() {
        let report = DriveTestPreflightPolicy.evaluate(
            snapshot(
                locationAuthorization: .denied,
                availableStorageBytes: 80_000_000
            )
        )

        XCTAssertTrue(report.isBlocked)
        XCTAssertEqual(report.issues.map(\.id), [.locationPermission, .storage])
        XCTAssertEqual(report.issues.first?.action, .openSettings)
    }

    func testUndeterminedLocationRequestsPermissionInsteadOfStarting() {
        let report = DriveTestPreflightPolicy.evaluate(
            snapshot(locationAuthorization: .notDetermined)
        )

        XCTAssertTrue(report.isBlocked)
        XCTAssertEqual(report.issues.map(\.id), [.locationPermission])
        XCTAssertEqual(report.issues.first?.action, .requestLocation)
    }

    func testLowBatteryIsWarningNotBlocker() {
        let report = DriveTestPreflightPolicy.evaluate(
            snapshot(batteryPercent: 9)
        )

        XCTAssertEqual(report.issues.map(\.id), [.battery])
        XCTAssertFalse(report.isBlocked)
    }

    func testOfflineDriveTestBlocksWithoutCoverageFallback() {
        let report = DriveTestPreflightPolicy.evaluate(snapshot(isOnline: false))

        XCTAssertEqual(report.issues.first?.id, .connectivity)
        XCTAssertTrue(report.isBlocked)
    }

    func testMissingOrStaleGpsFixWarnsWithoutInventingASimProblem() {
        let report = DriveTestPreflightPolicy.evaluate(
            snapshot(locationAgeSeconds: nil, horizontalAccuracyMeters: nil)
        )

        XCTAssertEqual(report.issues.map(\.id), [.gpsFix])
        XCTAssertFalse(report.isBlocked)
    }

    private func snapshot(
        locationAuthorization: DriveTestPreflightSnapshot.LocationAuthorization = .authorized,
        locationAgeSeconds: TimeInterval? = 2,
        horizontalAccuracyMeters: Double? = 12,
        availableStorageBytes: Int64? = 500_000_000,
        batteryPercent: Int? = 80,
        isCharging: Bool = false,
        isOnline: Bool = true,
        connection: NetworkConnectionKind = .cellular,
        isConstrained: Bool = false
    ) -> DriveTestPreflightSnapshot {
        DriveTestPreflightSnapshot(
            locationAuthorization: locationAuthorization,
            locationAgeSeconds: locationAgeSeconds,
            horizontalAccuracyMeters: horizontalAccuracyMeters,
            availableStorageBytes: availableStorageBytes,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            isOnline: isOnline,
            connection: connection,
            isConstrained: isConstrained
        )
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

    func testIncompleteLegacyJSONDraftSurvivesRecovery() throws {
        let fileURL = try makeTemporaryQueueURL()
        let upload = makeSession(id: UUID(), startTime: 1_000, endTime: 1_000,
                                 showOnMap: false, points: [makePoint(timestamp: 1_000)])
        let queue = CoverageSessionQueue(fileURL: fileURL)
        try queue.upsert(upload, state: .recording)
        let original = try Data(contentsOf: fileURL)

        try queue.recoverInterruptedRecordings()

        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(try queue.allPending().first?.upload.sessionId, upload.sessionId)
        XCTAssertEqual(try queue.allPending().first?.state, .recording)
    }

    func testIncompleteLegacySwiftDataDraftSurvivesRecovery() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("SwiftData coverage store requires iOS 17") }
        let legacyURL = try makeTemporaryQueueURL()
        let storeURL = legacyURL.deletingLastPathComponent().appendingPathComponent("CoverageSessions.store")
        let store = try XCTUnwrap(SwiftDataCoverageSessionStore(storeURL: storeURL, legacyFileURL: legacyURL))
        let upload = makeSession(id: UUID(), startTime: 1_000, endTime: 1_000,
                                 showOnMap: false, points: [makePoint(timestamp: 1_000)])
        try store.upsert(upload, state: .recording)
        let original = try store.allPending()

        try store.recoverInterruptedRecordings()

        XCTAssertEqual(try store.allPending(), original)
    }

    func testRetiredCoveragePreservesOldDraftsWithoutUploadingOrRecoveringThem() async throws {
        for state: CoverageSessionQueueState in [.recording, .queued] {
            let fileURL = try makeTemporaryQueueURL()
            let upload = makeSession(id: UUID(), startTime: 1_000, endTime: 2_000,
                showOnMap: false, points: [makePoint(timestamp: 1_000), makePoint(timestamp: 2_000)])
            try CoverageSessionQueue(fileURL: fileURL).upsert(upload, state: state)
            LocalOfflineOwnership.claim(kind: "coverage", id: upload.sessionId.uuidString)
            defer { LocalOfflineOwnership.release(kind: "coverage", id: upload.sessionId.uuidString) }
            let original = try Data(contentsOf: fileURL)
            MockURLProtocol.requestHandler = { _ in
                XCTFail("Retired coverage must never reach the network")
                throw URLError(.notConnectedToInternet)
            }
            let service = SessionsService(api: makeAPIClient(), queueFileURL: fileURL)
            await service.retryPendingCoverageSessions()
            await SessionsService(api: makeAPIClient(), queueFileURL: fileURL).retryPendingCoverageSessions()
            XCTAssertEqual(try Data(contentsOf: fileURL), original, "Legacy data must remain byte-for-byte unchanged")
        }
    }

    func testRetiredCoverageLeavesSwiftDataDraftsUntouchedWithoutUploading() async throws {
        guard #available(iOS 17, *) else { throw XCTSkip("SwiftData coverage store requires iOS 17") }
        let legacyURL = try makeTemporaryQueueURL()
        let storeURL = legacyURL.deletingLastPathComponent().appendingPathComponent("CoverageSessions.store")
        let recording = makeSession(id: UUID(), startTime: 1_000, endTime: 2_000,
                                    showOnMap: false, points: [makePoint(timestamp: 1_000), makePoint(timestamp: 2_000)])
        let queued = makeSession(id: UUID(), startTime: 3_000, endTime: 4_000,
                                 showOnMap: true, points: [makePoint(timestamp: 3_000), makePoint(timestamp: 4_000)])
        let before: [PendingCoverageSession] = try {
            let oldStore = try XCTUnwrap(SwiftDataCoverageSessionStore(storeURL: storeURL, legacyFileURL: legacyURL))
            try oldStore.upsert(recording, state: .recording)
            try oldStore.upsert(queued, state: .queued)
            return try oldStore.allPending()
        }()
        XCTAssertEqual(before.count, 2)
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Retired SwiftData coverage must never reach the network")
            throw URLError(.notConnectedToInternet)
        }

        let service = SessionsService(api: makeAPIClient(), queueFileURL: legacyURL)
        await service.retryPendingCoverageSessions()
        await SessionsService(api: makeAPIClient(), queueFileURL: legacyURL).retryPendingCoverageSessions()
        do {
            _ = try await service.createCoverageSession(queued)
            XCTFail("Retired coverage accepted a new upload")
        } catch CoverageRecordingError.retired {
            // Expected: the old store stays available for a future explicit migration.
        }

        let reopened = try XCTUnwrap(SwiftDataCoverageSessionStore(storeURL: storeURL, legacyFileURL: legacyURL))
        XCTAssertEqual(try reopened.allPending(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testRetiredCoverageRejectsNewDraftsWithoutCreatingAQueue() throws {
        let fileURL = try makeTemporaryQueueURL()
        let upload = makeSession(id: UUID(), startTime: 1_000, endTime: 2_000,
            showOnMap: false, points: [makePoint(timestamp: 1_000), makePoint(timestamp: 2_000)])
        let service = SessionsService(api: makeAPIClient(), queueFileURL: fileURL)
        XCTAssertThrowsError(try service.persistCoverageDraft(upload))
        XCTAssertThrowsError(try service.finalizeCoverageDraft(upload))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSwiftDataMigrationKeepsEarlierJSONBackup() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("SwiftData coverage store requires iOS 17") }
        let legacyURL = try makeTemporaryQueueURL()
        let backupURL = legacyURL.appendingPathExtension("migrated")
        let storeURL = legacyURL.deletingLastPathComponent().appendingPathComponent("CoverageSessions.store")
        let older = makeSession(id: UUID(), startTime: 1_000, endTime: 2_000,
                                showOnMap: false, points: [makePoint(timestamp: 1_000), makePoint(timestamp: 2_000)])
        let newer = makeSession(id: UUID(), startTime: 3_000, endTime: 4_000,
                                showOnMap: false, points: [makePoint(timestamp: 3_000), makePoint(timestamp: 4_000)])
        try CoverageSessionQueue(fileURL: backupURL).upsert(older, state: .queued)
        try CoverageSessionQueue(fileURL: legacyURL).upsert(newer, state: .queued)
        let olderBytes = try Data(contentsOf: backupURL)
        let newerBytes = try Data(contentsOf: legacyURL)

        let store = try XCTUnwrap(SwiftDataCoverageSessionStore(storeURL: storeURL, legacyFileURL: legacyURL))

        XCTAssertEqual(try Data(contentsOf: backupURL), olderBytes)
        XCTAssertEqual(try Data(contentsOf: backupURL.appendingPathExtension("1")), newerBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(try store.allPending().map(\.upload.sessionId), [newer.sessionId])
    }

    func testLocalArchiveReadsJSONAndBackupsWithoutChangingFiles() throws {
        let directory = try makeTemporaryQueueURL().deletingLastPathComponent()
        let currentURL = directory.appendingPathComponent("PendingCoverageSessions.json")
        let backupURL = currentURL.appendingPathExtension("migrated")
        let unreadableURL = currentURL.appendingPathExtension("migrated.1")
        let id = UUID()
        let older = makeSession(id: id, startTime: 1_000, endTime: 1_000,
                                showOnMap: false, points: [makePoint(timestamp: 1_000)])
        let newer = makeSession(id: id, startTime: 1_000, endTime: 3_000,
                                showOnMap: false, points: [makePoint(timestamp: 1_000), makePoint(timestamp: 3_000)])
        let other = makeSession(id: UUID(), startTime: 4_000, endTime: 4_000,
                                showOnMap: false, points: [makePoint(timestamp: 4_000)])
        try CoverageSessionQueue(fileURL: currentURL).upsert(older, state: .recording)
        try CoverageSessionQueue(fileURL: backupURL).upsert(newer, state: .queued)
        try CoverageSessionQueue(fileURL: backupURL).upsert(other, state: .recording)
        try Data("invalid archive".utf8).write(to: unreadableURL)
        let originalFiles = try [currentURL, backupURL, unreadableURL].map { try Data(contentsOf: $0) }

        let snapshot = LocalCoverageArchiveReader.load(directory: directory)

        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.entries.first?.id, other.sessionId)
        XCTAssertEqual(snapshot.entries.last?.id, id)
        XCTAssertEqual(snapshot.entries.last?.pointCount, 2)
        XCTAssertEqual(snapshot.entries.last?.state, .queued)
        XCTAssertEqual(snapshot.unreadableSources, 1)
        XCTAssertEqual(try [currentURL, backupURL, unreadableURL].map { try Data(contentsOf: $0) }, originalFiles)
    }

    func testLocalArchiveReadsSwiftDataAndLegacyJSONWithoutMigrating() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("SwiftData coverage store requires iOS 17") }
        let directory = try makeTemporaryQueueURL().deletingLastPathComponent()
        let legacyURL = directory.appendingPathComponent("PendingCoverageSessions.json")
        let storeURL = directory.appendingPathComponent("CoverageSessions.store")
        let databaseSession = makeSession(id: UUID(), startTime: 1_000, endTime: 2_000,
                                          showOnMap: false, points: [makePoint(timestamp: 1_000), makePoint(timestamp: 2_000)])
        let jsonSession = makeSession(id: UUID(), startTime: 3_000, endTime: 4_000,
                                      showOnMap: false, points: [makePoint(timestamp: 3_000), makePoint(timestamp: 4_000)])
        let store = try XCTUnwrap(SwiftDataCoverageSessionStore(storeURL: storeURL, migrateLegacy: false))
        try store.upsert(databaseSession, state: .queued)
        try CoverageSessionQueue(fileURL: legacyURL).upsert(jsonSession, state: .recording)
        let originalJSON = try Data(contentsOf: legacyURL)

        let snapshot = LocalCoverageArchiveReader.load(directory: directory, storeURL: storeURL)

        XCTAssertEqual(Set(snapshot.entries.map(\.id)), Set([databaseSession.sessionId, jsonSession.sessionId]))
        XCTAssertEqual(snapshot.unreadableSources, 0)
        XCTAssertEqual(try Data(contentsOf: legacyURL), originalJSON)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.appendingPathExtension("migrated").path))
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
