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

    /// MEASURED-AT-1 : l'heure de mesure servie reconnaît un envoi différé de plus
    /// de 24 h, que la fenêtre d'avant laissait en double ; une autre heure de
    /// mesure n'est jamais confondue, même à la même seconde d'arrivée.
    func testServedMeasurementTimeMatchesADelayedUpload() {
        let phone = [local(64.34, at: t0)]
        var late = account("late", average: 80, at: t0.addingTimeInterval(3 * 86_400))
        late.measuredAt = t0.addingTimeInterval(0.0004)
        var other = account("other", average: 64.34, at: t0.addingTimeInterval(10))
        other.measuredAt = t0.addingTimeInterval(-600)
        XCTAssertEqual(SpeedtestAccountHistory.accountOnly([late, other], local: phone).map(\.id), ["other"])
        XCTAssertEqual(late.displayedDate, late.measuredAt)
        XCTAssertEqual(account("old", average: 1, at: t0).displayedDate, t0, "Sans heure de mesure : l'heure d'arrivée")
    }

    /// MEASURED-AT-1 : on envoie la fin de mesure (début + durée), et un test
    /// servi avec la fin comme avec le début (envois du 09/11) reste reconnu.
    func testMeasuredAtIsTheEndOfTheMeasurement() {
        let result = local(64.34, at: t0)
        XCTAssertEqual(result.measurementEndedAt, t0.addingTimeInterval(10))
        XCTAssertEqual(SpeedtestSubmission.iosPayload(from: result, streams: 1, deviceModel: "iPhone").measuredAt,
                       SpeedtestSubmission.measuredAtString(t0.addingTimeInterval(10)))
        var end = account("end", average: 80, at: t0.addingTimeInterval(3 * 86_400))
        end.measuredAt = t0.addingTimeInterval(10)
        var start = account("start", average: 80, at: t0.addingTimeInterval(3 * 86_400))
        start.measuredAt = t0
        var between = account("between", average: 64.34, at: t0.addingTimeInterval(12))
        between.measuredAt = t0.addingTimeInterval(5)
        XCTAssertEqual(SpeedtestAccountHistory.accountOnly([end, start, between], local: [result]).map(\.id), ["between"])
    }

    func testMeasuredAtIsSentInUTCWithMilliseconds() throws {
        let date = Date(timeIntervalSince1970: 1_794_227_696.7896)
        XCTAssertEqual(SpeedtestSubmission.measuredAtString(date), "2026-11-09T12:34:56.789Z")
        let decoded = try JSONDecoder.signalQuest.decode(
            SocialShareableSpeedtest.self,
            from: Data(#"{"id":"x","timestamp":"2026-11-12T08:00:00.000Z","measuredAt":"2026-11-09T12:34:56.789Z"}"#.utf8)
        )
        XCTAssertEqual(try XCTUnwrap(decoded.measuredAt).timeIntervalSince1970, 1_794_227_696.789, accuracy: 0.001)
        let legacy = try JSONDecoder.signalQuest.decode(
            SocialShareableSpeedtest.self, from: Data(#"{"id":"y","timestamp":"2026-11-12T08:00:00.000Z","measuredAt":null}"#.utf8)
        )
        XCTAssertNil(legacy.measuredAt)
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

    /// cmw9share0nonoperateur01 : un nom qui n'est pas un opérateur n'est pas affiché.
    func testAnUnknownOperatorNameIsNotShownInTheRow() {
        let test = SocialShareableSpeedtest(id: "x", downloadSpeed: 60, uploadSpeed: nil, ping: 20,
                                            networkType: "LTE", mobileOperator: "Cloudflare, Inc.", timestamp: t0)
        XCTAssertEqual(AccountSpeedtestRow(test: test).subtitleLine, "4G")
        XCTAssertNil(SpeedtestAccountHistory.knownOperatorName("Cloudflare, Inc."))
        XCTAssertEqual(SpeedtestAccountHistory.knownOperatorName(" Rogers "), "Rogers")
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

    /// cmw9share0nonoperateur01 : un nom qui n'est pas un opérateur n'atteint ni la fiche,
    /// ni l'image, ni la légende de partage.
    func testANameThatIsNotAnOperatorIsDropped() throws {
        let base = #""id":"x","timestamp":"2026-03-11T10:00:00.000Z","averageSpeed":80,"connectionType":"CELLULAR","networkType":"LTE""#
        // Serveur antérieur à MVNO-1 r3 : seul un nom de la palette est gardé.
        let legacy = SpeedtestAccountHistory.runResult(from: try detail("{\(base),\"mobileOperator\":\"Cloudflare, Inc.\"}"))
        XCTAssertNil(legacy.networkOperatorName)
        XCTAssertNil(SpeedtestShareImageRenderer.shareText(for: legacy).range(of: "Cloudflare"))
        XCTAssertEqual(SpeedtestAccountHistory.runResult(from: try detail("{\(base),\"mobileOperator\":\"Orange\"}")).networkOperatorName, "Orange")
        // MVNO-1 r3 : le serveur dit s'il a reconnu le réseau.
        let unknown = try detail("{\(base),\"mobileOperator\":\"Cloudflare, Inc.\",\"operatorDisplay\":{\"brand\":null,\"brandSource\":null,\"network\":\"Cloudflare, Inc.\",\"networkKey\":null}}")
        XCTAssertNil(SpeedtestAccountHistory.runResult(from: unknown).networkOperatorName)
        let known = try detail("{\(base),\"mobileOperator\":\"Bouygues\",\"operatorDisplay\":{\"brand\":null,\"brandSource\":null,\"network\":\"Bouygues Telecom\",\"networkKey\":\"BOUYGUES\"}}")
        XCTAssertEqual(SpeedtestAccountHistory.runResult(from: known).networkOperatorName, "Bouygues Telecom")
        // Une forme inattendue ne fait pas échouer le détail.
        XCTAssertNil(try detail("{\(base),\"operatorDisplay\":\"x\"}").operatorDisplay)
    }

    /// MVNO-1 r3 (servi le 10/11) : « <marque> · réseau <réseau> » quand l'API sert une
    /// marque (vrai MVNO, test Android), sinon le réseau reconnu seul.
    func testServedBrandReadsBrandThenNetwork() throws {
        let display = SpeedtestServedOperatorDisplay(brand: "La Poste Mobile", network: "Bouygues Telecom", networkKey: "BOUYGUES")
        XCTAssertEqual(SpeedtestAccountHistory.operatorLabel(display: display, raw: "La Poste Mobile"), "La Poste Mobile · réseau Bouygues Telecom")
        XCTAssertEqual(SpeedtestAccountHistory.operatorLabel(display: .init(brand: nil, network: "Orange", networkKey: "ORANGE"), raw: "Sosh"), "Orange")
        XCTAssertEqual(SpeedtestAccountHistory.operatorLabel(display: .init(brand: "La Poste Mobile", network: "Cloudflare, Inc.", networkKey: nil), raw: nil), "La Poste Mobile")
        XCTAssertNil(SpeedtestAccountHistory.operatorLabel(display: .init(brand: nil, network: "Cloudflare, Inc.", networkKey: nil), raw: "Cloudflare, Inc."))
        XCTAssertEqual(SpeedtestAccountHistory.operatorLabel(display: nil, raw: "Orange"), "Orange")

        let base = #""id":"x","timestamp":"2026-11-10T10:00:00.000Z","averageSpeed":80,"connectionType":"CELLULAR","networkType":"LTE""#
        let result = SpeedtestAccountHistory.runResult(from: try detail("{\(base),\"mobileOperator\":\"Bouygues Telecom\",\"operatorDisplay\":{\"brand\":\"La Poste Mobile\",\"brandSource\":\"sim-column\",\"network\":\"Bouygues Telecom\",\"networkKey\":\"BOUYGUES\"}}"))
        XCTAssertEqual(result.networkOperatorName, "Bouygues Telecom", "le partage nomme le réseau")
        XCTAssertEqual(result.networkShareDisplayName, "La Poste Mobile · réseau Bouygues Telecom 4G")

        let listed = try JSONDecoder.signalQuest.decode(SocialShareableSpeedtest.self, from: Data("""
        {"id":"y","averageSpeed":50,"networkType":"LTE","mobileOperator":"Bouygues Telecom",
         "operatorDisplay":{"brand":"La Poste Mobile","brandSource":"sim-column","network":"Bouygues Telecom","networkKey":"BOUYGUES"}}
        """.utf8))
        XCTAssertEqual(AccountSpeedtestRow(test: listed).subtitleLine, "4G · La Poste Mobile · réseau Bouygues Telecom")
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

