import SwiftUI
import XCTest
@testable import SignalQuest

/// TRX-11 (plan 3, lot 11) : la tuile de mesure partagée, dans les grilles des
/// écrans qui l'utilisent (stats d'un trajet, mesure d'un drive test, fiche
/// antenne), en français et en anglais, en taille normale et agrandie, pour
/// une relecture visuelle (`build/qa/metric-tile`). Le détail d'un trajet n'a
/// pas de données de démonstration : ce rendu est sa seule vue hors compte réel.
@MainActor
final class SQMetricTileRenderingTests: XCTestCase {
    private struct Grid: View {
        @State private var selection: AntennaGlossaryEntry?
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm), count: 2), spacing: SQSpace.sm) {
                        SQMetricTile(label: "Points", value: "1 284", icon: "mappin.and.ellipse", iconTint: SQColor.brandRed)
                        SQMetricTile(label: "Distance", value: "42,7 km", icon: "ruler", iconTint: SQColor.brandRed)
                        SQMetricTile(label: "RSRP moyen", value: "−94 dBm", icon: "antenna.radiowaves.left.and.right", iconTint: SQColor.brandRed)
                        SQMetricTile(label: "Durée", value: "1 h 12 min", icon: "clock", iconTint: SQColor.brandRed)
                    }
                }
                // Comme la rangée d'un trajet : trois colonnes, puis une seule à partir de .xxLarge.
                let speeds = Group {
                    SQMetricTile(label: "Réception moy.", value: "187", unit: "Mbit/s", icon: "arrow.down",
                                 iconTint: Color(uiColor: SessionSpeedColor.ui(187)), fillsHeight: true)
                    SQMetricTile(label: "Envoi moy.", value: "38", unit: "Mbit/s", icon: "arrow.up", iconTint: SQColor.success,
                                 fillsHeight: true)
                    SQMetricTile(label: "Latence moy.", value: "24", unit: "ms", icon: "bolt.horizontal", iconTint: SQColor.warning,
                                 fillsHeight: true)
                }
                if dynamicTypeSize >= .xxLarge {
                    VStack(spacing: SQSpace.sm) { speeds }
                } else {
                    HStack(alignment: .top, spacing: SQSpace.sm) { speeds }
                        .fixedSize(horizontal: false, vertical: true)
                }
                GlassCard {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: SQSpace.sm) {
                        SQMetricTile(label: "Réception", value: "212", unit: "Mbit/s", icon: "arrow.down",
                                     iconTint: Color(uiColor: SessionSpeedColor.ui(212)), detail: "max 287 Mbit/s", size: .large)
                        SQMetricTile(label: "Latence", value: "19", unit: "ms", term: .latency, icon: "bolt.horizontal",
                                     iconTint: SQColor.warning, detail: "min 14 · max 31", size: .large)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: SQSpace.sm) {
                    AntennaMetricTile(label: "Hauteur", value: "32 m", entry: AntennaGlossary.distance(1_250), selection: $selection)
                    AntennaMetricTile(label: "Azimut", value: "120°", highlight: true, entry: AntennaGlossary.distance(1_250), selection: $selection)
                }
            }
        }
    }

    func testSharedTilesRenderInFrenchAndEnglish() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = repository.appendingPathComponent("build/qa/metric-tile")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cases: [(String, Locale, DynamicTypeSize)] = [
            ("fr", Locale(identifier: "fr_FR"), .large),
            ("en", Locale(identifier: "en_US"), .large),
            ("fr-xxl", Locale(identifier: "fr_FR"), .xxxLarge),
        ]
        for (name, locale, size) in cases {
            let content = Grid()
                .padding(16)
                .frame(width: 390)
                .background(SQColor.bg)
                .environment(\.dynamicTypeSize, size)
                .environment(\.locale, locale)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, 390, accuracy: 0.1)
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
        }
    }
}
