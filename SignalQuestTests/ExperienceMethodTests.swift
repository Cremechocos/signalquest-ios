import XCTest
@testable import SignalQuest

/// Lot F10a : le cœur pur de la méthode `experience-v3`. Les cas de lecture, de
/// note, de jeu et de phases web reprennent ceux d'Android, pour que les deux apps
/// mesurent pareil ; le corps envoyé suit le contrat `experience-tests-v1`.
final class ExperienceMethodTests: XCTestCase {
    private func ms(_ value: Int64) -> Int64 { value * 1_000_000 }

    // MARK: Lecture simulée

    func testSegmentsArrivingEarlyNeverStall() {
        var model = ExperiencePlaybackModel()
        for at: Int64 in [0, 500, 1_000, 1_500, 2_000] { model.onSegment(at: ms(at)) }
        XCTAssertTrue(model.stalls.isEmpty)
        XCTAssertEqual(model.bufferMinMs, 1_500, "2 s − 0,5 s au 2ᵉ segment")
        XCTAssertEqual(model.segmentCount, 5)
    }

    func testALateSegmentStallsAtThePlaybackPosition() {
        var model = ExperiencePlaybackModel()
        model.onSegment(at: ms(0))
        model.onSegment(at: ms(1_000))
        model.onSegment(at: ms(5_000))
        XCTAssertEqual(model.stalls, [ExperienceStall(atPlaybackMs: 4_000, waitMs: 1_000)])
        XCTAssertEqual(model.bufferMinMs, 0)
    }

    func testWaitingAndPendingStall() {
        var model = ExperiencePlaybackModel()
        model.onSegment(at: ms(0))
        XCTAssertNil(model.bufferMinMs, "un seul segment")
        XCTAssertEqual(model.waitingNanos(at: ms(1_500)), 0)
        XCTAssertNil(model.pendingStall(at: ms(1_500)))
        XCTAssertEqual(model.waitingNanos(at: ms(6_000)), ms(4_000))
        XCTAssertEqual(model.pendingStall(at: ms(6_000)), ExperienceStall(atPlaybackMs: 2_000, waitMs: 4_000))
        XCTAssertEqual(model.drainsAt, ms(2_000))
    }

    func testAverageBufferIsWeightedByTime() {
        var model = ExperiencePlaybackModel()
        model.onSegment(at: ms(0))
        model.onSegment(at: ms(0))
        XCTAssertEqual(model.bufferAvgMs(), 2_000)
    }

    // MARK: Lecteur adaptatif et note

    func testAdaptivePlayerStartsLowClimbsOneStepAndDropsAtOnce() {
        XCTAssertEqual(ExperienceAdaptivePlayer.next(current: .p480, throughputBps: nil, bufferMs: 0), .p480)
        XCTAssertEqual(ExperienceAdaptivePlayer.next(current: .p480, throughputBps: 40e6, bufferMs: 8_000), .p720)
        XCTAssertEqual(ExperienceAdaptivePlayer.next(current: .p480, throughputBps: 40e6, bufferMs: 7_999), .p480)
        XCTAssertEqual(ExperienceAdaptivePlayer.next(current: .p2160, throughputBps: 5e6, bufferMs: 3_999), .p720)
        XCTAssertEqual(ExperienceAdaptivePlayer.next(current: .p2160, throughputBps: 5e6, bufferMs: 4_000), .p2160)
        XCTAssertEqual(ExperienceAdaptivePlayer.target(throughputBps: 1e6), .p480)
        XCTAssertEqual(ExperienceAdaptivePlayer.target(throughputBps: 25e6), .p2160)
        let transfers: [ExperienceAdaptivePlayer.SegmentTransfer] = [
            .init(bytes: 1_000_000, nanos: 1_000_000_000), .init(bytes: 2_000_000, nanos: 1_000_000_000),
            .init(bytes: 2_000_000, nanos: 1_000_000_000), .init(bytes: 2_000_000, nanos: 500_000_000)
        ]
        XCTAssertEqual(ExperienceAdaptivePlayer.throughputBps(transfers) ?? 0, 19.2e6, accuracy: 1)
        XCTAssertNil(ExperienceAdaptivePlayer.throughputBps([]))
        XCTAssertEqual(ExperienceVideoQuality.p1440.segmentBytes, 3_000_000)
    }

    func testVideoScoreScaleAndRounding() {
        XCTAssertEqual(
            ExperienceVideoScoring.score(timeByQualityMs: [.p1080: 30_000], stalls: [.init(atPlaybackMs: 8_000, waitMs: 200)], startupMs: 900),
            ExperienceVideoScore(total: 28 + 29 + 20, quality: 28, smoothness: 29, startup: 20)
        )
        XCTAssertEqual(
            ExperienceVideoScoring.score(timeByQualityMs: [.p480: 10_000, .p720: 20_000], stalls: [], startupMs: 1_500),
            ExperienceVideoScore(total: 15 + 40 + 15, quality: 15, smoothness: 40, startup: 15)
        )
        let half = ExperienceVideoScoring.score(timeByQualityMs: [.p480: 15_000, .p1080: 15_000], stalls: [], startupMs: 3_000)
        XCTAssertEqual(half.quality, 18)
        XCTAssertEqual(half.startup, 8)
        let smooth = ExperienceVideoScoring.score(timeByQualityMs: [.p480: 2_000], stalls: [.init(atPlaybackMs: 0, waitMs: 100)], startupMs: 5_000)
        XCTAssertEqual(smooth.smoothness, 30, "29,5 → 30")
        XCTAssertEqual(smooth.startup, 0)
        let floor = ExperienceVideoScoring.score(
            timeByQualityMs: [.p480: 2_000], stalls: Array(repeating: .init(atPlaybackMs: 0, waitMs: 5_000), count: 5), startupMs: 500
        )
        XCTAssertEqual(floor.smoothness, 0)
    }

    // MARK: Jeu et appels

    func testJitterKeepsDecimalsAndRoundsOnceHalfUp() {
        XCTAssertEqual(ExperienceGameStats.jitter([40, 50, 40, 50]), 10)
        XCTAssertEqual(ExperienceGameStats.jitter([40, 42, 45]), 2.5)
        XCTAssertEqual(ExperienceSubmission.roundHalfUp(2.5), 3)
        XCTAssertEqual(ExperienceSubmission.roundHalfUp(2.49), 2)
        XCTAssertEqual(ExperienceGameStats.jitter([40, 41, 41, 42]) ?? 0, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(ExperienceSubmission.roundHalfUp(2.0 / 3), 1)
        XCTAssertEqual(ExperienceSubmission.roundHalfUp(ExperienceGameStats.jitter([40, 40, 41, 40, 40, 40, 40]) ?? -1), 0)
        XCTAssertNil(ExperienceGameStats.jitter([40]))
        XCTAssertNil(ExperienceGameStats.jitter([]))
    }

    func testSpikesAreStrictlyAboveMedianPlusOneHundred() throws {
        let summary = try XCTUnwrap(ExperienceGameStats.summarize(Array(repeating: 40, count: 8) + [140, 141, 300]))
        XCTAssertEqual(summary.medianMs, 40)
        XCTAssertEqual(summary.spikeCount, 2, "140 = médiane + 100 n'en est pas un")
        XCTAssertEqual(summary.maxMs, 300)
        XCTAssertEqual(summary.spikeShare, 2.0 / 11, accuracy: 1e-9)
        XCTAssertNil(ExperienceGameStats.summarize([]))
    }

    func testProbeFailureRule() {
        XCTAssertTrue(ExperienceGameStats.hasEnoughProbes(sent: 300, valid: 300))
        XCTAssertTrue(ExperienceGameStats.hasEnoughProbes(sent: 300, valid: 150))
        XCTAssertFalse(ExperienceGameStats.hasEnoughProbes(sent: 300, valid: 149))
        XCTAssertTrue(ExperienceGameStats.hasEnoughProbes(sent: 40, valid: 20))
        XCTAssertFalse(ExperienceGameStats.hasEnoughProbes(sent: 25, valid: 19))
        XCTAssertFalse(ExperienceGameStats.hasEnoughProbes(sent: 0, valid: 0))
        XCTAssertTrue(ExperienceGameStats.hasEnoughProbes(sent: 120, valid: 100))
    }

    func testUsageVerdictsAreInclusive() {
        XCTAssertTrue(ExperienceGameStats.suits(.competitiveGaming, medianMs: 50, jitterMs: 10, spikeCount: 0))
        XCTAssertFalse(ExperienceGameStats.suits(.competitiveGaming, medianMs: 50, jitterMs: 10, spikeCount: 1))
        XCTAssertFalse(ExperienceGameStats.suits(.competitiveGaming, medianMs: 51, jitterMs: 10, spikeCount: 0))
        XCTAssertTrue(ExperienceGameStats.suits(.casualGaming, medianMs: 100, jitterMs: 30, spikeCount: 5))
        XCTAssertFalse(ExperienceGameStats.suits(.hdVideoCall, medianMs: 151, jitterMs: 5, spikeCount: 0))
        XCTAssertTrue(ExperienceGameStats.suits(.audioCall, medianMs: 300, jitterMs: nil, spikeCount: nil))
        XCTAssertFalse(ExperienceGameStats.suits(.casualGaming, medianMs: 40, jitterMs: nil, spikeCount: 0))
    }

    func testUnderLoadGradeIsTheSpeedtestScale() {
        XCTAssertEqual(ExperienceGameStats.underLoadGrade(idleMs: 22, loadedDownMs: 41, loadedUpMs: 49)?.grade, "B")
        XCTAssertEqual(ExperienceGameStats.underLoadGrade(idleMs: 22, loadedDownMs: 41, loadedUpMs: 49)?.deltaMs, 27)
        XCTAssertEqual(ExperienceGameStats.underLoadGrade(idleMs: 20, loadedDownMs: 25, loadedUpMs: nil)?.grade, "A")
        XCTAssertEqual(ExperienceGameStats.underLoadGrade(idleMs: 20, loadedDownMs: 221, loadedUpMs: nil)?.grade, "F")
        XCTAssertNil(ExperienceGameStats.underLoadGrade(idleMs: 20, loadedDownMs: nil, loadedUpMs: nil))
    }

    // MARK: Phases web

    private var fresh: ExperienceWebPhases.Times {
        ExperienceWebPhases.Times(
            dnsStart: 10_000_000, dnsEnd: 22_000_000, connectStart: 22_000_000, connectEnd: 100_000_000,
            secureStart: 60_000_000, secureEnd: 100_000_000, requestStart: 100_000_000, responseStart: 220_000_000
        )
    }

    func testFivePhasesAddUpToTheTotal() throws {
        let opening = ExperienceWebPhases.opening(fresh, totalNanos: 2_061_000_000, protocolName: "h2")
        XCTAssertTrue(opening.measured)
        XCTAssertEqual(opening.freshConnection, true)
        XCTAssertEqual(opening.dnsMs, 12)
        XCTAssertEqual(opening.dnsCached, false)
        XCTAssertEqual(opening.connectMs, 38, "TCP seul, le TLS est compté à part")
        XCTAssertEqual(opening.tlsMs, 40)
        XCTAssertEqual(opening.firstByteMs, 120)
        let parts = try [opening.dnsMs, opening.connectMs, opening.tlsMs, opening.firstByteMs, opening.contentMs].map { try XCTUnwrap($0) }
        XCTAssertEqual(parts.reduce(0, +), opening.totalMs)
    }

    func testCachedDNSHasNoInventedZero() {
        var subMillisecond = fresh
        subMillisecond.dnsEnd = 10_400_000
        let cached = ExperienceWebPhases.opening(subMillisecond, totalNanos: 2_000_000_000, protocolName: "h2")
        XCTAssertEqual(cached.dnsCached, true)
        XCTAssertEqual(cached.dnsMs, 0)
        var none = fresh
        none.dnsStart = nil
        none.dnsEnd = nil
        let system = ExperienceWebPhases.opening(none, totalNanos: 2_000_000_000, protocolName: "http/1.1")
        XCTAssertEqual(system.dnsCached, true)
        XCTAssertNil(system.dnsMs, "dnsCached sans dnsMs, jamais 0")
        XCTAssertTrue(system.measured)
    }

    func testAReusedConnectionFailsTheOpening() {
        var reused = ExperienceWebPhases.Times(requestStart: 1_000_000, responseStart: 50_000_000)
        XCTAssertFalse(ExperienceWebPhases.opening(reused, totalNanos: 1_000_000_000, protocolName: "h2").measured)
        reused = fresh
        reused.reusedConnection = true
        let opening = ExperienceWebPhases.opening(reused, totalNanos: 1_000_000_000, protocolName: "h2")
        XCTAssertFalse(opening.measured)
        XCTAssertEqual(opening.freshConnection, false)
        XCTAssertNil(opening.totalMs)
        XCTAssertEqual(ExperienceWebPhases.protocolWire("H2"), "h2")
        XCTAssertEqual(ExperienceWebPhases.protocolWire("h3"), "h3")
        XCTAssertNil(ExperienceWebPhases.protocolWire("spdy/3"))
    }

    // MARK: Reprise d'un speedtest

    func testLatencyIsReusedOnlyOnAProvenSameNetwork() {
        let wifi = ExperienceNetworkPath(transport: .wifi, ssid: "Maison", vpn: false)
        XCTAssertTrue(ExperienceLatencyReuse.sameNetwork(wifi, wifi))
        XCTAssertFalse(ExperienceLatencyReuse.sameNetwork(wifi, ExperienceNetworkPath(transport: .wifi, ssid: nil, vpn: false)))
        XCTAssertFalse(ExperienceLatencyReuse.sameNetwork(wifi, ExperienceNetworkPath(transport: .wifi, ssid: "Maison", vpn: true)))
        let cell = ExperienceNetworkPath(transport: .cellular, dataServiceId: "0000001", carrierOperatorKey: "ORANGE", vpn: false)
        XCTAssertTrue(ExperienceLatencyReuse.sameNetwork(cell, cell))
        var unknownVPN = cell
        unknownVPN.vpn = nil
        XCTAssertFalse(ExperienceLatencyReuse.sameNetwork(cell, unknownVPN), "VPN inconnu")
        var otherSIM = cell
        otherSIM.dataServiceId = "0000002"
        XCTAssertFalse(ExperienceLatencyReuse.sameNetwork(cell, otherSIM))
        var noCarrier = cell
        noCarrier.carrierOperatorKey = nil
        XCTAssertFalse(ExperienceLatencyReuse.sameNetwork(noCarrier, noCarrier))
        XCTAssertFalse(ExperienceLatencyReuse.sameNetwork(wifi, cell), "chemin changé")
        XCTAssertFalse(ExperienceLatencyReuse.sameNetwork(nil, wifi))

        let at = Date(timeIntervalSince1970: 1_793_000_000)
        let snapshot = ExperienceLatencyReuse.Snapshot(measuredAt: at, path: wifi, idleMs: 22.4, loadedDownMs: 41.5, loadedUpMs: 49)
        XCTAssertEqual(
            ExperienceLatencyReuse.reuse(snapshot, now: wifi, at: at.addingTimeInterval(599)),
            ExperienceUnderLoad(idleMs: 22, loadedDownMs: 42, loadedUpMs: 49, grade: "B", deltaMs: 27, source: .recentSpeedtest)
        )
        XCTAssertNil(ExperienceLatencyReuse.reuse(snapshot, now: wifi, at: at.addingTimeInterval(600)), "10 min pile")
        XCTAssertNil(ExperienceLatencyReuse.reuse(snapshot, now: cell, at: at))
    }

    func testBudgetAndDefaultSelection() {
        XCTAssertEqual(ExperienceBudget.maxBytes(Set(ExperienceTestKind.allCases)), 211_025_000)
        XCTAssertEqual(ExperienceBudget.megabytesCeil(ExperienceBudget.maxBytes(Set(ExperienceTestKind.allCases))), 212)
        XCTAssertEqual(ExperienceBudget.megabytesCeil(ExperienceBudget.maxBytes(ExperienceBudget.defaultSelection(onMobileData: true))), 102)
        XCTAssertEqual(ExperienceBudget.maxBytes(.gameAndCalls, recentLatencyReused: true), 1_000_000)
        XCTAssertEqual(ExperienceBudget.defaultSelection(onMobileData: false).count, 5)
        XCTAssertEqual(ExperienceBudget.megabytesCeil(1), 1)
        XCTAssertEqual(ExperienceBudget.megabytesCeil(1_000_000), 1)
    }

    // MARK: Corps envoyé

    private func submission(_ tests: ExperienceTestsResult, location: ExperienceSubmission.Location? = nil) -> ExperienceSubmission {
        ExperienceSubmission(
            clientSubmissionId: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, appVersion: "1.0 (180)",
            measuredAt: Date(timeIntervalSince1970: 1_793_019_912.1234), durationMs: 159_000, bytesUsed: 109_000_000,
            network: .init(connectionType: "cellular", technology: "5G NSA", operatorKey: "ORANGE", marketCode: "FR"),
            location: location, tests: tests
        )
    }

    private func decoded(_ submission: ExperienceSubmission) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: submission.body()) as? [String: Any])
    }

    func testBodyFollowsTheContract() throws {
        var tests = ExperienceTestsResult()
        tests.videoLadder = ExperienceLadderResult(state: .measured, rungs: [
            ExperienceRung(quality: .p480, state: .measured, startupMs: 640, bufferMinMs: 1_800, bufferAvgMs: 6_200, receivedBps: 3_600_000, bytes: 1_875_000),
            ExperienceRung(quality: .p720, state: .abandoned, startupMs: 900, stalls: [.init(atPlaybackMs: 6_000, waitMs: 6_100)], bytes: 2_000_000),
            ExperienceRung(quality: .p1080, state: .notTested)
        ])
        tests.videoAdaptive = ExperienceAdaptiveResult(state: .interrupted, reason: .background, playbackMs: 9_000, startupMs: 700,
                                                       timeByQualityMs: [.p480: 4_000, .p720: 6_000], switchesUp: 1, switchesDown: 0, stalls: [],
                                                       score: ExperienceVideoScore(total: 1, quality: 1, smoothness: 0, startup: 0))
        tests.webPage = ExperienceWebResult(state: .measured, pageBytes: 2_300_000, parallelRequests: 6, openings: [
            ExperienceWebPhases.opening(fresh, totalNanos: 2_061_000_000, protocolName: "h2"),
            ExperienceWebOpening(measured: true, protocolName: "h2", freshConnection: false, dnsMs: 3, dnsCached: true, totalMs: 1_800)
        ])
        tests.gameAndCalls = ExperienceGameResult(state: .measured, probeMethod: "tcp_connect", medianMs: 41, jitterMs: 2.5, maxMs: 180,
                                                  spikeCount: 0, spikeShare: 0, series: [41, 39, 44])
        tests.upload = ExperienceUploadResult(state: .failed, reason: .offline)

        let body = try decoded(submission(tests, location: .init(city: "Grenoble", marketCode: "FR")))
        XCTAssertEqual(body["measuredAt"] as? String, "2026-10-26T13:05:12.123Z")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["methodology"] as? String, "experience-v3")
        XCTAssertEqual(body["clientSubmissionId"] as? String, "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        XCTAssertNil(body["isPublic"])
        XCTAssertNil((body["network"] as? [String: Any])?["observedPlmn"])
        XCTAssertEqual((body["location"] as? [String: String])?["city"], "Grenoble")

        let sent = try XCTUnwrap(body["tests"] as? [String: Any])
        let ladder = try XCTUnwrap(sent["videoLadder"] as? [String: Any])
        XCTAssertNil(ladder["notTestedReason"])
        let rungs = try XCTUnwrap(ladder["rungs"] as? [[String: Any]])
        XCTAssertEqual(rungs.map { $0["requiredBps"] as? Int }, [1_500_000, 3_000_000, 6_000_000])
        XCTAssertNotNil(rungs[0]["stalls"], "une marche jouée porte ses coupures, même vides")
        XCTAssertNil(rungs[2]["stalls"])
        let adaptive = try XCTUnwrap(sent["videoAdaptive"] as? [String: Any])
        XCTAssertEqual(adaptive["notTestedReason"] as? String, "background")
        XCTAssertNil(adaptive["score"], "pas de note sans lecture allée au bout")
        let openings = try XCTUnwrap((sent["webPage"] as? [String: Any])?["openings"] as? [[String: Any]])
        XCTAssertEqual(openings[0]["dnsMs"] as? Int, 12)
        XCTAssertNil(openings[1]["dnsCached"], "aucune phase sans connexion neuve")
        XCTAssertNil(openings[1]["dnsMs"])
        let game = try XCTUnwrap(sent["gameAndCalls"] as? [String: Any])
        XCTAssertEqual(game["jitterMs"] as? Int, 3)
        XCTAssertEqual(game["probeCount"] as? Int, 3)
        let upload = try XCTUnwrap(sent["upload"] as? [String: Any])
        XCTAssertNil(upload["notTestedReason"], "jamais avec failed")
        XCTAssertNil(upload["items"])

        // Les `highlights` que le serveur en tirerait, par le lecteur du contrat (F9).
        let json = try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: sent))
        XCTAssertEqual(
            ExperienceHighlights(tests: json),
            ExperienceHighlights(videoMaxQuality: "480p", pageMedianMs: 1_930, gameMedianMs: 41, gameProbeMethod: "tcp_connect")
        )
    }

    func testAPrivateZoneSendsAnExplicitNullLocation() throws {
        let body = try decoded(submission(ExperienceTestsResult(upload: ExperienceUploadResult(state: .notTested, reason: .userStopped))))
        XCTAssertTrue(body["location"] is NSNull)
        XCTAssertEqual((body["tests"] as? [String: Any])?.keys.sorted(), ["upload"])
    }
}
