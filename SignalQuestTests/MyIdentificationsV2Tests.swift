import XCTest
@testable import SignalQuest

/// « Mes identifications » v2 : vecteur `contracts/identify/my-identifications-v2.json`,
/// copié à l'octet depuis le serveur (1e3859bbc, servi par 88d9988dd).
@MainActor
final class MyIdentificationsV2Tests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/identify/my-identifications-v2.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func page(_ name: String) throws -> MyIdentificationsPage {
        let examples = try XCTUnwrap(try vector()["examples"] as? [String: Any])
        let raw = try XCTUnwrap(examples[name])
        return try JSONDecoder.signalQuest.decode(MyIdentificationsPage.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    // MARK: Décodage des pages d'exemple

    func testOrphanPageDecodesAsCellsWithoutNode() throws {
        let page = try page("orphanPage")
        let orphan = try XCTUnwrap(page.identifications.first)
        XCTAssertTrue(orphan.orphan)
        XCTAssertNil(page.totals, "Pages suivantes : totals vaut null")
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(orphan.sectorCheck?.status, .unknown)
        XCTAssertNil(orphan.sectorCheck?.expected)

        // Elle garde son eNB, mais aucune ligne nœud active ne la porte.
        XCTAssertEqual(orphan.enb, "1043648")
        let groups = IdentifiedNodeGroup.group(page.identifications)
        XCTAssertEqual(groups.map(\.kind), [.unassigned])
    }

    func testTruncatedNodeCarriesItsFlagAndAMismatchWithExpectedSector() throws {
        let page = try page("cellsTruncatedNode")
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.nextCursor, "eyJwIjoibiJ9")
        let totals = try XCTUnwrap(page.totals)
        XCTAssertEqual(totals.cellRows, 4001)
        XCTAssertEqual(totals.orphanRows, 0)
        XCTAssertEqual(totals.conflicts, 0)

        let node = try XCTUnwrap(page.identifications.first { $0.kind == .enb })
        XCTAssertTrue(node.cellsTruncated)
        XCTAssertEqual(node.conflictStatus, .ok)
        let cell = try XCTUnwrap(page.identifications.first { $0.kind == .cellid })
        XCTAssertEqual(cell.sectorCheck?.status, .mismatch)
        XCTAssertEqual(cell.sectorCheck?.expected, 2)

        let group = try XCTUnwrap(IdentifiedNodeGroup.group(page.identifications).first)
        XCTAssertTrue(group.cellsTruncated)
        XCTAssertEqual(group.cells.count, 1)
    }

    func testRestartAdvisedPageHasNoTotals() throws {
        let page = try page("restartAdvisedPage")
        XCTAssertTrue(page.restartAdvised)
        XCTAssertNil(page.totals)
    }

    /// Un contrôle indisponible ne vaut jamais « aucun conflit ».
    func testUnavailableConflictCheckIsExplicit() throws {
        let page = try page("conflictUnavailablePage")
        XCTAssertEqual(page.checks.conflict, .unavailable)
        XCTAssertEqual(page.checks.sectorCheck, .ok)
        XCTAssertNil(page.totals?.conflicts)
        XCTAssertNil(page.totals?.contested)
        let node = try XCTUnwrap(page.identifications.first)
        XCTAssertTrue(node.conflictCheckUnavailable)
        XCTAssertFalse(node.conflict)
    }

    func testContestedNodeAndCellConflictDecode() throws {
        let example = try XCTUnwrap(try vector()["example"])
        let page = try JSONDecoder.signalQuest.decode(MyIdentificationsPage.self,
                                                     from: JSONSerialization.data(withJSONObject: example))
        let node = try XCTUnwrap(page.identifications.first { $0.kind == .enb })
        XCTAssertEqual(node.contested?.reason, .tie)
        XCTAssertEqual(node.contested?.otherSites.first?.siteId, "2603829")
        XCTAssertEqual(node.contested?.otherSites.first?.validations, 1)
        XCTAssertEqual(page.totals?.contested, 1)

        let cell = try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data("""
        {"id":"c","siteId":"1","type":"cellid","ci":"267173891","cellConflict":{"reason":"pci_mismatch","pci":"42"}}
        """.utf8))
        XCTAssertEqual(cell.cellConflict?.reason, .pciMismatch)
        XCTAssertEqual(cell.cellConflict?.pci, "42")
        let unknown = try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data("""
        {"id":"c","siteId":"1","type":"cellid","cellConflict":{"reason":"later"},"sectorCheck":{"status":"later"}}
        """.utf8))
        XCTAssertNil(unknown.cellConflict, "Une raison inconnue n'invente pas de phrase")
        XCTAssertNil(unknown.sectorCheck)
    }

    /// `expected` n'existe que pour `mismatch` ; un écart sans secteur attendu n'a rien à proposer.
    func testExpectedSectorOnlyComesWithAMismatch() throws {
        func check(_ json: String) throws -> IdentificationSectorCheck {
            try JSONDecoder.signalQuest.decode(IdentificationSectorCheck.self, from: Data(json.utf8))
        }
        XCTAssertNil(try check(#"{"status":"match","expected":2}"#).expected)
        XCTAssertEqual(try check(#"{"status":"mismatch","expected":0}"#).expected, 0, "SFR en base 0")
        XCTAssertEqual(try check(#"{"status":"mismatch","expected":null}"#).status, .unknown)
    }

    /// Sans `checks`, rien n'est conclu ; plusieurs pages gardent le pire état.
    func testMissingChecksAreUnavailableAndMergeKeepsTheWorst() throws {
        let page = try JSONDecoder.signalQuest.decode(MyIdentificationsPage.self, from: Data(#"{"identifications":[]}"#.utf8))
        XCTAssertEqual(page.checks, .unavailable)
        XCTAssertFalse(page.truncated)
        let ok = IdentificationChecks(conflict: .ok, cellConflict: .ok, sectorCheck: .ok)
        let merged = ok.merged(with: IdentificationChecks(conflict: .ok, cellConflict: .unavailable, sectorCheck: .ok))
        XCTAssertEqual(merged.cellConflict, .unavailable)
        XCTAssertEqual(merged.conflict, .ok)
    }

    /// L'ordre du serveur (createdAt décroissant) est gardé : pas de retri sur
    /// lastValidated, qui ferait sauter les nœuds pendant le défilement.
    func testGroupsKeepServerOrder() throws {
        let items = try JSONDecoder.signalQuest.decode([MyIdentification].self, from: Data("""
        [{"id":"a","siteId":"1","type":"enb","enb":"2","lastValidated":"2026-10-01T00:00:00.000Z"},
         {"id":"b","siteId":"1","type":"enb","enb":"1","lastValidated":"2026-10-27T00:00:00.000Z"}]
        """.utf8))
        XCTAssertEqual(IdentifiedNodeGroup.group(items).map(\.nodeValue), ["2", "1"])
    }

    // MARK: Pagination

    func testPagesAppendKeepFirstTotalsAndRestartOnInvalidCursor() async throws {
        let service = PagedIdentifyService()
        let first = try page("cellsTruncatedNode")
        let next = try page("restartAdvisedPage")
        service.pages = [nil: first, "eyJwIjoibiJ9": next]
        let model = MyIdentificationsViewModel(service: service)

        await model.load()
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(model.counts[.all], 3, "Compteurs pris dans les totaux, avant la dernière page")
        XCTAssertEqual(model.conflictCount, 0)

        await model.loadMore()
        XCTAssertFalse(model.hasMore)
        XCTAssertTrue(model.restartAdvised)
        XCTAssertEqual(model.totals?.cellRows, 4001, "Les totaux de la première page restent")
        XCTAssertEqual(Set(model.items.map(\.id)), ["ex-big", "ex-big-c1", "ex-next"])

        // Curseur refusé : retour à la première page, sans message.
        service.invalidCursor = true
        await model.load()
        await model.loadMore()
        XCTAssertNil(model.loadMoreError)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(service.requests.suffix(3).map(\.cursor), [nil, "eyJwIjoibiJ9", nil])

        // Un second refus juste après la reprise s'affiche au lieu de boucler.
        service.invalidCursor = true
        await model.loadMore()
        XCTAssertEqual(model.loadMoreError, String(localized: "Impossible de charger la suite"))
        XCTAssertEqual(service.requests.last?.cursor, "eyJwIjoibiJ9", "Pas de nouvelle première page")
    }

    func testConflictBannerFiltersOnTheServer() async throws {
        let service = PagedIdentifyService()
        service.pages = [nil: try page("conflictUnavailablePage")]
        let model = MyIdentificationsViewModel(service: service)
        await model.load()
        XCTAssertNil(model.conflictCount, "Indisponible : on ne compte rien")
        XCTAssertTrue(model.conflictCheckUnavailable)

        await model.setConflictOnly(true)
        XCTAssertEqual(service.requests.last?.conflictOnly, true)
        XCTAssertTrue(model.conflictOnly)
        await model.setConflictOnly(false)
        XCTAssertEqual(service.requests.last?.conflictOnly, false)
    }

    /// Écart de secteur : « Corriger le secteur » part du secteur de la règle
    /// (numérotation stockée, Orange en base 1), le membre restant libre.
    func testSectorSheetPreselectsTheExpectedSector() async throws {
        let cell = try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data("""
        {"id":"c","siteId":"799050","type":"cellid","ci":"267173891","operator":"ORANGE","operatorMcc":208,
         "operatorMnc":1,"marketCode":"FR","sectors":[1],"sectorCheck":{"status":"mismatch","expected":2}}
        """.utf8))
        let antennas = AzimuthAntennasService()
        let prefilled = SectorEditViewModel(item: cell, antennas: antennas, identify: PagedIdentifyService(),
                                            prefilledSector: cell.sectorCheck?.expected)
        await prefilled.load()
        XCTAssertEqual(prefilled.selectedIndex, 1, "Secteur 2 d'Orange = deuxième azimut")
        let plain = SectorEditViewModel(item: cell, antennas: antennas, identify: PagedIdentifyService())
        await plain.load()
        XCTAssertEqual(plain.selectedIndex, 0, "Sans écart : le secteur enregistré")
    }

    // MARK: Requêtes

    func testMinePageQueryAndAdoptConsensusBody() async throws {
        let client = APIClient(
            config: .test,
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
            session: Self.mockSession()
        )
        var query: String?
        var body: [String: Any] = [:]
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "POST", let data = Self.requestBody(request) {
                body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"success":true,"moved":3,"toSiteId":"2603829"}"#.utf8))
            }
            query = request.url?.query
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"identifications":[],"nextCursor":null,"truncated":false,"restartAdvised":false,"checks":{"conflict":"ok","cellConflict":"ok","sectorCheck":"ok"},"totals":{"nodes":0,"enb":0,"gnb":0,"cellRows":0,"orphanRows":0,"conflicts":0,"contested":0}}"#.utf8))
        }
        let service = IdentifyService(api: client)

        _ = try await service.minePage(cursor: "abc", conflictOnly: true, includeRelated: true, limit: nil)
        XCTAssertEqual(query, "v=2&include=related&conflict=only&cursor=abc")
        let first = try await service.minePage(cursor: nil, conflictOnly: false, includeRelated: false, limit: 1)
        XCTAssertEqual(query, "v=2&limit=1")
        XCTAssertEqual(first.totals?.nodes, 0)

        let moved = try await service.adoptConsensus(fromSiteId: "799050", toSiteId: "2603829", enb: "1043648", gnb: nil)
        XCTAssertEqual(moved.moved, 3)
        XCTAssertEqual(body as NSDictionary, [
            "fromSiteId": "799050", "toSiteId": "2603829", "enb": "1043648", "adoptConsensus": true
        ] as NSDictionary, "toSiteId est toujours le support affiché")
    }

    private static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

// MARK: - Doublure

private final class PagedIdentifyService: IdentifyServicing, @unchecked Sendable {
    struct Request { let cursor: String?; let conflictOnly: Bool }
    var pages: [String?: MyIdentificationsPage] = [:]
    var invalidCursor = false
    var requests: [Request] = []

    func minePage(cursor: String?, conflictOnly: Bool, includeRelated: Bool, limit: Int?) async throws -> MyIdentificationsPage {
        requests.append(Request(cursor: cursor, conflictOnly: conflictOnly))
        if cursor != nil, invalidCursor {
            invalidCursor = false
            throw APIError.http(status: 400, code: "INVALID_CURSOR", message: "", requestId: nil, retryAfter: nil)
        }
        guard let page = pages[cursor] else { throw APIError.cancelled }
        return page
    }

    func identify(_ request: IdentifyDirectRequest) async throws -> IdentifyResult { throw APIError.cancelled }
    func mine(includeRelated: Bool) async throws -> [MyIdentification] { [] }
    func withdraw(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> WithdrawResult { throw APIError.cancelled }
    func delete(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> DeleteResult { throw APIError.cancelled }
    func editSite(fromSiteId: String, toSiteId: String, enb: String?, gnb: String?, reason: String?) async throws -> EditSiteResult { throw APIError.cancelled }
    func editSectors(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, operatorName: String, marketCode: String?, sectors: [Int]) async throws -> EditSectorsResult { throw APIError.cancelled }
}

private struct AzimuthAntennasService: AntennasServicing {
    func list(bbox: BoundingBox) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, sharing: Set<String>) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, bandMatch: BandMatchMode, sharing: Set<String>) async throws -> [AntennaSite] { [] }
    func details(id: String) async throws -> AntennaDetails { try await details(id: id, market: "FR", operatorName: "ORANGE") }
    func details(id: String, market: String, operatorName: String) async throws -> AntennaDetails {
        try JSONDecoder.signalQuest.decode(AntennaDetails.self, from: Data("""
        {"antenna":{"id":"799050","supId":"799050","lat":45.0,"lng":5.0,"operators":["ORANGE"],"technologies":["4G"],"azimuts":[0,120,240]}}
        """.utf8))
    }
    func details(id: String, market: String, operatorName: String, anfrCode: String?) async throws -> AntennaDetails {
        try await details(id: id, market: market, operatorName: operatorName)
    }
    func search(query: String) async throws -> [AntennaSite] { [] }
    func quickSearch(query: String, market: String, department: String?) async throws -> [AntennaSite] { [] }
    func listCommunitySites(bbox: BoundingBox, market: String, operatorName: String?) async throws -> [AntennaSite] { [] }
}
