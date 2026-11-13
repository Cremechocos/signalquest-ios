import XCTest
@testable import SignalQuest

/// SPEEDTEST-FAIL-1 : ce qu'une ligne contient, quand elle part, et ce que le serveur en fait.
final class SpeedtestFailureReporterTests: XCTestCase {
    private func status(_ connection: NetworkConnectionKind, _ tech: CellularRadioTechnology? = nil) -> NetworkPathStatus {
        NetworkPathStatus(connection: connection, cellularTechnology: tech, operatorName: nil,
                          operatorMcc: 208, operatorMnc: 20, isExpensive: false, isConstrained: false)
    }

    private func line(_ code: String = "PING_UNREACHABLE", quarter: String) -> SpeedtestFailure.Line {
        SpeedtestFailure.Line(code: code, phase: .latency, engine: "cloudflare", technology: "5G_NSA",
                              operatorKey: "BOUYGUES", quarterStart: quarter)
    }

    func testLineEncodesExactlyTheContractKeysWithExplicitNulls() throws {
        let batch = SpeedtestFailure.Batch(build: "185", failures: [
            SpeedtestFailure.Line(code: "NO_INTERNET", phase: .setup, engine: nil, technology: "WIFI",
                                  operatorKey: nil, quarterStart: "2026-11-13T19:45:00.000Z"),
        ])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "platform", "build", "failures"])
        XCTAssertEqual(object["version"] as? String, "1")
        XCTAssertEqual(object["platform"] as? String, "ios")
        let first = try XCTUnwrap((object["failures"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["code", "phase", "engine", "technology", "operatorKey", "quarterStart"],
                       "engine et operatorKey toujours présents, même à null")
        XCTAssertTrue(first["engine"] is NSNull)
        XCTAssertTrue(first["operatorKey"] is NSNull)
        XCTAssertEqual(first["phase"] as? String, "setup")
    }

    func testQuarterStartIsTheUTCQuarterHourAtTheMillisecond() {
        let date = ISO8601DateFormatter().date(from: "2026-10-28T10:29:59Z")!
        XCTAssertEqual(SpeedtestFailure.quarterStart(date), "2026-10-28T10:15:00.000Z")
        let exact = ISO8601DateFormatter().date(from: "2026-10-28T10:45:00Z")!
        XCTAssertEqual(SpeedtestFailure.quarterStart(exact), "2026-10-28T10:45:00.000Z")
    }

    func testCodesFollowTheSharedTable() {
        XCTAssertEqual(SpeedtestFailure.code(for: URLError(.notConnectedToInternet), cancelled: false, stop: nil), "NO_INTERNET")
        XCTAssertEqual(SpeedtestFailure.code(for: URLError(.dataNotAllowed), cancelled: false, stop: nil), "CELLULAR_NETWORK_UNAVAILABLE")
        XCTAssertEqual(SpeedtestFailure.code(for: URLError(.timedOut), cancelled: false, stop: nil), "CONNECTION_UNSTABLE")
        XCTAssertEqual(SpeedtestFailure.code(for: URLError(.serverCertificateUntrusted), cancelled: false, stop: nil), "SECURE_ACCESS_UNAVAILABLE")
        XCTAssertEqual(SpeedtestFailure.code(for: URLError(.cannotConnectToHost), cancelled: false, stop: nil), "TEMPORARILY_UNAVAILABLE")
        XCTAssertEqual(SpeedtestFailure.code(for: URLError(.cannotFindHost), cancelled: false, stop: nil), "PING_UNREACHABLE")
        XCTAssertEqual(SpeedtestFailure.code(for: URLError(.dnsLookupFailed), cancelled: false, stop: nil), "PING_UNREACHABLE")
        XCTAssertEqual(SpeedtestFailure.code(for: IPerf3Error.accessDenied, cancelled: false, stop: nil), "TEMPORARILY_UNAVAILABLE")
        XCTAssertEqual(SpeedtestFailure.code(for: IPerf3Error.connectionClosed(got: 1, expected: 2), cancelled: false, stop: nil), "CONNECTION_UNSTABLE")
        XCTAssertEqual(SpeedtestFailure.code(for: APIError.http(status: 429, code: nil, message: "", requestId: nil, retryAfter: nil),
                                             cancelled: false, stop: nil), "TEMPORARILY_UNAVAILABLE")
        XCTAssertEqual(SpeedtestFailure.code(for: NSError(domain: "x", code: 1), cancelled: false, stop: nil), "UNKNOWN")
        XCTAssertNil(SpeedtestFailure.code(for: SpeedtestBusyError.alreadyRunning, cancelled: false, stop: nil),
                     "Un test refusé parce qu'un autre tourne n'est pas un test raté")
    }

    func testOnlyAMemberStopCountsAsCancelled() {
        XCTAssertEqual(SpeedtestFailure.code(for: CancellationError(), cancelled: true, stop: .member), "CANCELLED")
        XCTAssertNil(SpeedtestFailure.code(for: CancellationError(), cancelled: true, stop: nil),
                     "Arrêt par l'app (fin de trajet, changement de réseau) : aucune ligne")
        XCTAssertNil(SpeedtestFailure.code(for: URLError(.networkConnectionLost), cancelled: true, stop: nil),
                     "Une socket fermée par l'annulation n'est pas une panne du réseau")
    }

    func testTechnologyAndOperatorNeverDescribeATunnelOrWiFi() {
        XCTAssertEqual(SpeedtestFailure.technology(status(.cellular, .fiveGNSA), viaVpn: false), "5G_NSA")
        XCTAssertEqual(SpeedtestFailure.technology(status(.cellular, nil), viaVpn: false), "UNKNOWN")
        XCTAssertEqual(SpeedtestFailure.technology(status(.wifi), viaVpn: false), "WIFI")
        XCTAssertEqual(SpeedtestFailure.technology(status(.cellular, .fourG), viaVpn: true), "UNKNOWN")
        XCTAssertEqual(SpeedtestFailure.operatorKey("SFR", status: status(.cellular, .fourG), viaVpn: false), "SFR")
        XCTAssertNil(SpeedtestFailure.operatorKey("SFR", status: status(.wifi), viaVpn: false))
        XCTAssertNil(SpeedtestFailure.operatorKey("SFR", status: status(.cellular, .fourG), viaVpn: true))
        XCTAssertNil(SpeedtestFailure.operatorKey("Bouygues Telecom", status: status(.cellular, .fourG), viaVpn: false))
    }

    func testProbeKeepsTheFurthestPhaseAndTheLastEngine() {
        let probe = SpeedtestFailureProbe()
        XCTAssertEqual(probe.snapshot.phase, .setup)
        XCTAssertNil(probe.snapshot.engine)
        probe.reach(.download)
        probe.reach(.ping)
        probe.use(engine: "cloudflare")
        probe.use(engine: "iperf3")
        XCTAssertEqual(probe.snapshot.phase, .download, "Une étape ne recule jamais")
        XCTAssertEqual(probe.snapshot.engine, "iperf3")
    }

    func testSendWaitsFifteenMinutesAfterTheLastFailureThenSendsOldestFirst() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let sent = SentBodies()
        let reporter = SpeedtestFailureReporter(fileURL: nil, build: "185", now: { clock.now }, enabled: true, transport: { body, key in
            await sent.append(body, key)
            return (202, nil)
        })
        let quarter = SpeedtestFailure.quarterStart(clock.now)
        await reporter.record(line("PING_UNREACHABLE", quarter: quarter))
        await reporter.record(line("NO_INTERNET", quarter: quarter))
        let early = await reporter.delayBeforeSend(at: clock.now.addingTimeInterval(60))
        XCTAssertEqual(early, 14 * 60, accuracy: 1)
        clock.advance(15 * 60)
        let outcome = await reporter.sendOneBatch()
        XCTAssertEqual(outcome, .sent)
        let bodies = await sent.bodies
        XCTAssertEqual(bodies.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        XCTAssertEqual((object["failures"] as? [[String: Any]])?.map { $0["code"] as? String }, ["PING_UNREACHABLE", "NO_INTERNET"])
        let state = await reporter.snapshot
        XCTAssertTrue(state.lines.isEmpty && state.inFlight.isEmpty)
    }

    /// Les deux pièges qui font refuser tout le lot en 400 (Backend, 13/11) : `engine` et `operatorKey`
    /// écrits à null plutôt qu'omis, `quarterStart` en UTC à la milliseconde. Comparé à l'octet près.
    func testSentBodyMatchesTheContractBytes() async throws {
        let failedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-13T19:37:12Z"))
        let clock = TestClock(failedAt)
        let sent = SentBodies()
        let reporter = SpeedtestFailureReporter(fileURL: nil, build: "185", now: { clock.now }, enabled: true, transport: { body, key in
            await sent.append(body, key)
            return (202, nil)
        })
        await reporter.record(SpeedtestFailure.Line(code: "NO_INTERNET", phase: .setup, engine: nil, technology: "WIFI",
                                                    operatorKey: nil, quarterStart: SpeedtestFailure.quarterStart(failedAt)))
        clock.advance(16 * 60)
        let outcome = await reporter.sendOneBatch()
        XCTAssertEqual(outcome, .sent)
        let bodies = await sent.bodies
        let keys = await sent.keys
        let body = try XCTUnwrap(bodies.first)
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"build":"185","failures":[{"code":"NO_INTERNET","engine":null,"operatorKey":null,"phase":"setup","quarterStart":"2026-11-13T19:30:00.000Z","technology":"WIFI"}],"platform":"ios","version":"1"}"#)
        let key = try XCTUnwrap(keys.first)
        XCTAssertNotNil(UUID(uuidString: key), "Idempotency-Key au format UUID")
    }

    func testRetryKeepsTheSameBatchAndKeyAndARejectionDropsIt() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let sent = SentBodies()
        let statuses = StatusQueue([503, 202])
        let reporter = SpeedtestFailureReporter(fileURL: nil, build: "185", now: { clock.now }, enabled: true, transport: { body, key in
            await sent.append(body, key)
            return (await statuses.next(), nil)
        })
        await reporter.record(line(quarter: SpeedtestFailure.quarterStart(clock.now)))
        clock.advance(16 * 60)
        let first = await reporter.sendOneBatch()
        XCTAssertEqual(first, .retry(after: nil))
        let waiting = await reporter.delayBeforeSend(at: clock.now)
        XCTAssertEqual(waiting, 30 * 60, accuracy: 1, "503 : nouvel essai 30 min plus tard")
        await reporter.record(line("NO_INTERNET", quarter: SpeedtestFailure.quarterStart(clock.now)))
        clock.advance(31 * 60)
        let second = await reporter.sendOneBatch()
        XCTAssertEqual(second, .sent)
        let keys = await sent.keys
        let bodies = await sent.bodies
        XCTAssertEqual(keys[0], keys[1], "Le renvoi garde sa clé : le serveur n'ajoute pas deux fois les lignes")
        XCTAssertEqual(bodies[0], bodies[1], "Le même lot repart, sans la ligne arrivée entre-temps")
        let state = await reporter.snapshot
        XCTAssertEqual(state.lines.map(\.code), ["NO_INTERNET"])

        XCTAssertEqual(SpeedtestFailureReporter.outcome(status: 400, retryAfter: nil), .rejected)
        XCTAssertEqual(SpeedtestFailureReporter.outcome(status: 429, retryAfter: 120), .retry(after: 120))
        XCTAssertEqual(SpeedtestFailureReporter.outcome(status: nil, retryAfter: nil), .retry(after: nil))
    }

    func testQueueKeepsTheNewest200AndDropsLinesOlderThanSevenDays() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let reporter = SpeedtestFailureReporter(fileURL: nil, build: "185", now: { clock.now }, enabled: true, transport: { _, _ in (202, nil) })
        for index in 0..<205 {
            await reporter.record(line(index < 5 ? "UNKNOWN" : "PING_UNREACHABLE", quarter: SpeedtestFailure.quarterStart(clock.now)))
        }
        let state = await reporter.snapshot
        XCTAssertEqual(state.lines.count, 200)
        XCTAssertFalse(state.lines.contains { $0.code == "UNKNOWN" }, "Les plus anciennes sortent")

        let old = line(quarter: SpeedtestFailure.quarterStart(clock.now.addingTimeInterval(-7 * 24 * 3600)))
        XCTAssertFalse(SpeedtestFailure.isSendable(old, now: clock.now))
        XCTAssertTrue(SpeedtestFailure.isSendable(line(quarter: SpeedtestFailure.quarterStart(clock.now)), now: clock.now))
        XCTAssertFalse(SpeedtestFailure.isSendable(line("SOMETHING_NEW", quarter: SpeedtestFailure.quarterStart(clock.now)), now: clock.now))
    }

    func testNeverWithinAMinuteOfASpeedtestPost() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let reporter = SpeedtestFailureReporter(fileURL: nil, build: "185", now: { clock.now }, enabled: true, transport: { _, _ in (202, nil) })
        await reporter.record(line(quarter: SpeedtestFailure.quarterStart(clock.now)))
        clock.advance(20 * 60)
        SpeedtestFailureReporter.noteSpeedtestPost(at: clock.now.addingTimeInterval(-10))
        let wait = await reporter.delayBeforeSend(at: clock.now)
        XCTAssertEqual(wait, 50, accuracy: 1)
        SpeedtestFailureReporter.noteSpeedtestPost(at: .distantPast)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private actor SentBodies {
    private(set) var bodies: [Data] = []
    private(set) var keys: [String] = []
    func append(_ body: Data, _ key: String) { bodies.append(body); keys.append(key) }
}

private actor StatusQueue {
    private var values: [Int]
    init(_ values: [Int]) { self.values = values }
    func next() -> Int? { values.isEmpty ? nil : values.removeFirst() }
}
