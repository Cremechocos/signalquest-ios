import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SignalQuest

/// Une pièce jointe ne doit jamais trahir où elle a été prise : GPS d'une image,
/// atomes de lieu QuickTime d'une vidéo (révision 17 du chiffrement, et en clair).
final class MediaLocationStripperTests: XCTestCase {
    private var geotaggedMovie: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/geotagged.mov")
    }

    private func locationItems(_ url: URL) async throws -> [AVMetadataItem] {
        let asset = AVURLAsset(url: url)
        var items = try await asset.load(.metadata)
        for format in try await asset.load(.availableMetadataFormats) {
            items += try await asset.loadMetadata(for: format)
        }
        return items.filter { item in
            item.commonKey == .commonKeyLocation
                || (item.identifier?.rawValue.lowercased().contains("location") ?? false)
                || (item.identifier?.rawValue.contains("xyz") ?? false)
        }
    }

    /// `©xyz` (udta) et `com.apple.quicktime.location.ISO6709` (mdta, celui de l'appareil photo).
    func testMovieLosesItsLocationButKeepsItsVideo() async throws {
        for movie in [geotaggedMovie, geotaggedMovie.deletingLastPathComponent().appendingPathComponent("geotagged-mdta.mov")] {
            try await assertLocationRemoved(from: movie)
        }
    }

    private func assertLocationRemoved(from movie: URL) async throws {
        // La preuve porte sur les octets : un filtre qui n'expose plus une métadonnée
        // ne garantit pas qu'elle a quitté le conteneur.
        XCTAssertTrue(String(decoding: try Data(contentsOf: movie), as: UTF8.self).contains("48.8566"),
                      "La vidéo de test doit porter un lieu")

        let clean = try await MediaLocationStripper.strippedMovie(at: movie)
        defer { try? FileManager.default.removeItem(at: clean) }
        let after = try await locationItems(clean)
        XCTAssertTrue(after.isEmpty, "Lieu encore présent : \(after.compactMap { $0.identifier?.rawValue })")
        XCTAssertFalse(String(decoding: try Data(contentsOf: clean), as: UTF8.self).contains("48.8566"))

        let tracks = try await AVURLAsset(url: clean).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    private func geotaggedJPEG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 48.8566, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.3522, kCGImagePropertyGPSLongitudeRef: "E",
        ]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testImageLosesItsGPSButKeepsItsPixels() throws {
        let original = try geotaggedJPEG()
        XCTAssertTrue(MediaLocationStripper.hasLocation(original))

        let clean = try XCTUnwrap(MediaLocationStripper.strippedImage(original))
        XCTAssertFalse(MediaLocationStripper.hasLocation(clean))
        // Dans les octets : plus de pointeur vers le répertoire GPS (tag EXIF 0x8825).
        let exif = try XCTUnwrap(app1(of: original))
        XCTAssertTrue(exif.contains(gpsPointer(bigEndian: exif.starts(with: Data("Exif\0\0MM".utf8)))))
        if let cleanExif = app1(of: clean) {
            XCTAssertFalse(cleanExif.contains(gpsPointer(bigEndian: true)) || cleanExif.contains(gpsPointer(bigEndian: false)))
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(clean as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 8)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 6)
    }

    /// Segment APP1 (EXIF) d'un JPEG.
    private func app1(of jpeg: Data) -> Data? {
        let bytes = [UInt8](jpeg)
        var index = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if marker == 0xE1 { return Data(bytes[(index + 4)..<min(bytes.count, index + 2 + length)]) }
            if marker == 0xDA { return nil }
            index += 2 + length
        }
        return nil
    }

    private func gpsPointer(bigEndian: Bool) -> Data {
        Data(bigEndian ? [0x88, 0x25, 0x00, 0x04] : [0x25, 0x88, 0x04, 0x00])
    }

    /// Ce qui n'est pas une image (un PDF, du texte) passe tel quel.
    func testNonImageDataIsUntouched() {
        let text = Data("bonjour".utf8)
        XCTAssertEqual(MediaLocationStripper.strippedImage(text), text)
    }
}
