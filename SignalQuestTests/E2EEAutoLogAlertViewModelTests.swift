import XCTest
@testable import SignalQuest

/// Alerte de fourche (E2EE-AUTO §3.5, lot 6d) : signalement avec l'accord de
/// l'utilisateur, puis réinitialisation volontaire, jamais avant.
@MainActor
final class E2EEAutoLogAlertViewModelTests: XCTestCase {
    private let device = BugReportDevice(
        model: "iPhone 17", osVersion: "iOS 27.0", appVersion: "1.0 (180)", build: "180", network: "Wi-Fi", screenSize: nil
    )

    private final class Calls {
        var submitted: [BugReportSubmission] = []
        var reportId: String?
        var resets = 0
        var failsSubmit = false
    }

    private func model(_ calls: Calls, alert: E2EEAutoLogStore.Alert = .init(error: "FORK", seq: 42)) -> E2EEAutoLogAlertViewModel {
        E2EEAutoLogAlertViewModel(alert: alert, dependencies: .init(
            submit: { submission in
                if calls.failsSubmit { throw URLError(.notConnectedToInternet) }
                calls.submitted.append(submission)
                return "bug_\(calls.submitted.count)"
            },
            reset: { calls.resets += 1 },
            reportId: { calls.reportId },
            setReported: { calls.reportId = $0 },
            device: { self.device }
        ))
    }

    func testResetWaitsForTheReport() async {
        let calls = Calls()
        let model = model(calls)
        XCTAssertEqual(model.kind, .fork)
        XCTAssertEqual(model.report, .idle)

        await model.reset()
        XCTAssertEqual(calls.resets, 0, "pas de réinitialisation avant le signalement")

        calls.failsSubmit = true
        await model.sendReport()
        XCTAssertEqual(model.report, .failed)
        XCTAssertNil(calls.reportId)

        calls.failsSubmit = false
        await model.sendReport()
        XCTAssertEqual(model.report, .sent)
        XCTAssertEqual(calls.reportId, "bug_1")
        await model.sendReport()
        XCTAssertEqual(calls.submitted.count, 1, "un seul signalement")

        await model.reset()
        XCTAssertEqual(calls.resets, 1)
        XCTAssertTrue(model.didReset)
    }

    func testAlreadyReportedAlertOffersTheResetAtOnce() {
        let calls = Calls()
        calls.reportId = "bug_9"
        let model = model(calls, alert: .init(error: "ROLLBACK", seq: 16))
        XCTAssertEqual(model.kind, .rollback)
        XCTAssertEqual(model.report, .sent)
        XCTAssertEqual(self.model(Calls(), alert: .init(error: "CHAIN_INVALID", seq: 3)).kind, .chainInvalid)
    }

    /// Ni contenu ni identifiant d'appareil du journal : l'écart, son maillon et l'appareil.
    func testSubmissionCarriesOnlyTheGapAndTheDevice() throws {
        let submission = E2EEAutoLogAlerts.submission(.init(error: "FORK", seq: 42), device: device)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(submission)) as? [String: Any])
        XCTAssertEqual(object["category"] as? String, "data")
        XCTAssertEqual(object["severity"] as? String, "critical")
        XCTAssertEqual(object["description"] as? String, "E2EE-AUTO log alert: FORK at seq 42")
        XCTAssertTrue((object["title"] as? String)?.contains("FORK") == true)
        XCTAssertNil(object["images"])
        XCTAssertNil(object["steps"])
    }
}
