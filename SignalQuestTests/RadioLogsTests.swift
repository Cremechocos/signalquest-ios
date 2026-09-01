import XCTest
@testable import SignalQuest

/// Verrouille ce qui casserait en silence : le décodage du journal (dont `ci`,
/// qui arrive en CHAÎNE), la fusion idempotente avec pierres tombales,
/// l'agrégation en sites, le critère d'« identifié », et la charge
/// d'`identify/direct` — celle-là même qui envoyait un PLMN sous des noms que le
/// serveur ignore.
final class RadioLogsTests: XCTestCase {

    func testLegacyOperatorAliasNeedsExplicitFrenchEvidence() {
        XCTAssertNil(RadioLogOperatorResolver.operatorKey(forOperator: "ByTel"))
        XCTAssertNil(RadioLogOperatorResolver.marketCode(forOperator: "SFR", mcc: nil))
        XCTAssertNil(RadioLogOperatorResolver.mccMnc(forOperator: "SFR", marketCode: nil))

        XCTAssertEqual(
            RadioLogOperatorResolver.operatorKey(
                forOperator: "ByTel",
                marketCode: "FR"
            ),
            "BOUYGUES"
        )
        XCTAssertEqual(
            RadioLogOperatorResolver.mccMnc(forOperator: "SFR", marketCode: "FR")?.mnc,
            "10"
        )
        XCTAssertEqual(RadioLogOperatorResolver.marketCode(forOperator: nil, mcc: "208"), "FR")
        XCTAssertEqual(RadioLogOperatorResolver.marketCode(forOperator: "ZB", mcc: nil), "FR")
    }

    // MARK: Décodage

    /// `ci` est un `BigInt` côté serveur : `JSON.stringify` refuse de le
    /// sérialiser en nombre, il arrive donc en chaîne. Le décoder en `Int64`
    /// depuis un nombre ferait échouer la ligne entière.
    func testDecodesCiFromString() throws {
        let json = """
        {"items":[{
          "id":"c1","dedupeKey":"cap|1","scope":"cap","technology":"LTE","operator":"SFR",
          "mccMnc":"208-10","enb":"626821","ci":"160466202","pci":35,"band":3,
          "observedAt":"2026-07-01T10:00:00.000Z","updatedAt":"2026-07-01T10:00:00.000Z"
        }],"nextCursor":{"sinceAt":"2026-07-01T10:00:00.000Z","sinceId":"c1"},"hasMore":false,"readOnly":false}
        """
        let page = try JSONDecoder.signalQuest.decode(RadioLogPullPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].ci, 160_466_202)
        XCTAssertEqual(page.items[0].enb, "626821")
        XCTAssertEqual(page.items[0].mcc, "208")
        XCTAssertEqual(page.items[0].mnc, "10")
        XCTAssertEqual(page.nextCursor?.sinceId, "c1")
        XCTAssertFalse(page.hasMore)
    }

    /// Une NCI sur 36 bits peut dépasser la capacité d'un ECI LTE sur 28 bits.
    func testDecodesLargeNrCellIdentity() throws {
        let json = """
        {"items":[{"id":"c2","dedupeKey":"cap|2","scope":"cap","technology":"NR",
        "gnb":"1060426","ci":"17374019585","observedAt":"2026-07-01T10:00:00.000Z",
        "updatedAt":"2026-07-01T10:00:00.000Z"}],"hasMore":false}
        """
        let page = try JSONDecoder.signalQuest.decode(RadioLogPullPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items[0].ci, 17_374_019_585)
        XCTAssertTrue(page.items[0].isNr)
    }

    /// Une ligne malformée ne doit pas emporter le lot entier.
    func testMalformedRowDoesNotDropThePage() throws {
        let json = """
        {"items":[
          {"id":"ok","dedupeKey":"cap|ok","scope":"cap","technology":"LTE","enb":"1",
           "observedAt":"2026-07-01T10:00:00.000Z","updatedAt":"2026-07-01T10:00:00.000Z"},
          {"id":42}
        ],"hasMore":false}
        """
        let page = try JSONDecoder.signalQuest.decode(RadioLogPullPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.map(\.dedupeKey), ["cap|ok"])
    }

    /// `mccMnc` arrive sous plusieurs formes selon l'émetteur.
    func testPlmnSplitAcceptsEveryKnownShape() {
        XCTAssertEqual(RadioLogPlmn.split("208-10")?.mnc, "10")
        XCTAssertEqual(RadioLogPlmn.split("208/15")?.mnc, "15")
        XCTAssertEqual(RadioLogPlmn.split("20810")?.mcc, "208")
        XCTAssertEqual(RadioLogPlmn.split("20810")?.mnc, "10")
        XCTAssertEqual(RadioLogPlmn.split("208001")?.mnc, "001")
        XCTAssertNil(RadioLogPlmn.split(nil))
        XCTAssertNil(RadioLogPlmn.split("  "))
    }

    func testPlmnSplitRejectsShortMncExtraTokensAndNonAsciiDigits() {
        for value in ["3101", "310-1", "208/010/99", "abc20810", "208x10", "٢٠٨١٠"] {
            XCTAssertNil(RadioLogPlmn.split(value), value)
        }
        XCTAssertEqual(RadioLogPlmn.split(" 310 / 001 ")?.mnc, "001")
        XCTAssertNotEqual(RadioLogPlmn.split("310001")?.mnc, RadioLogPlmn.split("31001")?.mnc)
    }

    func testNumericPlmnComponentsStayAmbiguousThroughTheRealDiskCache() throws {
        let entry = try decodeEntry(#"""
        {
          "dedupeKey":"imp|numeric","scope":"imp","technology":"5G NSA",
          "mcc":208,"mnc":10,"operator":"SFR","canonicalOperatorKey":"SFR","marketCode":"FR",
          "ci":"3112966","eciCellId":"6","enb":"12160","gnb":"190"
        }
        """#)
        XCTAssertEqual(entry.observedMcc, "208")
        XCTAssertEqual(entry.observedMnc, "10")
        XCTAssertEqual(entry.plmnEvidence, .legacyAmbiguous)
        XCTAssertNil(entry.servingPlmn)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("radio-provenance-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        RadioLogStore(fileURL: url).merge(incoming: [entry], cursor: nil, nowMs: 1)
        let reloaded = try XCTUnwrap(RadioLogStore(fileURL: url).load().entries.first)
        XCTAssertEqual(reloaded, entry)
        XCTAssertEqual(reloaded.plmnEvidence, .legacyAmbiguous)
        XCTAssertEqual(reloaded.ci, 3_112_966)
        XCTAssertEqual(reloaded.gnb, "190", "Le brut historique reste disponible, sans devenir une preuve")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.signalQuest.encode(reloaded)) as? [String: Any])
        XCTAssertEqual(encoded["mcc"] as? Int, 208)
        XCTAssertEqual(encoded["mnc"] as? Int, 10)
        XCTAssertNil(encoded["mnc"] as? String, "Le cache ne doit pas renforcer la confiance")
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: [reloaded]).first)
        XCTAssertEqual(site.kind, .enb)
        XCTAssertEqual(site.node, "12160")
        XCTAssertNil(site.mcc)
        XCTAssertNil(site.mnc)
        XCTAssertNil(site.operatorName)
        XCTAssertNil(site.resolvedOperatorKey)
        XCTAssertNil(site.resolvedMarketCode)
        XCTAssertNotNil(RadioLogIdentifyPicker.blockingReason(for: site))
    }

    func testNumericAndShortMncNeverBorrowAReconstructedExactPlmn() throws {
        for fields in [
            #""mcc":208,"mnc":1"#,
            #""mcc":"208","mnc":"1""#,
            #""observedPlmn":20801"#,
            #""observedPlmn":"20801","networkIdentityConfidence":"AMBIGUOUS_MNC_WIDTH""#,
            #""observedPlmn":"20801","networkIdentitySource":"LEGACY_AMBIGUOUS""#
        ] {
            let entry = try decodeEntry("{\"dedupeKey\":\"imp|ambiguous\",\"scope\":\"imp\",\"mccMnc\":\"20801\",\(fields)}")
            XCTAssertEqual(entry.plmnEvidence, .legacyAmbiguous, fields)
            XCTAssertNil(entry.servingPlmn, fields)
            let cached = try JSONDecoder.signalQuest.decode(RadioLogEntry.self, from: JSONEncoder.signalQuest.encode(entry))
            XCTAssertEqual(cached.plmnEvidence, .legacyAmbiguous, fields)
        }
    }

    func testNeutralizedServerProjectionKeepsLegacyTokensSourceAndSeparateGroupingKeys() throws {
        let entries = try ["1", "01"].map { mnc in
            try decodeEntry("""
            {"dedupeKey":"imp|legacy-\(mnc)","scope":"imp","technology":"LTE","enb":"42","ci":"10753",
             "observedPlmn":null,"mccMnc":null,"mcc":null,"mnc":null,
             "legacyMccMnc":"208/\(mnc)","legacyMcc":"208","legacyMnc":"\(mnc)",
             "networkIdentitySource":"IMPORT","networkIdentityConfidence":"AMBIGUOUS_MNC_WIDTH"}
            """)
        }
        for entry in entries {
            let reloaded = try JSONDecoder.signalQuest.decode(RadioLogEntry.self, from: JSONEncoder.signalQuest.encode(entry))
            XCTAssertEqual(reloaded, entry)
            XCTAssertEqual(reloaded.legacyMcc, "208")
            XCTAssertEqual(reloaded.legacyMnc, entry.legacyMnc)
            XCTAssertEqual(reloaded.legacyMccMnc, entry.legacyMccMnc)
            XCTAssertEqual(reloaded.networkIdentitySource, "IMPORT")
            XCTAssertEqual(reloaded.networkIdentityConfidence, "AMBIGUOUS_MNC_WIDTH")
            XCTAssertEqual(reloaded.plmnEvidence, .legacyAmbiguous)
            XCTAssertNil(reloaded.servingPlmn)
        }
        let sites = RadioLogSiteBuilder.build(from: entries)
        XCTAssertEqual(sites.count, 2)
        XCTAssertTrue(sites.allSatisfy { $0.resolvedOperatorKey == nil && $0.resolvedMarketCode == nil })
    }

    func testExactObservedPlmnWinsOverConflictingLegacyComponentsAndHomeNetwork() throws {
        let entry = try decodeEntry(#"""
        {
          "dedupeKey":"cap|roaming","technology":"LTE","enb":"42",
          "observedPlmn":"310260","mcc":208,"mnc":15,"mccMnc":"20815",
          "operator":"Free","canonicalOperatorKey":"FREE","canonicalOperatorName":"Free Mobile",
          "marketCode":"FR","simPlmn":"20815","simOperatorName":"Free","isRoaming":true
        }
        """#)
        XCTAssertEqual(entry.servingPlmn, "310260")
        XCTAssertEqual(entry.mcc, "310")
        XCTAssertEqual(entry.mnc, "260")
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: [entry]).first)
        XCTAssertEqual(site.resolvedOperatorKey, "TMOBILE_US")
        XCTAssertEqual(site.operatorName, "T-Mobile")
        XCTAssertEqual(site.resolvedMarketCode, "US")
        XCTAssertEqual(site.rawOperatorName, "Free")
        XCTAssertEqual(site.isRoaming, true)
    }

    func testSimOnlyAndUnregisteredPlmnNeverSelectTheHomeOperator() throws {
        let simOnly = try decodeEntry(#"""
        {
          "dedupeKey":"cap|sim","technology":"LTE","enb":"42","mccMnc":"20815",
          "simPlmn":"20815","operator":"Free","marketCode":"FR","networkIdentitySource":"SIM_ONLY"
        }
        """#)
        XCTAssertNil(simOnly.servingPlmn)
        let unknown = try decodeEntry(#"""
        {
          "dedupeKey":"cap|unknown","technology":"LTE","enb":"42","observedPlmn":"310001",
          "simPlmn":"20815","operator":"Free","canonicalOperatorKey":"FREE","marketCode":"FR"
        }
        """#)
        for entry in [simOnly, unknown] {
            let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: [entry]).first)
            XCTAssertNil(site.resolvedOperatorKey)
            XCTAssertNil(site.operatorName)
            XCTAssertNotEqual(site.resolvedMarketCode, "FR")
        }
    }

    func testAmbiguousAndExactNetworksNeverMergeEvenWithTheSameNodeCiAndPci() throws {
        let ambiguous = try decodeEntry(#"{"dedupeKey":"imp|amb","mcc":208,"mnc":1,"technology":"LTE","enb":"42","ci":"10753","pci":7}"#)
        let exact = try decodeEntry(#"{"dedupeKey":"imp|exact","mcc":"208","mnc":"01","technology":"LTE","enb":"42","ci":"10753","pci":7}"#)
        let threeDigit = try decodeEntry(#"{"dedupeKey":"imp|three","observedPlmn":"310001","technology":"LTE","enb":"42","ci":"10753","pci":7}"#)
        let twoDigit = try decodeEntry(#"{"dedupeKey":"imp|two","observedPlmn":"31001","technology":"LTE","enb":"42","ci":"10753","pci":7}"#)
        let sites = RadioLogSiteBuilder.build(from: [ambiguous, exact, threeDigit, twoDigit])
        XCTAssertEqual(sites.count, 4)
        XCTAssertEqual(Set(sites.map(\.id)).count, 4)
        XCTAssertEqual(sites.compactMap(\.mnc).sorted(), ["001", "01", "01"])
    }

    func testLegacyMixedCacheRetainsExplicitPlmnAndRefreshesOnlyUndecidableTuples() throws {
        let data = Data(#"""
        {
          "entries":[
            {"dedupeKey":"imp|explicit","observedPlmn":"310001","mcc":"310","mnc":"001","networkIdentitySource":"IMPORT"},
            {"dedupeKey":"imp|tuple","mcc":"208","mnc":"10","ci":"3112966"},
            {"dedupeKey":"imp|legacy-full","mccMnc":"208-01"}
          ],
          "cursor":{"sinceAt":"2026-07-01T10:00:00.000Z","sinceId":"last"},"lastSyncedAtMs":1234
        }
        """#.utf8)
        let snapshot = try JSONDecoder.signalQuest.decode(RadioLogSnapshot.self, from: data)
        XCTAssertEqual(snapshot.entries.count, 3)
        XCTAssertEqual(snapshot.entries[0].servingPlmn, "310001")
        XCTAssertEqual(snapshot.entries[0].networkIdentitySource, "IMPORT")
        XCTAssertEqual(snapshot.entries[1].plmnEvidence, .legacyAmbiguous)
        XCTAssertEqual(snapshot.entries[1].observedMnc, "10")
        XCTAssertEqual(snapshot.entries[1].ci, 3_112_966)
        XCTAssertEqual(snapshot.entries[2].servingPlmn, "20801")
        XCTAssertNil(snapshot.cursor)
        XCTAssertNil(snapshot.lastSyncedAtMs)
        let next = try JSONDecoder.signalQuest.decode(RadioLogSnapshot.self, from: JSONEncoder.signalQuest.encode(snapshot))
        XCTAssertEqual(next.entries, snapshot.entries)
        XCTAssertEqual(next.entries[1].plmnEvidence, .legacyAmbiguous)
        let refreshed = try decodeEntry(#"{"dedupeKey":"imp|tuple","mcc":"208","mnc":"010","ci":"3112966"}"#)
        let merged = RadioLogStore.applying(incoming: [refreshed], to: next.entries)
        XCTAssertEqual(merged.first { $0.dedupeKey == "imp|tuple" }?.servingPlmn, "208010")
    }

    func testLegacyCacheWithOnlyExplicitPlmnKeepsItsCursor() throws {
        let data = Data(#"{"entries":[{"dedupeKey":"cap|exact","observedPlmn":"310001"}],"cursor":{"sinceAt":"2026-07-01T10:00:00.000Z","sinceId":"last"},"lastSyncedAtMs":1234}"#.utf8)
        let snapshot = try JSONDecoder.signalQuest.decode(RadioLogSnapshot.self, from: data)
        XCTAssertEqual(snapshot.cursor?.sinceId, "last")
        XCTAssertEqual(snapshot.lastSyncedAtMs, 1234)
        XCTAssertEqual(snapshot.entries.first?.servingPlmn, "310001")
    }

    func testLegacyImportWithLostFormatPreservesPlmnWhileRefreshingOnlyCellEvidence() throws {
        let data = Data(#"""
        {
          "entries":[
            {"dedupeKey":"imp|lost-format","scope":"imp","technology":"NR","observedPlmn":"20810","ci":"2147483647","gnb":"131071"},
            {"dedupeKey":"cap|nr","scope":"cap","technology":"NR","observedPlmn":"20810","ci":"2147483647","gnb":"131071"},
            {"dedupeKey":"imp|known-csv","scope":"imp","technology":"NR","observedPlmn":"20810","ci":"2147483647","gnb":"131071","sourceFileName":"radio.csv"}
          ],
          "cursor":{"sinceAt":"2026-07-01T10:00:00.000Z","sinceId":"last"}
        }
        """#.utf8)
        let snapshot = try JSONDecoder.signalQuest.decode(RadioLogSnapshot.self, from: data)
        XCTAssertTrue(snapshot.entries[0].cellIdentityEvidenceRequiresRefresh)
        XCTAssertEqual(snapshot.entries[0].servingPlmn, "20810", "La preuve PLMN n'est pas dégradée")
        XCTAssertEqual(snapshot.entries[0].ci, 2_147_483_647)
        XCTAssertTrue(RadioLogSiteBuilder.build(from: [snapshot.entries[0]]).isEmpty)
        for entry in snapshot.entries.dropFirst() {
            XCTAssertFalse(entry.cellIdentityEvidenceRequiresRefresh)
            XCTAssertEqual(RadioLogSiteBuilder.build(from: [entry]).first?.kind, .gnb)
        }
        XCTAssertNil(snapshot.cursor)
        let next = try JSONDecoder.signalQuest.decode(RadioLogSnapshot.self, from: JSONEncoder.signalQuest.encode(snapshot))
        XCTAssertEqual(next.entries, snapshot.entries)
        XCTAssertTrue(next.entries[0].cellIdentityEvidenceRequiresRefresh)
    }

    func testSessionNumericComponentsStayAmbiguousAndExplicitPlmnStillWins() throws {
        for fields in [
            #""mobileCountryCode":310,"mobileNetworkCode":1"#,
            #""observedMcc":"310","observedMnc":"1""#,
            #""observedPlmn":"31001","networkIdentityConfidence":"AMBIGUOUS_MNC_WIDTH""#
        ] {
            let point = try JSONDecoder.signalQuest.decode(CoverageSessionPoint.self, from: Data("{\"id\":\"p\",\(fields)}".utf8))
            XCTAssertEqual(point.plmnEvidence, .legacyAmbiguous)
            XCTAssertNil(point.servingPlmn)
        }
        let point = try JSONDecoder.signalQuest.decode(CoverageSessionPoint.self, from: Data(#"{"id":"p","observedPlmn":"310001","mobileCountryCode":208,"mobileNetworkCode":15}"#.utf8))
        XCTAssertEqual(point.servingPlmn?.plmn, "310001")
        XCTAssertNil(point.networkIdentitySource, "Une ancienne session sans provenance reste inconnue")
    }

    func testImportedNsaEciNeverSelectsHistoricalGnb190OrChangesTheFullCi() async throws {
        let entry = try decodeEntry(#"""
        {
          "dedupeKey":"imp|nsa","scope":"imp","technology":"5G NSA","observedPlmn":"20820",
          "ci":"3112966","eciCellId":"6","enb":"12160","gnb":"190",
          "nodeIdentityKind":"GNB_REPORTED","nodeIdentityRaw":"190","networkIdentitySource":"IMPORT"
        }
        """#)
        XCTAssertFalse(entry.isNr)
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: [entry]).first)
        XCTAssertEqual(site.kind, .enb)
        XCTAssertEqual(site.node, "12160")
        XCTAssertEqual(site.cells.first?.ci, 3_112_966)
        XCTAssertEqual(site.cells.first?.eciCellId, "6")
        XCTAssertEqual(site.cells.first?.identityLabel, "ECI 3112966")
        let body = try await encodeIdentifyBody(RadioLogIdentifyPicker.request(for: site, candidate: candidate()))
        XCTAssertEqual(body["enb"] as? String, "12160")
        XCTAssertNil(body["gnb"])
        XCTAssertEqual(body["ci"] as? String, "3112966")
        XCTAssertEqual(body["cellId"] as? String, "6")
        XCTAssertEqual(body["networkIdentitySource"] as? String, "IMPORT")
    }

    func testNsa20810UsesEnb6506AndCarriesLilleEvidenceInsteadOfGnb16383() async throws {
        let entry = try decodeEntry(#"""
        {
          "dedupeKey":"cap|tacos-nsa","scope":"cap","technology":"5G NSA",
          "observedPlmn":"20810","operator":"SFR","canonicalOperatorKey":"SFR",
          "ci":"1665538","eciCellId":"2","enb":"6506","gnb":"16383",
          "pci":253,"band":7,"earfcn":2850,"latitude":50.6292,"longitude":3.0573,
          "networkIdentitySource":"SERVING_CELL"
        }
        """#)

        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: [entry]).first)
        XCTAssertEqual(site.kind, .enb)
        XCTAssertEqual(site.node, "6506")
        XCTAssertEqual(site.observedPlmn, "20810")

        let item = RadioLogsService.batchItem(for: site)
        XCTAssertEqual(item.observedPlmn, "20810")
        XCTAssertEqual(item.enb, "6506")
        XCTAssertNil(item.gnb, "Le gNB secondaire NSA ne doit pas remplacer l'ancre LTE")
        XCTAssertEqual(item.pci, "253")
        XCTAssertEqual(item.cellId, "2")
        XCTAssertEqual(item.ci, "1665538")
        XCTAssertEqual(item.lat, 50.6292)
        XCTAssertEqual(item.lng, 3.0573)

        let query = try await captureHypothesisQuery(for: site)
        XCTAssertEqual(query["observedPlmn"], "20810")
        XCTAssertEqual(query["enb"], "6506")
        XCTAssertNil(query["gnb"])
        XCTAssertEqual(query["pci"], "253")
        XCTAssertEqual(query["cellId"], "2")
        XCTAssertEqual(query["ci"], "1665538")
        XCTAssertEqual(query["lat"], "50.6292")
        XCTAssertEqual(query["lng"], "3.0573")
    }

    func testRealGnb16383AloneOrAmbiguousNeverIdentifiesPaimpolFromLille() throws {
        let entry = try decodeEntry(#"""
        {
          "dedupeKey":"cap|real-gnb-16383","scope":"cap","technology":"5G SA",
          "observedPlmn":"20810","operator":"SFR","canonicalOperatorKey":"SFR",
          "ci":"268419077","eciCellId":"5","gnb":"16383","pci":500,
          "band":1,"earfcn":428000,"latitude":50.6292,"longitude":3.0573,
          "nodeIdentityKind":"GNB_REPORTED","nodeIdentityRaw":"16383"
        }
        """#)
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: [entry]).first)
        XCTAssertEqual(site.kind, .gnb)
        XCTAssertEqual(site.node, "16383", "Un vrai gNB 16383 n'est pas blacklisté")

        let item = RadioLogsService.batchItem(for: site)
        XCTAssertEqual(item.observedPlmn, "20810")
        XCTAssertEqual(item.gnb, "16383")
        XCTAssertEqual(item.ci, "268419077")
        XCTAssertEqual(item.pci, "500")
        XCTAssertEqual(item.lat, 50.6292)

        let farNodeOnly = try resolution(#"""
        {"found":true,"siteId":"paimpol","distanceMeters":498146,
         "matchedRadio":[{"type":"gnb","value":"16383"}]}
        """#)
        XCTAssertEqual(RadioLogsService.state(from: farNodeOnly, site: site), .unidentified)

        let ambiguous = try resolution(#"""
        {"found":false,"ambiguous":true,"sharedNode":true,"resolutionMode":"unresolved",
         "candidates":[{"siteId":"lille"},{"siteId":"paimpol"}],
         "matchedRadio":[{"type":"gnb","value":"16383"},{"type":"pci","value":"500"}]}
        """#)
        XCTAssertEqual(RadioLogsService.state(from: ambiguous, site: site), .unidentified)

        let localCellProof = try resolution(#"""
        {"found":true,"siteId":"lille","distanceMeters":350,"sharedNode":true,
         "matchedRadio":[{"type":"gnb","value":"16383"},{"type":"pci","value":"500"}]}
        """#)
        XCTAssertEqual(RadioLogsService.state(from: localCellProof, site: site), .identified(siteId: "lille"))

        let repeatedPciTooFar = try resolution(#"""
        {"found":true,"siteId":"another-sfr-site","distanceMeters":20000,"sharedNode":true,
         "matchedRadio":[{"type":"gnb","value":"16383"},{"type":"pci","value":"500"}]}
        """#)
        XCTAssertEqual(
            RadioLogsService.state(from: repeatedPciTooFar, site: site),
            .unidentified,
            "Le même PCI à 20 km n'est pas une preuve physique du site"
        )
    }

    func testConfirmedNciIsPreservedButUnknownPlmnCannotBorrowItsFourteenBitSplit() throws {
        for plmn in ["20810", "310001", "208010"] {
            let entry = try decodeEntry("""
            {"dedupeKey":"imp|\(plmn)","scope":"imp","technology":"NR","observedPlmn":"\(plmn)",
             "ci":"17374019585","gnb":"1060426","nodeIdentityKind":"GNB_REPORTED","nodeIdentityRaw":"1060426"}
            """)
            let cached = try JSONDecoder.signalQuest.decode(RadioLogEntry.self, from: JSONEncoder.signalQuest.encode(entry))
            XCTAssertEqual(cached.ci, 17_374_019_585)
            XCTAssertNil(cached.eciCellId, "Aucun numéro local n'a été observé")
            let sites = RadioLogSiteBuilder.build(from: [cached])
            if plmn == "20810" {
                XCTAssertEqual(sites.first?.node, "1060426")
                XCTAssertEqual(sites.first?.cells.first?.identityLabel, "NCI 17374019585")
            } else {
                XCTAssertTrue(sites.isEmpty, "\(plmn) ne fournit pas la largeur du gNB historique")
            }
        }
    }

    func testContradictoryGnbNeverOverwritesObservedNciOrLocalCell() throws {
        let entry = try decodeEntry(#"{"dedupeKey":"imp|conflict","technology":"NR","observedPlmn":"20810","ci":"17374019585","gnb":"123456","enb":"12160","eciCellId":"42"}"#)
        XCTAssertTrue(RadioLogSiteBuilder.build(from: [entry]).isEmpty)
        let cached = try JSONDecoder.signalQuest.decode(RadioLogEntry.self, from: JSONEncoder.signalQuest.encode(entry))
        XCTAssertEqual(cached.ci, 17_374_019_585)
        XCTAssertEqual(cached.gnb, "123456")
        XCTAssertEqual(cached.eciCellId, "42")
    }

    func testForeignTenBitLocalEvidenceRemainsSeparateFromFullNci() async throws {
        let entry = try decodeEntry(#"""
        {
          "dedupeKey":"imp|foreign","scope":"imp","technology":"5G SA","observedPlmn":"310260",
          "ci":"126418986","gnb":"123456","eciCellId":"42",
          "nodeIdentityKind":"GNB_REPORTED","nodeIdentityRaw":"123456","networkIdentitySource":"IMPORT"
        }
        """#)
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: [entry]).first)
        XCTAssertEqual(site.cells.first?.ci, 126_418_986)
        XCTAssertEqual(site.cells.first?.eciCellId, "42")
        XCTAssertEqual(site.cells.first?.identityLabel, "NCI 126418986", "La taille seule ne transforme pas une NCI en ECI")
        let body = try await encodeIdentifyBody(RadioLogIdentifyPicker.request(for: site, candidate: candidate()))
        XCTAssertEqual(body["ci"] as? String, "126418986")
        XCTAssertEqual(body["cellId"] as? String, "42")
        XCTAssertEqual(body["gnb"] as? String, "123456")
    }

    func testGnbAndLocalCellRequireExactPlmnAndReportedProvenance() throws {
        for plmn in ["20810", "310260"] {
            let entry = try decodeEntry("{\"dedupeKey\":\"imp|\(plmn)\",\"technology\":\"NR\",\"observedPlmn\":\"\(plmn)\",\"gnb\":\"123456\",\"eciCellId\":\"42\"}")
            let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: [entry]).first)
            XCTAssertNil(entry.ci)
            XCTAssertNil(site.cells.first?.ci)
            XCTAssertEqual(site.cells.first?.eciCellId, "42")
            XCTAssertNil(RadioLogIdentifyPicker.request(for: site, candidate: candidate()).ci)
        }
        let reported = try decodeEntry(#"{"dedupeKey":"imp|reported","technology":"NR","observedPlmn":"20810","gnb":"123456","eciCellId":"42","nodeIdentityKind":"GNB_REPORTED"}"#)
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: [reported]).first)
        XCTAssertEqual(site.cells.first?.ci, 2_022_703_146)
        XCTAssertEqual(RadioLogIdentifyPicker.request(for: site, candidate: candidate()).ci, "2022703146")
    }

    func testZeroAndOutOfRangeFullCiAreNeverReplacedByNodePlusLocal() throws {
        for ci in ["0", "68719476736", "9223372036854775807"] {
            let entry = try decodeEntry("{\"dedupeKey\":\"imp|\(ci)\",\"technology\":\"NR\",\"observedPlmn\":\"20810\",\"ci\":\"\(ci)\",\"gnb\":\"123456\",\"eciCellId\":\"42\"}")
            XCTAssertEqual(entry.ci, Int64(ci))
            XCTAssertTrue(RadioLogSiteBuilder.build(from: [entry]).isEmpty)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.signalQuest.encode(entry)) as? [String: Any])
            XCTAssertEqual(body["ci"] as? String, ci)
            XCTAssertEqual(body["eciCellId"] as? String, "42")
        }
        let maximum = try decodeEntry(#"{"dedupeKey":"imp|max-nci","technology":"NR","observedPlmn":"20810","ci":"68719476735","gnb":"4194303"}"#)
        let maximumSite = try XCTUnwrap(RadioLogSiteBuilder.build(from: [maximum]).first)
        XCTAssertEqual(maximumSite.cells.first?.ci, 68_719_476_735)
        XCTAssertNil(maximumSite.cells.first?.eciCellId, "Le lecteur ne fabrique pas une cellule locale")
        let localZero = try decodeEntry(#"{"dedupeKey":"imp|local-zero","technology":"NR","observedPlmn":"310260","gnb":"123456","eciCellId":"0"}"#)
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: [localZero]).first)
        XCTAssertNil(site.cells.first?.ci)
        XCTAssertEqual(site.cells.first?.eciCellId, "0")
        XCTAssertEqual(RadioLogIdentifyPicker.request(for: site, candidate: candidate()).cellId, "0")
    }

    func testNtmSentinelIsFormatScopedAndNeverPromotesAnLteValueToNr() throws {
        for (technology, fileName, expectedNrNode) in [
            ("LTE", "radio.csv", false),
            ("NR", "radio.csv", true),
            ("NR", "radio.NTM", false)
        ] {
            let entry = try decodeEntry("""
            {"dedupeKey":"imp|\(technology)|\(fileName)","scope":"imp","technology":"\(technology)",
             "observedPlmn":"20810","ci":"2147483647","gnb":"131071",
             "logSource":"IMPORT","sourceApp":"NetMonster","sourceFileName":"\(fileName)"}
            """)
            let cached = try JSONDecoder.signalQuest.decode(RadioLogEntry.self, from: JSONEncoder.signalQuest.encode(entry))
            XCTAssertEqual(cached.ci, 2_147_483_647, "La valeur brute est conservée pour son diagnostic")
            XCTAssertEqual(cached.sourceApp, "NetMonster")
            XCTAssertEqual(cached.sourceFileName, fileName)
            XCTAssertEqual(cached.logSource, "IMPORT")
            XCTAssertEqual(cached.isNtmUnknownCellIdentity, fileName == "radio.NTM")
            let sites = RadioLogSiteBuilder.build(from: [cached])
            XCTAssertEqual(sites.first?.kind == .gnb, expectedNrNode)
            if expectedNrNode { XCTAssertEqual(sites.first?.cells.first?.ci, 2_147_483_647) }
            else { XCTAssertTrue(sites.isEmpty) }
        }
    }

    func testMergingImportAndCaptureDoesNotPromoteTheirSource() throws {
        let entries = try ["IMPORT", "SERVING_CELL"].map { source in
            try decodeEntry("{\"dedupeKey\":\"\(source)\",\"technology\":\"LTE\",\"observedPlmn\":\"20810\",\"enb\":\"42\",\"ci\":\"10753\",\"networkIdentitySource\":\"\(source)\"}")
        }
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: entries).first)
        XCTAssertEqual(site.cells.count, 1)
        XCTAssertNil(site.cells.first?.networkIdentitySource)
        XCTAssertNil(RadioLogIdentifyPicker.request(for: site, candidate: candidate()).networkIdentitySource)
    }

    func testAmbiguousNetworkIsNeverSentToQuickIdentifyOrMarkedIdentified() async throws {
        let entry = try decodeEntry(#"{"dedupeKey":"imp|amb","mcc":208,"mnc":1,"technology":"LTE","enb":"42"}"#)
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: [entry]).first)
        let matched = try resolution(#"{"found":true,"siteId":"wrong-home-site","matchedRadio":[{"type":"enb","value":"42"}]}"#)
        XCTAssertEqual(RadioLogsService.state(from: matched, site: site), .unchecked)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            XCTFail("Un PLMN ambigu ne doit déclencher aucune identification : \(request.url?.path ?? "")")
            throw URLError(.badURL)
        }
        defer { MockURLProtocol.requestHandler = nil }
        let service = RadioLogsService(api: APIClient(config: .test, session: URLSession(configuration: configuration)))
        for await states in service.scanStream(sites: [site]) { XCTAssertTrue(states.isEmpty) }
    }

    func testDecodesServingNetworkIdentityWithoutLosingMncZeroes() throws {
        let json = """
        {"items":[{
          "id":"us1","dedupeKey":"cap|us1","scope":"cap","technology":"LTE",
          "operator":"T-Mobile","rawOperatorName":"TMO US",
          "canonicalOperatorKey":"T_MOBILE_US","canonicalOperatorName":"T-Mobile US",
          "observedPlmn":"310001","mcc":"310","mnc":"001",
          "simPlmn":"20815","simOperatorName":"Free","marketCode":"US","countryCode":"US",
          "isRoaming":true,"enb":"42",
          "observedAt":"2026-07-01T10:00:00.000Z","updatedAt":"2026-07-01T10:00:00.000Z"
        }],"hasMore":false}
        """

        let entry = try JSONDecoder.signalQuest.decode(RadioLogPullPage.self, from: Data(json.utf8)).items[0]

        XCTAssertEqual(entry.servingPlmn, "310001")
        XCTAssertEqual(entry.mcc, "310")
        XCTAssertEqual(entry.mnc, "001")
        XCTAssertEqual(entry.displayOperatorName, "T-Mobile US")
        XCTAssertEqual(entry.canonicalOperatorKey, "T_MOBILE_US")
        XCTAssertEqual(entry.simPlmn, "20815")
        XCTAssertEqual(entry.isRoaming, true)
    }

    func testSessionPointKeepsServingPlmnInsteadOfRebuildingItFromOperatorName() throws {
        let json = """
        {
          "id":"p1","latitude":40.7128,"longitude":-74.006,
          "technology":"LTE","operatorKey":"T_MOBILE_US",
          "mobileOperator":"Free","observedPlmn":"310001",
          "observedMcc":"310","observedMnc":"001",
          "marketCode":"US","countryCode":"US","isRoaming":true,"networkIdentitySource":"IMPORT",
          "enb":"42"
        }
        """

        let point = try JSONDecoder.signalQuest.decode(CoverageSessionPoint.self, from: Data(json.utf8))

        XCTAssertEqual(point.servingPlmn?.plmn, "310001")
        XCTAssertEqual(point.servingPlmn?.mnc, "001")
        XCTAssertEqual(point.operatorKey, "T_MOBILE_US")
        XCTAssertEqual(point.simOperator, "Free")
        XCTAssertEqual(point.marketCode, "US")
        XCTAssertEqual(point.isRoaming, true)
        XCTAssertEqual(point.networkIdentitySource, "IMPORT")
    }

    // MARK: Fusion

    /// Une reprise peut revoir des lignes déjà reçues. L'application doit donc
    /// être idempotente, et le dernier état reçu doit gagner.
    func testMergeIsIdempotentAndLastWriteWins() throws {
        let first = try entry(id: "a", dedupeKey: "cap|1", pci: 35)
        let updated = try entry(id: "a", dedupeKey: "cap|1", pci: 112)

        let once = RadioLogStore.applying(incoming: [first], to: [])
        XCTAssertEqual(once.count, 1)

        let twice = RadioLogStore.applying(incoming: [first], to: once)
        XCTAssertEqual(twice.count, 1, "Rejouer la même ligne ne doit pas la dupliquer")

        let merged = RadioLogStore.applying(incoming: [updated], to: twice)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].pci, 112)
    }

    /// Une pierre tombale (`deletedAt` non nul) est PRÉSENTE dans la réponse :
    /// elle propage une suppression faite ailleurs, elle ne s'ajoute pas.
    func testTombstoneRemovesTheRow() throws {
        let live = try entry(id: "a", dedupeKey: "cap|1", pci: 35)
        let tombstone = try entry(id: "a", dedupeKey: "cap|1", pci: nil, deleted: true)

        let stored = RadioLogStore.applying(incoming: [live], to: [])
        XCTAssertEqual(stored.count, 1)

        let after = RadioLogStore.applying(incoming: [tombstone], to: stored)
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: Agrégation en sites

    /// L'unité de la page est le SITE. En 5G le gNB prime, sinon l'eNB.
    func testAggregatesByNodeWithGnbPriorityOnNr() throws {
        let entries = [
            try entry(id: "1", dedupeKey: "cap|1", enb: "626821", pci: 35, ci: 160_466_202),
            try entry(id: "2", dedupeKey: "cap|2", enb: "626821", pci: 112, ci: 160_466_178),
            try entry(id: "3", dedupeKey: "cap|3", enb: "626821", pci: 35, ci: 160_466_202),
            try entry(id: "4", dedupeKey: "cap|4", enb: "1", gnb: "9881", technology: "NR", pci: 500)
        ]
        let sites = RadioLogSiteBuilder.build(from: entries).sorted { $0.logCount > $1.logCount }

        XCTAssertEqual(sites.count, 2)
        let lte = try XCTUnwrap(sites.first { $0.kind == .enb })
        XCTAssertEqual(lte.node, "626821")
        XCTAssertEqual(lte.logCount, 3)
        XCTAssertEqual(lte.cells.count, 2, "Deux cellules distinctes, la première vue deux fois")
        XCTAssertEqual(lte.distinctPciCount, 2)
        XCTAssertEqual(lte.techLabel, "4G")

        let nr = try XCTUnwrap(sites.first { $0.kind == .gnb })
        XCTAssertEqual(nr.node, "9881", "En NR le gNB prime, même si un eNB est présent")
        XCTAssertEqual(nr.techLabel, "5G")
    }

    /// Plusieurs cellules partagent souvent le même PCI (bandes ou secteurs
    /// différents). Les pastilles décrivent le SITE : les répéter contredisait le
    /// « 3 PCI » affiché juste au-dessus — vu tel quel sur un site réel, qui
    /// alignait « PCI 261 » quatre fois.
    func testPciPillsAreDistinct() throws {
        let entries = [
            try entry(id: "1", dedupeKey: "cap|1", enb: "95566", pci: 261, ci: 1),
            try entry(id: "2", dedupeKey: "cap|2", enb: "95566", pci: 261, ci: 2),
            try entry(id: "3", dedupeKey: "cap|3", enb: "95566", pci: 261, ci: 3),
            try entry(id: "4", dedupeKey: "cap|4", enb: "95566", pci: 262, ci: 4)
        ]
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: entries).first)
        XCTAssertEqual(site.cells.count, 4, "Quatre cellules distinctes")
        XCTAssertEqual(site.distinctPciCount, 2)
        XCTAssertEqual(site.distinctPciLabels, ["PCI 261", "PCI 262"])
    }

    /// Une ligne supprimée ne compte pas dans les sites.
    func testDeletedEntriesAreNotAggregated() throws {
        let entries = [
            try entry(id: "1", dedupeKey: "cap|1", enb: "1", pci: 1),
            try entry(id: "2", dedupeKey: "cap|2", enb: "1", pci: 2, deleted: true)
        ]
        let sites = RadioLogSiteBuilder.build(from: entries)
        XCTAssertEqual(sites.count, 1)
        XCTAssertEqual(sites[0].logCount, 1)
    }

    /// La position est une MÉDIANE par axe : un fix GPS aberrant ne doit pas
    /// déplacer le site. Avec une moyenne, ce test échouerait de ~1,6°.
    func testMedianPositionResistsAnOutlierFix() throws {
        let entries = [
            try entry(id: "1", dedupeKey: "cap|1", enb: "1", latitude: 45.50, longitude: 5.30),
            try entry(id: "2", dedupeKey: "cap|2", enb: "1", latitude: 45.51, longitude: 5.31),
            try entry(id: "3", dedupeKey: "cap|3", enb: "1", latitude: 45.52, longitude: 5.32),
            try entry(id: "4", dedupeKey: "cap|4", enb: "1", latitude: 52.00, longitude: 13.00)
        ]
        let site = try XCTUnwrap(RadioLogSiteBuilder.build(from: entries).first)
        let latitude = try XCTUnwrap(site.latitude)
        XCTAssertEqual(latitude, 45.515, accuracy: 0.001)
    }

    /// Deux opérateurs qui partagent un numéro d'eNB restent deux sites : les
    /// eNB ne sont uniques qu'à l'intérieur d'un réseau.
    func testSameNodeOnTwoOperatorsStaysTwoSites() throws {
        let entries = [
            try entry(id: "1", dedupeKey: "cap|1", enb: "42", operatorName: "SFR", mccMnc: "208-10"),
            try entry(id: "2", dedupeKey: "cap|2", enb: "42", operatorName: "ORANGE", mccMnc: "208-01")
        ]
        XCTAssertEqual(RadioLogSiteBuilder.build(from: entries).count, 2)
    }

    func testRawBouyguesAliasesCollapseUnderCanonicalServingPlmn() throws {
        let entries = [
            try entry(
                id: "1", dedupeKey: "cap|1", enb: "42", operatorName: "ByTel",
                mccMnc: "208-20", observedPlmn: "20820",
                canonicalOperatorKey: "BOUYGUES", canonicalOperatorName: "Bouygues Telecom"
            ),
            try entry(
                id: "2", dedupeKey: "cap|2", enb: "42", operatorName: "BOUYGUES",
                mccMnc: "208-20", observedPlmn: "20820",
                canonicalOperatorKey: "BOUYGUES", canonicalOperatorName: "Bouygues Telecom"
            )
        ]

        let sites = RadioLogSiteBuilder.build(from: entries)
        XCTAssertEqual(sites.count, 1)
        let site = try XCTUnwrap(sites.first)

        XCTAssertEqual(site.operatorName, "Bouygues Telecom")
        XCTAssertEqual(site.operatorKey, "BOUYGUES")
        XCTAssertEqual(site.logCount, 2)
    }

    // MARK: Critère d'identification

    /// UN critère : l'eNB/gNB est-il connu du serveur ? Une résolution par
    /// PROXIMITÉ (aucun identifiant radio reconnu) n'est PAS une identification.
    func testProximityResolutionIsNotAnIdentification() throws {
        let site = try makeSite(kind: .enb, node: "626821")
        let proximity = try resolution("""
        {"found":true,"siteId":"0380001","resolutionMode":"proximity","matchedRadio":[],
         "distanceMeters":2900}
        """)
        XCTAssertEqual(RadioLogsService.state(from: proximity, site: site), .unidentified)
    }

    func testMatchedNodeIsAnIdentification() throws {
        let site = try makeSite(kind: .enb, node: "626821")
        let matched = try resolution("""
        {"found":true,"canonicalSiteId":"0382700518","matchedRadio":[{"type":"enb","value":"626821"}]}
        """)
        XCTAssertEqual(RadioLogsService.state(from: matched, site: site), .identified(siteId: "0382700518"))
    }

    /// SITE MUTUALISÉ — le cas qui a fait tomber 23 % du catalogue à tort.
    ///
    /// Le serveur renvoie `requiresUserConfirmation: true` et
    /// `resolutionMode: "shared_operator"` pour un site partagé entre opérateurs,
    /// TOUT EN listant l'eNB dans `matchedRadio` et en le sourçant depuis
    /// `fr_validations`. Le nœud est donc parfaitement connu : ce qui demande
    /// confirmation, c'est l'opérateur propriétaire, pas l'existence du nœud.
    /// Mesuré sur un journal réel : 35 sites sur 150 dans ce cas.
    func testSharedOperatorSiteWithMatchedNodeIsIdentified() throws {
        let site = try makeSite(kind: .enb, node: "531087")
        let shared = try resolution("""
        {"found":true,"siteId":"1713624","canonicalSiteId":"1713624",
         "resolutionMode":"shared_operator","source":"fr_validations",
         "requiresUserConfirmation":true,"operatorMatched":true,
         "matchedRadio":[{"type":"enb","value":"531087"}]}
        """)
        XCTAssertEqual(
            RadioLogsService.state(from: shared, site: site),
            .identified(siteId: "1713624"),
            "Un nœud listé dans matchedRadio est connu, quelle que soit la confirmation demandée sur le site"
        )
    }

    /// Sans AUCUNE correspondance détaillée, `requiresUserConfirmation` reprend
    /// tout son sens : le `found` ne vient alors pas d'un identifiant radio.
    func testConfirmationRequiredWithoutAnyMatchIsNotAnIdentification() throws {
        let site = try makeSite(kind: .enb, node: "1")
        let vague = try resolution("""
        {"found":true,"siteId":"S","matchedRadio":[],"requiresUserConfirmation":true}
        """)
        XCTAssertEqual(RadioLogsService.state(from: vague, site: site), .unidentified)
    }

    /// Un PCI reconnu sans le nœud ne suffit pas : c'est le nœud qui porte
    /// l'identification du site.
    func testMatchedPciAloneIsNotAnIdentification() throws {
        let site = try makeSite(kind: .gnb, node: "9881")
        let pciOnly = try resolution("""
        {"found":true,"siteId":"0380001","matchedRadio":[{"type":"pci","value":"500"}]}
        """)
        XCTAssertEqual(RadioLogsService.state(from: pciOnly, site: site), .unidentified)
    }

    func testNotFoundIsUnidentified() throws {
        let site = try makeSite(kind: .enb, node: "1")
        XCTAssertEqual(RadioLogsService.state(from: nil, site: site), .unidentified)
        let notFound = try resolution(#"{"found":false}"#)
        XCTAssertEqual(RadioLogsService.state(from: notFound, site: site), .unidentified)
    }

    // MARK: Charge d'identify/direct

    /// LE défaut historique : iOS envoyait `mcc`/`mnc`, que `DirectIdentifyBody`
    /// ne connaît pas. Résultat, aucun PLMN côté serveur → `400 MISSING_PLMN`.
    /// Ce test verrouille les noms que le serveur lit VRAIMENT.
    func testIdentifyPayloadCarriesPlmnUnderTheServerNames() async throws {
        let site = try makeSite(kind: .enb, node: "626821", mccMnc: "208-10", operatorName: "SFR")
        let candidate = RadioLogCandidate(
            id: "0382700518", siteId: "0382700518", latitude: 45.5, longitude: 5.3,
            operators: ["SFR"], technologies: ["4G"], address: nil,
            distanceMeters: 320, confidenceScore: 88, isServerHypothesis: true
        )
        let request = RadioLogIdentifyPicker.request(for: site, candidate: candidate)

        XCTAssertEqual(request.mcc, "208")
        XCTAssertEqual(request.mnc, "10")

        let encoded = try await encodeIdentifyBody(request)
        XCTAssertEqual(encoded["mobileCountryCode"] as? String, "208")
        XCTAssertEqual(encoded["mobileNetworkCode"] as? String, "10")
        XCTAssertEqual(encoded["observedPlmn"] as? String, "20810")
        XCTAssertEqual(encoded["operatorKey"] as? String, "SFR")
        XCTAssertEqual(encoded["marketCode"] as? String, "FR")
        XCTAssertNil(encoded["mcc"], "Le serveur ne lit pas `mcc` — l'envoyer revient à n'envoyer aucun PLMN")
        XCTAssertNil(encoded["mnc"])
        XCTAssertEqual(encoded["siteId"] as? String, "0382700518")
        XCTAssertEqual(encoded["enb"] as? String, "626821")
        XCTAssertEqual(encoded["tech"] as? String, "4G")
        XCTAssertNil(encoded["sectorIndex"], "Le secteur est dérivé par le serveur, sa règle fait autorité")
    }

    /// Un MNC à trois chiffres reste textuellement intact jusque dans la charge
    /// HTTP : `310001` ne doit jamais devenir l'ambigu `3101`.
    func testIdentifyPayloadPreservesThreeDigitMncWithLeadingZeroes() async throws {
        let site = try makeSite(
            kind: .enb,
            node: "42",
            mccMnc: "310001",
            operatorName: "T-Mobile US"
        )
        let candidate = RadioLogCandidate(
            id: "US", siteId: "US", latitude: 40.7, longitude: -74,
            operators: [], technologies: ["4G"], address: nil,
            distanceMeters: nil, confidenceScore: nil, isServerHypothesis: false
        )

        let encoded = try await encodeIdentifyBody(
            RadioLogIdentifyPicker.request(for: site, candidate: candidate)
        )

        XCTAssertEqual(encoded["mobileCountryCode"] as? String, "310")
        XCTAssertEqual(encoded["mobileNetworkCode"] as? String, "001")
        XCTAssertEqual(encoded["observedPlmn"] as? String, "310001")
    }

    /// Un nom d'opérateur n'est pas une preuve de PLMN : l'app ne doit pas
    /// transformer silencieusement « Orange » en réseau servant 208/01.
    func testIdentifyPayloadDoesNotInventPlmnFromOperatorName() throws {
        let site = try makeSite(kind: .enb, node: "1", mccMnc: nil, operatorName: "Orange")
        let candidate = RadioLogCandidate(
            id: "S", siteId: "S", latitude: nil, longitude: nil, operators: [],
            technologies: [], address: nil, distanceMeters: nil, confidenceScore: nil,
            isServerHypothesis: false
        )
        let request = RadioLogIdentifyPicker.request(for: site, candidate: candidate)
        XCTAssertNil(request.mcc)
        XCTAssertNil(request.mnc)
        XCTAssertNotNil(RadioLogIdentifyPicker.blockingReason(for: site))
    }

    /// `ci` part en CHAÎNE, conformément au contrat `BigInt` du serveur.
    func testIdentifyPayloadSendsCellIdentityAsString() async throws {
        let site = try makeSite(kind: .gnb, node: "1060426", mccMnc: "208-10", operatorName: "SFR", ci: 17_374_019_585)
        let candidate = RadioLogCandidate(
            id: "S", siteId: "S", latitude: nil, longitude: nil, operators: [],
            technologies: [], address: nil, distanceMeters: nil, confidenceScore: nil,
            isServerHypothesis: false
        )
        let encoded = try await encodeIdentifyBody(RadioLogIdentifyPicker.request(for: site, candidate: candidate))
        XCTAssertEqual(encoded["ci"] as? String, "17374019585")
        XCTAssertEqual(encoded["gnb"] as? String, "1060426")
        XCTAssertEqual(encoded["tech"] as? String, "5G")
        XCTAssertNil(encoded["enb"], "Un site 5G n'envoie pas d'eNB")
    }

    /// On refuse de partir vers un échec prévisible, et on dit pourquoi.
    func testBlockingReasonNamesWhatIsMissing() throws {
        let noPlmn = try makeSite(kind: .enb, node: "1", mccMnc: nil, operatorName: "Inconnu")
        XCTAssertNotNil(RadioLogIdentifyPicker.blockingReason(for: noPlmn))

        let noPosition = try makeSite(kind: .enb, node: "1", mccMnc: "208-10", operatorName: "SFR", latitude: nil)
        XCTAssertNotNil(RadioLogIdentifyPicker.blockingReason(for: noPosition))

        let complete = try makeSite(kind: .enb, node: "1", mccMnc: "208-10", operatorName: "SFR")
        XCTAssertNil(RadioLogIdentifyPicker.blockingReason(for: complete))
    }

    // MARK: Libellés d'erreur

    /// Un code technique ne doit jamais s'afficher tel quel.
    func testKnownIdentifyErrorCodesGetAFrenchLabel() {
        for code in ["MISSING_PLMN", "OPERATOR_NOT_ALLOWED", "IDENTIFY_MARKET_MISMATCH",
                     "IDENTIFY_OPERATOR_MISMATCH", "VALIDATION_NODE_SITE_MISMATCH",
                     "IDENTIFY_SITE_NOT_FOUND", "MISSING_CELL_IDENTIFIERS", "PREMIUM_REQUIRED"] {
            let message = APIError.userFacingMessage(status: 400, code: code, serverMessage: code)
            XCTAssertFalse(message.contains("_"), "\(code) s'affiche encore brut : « \(message) »")
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: Fabriques

    private func decodeEntry(_ json: String) throws -> RadioLogEntry {
        try JSONDecoder.signalQuest.decode(RadioLogEntry.self, from: Data(json.utf8))
    }

    private func candidate() -> RadioLogCandidate {
        RadioLogCandidate(
            id: "synthetic", siteId: "synthetic", latitude: nil, longitude: nil,
            operators: [], technologies: [], address: nil, distanceMeters: nil,
            confidenceScore: nil, isServerHypothesis: false
        )
    }

    private func entry(
        id: String,
        dedupeKey: String,
        enb: String? = nil,
        gnb: String? = nil,
        technology: String = "LTE",
        operatorName: String? = "SFR",
        mccMnc: String? = "208-10",
        observedPlmn: String? = nil,
        canonicalOperatorKey: String? = nil,
        canonicalOperatorName: String? = nil,
        pci: Int? = nil,
        ci: Int64? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        deleted: Bool = false
    ) throws -> RadioLogEntry {
        var fields: [String] = [
            "\"id\":\"\(id)\"",
            "\"dedupeKey\":\"\(dedupeKey)\"",
            "\"scope\":\"cap\"",
            "\"technology\":\"\(technology)\"",
            "\"observedAt\":\"2026-07-01T10:00:00.000Z\"",
            "\"updatedAt\":\"2026-07-01T10:00:00.000Z\""
        ]
        if let operatorName { fields.append("\"operator\":\"\(operatorName)\"") }
        if let mccMnc { fields.append("\"mccMnc\":\"\(mccMnc)\"") }
        if let observedPlmn { fields.append("\"observedPlmn\":\"\(observedPlmn)\"") }
        if let canonicalOperatorKey { fields.append("\"canonicalOperatorKey\":\"\(canonicalOperatorKey)\"") }
        if let canonicalOperatorName { fields.append("\"canonicalOperatorName\":\"\(canonicalOperatorName)\"") }
        if let enb { fields.append("\"enb\":\"\(enb)\"") }
        if let gnb { fields.append("\"gnb\":\"\(gnb)\"") }
        if let pci { fields.append("\"pci\":\(pci)") }
        if let ci { fields.append("\"ci\":\"\(ci)\"") }
        if let latitude { fields.append("\"latitude\":\(latitude)") }
        if let longitude { fields.append("\"longitude\":\(longitude)") }
        if deleted { fields.append("\"deletedAt\":\"2026-07-02T10:00:00.000Z\"") }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder.signalQuest.decode(RadioLogEntry.self, from: Data(json.utf8))
    }

    private func makeSite(
        kind: RadioLogNodeKind,
        node: String,
        mccMnc: String? = "208-10",
        operatorName: String? = "SFR",
        ci: Int64? = nil,
        latitude: Double? = 45.5
    ) throws -> RadioLogSite {
        let entry = try entry(
            id: "s",
            dedupeKey: "cap|s",
            enb: kind == .enb ? node : nil,
            gnb: kind == .gnb ? node : nil,
            technology: kind == .gnb ? "NR" : "LTE",
            operatorName: operatorName,
            mccMnc: mccMnc,
            pci: 35,
            ci: ci,
            latitude: latitude,
            longitude: latitude == nil ? nil : 5.3
        )
        return try XCTUnwrap(RadioLogSiteBuilder.build(from: [entry]).first)
    }

    private func resolution(_ json: String) throws -> QuickIdentifyResolution {
        try JSONDecoder.signalQuest.decode(QuickIdentifyResolution.self, from: Data(json.utf8))
    }

    /// Capture le corps HTTP RÉELLEMENT émis par `IdentifyService`.
    ///
    /// On passe par le vrai service et un vrai `APIClient` : un test qui
    /// reconstruirait la charge de son côté validerait sa propre copie, pas le
    /// code livré — et laisserait passer un renommage de champ, c'est-à-dire
    /// exactement le défaut qu'on corrige ici.
    private func encodeIdentifyBody(_ request: IdentifyDirectRequest) async throws -> [String: Any] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let captured = CapturedBody()
        MockURLProtocol.requestHandler = { urlRequest in
            // URLSession transforme `httpBody` en flux avant d'atteindre le
            // URLProtocol : c'est là qu'il faut aller le chercher.
            captured.data = urlRequest.httpBody ?? urlRequest.httpBodyStream.map(Self.readAll)
            let response = HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"success":true,"siteId":"S"}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let service = IdentifyService(api: APIClient(config: .test, session: session))
        _ = try await service.identify(request)

        let body = try XCTUnwrap(captured.data, "Aucun corps HTTP capturé")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func captureHypothesisQuery(for site: RadioLogSite) async throws -> [String: String] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let captured = CapturedURL()
        MockURLProtocol.requestHandler = { request in
            captured.url = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"found":false,"resolutionMode":"unresolved"}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let service = RadioLogsService(
            api: APIClient(config: .test, session: URLSession(configuration: configuration))
        )
        _ = await service.hypothesis(for: site)
        let url = try XCTUnwrap(captured.url, "Aucune requête quick-identify capturée")
        return Dictionary(
            uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .compactMap { item in item.value.map { (item.name, $0) } } ?? []
        )
    }

    private final class CapturedBody: @unchecked Sendable {
        var data: Data?
    }

    private final class CapturedURL: @unchecked Sendable {
        var url: URL?
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Doublures

private struct StubIdentifyService: IdentifyServicing {
    func identify(_ request: IdentifyDirectRequest) async throws -> IdentifyResult { throw APIError.cancelled }
    func mine(includeRelated: Bool) async throws -> [MyIdentification] { [] }
    func withdraw(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> WithdrawResult { throw APIError.cancelled }
    func delete(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, reason: String?) async throws -> DeleteResult { throw APIError.cancelled }
    func editSite(fromSiteId: String, toSiteId: String, enb: String?, gnb: String?, reason: String?) async throws -> EditSiteResult { throw APIError.cancelled }
    func editSectors(siteId: String, enb: String?, gnb: String?, pci: String?, cellId: String?, ci: String?, tech: String?, operatorName: String, marketCode: String?, sectors: [Int]) async throws -> EditSectorsResult { throw APIError.cancelled }
}

private struct StubRadioLogsService: RadioLogsServicing {
    func cachedSnapshot() -> RadioLogSnapshot { RadioLogSnapshot() }
    func syncStream() -> AsyncStream<RadioLogSyncProgress> { AsyncStream { $0.finish() } }
    func cachedSiteStates() -> [String: RadioLogSiteState] { [:] }
    func scanStream(sites: [RadioLogSite]) -> AsyncStream<[String: RadioLogSiteState]> { AsyncStream { $0.finish() } }
    func hypothesis(for site: RadioLogSite) async -> RadioLogSiteHypothesis? { nil }
    func markIdentified(siteKey: String, siteId: String) {}
    func purge() async throws {}
    func clearLocalCache() {}
}


extension RadioLogsTests {

    func testSharedWorldRadioCorpusKeepsIOSFailClosedForDualSimCaAndTa() throws {
        struct Fixture: Decodable {
            struct PlatformRules: Decodable {
                struct IOS: Decodable {
                    let mayExposePerSubscriptionRadio: Bool
                    let unavailableState: String
                }
                let ios: IOS
            }
            struct Case: Decodable {
                struct Subscription: Decodable {
                    let seriesKey: String
                    let simPlmn: String
                    let observedPlmn: String?
                    let isRoaming: Bool
                    let observable: Bool
                    let unavailableReason: String?
                }
                struct Cell: Decodable {
                    let seriesKey: String
                    let role: String
                    let rat: String
                    let band: String
                    let bandwidthMhz: Int
                    let timingAdvance: Int?
                    let timingAdvanceSourceTechnology: String?
                    let numerology: Int?
                }
                struct Expected: Decodable {
                    struct CA: Decodable {
                        let seriesKey: String
                        let componentCount: Int
                        let totalBandwidthMhz: Int
                        let bands: [String]
                    }
                    struct TA: Decodable {
                        let accepted: Bool
                        let reason: String?
                        let sourceTechnology: String?
                        let distanceModel: String?
                        let distanceMeters: Int?
                    }
                    let observableSeries: [String]
                    let carrierAggregation: CA?
                    let timingAdvance: TA?
                }
                let id: String
                let subscriptions: [Subscription]
                let cells: [Cell]
                let expected: Expected
            }
            let schemaVersion: Int
            let platformRules: PlatformRules
            let cases: [Case]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: root.appendingPathComponent("SignalQuestTests/Fixtures/radio-world-scenarios-v1.json"))
        )
        XCTAssertEqual(fixtures.schemaVersion, 1)
        XCTAssertEqual(fixtures.cases.count, 9)
        XCTAssertFalse(fixtures.platformRules.ios.mayExposePerSubscriptionRadio)
        XCTAssertEqual(fixtures.platformRules.ios.unavailableState, "notExposedByPlatform")
        for scenario in fixtures.cases {
            XCTAssertEqual(
                scenario.subscriptions.filter(\.observable).map(\.seriesKey).sorted(),
                scenario.expected.observableSeries.sorted(),
                scenario.id
            )
            for subscription in scenario.subscriptions where !subscription.observable {
                XCTAssertNil(subscription.observedPlmn, scenario.id)
                XCTAssertNotNil(subscription.unavailableReason, scenario.id)
            }
            for subscription in scenario.subscriptions where subscription.isRoaming {
                XCTAssertNotEqual(subscription.observedPlmn, subscription.simPlmn, scenario.id)
            }
            if let ca = scenario.expected.carrierAggregation {
                let components = scenario.cells.filter { $0.seriesKey == ca.seriesKey }
                XCTAssertEqual(components.count, ca.componentCount, scenario.id)
                XCTAssertEqual(components.reduce(0) { $0 + $1.bandwidthMhz }, ca.totalBandwidthMhz, scenario.id)
                XCTAssertEqual(components.map(\.band), ca.bands, scenario.id)
            }
            if let ta = scenario.expected.timingAdvance, ta.sourceTechnology == "NR" {
                XCTAssertTrue(ta.accepted, scenario.id)
                XCTAssertNil(ta.distanceModel, scenario.id)
                XCTAssertNil(ta.distanceMeters, scenario.id)
                XCTAssertTrue(scenario.cells.filter { $0.timingAdvance != nil }
                    .allSatisfy { $0.rat == "NR" && $0.numerology == nil })
            }
            if scenario.expected.timingAdvance?.accepted == false {
                XCTAssertEqual(scenario.expected.timingAdvance?.reason, "notApplicable", scenario.id)
                XCTAssertTrue(scenario.cells.filter { $0.timingAdvance != nil }
                    .allSatisfy { $0.rat == "NR" && $0.role == "SCC" })
            }
        }
        let leadingZero = try XCTUnwrap(fixtures.cases.first { $0.id == "three-digit-mnc-leading-zeros" })
        XCTAssertEqual(leadingZero.subscriptions.first?.observedPlmn, "310001")
    }

    func testSharedNciProvenanceCorpusUsesVersionedReportedGnbContract() throws {
        struct Fixture: Decodable {
            struct Case: Decodable {
                let id: String
                let technology: String
                let observedPlmn: String
                let ci: String?
                let enb: String?
                let gnb: String?
                let nodeIdentityKind: String?
                let cellId: String?
                let expectedCanonicalCi: String?
                let expectedDerivedGnb: String?
                let expectedLocalCellId: String?
            }
            let schemaVersion: Int
            let cases: [Case]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: root.appendingPathComponent("SignalQuestTests/Fixtures/nci-provenance-v1.json"))
        )
        XCTAssertEqual(fixtures.schemaVersion, 2)
        XCTAssertEqual(fixtures.cases.count, 14)
        for entry in fixtures.cases {
            let ci = entry.ci.flatMap(Int64.init)
            let canonical = RadioCellIdentityNormalizer.canonicalFullCellIdentity(
                cellId: entry.cellId,
                ci: ci,
                enb: entry.enb,
                gnb: entry.gnb,
                technology: entry.technology,
                observedPlmn: entry.observedPlmn,
                nodeIdentityKind: entry.nodeIdentityKind
            )
            XCTAssertEqual(canonical.map(String.init), entry.expectedCanonicalCi, entry.id)
            XCTAssertEqual(RadioCellIdentityNormalizer.localCellIdentity(
                cellId: entry.cellId,
                ci: ci,
                enb: entry.enb,
                gnb: entry.gnb,
                technology: entry.technology,
                observedPlmn: entry.observedPlmn
            ), entry.expectedLocalCellId, entry.id)
            XCTAssertEqual(RadioCellIdentityNormalizer.derivedNrNodeIdentity(
                ci: ci,
                technology: entry.technology,
                observedPlmn: entry.observedPlmn
            ), entry.expectedDerivedGnb, entry.id)
        }
    }

    func testNrReconstructionRejectsLegacyDerivedAndMissingGnbProvenance() {
        for kind in [nil, "GNB_LEGACY", "GNB_DERIVED"] as [String?] {
            XCTAssertNil(RadioCellIdentityNormalizer.canonicalFullCellIdentity(
                cellId: "42",
                ci: nil,
                enb: nil,
                gnb: "123456",
                technology: "NR",
                observedPlmn: "20810",
                nodeIdentityKind: kind
            ), kind ?? "missing")
        }
        XCTAssertEqual(RadioCellIdentityNormalizer.canonicalFullCellIdentity(
            cellId: "42",
            ci: nil,
            enb: nil,
            gnb: "123456",
            technology: "NR",
            observedPlmn: "20810",
            nodeIdentityKind: "GNB_REPORTED"
        ), 2_022_703_146)
    }

    func testSharedExactPlmnFixturesMatchAndroidAndBackend() throws {
        struct Fixture: Decodable {
            struct Case: Decodable {
                struct Expected: Decodable { let plmn: String?; let marketCode: String?; let operatorKey: String? }
                let id: String
                let observedPlmn: String
                let expected: Expected
            }
            let cases: [Case]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let payload = try JSONDecoder.signalQuest.decode(MarketRegistryPayload.self, from: Data(contentsOf: root.appendingPathComponent("SignalQuestApp/Resources/market_registry_fallback.json")))
        let fixtures = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("SignalQuestTests/Fixtures/runtime-plmn-cases-v1.json")))
        XCTAssertFalse(fixtures.cases.isEmpty)
        for entry in fixtures.cases {
            let market = payload.market(forObservedPlmn: entry.observedPlmn)
            XCTAssertEqual(market?.marketCode, entry.expected.marketCode, entry.id)
            XCTAssertEqual(market?.radioOperatorKey(observedPlmn: entry.observedPlmn), entry.expected.operatorKey, entry.id)
        }
    }

    func testOldOrIncompleteRegistryCannotReplaceExactBundledRadioProof() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let current = try JSONDecoder.signalQuest.decode(MarketRegistryPayload.self, from: Data(contentsOf: root.appendingPathComponent("SignalQuestApp/Resources/market_registry_fallback.json")))
        let old = MarketRegistryPayload(schemaVersion: 3, markets: current.markets)
        let incomplete = MarketRegistryPayload(schemaVersion: 3, contract: current.contract, markets: current.markets)
        XCTAssertTrue(current.supportsExactPlmnResolution)
        XCTAssertFalse(old.canReplaceRadioReference(current))
        XCTAssertFalse(incomplete.canReplaceRadioReference(current))
        XCTAssertTrue(current.canReplaceRadioReference(current))
        XCTAssertTrue(current.supportsVersionedMarketContent)
        let contentHash = try XCTUnwrap(current.contract?.marketContentSha256)
        XCTAssertEqual(contentHash.count, 64)
        XCTAssertTrue(current.contract?.registryVersion.hasSuffix(String(contentHash.prefix(12))) == true)
        XCTAssertEqual(current.market(forCode: "HU")?.operatorEntry(forKey: "DIGI_HU")?.key, "VODAFONE_HU")
        XCTAssertEqual(current.market(forCode: "HU")?.operatorEntry(forKey: "DIGI_HU")?.label, "One Hungary")

        var tamperedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("SignalQuestApp/Resources/market_registry_fallback.json"))) as? [String: Any]
        )
        var tamperedContract = try XCTUnwrap(tamperedObject["contract"] as? [String: Any])
        tamperedContract["marketContentSha256"] = String(repeating: "0", count: 64)
        tamperedObject["contract"] = tamperedContract
        let tampered = try JSONDecoder.signalQuest.decode(
            MarketRegistryPayload.self,
            from: JSONSerialization.data(withJSONObject: tamperedObject)
        )
        XCTAssertFalse(tampered.canReplaceRadioReference(current))
    }

    func testBundledWorldMarketRegistryMatchesSharedContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let registryURL = repositoryRoot
            .appendingPathComponent("SignalQuestApp/Resources/market_registry_fallback.json")
        let payload = try JSONDecoder.signalQuest.decode(
            MarketRegistryPayload.self,
            from: Data(contentsOf: registryURL)
        )

        XCTAssertEqual(payload.schemaVersion, 3)
        XCTAssertEqual(payload.markets.count, 212)
        XCTAssertEqual(payload.contract?.minimumCompatibleSchemaVersion, 3)
        XCTAssertEqual(payload.contract?.plmnRegistryVersion, "2026-08-15-ob1346-a62-parser2-names3")
        XCTAssertEqual(
            payload.contract?.plmnContentSha256,
            "ba972a1edc8d9a0a7dbc4161a046724011a92ddd3e1b1a66884a73b93def541e"
        )

        let france = try XCTUnwrap(payload.market(forCode: "FR"))
        let bouygues = try XCTUnwrap(france.radioOperators.first { $0.key == "BOUYGUES" })
        XCTAssertEqual(bouygues.label, "Bouygues Telecom")
        XCTAssertEqual(bouygues.aliases, ["Bouygues", "Bouygues Telecom", "ByTel", "Bouygtel"])
        XCTAssertEqual(france.source.status, "compatible")
        XCTAssertTrue(france.radioCapabilities.officialAntennas)
        XCTAssertEqual(france.radioMvnos.count, 7)
        XCTAssertEqual(france.radioMvnos.first(where: { $0.key == "LEBARA" })?.hostOperatorKey, "SFR")
        XCTAssertEqual(france.radioMvnos.first(where: { $0.key == "LEBARA" })?.plmns.first?.plmn, "20838")
        XCTAssertNil(france.radioOperatorKey(observedPlmn: "20838"))
        XCTAssertNil(france.radioOperatorKey(observedPlmn: "20825"))
        XCTAssertNil(france.radioOperatorKey(observedPlmn: "20822"))
        XCTAssertEqual(payload.radioMvno(simPlmn: "20838", simOperatorName: nil)?.key, "LEBARA")
        XCTAssertEqual(payload.radioMvno(simPlmn: "20820", simOperatorName: "Lebara Mobile")?.key, "LEBARA")
        XCTAssertNil(payload.radioMvno(simPlmn: "20838", simOperatorName: "Lycamobile"))
        XCTAssertEqual(
            Set(france.radioMvnos.map(\.key)),
            Set(["LEBARA", "LYCAMOBILE", "NRJ_MOBILE", "CORIOLIS", "VECTONE", "TRANSATEL", "AIRMOB"])
        )

        let cayman = try XCTUnwrap(payload.market(forCode: "KY"))
        XCTAssertEqual(cayman.radioOperatorKey(observedPlmn: "346001"), "LOGIC_346")

        let unitedStates = try XCTUnwrap(payload.market(forCode: "US"))
        XCTAssertNil(
            unitedStates.radioOperatorKey(observedPlmn: "310001"),
            "Un PLMN non référencé doit rester sans attribution opérateur"
        )
        XCTAssertEqual(unitedStates.sourceMode, "community")
        XCTAssertEqual(unitedStates.source.status, "coverage-only")

        for (plmn, marketCode) in [
            ("302880", "CA"),
            ("302820", "CA"),
            ("302520", "CA"),
            ("22811", "CH"),
        ] {
            let market = try XCTUnwrap(payload.market(forObservedPlmn: plmn), plmn)
            XCTAssertEqual(market.marketCode, marketCode, plmn)
            XCTAssertNil(market.radioOperatorKey(observedPlmn: plmn), plmn)
        }
    }

    func testBundledRadioChannelRegistryMatchesSharedContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let registryURL = repositoryRoot
            .appendingPathComponent("SignalQuestApp/Resources/radio_channel_registry_v1.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any]
        )
        let tables = try XCTUnwrap(object["tables"] as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["minimumCompatibleSchemaVersion"] as? Int, 1)
        XCTAssertEqual(object["registryVersion"] as? String, "3gpp-r17-r18-2026-08-24")
        XCTAssertEqual((tables["umtsDownlinkUarfcn"] as? [[String: Any]])?.count, 21)
        XCTAssertEqual((tables["lteDownlinkEarfcn"] as? [[String: Any]])?.count, 67)
        XCTAssertEqual((tables["nrDownlinkRaster"] as? [[String: Any]])?.count, 63)
        XCTAssertEqual(
            object["contentSha256"] as? String,
            "59ab8b0dc49ef4c06e3f7048acec2b186142a2b9c691841738292e67cfe0b6c7"
        )
    }

    func testBundledWorldLocationAreasResolveGlobalAndCoastalFixtures() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let areasURL = repositoryRoot
            .appendingPathComponent("SignalQuestApp/Resources/market_location_areas.json")
        let file = try JSONDecoder().decode(
            MarketLocationAreasFile.self,
            from: Data(contentsOf: areasURL)
        )

        XCTAssertEqual(file.areas.count, 1_335)
        XCTAssertEqual(Set(file.areas.map(\.market)).count, 212)
        XCTAssertEqual(file.candidates(latitude: 28.0339, longitude: 1.6596).first?.market, "DZ")
        XCTAssertEqual(file.candidates(latitude: 31.7917, longitude: -7.0926).first?.market, "MA")
        XCTAssertEqual(file.candidates(latitude: 42.3154, longitude: 43.3569).first?.market, "GE")
        XCTAssertEqual(file.candidates(latitude: 40.7128, longitude: -74.0060).first?.market, "US")
        XCTAssertEqual(file.candidates(latitude: 41.0082, longitude: 28.9784).first?.market, "TR")
        XCTAssertEqual(file.candidates(latitude: 16.25, longitude: -61.55).first?.market, "DROM")
    }

    /// UNE IDENTIFICATION DOIT SURVIVRE AU RETOUR SUR L'ÉCRAN.
    ///
    /// Le statut ne vivait qu'en mémoire : le magasin n'était alimenté que par le balayage,
    /// donc la liste réaffichait « Non identifié » dès qu'elle relisait le cache. L'utilisateur
    /// voyait son travail disparaître alors que le serveur l'avait accepté.
    func testIdentificationSurvivesACacheReload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("radiolog-status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = RadioLogSiteStatusStore(fileURL: url)
        store.merge(["enb:626821": .identified(siteId: "sup-42")], nowMs: 1_786_000_000_000)

        // Relecture par une INSTANCE NEUVE : c'est ce que fait l'écran au retour.
        let reloaded = RadioLogSiteStatusStore(fileURL: url)
        let states = reloaded.fresh(
            identifiedTtlMs: 30 * 24 * 3_600_000,
            unidentifiedTtlMs: 3_600_000,
            nowMs: 1_786_000_060_000
        )
        XCTAssertEqual(states["enb:626821"], .identified(siteId: "sup-42"))
    }
}

private struct StubAntennasService: AntennasServicing {
    func list(bbox: BoundingBox) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, sharing: Set<String>) async throws -> [AntennaSite] { [] }
    func list(bbox: BoundingBox, market: String, operatorName: String, technologies: Set<String>, bands: Set<Int>, bandMatch: BandMatchMode, sharing: Set<String>) async throws -> [AntennaSite] { [] }
    func details(id: String) async throws -> AntennaDetails { throw APIError.cancelled }
    func details(id: String, market: String, operatorName: String) async throws -> AntennaDetails { throw APIError.cancelled }
    func details(id: String, market: String, operatorName: String, anfrCode: String?) async throws -> AntennaDetails { throw APIError.cancelled }
    func search(query: String) async throws -> [AntennaSite] { [] }
    func quickSearch(query: String, market: String, department: String?) async throws -> [AntennaSite] { [] }
    func listCommunitySites(bbox: BoundingBox, market: String, operatorName: String?) async throws -> [AntennaSite] { [] }
}
