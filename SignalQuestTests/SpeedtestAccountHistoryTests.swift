import XCTest
@testable import SignalQuest

/// UI-12 : l'onglet Tester montre les tests du compte absents du téléphone,
/// sans répéter ceux qui y sont déjà.
final class SpeedtestAccountHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_703_600)

    private func local(_ mbps: Double, at date: Date) -> SpeedtestRunResult {
        SpeedtestRunResult(label: "local", downloadMbps: mbps, downloadAverageMbps: mbps,
                           downloadMaxMbps: mbps, durationSeconds: 10, connectionType: .cellular,
                           createdAt: date)
    }

    private func account(_ id: String, average: Double, at date: Date) -> SocialShareableSpeedtest {
        var test = SocialShareableSpeedtest(id: id, downloadSpeed: average * 1.2, uploadSpeed: nil, ping: 20,
                                            networkType: "LTE", mobileOperator: "Orange", timestamp: date)
        test.averageSpeed = average
        return test
    }

    func testTestsAlreadyOnThePhoneAreNotRepeated() {
        let phone = [local(64.3, at: t0)]
        let server = [account("same", average: 64.3, at: t0.addingTimeInterval(30)),
                      account("older", average: 120, at: t0.addingTimeInterval(-3 * 86_400))]
        XCTAssertEqual(SpeedtestAccountHistory.accountOnly(server, local: phone).map(\.id), ["older"])
    }

    func testDelayedUploadIsRecognisedByItsSpeed() {
        let phone = [local(64.34, at: t0)]
        let server = [account("delayed", average: 64.34, at: t0.addingTimeInterval(5 * 3600)),
                      account("other", average: 90, at: t0.addingTimeInterval(5 * 3600))]
        XCTAssertEqual(SpeedtestAccountHistory.accountOnly(server, local: phone).map(\.id), ["other"])
    }

    func testEveryAccountTestShowsOnAFreshInstall() {
        let server = [account("a", average: 10, at: t0), account("b", average: 20, at: t0.addingTimeInterval(-60))]
        XCTAssertEqual(SpeedtestAccountHistory.accountOnly(server, local: []).count, 2)
    }

    func testAverageIsPreferredOverAPeakDownloadSpeed() {
        let test = account("x", average: 50, at: t0)
        XCTAssertEqual(test.downloadAverageMbps, 50, "downloadSpeed may carry the peak for non-iOS sources")
        XCTAssertEqual(AccountSpeedtestRow(test: test).subtitleLine, "4G · Orange")
    }
}
