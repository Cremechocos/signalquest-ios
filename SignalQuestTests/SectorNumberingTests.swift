import XCTest
@testable import SignalQuest

/// SECTOR-TELECOM-01 — vérifie la parité avec Android `SectorNumbering.kt` :
/// SFR numérote à partir de 0, Orange/Bouygues/Free à partir de 1, tant que la base 1
/// (`SQFeatures.sectorBaseOne`) est fermée ; puis SECTOR-BASE-1, tout à partir de 1.
final class SectorNumberingTests: XCTestCase {
    func testOrangeIsOneBased() {
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, operatorName: "ORANGE", sectorBaseOne: false), 1)
        XCTAssertEqual(SectorNumbering.displayValue(index: 2, operatorName: "Orange France", sectorBaseOne: false), 3)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, mccMnc: "20801", operatorName: nil, sectorBaseOne: false), 1)
    }

    func testSfrIsZeroBased() {
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, operatorName: "SFR", sectorBaseOne: false), 0)
        XCTAssertEqual(SectorNumbering.displayValue(index: 2, operatorName: "SFR", sectorBaseOne: false), 2)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 1, mccMnc: "20810", operatorName: nil, sectorBaseOne: false), 1)
    }

    func testBouyguesAndFreeAreOneBased() {
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, operatorName: "Bouygues Telecom", sectorBaseOne: false), 1)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, operatorName: "Free Mobile", sectorBaseOne: false), 1)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, mccMnc: "20820", operatorName: nil, sectorBaseOne: false), 1) // Bouygues
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, mccMnc: "20815", operatorName: nil, sectorBaseOne: false), 1) // Free
    }

    func testIndexForStoredValue() {
        // Orange stocke 1-based : secteur 1 → index 0.
        XCTAssertEqual(SectorNumbering.index(forStoredValue: 1, azimuthCount: 3, operatorName: "ORANGE", sectorBaseOne: false), 0)
        // SFR stocke 0-based : secteur 0 → index 0.
        XCTAssertEqual(SectorNumbering.index(forStoredValue: 0, azimuthCount: 3, operatorName: "SFR", sectorBaseOne: false), 0)
        // Hors plage → nil.
        XCTAssertNil(SectorNumbering.index(forStoredValue: 9, azimuthCount: 3, operatorName: "SFR", sectorBaseOne: false))
    }

    func testSectorFromPci() {
        // SFR zero-based : PCI 7 → 7 % 3 = 1 → secteur 1.
        XCTAssertEqual(SectorNumbering.sectorValue(forPci: 7, operatorName: "SFR", sectorBaseOne: false), 1)
        // Orange one-based : PCI 7 → index 1 → secteur 2.
        XCTAssertEqual(SectorNumbering.sectorValue(forPci: 7, operatorName: "ORANGE", sectorBaseOne: false), 2)
        XCTAssertNil(SectorNumbering.sectorValue(forPci: -1, operatorName: "ORANGE", sectorBaseOne: false))
    }

    func testUnknownOperatorIsLegacy() {
        // Legacy : affiche 1-based, soumet 0-based (comportement historique conservé).
        XCTAssertEqual(SectorNumbering.displayValue(index: 0, operatorName: "UnknownCarrier", sectorBaseOne: false), 1)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, operatorName: "UnknownCarrier", sectorBaseOne: false), 0)
    }

    func testRadioIdentifiersPickTheAzimuthOfTheOperatorNumbering() {
        // SFR : secteur 0 = premier azimut ; Orange : secteur 1 = premier azimut.
        XCTAssertEqual(AntennaRadioIdentifiersView.azimuthIndex(forSector: 0, operatorName: "SFR", sectorBaseOne: false), 0)
        XCTAssertEqual(AntennaRadioIdentifiersView.azimuthIndex(forSector: 2, operatorName: "SFR", sectorBaseOne: false), 2)
        XCTAssertEqual(AntennaRadioIdentifiersView.azimuthIndex(forSector: 1, operatorName: "ORANGE", sectorBaseOne: false), 0)
        XCTAssertEqual(AntennaRadioIdentifiersView.azimuthIndex(forSector: 4, operatorName: "FREE MOBILE", sectorBaseOne: false), 3)
        XCTAssertNil(AntennaRadioIdentifiersView.azimuthIndex(forSector: 0, operatorName: "ORANGE", sectorBaseOne: false))
        // Tous opérateurs : convention historique, à partir de 1.
        XCTAssertEqual(AntennaRadioIdentifiersView.azimuthIndex(forSector: 1, operatorName: "ALL", sectorBaseOne: false), 0)
    }

    /// ANFR-38 : le PLMN d'une identification garde deux chiffres de MNC.
    func testPlmnKeepsTwoDigitsOfTheMnc() {
        XCTAssertEqual(SectorNumbering.plmn(mcc: 208, mnc: 1), "20801")
        XCTAssertEqual(SectorNumbering.plmn(mcc: 208, mnc: 15), "20815")
        XCTAssertNil(SectorNumbering.plmn(mcc: 208, mnc: nil))
        XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: SectorNumbering.plmn(mcc: 208, mnc: 10), operatorName: nil, sectorBaseOne: false), .zeroBased)
    }

    // MARK: SECTOR-BASE-1

    func testBaseOneNumbersSfrFromOne() {
        XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: "20810", operatorName: nil, sectorBaseOne: true), .oneBased)
        XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: nil, operatorName: "SFR", sectorBaseOne: true), .oneBased)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, mccMnc: "20810", operatorName: "SFR", sectorBaseOne: true), 1)
        XCTAssertEqual(SectorNumbering.displayValue(index: 2, operatorName: "SFR", sectorBaseOne: true), 3)
        // Le secteur 1 stocké est le premier azimut ; une valeur 0 d'avant reste lisible.
        XCTAssertEqual(SectorNumbering.index(forStoredValue: 1, azimuthCount: 3, operatorName: "SFR", sectorBaseOne: true), 0)
        XCTAssertEqual(SectorNumbering.index(forStoredValue: 0, azimuthCount: 3, operatorName: "SFR", sectorBaseOne: true), 0)
        XCTAssertEqual(SectorNumbering.sectorValue(forPci: 7, operatorName: "SFR", sectorBaseOne: true), 2)
        XCTAssertEqual(AntennaRadioIdentifiersView.azimuthIndex(forSector: 1, operatorName: "SFR", sectorBaseOne: true), 0)
        XCTAssertNil(AntennaRadioIdentifiersView.azimuthIndex(forSector: 0, operatorName: "SFR", sectorBaseOne: true))
    }

    func testBaseOneCoversTheWhiteZoneAndEveryFrenchPlmn() {
        // Zone blanche sans PLMN d'opérateur (MNC 0) et MVNO : la base 0 disparaît en France.
        XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: "20800", operatorName: nil, sectorBaseOne: true), .oneBased)
        XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: nil, operatorName: "ZB", sectorBaseOne: true), .oneBased)
        XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: "20826", operatorName: nil, sectorBaseOne: true), .oneBased)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, mccMnc: "20800", operatorName: "ZB", sectorBaseOne: true), 1)
        // Avant la base 1, ces lignes restaient `legacy`.
        XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: "20800", operatorName: nil, sectorBaseOne: false), .legacy)
        XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: "20801", operatorName: nil, sectorBaseOne: true), .oneBased)
    }

    func testBaseOneNumbersEveryOperatorFromOne() {
        for name in ["BELL", "ROGERS", "TELUS", "VIDEOTRON_FREEDOM", "Freedom Mobile", "REGIONAL"] {
            XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: nil, operatorName: name, sectorBaseOne: true), .oneBased, name)
            XCTAssertEqual(SectorNumbering.submissionValue(index: 0, operatorName: name, sectorBaseOne: true), 1, name)
        }
        XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: "302220", operatorName: nil, sectorBaseOne: true), .oneBased)
        XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: nil, operatorName: "VIDEOTRON_FREEDOM", sectorBaseOne: false), .legacy)
        // « Tout en base 1 » (§5) : Belgique, Suisse, DROM et opérateur inconnu aussi, le
        // legacy disparaît ; hors base 1 ils restent legacy.
        for (plmn, name) in [("20620", "BASE"), ("22803", "SALT"), ("64710", "SRR"), ("34020", "DIGICEL"),
                             (nil, "UnknownCarrier"), (nil, nil)] as [(String?, String?)] {
            XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: plmn, operatorName: name, sectorBaseOne: true), .oneBased, name ?? "nil")
            XCTAssertEqual(SectorNumbering.submissionValue(index: 0, mccMnc: plmn, operatorName: name, sectorBaseOne: true), 1, name ?? "nil")
            XCTAssertEqual(SectorNumbering.resolveMode(mccMnc: plmn, operatorName: name, sectorBaseOne: false), .legacy, name ?? "nil")
        }
        XCTAssertEqual(SectorNumbering.index(forStoredValue: 1, azimuthCount: 3, operatorName: "DIGICEL", sectorBaseOne: true), 0)
        XCTAssertEqual(AntennaRadioIdentifiersView.azimuthIndex(forSector: 1, operatorName: "ALL", sectorBaseOne: true), 0)
    }

    // MARK: Signalements d'antenne (SECTOR-BASE-1 §3)

    func testReportSendsTheNumberAndTheAzimuthApartInBaseOne() throws {
        let before = AntennaReportSubmission.sectorFields(azimuth: 220, number: 2, sectorBaseOne: false)
        XCTAssertEqual(before.sector, 220, "avant : l'azimut dans `sector`, rangé par le serveur")
        XCTAssertNil(before.sectorAzimuth)
        let after = AntennaReportSubmission.sectorFields(azimuth: 220, number: 2, sectorBaseOne: true)
        XCTAssertEqual(after.sector, 2)
        XCTAssertEqual(after.sectorAzimuth, 220)
        let unknownOperator = AntennaReportSubmission.sectorFields(azimuth: 220, number: nil, sectorBaseOne: true)
        XCTAssertNil(unknownOperator.sector, "sans opérateur, le numéro n'est pas connu")
        XCTAssertEqual(unknownOperator.sectorAzimuth, 220)
        let none = AntennaReportSubmission.sectorFields(azimuth: nil, number: nil, sectorBaseOne: true)
        XCTAssertNil(none.sector)
        XCTAssertNil(none.sectorAzimuth)

        let body = AntennaReportSubmission(siteId: "0381234", reportType: "incorrect_sector", currentValue: nil,
                                           suggestedValue: nil, reason: nil, sector: 2, sectorAzimuth: 220)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(json["sector"] as? Int, 2)
        XCTAssertEqual(json["sectorAzimuth"] as? Int, 220)
        let old = AntennaReportSubmission(siteId: "0381234", reportType: "incorrect_sector", currentValue: nil,
                                          suggestedValue: nil, reason: nil, sector: 220, sectorAzimuth: nil)
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        XCTAssertNil(oldJSON["sectorAzimuth"], "un champ vide n'est pas envoyé")
    }

    func testReportReadsTheNumberAndTheAzimuth() throws {
        let report = try JSONDecoder().decode(AntennaReport.self, from: Data(#"""
        {"id":"r1","siteId":"0381234","reportType":"incorrect_sector","sector":2,"sectorAzimuth":220,"status":"pending"}
        """#.utf8))
        XCTAssertEqual(report.sector, 2)
        XCTAssertEqual(report.sectorAzimuth, 220)
        XCTAssertEqual(report.sectorLabel(sectorBaseOne: true), String(localized: "Secteur \(2) · \(220)°"))
        XCTAssertEqual(AntennaReport(id: "r2", siteId: "s", reportType: .incorrectSector, sector: 3).sectorLabel(sectorBaseOne: true),
                       String(localized: "Secteur \(3)"))
        XCTAssertEqual(AntennaReport(id: "r3", siteId: "s", reportType: .incorrectSector, sectorAzimuth: 140).sectorLabel(sectorBaseOne: true),
                       String(localized: "Secteur \(140)°"))
        // Sans l'en-tête, le serveur renvoie l'azimut dans `sector` : lu comme avant.
        XCTAssertEqual(AntennaReport(id: "r4", siteId: "s", reportType: .incorrectSector, sector: 220).sectorLabel(sectorBaseOne: false),
                       String(localized: "Secteur \(220)°"))
        XCTAssertNil(AntennaReport(id: "r5", siteId: "s", reportType: .other).sectorLabel(sectorBaseOne: true))
    }

    // MARK: SECTOR-NORTH-2 (vecteur sector-numbering-v1, copié à l'octet de la PR #1352)

    private func sectorVector() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/identify/sector-numbering-v1.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func context(_ item: [String: Any]) -> SectorOrientation.Context {
        SectorOrientation.Context(operatorName: item["operator"] as? String, sharingType: item["sharingType"] as? String,
                                  crozonLeader: item["crozonLeader"] as? String, isZTD: item["isZTD"] as? Bool ?? false)
    }

    func testNorthFirstOrderReplaysTheServerVector() throws {
        let cases = try XCTUnwrap(sectorVector()["orderCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 18)
        for item in cases {
            let name = item["name"] as? String ?? "?"
            let azimuths = try XCTUnwrap(item["azimuts"] as? [Double], name)
            let expected = try XCTUnwrap(item["expectedOrder"] as? [Double], name)
            XCTAssertEqual(SectorOrientation.ordered(azimuths, context: context(item)), expected, name)
        }
    }

    /// Le numéro servi désigne le même cône que chez le serveur : azimuts hors faisceau hertzien
    /// (comme `azimuts` du détail), regroupés à 20°, ordonnés, puis le secteur N au rang N.
    func testEachServedNumberPointsTheServerCone() throws {
        let cases = try XCTUnwrap(sectorVector()["cellCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 34)
        for item in cases {
            let name = item["name"] as? String ?? "?"
            let raw = try XCTUnwrap(item["azimuts"] as? [Double], name)
            let fh = item["azimutsFh"] as? [Bool] ?? []
            let served = raw.enumerated().filter { !(fh.indices.contains($0.offset) && fh[$0.offset]) }.map(\.element)
            let cones = SectorOrientation.numberedCones(served, context: context(item), sectorBaseOne: true)
            XCTAssertEqual(cones.count, item["expectedSectorCount"] as? Int ?? 0, name)
            guard let sector = item["expectedSector"] as? Int, let azimuth = item["expectedAzimuthDeg"] as? Double else { continue }
            let index = try XCTUnwrap(AntennaRadioIdentifiersView.azimuthIndex(
                forSector: sector, operatorName: item["operator"] as? String, sectorBaseOne: true), name)
            XCTAssertEqual(cones[index], azimuth, accuracy: 0.01, name)
        }
    }

    func testNorthFirstWaitsForBaseOne() {
        let sfrOnBouyguesCrozon = SectorOrientation.Context(operatorName: "SFR", sharingType: "crozon", crozonLeader: "BOUYGUES")
        // Sans l'en-tête, l'ordre servi reste tel quel : le serveur convertit les numéros SFR.
        XCTAssertEqual(SectorOrientation.numberedCones([90, 200, 330], context: sfrOnBouyguesCrozon, sectorBaseOne: false), [90, 200, 330])
        XCTAssertEqual(SectorOrientation.numberedCones([74, 75, 255], context: SectorOrientation.Context(), sectorBaseOne: false), [74, 75, 255])
        let northFirst = SectorOrientation.numberedCones([90, 200, 330], context: sfrOnBouyguesCrozon, sectorBaseOne: true)
        XCTAssertEqual(northFirst.count, 3)
        for (cone, expected) in zip(northFirst, [330.0, 90, 200]) { XCTAssertEqual(cone, expected, accuracy: 0.01) }
        // Le regroupement boucle par le nord : 355° et 3° sont un seul secteur, vers 359°.
        let wrapped = SectorOrientation.clustered([3, 120, 240, 355])
        XCTAssertEqual(wrapped.count, 3)
        XCTAssertEqual(wrapped.last ?? 0, 359, accuracy: 0.01)
    }

    func testReportAzimuthTakesTheRankOfItsNearestCone() {
        let cones: [Double] = [330, 90, 200]
        XCTAssertEqual(SectorOrientation.nearestIndex(of: 332, in: cones), 0)
        XCTAssertEqual(SectorOrientation.nearestIndex(of: 2, in: cones), 0)
        XCTAssertEqual(SectorOrientation.nearestIndex(of: 91, in: cones), 1)
        XCTAssertEqual(SectorOrientation.nearestIndex(of: 199, in: cones), 2)
        XCTAssertNil(SectorOrientation.nearestIndex(of: 10, in: []))
    }
}
