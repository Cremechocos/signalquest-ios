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

    /// IOS-037 lot 2 : la fiche relit ce que le serveur sert en plus (test Android compris), le nom du
    /// Wi-Fi seulement pour son propriétaire ; l'envoi iOS porte la même note, à grandeur égale.
    func testServedSpeedtestExtrasAndTheSubmittedLoadedLatencyGrade() throws {
        let served = try detail("""
        {"id":"cksp2","timestamp":"2026-11-24T10:00:00.000Z","averageSpeed":300,"connectionType":"wifi","connectionKind":"wifi",
         "uploadServerName":"Paris BBR","wifiSsid":"Maison-5G","radioTechChangedDuringTest":true,
         "bufferbloatGrade":"B","bufferbloatDeltaMs":21,"packetLossPct":12.5,"pingSampleCount":8,"streams":16}
        """)
        let owner = SpeedtestAccountHistory.runResult(from: served)
        XCTAssertEqual(owner.uploadServerName, "Paris BBR")
        XCTAssertEqual(owner.wifiSSID, "Maison-5G")
        XCTAssertEqual(owner.networkChangedDuringTest, true)
        XCTAssertEqual(owner.servedBufferbloatGrade, "B")
        XCTAssertEqual(owner.packetLossPct, 12.5)
        XCTAssertEqual(owner.pingSampleCount, 8)
        XCTAssertEqual(owner.streamCount, 16)
        XCTAssertEqual(SpeedtestDetailContent.packetLossText(12.5, pings: 8), "12,5 % sur 8 pings")
        XCTAssertNil(SpeedtestAccountHistory.runResult(from: served, includesPrivateDetails: false).wifiSSID)
        let bogus = try detail(#"{"id":"x","bufferbloatGrade":"Z","packetLossPct":140}"#)
        XCTAssertNil(bogus.bufferbloatGrade)
        XCTAssertNil(bogus.packetLossPct)

        // Envoi : moyenne en charge du pire sens (57) contre moyenne au repos (24) → 33 ms, C.
        var local = SpeedtestRunResult(label: "t", downloadMbps: 300, downloadAverageMbps: 300, downloadMaxMbps: 310,
                                       pingMs: 24, pingMinMs: 14, pingDlMs: 42, pingUlMs: 57,
                                       durationSeconds: 20, connectionType: .wifi, wifiSSID: " Maison-5G ",
                                       serverName: "Paris BBR", downloadServerName: "Paris BBR",
                                       downloadServerHost: "paris.bbr.test", pingServerHost: "paris.bbr.test",
                                       uploadServerHost: "paris.bbr.test")
        local.packetLossPct = 0
        local.pingSampleCount = 7
        var payload = SpeedtestSubmission.iosPayload(from: local, streams: 16, deviceModel: "test")
        XCTAssertEqual(payload.bufferbloatGrade, "C")
        XCTAssertEqual(payload.bufferbloatDeltaMs, 33)
        XCTAssertEqual(payload.pingMeasuredOnTestServer, true)
        XCTAssertEqual(payload.uploadServerName, "Paris BBR")
        XCTAssertEqual(payload.wifiSsid, "Maison-5G")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual((json["wifi"] as? [String: Any])?["ssid"] as? String, "Maison-5G")
        XCTAssertEqual(json["packetLossPct"] as? Double, 0)
        XCTAssertEqual(json["pingSampleCount"] as? Int, 7)
        // Latence visée ailleurs que sur le serveur du test : pas de note ; jamais de nom de Wi-Fi en cellulaire.
        let elsewhere = SpeedtestRunResult(label: "t", downloadMbps: 300, downloadAverageMbps: 300, downloadMaxMbps: 310,
                                           pingMs: 24, pingDlMs: 42, durationSeconds: 20, connectionType: .cellular,
                                           wifiSSID: "Maison-5G", downloadServerHost: "paris.bbr.test", pingServerHost: "1.1.1.1")
        payload = SpeedtestSubmission.iosPayload(from: elsewhere, streams: 16, deviceModel: "test")
        XCTAssertNil(payload.bufferbloatGrade)
        XCTAssertEqual(payload.pingMeasuredOnTestServer, false)
        XCTAssertNil(payload.wifiSsid)

        // Perte de paquets, comme Android : échos sans réponse sur échos envoyés, chauffe exclue.
        XCTAssertEqual(speedtestPacketLoss(sent: 7, received: 7), SpeedtestPingLoss(percent: 0, samples: 7))
        XCTAssertEqual(speedtestPacketLoss(sent: 7, received: 6), SpeedtestPingLoss(percent: 14.3, samples: 7))
        XCTAssertEqual(speedtestPacketLoss(sent: 7, received: 9)?.percent, 0, "jamais de perte négative")
        XCTAssertNil(speedtestPacketLoss(sent: 0, received: 0), "rien envoyé : perte inconnue, pas 0 %")
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

    /// AIRMOB-1 (servi le 20/11) : un MVNO multi-réseaux reconnu à son AS s'affiche par sa
    /// marque seule, sans réseau ni couleur, et cette marque ne part jamais à l'envoi.
    func testAirmobBrandIsShownWithoutANetworkAndNeverSent() throws {
        func detected(_ json: String) throws -> DetectedOperator {
            try JSONDecoder.signalQuest.decode(DetectedOperator.self, from: Data(json.utf8))
        }
        let airmob = try detected(#"{"operatorKey":null,"label":null,"shortLabel":null,"color":null,"viaVpn":false,"source":"ip-asn","mvnoKey":"AIRMOB","mvnoLabel":"Airmob","networkKnown":false}"#)
        XCTAssertEqual(airmob.brandWithoutNetwork, "Airmob")
        XCTAssertNil(try detected(#"{"operatorKey":"ORANGE","label":"Orange","shortLabel":"Orange","viaVpn":false,"mvnoKey":null,"mvnoLabel":null,"networkKnown":true}"#).brandWithoutNetwork)
        XCTAssertNil(try detected(#"{"operatorKey":null,"viaVpn":true,"mvnoLabel":"Airmob","networkKnown":false}"#).brandWithoutNetwork, "sous VPN, rien")
        XCTAssertNil(try detected(#"{"operatorKey":null,"label":null,"viaVpn":false}"#).brandWithoutNetwork, "serveur antérieur")

        // Test relu : la marque servie, aucun réseau.
        let base = #""id":"x","timestamp":"2026-11-20T10:00:00.000Z","averageSpeed":80,"uploadSpeed":20,"ping":24,"connectionType":"CELLULAR","networkType":"LTE""#
        let reread = SpeedtestAccountHistory.runResult(from: try detail("{\(base),\"operatorDisplay\":{\"brand\":\"Airmob\",\"brandSource\":\"ip-asn\",\"network\":null,\"networkKey\":null}}"))
        XCTAssertNil(reread.networkOperatorName)
        XCTAssertEqual(reread.displayOperatorName, "Airmob")
        XCTAssertEqual(reread.networkShareDisplayName, "Airmob 4G")
        XCTAssertEqual(SQShareCardBuilder.operatorDisplayName(for: reread), "Airmob")
        let line = try XCTUnwrap(SQShareCardBuilder.networkLine(for: reread))
        XCTAssertEqual(line.name, "Airmob")
        XCTAssertNil(line.barColor, "aucune couleur de réseau")
        XCTAssertNotNil(SpeedtestShareImageRenderer.shareText(for: reread).range(of: "Airmob"))

        // Mesure de l'iPhone : la marque vient de /api/speedtest/operator, l'envoi l'ignore.
        func local(_ connection: NetworkConnectionKind) -> SpeedtestRunResult {
            SpeedtestRunResult(label: "local", downloadMbps: 80, downloadAverageMbps: 80, downloadMaxMbps: 90,
                               durationSeconds: 10, connectionType: connection, cellularTechnology: .fourG,
                               createdAt: Date(timeIntervalSince1970: 1_795_190_000), servedBrand: airmob.brandWithoutNetwork)
        }
        let measured = local(.cellular)
        XCTAssertEqual(measured.displayOperatorName, "Airmob")
        XCTAssertEqual(SpeedtestHistoryRow(result: measured).subtitleLine, "4G · Airmob")
        let payload = SpeedtestSubmission.iosPayload(from: measured, streams: 4, deviceModel: "iPhone")
        XCTAssertNil(payload.mobileOperator, "la marque n'est pas un réseau")
        XCTAssertNil(payload.operatorKey)
        XCTAssertNil(payload.mvnoKey, "le serveur relit l'AS lui-même")
        XCTAssertNil(payload.mvnoName)
        XCTAssertNil(local(.wifi).displayOperatorName, "jamais en Wi-Fi : l'IP décrit la box")
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

    /// Revue du détail (choix d'Alexandre du 22/11) : la commune, l'adresse, le moteur
    /// et le serveur de réception servis remplissent la fiche de l'auteur ; les bandes
    /// (QA-045) et le signal d'un test Android forment le bloc « Signal ».
    func testServedPlaceBandsAndSignalFillTheAuthorsDetail() throws {
        let served = try detail("""
        {"id":"cksp2","timestamp":"2026-11-20T10:00:00.000Z","averageSpeed":212,"connectionType":"CELLULAR",
         "networkType":"5G NSA","mobileOperator":"Orange","latitude":46.159,"longitude":-1.152,
         "city":"La Rochelle","address":"Rue du Minage, 17000 La Rochelle","engine":"iperf3",
         "downloadServerHost":"par.example.net","downloadServerPort":9210,
         "rsrp":-95.4,"rsrq":-11,"snr":14,
         "carriers":[{"tech":"LTE","band":3,"role":"primary"},{"tech":"LTE","band":7,"role":"secondary"},
                     {"tech":"LTE","band":3,"role":"secondary"},{"tech":"NR","band":78,"role":"secondary"},
                     {"tech":"GSM","band":900,"role":"secondary"},{"tech":"NR","band":2000,"role":"secondary"}]}
        """)
        let mine = SpeedtestAccountHistory.runResult(from: served)
        XCTAssertEqual(mine.city, "La Rochelle")
        XCTAssertEqual(mine.address, "Rue du Minage, 17000 La Rochelle")
        XCTAssertEqual(mine.engine, "iperf3")
        XCTAssertEqual(mine.downloadServerHost, "par.example.net")
        XCTAssertEqual(mine.downloadServerPort, 9210)
        let theirs = SpeedtestAccountHistory.runResult(from: served, includesPrivateDetails: false)
        XCTAssertNil(theirs.city, "ni commune ni adresse pour le test d'un autre membre")
        XCTAssertNil(theirs.address)

        let radio = SpeedtestAccountHistory.servedRadio(from: served)
        XCTAssertEqual(radio.bands, "B3 + B7 · n78", "principale d'abord, B3 une seule fois, GSM et n2000 écartés")
        XCTAssertEqual(radio.readings.map(\.label), ["RSRP", "RSRQ", "SINR"])
        XCTAssertEqual(radio.readings.map(\.value), ["-95 dBm", "-11 dB", "14 dB"])
        XCTAssertEqual(radio.readings.map(\.level), [.fair, .good, .good], "seuils SS-RSRP, SS-RSRQ et SINR de l'échelle v3")

        // Une 5G principale passe devant ; un ancien serveur ou un test Wi-Fi n'a pas de bandes.
        XCTAssertEqual(SpeedtestAccountHistory.bandsLine([
            SpeedtestServingCarrier(tech: "NR", band: 78, role: "primary"),
            SpeedtestServingCarrier(tech: "LTE", band: 20, role: "secondary"),
        ]), "n78 · B20")
        XCTAssertNil(SpeedtestAccountHistory.bandsLine([]))
        let base = #""id":"w","timestamp":"2026-11-20T10:00:00.000Z","averageSpeed":90"#
        XCTAssertNil(try detail("{\(base),\"connectionType\":\"WIFI\",\"carriers\":[]}").carriers?.first)
        XCTAssertNil(try detail("{\(base),\"carriers\":{\"tech\":\"LTE\"}}").carriers, "une forme inattendue ne casse pas le détail")

        // Un test iOS (ni bandes ni signal) n'a pas de bloc ; une sentinelle ou une valeur
        // hors plage ne donne pas de ligne.
        XCTAssertTrue(SpeedtestAccountHistory.servedRadio(from: try detail("{\(base),\"networkType\":\"4G\"}")).isEmpty)
        let sentinel = SpeedtestAccountHistory.servedRadio(from: try detail("{\(base),\"networkType\":\"LTE\",\"rsrp\":0,\"rsrq\":-60,\"snr\":8}"))
        XCTAssertEqual(sentinel.readings.map(\.label), ["SINR"])
        XCTAssertEqual(SpeedtestAccountHistory.servedRadio(from: try detail("{\(base),\"networkType\":\"5G SA\",\"rsrp\":-85}")).readings.first?.level,
                       .good, "« 5G SA » se lit en SS-RSRP")

        // La forme lue sur la prod le 22/11 (test Android public) : la technologie est dans
        // `connectionType`, `networkType` vaut « CELLULAR ». Le bloc garde ses trois mesures
        // et la ligne Réseau sa technologie.
        let production = try detail("""
        {\(base),"connectionType":"5G SA","networkType":"CELLULAR","connectionKind":"CELLULAR_5G_SA",
         "rsrp":-94,"rsrq":-10,"snr":12,"carriers":[{"tech":"NR","band":78,"role":"primary"}]}
        """)
        let productionRadio = SpeedtestAccountHistory.servedRadio(from: production)
        XCTAssertEqual(productionRadio.bands, "n78")
        XCTAssertEqual(productionRadio.readings.map(\.label), ["RSRP", "RSRQ", "SINR"])
        XCTAssertEqual(productionRadio.readings.map(\.level), [.fair, .good, .fair])
        XCTAssertEqual(SpeedtestAccountHistory.runResult(from: production).cellularTechnology, .fiveGSA)
    }
}

