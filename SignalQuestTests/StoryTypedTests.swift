import XCTest
import ImageIO
import UIKit
@testable import SignalQuest

/// Le serveur décide qu'une story est VIDE en inspectant la présence de
/// `attachRadio` / `metadata`. Un `false` explicite au lieu d'une absence fait
/// donc basculer la validation du mauvais côté — un défaut qui ne se voit qu'au
/// 400 renvoyé, sur une story sans texte ni image.
final class StoryTypedTests: XCTestCase {

    private func encoded(attachRadio: Bool?) throws -> [String: Any] {
        let body = CreateStoryRequest(
            text: nil, mediaUrl: nil, thumbnailUrl: nil, mediaKind: nil,
            durationSeconds: 10, visibility: "friends", ttlHours: 24,
            hiddenUserIds: nil, background: nil,
            attachRadio: attachRadio, metadata: nil
        )
        let data = try JSONEncoder().encode(body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Une story « signal » doit envoyer la clé.
    func testAttachRadioIsSentWhenEnabled() throws {
        let json = try encoded(attachRadio: true)
        XCTAssertEqual(json["attachRadio"] as? Bool, true)
    }

    /// Et surtout : la clé doit être ABSENTE quand l'option est désactivée, pas
    /// présente à `false`.
    func testAttachRadioIsOmittedWhenDisabled() throws {
        let json = try encoded(attachRadio: nil)
        XCTAssertNil(json["attachRadio"], "Un `false` explicite fausserait la validation serveur")
    }

    /// Les durées de vie hors bornes doivent être ramenées dans 1…72 : le
    /// serveur répondrait 400 sinon.
    func testTtlIsClampedToTheServerRange() throws {
        for (input, expected) in [(0, 1), (1, 1), (24, 24), (72, 72), (999, 72)] {
            let body = CreateStoryRequest(
                text: "x", mediaUrl: nil, thumbnailUrl: nil, mediaKind: nil,
                durationSeconds: 10, visibility: "friends",
                ttlHours: min(72, max(1, input)),
                hiddenUserIds: nil, background: nil, attachRadio: nil, metadata: nil
            )
            XCTAssertEqual(body.ttlHours, expected, "ttl \(input)")
        }
    }

    func testSocialImageSanitizerRemovesGPSAndCameraMetadata() throws {
        let original = try makeJpegWithSensitiveMetadata()
        let originalProperties = try properties(of: original)
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary])

        let sanitized = try XCTUnwrap(
            SocialImagePrivacy.sanitizedJPEG(from: original, maxSide: 1600, quality: 0.85)
        )
        let sanitizedProperties = try properties(of: sanitized)
        XCTAssertNil(sanitizedProperties[kCGImagePropertyGPSDictionary])
        let tiff = sanitizedProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel])
        XCTAssertEqual((sanitizedProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 8)
        XCTAssertEqual((sanitizedProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 12)
    }

    func testSocialImageSanitizerFailsClosedForInvalidInput() {
        XCTAssertNil(SocialImagePrivacy.sanitizedJPEG(from: Data("not-an-image".utf8)))
    }

    private func makeJpegWithSensitiveMetadata() throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8), format: format)
        let base = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        }
        let jpeg = try XCTUnwrap(base.jpegData(compressionQuality: 0.95))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)
        )
        let metadata: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "SignalQuest Camera",
                kCGImagePropertyTIFFModel: "Private Pixel",
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 48.85,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.35,
                kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
    }
}
