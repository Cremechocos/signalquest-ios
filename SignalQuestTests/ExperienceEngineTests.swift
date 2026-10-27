import XCTest
@testable import SignalQuest

/// Le moteur v3 contre un faux edge : chaque transfert avance une horloge virtuelle (aucun
/// réseau, aucune attente réelle). Mêmes cas que `ExperienceEngineTest.kt` d'Android.
final class ExperienceEngineTests: XCTestCase {

    // MARK: Horloge et faux edge

    final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 1_000_000_000
        private var waiters: [(deadline: Int64, continuation: CheckedContinuation<Void, Never>)] = []

        var nanos: Int64 { lock.withLock { value } }
        var ms: Int64 { nanos / 1_000_000 }

        func advance(ms: Int64) {
            let due: [CheckedContinuation<Void, Never>] = lock.withLock {
                value += ms * 1_000_000
                let due = waiters.filter { $0.deadline <= value }.map(\.continuation)
                waiters.removeAll { $0.deadline <= value }
                return due
            }
            due.forEach { $0.resume() }
        }

        /// Attend que d'autres (les sondes) aient avancé l'horloge jusqu'à `deadline`.
        func wait(until deadline: Int64) async {
            await withCheckedContinuation { continuation in
                let now: Bool = lock.withLock {
                    guard value < deadline else { return true }
                    waiters.append((deadline, continuation))
                    return false
                }
                if now { continuation.resume() }
            }
        }
    }

    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            let all: [CheckedContinuation<Void, Never>] = lock.withLock {
                isOpen = true
                defer { waiters = [] }
                return waiters
            }
            all.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let open: Bool = lock.withLock {
                    if !isOpen { waiters.append(continuation) }
                    return isOpen
                }
                if open { continuation.resume() }
            }
        }
    }

    final class FakeEdge: ExperienceTransport, @unchecked Sendable {
        let clock: VirtualClock
        /// Durée virtuelle d'un transfert (n° d'appel HTTP dans l'ordre, chemin, octets).
        let transferMs: @Sendable (Int, String, Int64) -> Int64
        let status: @Sendable (String) -> Int
        /// RTT en nanosecondes selon le rang de la sonde (0 = chauffe) ; nil = échec.
        let tcp: @Sendable (Int) async -> Int64?
        /// Les transferts attendent que l'horloge (avancée par les sondes) les rattrape.
        let followClock: Bool

        private let lock = NSLock()
        private(set) var httpCalls = 0
        private var probeIndex = 0
        private var probesInFlight = 0

        init(clock: VirtualClock, followClock: Bool = false,
             transferMs: @escaping @Sendable (Int, String, Int64) -> Int64,
             status: @escaping @Sendable (String) -> Int = { _ in 200 },
             tcp: @escaping @Sendable (Int) async -> Int64? = { _ in 40_000_000 }) {
            self.clock = clock
            self.followClock = followClock
            self.transferMs = transferMs
            self.status = status
            self.tcp = tcp
        }

        var probes: Int { lock.withLock { probeIndex } }
        var inFlight: Int { lock.withLock { probesInFlight } }

        private func transfer(_ path: String, _ size: Int64, timeoutMs: Int64, shouldStop: @Sendable () -> Bool,
                              onBytes: @Sendable (Int) -> Void) async -> (ExperienceFetch, Int64) {
            let call: Int = lock.withLock { defer { httpCalls += 1 }; return httpCalls }
            let code = status(path)
            guard (200...299).contains(code) else { return (.failed(.http(code)), 0) }
            let wanted = transferMs(call, path, size)
            let ms = min(wanted, timeoutMs)
            if followClock { await clock.wait(until: clock.nanos + ms * 1_000_000) } else { clock.advance(ms: ms) }
            var left = wanted > timeoutMs ? size * timeoutMs / max(1, wanted) : size
            while left > 0 {
                let chunk = Int(min(left, 65_536))
                onBytes(chunk)
                left -= Int64(chunk)
            }
            if shouldStop() { return (.stopped, 0) }
            return (wanted > timeoutMs ? .timedOut : .done, ms * 1_000_000)
        }

        func download(bytes: Int64, timeoutMs: Int64, shouldStop: @escaping @Sendable () -> Bool,
                      onRead: @escaping @Sendable (Int) -> Void) async -> ExperienceFetch {
            await transfer("/__down", bytes, timeoutMs: timeoutMs, shouldStop: shouldStop, onBytes: onRead).0
        }

        func upload(bytes: Int64, timeoutMs: Int64, shouldStop: @escaping @Sendable () -> Bool,
                    onWrite: @escaping @Sendable (Int) -> Void) async -> (fetch: ExperienceFetch, nanos: Int64) {
            let sent = await transfer("/__up", bytes, timeoutMs: timeoutMs, shouldStop: shouldStop, onBytes: onWrite)
            return (sent.0, sent.0 == .done ? sent.1 : 0)
        }

        func openPage(timeoutMs: Int64, shouldStop: @escaping @Sendable () -> Bool,
                      onRead: @escaping @Sendable (Int) -> Void) async -> ExperiencePageFetch {
            let startedAt = clock.nanos
            let document = await transfer("/__down", ExperienceMethod.webDocumentBytes, timeoutMs: timeoutMs,
                                          shouldStop: shouldStop, onBytes: onRead).0
            guard document == .done else { return ExperiencePageFetch(fetch: document, protocolName: "h2") }
            let rest = ExperienceMethod.webPageBytes - ExperienceMethod.webDocumentBytes
            let part = rest / Int64(ExperienceMethod.webParallelRequests)
            for index in 0..<ExperienceMethod.webParallelRequests {
                let size = index == ExperienceMethod.webParallelRequests - 1 ? rest - part * Int64(index) : part
                let fetch = await transfer("/__down", size, timeoutMs: timeoutMs, shouldStop: shouldStop, onBytes: onRead).0
                if fetch != .done { return ExperiencePageFetch(fetch: fetch, protocolName: "h2") }
            }
            var times = ExperienceWebPhases.Times()
            times.dnsStart = 0
            times.dnsEnd = 12_000_000
            times.connectStart = 12_000_000
            times.connectEnd = 40_000_000
            times.secureStart = 20_000_000
            times.secureEnd = 40_000_000
            times.requestStart = 40_000_000
            times.responseStart = 70_000_000
            return ExperiencePageFetch(fetch: .done, times: times, totalNanos: UInt64(clock.nanos - startedAt), protocolName: "h2")
        }

        func resolveHost() async -> String? { "192.0.2.1" }

        func tcpProbe(address: String, timeoutMs: Int64) async -> Int64? {
            let index: Int = lock.withLock {
                probesInFlight += 1
                defer { probeIndex += 1 }
                return probeIndex
            }
            let rtt = await tcp(index)
            lock.withLock { probesInFlight -= 1 }
            return rtt
        }
    }

    private let recent = ExperienceUnderLoad(idleMs: 20, loadedDownMs: 40, loadedUpMs: 50, grade: "B", deltaMs: 30, source: .recentSpeedtest)

    private func engine(
        _ edge: FakeEdge,
        conditions: ExperienceConditions = ExperienceConditions(),
        reuseRecent: Bool = true,
        onSleep: @escaping @Sendable () -> Void = {}
    ) -> ExperienceEngine {
        let clock = edge.clock
        return ExperienceEngine(
            transport: edge, conditions: conditions, recentLatency: reuseRecent ? recent : nil,
            nowNanos: { clock.nanos },
            sleep: { ms in
                clock.advance(ms: ms)
                onSleep()
                // Les sondes lancées finissent avant le créneau suivant, comme sur un vrai réseau.
                for _ in 0..<200 where edge.inFlight > 0 { await Task.yield() }
                for _ in 0..<5 { await Task.yield() }
            }
        )
    }

    private func rate(_ bps: Double) -> @Sendable (Int, String, Int64) -> Int64 {
        { _, _, size in Int64(Double(size) * 8 / bps * 1_000) }
    }

    private func highlights(_ tests: ExperienceTestsResult) throws -> ExperienceHighlights {
        let submission = ExperienceSubmission(
            clientSubmissionId: UUID(), appVersion: "1.0 (180)", measuredAt: Date(), durationMs: 1, bytesUsed: 1,
            network: .init(connectionType: "wifi"), location: nil, tests: tests
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: submission.body()) as? [String: Any])
        let sent = try JSONSerialization.data(withJSONObject: try XCTUnwrap(body["tests"]))
        return ExperienceHighlights(tests: try JSONDecoder().decode([String: JSONValue].self, from: sent))
    }

    // MARK: Vidéo

    func testLadderOnAFastNetworkHoldsFiveRungsWithExactBytes() async throws {
        let edge = FakeEdge(clock: VirtualClock(), transferMs: rate(200e6))
        let run = await engine(edge).run([.videoLadder])
        let ladder = try XCTUnwrap(run.tests.videoLadder)
        XCTAssertEqual(ladder.state, .measured)
        XCTAssertEqual(ladder.rungs.count, 5)
        XCTAssertTrue(ladder.rungs.allSatisfy { $0.state == .measured && $0.stalls.isEmpty })
        XCTAssertEqual(run.bytesUsed, ExperienceMethod.ladderMaxBytes)
        XCTAssertEqual(try highlights(run.tests).videoMaxQuality, "2160p")
        XCTAssertNil(run.stop)
        XCTAssertNil(run.tests.videoAdaptive)
    }

    func testALadderRungThatStallsIsAbandonedAndTheLadderStops() async throws {
        // 2160p (segments de 5 Mo) : 10 s par segment, le 2e arrive après plus de 6 s de tampon vide.
        let slowAbove: @Sendable (Int, String, Int64) -> Int64 = { _, _, size in size >= 5_000_000 ? 10_000 : size * 8 / 200_000 }
        let run = await engine(FakeEdge(clock: VirtualClock(), transferMs: slowAbove)).run([.videoLadder])
        let ladder = try XCTUnwrap(run.tests.videoLadder)
        XCTAssertEqual(ladder.state, .measured)
        let last = try XCTUnwrap(ladder.rungs.last)
        XCTAssertEqual(last.quality, .p2160)
        XCTAssertEqual(last.state, .abandoned)
        XCTAssertFalse(last.stalls.isEmpty)
        XCTAssertEqual(try highlights(run.tests).videoMaxQuality, "1440p")
    }

    func testAStallMidLadderLeavesTheHigherRungsNotTested() async throws {
        // 1080p (1,5 Mo) : 4 s par segment, soit 2 s de coupure à chaque fois sans dépasser 6 s.
        let slowFrom1080: @Sendable (Int, String, Int64) -> Int64 = { _, _, size in size >= 1_500_000 ? 4_000 : size * 8 / 200_000 }
        let run = await engine(FakeEdge(clock: VirtualClock(), transferMs: slowFrom1080)).run([.videoLadder])
        let rungs = try XCTUnwrap(run.tests.videoLadder?.rungs)
        XCTAssertEqual(rungs.map(\.state), [.measured, .measured, .measured, .notTested, .notTested])
        XCTAssertFalse(rungs[2].stalls.isEmpty, "1080p tenu jusqu'au bout, mais avec des coupures")
        XCTAssertEqual(try highlights(run.tests).videoMaxQuality, "720p")
    }

    func testAdaptiveWaitOverSixSecondsFailsAndKeepsPartialValues() async throws {
        // 1er segment en 0,5 s ; le 2e mettrait 10 s : coupé quand l'attente atteint 6 s.
        let delays: @Sendable (Int, String, Int64) -> Int64 = { call, _, _ in call == 0 ? 500 : 10_000 }
        let run = await engine(FakeEdge(clock: VirtualClock(), transferMs: delays)).run([.videoAdaptive])
        let adaptive = try XCTUnwrap(run.tests.videoAdaptive)
        XCTAssertEqual(adaptive.state, .failed)
        XCTAssertNil(adaptive.reason)
        XCTAssertNil(adaptive.score)
        XCTAssertEqual(adaptive.playbackMs, 2_000)
        XCTAssertEqual(adaptive.startupMs, 500)
        XCTAssertEqual(adaptive.stalls, [ExperienceStall(atPlaybackMs: 2_000, waitMs: 6_000)])
        XCTAssertNil(run.stop)
        XCTAssertNil(try highlights(run.tests).videoScore, "un test en échec ne publie pas de note")
    }

    func testAdaptiveFullPlaybackLastsThirtySecondsWithAScore() async throws {
        let run = await engine(FakeEdge(clock: VirtualClock(), transferMs: rate(100e6))).run([.videoAdaptive])
        let adaptive = try XCTUnwrap(run.tests.videoAdaptive)
        XCTAssertEqual(adaptive.state, .measured)
        XCTAssertEqual(adaptive.playbackMs, 30_000)
        XCTAssertEqual(adaptive.timeByQualityMs.values.reduce(0, +), 30_000)
        let score = try XCTUnwrap(adaptive.score)
        XCTAssertEqual(score.total, score.quality + score.smoothness + score.startup)
        XCTAssertLessThanOrEqual(run.bytesUsed, ExperienceMethod.adaptiveMaxBytes)
    }

    func testAdaptiveGoingToBackgroundIsInterruptedWithoutScore() async throws {
        let clock = VirtualClock()
        let startMs = clock.ms
        let conditions = ExperienceConditions(isForeground: { clock.ms - startMs < 3_000 })
        let run = await engine(FakeEdge(clock: clock, transferMs: rate(100e6)), conditions: conditions).run([.videoAdaptive])
        let adaptive = try XCTUnwrap(run.tests.videoAdaptive)
        XCTAssertEqual(adaptive.state, .interrupted)
        XCTAssertEqual(adaptive.reason, .background)
        XCTAssertNil(adaptive.score)
        XCTAssertEqual(run.stop, .background)
        XCTAssertTrue((1...29_999).contains(try XCTUnwrap(adaptive.playbackMs)))
    }

    // MARK: Arrêt, ordre, bout en bout

    func testStopBeforeLaunchLeavesEverythingNotTestedWithTheReason() async throws {
        let engine = engine(FakeEdge(clock: VirtualClock(), transferMs: rate(100e6)))
        engine.requestStop(.userStopped)
        let run = await engine.run([.videoLadder, .upload])
        XCTAssertEqual(run.tests.videoLadder, ExperienceLadderResult(state: .notTested, reason: .userStopped))
        XCTAssertEqual(run.tests.upload, ExperienceUploadResult(state: .notTested, reason: .userStopped))
        XCTAssertEqual(run.bytesUsed, 0)
        XCTAssertNil(run.tests.webPage)
    }

    func testFullSuiteRunsInOrderAndWritesAValidBody() async throws {
        let order = OrderLog()
        let run = await engine(FakeEdge(clock: VirtualClock(), transferMs: rate(100e6)))
            .run(Set(ExperienceTestKind.allCases)) { order.note($0.test) }
        XCTAssertEqual(order.tests, ExperienceMethod.order)
        for kind in ExperienceTestKind.allCases { XCTAssertEqual(run.tests.state(of: kind), .measured, kind.rawValue) }
        XCTAssertNil(run.stop)
        XCTAssertGreaterThan(run.bytesUsed, 0)
        XCTAssertLessThanOrEqual(run.bytesUsed, ExperienceBudget.maxBytes(Set(ExperienceTestKind.allCases), recentLatencyReused: true))
        let submission = ExperienceSubmission(
            clientSubmissionId: UUID(), appVersion: "1.0 (180)", measuredAt: Date(), durationMs: run.durationMs,
            bytesUsed: run.bytesUsed, network: .init(connectionType: "wifi"), location: nil, tests: run.tests
        )
        let body = try submission.body()
        XCTAssertLessThanOrEqual(body.count, ExperienceMethod.maxBodyBytes)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("\"cap\""))
    }

    func testUsagePerTestSumsToTheTotal() async throws {
        let run = await engine(FakeEdge(clock: VirtualClock(), transferMs: rate(100e6))).run(Set(ExperienceTestKind.allCases))
        XCTAssertEqual(Set(run.usage.keys), Set(ExperienceTestKind.allCases))
        XCTAssertEqual(run.usage.values.reduce(0) { $0 + $1.bytes }, run.bytesUsed)
        XCTAssertEqual(run.usage[.videoLadder]?.bytes, ExperienceMethod.ladderMaxBytes)
        XCTAssertEqual(run.usage[.upload]?.bytes, 35_000_000)
        XCTAssertTrue(run.usage.values.allSatisfy { $0.durationMs > 0 })
    }

    // MARK: Web

    func testWebOpensThreeTimesTwoPointThreeMegabytesEach() async throws {
        let run = await engine(FakeEdge(clock: VirtualClock(), transferMs: rate(80e6))).run([.webPage])
        let web = try XCTUnwrap(run.tests.webPage)
        XCTAssertEqual(web.state, .measured)
        XCTAssertEqual(web.openings.count, 3)
        XCTAssertEqual(web.pageBytes, ExperienceMethod.webPageBytes)
        XCTAssertEqual(web.parallelRequests, 6)
        XCTAssertEqual(run.bytesUsed, 3 * ExperienceMethod.webPageBytes)
        XCTAssertTrue(web.openings.allSatisfy { $0.measured && $0.totalMs != nil && $0.freshConnection == true })
        XCTAssertEqual(web.openings.first?.dnsMs, 12)
        XCTAssertEqual(web.openings.first?.protocolName, "h2")
    }

    func testWebRedirectFailsAsRouteChangedAfterOneOpening() async throws {
        let edge = FakeEdge(clock: VirtualClock(), transferMs: rate(80e6), status: { _ in 302 })
        let run = await engine(edge).run([.webPage])
        let web = try XCTUnwrap(run.tests.webPage)
        XCTAssertEqual(web.state, .failed)
        XCTAssertEqual(web.openings.count, 1)
        XCTAssertEqual(web.openings.first?.measured, false)
        XCTAssertEqual(run.failures[.webPage], .routeChanged)
        XCTAssertEqual(edge.httpCalls, 1)
    }

    // MARK: Jeu et appels

    func testGameWarmUpProbeIsCountedNowhere() async throws {
        // La chauffe répond en 900 ms ; elle n'apparaît ni dans la série ni dans le maximum.
        let edge = FakeEdge(clock: VirtualClock(), transferMs: rate(100e6), tcp: { $0 == 0 ? 900_000_000 : 40_000_000 })
        let run = await engine(edge).run([.gameAndCalls])
        let game = try XCTUnwrap(run.tests.gameAndCalls)
        XCTAssertEqual(game.state, .measured)
        XCTAssertEqual(game.probeMethod, "tcp_connect")
        XCTAssertEqual(edge.probes, 301)
        XCTAssertEqual(game.series.count, 300)
        XCTAssertEqual(game.medianMs, 40)
        XCTAssertEqual(game.maxMs, 40)
        XCTAssertEqual(game.jitterMs, 0)
        XCTAssertEqual(game.spikeCount, 0)
        XCTAssertEqual(game.underLoad?.source, .recentSpeedtest)
    }

    func testGameFailedProbesCountAsSentWithAFiftyPercentFloor() async throws {
        func play(failures: Int) async throws -> ExperienceGameResult {
            let edge = FakeEdge(clock: VirtualClock(), transferMs: rate(100e6), tcp: { (1...failures).contains($0) ? nil : 40_000_000 })
            let run = await engine(edge).run([.gameAndCalls])
            return try XCTUnwrap(run.tests.gameAndCalls)
        }
        let exactlyHalf = try await play(failures: 150)
        XCTAssertEqual(exactlyHalf.state, .measured)
        XCTAssertEqual(exactlyHalf.series.count, 150)
        let underHalf = try await play(failures: 151)
        XCTAssertEqual(underHalf.state, .failed)
        XCTAssertEqual(underHalf.series.count, 149, "les sondes réussies restent montrées")
        XCTAssertNil(underHalf.medianMs)
        XCTAssertNil(underHalf.jitterMs)
        XCTAssertEqual(underHalf.probeMethod, "tcp_connect")
        let nothing = try await play(failures: 300)
        XCTAssertEqual(nothing.state, .failed)
        XCTAssertTrue(nothing.series.isEmpty)
    }

    func testGameKeepsAtMostTwoProbesInFlightAndSkippedSlotsAreNotSent() async throws {
        let clock = VirtualClock()
        let gate = Gate()
        let startMs = clock.ms
        // Les sondes 1 et 2 restent en vol jusqu'à 500 ms d'horloge virtuelle.
        let edge = FakeEdge(clock: clock, transferMs: rate(100e6), tcp: { index in
            if (1...2).contains(index) { await gate.wait() }
            return 40_000_000
        })
        let run = await engine(edge, onSleep: { if clock.ms - startMs >= 500 { gate.open() } }).run([.gameAndCalls])
        let game = try XCTUnwrap(run.tests.gameAndCalls)
        XCTAssertEqual(game.state, .measured)
        // Créneaux 200 à 400 ms sautés : ni envoyés ni échoués.
        XCTAssertEqual(edge.probes - 1, 297)
        XCTAssertEqual(game.series.count, 297)
    }

    func testRefusedDownloadLoadInventsNoDownLatencyButKeepsUp() async throws {
        let edge = FakeEdge(clock: VirtualClock(), followClock: true, transferMs: { _, _, _ in 5_000 },
                            status: { $0 == "/__down" ? 429 : 200 })
        let run = await engine(edge, reuseRecent: false).run([.gameAndCalls])
        let game = try XCTUnwrap(run.tests.gameAndCalls)
        XCTAssertEqual(game.state, .measured)
        let underLoad = try XCTUnwrap(game.underLoad)
        XCTAssertEqual(underLoad.source, .shortLoad)
        XCTAssertNil(underLoad.loadedDownMs)
        XCTAssertEqual(underLoad.loadedUpMs, 40)
        XCTAssertTrue(run.failures.isEmpty, "un test mesuré n'a pas de cause d'échec")
    }

    func testNoAcceptedLoadGivesNoUnderLoadLatency() async throws {
        let edge = FakeEdge(clock: VirtualClock(), followClock: true, transferMs: { _, _, _ in 5_000 }, status: { _ in 429 })
        let run = await engine(edge, reuseRecent: false).run([.gameAndCalls])
        let game = try XCTUnwrap(run.tests.gameAndCalls)
        XCTAssertEqual(game.state, .measured)
        XCTAssertNil(game.underLoad)
        XCTAssertNotNil(game.medianMs)
    }

    // MARK: Envoi

    func testUploadSendsPhotoThenVideoTimedToTheServerResponse() async throws {
        let run = await engine(FakeEdge(clock: VirtualClock(), transferMs: rate(40e6))).run([.upload])
        let upload = try XCTUnwrap(run.tests.upload)
        XCTAssertEqual(upload.state, .measured)
        XCTAssertEqual(upload.items, [
            ExperienceUploadItem(kind: .photo, bytes: 5_000_000, totalMs: 1_000),
            ExperienceUploadItem(kind: .video, bytes: 30_000_000, totalMs: 6_000)
        ])
        XCTAssertEqual(run.bytesUsed, 35_000_000)
        XCTAssertEqual(try highlights(run.tests).uploadPhotoMs, 1_000)
    }

    func testUploadServerErrorFailsWithoutInventedItemsButTriesTheVideo() async throws {
        let edge = FakeEdge(clock: VirtualClock(), transferMs: rate(40e6), status: { _ in 500 })
        let run = await engine(edge).run([.upload])
        XCTAssertEqual(run.tests.upload, ExperienceUploadResult(state: .failed))
        XCTAssertEqual(run.failures[.upload], .generic)
        XCTAssertEqual(edge.httpCalls, 2)
    }

    func testUploadServerBusyDoesNotGoOnToTheVideo() async throws {
        let edge = FakeEdge(clock: VirtualClock(), transferMs: rate(40e6), status: { _ in 429 })
        let run = await engine(edge).run([.upload])
        XCTAssertEqual(run.tests.upload?.state, .failed)
        XCTAssertEqual(run.failures[.upload], .serverBusy)
        XCTAssertEqual(edge.httpCalls, 1)
    }

    // MARK: Causes d'échec

    func testLadderServerBusyFailsOnceWithoutRetry() async throws {
        let edge = FakeEdge(clock: VirtualClock(), transferMs: rate(200e6), status: { _ in 429 })
        let run = await engine(edge).run([.videoLadder])
        XCTAssertEqual(run.tests.videoLadder?.state, .failed)
        XCTAssertEqual(run.failures[.videoLadder], .serverBusy)
        XCTAssertEqual(edge.httpCalls, 1, "pas de réessai en boucle")
        XCTAssertEqual(run.bytesUsed, 0)
        XCTAssertNil(run.stop)
    }

    func testFailureCausesOnlyForFailedTests() async throws {
        let edge = FakeEdge(clock: VirtualClock(), transferMs: rate(80e6), status: { $0 == "/__up" ? 429 : 200 })
        let run = await engine(edge).run([.webPage, .upload])
        XCTAssertEqual(run.tests.webPage?.state, .measured)
        XCTAssertEqual(Set(run.failures.keys), [.upload])
    }

    func testHTTPStatusesMapToCauses() {
        XCTAssertEqual(ExperienceFailureCause.http(429), .serverBusy)
        XCTAssertEqual(ExperienceFailureCause.http(301), .routeChanged)
        XCTAssertEqual(ExperienceFailureCause.http(307), .routeChanged)
        XCTAssertEqual(ExperienceFailureCause.http(500), .generic)
        XCTAssertEqual(ExperienceFailureCause.http(403), .generic)
    }

    func testOfflineDuringATransferInterruptsTheSuite() async throws {
        let clock = VirtualClock()
        let startMs = clock.ms
        // Hors ligne après 1 s : l'envoi échoue, la suite s'arrête, le reste n'est pas testé.
        let online: @Sendable () -> Bool = { clock.ms - startMs < 1_000 }
        let edge = FakeEdge(clock: clock, transferMs: rate(40e6), status: { _ in online() ? 200 : 500 })
        let run = await engine(edge, conditions: ExperienceConditions(isOnline: online)).run([.upload])
        XCTAssertEqual(run.tests.upload?.state, .interrupted)
        XCTAssertEqual(run.tests.upload?.reason, .offline)
        XCTAssertEqual(run.tests.upload?.items.count, 1)
        XCTAssertEqual(run.stop, .offline)
    }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [ExperienceTestKind] = []
    func note(_ test: ExperienceTestKind) { lock.withLock { if list.last != test { list.append(test) } } }
    var tests: [ExperienceTestKind] { lock.withLock { list } }
}
