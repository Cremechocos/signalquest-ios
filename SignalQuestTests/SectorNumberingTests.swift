import XCTest
@testable import SignalQuest

/// SECTOR-TELECOM-01 — vérifie la parité avec Android `SectorNumbering.kt` :
/// SFR numérote à partir de 0, Orange/Bouygues/Free à partir de 1.
final class SectorNumberingTests: XCTestCase {
    func testOrangeIsOneBased() {
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, operatorName: "ORANGE"), 1)
        XCTAssertEqual(SectorNumbering.displayValue(index: 2, operatorName: "Orange France"), 3)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, mccMnc: "20801", operatorName: nil), 1)
    }

    func testSfrIsZeroBased() {
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, operatorName: "SFR"), 0)
        XCTAssertEqual(SectorNumbering.displayValue(index: 2, operatorName: "SFR"), 2)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 1, mccMnc: "20810", operatorName: nil), 1)
    }

    func testBouyguesAndFreeAreOneBased() {
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, operatorName: "Bouygues Telecom"), 1)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, operatorName: "Free Mobile"), 1)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, mccMnc: "20820", operatorName: nil), 1) // Bouygues
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, mccMnc: "20815", operatorName: nil), 1) // Free
    }

    func testIndexForStoredValue() {
        // Orange stocke 1-based : secteur 1 → index 0.
        XCTAssertEqual(SectorNumbering.index(forStoredValue: 1, azimuthCount: 3, operatorName: "ORANGE"), 0)
        // SFR stocke 0-based : secteur 0 → index 0.
        XCTAssertEqual(SectorNumbering.index(forStoredValue: 0, azimuthCount: 3, operatorName: "SFR"), 0)
        // Hors plage → nil.
        XCTAssertNil(SectorNumbering.index(forStoredValue: 9, azimuthCount: 3, operatorName: "SFR"))
    }

    func testSectorFromPci() {
        // SFR zero-based : PCI 7 → 7 % 3 = 1 → secteur 1.
        XCTAssertEqual(SectorNumbering.sectorValue(forPci: 7, operatorName: "SFR"), 1)
        // Orange one-based : PCI 7 → index 1 → secteur 2.
        XCTAssertEqual(SectorNumbering.sectorValue(forPci: 7, operatorName: "ORANGE"), 2)
        XCTAssertNil(SectorNumbering.sectorValue(forPci: -1, operatorName: "ORANGE"))
    }

    func testUnknownOperatorIsLegacy() {
        // Legacy : affiche 1-based, soumet 0-based (comportement historique conservé).
        XCTAssertEqual(SectorNumbering.displayValue(index: 0, operatorName: "UnknownCarrier"), 1)
        XCTAssertEqual(SectorNumbering.submissionValue(index: 0, operatorName: "UnknownCarrier"), 0)
    }
}
