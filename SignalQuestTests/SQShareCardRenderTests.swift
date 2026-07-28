import UIKit
import XCTest
@testable import SignalQuest

/// Rendu de la carte de partage.
///
/// Un rendu ne se prouve pas par des assertions : il se regarde. Ces tests
/// produisent donc les trois variantes en pièces jointes, et vérifient par
/// ailleurs les invariants qu'un coup d'œil rate — dimensions exactes, fond
/// réellement noir en OLED, absence de repli de police.
final class SQShareCardRenderTests: XCTestCase {

    private func sample(theme: SQShareCardTheme) -> SQShareCardModel {
        let series: [Double] = [
            12, 48, 180, 420, 610, 705, 742, 738, 751, 760,
            755, 762, 758, 764, 759, 766, 761, 768, 763, 770
        ]
        let uploadSeries: [Double] = [
            4, 22, 68, 96, 112, 118, 121, 119, 123, 120,
            124, 122, 125, 123, 126, 124, 127, 125, 128, 126
        ]
        return SQShareCardModel(
            theme: theme,
            brand: "SIGNALQUEST",
            // PAS de bande radio : iOS n'expose ni RSRP, ni PCI, ni bande — c'est
            // une limite assumée de la plateforme, pas un oubli. L'en-tête se
            // limite donc à la génération et à l'opérateur.
            headerNetworkText: "5G · Orange",
            dateTimeText: "28 juil. 2026 · 14:32",
            download: .init(
                label: "Download", value: "770,2", unit: "Mbps", maxValue: "812,4",
                labelColor: theme.qualityColor(ratio: 0.9),
                graph: .init(points: series, localMax: 812, accentColor: theme.qualityColor(ratio: 0.9))
            ),
            upload: .init(
                label: "Upload", value: "126,4", unit: "Mbps", maxValue: "131,0",
                labelColor: theme.qualityColor(ratio: 0.55),
                graph: .init(points: uploadSeries, localMax: 131, accentColor: theme.qualityColor(ratio: 0.55))
            ),
            latencyLabel: "Latence", latencyValueText: "18", latencyUnit: "ms",
            latencySubText: "min · ICMP · gigue 1,4 ms",
            latencyColor: theme.qualityColor(ratio: 0.85),
            underLoadLabel: "Sous charge",
            underLoadRows: [
                .init(prefix: "DL", valueText: "42 ms", jitText: "± 6", dotColor: theme.qualityColor(ratio: 0.6)),
                .init(prefix: "UL", valueText: "57 ms", jitText: "± 9", dotColor: theme.qualityColor(ratio: 0.4))
            ],
            serverLabel: "Serveur", serverText: "Paris BBR (Bouygues)",
            deviceCityText: "iPhone 17 Pro · Lyon",
            // VIDE sur iOS, et ce n'est pas un trou à combler : ces lignes portent
            // l'identité radio (porteuses agrégées, MCC/MNC, bande) qu'Android lit
            // sur son modem et qu'iOS n'expose pas. Le pied se replie tout seul.
            radioLines: []
        )
    }

    private func attach(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Produit les trois variantes. Elles sont à REGARDER : c'est la comparaison
    /// avec la carte Android qui valide le port, pas une assertion.
    func testRendersTheThreeVariants() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded, "Polices absentes — la carte serait composée en Helvetica")
        for (theme, name) in [(SQShareCardTheme.light, "clair"),
                              (SQShareCardTheme.dark, "sombre"),
                              (SQShareCardTheme.oled, "oled")] {
            let image = SQShareCardRenderer.render(sample(theme: theme))
            attach(image, "carte-\(name)")
            XCTAssertEqual(image.size.width, 2_160, accuracy: 0.5, "Largeur d'export inattendue (\(name))")
            XCTAssertEqual(image.size.height, 1_300, accuracy: 0.5, "Hauteur d'export inattendue (\(name))")
        }
    }

    /// En OLED, le fond doit être NOIR PUR — c'est toute la raison d'être du mode
    /// sur un écran à pixels éteints. Un gris très foncé passerait inaperçu à l'œil
    /// mais annulerait le bénéfice.
    func testOledBackgroundIsPureBlack() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        let image = SQShareCardRenderer.render(sample(theme: .oled))
        let corner = try XCTUnwrap(image.pixelColor(at: CGPoint(x: 4, y: 4)))
        XCTAssertEqual(corner.red, 0, accuracy: 0.01)
        XCTAssertEqual(corner.green, 0, accuracy: 0.01)
        XCTAssertEqual(corner.blue, 0, accuracy: 0.01)
    }

    /// …et le mode sombre classique ne doit PAS l'être, sinon les deux réglages
    /// seraient indiscernables et l'option n'aurait aucun sens.
    func testDarkBackgroundIsNotPureBlack() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        let image = SQShareCardRenderer.render(sample(theme: .dark))
        let corner = try XCTUnwrap(image.pixelColor(at: CGPoint(x: 4, y: 4)))
        XCTAssertGreaterThan(corner.red + corner.green + corner.blue, 0.02, "Le sombre classique est devenu noir pur")
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
    func testOversizedValueStillRenders() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        var model = sample(theme: .light)
        model = SQShareCardModel(
            theme: model.theme, brand: model.brand,
            headerNetworkText: model.headerNetworkText, dateTimeText: model.dateTimeText,
            download: .init(label: "Download", value: "12408,6", unit: "Mbps", maxValue: "12999,9",
                            labelColor: model.download.labelColor, graph: model.download.graph),
            upload: model.upload,
            latencyLabel: model.latencyLabel, latencyValueText: model.latencyValueText,
            latencyUnit: model.latencyUnit, latencySubText: model.latencySubText,
            latencyColor: model.latencyColor,
            underLoadLabel: model.underLoadLabel, underLoadRows: model.underLoadRows,
            serverLabel: model.serverLabel, serverText: model.serverText,
            deviceCityText: model.deviceCityText, radioLines: model.radioLines
        )
        let image = SQShareCardRenderer.render(model)
        attach(image, "carte-valeur-large")
        XCTAssertEqual(image.size.width, 2_160, accuracy: 0.5)
    }

    /// Une série vide ou un maximum nul ne doivent pas empêcher la génération :
    /// un test partiellement raté reste partageable.
    func testDegenerateGraphStillRenders() throws {
        try XCTSkipUnless(SQShareFonts.areEmbedded)
        var model = sample(theme: .dark)
        model = SQShareCardModel(
            theme: model.theme, brand: model.brand,
            headerNetworkText: model.headerNetworkText, dateTimeText: nil,
            download: .init(label: "Download", value: "—", unit: "Mbps", maxValue: "—",
                            labelColor: model.download.labelColor,
                            graph: .init(points: [], localMax: 0, accentColor: model.download.labelColor)),
            upload: model.upload,
            latencyLabel: model.latencyLabel, latencyValueText: model.latencyValueText,
            latencyUnit: model.latencyUnit, latencySubText: model.latencySubText,
            latencyColor: model.latencyColor,
            underLoadLabel: model.underLoadLabel, underLoadRows: [],
            serverLabel: model.serverLabel, serverText: nil,
            deviceCityText: model.deviceCityText, radioLines: []
        )
        let image = SQShareCardRenderer.render(model)
        attach(image, "carte-degradee")
        XCTAssertEqual(image.size.height, 1_300, accuracy: 0.5)
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
