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
        let mismatch = try XCTUnwrap(page.identifications.first { $0.sectorCheck?.status == .mismatch })
        XCTAssertEqual(mismatch.derivedSector, 2, "derivedSector de l'exemple servi")

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

    // MARK: Corriger juste après l'identification (ticket ck2uk3vwvd2p5b8sd6y9p4zvl)

    func testCorrectionFindsTheNodeJustIdentifiedWithItsCells() async throws {
        let first = try page("cellsTruncatedNode")
        let node = try XCTUnwrap(first.identifications.first { $0.kind == .enb })
        let service = PagedIdentifyService()
        service.pages[nil] = first
        service.pages["eyJwIjoibiJ9"] = try page("orphanPage")
        let model = IdentificationCorrectionModel(
            target: IdentificationCorrectionTarget(siteId: node.siteId, kind: .enb, node: try XCTUnwrap(node.enb)),
            service: service
        )
        await model.load()
        guard case let .found(found, cells) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(found.id, node.id)
        XCTAssertEqual(cells.map(\.kind), [.cellid], "les cellules du nœud viennent avec lui, pour corriger leur secteur")
        XCTAssertEqual(service.requests.map(\.cursor), [nil, "eyJwIjoibiJ9"], "filtre refusé : lecture complète, jusqu'au bout")
    }

    func testCorrectionReadsTheNextPagesThenSaysWhenTheNodeIsNotThere() async throws {
        let service = PagedIdentifyService()
        service.pages[nil] = try page("cellsTruncatedNode")
        service.pages["eyJwIjoibiJ9"] = try page("orphanPage")
        let model = IdentificationCorrectionModel(
            target: IdentificationCorrectionTarget(siteId: "000", kind: .enb, node: "1"),
            service: service
        )
        await model.load()
        XCTAssertEqual(model.state, .notFound)
        XCTAssertEqual(service.requests.map(\.cursor), [nil, "eyJwIjoibiJ9"])
    }

    /// Filtre `/mine` (#854) : le support tel qu'écrit et le nœud, puis tout le curseur avant
    /// de conclure. Une page sans la ligne ne dit pas qu'elle n'existe pas.
    func testCorrectionFiltersOnTheNodeAndReadsTheCursorToTheEnd() async throws {
        let node = try XCTUnwrap(try page("cellsTruncatedNode").identifications.first { $0.kind == .enb })
        let empty = try JSONDecoder.signalQuest.decode(MyIdentificationsPage.self,
                                                       from: Data(#"{"identifications":[],"nextCursor":"n2"}"#.utf8))
        let service = PagedIdentifyService()
        service.filteredPages = [nil: empty, "n2": try page("cellsTruncatedNode"), "eyJwIjoibiJ9": try page("orphanPage")]
        let model = IdentificationCorrectionModel(
            target: IdentificationCorrectionTarget(siteId: node.siteId, kind: .enb, node: try XCTUnwrap(node.enb)),
            service: service
        )
        await model.load()
        guard case let .found(found, _) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(found.id, node.id)
        XCTAssertEqual(service.filters.map(\.cursor), [nil, "n2", "eyJwIjoibiJ9"], "le curseur est suivi jusqu'au bout")
        XCTAssertEqual(service.filters.first?.siteId, node.siteId)
        XCTAssertEqual(service.filters.first?.enb, node.enb)
        XCTAssertNil(service.filters.first?.gnb)
        XCTAssertTrue(service.requests.isEmpty, "aucune lecture complète quand le filtre répond")

        // Un curseur qui ne s'épuise pas : ni « trouvée » ni « absente ».
        let endless = try JSONDecoder.signalQuest.decode(MyIdentificationsPage.self,
                                                         from: Data(#"{"identifications":[],"nextCursor":"again"}"#.utf8))
        service.filteredPages = [nil: endless, "again": endless]
        await model.load()
        XCTAssertEqual(model.state, .failed(String(localized: "Tes identifications n’ont pas pu être lues en entier. Réessaie.")))
    }

    func testAWithdrawalThatMatchedNothingKeepsTheSheetOpenWithTheReason() async throws {
        let first = try page("cellsTruncatedNode")
        let node = try XCTUnwrap(first.identifications.first { $0.kind == .enb })
        let service = PagedIdentifyService()
        service.withdrawAnswer = #"{"success":true,"withdrawn":0}"#
        let model = IdentificationCorrectionModel(
            target: IdentificationCorrectionTarget(siteId: node.siteId, kind: .enb, node: "1"),
            service: service
        )
        let withdrawn = await model.withdraw(node)
        XCTAssertNil(withdrawn)
        XCTAssertEqual(model.actionError, IdentificationCorrectionText.nothingChanged)

        service.withdrawAnswer = #"{"success":true,"withdrawn":2}"#
        let again = await model.withdraw(node)
        XCTAssertEqual(again, String(localized: "Identification retirée."))
        XCTAssertNil(model.actionError)

        // Raison facultative (planche 3) : vide, rien n'est envoyé ; sinon nettoyée et bornée à 280.
        _ = await model.withdraw(node, reason: "  ")
        _ = await model.withdraw(node, reason: " Mauvais support \n")
        _ = await model.withdraw(node, reason: String(repeating: "a", count: 400))
        XCTAssertNil(service.sentReasons[service.sentReasons.count - 3] ?? nil)
        XCTAssertEqual(service.sentReasons[service.sentReasons.count - 2], "Mauvais support")
        XCTAssertEqual(service.sentReasons.last??.count, 280)
    }

    func testADeletionOfASharedLineSaysItWasOnlyWithdrawnForTheMember() async throws {
        let node = try XCTUnwrap(try page("cellsTruncatedNode").identifications.first { $0.kind == .enb })
        let service = PagedIdentifyService()
        let model = IdentificationCorrectionModel(
            target: IdentificationCorrectionTarget(siteId: node.siteId, kind: .enb, node: "1"),
            service: service
        )
        service.deleteAnswer = #"{"success":true,"deleted":0,"softWithdrawn":1}"#
        let shared = await model.delete(node)
        XCTAssertEqual(shared, String(localized: "Identification retirée pour toi. D’autres l’ont confirmée, leur travail reste."))
        service.deleteAnswer = #"{"success":true,"deleted":2,"softWithdrawn":0}"#
        let own = await model.delete(node)
        XCTAssertEqual(own, String(localized: "Identification supprimée."))
    }

    /// « Corriger » s'ouvre sur la cellule que le membre a vue, pas sur la première de la liste.
    func testCorrectionOpensOnTheObservedCell() throws {
        let cells = try ["11", "214", "216"].map { pci in
            try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data("""
            {"id":"\(pci)","siteId":"799050","type":"pci","pci":\(pci),"pciValue":"\(pci)","enb":"81234","sectors":[1]}
            """.utf8))
        }
        XCTAssertEqual(IdentificationCorrectionModel.observedCell(in: cells, observedPcis: [999, 216, 214])?.id, "216")
        XCTAssertEqual(IdentificationCorrectionModel.observedCell(in: cells, observedPcis: [])?.id, "11")
    }

    /// Sur un écart, le secteur du PCI est la référence en pointillés ; le choix reste le
    /// secteur enregistré. Changer de cellule repart du secteur de la nouvelle cellule.
    func testSectorSheetShowsThePciReferenceAndSwitchesCells() async throws {
        let mismatch = try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data("""
        {"id":"a","siteId":"799050","type":"cellid","ci":"267173891","operator":"ORANGE","operatorMcc":208,
         "operatorMnc":1,"marketCode":"FR","sectors":[1],"sectorCheck":{"status":"mismatch","expected":2}}
        """.utf8))
        let match = try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data("""
        {"id":"b","siteId":"799050","type":"cellid","ci":"267173892","operator":"ORANGE","operatorMcc":208,
         "operatorMnc":1,"marketCode":"FR","sectors":[2],"sectorCheck":{"status":"match"}}
        """.utf8))
        let model = SectorEditViewModel(item: mismatch, cells: [mismatch, match], antennas: AzimuthAntennasService(),
                                        identify: PagedIdentifyService())
        await model.load()
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.referenceIndex, 1, "secteur 2 d'Orange = deuxième azimut")
        XCTAssertFalse(model.selectionMatchesPci)

        model.select(cell: match)
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertNil(model.referenceIndex)
        XCTAssertTrue(model.selectionMatchesPci)

        let untrusted = SectorEditViewModel(item: mismatch, antennas: AzimuthAntennasService(),
                                            identify: PagedIdentifyService(), trustsSectorCheck: false)
        await untrusted.load()
        XCTAssertNil(untrusted.referenceIndex, "contrôle indisponible : aucune référence montrée")
        XCTAssertTrue(untrusted.cells.isEmpty)
    }

    /// Support sans schéma (au plus un azimut) : une liste de trois secteurs, extensible, dans
    /// la convention de l'opérateur. Pour SFR : 0, 1, 2 puis 3, et le numéro envoyé est le même.
    func testASiteWithoutAzimuthsOffersAListInTheOperatorsNumbering() async throws {
        let sfr = try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data("""
        {"id":"s","siteId":"799050","type":"pci","pci":214,"pciValue":"214","operator":"SFR","operatorMcc":208,
         "operatorMnc":10,"marketCode":"FR","sectors":[0]}
        """.utf8))
        let service = PagedIdentifyService()
        for azimuts: [Double] in [[], [140]] {
            let model = SectorEditViewModel(item: sfr, antennas: AzimuthAntennasService(azimuts: azimuts), identify: service)
            await model.load()
            XCTAssertTrue(model.usesList, "\(azimuts.count) azimut(s) : pas de schéma")
            XCTAssertEqual(model.slotCount, 3)
            XCTAssertEqual((0..<3).map(model.sectorLabel(forIndex:)), [0, 1, 2])
            XCTAssertEqual(model.selectedIndex, 0, "le secteur 0 enregistré par SFR est retrouvé")
        }
        let model = SectorEditViewModel(item: sfr, antennas: AzimuthAntennasService(azimuts: []), identify: service)
        await model.load()
        model.addListSlot()
        XCTAssertEqual(model.sectorLabel(forIndex: 3), 3)
        model.selectedIndex = 3
        await model.submit()
        XCTAssertEqual(service.sentSectors.last, [3])

        // Borne commune de 6 lignes ; un secteur enregistré au-delà reste affiché et choisi.
        for _ in 0..<10 { model.addListSlot() }
        XCTAssertEqual(model.slotCount, SectorEditViewModel.maxListCount)
        let beyond = try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data("""
        {"id":"t","siteId":"799050","type":"pci","pci":214,"pciValue":"214","operator":"SFR","operatorMcc":208,
         "operatorMnc":10,"marketCode":"FR","sectors":[9]}
        """.utf8))
        let wide = SectorEditViewModel(item: beyond, antennas: AzimuthAntennasService(azimuts: []), identify: service)
        await wide.load()
        XCTAssertEqual(wide.slotCount, 10)
        XCTAssertEqual(wide.selectedIndex, 9)
        wide.addListSlot()
        XCTAssertEqual(wide.slotCount, 10, "« Ajouter » ne raccourcit jamais la liste")
    }

    /// `derivedSector` (02/11) : la référence du PCI se montre avant tout choix, même sans
    /// secteur enregistré ; absent, rien n'est deviné.
    func testDerivedSectorIsShownBeforeTheChoiceAndNeverGuessed() async throws {
        let derived = try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data("""
        {"id":"c","siteId":"799050","type":"cellid","ci":"267173893","operator":"SFR","operatorMcc":208,
         "operatorMnc":10,"marketCode":"FR","sectors":[],"sectorCheck":{"status":"not_applicable"},"derivedSector":1}
        """.utf8))
        XCTAssertEqual(derived.derivedSector, 1)
        let model = SectorEditViewModel(item: derived, antennas: AzimuthAntennasService(), identify: PagedIdentifyService())
        await model.load()
        XCTAssertNil(model.selectedIndex)
        XCTAssertEqual(model.referenceIndex, 1, "SFR en base 0 : secteur 1 = deuxième azimut")
        model.selectedIndex = 1
        XCTAssertNil(model.referenceIndex)
        XCTAssertTrue(model.selectionMatchesPci)

        let absent = try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data("""
        {"id":"d","siteId":"799050","type":"cellid","ci":"267173894","operator":"SFR","operatorMcc":208,
         "operatorMnc":10,"marketCode":"FR","sectors":[],"sectorCheck":{"status":"not_applicable"}}
        """.utf8))
        XCTAssertNil(absent.derivedSector)
        let none = SectorEditViewModel(item: absent, antennas: AzimuthAntennasService(), identify: PagedIdentifyService())
        await none.load()
        none.selectedIndex = 0
        XCTAssertNil(none.referenceIndex)
        XCTAssertFalse(none.selectionMatchesPci)
    }

    /// Déplacer (planche 4) : la cible du conflit est présélectionnée une fois, la vue
    /// l'englobe, et la distance au support actuel est donnée.
    @MainActor
    func testMoveSelectsTheConflictTargetAndKnowsTheDistance() async throws {
        let node = try JSONDecoder.signalQuest.decode(MyIdentification.self, from: Data("""
        {"id":"n","siteId":"799050","type":"enb","enb":"80977","operator":"ORANGE","marketCode":"FR","conflict":true,
         "conflictSiteId":"799051","conflictSiteValidations":3,"conflictSiteLat":45.009,"conflictSiteLng":5.0}
        """.utf8))
        func site(_ id: String, _ lat: Double) -> AntennaSite {
            AntennaSite(id: id, siteId: id, latitude: lat, longitude: 5.0, operators: ["ORANGE"], technologies: ["4G"],
                        bands: [], azimuths: [], sharingType: nil, crozonLeader: nil, address: nil, height: nil, owner: nil)
        }
        var antennas = AzimuthAntennasService()
        antennas.sites = [site("799050", 45.0), site("799051", 45.009), site("799052", 45.02)]
        let model = SiteRemapViewModel(item: node, antennas: antennas, identify: PagedIdentifyService(), location: LocationService())
        await model.prepareCenter()
        XCTAssertGreaterThan(model.initialSpanMeters, 1_000)
        XCTAssertEqual(model.initialCenter?.latitude ?? 0, 45.0045, accuracy: 0.0001, "la vue englobe les deux supports")

        model.load(bbox: BoundingBox(north: 45.05, south: 44.95, east: 5.05, west: 4.95))
        for _ in 0..<50 where model.selected == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.selected?.siteId, "799051")
        XCTAssertEqual(try XCTUnwrap(model.distanceFromCurrent(to: site("799051", 45.009))), 1_000, accuracy: 15)

        // Un autre choix du membre n'est pas écrasé au rechargement suivant.
        model.selected = site("799052", 45.02)
        model.load(bbox: BoundingBox(north: 45.05, south: 44.95, east: 5.05, west: 4.95))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.selected?.siteId, "799052")
    }

    /// Les lignes du log que le membre a identifiées : nœud et support, jamais la seule cellule.
    func testLogRowsKnowWhichNodesTheMemberIdentified() throws {
        let items = try page("cellsTruncatedNode").identifications
        let keys = RadioLogsViewModel.nodeKeys(items)
        let node = try XCTUnwrap(items.first { $0.kind == .enb })
        XCTAssertTrue(keys.contains(RadioLogsViewModel.nodeKey(kind: .enb, node: try XCTUnwrap(node.enb), siteId: node.siteId)))
        XCTAssertEqual(keys.count, 1, "les cellules ne font pas de clé à elles seules")
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
    struct Filter { let cursor: String?; let siteId: String; let enb: String?; let gnb: String? }
    /// nil : le serveur refuse le filtre (`INVALID_FILTER`), comme avant #854.
    var filteredPages: [String?: MyIdentificationsPage]?
    var filters: [Filter] = []

    func minePage(cursor: String?, siteId: String, enb: String?, gnb: String?) async throws -> MyIdentificationsPage {
        filters.append(Filter(cursor: cursor, siteId: siteId, enb: enb, gnb: gnb))
        guard let filteredPages else {
            throw APIError.http(status: 400, code: "INVALID_FILTER", message: "", requestId: nil, retryAfter: nil)
        }
        guard let page = filteredPages[cursor] else { throw APIError.cancelled }
        return page
    }

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
    var withdrawAnswer = #"{"success":true,"withdrawn":1}"#
    var sentReasons: [String?] = []
    func withdraw(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> WithdrawResult {
        sentReasons.append(reason)
        return try JSONDecoder().decode(WithdrawResult.self, from: Data(withdrawAnswer.utf8))
    }
    var deleteAnswer = #"{"success":true,"deleted":1,"softWithdrawn":0}"#
    func delete(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> DeleteResult {
        try JSONDecoder().decode(DeleteResult.self, from: Data(deleteAnswer.utf8))
    }
    func editSite(fromSiteId: String, toSiteId: String, enb: String?, gnb: String?, reason: String?) async throws -> EditSiteResult { throw APIError.cancelled }
    var sentSectors: [[Int]] = []
    func editSectors(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, operatorName: String, marketCode: String?, sectors: [Int]) async throws -> EditSectorsResult {
        sentSectors.append(sectors)
        return try JSONDecoder().decode(EditSectorsResult.self, from: Data(#"{"success":true,"applied":true,"updated":1}"#.utf8))
    }
}

private struct AzimuthAntennasService: AntennasServicing {
    var azimuts: [Double] = [0, 120, 240]
    var sites: [AntennaSite] = []
    func list(bbox: BoundingBox) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>) async throws -> [AntennaSite] { sites }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, sharing: Set<String>) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, bandMatch: BandMatchMode, sharing: Set<String>) async throws -> [AntennaSite] { [] }
    func details(id: String) async throws -> AntennaDetails { try await details(id: id, market: "FR", operatorName: "ORANGE") }
    func details(id: String, market: String, operatorName: String) async throws -> AntennaDetails {
        try JSONDecoder.signalQuest.decode(AntennaDetails.self, from: Data("""
        {"antenna":{"id":"799050","supId":"799050","lat":45.0,"lng":5.0,"operators":["ORANGE"],"technologies":["4G"],"azimuts":\(azimuts)}}
        """.utf8))
    }
    func details(id: String, market: String, operatorName: String, anfrCode: String?) async throws -> AntennaDetails {
        try await details(id: id, market: market, operatorName: operatorName)
    }
    func search(query: String) async throws -> [AntennaSite] { [] }
    func quickSearch(query: String, market: String, department: String?) async throws -> [AntennaSite] { [] }
    func listCommunitySites(bbox: BoundingBox, market: String, operatorName: String?) async throws -> [AntennaSite] { [] }
}
