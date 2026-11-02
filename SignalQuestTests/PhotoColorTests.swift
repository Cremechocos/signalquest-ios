import XCTest
@testable import SignalQuest

/// Filtres et réglages (E2). Les pixels témoins font référence pour le web et
/// Android : une même entrée doit donner la même sortie partout.
final class PhotoColorTests: XCTestCase {
    private let witness = (0.8, 0.5, 0.2, 1.0)

    private func assertPixel(_ actual: (Double, Double, Double, Double), _ expected: (Double, Double, Double, Double),
                             accuracy: Double = 1e-6, _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(actual.0, expected.0, accuracy: accuracy, "R \(message)", line: line)
        XCTAssertEqual(actual.1, expected.1, accuracy: accuracy, "G \(message)", line: line)
        XCTAssertEqual(actual.2, expected.2, accuracy: accuracy, "B \(message)", line: line)
        XCTAssertEqual(actual.3, expected.3, accuracy: accuracy, "A \(message)", line: line)
    }

    func testWitnessPixelOfEachFilter() {
        let expected: [PhotoFilter: (Double, Double, Double, Double)] = [
            .none: (0.8, 0.5, 0.2, 1),
            .vivid: (0.929284, 0.483784, 0.038284, 1),
            .warm: (0.864, 0.5, 0.176, 1),
            .cool: (0.72, 0.5, 0.22, 1),
            .soft: (0.75116, 0.54716, 0.34316, 1),
            .mono: (0.54212, 0.54212, 0.54212, 1),
            .noir: (0.556862, 0.556862, 0.556862, 1),
        ]
        for filter in PhotoFilter.allCases {
            assertPixel(filter.matrix.apply(witness), expected[filter]!, filter.rawValue)
        }
    }

    func testOutputIsClampedToTheUnitRange() {
        let out = PhotoFilter.vivid.matrix.apply((1, 0, 0, 1))
        XCTAssertEqual(out.0, 1)
        XCTAssertEqual(out.1, 0)
    }

    func testCompositionAppliesTheFirstMatrixFirst() {
        let composed = PhotoColorMatrix.contrast(1.5).then(.offset(0.1))
        let stepwise = PhotoColorMatrix.offset(0.1).apply(PhotoColorMatrix.contrast(1.5).apply(witness))
        assertPixel(composed.apply(witness), stepwise)
        // L'ordre compte : le décalage avant le contraste est amplifié.
        let reversed = PhotoColorMatrix.offset(0.1).then(.contrast(1.5)).apply(witness)
        XCTAssertNotEqual(reversed.2, stepwise.2, accuracy: 1e-3)
    }

    func testStrengthBlendsWithTheIdentity() {
        XCTAssertEqual(PhotoFilter.mono.matrix.strength(0), .identity)
        XCTAssertEqual(PhotoFilter.mono.matrix.strength(1), PhotoFilter.mono.matrix)
        let half = PhotoFilter.mono.matrix.strength(0.5).apply(witness)
        XCTAssertEqual(half.0, (0.8 + 0.54212) / 2, accuracy: 1e-9)
    }

    func testUntouchedEditsKeepTheExactIdentity() {
        var edits = PhotoEdits()
        XCTAssertFalse(edits.hasColorChanges)
        XCTAssertEqual(edits.colorMatrix, .identity)
        XCTAssertTrue(edits.isIdentity)
        edits.filter = .warm
        edits.filterStrength = 0
        XCTAssertFalse(edits.hasColorChanges, "Un filtre à 0 % ne change rien")
        edits.adjustments.brightness = 0.5
        XCTAssertTrue(edits.hasColorChanges)
        XCTAssertFalse(edits.isIdentity)
    }

    func testAdjustmentsFollowTheirFixedOrder() {
        var adjustments = PhotoAdjustments()
        adjustments.brightness = 1
        assertPixel(adjustments.matrix.apply(witness), (1, 0.7, 0.4, 1))
        adjustments = PhotoAdjustments()
        adjustments[.contrast] = 2 // borné à 1 : contraste × 1,5
        XCTAssertEqual(adjustments.contrast, 1)
        assertPixel(adjustments.matrix.apply(witness), (0.95, 0.5, 0.05, 1))
        adjustments = PhotoAdjustments()
        adjustments.warmth = 1
        assertPixel(adjustments.matrix.apply(witness), (0.88, 0.5, 0.18, 1))
        adjustments = PhotoAdjustments()
        adjustments.saturation = -1
        assertPixel(adjustments.matrix.apply(witness), PhotoFilter.mono.matrix.apply(witness))
    }

    /// Les pixels rendus suivent la matrice appliquée aux valeurs sRGB gamma, comme le web.
    func testRenderedPixelsMatchTheMatrixInGammaSpace() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        for filter in PhotoFilter.allCases where filter != .none {
            let rendered = PhotoColor.render(source, matrix: filter.matrix)
            let pixel = try rgba(rendered)
            let expected = filter.matrix.apply(witness)
            assertPixel(pixel, expected, accuracy: 2.0 / 255, filter.rawValue)
        }
    }

    func testRendererBakesTheColorIntoTheUpload() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        var edits = PhotoEdits()
        edits.filter = .mono
        let pixel = try rgba(PhotoEditRenderer.render(source, edits: edits))
        XCTAssertEqual(pixel.0, pixel.1, accuracy: 2.0 / 255)
        XCTAssertEqual(pixel.1, pixel.2, accuracy: 2.0 / 255)
        XCTAssertEqual(pixel.0, 0.54212, accuracy: 2.0 / 255)
    }

    /// Pixel central, lu en sRGB 8 bits.
    private func rgba(_ image: UIImage) throws -> (Double, Double, Double, Double) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let x = cgImage.width / 2, y = cgImage.height / 2
        context.draw(cgImage, in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height))
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255, Double(bytes[3]) / 255)
    }
}
