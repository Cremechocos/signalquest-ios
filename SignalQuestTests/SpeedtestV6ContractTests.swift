import Foundation
import XCTest
import SwiftUI
@testable import SignalQuest

final class SpeedtestV6ContractTests: XCTestCase {
    private struct Vectors: Decodable { let cases: [Vector] }
    private struct Vector: Decodable {
        let name: String, startMs: Int64, endMs: Int64
        let samples: [SpeedtestMeasurementInterval]
        let averageMbps: Double, maxMbps: Double, p90Mbps: Double, p95Mbps: Double
    }

    func testSharedMeasuredVectors() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "speedtest-v6-vectors", withExtension: "json")
            ?? bundle.url(forResource: "speedtest-v6-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        for vector in vectors.cases {
            let average = SpeedtestTraceMath.mbps(bytes: Double(vector.samples.reduce(0) { $0 + $1.bytes }), durationMs: vector.endMs - vector.startMs)
            let windows = SpeedtestTraceMath.windows(vector.samples, windowMs: 1000).map(\.mbps)
            let peak = SpeedtestTraceMath.windows(vector.samples, windowMs: max(1000, Int64(Double(vector.endMs - vector.startMs) * 0.3))).map(\.mbps).max() ?? average
            XCTAssertEqual(average, vector.averageMbps, accuracy: 0.01, vector.name)
            XCTAssertEqual(max(average, peak), vector.maxMbps, accuracy: 0.01, vector.name)
            XCTAssertEqual(try XCTUnwrap(SpeedtestTraceMath.percentile(windows, 0.9)), vector.p90Mbps, accuracy: 0.01, vector.name)
            XCTAssertEqual(try XCTUnwrap(SpeedtestTraceMath.percentile(windows, 0.95)), vector.p95Mbps, accuracy: 0.01, vector.name)
        }
    }
}

extension SpeedtestV6ContractTests {
    func testRecentWindowInterpolatesIrregularBoundaryAndFallsToZero() {
        let sampler = SpeedtestLiveSampler(smoothing: 1)
        _ = sampler.observe(totalBytes: 12_500_000, elapsedMs: 1000)
        _ = sampler.observe(totalBytes: 18_750_000, elapsedMs: 1500)
        // 500 ms of silence: exact [1000,2000] interval is 50 Mbps.
        XCTAssertEqual(sampler.observe(totalBytes: 18_750_000, elapsedMs: 2000), 50, accuracy: 0.001)
        XCTAssertEqual(sampler.observe(totalBytes: 18_750_000, elapsedMs: 2600), 0, accuracy: 0.001)
        sampler.reset()
        XCTAssertEqual(sampler.observe(totalBytes: 137_500_000, elapsedMs: 1000), 1100, accuracy: 0.001)
    }

    func testClosedCountersExcludeLateBytesButTrafficRetainsThem() {
        let counter = SafeCounter()
        counter.add(100)
        let baseline = counter.markMeasurementStart()
        counter.add(250)
        let closed = counter.close()
        counter.add(50)
        XCTAssertEqual(closed.bytes - baseline.bytes, 250)
        XCTAssertEqual(counter.timedSnapshot().bytes, 350)
        XCTAssertEqual(counter.timedSnapshot().timestamp, closed.timestamp)
        XCTAssertEqual(counter.trafficValue, 400)
    }

    func testTraceResultAndPendingSaveSurviveRoundTripWithoutRelabelingArchives() throws {
        let recorder = SpeedtestTraceRecorder()
        recorder.retain(phase: "download", id: "attempt-a", start: recorder.origin,
            baseline: recorder.origin + 1, end: recorder.origin + 3, measuredBytes: 25_000_000,
            totalBytes: 30_000_000, source: "client-received",
            samples: [.init(startMs: 0, endMs: 1000, bytes: 12_500_000), .init(startMs: 1000, endMs: 2000, bytes: 12_500_000)])
        let result = SpeedtestRunResult(id: recorder.runId, label: "v6", downloadMbps: 100,
            downloadAverageMbps: 100, downloadMaxMbps: 100, downloadP90Mbps: 100,
            pingMs: 20, pingMinMs: 10, durationSeconds: 3, connectionType: .wifi,
            measurementTrace: recorder.snapshot(), methodologyVersion: 6, ownerScopeId: "guest")
        let restored = try JSONDecoder().decode(SpeedtestRunResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(restored, result)
        XCTAssertEqual(restored.primaryPingMs, 10)
        let pending = PendingSpeedtestSave(id: result.id.uuidString, result: result, streams: 4,
            deviceModel: "test", createdAt: Date(), isVisibleOnMap: false, shareExactLocation: false,
            guestDeleteToken: nil, driveSessionId: nil, ownerScopeId: "guest")
        XCTAssertEqual(try JSONDecoder().decode(PendingSpeedtestSave.self, from: JSONEncoder().encode(pending)), pending)
        let payload = SpeedtestSubmission.iosPayload(from: restored, streams: 4, deviceModel: "test")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(json["methodologyVersion"] as? Int, 6)
        XCTAssertEqual(json["ping"] as? Double, 10)
        XCTAssertEqual(json["pingAvg"] as? Double, 20)
        XCTAssertNotNil(json["measurementTrace"])
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        legacyJSON.removeValue(forKey: "measurementTrace")
        legacyJSON.removeValue(forKey: "methodologyVersion")
        legacyJSON.removeValue(forKey: "ownerScopeId")
        let legacy = try JSONDecoder().decode(SpeedtestRunResult.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertNil(legacy.measurementTrace)
        XCTAssertNil(legacy.methodologyVersion)
        XCTAssertEqual(legacy.primaryPingMs, 20)
        XCTAssertEqual(SpeedtestSubmission.iosPayload(from: legacy, streams: 4, deviceModel: "test").methodologyVersion, 5)
    }

    func testConcurrentRetriesUseOneSubmission() async throws {
        actor Count {
            var value = 0
            func increment() { value += 1 }
        }
        let count = Count()
        let coordinator = SpeedtestSubmissionCoordinator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await coordinator.submit(id: "same-result") {
                        await count.increment()
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
            }
            try await group.waitForAll()
        }
        let total = await count.value
        XCTAssertEqual(total, 1)
    }

    func testReplacedAttemptIsSeparateFromRetainedCurve() throws {
        let recorder = SpeedtestTraceRecorder()
        for id in ["old", "new"] {
            recorder.retain(phase: "download", id: id, start: recorder.origin, baseline: recorder.origin,
                end: recorder.origin + 1, measuredBytes: 125, totalBytes: 125, source: "client-received",
                samples: [.init(startMs: 0, endMs: 1000, bytes: 125)])
        }
        let trace = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(trace.phases.count, 1)
        XCTAssertEqual(trace.phases.first?.attemptId, "new")
        XCTAssertEqual(trace.abandonedAttempts.first?.attemptId, "old")
        XCTAssertEqual(trace.phases.first?.samples.count, 1)
    }
}

extension SpeedtestV6ContractTests {
    func testConcurrentLegacyStoreUpdatesSurviveReload() async throws {
        let cache = DiskCache(folderName: "SpeedtestV6Test-\(UUID().uuidString)", evicts: false)
        let store = DiskCacheSpeedtestPendingStore(cache: cache, key: "pending")
        let result = SpeedtestRunResult(label: "queued", downloadMbps: 100, downloadAverageMbps: 100,
            downloadMaxMbps: 100, durationSeconds: 10, connectionType: .wifi)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await store.upsert(.init(id: String(index), result: result, streams: 1,
                        deviceModel: "test", createdAt: Date(), isVisibleOnMap: false,
                        shareExactLocation: false, guestDeleteToken: nil, driveSessionId: nil, ownerScopeId: "guest"))
                }
            }
            try await group.waitForAll()
        }
        let reloaded = await DiskCacheSpeedtestPendingStore(cache: cache, key: "pending").loadAll()
        XCTAssertEqual(Set(reloaded.map(\.id)), Set((0..<20).map(String.init)))
        await cache.remove("pending")
    }

    func testSubMillisecondFinalIntervalPreservesByteTotal() {
        let box = SpeedtestSamplesBox()
        box.append(start: 0, end: 1000.1, bytes: 100)
        box.append(start: 1000.1, end: 1000.2, bytes: 5)
        XCTAssertEqual(box.snapshotIntervals(), [.init(startMs: 0, endMs: 1000, bytes: 105)])
    }
}


extension SpeedtestV6ContractTests {
    @MainActor
    func testTimedDetailsRenderAtAccessibleSizesAndExportTraceContract() throws {
        let phase = SpeedtestPhaseTrace(phase: "download", attemptId: "render-attempt", startOffsetMs: 500,
            warmupEndOffsetMs: 1500, measurementEndOffsetMs: 3500, totalEndOffsetMs: 3600,
            measuredBytes: 250_000_000, totalTransferredBytes: 300_000_000,
            byteSource: "client-received", sampleByteSource: "client-received", liveWindowMs: 1000,
            peakWindowMs: 1000, samples: [.init(startMs: 1500, endMs: 2100, bytes: 75_000_000),
                .init(startMs: 2100, endMs: 2800, bytes: 87_500_000), .init(startMs: 2800, endMs: 3500, bytes: 87_500_000)])
        let trace = SpeedtestMeasurementTrace(runId: "render-run", phases: [phase], abandonedAttempts: [])
        try JSONEncoder().encode(trace).write(to: URL(fileURLWithPath: "/tmp/sq-ios-v6-contract-trace.json"))
        let result = SpeedtestRunResult(label: "v6", downloadMbps: 1000, downloadAverageMbps: 1000,
            downloadMaxMbps: 1000, downloadP90Mbps: 1000, pingMs: 20, pingMinMs: 12, durationSeconds: 4,
            connectionType: .wifi, uploadMeasurementSource: "client-written", measurementTrace: trace, methodologyVersion: 6)
        let card = SQShareCardBuilder.model(for: result, theme: .light, locale: Locale(identifier: "fr_FR"))
        XCTAssertEqual(card.download.unit, "Gbps")
        XCTAssertEqual(card.download.value, "1,00")
        XCTAssertEqual(card.download.graph.normalizedTimes, [0.65, 1.0])
        XCTAssertEqual(card.latencyValueText, "12")
        XCTAssertEqual(card.upload.value, "—")
        XCTAssertEqual(card.upload.maxValue, "—")
        let share = SQShareCardRenderer.render(card)
        try XCTUnwrap(share.pngData()).write(to: URL(fileURLWithPath: "/tmp/sq-ios-v6-active-share.png"))
        for (name, width, size, theme) in [("phone", 320.0, DynamicTypeSize.accessibility3, ColorScheme.light),
                                         ("tablet", 768.0, DynamicTypeSize.large, ColorScheme.dark)] {
            let view = SpeedtestDetailContent(result: result).frame(width: width)
                .environment(\.dynamicTypeSize, size).environment(\.colorScheme, theme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, width, accuracy: 1)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/sq-ios-v6-\(name).png"))
        }
    }
}


extension SpeedtestV6ContractTests {
    func testSenderSlotCounterReleasesCapacity() {
        let outstanding = SafeCounter()
        for _ in 0..<8 { outstanding.add(1) }
        outstanding.add(-1)
        XCTAssertEqual(outstanding.value, 7, "Completed upload blocks must release the next send slot")
        outstanding.add(-20)
        XCTAssertEqual(outstanding.value, 0)
    }

    func testRunTrafficIncludesWarmupAndAbandonedAttempts() throws {
        let recorder = SpeedtestTraceRecorder()
        let first = SafeCounter(onDelta: { recorder.recordTraffic(phase: "download", bytes: $0) })
        first.add(200)
        _ = first.markMeasurementStart()
        first.add(300)
        _ = first.close()
        first.add(50)
        recorder.abandon(phase: "download", id: "failed", start: recorder.origin, reason: "TRANSFER_FAILED")
        let next = SafeCounter(onDelta: { recorder.recordTraffic(phase: "download", bytes: $0) })
        next.add(1000)
        recorder.retain(phase: "download", id: "retained", start: recorder.origin,
            baseline: recorder.origin, end: recorder.origin + 1, measuredBytes: 1000, totalBytes: 1000,
            source: "client-received", samples: [.init(startMs: 0, endMs: 1000, bytes: 1000)])
        XCTAssertEqual(try XCTUnwrap(recorder.snapshot()?.runTransferredBytes).download, 1550)
        XCTAssertEqual(recorder.snapshot()?.phases.first?.measuredBytes, 1000)
    }
}


extension SpeedtestV6ContractTests {
    func testRejectedOrMalformedSubmissionStaysDurableUntilAcknowledged() async throws {
        let previousUser = LocalAccountScope.currentUserId
        LocalAccountScope.deactivate()
        defer { if let previousUser { LocalAccountScope.activate(userId: previousUser) } }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("unit-test-session")
        let cache = DiskCache(folderName: "SpeedtestV6NetworkTest-\(UUID().uuidString)", evicts: false)
        let store = DiskCacheSpeedtestPendingStore(cache: cache, key: "pending")
        let service = SpeedtestService(api: APIClient(config: .test, credentials: credentials, session: URLSession(configuration: config)),
            historyCache: cache, pendingCache: cache, guestReceiptStore: GuestSpeedtestReceiptStore(store: InMemoryTokenStore()), pendingStore: store)
        let result = SpeedtestRunResult(label: "queued", downloadMbps: 100, downloadAverageMbps: 100,
            downloadMaxMbps: 100, downloadP90Mbps: 100, durationSeconds: 10, connectionType: .wifi,
            methodologyVersion: 6, ownerScopeId: LocalAccountScope.currentOwnerScopeId)
        defer { MockURLProtocol.requestHandler = nil }
        for (status, body) in [(500, "{\"success\":true,\"id\":\"server-id\"}"),
                               (200, "{\"success\":false,\"id\":\"server-id\"}"),
                               (200, "{\"success\":true}"),
                               (200, "{\"success\":true,\"id\":\"   \"}")] {
            MockURLProtocol.requestHandler = { request in
                XCTAssertEqual(request.url?.path, "/api/speedtests")
                return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            do {
                try await service.save(result, streams: 4)
                XCTFail("Status \(status) / \(body) must not acknowledge the durable submission")
            } catch { }
            let pending = await store.loadAll()
            XCTAssertEqual(pending.map(\.id), [result.id.uuidString])
            let serverID = await service.serverId(forClientId: result.id)
            XCTAssertNil(serverID)
        }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
             Data("{\"success\":true,\"id\":\"server-id\"}".utf8))
        }
        try await service.save(result, streams: 4)
        let remaining = await store.loadAll()
        XCTAssertTrue(remaining.isEmpty)
        let savedID = await service.serverId(forClientId: result.id)
        XCTAssertEqual(savedID, "server-id")
    }
}


extension SpeedtestV6ContractTests {
    func testIPerfServerReceiptUsesItsOwnDurationAndPreservesZero() throws {
        let data = Data("{\"streams\":[{\"bytes\":80000000,\"start_time\":0,\"end_time\":10}]}".utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let server = try XCTUnwrap(iperf3ExtractServerMeasurement(from: json))
        let result = iperf3SelectMeasurement(clientBytes: 100_000_000, clientDuration: 8, wallDuration: 11, isDownload: false, server: server)
        XCTAssertEqual(result.averageMbps, 64, accuracy: 0.001)
        XCTAssertEqual(result.measuredDuration, 10)
        XCTAssertEqual(result.clientDuration, 8)
        XCTAssertTrue(result.serverBytesUsed)
        XCTAssertNil(result.finalServerMeasurement?.maxMbps)
        let zero = iperf3SelectMeasurement(clientBytes: 100_000_000, clientDuration: 8, wallDuration: 11,
            isDownload: false, server: .init(bytes: 0, duration: 10))
        XCTAssertEqual(zero.measuredBytes, 0)
        XCTAssertEqual(zero.averageMbps, 0)
        XCTAssertTrue(zero.serverBytesUsed, "Confirmed zero must not silently become positive client bytes labeled server-received")
        let incomplete = iperf3ExtractServerMeasurement(from: ["streams": [["bytes": 80_000_000]]])
        XCTAssertNil(incomplete)
        let fallback = iperf3SelectMeasurement(clientBytes: 100_000_000, clientDuration: 8, wallDuration: 11, isDownload: false, server: incomplete)
        XCTAssertFalse(fallback.serverBytesUsed)
        XCTAssertEqual(fallback.averageMbps, 100, accuracy: 0.001)
        let legacy = iperf3ExtractServerMeasurement(from: ["end": ["sum_received": ["bytes": 80_000_000, "seconds": 10.0]]])
        XCTAssertEqual(legacy, server)
        XCTAssertNil(iperf3ExtractServerMeasurement(from: ["end": ["sum_received": ["bytes": 80_000_000, "seconds": Double.infinity]]]))
    }

    func testMigrationFailureKeepsJSONAndRollsBackThenRetries() async throws {
        guard #available(iOS 17, *) else { throw XCTSkip("SwiftData requires iOS 17") }
        enum Injected: Error { case diskFull }
        let cache = DiskCache(folderName: "SpeedtestV6Migration-\(UUID().uuidString)", evicts: false)
        let key = "legacy"
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let result = SpeedtestRunResult(label: "legacy", downloadMbps: 100, downloadAverageMbps: 100,
            downloadMaxMbps: 100, durationSeconds: 10, connectionType: .wifi, createdAt: timestamp)
        let pending = PendingSpeedtestSave(id: result.id.uuidString, result: result, streams: 1,
            deviceModel: "test", createdAt: timestamp, isVisibleOnMap: false, shareExactLocation: false,
            guestDeleteToken: nil, driveSessionId: nil, ownerScopeId: nil)
        try await cache.write([pending], for: key)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpeedtestV6Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("pending.store")
        let failing = try XCTUnwrap(SwiftDataSpeedtestPendingStore(storeURL: url, legacyCache: cache, legacyKey: key,
            beforeMigrationSave: { throw Injected.diskFull }))
        let failed = await failing.loadAll()
        XCTAssertTrue(failed.isEmpty, "Rolled-back rows cannot appear durable")
        let source = try await cache.read([PendingSpeedtestSave].self, for: key)
        XCTAssertEqual(source, [pending], "Failed migration must preserve its recoverable source")
        let recovering = try XCTUnwrap(SwiftDataSpeedtestPendingStore(storeURL: url, legacyCache: cache, legacyKey: key))
        let recovered = await recovering.loadAll()
        XCTAssertEqual(recovered, [pending])
        let removed = try await cache.read([PendingSpeedtestSave].self, for: key)
        XCTAssertNil(removed)
        let repeated = await recovering.loadAll()
        XCTAssertEqual(repeated.count, 1)
        XCTAssertNil(repeated.first?.ownerScopeId)
    }

    private func testToken(user: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["userId": user, "exp": Int(Date().timeIntervalSince1970) + 3600])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    func testOwnerTokenMismatchNeverReachesPostAndPrivateDetailsUseCapturedOwner() async throws {
        let previousUser = LocalAccountScope.currentUserId
        LocalAccountScope.activate(userId: "v6-owner-a")
        defer {
            MockURLProtocol.requestHandler = nil
            if let previousUser { LocalAccountScope.activate(userId: previousUser) } else { LocalAccountScope.deactivate() }
        }
        let tokenA = try testToken(user: "v6-owner-a")
        let tokenB = try testToken(user: "v6-owner-b")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken(tokenB) // Login installed B's token before activate(B).
        let cache = DiskCache(folderName: "SpeedtestV6Owner-\(UUID().uuidString)", evicts: false)
        let store = DiskCacheSpeedtestPendingStore(cache: cache, key: "pending")
        let service = SpeedtestService(api: APIClient(config: .test, credentials: credentials, session: URLSession(configuration: config)),
            historyCache: cache, pendingCache: cache, guestReceiptStore: GuestSpeedtestReceiptStore(store: InMemoryTokenStore()), pendingStore: store)
        let result = SpeedtestRunResult(label: "owner-a", downloadMbps: 100, downloadAverageMbps: 100,
            downloadMaxMbps: 100, durationSeconds: 10, connectionType: .wifi, ownerScopeId: "user:v6-owner-a")
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Mismatched token must not reach the transport")
            throw APIError.missingAuthToken
        }
        do { try await service.save(result); XCTFail("Mismatched token accepted") } catch { }
        let pending = await store.loadAll()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.ownerScopeId, "user:v6-owner-a")
        try credentials.setAccessToken(tokenA)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth_token=\(tokenA)")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{\"id\":\"private-test\",\"isVisibleOnMap\":false}".utf8))
        }
        let detail = try await service.details(id: "private-test")
        XCTAssertEqual(detail.id, "private-test")
        MockURLProtocol.requestHandler = { request in
            try credentials.setAccessToken(tokenB)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{\"id\":\"private-test\"}".utf8))
        }
        do { _ = try await service.details(id: "private-test"); XCTFail("Response survived token owner change") } catch { }
    }
}


extension SpeedtestV6ContractTests {
    func testUploadWarmupIsNotDisplayedAndUsefulWindowStartsWithoutWarmupBytes() {
        let sampler = SpeedtestPhaseLiveSampler(showsWarmupRate: false)
        let trafficBefore = SpeedtestDataMeter.shared.bytes
        for tick in 1...20 {
            XCTAssertEqual(sampler.observeWarmup(totalBytes: tick * 5_943_750, elapsedMs: Double(tick) * 150), 0)
        }
        // 317 Mbps of local warmup writes must not pollute the first useful 62 Mbps.
        XCTAssertEqual(sampler.observeUseful(totalBytes: 1_162_500, elapsedMs: 150), 62, accuracy: 0.001)
        XCTAssertEqual(sampler.observeUseful(totalBytes: 7_750_000, elapsedMs: 1000), 62, accuracy: 0.001)
        XCTAssertEqual(SpeedtestDataMeter.shared.bytes - trafficBefore, 118_875_000 + 7_750_000)
    }

    func testDownloadWarmupCanDisplayRateButNeverEntersUsefulWindow() {
        let sampler = SpeedtestPhaseLiveSampler(showsWarmupRate: true)
        XCTAssertEqual(sampler.observeWarmup(totalBytes: 39_625_000, elapsedMs: 1000), 317, accuracy: 0.001)
        XCTAssertEqual(sampler.observeUseful(totalBytes: 1_162_500, elapsedMs: 150), 62, accuracy: 0.001)
        sampler.reset()
        XCTAssertEqual(sampler.observeWarmup(totalBytes: 125_000_000, elapsedMs: 1000), 1000, accuracy: 0.001)
        XCTAssertEqual(sampler.observeUseful(totalBytes: 468_750, elapsedMs: 150), 25, accuracy: 0.001)
    }

    func testUsefulLiveRemainsRecentThroughputAfterWarmup() {
        let sampler = SpeedtestPhaseLiveSampler(showsWarmupRate: false, smoothing: 1)
        _ = sampler.observeWarmup(totalBytes: 100_000_000, elapsedMs: 1000)
        _ = sampler.observeUseful(totalBytes: 7_750_000, elapsedMs: 1000)
        // The second useful second is 100 Mbps, though the cumulative mean is 81.
        XCTAssertEqual(sampler.observeUseful(totalBytes: 20_250_000, elapsedMs: 2000), 100, accuracy: 0.001)
        XCTAssertEqual(sampler.observeUseful(totalBytes: 20_250_000, elapsedMs: 3000), 0, accuracy: 0.001)
    }
}
