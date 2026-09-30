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
        let frame = PhotoBlurEditor.fittedFrame(for: CGSize(width: 400, height: 200), in: CGSize(width: 300, height: 300))
        XCTAssertEqual(frame, CGRect(x: 0, y: 75, width: 300, height: 150))
        let rect = PhotoBlurEditor.normalizedRect(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 75, y: 112.5), in: frame)
        XCTAssertEqual(rect.minX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 0.25, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 0.25, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 0.25, accuracy: 1e-9)
    }

    /// La croix se centre sur le coin haut-droit de la zone, sans sortir de
    /// l'éditeur.
    func testRemoveButtonSitsOnTheTopRightCornerInsideTheEditor() {
        let container = CGSize(width: 300, height: 300)
        let frame = PhotoBlurEditor.fittedFrame(for: CGSize(width: 400, height: 200), in: container)
        let middle = PhotoBlurEditor.removeButtonOrigin(
            for: CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25), in: frame, container: container
        )
        XCTAssertEqual(middle, CGPoint(x: 150 - 22, y: 75 + 75 - 22))

        let topRight = PhotoBlurEditor.removeButtonOrigin(
            for: CGRect(x: 0.8, y: 0, width: 0.2, height: 0.2), in: frame, container: container
        )
        XCTAssertEqual(topRight, CGPoint(x: 300 - 44, y: 75 - 22), "Collée au bord droit, sans le dépasser")

        let tinyAtTheLeft = PhotoBlurEditor.removeButtonOrigin(
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
            from: data as Data, blurRegions: [CGRect(x: 0, y: 0, width: 1, height: 1)]
        ))
        let plainMetadata = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(plain.exifJSON).utf8)) as? NSDictionary
        let blurredMetadata = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(blurred.exifJSON).utf8)) as? NSDictionary
        XCTAssertEqual(blurredMetadata, plainMetadata)
        XCTAssertNotNil(blurredMetadata?["gpsLatitude"])
        let after = try pixels(try XCTUnwrap(UIImage(data: blurred.jpeg)))
        XCTAssertLessThan(contrast(after, row: 100, from: 60, to: 140), 20)
    }
}
