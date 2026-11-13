import XCTest
@testable import SignalQuest

/// OFFICIAL-NEARBY r1 : positions officielles avant création (§1), faits officiels de la fiche (§3)
/// et avertissement après création (§2).
/// Valeurs reprises de registres publics (instantané du 13/11/2026), sans adresse.
final class OfficialNearbyTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func draft(mcc: Int?, operatorKey: String?) throws -> CustomSiteDraft {
        let cell = try JSONDecoder.signalQuest.decode(AndroidCommunitySiteMarker.self, from: Data("""
        {"id": "c1", "lat": 50.96, "lng": 3.97, "radioNodeType": "LTE", "operatorKey": "PROXIMUS_BE",
         "observationCount": 3, "mcc": 206, "mnc": 1, "pci": 12, "cellId": "20601001", "enb": "81234"}
        """.utf8))
        var draft = CustomSiteDraft.fromObservedCells([cell], latitude: 50.9605, longitude: 3.9781, name: "Pylône", type: "PYLONE")
        draft.radio?.mcc = mcc
        draft.radio?.mobileOperator = operatorKey
        return draft
    }

    /// Belgique et Suisse seulement, avec un opérateur ; la position est celle visée par le membre.
    func testQueryIsSentOnlyForBelgiumOrSwitzerlandWithAnOperator() throws {
        let belgium = try XCTUnwrap(OfficialNearbyQuery(draft: try draft(mcc: 206, operatorKey: "PROXIMUS_BE")))
        XCTAssertEqual(belgium.market, "BE")
        XCTAssertEqual(belgium.operator, "PROXIMUS_BE")
        XCTAssertEqual(belgium.lat, 50.9605)
        XCTAssertEqual(belgium.lon, 3.9781)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(belgium)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["lat", "lon", "market", "operator", "radiusM"])
        XCTAssertEqual(body["radiusM"] as? Int, 300)
        XCTAssertEqual(OfficialNearbyQuery(draft: try draft(mcc: 228, operatorKey: "SUNRISE_CH"))?.market, "CH")
        XCTAssertNil(OfficialNearbyQuery(draft: try draft(mcc: 208, operatorKey: "ORANGE")), "France : pas de requête")
        XCTAssertNil(OfficialNearbyQuery(draft: try draft(mcc: 206, operatorKey: nil)), "Sans opérateur, rien à comparer")
    }

    /// Filtre d'Android : même opérateur, 300 m, région connue, siteKey et supId, cinq lignes, la plus
    /// proche d'abord ; enbCount absent = 1 si hasEnb. Un opérateur ignoré par le serveur ne donne rien.
    func testRowsKeepAndroidsFilter() throws {
        func row(_ key: String, op: String = "PROXIMUS_BE", region: String = "BE-VLA", meters: Double,
                 hasEnb: Bool = false, extra: String = "") -> String {
            #"{"siteKey":"\#(key)","supId":"\#(key)","market":"BE","region":"\#(region)","operator":"\#(op)","distanceMeters":\#(meters),"hasEnb":\#(hasEnb),"hasGnb":false\#(extra)}"#
        }
        let rows = [
            row("BE:VLA:A", meters: 250),
            row("BE:VLA:B", meters: 10.2, hasEnb: true),
            row("BE:VLA:C", op: "ORANGE_BE", meters: 20),
            row("BE:VLA:D", meters: 301),
            row("BE:XX:E", region: "BE-WAL", meters: 30),
            #"{"siteKey":"BE:VLA:F","region":"BE-VLA","operator":"PROXIMUS_BE","distanceMeters":40}"#,
            row("BE:BRU:G", region: "BE-BRU", meters: 60, extra: #","enbCount":2"#),
            row("BE:VLA:H", meters: 70), row("BE:VLA:I", meters: 80), row("BE:VLA:J", meters: 90),
        ]
        let data = Data(#"{"sites":[\#(rows.joined(separator: ","))],"operatorIgnored":false}"#.utf8)
        let sites = try OfficialNearbySite.rows(from: data, operatorKey: "proximus_be")
        XCTAssertEqual(sites.map(\.siteKey), ["BE:VLA:B", "BE:BRU:G", "BE:VLA:H", "BE:VLA:I", "BE:VLA:J"])
        XCTAssertEqual(sites.first?.enbCount, 1, "hasEnb sans enbCount : un eNB posé")
        XCTAssertEqual(sites[1].enbCount, 2)
        XCTAssertEqual(sites[1].registryName, "Bruxelles Environnement")
        XCTAssertEqual(sites.first?.market, "BE")
        let ignored = Data(#"{"sites":[\#(row("BE:VLA:A", meters: 5))],"operatorIgnored":true}"#.utf8)
        XCTAssertTrue(try OfficialNearbySite.rows(from: ignored, operatorKey: "PROXIMUS_BE").isEmpty)
    }

    /// POST /api/sites/official-nearby avec la session : le corps du contrat, la réponse filtrée.
    func testServicePostsTheQueryAndFiltersTheAnswer() async throws {
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("test-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let seen = RequestLog()
        MockURLProtocol.requestHandler = { request in
            seen.record(request)
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"sites":[{"siteKey":"CH:BAKOM:Sunrise_ZH301_3_2699484_1263084","supId":"CH:BAKOM:Sunrise_ZH301_3_2699484_1263084","market":"CH","region":"CH","operator":"SUNRISE_CH","distanceMeters":42.6,"hasEnb":false,"hasGnb":false,"enbCount":0}],"operatorIgnored":false}"#
            return (response, Data(body.utf8))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OfficialNearbyTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let service = CustomSitesService(api: client, currentUserId: { "owner" },
                                         outbox: CustomSiteOutboxStore(rootURL: root, keyStore: InMemoryTokenStore()))
        let query = try XCTUnwrap(OfficialNearbyQuery(draft: try draft(mcc: 228, operatorKey: "SUNRISE_CH")))
        let sites = try await service.officialNearby(query)
        XCTAssertEqual(sites.map(\.supId), ["CH:BAKOM:Sunrise_ZH301_3_2699484_1263084"])
        XCTAssertEqual(sites.first?.registryName, "OFCOM")
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.path, "/api/sites/official-nearby")
        let body = try XCTUnwrap(seen.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["market"] as? String, "CH")
        XCTAssertEqual(body["operator"] as? String, "SUNRISE_CH")
    }

    private func details(_ json: String) throws -> OfficialSiteDetails {
        try JSONDecoder.signalQuest.decode(OfficialSiteDetails.self, from: Data(json.utf8))
    }

    /// CH:BAKOM:Sunrise_ZH301_3_2699484_1263084.
    func testSwissPositionReadsItsClassLimitTypeAndOperation() throws {
        let swiss = try details(#"{"powerClass":"medium","powerClassMaxW":5000,"installationLimitVm":5,"installationType":"outdoor_high","adaptiveMode":"partial"}"#)
        XCTAssertEqual(swiss.powerClass, .medium)
        XCTAssertFalse(swiss.isBrussels)
        let fr = Locale(identifier: "fr_FR")
        let watts = 5000.formatted(.number.grouping(.automatic).locale(fr))
        XCTAssertEqual(swiss.powerClassText(locale: fr), "Moyenne, jusqu’à \(watts)\u{00A0}W")
        XCTAssertEqual(swiss.installationLimitText(locale: fr), "5,0\u{00A0}V/m")
        XCTAssertEqual(swiss.installationText, "Extérieure, plus de 6\u{00A0}W\u{00A0}ERP", "Unité jamais coupée de son nombre")
        XCTAssertTrue(swiss.adaptivePartial)
        XCTAssertEqual(swiss.title, "Données officielles OFCOM")
    }

    /// CH:BAKOM:Swisscom_LANS_2762058_1173220 : classe forte, sans plafond ; et le piège
    /// `adaptiveMode: null` PRÉSENT (CH:BAKOM:Sunrise_ZU407_3_2692402_1241977).
    func testHighClassShowsItsFloorAndANullAdaptiveModeShowsNoOperationRow() throws {
        let high = try details(#"{"powerClass":"high","powerClassMaxW":null,"powerClassMinW":5000,"installationLimitVm":5,"installationType":"outdoor_high","adaptiveMode":null}"#)
        let fr = Locale(identifier: "fr_FR")
        XCTAssertEqual(high.powerClassText(locale: fr), "Forte, plus de \(5000.formatted(.number.grouping(.automatic).locale(fr)))\u{00A0}W")
        XCTAssertFalse(high.adaptivePartial)
        let unknown = try details(#"{"powerClass":"giant","installationType":"rooftop"}"#)
        XCTAssertNil(unknown.powerClass, "Valeur inconnue : rien d'inventé")
        XCTAssertNil(unknown.installationType)
        XCTAssertTrue(unknown.isEmpty)
    }

    /// BE:BRU:Bruxelles_1D_octroye_02VVL_42098B1 : seul le nombre d'opérateurs.
    func testBrusselsPositionShowsOnlyItsOperatorCount() throws {
        let brussels = try details(#"{"operatorCount":2}"#)
        XCTAssertTrue(brussels.isBrussels)
        XCTAssertEqual(brussels.operatorCount, 2)
        XCTAssertEqual(brussels.title, "Données officielles Bruxelles Environnement")
        XCTAssertNil(brussels.powerClassText())
    }


    /// `officialDetails` est à la RACINE de la fiche (à côté de `antenna`), quelle que soit la
    /// plateforme ; une fiche française ou un serveur antérieur n'en a pas.
    func testAntennaDetailsReadOfficialDetailsAtTheRoot() throws {
        let swiss = try JSONDecoder.signalQuest.decode(AntennaDetails.self, from: Data("""
        {
          "antenna": {
            "id": "CH:BAKOM:Sunrise_ZH301_3_2699484_1263084", "supId": "CH:BAKOM:Sunrise_ZH301_3_2699484_1263084",
            "lat": 47.51096938959109, "lng": 8.759287377258746,
            "operators": ["SUNRISE_CH"], "technologies": ["5G", "4G"]
          },
          "officialDetails": {"powerClass":"medium","powerClassMaxW":5000,"installationLimitVm":5,"installationType":"outdoor_high","adaptiveMode":"partial"}
        }
        """.utf8))
        XCTAssertEqual(swiss.officialDetails?.powerClass, .medium)
        XCTAssertEqual(swiss.officialDetails?.installationType, .outdoorHigh)
        let french = try JSONDecoder.signalQuest.decode(AntennaDetails.self, from: Data("""
        {"antenna": {"id": "24763", "supId": "24763", "lat": 42.9158, "lng": 1.0139, "operators": ["SFR"], "technologies": ["4G"]}}
        """.utf8))
        XCTAssertNil(french.officialDetails)
        XCTAssertNotNil(french.core, "Le champ additif ne casse pas la fiche")
    }

    func testCreationWarningNamesTheNearestOfficialPosition() throws {
        let result = try JSONDecoder.signalQuest.decode(CustomSiteCreationResult.self, from: Data("""
        {"site":{"id":"cm-new","slug":"pylone"},"warnings":{"nearbyOfficial":[
          {"siteKey":"BE:VLA:53LED_00","supId":"BE:VLA:53LED_00","market":"BE","region":"BE-VLA","operator":"PROXIMUS_BE","distanceMeters":120.4,"hasEnb":false,"hasGnb":false,"enbCount":0},
          {"siteKey":"BE:VLA:C2_40472_G1","supId":"BE:VLA:C2_40472_G1","market":"BE","region":"BE-VLA","operator":"PROXIMUS_BE","distanceMeters":10.2,"hasEnb":false,"hasGnb":false,"enbCount":0}
        ]}}
        """.utf8))
        XCTAssertEqual(result.id, "cm-new")
        XCTAssertEqual(result.nearestOfficialMeters, 10)
        XCTAssertNotNil(result.nearbyOfficialNotice)
        let plain = try JSONDecoder.signalQuest.decode(CustomSiteCreationResult.self, from: Data(#"{"id":"cm-2"}"#.utf8))
        XCTAssertNil(plain.nearestOfficialMeters, "Hors BE/CH ou ancien serveur : pas d'avertissement")
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var data: Data?
    func record(_ request: URLRequest) {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        lock.lock(); self.request = request; data = body; lock.unlock()
    }
    var method: String? { lock.lock(); defer { lock.unlock() }; return request?.httpMethod }
    var path: String? { lock.lock(); defer { lock.unlock() }; return request?.url?.path }
    var body: Data? { lock.lock(); defer { lock.unlock() }; return data }
}
