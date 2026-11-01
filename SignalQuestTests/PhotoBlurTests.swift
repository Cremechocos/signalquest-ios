import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import SignalQuest

/// Flou avant publication (plan 3, vague 1).
@MainActor
final class PhotoBlurTests: XCTestCase {
    /// Damier fin : un flou y change forcément les pixels.
    private func checkerboard(size: Int = 200, cell: Int = 4) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            for x in stride(from: 0, to: size, by: cell) {
                for y in stride(from: 0, to: size, by: cell) {
                    ((x / cell + y / cell) % 2 == 0 ? UIColor.black : UIColor.white).setFill()
                    context.fill(CGRect(x: x, y: y, width: cell, height: cell))
                }
            }
        }
    }

    private func pixels(_ image: UIImage) throws -> (bytes: [UInt8], width: Int) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width)
    }

    /// Écart moyen entre deux pixels voisins d'une ligne : fort sur le damier,
    /// presque nul une fois flouté.
    private func contrast(_ data: (bytes: [UInt8], width: Int), row: Int, from: Int, to: Int) -> Double {
        var total = 0.0
        for x in from..<(to - 1) {
            let a = Int(data.bytes[(row * data.width + x) * 4]), b = Int(data.bytes[(row * data.width + x + 1) * 4])
            total += Double(abs(a - b))
        }
        return total / Double(to - from - 1)
    }

    func testBlurChangesOnlyTheChosenArea() throws {
        let image = checkerboard()
        let blurred = PhotoBlur.render(image, regions: [CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)])
        let before = try pixels(image), after = try pixels(blurred)
        XCTAssertEqual(after.width, 200)
        // Coin haut gauche intact, centre de la zone floutée (hors coins arrondis) lissé.
        XCTAssertEqual(contrast(after, row: 20, from: 0, to: 80), contrast(before, row: 20, from: 0, to: 80), accuracy: 1)
        XCTAssertGreaterThan(contrast(before, row: 150, from: 120, to: 180), 40)
        XCTAssertLessThan(contrast(after, row: 150, from: 120, to: 180), 20, "Le damier doit être effacé dans la zone")
    }

    func testNoAreaLeavesThePhotoUntouched() {
        let image = checkerboard()
        XCTAssertTrue(PhotoBlur.render(image, regions: []) === image)
        XCTAssertTrue(PhotoBlur.render(image, regions: [CGRect(x: 2, y: 2, width: 1, height: 1)]) === image,
                      "Une zone hors de l'image ne floute rien")
    }

    func testGeometryIsClampedAndFacesGetAMargin() {
        let clamped = PhotoBlur.clamped(CGRect(x: -0.2, y: 0.9, width: 0.5, height: 0.5))
        XCTAssertEqual(clamped.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(clamped.maxX, 0.3, accuracy: 1e-9)
        XCTAssertEqual(clamped.maxY, 1, accuracy: 1e-9)
        let face = PhotoBlur.expanded(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), by: 0.3)
        XCTAssertEqual(face.width, 0.26, accuracy: 1e-9)
        XCTAssertEqual(face.midX, 0.5, accuracy: 1e-9)
    }

    func testNoFaceIsInventedOnAPlainImage() async {
        let faces = await PhotoBlur.detectFaces(in: checkerboard())
        XCTAssertTrue(faces.isEmpty)
    }

    func testEditorMapsTheDrawnAreaToTheImage() {
        let frame = PhotoBlurCanvas.fittedFrame(for: CGSize(width: 400, height: 200), in: CGSize(width: 300, height: 300))
        XCTAssertEqual(frame, CGRect(x: 0, y: 75, width: 300, height: 150))
        let rect = PhotoBlurCanvas.normalizedRect(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 75, y: 112.5), in: frame)
        XCTAssertEqual(rect.minX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 0.25, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 0.25, accuracy: 1e-9)
    }

    /// La croix se centre sur le coin haut-droit de la zone, sans sortir de
    /// l'éditeur.
    func testRemoveButtonSitsOnTheTopRightCornerInsideTheEditor() {
        let container = CGSize(width: 300, height: 300)
        let frame = PhotoBlurCanvas.fittedFrame(for: CGSize(width: 400, height: 200), in: container)
        let middle = PhotoBlurCanvas.removeButtonOrigin(
            for: CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25), in: frame, container: container
        )
        XCTAssertEqual(middle, CGPoint(x: 150 - 22, y: 75 + 75 - 22))

        let topRight = PhotoBlurCanvas.removeButtonOrigin(
            for: CGRect(x: 0.8, y: 0, width: 0.2, height: 0.2), in: frame, container: container
        )
        XCTAssertEqual(topRight, CGPoint(x: 300 - 44, y: 75 - 22), "Collée au bord droit, sans le dépasser")

        let tinyAtTheLeft = PhotoBlurCanvas.removeButtonOrigin(
            for: CGRect(x: 0, y: 0.1, width: 0.04, height: 0.1), in: CGRect(x: 0, y: 0, width: 300, height: 300), container: container
        )
        XCTAssertEqual(tinyAtTheLeft.x, 0, "Jamais à gauche de l'éditeur")
        XCTAssertEqual(tinyAtTheLeft.y, 8, accuracy: 1e-9)
    }

    /// Antennes : le flou part dans les pixels, la position et la date restent
    /// celles de l'original.
    func testUploadKeepsTheOriginalMetadataAndBlursThePixels() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 45.76, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 4.83, kCGImagePropertyGPSLongitudeRef: "E"
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(checkerboard().cgImage),
                                   [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let plain = try XCTUnwrap(PhotoUploadPreparation.prepare(from: data as Data))
        let blurred = try XCTUnwrap(PhotoUploadPreparation.prepare(
            from: data as Data, edits: PhotoEdits(blurRegions: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        ))
        let plainMetadata = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(plain.exifJSON).utf8)) as? NSDictionary
        let blurredMetadata = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(blurred.exifJSON).utf8)) as? NSDictionary
        XCTAssertEqual(blurredMetadata, plainMetadata)
        XCTAssertNotNil(blurredMetadata?["gpsLatitude"])
        let after = try pixels(try XCTUnwrap(UIImage(data: blurred.jpeg)))
        XCTAssertLessThan(contrast(after, row: 100, from: 60, to: 140), 20)
    }
}

/// Éditeur « Modifier » (E1) : géométrie du cadre et rendu non destructif.
@MainActor
final class PhotoEditorTests: XCTestCase {
    /// Moitié gauche rouge, moitié droite bleue, 40 × 20 px.
    private func halves() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            UIColor.blue.setFill(); context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        }
    }

    /// Composantes rouge et bleue du pixel (x, y).
    private func color(_ image: UIImage, x: Int, y: Int) throws -> (red: UInt8, blue: UInt8) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height))
        return (bytes[0], bytes[2])
    }

    func testUnchangedEditsReturnTheOriginal() {
        let image = halves()
        XCTAssertTrue(PhotoEdits().isIdentity)
        XCTAssertTrue(PhotoEditRenderer.render(image, edits: PhotoEdits()) === image)
    }

    /// Quart de tour à gauche : la moitié droite (bleue) monte en haut.
    func testRotateLeftTurnsThePixelsAndTheFrame() throws {
        var edits = PhotoEdits()
        edits.rotateLeft()
        let output = PhotoEditRenderer.render(halves(), edits: edits)
        let cg = try XCTUnwrap(output.cgImage)
        XCTAssertEqual(cg.width, 20)
        XCTAssertEqual(cg.height, 40)
        XCTAssertGreaterThan(try color(output, x: 10, y: 5).blue, 200, "le haut doit être bleu")
        XCTAssertGreaterThan(try color(output, x: 10, y: 35).red, 200, "le bas doit être rouge")

        let rect = CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.2)
        let turnedRect = PhotoEdits.rotatedLeft(rect)
        for (value, expected) in [(turnedRect.minX, 0.1), (turnedRect.minY, 0.1), (turnedRect.width, 0.2), (turnedRect.height, 0.3)] {
            XCTAssertEqual(value, expected, accuracy: 1e-9)
        }
        var turned = PhotoEdits(blurRegions: [rect])
        for _ in 0..<4 { turned.rotateLeft() }
        XCTAssertEqual(turned.quarterTurns, 0)
        XCTAssertEqual(turned.blurRegions[0].minX, rect.minX, accuracy: 1e-9)
        XCTAssertEqual(turned.blurRegions[0].height, rect.height, accuracy: 1e-9)
    }

    /// Cadre sur la moitié gauche : il ne reste que du rouge, à la bonne taille.
    func testCropKeepsOnlyTheFrame() throws {
        let edits = PhotoEdits(crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let output = PhotoEditRenderer.render(halves(), edits: edits)
        let cg = try XCTUnwrap(output.cgImage)
        XCTAssertEqual(cg.width, 20)
        XCTAssertEqual(cg.height, 20)
        XCTAssertGreaterThan(try color(output, x: 18, y: 10).red, 200)
        XCTAssertLessThan(try color(output, x: 18, y: 10).blue, 50)
    }

    /// Redresser agrandit juste assez pour qu'aucun coin ne reste vide.
    func testStraightenScaleCoversTheFrame() {
        XCTAssertEqual(PhotoEdits.straightenScale(for: CGSize(width: 100, height: 100), degrees: 0), 1)
        XCTAssertEqual(PhotoEdits.straightenScale(for: CGSize(width: 100, height: 100), degrees: 45), sqrt(2), accuracy: 1e-9)
        XCTAssertEqual(PhotoEdits.straightenScale(for: CGSize(width: 100, height: 100), degrees: -45), sqrt(2), accuracy: 1e-9)
    }

    func testLargestCropFollowsThePixelAspect() {
        let square = PhotoEdits.largestCrop(aspect: 1, in: CGSize(width: 400, height: 200))
        XCTAssertEqual(square, CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        let story = PhotoEdits.largestCrop(aspect: 9 / 16, in: CGSize(width: 900, height: 1600))
        XCTAssertEqual(story.width, 1, accuracy: 1e-9)
        XCTAssertEqual(story.height, 1, accuracy: 1e-9)
        let moved = PhotoEdits.largestCrop(aspect: 1, in: CGSize(width: 400, height: 200), centeredOn: CGPoint(x: 0.95, y: 0.5))
        XCTAssertEqual(moved.maxX, 1, accuracy: 1e-9, "le cadre reste dans la photo")
    }

    /// Tirer un coin garde le coin opposé et les proportions, sans sortir de la photo.
    func testCornerDragKeepsTheOppositeCornerAndTheAspect() {
        let start = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let free = PhotoEditorView.resized(start, corner: .bottomRight, to: CGPoint(x: 0.9, y: 0.7), aspect: nil)
        XCTAssertEqual(free.minX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(free.maxX, 0.9, accuracy: 1e-9)
        XCTAssertEqual(free.maxY, 0.7, accuracy: 1e-9)
        let square = PhotoEditorView.resized(start, corner: .topLeft, to: CGPoint(x: -0.5, y: 0.1), aspect: 1)
        XCTAssertEqual(square.maxX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(square.maxY, 0.6, accuracy: 1e-9)
        XCTAssertEqual(square.width, square.height, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(square.minX, 0)
        XCTAssertGreaterThanOrEqual(square.minY, 0)
        let zoomed = PhotoEditorView.zoomed(start, by: 2)
        XCTAssertEqual(zoomed.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(zoomed.midX, start.midX, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(PhotoEditorView.zoomed(start, by: 0.1).width, 1)
    }

    /// Les zones gardées dans la base se retrouvent à l'identique après un aller-retour par le cadre.
    func testBlurRegionsRoundTripThroughTheFrame() {
        let crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        let region = CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1)
        let back = PhotoEditorView.toBase(PhotoEditorView.toCrop(region, crop: crop), crop: crop)
        XCTAssertEqual(back.minX, region.minX, accuracy: 1e-9)
        XCTAssertEqual(back.width, region.width, accuracy: 1e-9)
    }

    /// À l'envoi, la borne de 1600 px vaut pour le cadre retenu, pas pour la photo entière.
    func testUploadAppliesTheFrameToTheOriginal() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let large = UIGraphicsImageRenderer(size: CGSize(width: 3200, height: 1600), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3200, height: 1600))
        }
        let data = try XCTUnwrap(large.jpegData(compressionQuality: 0.9))
        let prepared = try XCTUnwrap(PhotoUploadPreparation.prepare(
            from: data, edits: PhotoEdits(crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        ))
        let output = try XCTUnwrap(UIImage(data: prepared.jpeg)?.cgImage)
        XCTAssertEqual(output.width, 1600)
        XCTAssertEqual(output.height, 1600)
    }
}
