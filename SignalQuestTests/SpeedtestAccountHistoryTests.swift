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

/// Ticket du 26/10 : un test fait ailleurs s'ouvre avec la même fiche qu'un
/// test du téléphone, à partir du détail renvoyé par le serveur.
final class AccountSpeedtestDetailTests: XCTestCase {
    private func detail(_ json: String) throws -> SpeedtestDetail {
        try JSONDecoder.signalQuest.decode(SpeedtestDetail.self, from: Data(json.utf8))
    }

    func testServerDetailBecomesTheSameCardAsALocalTest() throws {
        let result = SpeedtestAccountHistory.runResult(from: try detail("""
        {"id":"cksp1","timestamp":"2026-10-20T10:00:00.000Z","downloadSpeed":410,"averageSpeed":312.4,
         "downloadMax":401,"uploadAvg":48.2,"uploadMax":60,"pingMin":18,"ping":21,"jitter":3.4,
         "testDuration":15,"connectionType":"CELLULAR","networkType":"5G NSA","mobileOperator":"Orange",
         "latitude":45.76,"longitude":4.83,"downloadServerName":"Cloudflare Paris","deviceModel":"iPhone 16"}
        """))
        XCTAssertEqual(result.downloadAverageMbps, 312.4, "the average leads, never the raw peak")
        XCTAssertEqual(result.downloadMaxMbps, 401)
        XCTAssertEqual(result.uploadAverageMbps, 48.2)
        XCTAssertEqual(result.pingMinMs, 18)
        XCTAssertEqual(result.connectionType, .cellular)
        XCTAssertEqual(result.cellularTechnology, .fiveGNSA)
        XCTAssertEqual(result.networkOperatorName, "Orange")
        XCTAssertEqual(result.coordinate?.latitude, 45.76)
        XCTAssertEqual(result.downloadServerName, "Cloudflare Paris")
        XCTAssertEqual(result.durationSeconds, 15)
    }

    func testNetworkKindIsReadWithoutGuessing() {
        XCTAssertEqual(SpeedtestAccountHistory.cellularTechnology("LTE"), .fourG)
        XCTAssertNil(SpeedtestAccountHistory.cellularTechnology("5G"), "5G alone is neither NSA nor SA")
        XCTAssertEqual(SpeedtestAccountHistory.connectionKind("wifi", technology: nil), .wifi)
        XCTAssertEqual(SpeedtestAccountHistory.connectionKind(nil, technology: .fourG), .cellular)
        XCTAssertEqual(SpeedtestAccountHistory.connectionKind(nil, technology: nil), .other)
    }

    /// CONN-KIND v1 : le classement du serveur l'emporte, `UNKNOWN` ou une valeur
    /// d'une future v2 rendent la main à la lecture brute.
    func testServedConnectionKindIsPreferred() {
        XCTAssertEqual(SpeedtestAccountHistory.connectionKind(served: "CELLULAR_5G"), .cellular)
        XCTAssertEqual(SpeedtestAccountHistory.connectionKind(served: "CELLULAR"), .cellular)
        XCTAssertEqual(SpeedtestAccountHistory.connectionKind(served: "ETHERNET"), .wired)
        XCTAssertEqual(SpeedtestAccountHistory.connectionKind(served: "WIFI"), .wifi)
        XCTAssertNil(SpeedtestAccountHistory.connectionKind(served: "UNKNOWN"))
        XCTAssertNil(SpeedtestAccountHistory.connectionKind(served: "SATELLITE"))
        XCTAssertNil(SpeedtestAccountHistory.connectionKind(served: nil))
    }
}

