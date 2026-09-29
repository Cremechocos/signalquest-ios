import XCTest
import UIKit
@testable import SignalQuest

/// Lot 3a : une seule échelle débit / signal / génération (MES-11, TRX-05),
/// et un seul formatage des débits et des bandes (TRX-24, MES-25, TRX-27).
final class QualityScaleTests: XCTestCase {
    func testThroughputTiersMatchTheWebThresholds() {
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 1_000), .exceptional)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 999.9), .excellent)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 300), .veryGood)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 100), .good)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 30), .medium)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 10), .slow)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 9.9), .verySlow)
        XCTAssertEqual(SQQualityScale.Throughput.exceptional.hex, 0x3B82F6)
        XCTAssertEqual(SQQualityScale.Throughput.verySlow.hex, 0xEF4444)
    }

    /// La variante « marque » du Drive Test peignait le meilleur palier en terre
    /// cuite et le pire en rouge : ils doivent rester aux deux bouts de l'échelle.
    func testBestAndWorstThroughputTiersAreFarApart() {
        XCTAssertNotEqual(SQQualityScale.Throughput.exceptional.hex, SQQualityScale.Throughput.verySlow.hex)
        XCTAssertEqual(Set(SQQualityScale.Throughput.allCases.map(\.hex)).count, SQQualityScale.Throughput.allCases.count)
    }

    func testSignalKeepsTheNoMeasurementGuard() {
        XCTAssertEqual(SQQualityScale.Signal(rsrp: nil), .unknown)
        XCTAssertEqual(SQQualityScale.Signal(rsrp: 0), .unknown)
        XCTAssertEqual(SQQualityScale.Signal(rsrp: -44), .excellent)
        XCTAssertEqual(SQQualityScale.Signal(rsrp: -90), .good)
        XCTAssertEqual(SQQualityScale.Signal(rsrp: -110.5), .poor)
    }

    func testMapBandsReadTheSharedScale() {
        XCTAssertEqual(CoverageQualityBand.band(for: -95), .fair)
        XCTAssertEqual(CoverageQualityBand.fair.colorHex, SQQualityScale.Signal.fair.hex)
        XCTAssertEqual(CoverageGenerationBand.band(for: "5G NSA"), .g5)
        XCTAssertEqual(CoverageGenerationBand.g4.colorHex, SQQualityScale.Generation.fourG.hex)
        XCTAssertEqual(SpeedBand.band(forDownload: 450), .veryGood)
        XCTAssertEqual(SQNetworkColors.speedHex(450), SQQualityScale.Throughput.veryGood.hex)
        XCTAssertEqual(SQNetworkColors.rsrpHex(-85), SQQualityScale.Signal.good.hex)
    }

    /// Les anciens glyphes « chevron.up.3 » (inexistant) et « chevron.up.2 »
    /// (iOS 18) laissaient des cases vides dans la légende du Drive Test.
    func testEveryGlyphExists() {
        for tier in SQQualityScale.Throughput.allCases {
            XCTAssertNotNil(UIImage(systemName: tier.glyph), tier.glyph)
        }
        for level in SQQualityScale.Signal.allCases {
            XCTAssertNotNil(UIImage(systemName: level.glyph), level.glyph)
        }
    }

    func testThroughputUsesTheLocaleDecimalSeparator() {
        let fr = Locale(identifier: "fr_FR"), en = Locale(identifier: "en_US")
        XCTAssertEqual(SQUnits.throughputValue(mbps: 64.34, locale: fr), "64,3")
        XCTAssertEqual(SQUnits.throughputValue(mbps: 64.34, locale: en), "64.3")
        XCTAssertEqual(SQUnits.throughputValue(mbps: 412.4, locale: fr), "412")
        XCTAssertEqual(SQUnits.throughputValue(mbps: 1_234, locale: fr), "1,2")
        XCTAssertEqual(SQUnits.throughputValue(mbps: .nan, locale: fr), "—")
    }

    /// Le lexique veut « Mbps » en anglais ; les unités manquaient au catalogue,
    /// l'anglais affichait donc « Mbit/s ». Lu dans le fichier compilé : cette
    /// suite tourne en français.
    func testEnglishWritesMbpsAndGbps() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
            subdirectory: "en.lproj"))
        let english = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil) as? [String: String])
        XCTAssertEqual(english["Mbit/s"], "Mbps")
        XCTAssertEqual(english["Gbit/s"], "Gbps")
    }

    func testRangeLabelsDescribeEachTier() {
        XCTAssertTrue(SQQualityScale.Throughput.exceptional.rangeLabel.hasSuffix("+"))
        XCTAssertTrue(SQQualityScale.Throughput.verySlow.rangeLabel.hasPrefix("< "))
        XCTAssertTrue(SQQualityScale.Throughput.medium.rangeLabel.hasPrefix("30"))
        XCTAssertTrue(SQQualityScale.Throughput.medium.rangeLabel.hasSuffix("100"))
    }

    func testFiveGBandsUseTheNPrefix() {
        XCTAssertEqual(SQUnits.band(78), "n78")
        XCTAssertEqual(SQUnits.band(257), "n257")
        XCTAssertEqual(SQUnits.band(20, technology: "LTE"), "B20")
        XCTAssertEqual(SQUnits.band(28, technology: "NR"), "n28")
        XCTAssertEqual(SQUnits.band(3, technology: "5G"), "n3")
        XCTAssertEqual(SQUnits.band(28, technology: "5G NSA"), "B28", "En NSA, la bande principale est souvent l'ancre 4G")
        XCTAssertEqual(SQUnits.band(28, isNR: true), "n28")
    }
}
