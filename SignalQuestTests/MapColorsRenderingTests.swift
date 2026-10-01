import MapKit
import SwiftUI
import XCTest
@testable import SignalQuest

/// Contrat quality-scale v1 : légende de la couverture (niveaux, « sans réseau
/// constaté » hachuré, générations) et pastilles de la carte, rendues pour une
/// relecture visuelle (`build/qa/map-colors`).
@MainActor
final class MapColorsRenderingTests: XCTestCase {
    private var output: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/qa/map-colors")
    }

    private struct Legend: View {
        var body: some View {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    ForEach(CoverageQualityBand.visibleBands) { band in
                        entry(band.title, band.swiftUIColor, hatched: band.isHatched)
                    }
                    entry(CoverageQualityBand.unknown.title, CoverageQualityBand.unknown.swiftUIColor, hatched: false)
                }
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    ForEach(CoverageGenerationBand.visibleBands) { band in
                        entry(band.title, band.swiftUIColor, hatched: false)
                    }
                }
            }
            .padding(20)
            .background(SQColor.surface)
        }

        private func entry(_ title: String, _ color: Color, hatched: Bool) -> some View {
            HStack(spacing: SQSpace.md) {
                Group {
                    if hatched {
                        SQHatchedSwatch(color: color).clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        RoundedRectangle(cornerRadius: 3).fill(color)
                    }
                }
                .frame(width: 24, height: 8)
                Text(title).font(SQType.subhead).foregroundStyle(SQColor.label)
            }
        }
    }

    func testTheLegendRendersTheContractColors() throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, scheme) in [("legende-clair", ColorScheme.light), ("legende-sombre", ColorScheme.dark)] {
            let renderer = ImageRenderer(content: Legend().environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    /// Pastilles de la carte, telles que le moteur les dessine, à plusieurs tailles.
    func testDotsRenderPlainAndHatched() throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bands = CoverageQualityBand.visibleBands
        let size = CGSize(width: 60 + CGFloat(bands.count) * 40, height: 140)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.96, green: 0.94, blue: 0.9, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (row, radius) in [CGFloat(4.6), 9, 18].enumerated() {
                for (column, band) in bands.enumerated() {
                    let center = CGPoint(x: 40 + CGFloat(column) * 40, y: 25 + CGFloat(row) * 42)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    let color = SQNetworkColors.uiColor(band.colorHex).withAlphaComponent(0.78).cgColor
                    if band.isHatched {
                        SQMapKitDotsRenderer.drawHatched(color, in: rect, context: context.cgContext)
                    } else {
                        context.cgContext.setFillColor(color)
                        context.cgContext.fillEllipse(in: rect)
                    }
                }
            }
        }
        try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("pastilles.png"))
    }
}
