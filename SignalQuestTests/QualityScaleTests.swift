import XCTest
import UIKit
@testable import SignalQuest

/// Lot 3a : une seule échelle débit / signal / génération (MES-11, TRX-05),
/// et un seul formatage des débits et des bandes (TRX-24, MES-25, TRX-27).
final class QualityScaleTests: XCTestCase {
    func testThroughputTiersMatchTheWebThresholds() {
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 1_000), .exceptional)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 999.9), .veryGood)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 600), .veryGood)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 300), .veryGood)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 100), .good)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 30), .medium)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 10), .slow)
        XCTAssertEqual(SQQualityScale.Throughput(mbps: 9.9), .verySlow)
        XCTAssertEqual(SQQualityScale.Throughput.exceptional.hex, 0x15803D)
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
        // Arrondi de Math.round (contrat quality-scale v1) : −110,5 → −110, « faible ».
        XCTAssertEqual(SQQualityScale.Signal(rsrp: -110.5), .weak)
        XCTAssertEqual(SQQualityScale.Signal(rsrp: -110.6), .poor)
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
        XCTAssertEqual(SQUnits.throughputValue(mbps: 7.54, locale: fr), "7,5")
        XCTAssertEqual(SQUnits.throughputValue(mbps: 7.54, locale: en), "7.5")
        XCTAssertEqual(SQUnits.throughputValue(mbps: 64.34, locale: fr), "64")
        XCTAssertEqual(SQUnits.throughputValue(mbps: 412.4, locale: fr), "412")
        XCTAssertEqual(SQUnits.throughputValue(mbps: 1_722, locale: fr), "1,722")
        XCTAssertEqual(SQUnits.throughputValue(mbps: 2_000, locale: en), "2.000")
        XCTAssertEqual(SQUnits.throughputValue(mbps: .nan, locale: fr), "—")
    }

    /// Bornes `rates` de presentation-v1 (map-nextjs, #811) : décimale facultative
    /// sous 9,95 Mb/s (« 7 », jamais « 7,0 »), entier ensuite, Gb/s à trois
    /// décimales dès 999,5 (décision du 02/11, commune aux trois apps).
    func testThroughputFollowsThePresentationRateVector() {
        let fr = Locale(identifier: "fr_FR"), en = Locale(identifier: "en_US")
        let rates: [(kbps: Double, fr: String, en: String)] = [
            (7_000, "7\u{00A0}Mb/s", "7\u{00A0}Mb/s"), (7_500, "7,5\u{00A0}Mb/s", "7.5\u{00A0}Mb/s"),
            (9_940, "9,9\u{00A0}Mb/s", "9.9\u{00A0}Mb/s"), (9_950, "10\u{00A0}Mb/s", "10\u{00A0}Mb/s"),
            (84_000, "84\u{00A0}Mb/s", "84\u{00A0}Mb/s"), (999_400, "999\u{00A0}Mb/s", "999\u{00A0}Mb/s"),
            (999_500, "1,000\u{00A0}Gb/s", "1.000\u{00A0}Gb/s"), (1_722_000, "1,722\u{00A0}Gb/s", "1.722\u{00A0}Gb/s"),
        ]
        for rate in rates {
            let mbps = rate.kbps / 1_000
            // Les vecteurs portent une insécable U+00A0 avant l'unité.
            XCTAssertEqual(SQUnits.throughput(mbps: mbps, locale: fr), rate.fr, "\(rate.kbps)")
            XCTAssertEqual(SQUnits.throughput(mbps: mbps, locale: en), rate.en, "\(rate.kbps)")
            XCTAssertEqual(WidgetUnits.throughputValue(mbps: mbps, locale: fr), SQUnits.throughputValue(mbps: mbps, locale: fr), "\(rate.kbps)")
        }
        XCTAssertEqual(SQUnits.throughputValue(mbps: 0, locale: fr), "0")
        XCTAssertEqual(SQUnits.throughputValue(mbps: 6.96, locale: fr), "7")
        // Arrondi sur des kb/s entiers, demi vers le haut (feed-text-keys v2, presentation-v1).
        for (mbps, expected) in [(0.15, "0,2"), (7.25, "7,3"), (10.5, "11"), (12.5, "13"), (87.34, "87"), (998.5, "999"), (999.4996, "1,000"), (1_722.5, "1,723")] {
            XCTAssertEqual(SQUnits.throughputValue(mbps: mbps, locale: fr), expected, "\(mbps)")
            XCTAssertEqual(WidgetUnits.throughputValue(mbps: mbps, locale: fr), expected, "\(mbps)")
        }
        XCTAssertEqual(SQUnits.throughputUnit(mbps: 999.4996), SQUnits.throughputUnit(mbps: 1_000), "999 499,6 kb/s s'arrondit à 999 500 : Gb/s")
    }

    /// Même règle pour les distances : « 12,3 km » en français (MES-25).
    func testDistanceUsesTheLocaleDecimalSeparator() {
        let fr = Locale(identifier: "fr_FR"), en = Locale(identifier: "en_US")
        XCTAssertEqual(SQUnits.distance(meters: 12_345, system: .metric, locale: fr), "12,3 km")
        XCTAssertEqual(SQUnits.distance(meters: 12_345, system: .metric, locale: en), "12.3 km")
        XCTAssertEqual(SQUnits.distance(meters: 340, system: .metric, locale: fr), "340 m")
        XCTAssertEqual(SQUnits.distance(meters: 2_414, system: .imperial, locale: fr), "1,5 mi")
    }

    /// Les widgets et la Live Activity recopient les règles de `SQUnits` (la cible
    /// widget ne le voit pas) : débit, unité et distance restent identiques.
    func testWidgetUnitsFollowTheAppRules() {
        let fr = Locale(identifier: "fr_FR"), en = Locale(identifier: "en_US")
        for mbps in [0.0, 6.4, 99.96, 100, 412.4, 999.4, 1_000, 1_240, .nan, -3] {
            XCTAssertEqual(WidgetUnits.throughputValue(mbps: mbps, locale: fr), SQUnits.throughputValue(mbps: mbps, locale: fr), "\(mbps)")
            XCTAssertEqual(WidgetUnits.throughputValue(mbps: mbps, locale: en), SQUnits.throughputValue(mbps: mbps, locale: en), "\(mbps)")
            XCTAssertEqual(WidgetUnits.throughputUnit(mbps: mbps), SQUnits.throughputUnit(mbps: mbps), "\(mbps)")
            XCTAssertEqual(WidgetUnits.throughput(mbps: mbps, locale: fr), SQUnits.throughput(mbps: mbps, locale: fr), "\(mbps)")
        }
        XCTAssertEqual(WidgetUnits.throughputValue(mbps: 6.4, locale: fr), "6,4", "6,4 ne s'arrondit plus à 6")
        XCTAssertEqual(WidgetUnits.compactThroughput(mbps: 1_240, locale: fr), "1,240G")
        XCTAssertEqual(WidgetUnits.compactThroughput(mbps: 412, locale: fr), "412")
        for meters in [30.0, 180, 340, 999, 1_000, 2_414, 12_345, .nan] {
            XCTAssertEqual(WidgetUnits.distance(meters: meters, imperial: false, locale: fr), SQUnits.distance(meters: meters, system: .metric, locale: fr), "\(meters)")
            XCTAssertEqual(WidgetUnits.distance(meters: meters, imperial: true, locale: fr), SQUnits.distance(meters: meters, system: .imperial, locale: fr), "\(meters)")
        }
    }

    /// Un rayon rond ne prend pas de décimale inutile (« 5 km », pas « 5,0 km »),
    /// et suit la préférence métrique ou impériale.
    func testCompactDistanceKeepsRoundRadiiRound() {
        let fr = Locale(identifier: "fr_FR")
        XCTAssertEqual(SQUnits.distanceCompact(meters: 5_000, system: .metric, locale: fr), "5 km")
        XCTAssertEqual(SQUnits.distanceCompact(meters: 1_500, system: .metric, locale: fr), "1,5 km")
        XCTAssertEqual(SQUnits.distanceCompact(meters: 250, system: .metric, locale: fr), "250 m")
        XCTAssertEqual(SQUnits.distanceCompact(meters: 1_609.344, system: .imperial, locale: fr), "1 mi")
        XCTAssertEqual(SQUnits.distanceCompact(meters: 5_000, system: .imperial, locale: fr), "3,1 mi")
        XCTAssertEqual(SQUnits.distanceCompact(meters: 30, system: .imperial, locale: fr), "98 ft")
        XCTAssertEqual(SQUnits.distanceCompact(meters: .nan, system: .metric, locale: fr), "—")
    }

    /// Une seule règle de gigue pour le test, son détail et le Drive Test :
    /// une décimale sous 10 ms, entière au-delà.
    func testJitterHasOneDecimalUnderTenMilliseconds() {
        let fr = Locale(identifier: "fr_FR"), en = Locale(identifier: "en_US")
        XCTAssertEqual(SQUnits.jitterValue(4.24, locale: fr), "4,2")
        XCTAssertEqual(SQUnits.jitterValue(4.24, locale: en), "4.2")
        XCTAssertEqual(SQUnits.jitterValue(0, locale: fr), "0,0")
        XCTAssertEqual(SQUnits.jitterValue(9.96, locale: fr), "10", "9,96 s'arrondit à 10 : plus de décimale")
        XCTAssertEqual(SQUnits.jitterValue(12.4, locale: fr), "12")
        XCTAssertEqual(SQUnits.jitter(12.4, locale: fr), "12 ms")
        XCTAssertEqual(SQUnits.jitter(.nan, locale: fr), "—")
        XCTAssertEqual(SQUnits.jitterValue(-1, locale: fr), "—")
    }

    /// « Mb/s » et « Gb/s » dans toutes les langues, comme Android et le web
    /// (décision du 20/10). Lu dans les fichiers compilés : cette suite tourne en
    /// français.
    func testEveryLanguageWritesMbAndGbPerSecond() throws {
        for language in ["en", "fr"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                subdirectory: "\(language).lproj"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), options: [], format: nil) as? [String: String])
            XCTAssertEqual(table["Mbit/s"], "Mb/s", language)
            XCTAssertEqual(table["Gbit/s"], "Gb/s", language)
            let legacy = table.filter { $0.value.range(of: #"Mbps|Gbps|Mbit/s|Gbit/s"#, options: .regularExpression) != nil }
            XCTAssertEqual(legacy.keys.sorted(), [], language)
        }
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
