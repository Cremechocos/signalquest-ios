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

    private func geotaggedImage(_ type: UTType) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 48.8566, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.3522, kCGImagePropertyGPSLongitudeRef: "E",
        ]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// ImageIO ne retire le GPS sans réencoder que du JPEG : le HEIC et le PNG
    /// passent par la réécriture, vérifiée ici aussi.
    func testHEICAndPNGLoseTheirGPSToo() throws {
        for type in [UTType.heic, .png] {
            let original = try geotaggedImage(type)
            XCTAssertTrue(MediaLocationStripper.hasLocation(original), "\(type)")
            XCTAssertTrue(containsGPSPointer(original), "\(type)")
            let clean = try XCTUnwrap(MediaLocationStripper.strippedImage(original), "\(type)")
            XCTAssertFalse(MediaLocationStripper.hasLocation(clean), "\(type)")
            XCTAssertFalse(containsGPSPointer(clean), "\(type)")
            let source = try XCTUnwrap(CGImageSourceCreateWithData(clean as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 8, "\(type)")
        }
    }

    private func containsGPSPointer(_ data: Data) -> Bool {
        data.range(of: Data([0x88, 0x25])) != nil || data.range(of: Data([0x25, 0x88])) != nil
    }

    func testImageLosesItsGPSButKeepsItsPixels() throws {
        let original = try geotaggedImage(.jpeg)
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

    /// GIF de `frames` images 8 × 6, 0,1 s chacune.
    private func gif(frames: Int) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, frames, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        for index in 0..<frames {
            context.setFillColor(CGColor(red: CGFloat(index) / CGFloat(max(1, frames)), green: 0.2, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), delay)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Un GIF animé part tel quel (images et délais intacts) au lieu d'un JPEG fixe ;
    /// un GIF fixe ou une autre image reste sur le chemin JPEG.
    func testAnimatedGIFKeepsItsFrames() throws {
        let animated = try gif(frames: 3)
        let result = try XCTUnwrap(MediaLocationStripper.animatedGIF(animated))
        XCTAssertEqual(result.width, 8)
        XCTAssertEqual(result.height, 6)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.gif.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        let frame = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any])
        let gifProperties = try XCTUnwrap(frame[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(gifProperties[kCGImagePropertyGIFDelayTime] as? Double ?? 0, 0.1, accuracy: 0.001)
        XCTAssertFalse(MediaLocationStripper.hasLocation(result.data))

        XCTAssertNil(MediaLocationStripper.animatedGIF(try gif(frames: 1)))
        XCTAssertNil(MediaLocationStripper.animatedGIF(Data("bonjour".utf8)))
    }

    /// Ce qui n'est pas une image (un PDF, du texte) passe tel quel.
    func testNonImageDataIsUntouched() {
        let text = Data("bonjour".utf8)
        XCTAssertEqual(MediaLocationStripper.strippedImage(text), text)
    }
}
