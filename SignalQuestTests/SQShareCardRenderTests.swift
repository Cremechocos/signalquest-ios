import UIKit
import XCTest
@testable import SignalQuest

/// Rendu de l'image de partage A.
///
/// Un rendu ne se prouve pas par des assertions : il se regarde. Ces tests
/// reproduisent donc les deux références validées le 19/10 (A-ios.png et
/// A-sans-courbe-ni-radio.png, mêmes valeurs et mêmes courbes) en pièces jointes,
/// et vérifient ce qu'un coup d'œil rate — dimensions exactes, fond papier,
/// absence de repli de police.
final class SQShareCardRenderTests: XCTestCase {

    /// Courbes de la référence v11, normalisées sur leur maximum : 50 fenêtres de
    /// 0,2 s, la première placée à son temps et non à zéro.
    private static let downloadShape: [Double] = [
        0.297, 0.494, 0.638, 0.718, 0.784, 0.863, 0.851, 0.834, 0.831, 0.823, 0.885, 0.899, 0.878,
        0.909, 0.918, 0.968, 1.0, 0.944, 0.929, 0.914, 0.903, 0.928, 0.872, 0.842, 0.87, 0.883,
        0.941, 0.948, 0.915, 0.952, 0.962, 0.973, 0.97, 0.891, 0.878, 0.889, 0.881, 0.902, 0.866,
        0.862, 0.926, 0.948, 0.977, 0.966, 0.921, 0.952, 0.952, 0.925, 0.906, 0.842,
    ]
    private static let uploadShape: [Double] = [
        0.215, 0.37, 0.507, 0.599, 0.679, 0.717, 0.706, 0.756, 0.8, 0.836, 0.881, 0.862, 0.895,
        0.954, 0.962, 0.977, 0.933, 0.894, 0.925, 0.91, 0.898, 0.882, 0.846, 0.902, 0.945, 0.949,
        0.968, 0.94, 0.958, 1.0, 0.962, 0.937, 0.894, 0.866, 0.914, 0.905, 0.887, 0.901, 0.898,
        0.964, 0.999, 0.966, 0.966, 0.94, 0.944, 0.966, 0.906, 0.875, 0.87, 0.872,
    ]
    private static let windowTimes: [Double] = (1...50).map { Double($0) / 50 }

    private func sample(curves: Bool = true) -> SQShareCardModel {
        SQShareCardModel(
            dateText: "19 octobre 2026 à 14:32",
            network: .init(name: "SFR", detail: "5G", barColor: UIColor(hex: 0xE60012)),
            download: .init(number: "1,722", unit: "Gb/s"),
            downloadPeakText: curves ? nil : "MAX 1,841 Gb/s",
            downloadGraph: curves
                ? .init(points: Self.downloadShape.map { $0 * 1_722 }, localMax: 1_841,
                        accentColor: UIColor(hex: 0x1C201E), normalizedTimes: Self.windowTimes, durationSeconds: 10,
                        maxText: "MAX 1,841 Gb/s", maxValue: 1_841)
                : nil,
            upload: .init(number: "84", unit: "Mb/s"),
            uploadPeakText: curves ? nil : "MAX 97 Mb/s",
            uploadGraph: curves
                ? .init(points: Self.uploadShape.map { $0 * 90 }, localMax: 97,
                        accentColor: UIColor(hex: 0xA8123A), normalizedTimes: Self.windowTimes, durationSeconds: 10,
                        maxText: "MAX 97 Mb/s", maxValue: 97)
                : nil,
            latencyLabel: "Latence min.",
            latency: .init(number: "14", unit: "ms"),
            latencyAverageText: "Moyenne 18 ms",
            rows: [
                .init(label: "Sous charge", value: "38 ms · gigue 6,2 ms", grade: .init(
                    letter: "B", color: UIColor(hex: 0x477818),
                    background: UIColor(hex: 0x7DB834, alpha: 0.16)
                ), arrow: .down),
                .init(label: "Sous charge", value: "31 ms · gigue 11 ms", arrow: .up),
                .init(label: "Gigue au repos", value: "3,2 ms"),
                .init(label: "Serveur", value: "Roubaix (OVH RBX)"),
            ],
            deviceCityText: "iPhone 17 Pro · Grenoble"
        )
    }

    private func attach(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Les deux références. Elles sont à REGARDER côte à côte avec les PNG validés.
    func testRendersTheTwoReferences() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded, "Polices absentes — la carte serait composée en Helvetica")
        for (curves, name) in [(true, "A-ios"), (false, "A-sans-courbe-ni-radio")] {
            let image = SQShareCardRenderer.render(sample(curves: curves))
            attach(image, name)
            XCTAssertEqual(image.size.width, 2_400, accuracy: 0.5, "Largeur d'export inattendue (\(name))")
            XCTAssertEqual(image.size.height, 1_260, accuracy: 0.5, "Hauteur d'export inattendue (\(name))")
            // Hors bac à sable, l'hôte récupère l'image pour la comparer au pixel.
            try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/sq-share-\(name).png"))
        }
    }

    /// Fond papier #F4F2EC et cartouche blanche, quel que soit le thème de l'app.
    func testPaperAndCardColors() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        let image = SQShareCardRenderer.render(sample())
        let corner = try XCTUnwrap(image.pixelColor(at: CGPoint(x: 4, y: 4)))
        XCTAssertEqual(corner.red, 0xF4 / 255, accuracy: 0.01)
        XCTAssertEqual(corner.green, 0xF2 / 255, accuracy: 0.01)
        XCTAssertEqual(corner.blue, 0xEC / 255, accuracy: 0.01)
        // Intérieur de la cartouche, entre l'opérateur et la rubrique.
        let card = try XCTUnwrap(image.pixelColor(at: CGPoint(x: 1_000, y: 330)))
        XCTAssertEqual(card.red + card.green + card.blue, 3, accuracy: 0.02)
    }

    /// L'échelle de qualité doit rester monotone : un débit plus élevé ne peut pas
    /// produire une couleur « moins bonne ».
    func testQualityScaleIsMonotonic() {
        let theme = SQShareCardTheme.light
        let colors = stride(from: 0.0, through: 1.0, by: 0.25).map { theme.qualityColor(ratio: $0) }
        XCTAssertEqual(Set(colors.map { $0.description }).count, colors.count, "Deux paliers rendent la même couleur")
        XCTAssertEqual(theme.qualityColor(ratio: -5), theme.speedPalette.first)
        XCTAssertEqual(theme.qualityColor(ratio: 42), theme.speedPalette.last)
        XCTAssertEqual(theme.qualityColor(ratio: .nan), theme.speedPalette.first, "Un ratio non fini doit rester dessinable")
    }

    /// Une valeur très large doit rétrécir, jamais déborder de sa colonne.
    func testOversizedValuesStillRender() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        let base = sample()
        let model = SQShareCardModel(
            dateText: base.dateText, network: .init(name: "Bouygues Telecom", detail: "5G", barColor: UIColor(hex: 0x009DDC)),
            download: .init(number: "12,409", unit: "Gb/s"), downloadPeakText: base.downloadPeakText,
            downloadGraph: base.downloadGraph, upload: .init(number: "2,481", unit: "Gb/s"),
            // Durées différentes : une durée sous chaque courbe.
            uploadPeakText: nil, uploadGraph: base.uploadGraph.map { graph in
                var graph = graph; graph.durationSeconds = 13; graph.maxText = "MAX 2,512 Gb/s"; return graph
            }, latencyLabel: base.latencyLabel,
            latency: .init(number: "1234", unit: "ms"), latencyAverageText: "Moyenne 1456 ms",
            rows: base.rows.dropLast() + [.init(label: "Serveur", value: "Un nom de serveur beaucoup trop long pour la colonne")],
            deviceCityText: base.deviceCityText
        )
        let image = SQShareCardRenderer.render(model)
        attach(image, "A-valeurs-larges")
        try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/sq-share-A-valeurs-larges.png"))
        XCTAssertEqual(image.size.width, 2_400, accuracy: 0.5)
    }

    /// Tout ce qui est facultatif absent : la carte reste dessinable, sans tiret.
    func testMinimalCardStillRenders() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        let model = SQShareCardModel(
            dateText: nil, network: nil, download: .init(number: "8,4", unit: "Mb/s"),
            downloadPeakText: nil, downloadGraph: .init(points: [], localMax: 0, accentColor: .black),
            upload: nil, uploadPeakText: nil, uploadGraph: nil, latencyLabel: "Latence", latency: nil,
            latencyAverageText: nil, rows: [], deviceCityText: ""
        )
        let image = SQShareCardRenderer.render(model)
        attach(image, "A-minimale")
        XCTAssertEqual(image.size.height, 1_260, accuracy: 0.5)
    }
}

private extension UIImage {
    /// Couleur d'un pixel, pour vérifier un fond sans se fier à l'œil.
    func pixelColor(at point: CGPoint) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard let cg = cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cg, in: CGRect(x: -point.x, y: -(CGFloat(cg.height) - point.y - 1), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }
}
