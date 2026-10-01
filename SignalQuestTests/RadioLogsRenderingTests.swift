import SwiftUI
import XCTest
@testable import SignalQuest

/// TRX-12 (plan 3, lot 11) : la carte d'un site du journal radio au plancher
/// de 12 pt, rendue en français et en anglais, en taille normale et agrandie,
/// pour une relecture visuelle (`build/qa/radio-logs-card`). Le mode démo n'a
/// pas de journal : ce rendu est la seule vue de ses rangées hors compte réel.
@MainActor
final class RadioLogsRenderingTests: XCTestCase {
    func testSiteCardRendersAtTheTwelvePointFloor() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = repository.appendingPathComponent("build/qa/radio-logs-card")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let site = RadioLogSite(
            id: "orange|208|01|eNB|812345", kind: .enb, node: "812345", operatorName: "Orange", rawOperatorName: "Orange F",
            operatorKey: "orange", marketCode: "FR", countryCode: "FR", isRoaming: false, mcc: "208", mnc: "01",
            cells: [
                RadioLogCell(
                    id: "c1", pci: 35, ci: 207_960_321, eciCellId: nil, identityKind: "ECI",
                    networkIdentitySource: "SERVING_CELL", band: 3, earfcn: 1_501, bestRsrp: -87, logCount: 42
                ),
                RadioLogCell(
                    id: "c2", pci: 412, ci: 207_960_322, eciCellId: nil, identityKind: "ECI",
                    networkIdentitySource: "SERVING_CELL", band: 20, earfcn: 6_300, bestRsrp: -104, logCount: 7
                ),
            ],
            logCount: 49, firstSeenAt: Date(timeIntervalSince1970: 1_790_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_790_050_000), latitude: 45.19, longitude: 5.72, band: 3, earfcn: 1_501
        )
        let cases: [(String, Locale, DynamicTypeSize, Bool)] = [
            ("fr", Locale(identifier: "fr_FR"), .large, true),
            ("en", Locale(identifier: "en_US"), .large, true),
            ("fr-xxl", Locale(identifier: "fr_FR"), .xxxLarge, true),
            ("fr-repliee", Locale(identifier: "fr_FR"), .large, false),
        ]
        for (name, locale, size, expanded) in cases {
            let content = RadioLogSiteCard(
                site: site, state: .identified(siteId: "0381234"), siteName: "Grenoble · 12 rue Félix Poulat",
                isExpanded: expanded, onIdentify: {}, onOpenMap: {}
            )
            .padding(16)
            .frame(width: 390)
            .background(SQColor.bg)
            .environment(\.dynamicTypeSize, size)
            .environment(\.locale, locale)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 390, accuracy: 0.1)
            XCTAssertGreaterThan(image.size.height, 100)
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
        }
    }
}
