import CoreLocation
import XCTest
@testable import SignalQuest

/// Session des tests d'expérience (F10c2) : sélection par défaut selon le réseau, lancement,
/// arrêts, reprise d'un speedtest récent, enregistrement et ville hors zone privée.
@MainActor
final class ExperienceTestsModelTests: XCTestCase {

    final class FakeSuite: ExperienceSuiteRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var stops: [ExperienceStopReason] = []
        let result: ExperienceRun
        let live: ExperienceLive?
        let reuse: ExperienceUnderLoad?
        var onRun: (@Sendable () async -> Void)?

        init(result: ExperienceRun, live: ExperienceLive? = nil, reuse: ExperienceUnderLoad?) {
            self.result = result
            self.live = live
            self.reuse = reuse
        }

        func run(_ selected: Set<ExperienceTestKind>, onLive: @escaping @Sendable (ExperienceLive) -> Void) async -> ExperienceRun {
            if let live { onLive(live) }
            await onRun?()
            return result
        }

        func requestStop(_ reason: ExperienceStopReason) { lock.withLock { stops.append(reason) } }
        var stopReasons: [ExperienceStopReason] { lock.withLock { stops } }
    }

    final class Recorder: @unchecked Sendable {
        var engines: [FakeSuite] = []
        var submissions: [ExperienceSubmission] = []
        var contexts = 0
    }

    private static let now = Date(timeIntervalSince1970: 1_793_019_912.5)

    private static func measuredRun(stop: ExperienceStopReason? = nil) -> ExperienceRun {
        var tests = ExperienceTestsResult()
        tests.webPage = ExperienceWebResult(state: .measured, pageBytes: 2_300_000, parallelRequests: 6, openings: [
            ExperienceWebOpening(measured: true, protocolName: "h2", freshConnection: true, dnsMs: 10, connectMs: 20, tlsMs: 30,
                                 firstByteMs: 40, contentMs: 1_000, totalMs: 1_100)
        ])
        tests.upload = ExperienceUploadResult(state: stop == nil ? .measured : .interrupted, reason: stop)
        return ExperienceRun(tests: tests, bytesUsed: 6_900_000, durationMs: 8_000, stop: stop, failures: [:],
                             usage: [.webPage: .init(bytes: 6_900_000, durationMs: 8_000)])
    }

    private func model(
        run: ExperienceRun = measuredRun(), context: ExperienceTestsModel.LaunchContext = .init(operatorKey: "ORANGE", marketCode: "FR",
                                                                                               location: .init(city: "Grenoble", marketCode: "FR")),
        snapshot: ExperienceLatencyReuse.Snapshot? = nil, live: ExperienceLive? = nil,
        outcome: ExperienceTestsService.SaveOutcome = .queued(clientSubmissionId: "x"),
        recorder: Recorder, onRun: (@Sendable () async -> Void)? = nil, beforeContext: (() async -> Void)? = nil
    ) -> ExperienceTestsModel {
        ExperienceTestsModel(environment: .init(
            makeEngine: { _, reuse in
                let suite = FakeSuite(result: run, live: live, reuse: reuse)
                suite.onRun = onRun
                MainActor.assumeIsolated { recorder.engines.append(suite) }
                return suite
            },
            context: { _ in
                await beforeContext?()
                recorder.contexts += 1
                return context
            },
            save: { submission, _ in
                recorder.submissions.append(submission)
                return outcome
            },
            localItems: { [] },
            recentLatency: { snapshot },
            appVersion: "1.0",
            now: { Self.now }
        ))
    }

    private func status(_ connection: NetworkConnectionKind, _ technology: CellularRadioTechnology? = nil) -> NetworkPathStatus {
        NetworkPathStatus(connection: connection, cellularTechnology: technology, operatorName: nil, operatorMcc: nil, operatorMnc: nil,
                          isExpensive: connection == .cellular, isConstrained: false)
    }

    // MARK: Sélection

    func testDefaultSelectionFollowsTheNetworkUntilTouched() {
        let model = model(recorder: Recorder())
        model.update(status: status(.cellular, .fourG), online: true)
        XCTAssertEqual(model.selected, [.videoLadder, .webPage, .gameAndCalls])
        XCTAssertTrue(model.network.isMobile)
        model.update(status: status(.wifi), online: true)
        XCTAssertEqual(model.selected, Set(ExperienceTestKind.allCases))
        XCTAssertEqual(model.estimatedSeconds, 150, "environ 2 min 30 pour les cinq")
        XCTAssertEqual(model.maxMegabytes, 212)
        model.toggle(.upload)
        model.update(status: status(.cellular, .fourG), online: true)
        XCTAssertEqual(model.selected, Set(ExperienceTestKind.allCases).subtracting([.upload]), "un choix de l'utilisateur reste")
    }

    // MARK: Lancement

    func testOfflineStartConsumesNothing() async {
        let recorder = Recorder()
        let model = model(recorder: recorder)
        model.update(status: status(.other), online: false)
        await model.start()
        XCTAssertTrue(model.offlineAtStart)
        XCTAssertTrue(recorder.engines.isEmpty)
        XCTAssertEqual(recorder.contexts, 0)
        XCTAssertNil(model.finished)
    }

    func testFinishedRunIsSavedWithTheLaunchNetworkAndCity() async throws {
        let recorder = Recorder()
        let model = model(outcome: .queued(clientSubmissionId: "x"), recorder: recorder)
        model.update(status: status(.cellular, .fiveGNSA), online: true)
        await model.start()
        let finished = try XCTUnwrap(model.finished)
        XCTAssertEqual(finished.finish, .completed)
        XCTAssertEqual(finished.save, .queued)
        XCTAssertFalse(model.running)
        let submission = try XCTUnwrap(recorder.submissions.first)
        XCTAssertEqual(submission.network, .init(connectionType: "cellular", technology: "5G NSA", operatorKey: "ORANGE", marketCode: "FR"))
        XCTAssertEqual(submission.location, .init(city: "Grenoble", marketCode: "FR"))
        XCTAssertEqual(submission.measuredAt, Self.now)
        XCTAssertEqual(submission.bytesUsed, 6_900_000)
        XCTAssertEqual(submission.tests, Self.measuredRun().tests)
        XCTAssertEqual(submission.appVersion, "1.0")
    }

    func testNothingMeasuredIsNotSaved() async throws {
        let recorder = Recorder()
        var tests = ExperienceTestsResult()
        tests.webPage = ExperienceWebResult(state: .failed)
        let run = ExperienceRun(tests: tests, bytesUsed: 10, durationMs: 1, stop: nil, failures: [:], usage: [:])
        let model = model(run: run, recorder: recorder)
        model.update(status: status(.wifi), online: true)
        await model.start()
        XCTAssertEqual(model.finished?.save, ExperienceSaveState.none)
        XCTAssertTrue(recorder.submissions.isEmpty)
    }

    func testStoppedRunKeepsFinishedTests() async throws {
        let recorder = Recorder()
        let model = model(run: Self.measuredRun(stop: .networkChanged), recorder: recorder)
        model.update(status: status(.wifi), online: true)
        await model.start()
        XCTAssertEqual(model.finished?.finish, .networkChanged)
        XCTAssertEqual(recorder.submissions.first?.tests.upload?.state, .interrupted)
    }

    func testStopDuringPreparationStopsTheEngineAtOnce() async throws {
        let recorder = Recorder()
        var resume: CheckedContinuation<Void, Never>?
        let model = model(recorder: recorder, beforeContext: {
            await withCheckedContinuation { resume = $0 }
        })
        model.update(status: status(.wifi), online: true)
        let task = Task { await model.start() }
        while resume == nil { await Task.yield() }
        XCTAssertTrue(model.running, "« Préparation » : l'écran passe en cours tout de suite")
        model.stop()
        resume?.resume()
        await task.value
        XCTAssertEqual(recorder.engines.first?.stopReasons, [.userStopped])
    }

    func testGoingToTheBackgroundStopsTheRunningEngine() async throws {
        let recorder = Recorder()
        let model = model(recorder: recorder, onRun: {
            await MainActor.run { }
        })
        model.update(status: status(.wifi), online: true)
        let task = Task { await model.start() }
        while recorder.engines.isEmpty { await Task.yield() }
        model.setForeground(false)
        await task.value
        XCTAssertEqual(recorder.engines.first?.stopReasons, [.background])
    }

    func testDiscardOnAccountChangeStopsTheRunAndSavesNothing() async throws {
        let recorder = Recorder()
        var resume: CheckedContinuation<Void, Never>?
        let model = model(recorder: recorder, beforeContext: {
            await withCheckedContinuation { resume = $0 }
        })
        model.update(status: status(.wifi), online: true)
        let task = Task { await model.start() }
        while resume == nil { await Task.yield() }
        model.discard()
        XCTAssertFalse(model.running)
        resume?.resume()
        await task.value
        XCTAssertTrue(recorder.engines.isEmpty, "pas de moteur lancé après le changement de compte")
        XCTAssertTrue(recorder.submissions.isEmpty)
        XCTAssertNil(model.finished)

        let running = Recorder()
        let other = self.model(recorder: running, onRun: { try? await Task.sleep(nanoseconds: 20_000_000) })
        other.update(status: status(.wifi), online: true)
        let second = Task { await other.start() }
        while running.engines.isEmpty { await Task.yield() }
        other.discard()
        await second.value
        XCTAssertEqual(running.engines.first?.stopReasons, [.userStopped])
        XCTAssertTrue(running.submissions.isEmpty, "le résultat de l'ancien compte n'est pas enregistré")
        XCTAssertNil(other.finished)
    }

    // MARK: Reprise d'un speedtest récent

    func testRecentSpeedtestOnTheSameWiFiIsReused() async throws {
        let path = try XCTUnwrap(ExperienceRecentLatency.path(connection: .wifi, ssid: "Maison", carrierOperatorKey: nil))
        let snapshot = ExperienceLatencyReuse.Snapshot(measuredAt: Self.now.addingTimeInterval(-240), path: path,
                                                       idleMs: 39, loadedDownMs: 58, loadedUpMs: 66)
        let recorder = Recorder()
        let model = model(context: .init(ssid: "Maison"), snapshot: snapshot, recorder: recorder)
        model.update(status: status(.wifi), online: true)
        await model.start()
        XCTAssertEqual(recorder.engines.first?.reuse?.source, .recentSpeedtest)
        XCTAssertEqual(model.finished?.reusedSpeedtestAge, 240)
        XCTAssertEqual(model.finished?.maxBytes, ExperienceBudget.maxBytes(Set(ExperienceTestKind.allCases), recentLatencyReused: true))

        let elsewhere = Recorder()
        let other = self.model(context: .init(ssid: "Bureau"), snapshot: snapshot, recorder: elsewhere)
        other.update(status: status(.wifi), online: true)
        await other.start()
        XCTAssertNil(elsewhere.engines.first?.reuse, "autre réseau : courte charge mesurée")
        XCTAssertNil(other.finished?.reusedSpeedtestAge)
    }

    func testLiveRankFollowsTheMethodOrder() async {
        let recorder = Recorder()
        var seen: (Int, Int)?
        let model = model(live: ExperienceLive(test: .webPage), recorder: recorder, onRun: {
            try? await Task.sleep(nanoseconds: 20_000_000)
        })
        model.update(status: status(.cellular, .fourG), online: true)
        let task = Task { await model.start() }
        while model.live == nil { await Task.yield() }
        if let liveRank = model.liveRank { seen = (liveRank.index, liveRank.total) }
        await task.value
        XCTAssertEqual(seen?.0, 2, "échelle, puis web")
        XCTAssertEqual(seen?.1, 3)
        XCTAssertNil(model.live, "plus de direct une fois fini")
    }

    // MARK: Navigation

    func testDetailAndUsagePagesOpenOnlyOnAResult() async {
        let model = model(recorder: Recorder())
        model.openDetail(.webPage)
        model.openUsage()
        XCTAssertEqual(model.page, .home, "rien à détailler avant un résultat")
        model.update(status: status(.wifi), online: true)
        await model.start()
        model.openDetail(.webPage)
        XCTAssertEqual(model.page, .detail(.webPage))
        model.back()
        XCTAssertEqual(model.page, .home)
        model.openUsage()
        XCTAssertEqual(model.page, .usage)
        model.newTest()
        XCTAssertEqual(model.page, .home)
        XCTAssertNil(model.finished)
    }

    // MARK: Ville

    func testCityIsKeptOnlyOutsideAnActivePrivateZone() {
        let here = CLLocationCoordinate2D(latitude: 45.1885, longitude: 5.7245)
        let home = PrivacyZone(id: "z1", name: "Maison", latitude: 45.1890, longitude: 5.7250, radius: 200)
        XCTAssertFalse(ExperienceLocationPolicy.allowsCity(zones: [home], signedIn: true, at: here))
        var inactive = home
        inactive.isActive = false
        XCTAssertTrue(ExperienceLocationPolicy.allowsCity(zones: [inactive], signedIn: true, at: here))
        var shown = home
        shown.hideSpeedtestsOnMap = false
        XCTAssertTrue(ExperienceLocationPolicy.allowsCity(zones: [shown], signedIn: true, at: here))
        let far = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        XCTAssertTrue(ExperienceLocationPolicy.allowsCity(zones: [home], signedIn: true, at: far))
        XCTAssertFalse(ExperienceLocationPolicy.allowsCity(zones: nil, signedIn: true, at: far), "zones illisibles : pas de ville")
        XCTAssertTrue(ExperienceLocationPolicy.allowsCity(zones: nil, signedIn: false, at: far))
        XCTAssertEqual(ExperienceLocationPolicy.cleanCity("  Saint-Martin-\nd'Hères  "), "Saint-Martin- d'Hères")
        XCTAssertNil(ExperienceLocationPolicy.cleanCity(" \t"))
        XCTAssertEqual(ExperienceLocationPolicy.cleanCity(String(repeating: "a", count: 140))?.count, 100)
    }
}
