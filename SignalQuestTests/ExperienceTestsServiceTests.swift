import XCTest
@testable import SignalQuest

/// Journal local, file d'envoi et lecture du serveur des tests d'expérience (contrat
/// `experience-tests-v1`), sans réseau : le serveur est une fermeture qui répond.
@MainActor
final class ExperienceTestsServiceTests: XCTestCase {

    // MARK: Fixtures

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("experience-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func measuredTests() -> ExperienceTestsResult {
        var tests = ExperienceTestsResult()
        tests.videoLadder = ExperienceLadderResult(state: .measured, rungs: [
            ExperienceRung(quality: .p480, state: .measured, startupMs: 640, bufferMinMs: 1_800, bufferAvgMs: 6_200,
                           receivedBps: 3_600_000, bytes: 1_875_000),
            ExperienceRung(quality: .p720, state: .abandoned, startupMs: 900, stalls: [.init(atPlaybackMs: 6_000, waitMs: 6_000)],
                           receivedBps: 2_000_000, bytes: 2_000_000),
            ExperienceRung(quality: .p1080, state: .notTested)
        ])
        tests.videoAdaptive = ExperienceAdaptiveResult(
            state: .measured, playbackMs: 30_000, startupMs: 500, timeByQualityMs: [.p480: 10_000, .p720: 20_000],
            switchesUp: 1, switchesDown: 0, stalls: [], score: ExperienceVideoScore(total: 75, quality: 15, smoothness: 40, startup: 20)
        )
        tests.webPage = ExperienceWebResult(state: .measured, pageBytes: 2_300_000, parallelRequests: 6, openings: [
            ExperienceWebOpening(measured: true, protocolName: "h2", freshConnection: true, dnsMs: 12, connectMs: 28, tlsMs: 20,
                                 firstByteMs: 30, contentMs: 1_971, totalMs: 2_061),
            ExperienceWebOpening(measured: false, protocolName: "h2")
        ])
        tests.gameAndCalls = ExperienceGameResult(
            state: .measured, probeMethod: "tcp_connect", medianMs: 41, jitterMs: 3, maxMs: 180, spikeCount: 1, spikeShare: 0.3333,
            series: [41, 39, 180],
            underLoad: ExperienceUnderLoad(idleMs: 39, loadedDownMs: 58, loadedUpMs: nil, grade: "B", deltaMs: 19, source: .shortLoad)
        )
        tests.upload = ExperienceUploadResult(state: .interrupted, reason: .networkChanged, items: [
            ExperienceUploadItem(kind: .photo, bytes: 5_000_000, totalMs: 4_600)
        ])
        return tests
    }

    private func submission(_ tests: ExperienceTestsResult, id: UUID = UUID(), at date: Date = Date(timeIntervalSince1970: 1_793_019_912.123)) -> ExperienceSubmission {
        ExperienceSubmission(
            clientSubmissionId: id, appVersion: "1.0 (180)", measuredAt: date, durationMs: 159_000, bytesUsed: 109_000_000,
            network: .init(connectionType: "cellular", technology: "4G", operatorKey: "ORANGE", marketCode: "FR"),
            location: .init(city: "Grenoble", marketCode: "FR"), tests: tests
        )
    }

    private func run(usage: [ExperienceTestKind: ExperienceTestUsage] = [.videoLadder: .init(bytes: 3_875_000, durationMs: 20_000)],
                     failures: [ExperienceTestKind: ExperienceFailureCause] = [:]) -> ExperienceRun {
        ExperienceRun(tests: measuredTests(), bytesUsed: 3_875_000, durationMs: 20_000, stop: nil, failures: failures, usage: usage)
    }

    final class FakeServer: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [APIEndpoint] = []
        var respond: @Sendable (APIEndpoint) throws -> Data

        init(respond: @escaping @Sendable (APIEndpoint) throws -> Data) { self.respond = respond }

        func send(_ endpoint: APIEndpoint) throws -> Data {
            lock.withLock { requests.append(endpoint) }
            return try respond(endpoint)
        }

        var sent: [APIEndpoint] { lock.withLock { requests } }
    }

    nonisolated private static func created(_ id: String, post: String? = "post-1") -> Data {
        let post = post.map { "{\"id\":\"\($0)\"}" } ?? "null"
        return Data("{\"success\":true,\"id\":\"\(id)\",\"idempotent\":false,\"post\":\(post),\"warnings\":[]}".utf8)
    }

    private func service(_ server: FakeServer, root: URL, owner: String = "user:alice", uploadEnabled: Bool = true) -> ExperienceTestsService {
        ExperienceTestsService(
            store: ExperienceJournalStore(rootURL: root, keyStore: InMemoryTokenStore()),
            send: { try server.send($0) }, uploadEnabled: uploadEnabled, ownerScopeId: { owner }
        )
    }

    // MARK: Lecture du résultat

    func testStoredBodyReadsBackToTheSameTests() throws {
        let tests = measuredTests()
        let result = try XCTUnwrap(ExperienceResultReader.read(try submission(tests).body()))
        XCTAssertEqual(result.tests, tests)
        XCTAssertEqual(result.city, "Grenoble")
        XCTAssertEqual(result.platform, "ios")
        XCTAssertEqual(result.network.operatorKey, "ORANGE")
        XCTAssertEqual(result.measuredAt.timeIntervalSince1970, 1_793_019_912.123, accuracy: 0.0005)
    }

    func testReaderDropsWhatTheWriterNeverSends() throws {
        var tests = ExperienceTestsResult()
        tests.videoAdaptive = ExperienceAdaptiveResult(state: .interrupted, reason: .background, playbackMs: 9_000,
                                                       score: ExperienceVideoScore(total: 1, quality: 1, smoothness: 0, startup: 0))
        tests.gameAndCalls = ExperienceGameResult(state: .measured, probeMethod: "tcp_connect", medianMs: 40, jitterMs: 2.5, series: [40])
        let read = try XCTUnwrap(ExperienceResultReader.read(try submission(tests).body())).tests
        XCTAssertNil(read.videoAdaptive?.score, "pas de note sans lecture allée au bout")
        XCTAssertEqual(read.videoAdaptive?.reason, .background)
        XCTAssertEqual(read.gameAndCalls?.jitterMs, 3, "gigue arrondie une fois, à l'écriture")
    }

    /// Les vecteurs du contrat (copie à l'octet) relus puis réécrits donnent les mêmes `highlights`.
    func testContractVectorsSurviveAReadAndRewrite() throws {
        struct Vectors: Decodable {
            struct Case: Decodable {
                let name: String
                let tests: [String: JSONValue]
                let expected: [String: JSONValue]
            }
            let cases: [Case]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/experience-tests/v1-highlights.json"))
        for vector in try JSONDecoder().decode(Vectors.self, from: data).cases {
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(vector.tests)) as? [String: Any])
            let body = try submission(ExperienceResultReader.tests(raw)).body()
            let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])["tests"]
            let tests = try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(rewritten)))
            XCTAssertEqual(ExperienceHighlights(tests: tests), ExperienceHighlights(served: vector.expected), vector.name)
        }
    }

    // MARK: Journal

    func testJournalIsEncryptedAndIsolatedByOwner() async throws {
        let root = temporaryRoot()
        let keys = InMemoryTokenStore()
        let store = ExperienceJournalStore(rootURL: root, keyStore: keys)
        let body = try submission(measuredTests()).body()
        try await store.insertIfAbsent(ExperienceJournalRecord(clientSubmissionId: "a", ownerScopeId: "user:alice", measuredAtMs: 1,
                                                               body: body, delivery: .pending))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        let file = try XCTUnwrap(files.first { $0.lastPathComponent == "tests.json.enc" })
        let bytes = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(bytes.contains("Grenoble"))
        XCTAssertFalse(files.contains { $0.path.contains("alice") }, "l'identifiant du compte n'est pas sur le disque")

        let relaunched = ExperienceJournalStore(rootURL: root, keyStore: keys)
        let alice = try await relaunched.records(ownerScopeId: "user:alice")
        let bob = try await relaunched.records(ownerScopeId: "user:bob")
        XCTAssertEqual(alice.map(\.clientSubmissionId), ["a"])
        XCTAssertTrue(bob.isEmpty)
    }

    func testPruningNeverDropsAPendingTest() {
        let body = Data("{}".utf8)
        var records = (0..<ExperienceJournalStore.maxRecords).map {
            ExperienceJournalRecord(clientSubmissionId: "s\($0)", ownerScopeId: "guest", measuredAtMs: Int64($0 + 10), body: body, delivery: .synced)
        }
        records.append(ExperienceJournalRecord(clientSubmissionId: "old-pending", ownerScopeId: "guest", measuredAtMs: 0, body: body, delivery: .pending))
        let pruned = ExperienceJournalStore.pruned(records)
        XCTAssertEqual(pruned.count, ExperienceJournalStore.maxRecords)
        XCTAssertTrue(pruned.contains { $0.clientSubmissionId == "old-pending" })
        XCTAssertFalse(pruned.contains { $0.clientSubmissionId == "s0" }, "le plus ancien test envoyé part en premier")
    }

    // MARK: Enregistrement et envoi

    func testSaveQueuesThenSyncsWithTheServerReceipt() async throws {
        let server = FakeServer { _ in Self.created("exp-1") }
        let service = service(server, root: temporaryRoot())
        let id = UUID()
        let outcome = await service.save(submission(measuredTests(), id: id), run: run(failures: [.upload: .serverBusy]))
        XCTAssertEqual(outcome, .queued(clientSubmissionId: id.uuidString.lowercased()))
        let request = try XCTUnwrap(server.sent.first)
        XCTAssertEqual(request.path, "/api/experience-tests")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.idempotencyKey, id.uuidString.lowercased())
        XCTAssertEqual(request.body, try submission(measuredTests(), id: id).body(), "le corps envoyé est celui gardé, à l'octet")
        let records = await service.localRecords()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.delivery, .synced)
        XCTAssertEqual(record.serverId, "exp-1")
        XCTAssertEqual(record.postId, "post-1")
        XCTAssertEqual(record.usage["videoLadder"], .init(bytes: 3_875_000, durationMs: 20_000))
        XCTAssertEqual(record.failureCauses["upload"], "serverBusy")
    }

    func testClosedSwitchKeepsTestsPendingWithoutCallingTheServer() async throws {
        let server = FakeServer { _ in Self.created("exp-1") }
        let service = service(server, root: temporaryRoot(), uploadEnabled: false)
        _ = await service.save(submission(measuredTests()), run: run())
        await service.retryPending()
        XCTAssertTrue(server.sent.isEmpty)
        let records = await service.localRecords()
        XCTAssertEqual(records.map(\.delivery), [.pending])
    }

    func testGuestKeepsTestsOnThePhoneOnly() async throws {
        let server = FakeServer { _ in Self.created("exp-1") }
        let service = service(server, root: temporaryRoot(), owner: "guest")
        let outcome = await service.save(submission(measuredTests()), run: run())
        guard case .localOnly = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(server.sent.isEmpty, "pas de mode invité en v1")
    }

    func testNothingMeasuredIsNotKept() async throws {
        let service = service(FakeServer { _ in Data() }, root: temporaryRoot())
        var tests = ExperienceTestsResult()
        tests.upload = ExperienceUploadResult(state: .failed)
        let outcome = await service.save(submission(tests), run: run())
        XCTAssertEqual(outcome, .nothingMeasured)
        let records = await service.localRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testDefinitiveRefusalLeavesTheQueueButANetworkErrorKeepsIt() async throws {
        let root = temporaryRoot()
        let server = FakeServer { _ in throw APIError.http(status: 400, code: "EXPERIENCE_TEST_INVALID", message: "x", requestId: nil, retryAfter: nil) }
        let service = service(server, root: root)
        _ = await service.save(submission(measuredTests()), run: run())
        let refused = await service.localRecords()
        let record = try XCTUnwrap(refused.first)
        XCTAssertEqual(record.delivery, .rejected)
        XCTAssertEqual(record.lastError, "invalid:-")

        let offline = FakeServer { _ in throw APIError.transport("offline") }
        let second = self.service(offline, root: temporaryRoot())
        _ = await second.save(submission(measuredTests()), run: run())
        _ = await second.save(submission(measuredTests(), at: Date(timeIntervalSince1970: 1_793_019_999)), run: run())
        let kept = await second.localRecords()
        XCTAssertEqual(kept.map(\.delivery), [.pending, .pending])
        XCTAssertEqual(kept.map(\.lastError), [nil, "network"], "le plus ancien d'abord ; le plus récent pas encore tenté")
        // Hors ligne : chaque passage s'arrête au premier échec au lieu d'essayer toute la file.
        XCTAssertEqual(offline.sent.count, 2)
    }

    func testFailureMappingFollowsTheContractCodes() {
        func http(_ status: Int, _ code: String? = nil) -> APIError {
            .http(status: status, code: code, message: "", requestId: nil, retryAfter: nil)
        }
        XCTAssertEqual(ExperienceAPIMapping.failure(http(400, "EXPERIENCE_TEST_METHODOLOGY_UNSUPPORTED")), .methodologyUnsupported)
        XCTAssertEqual(ExperienceAPIMapping.failure(http(400, "EXPERIENCE_TEST_SCORE_SCALE_UNSUPPORTED")), .scoreScaleUnsupported)
        XCTAssertEqual(ExperienceAPIMapping.failure(http(413)), .tooLarge)
        XCTAssertEqual(ExperienceAPIMapping.failure(http(409, "EXPERIENCE_TEST_CLIENT_SUBMISSION_ID_CONFLICT")), .submissionIdConflict)
        XCTAssertEqual(ExperienceAPIMapping.failure(http(409)), .other(status: 409), "un 409 sans le code n'est pas un conflit d'identifiant")
        XCTAssertEqual(ExperienceAPIMapping.failure(http(401)), .unauthorized)
        XCTAssertEqual(ExperienceAPIMapping.failure(http(429)), .rateLimited)
        XCTAssertEqual(ExperienceAPIMapping.failure(http(503)), .server)
        XCTAssertTrue(ExperienceSubmitFailure.invalid(path: nil).isDefinitive)
        XCTAssertFalse(ExperienceSubmitFailure.rateLimited.isDefinitive)
        XCTAssertFalse(ExperienceSubmitFailure.network.isDefinitive)
    }

    func testReplayReceiptIsAccepted() {
        let receipt = ExperienceAPIMapping.parseReceipt(Data("{\"success\":true,\"id\":\"exp-9\",\"idempotent\":true}".utf8))
        XCTAssertEqual(receipt, ExperienceReceipt(id: "exp-9", idempotent: true, postId: nil, warnings: []))
        XCTAssertNil(ExperienceAPIMapping.parseReceipt(Data("{\"success\":false,\"id\":\"x\"}".utf8)))
    }

    // MARK: Historique

    func testHistoryPageSkipsUnreadableRows() throws {
        let json = """
        {"experienceTests":[
          {"id":"e1","measuredAt":"2026-10-26T13:05:12.123Z","platform":"android","connectionType":"cellular",
           "technology":"5G NSA","operatorKey":"ORANGE","marketCode":"FR","city":null,
           "highlights":{"videoMaxQuality":"1080p","pageMedianMs":1930,"gameMedianMs":41,"gameProbeMethod":"tcp_connect"},
           "states":{"videoLadder":"measured","upload":"failed","unknown":"measured"},"post":{"id":"p1","visibility":"friends"}},
          {"id":"e2"}
        ],"count":2,"meta":{"page":1,"limit":25,"total":30,"hasMore":true}}
        """
        let page = try XCTUnwrap(ExperienceAPIMapping.parseHistoryPage(Data(json.utf8)))
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items.map(\.id), ["e1"])
        let item = page.items[0]
        XCTAssertEqual(item.highlights, ExperienceHighlights(videoMaxQuality: "1080p", pageMedianMs: 1_930, gameMedianMs: 41, gameProbeMethod: "tcp_connect"))
        XCTAssertEqual(item.states, [.videoLadder: .measured, .upload: .failed])
        XCTAssertEqual(item.postVisibility, "friends")
        XCTAssertNil(item.city)
    }

    func testHistoryQueryNeedsAMarketForAnOperator() {
        let names = { (query: ExperienceHistoryQuery) in query.queryItems.map(\.name) }
        XCTAssertEqual(names(ExperienceHistoryQuery(operatorKey: "ORANGE")), ["period", "limit", "page"])
        XCTAssertEqual(names(ExperienceHistoryQuery(marketCode: "FR", operatorKey: "ORANGE")), ["period", "limit", "page", "marketCode", "operatorKey"])
        XCTAssertEqual(ExperienceHistoryQuery(limit: 500).queryItems.first { $0.name == "limit" }?.value, "100")
    }

    func testMergeKeepsServerRowsAndUnsentLocalOnes() {
        func item(_ id: String, _ seconds: TimeInterval, delivery: ExperienceDelivery? = nil) -> ExperienceHistoryItem {
            ExperienceHistoryItem(id: id, measuredAt: Date(timeIntervalSince1970: seconds), platform: "ios", connectionType: "wifi",
                                  highlights: ExperienceHighlights(), states: [:], delivery: delivery)
        }
        let remote = [item("e2", 200), item("e1", 100.123)]
        let local = [
            item("e2", 200, delivery: .synced),           // déjà confirmé : la ligne du serveur fait foi
            item("local-a", 100.123, delivery: .pending), // reçu par le serveur, accusé perdu
            item("local-b", 300, delivery: .pending),     // pas encore envoyé
            item("local-c", 50, delivery: .localOnly)
        ]
        XCTAssertEqual(ExperienceHistoryMerge.merge(local: local, remote: remote).map(\.id), ["local-b", "e2", "e1", "local-c"])
    }

    func testLocalItemCarriesHighlightsAndDelivery() async throws {
        let service = service(FakeServer { _ in throw APIError.transport("offline") }, root: temporaryRoot())
        _ = await service.save(submission(measuredTests()), run: run())
        let items = await service.localItems()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.delivery, .pending)
        XCTAssertEqual(item.highlights.videoMaxQuality, "480p")
        XCTAssertEqual(item.highlights.pageMedianMs, 2_061)
        XCTAssertEqual(item.states[.upload], .interrupted)
        XCTAssertEqual(item.city, "Grenoble")
    }

    func testDetailIsReadWithItsPost() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try submission(measuredTests()).body()) as? [String: Any])
        object["id"] = "e1"
        object["post"] = ["id": "p1", "visibility": "public"]
        object["highlights"] = ["videoMaxQuality": "480p"]
        object["location"] = NSNull()
        let data = try JSONSerialization.data(withJSONObject: ["experienceTest": object])
        let detail = try XCTUnwrap(ExperienceAPIMapping.parseDetail(data))
        XCTAssertEqual(detail.id, "e1")
        XCTAssertEqual(detail.postVisibility, "public")
        XCTAssertNil(detail.result?.city, "un autre lecteur ne reçoit pas la ville")
        XCTAssertEqual(detail.result?.tests, measuredTests())
    }

    // MARK: Suppression

    func testDeletingAnUnsentTestStaysLocal() async throws {
        let server = FakeServer { _ in throw APIError.transport("offline") }
        let service = service(server, root: temporaryRoot())
        let id = UUID()
        _ = await service.save(submission(measuredTests(), id: id), run: run())
        let before = server.sent.count
        let outcome = await service.delete(serverId: nil, clientSubmissionId: id.uuidString.lowercased())
        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(server.sent.count, before, "rien n'existe sur le serveur")
        let records = await service.localRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testDeletingASyncedTestAsksTheServerFirst() async throws {
        let server = FakeServer { endpoint in
            if endpoint.method == .delete { throw APIError.transport("offline") }
            return Self.created("exp-7")
        }
        let service = service(server, root: temporaryRoot())
        let id = UUID()
        _ = await service.save(submission(measuredTests(), id: id), run: run())
        let offline = await service.delete(serverId: "exp-7", clientSubmissionId: nil)
        XCTAssertEqual(offline, .failed(.network))
        var records = await service.localRecords()
        XCTAssertEqual(records.count, 1, "hors ligne, rien n'est supprimé")

        server.respond = { endpoint in
            if endpoint.method == .delete {
                throw APIError.http(status: 404, code: "EXPERIENCE_TEST_NOT_FOUND", message: "", requestId: nil, retryAfter: nil)
            }
            return Data()
        }
        let gone = await service.delete(serverId: "exp-7", clientSubmissionId: nil)
        XCTAssertEqual(gone, .deleted, "déjà supprimé côté serveur : l'état voulu est atteint")
        XCTAssertEqual(server.sent.last?.path, "/api/experience-tests/exp-7")
        records = await service.localRecords()
        XCTAssertTrue(records.isEmpty)
    }

    // MARK: Reprise des latences

    func testRecentLatencyPathFollowsTheConnection() {
        XCTAssertNil(ExperienceRecentLatency.path(connection: .wired, ssid: nil, carrierOperatorKey: nil))
        let wifi = ExperienceRecentLatency.path(connection: .wifi, ssid: "Maison", carrierOperatorKey: "ORANGE")
        XCTAssertEqual(wifi?.transport, .wifi)
        XCTAssertEqual(wifi?.ssid, "Maison")
        XCTAssertNil(wifi?.carrierOperatorKey)
        let cellular = ExperienceRecentLatency.path(connection: .cellular, ssid: "Maison", carrierOperatorKey: "ORANGE")
        XCTAssertEqual(cellular?.transport, .cellular)
        XCTAssertNil(cellular?.ssid)
        XCTAssertEqual(cellular?.carrierOperatorKey, "ORANGE")

        let snapshot = ExperienceLatencyReuse.Snapshot(measuredAt: Date(), path: wifi!, idleMs: 20, loadedDownMs: 40, loadedUpMs: 50)
        ExperienceRecentLatency.record(snapshot)
        XCTAssertEqual(ExperienceRecentLatency.current, snapshot)
        ExperienceRecentLatency.clear()
        XCTAssertNil(ExperienceRecentLatency.current)
    }
}
