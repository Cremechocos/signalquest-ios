import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SignalQuest

/// Une pièce jointe ne doit jamais trahir où elle a été prise : GPS d'une image,
/// atomes de lieu QuickTime d'une vidéo (révision 17 du chiffrement, et en clair).
/// Les octets de lieu sont mis à zéro, aux plages d'Android (§7.7) : la taille ne change
/// pas, et chaque test vérifie d'abord que l'original porte bien le lieu.
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

        let original = try Data(contentsOf: movie)
        let cleanData = MediaLocationStripper.strippedMovie(original)
        XCTAssertEqual(cleanData.count, original.count)
        XCTAssertFalse(String(decoding: cleanData, as: UTF8.self).contains("48.8566"))
        let clean = FileManager.default.temporaryDirectory.appendingPathComponent("clean-\(UUID().uuidString).mov")
        try cleanData.write(to: clean)
        defer { try? FileManager.default.removeItem(at: clean) }
        var values: [String] = []
        for item in try await locationItems(clean) {
            if let value = try await item.load(.stringValue) { values.append(value) }
        }
        XCTAssertFalse(values.contains { $0.contains("48.8566") }, "Lieu encore lisible : \(values)")

        let tracks = try await AVURLAsset(url: clean).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    private func geotaggedImage(_ type: UTType, extra: [CFString: Any] = [:]) throws -> Data {
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
        CGImageDestinationAddImage(destination, image, extra.merging([kCGImagePropertyGPSDictionary: gps]) { $1 } as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// JPEG, HEIC (item Exif), PNG (eXIf), WebP et TIFF : le bloc GPS à zéro, la taille, les
    /// pixels, l'orientation et le modèle intacts, les CRC d'un PNG toujours justes.
    func testImageLosesItsGPSButKeepsEverythingElse() throws {
        for type in [UTType.jpeg, .heic, .png, .tiff] {
            let original = try geotaggedImage(type, extra: [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Banc 1"],
            ])
            XCTAssertTrue(MediaLocationStripper.hasLocation(original), "\(type)")
            let clean = MediaLocationStripper.strippedImage(original)
            XCTAssertEqual(clean.count, original.count, "\(type)")
            XCTAssertFalse(MediaLocationStripper.hasLocation(clean), "\(type)")
            let source = try XCTUnwrap(CGImageSourceCreateWithData(clean as CFData, nil), "\(type)")
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "\(type)")
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 8, "\(type)")
            XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6, "\(type)")
            XCTAssertEqual((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String,
                           "Banc 1", "\(type)")
            if type == .png { XCTAssertTrue(pngCRCsAreValid(clean)) }
        }
    }

    /// Un TIFF de deux pages : le GPS de la seconde, au bout de la chaîne des IFD, part aussi.
    func testTIFFLosesTheGPSOfEveryPage() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 2, nil))
        let image = try XCTUnwrap(solidImage())
        // Deux lieux différents : traiter deux fois la première page ne suffirait pas.
        for latitude in [48.8566, 45.7578] {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: latitude, kCGImagePropertyGPSLatitudeRef: "N",
            ]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = data as Data
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        for page in 0..<2 {
            XCTAssertNotNil((CGImageSourceCopyPropertiesAtIndex(originalSource, page, nil) as? [CFString: Any])?[kCGImagePropertyGPSDictionary])
        }

        let clean = MediaLocationStripper.strippedImage(original)
        XCTAssertEqual(clean.count, original.count)
        let cleanSource = try XCTUnwrap(CGImageSourceCreateWithData(clean as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(cleanSource), 2)
        for page in 0..<2 {
            let gps = (CGImageSourceCopyPropertiesAtIndex(cleanSource, page, nil) as? [CFString: Any])?[kCGImagePropertyGPSDictionary]
            XCTAssertNil(gps, "La coordonnée de la page \(page + 1) est encore lisible")
        }
    }

    /// CRC-32 de chaque chunk d'un PNG, sur le type et les données.
    private func pngCRCsAreValid(_ png: Data) -> Bool {
        let bytes = [UInt8](png)
        var index = 8
        while index + 12 <= bytes.count {
            let length = bytes[index..<index + 4].reduce(0) { $0 << 8 | Int($1) }
            let end = index + 8 + length
            guard end + 4 <= bytes.count else { return false }
            let stored = bytes[end..<end + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard MediaLocationScrubber.crc32(bytes[index + 4..<end]) == stored else { return false }
            index = end + 4
        }
        return index == bytes.count
    }

    private func solidImage() -> CGImage? {
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return context?.makeImage()
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
        let result = try XCTUnwrap(MediaLocationStripper.animatedImage(animated))
        XCTAssertEqual(result.type, .gif)
        XCTAssertEqual(result.width, 8)
        XCTAssertEqual(result.height, 6)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.gif.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        let frame = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any])
        let gifProperties = try XCTUnwrap(frame[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(gifProperties[kCGImagePropertyGIFDelayTime] as? Double ?? 0, 0.1, accuracy: 0.001)
        XCTAssertFalse(MediaLocationStripper.hasLocation(result.data))

        XCTAssertNil(MediaLocationStripper.animatedImage(try gif(frames: 1)))
        XCTAssertNil(MediaLocationStripper.animatedImage(Data("bonjour".utf8)))
    }

    /// Reçue, une image animée est décodée image par image, au délai de chacune
    /// (0,1 s × 3 = 0,3 s) ; sans animation demandée, seule la première est gardée.
    func testReceivedAnimationPlaysAllItsFrames() throws {
        let data = try gif(frames: 3)
        let animation = try XCTUnwrap(ImagePipeline.animatedImage(data: data, maxPixel: 240))
        XCTAssertEqual(animation.images?.count, 3)
        XCTAssertEqual(animation.duration, 0.3, accuracy: 0.001)
        XCTAssertNil(ImagePipeline.animatedImage(data: try gif(frames: 1), maxPixel: 240))
        XCTAssertNil(ImagePipeline.downsample(data: data, maxPixel: 240)?.images)
    }

    /// Ce qui n'est pas une image (un PDF, du texte) passe tel quel.
    /// Image sans GPS, mais avec des noms de lieu en clair : IPTC, ou XMP seul.
    private func placeNamedImage(_ type: UTType, xmp: Bool) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        if xmp {
            let metadata = CGImageMetadataCreateMutable()
            for (path, value) in [("photoshop:City", "Villeurbanne"), ("photoshop:Country", "Lointainpays"),
                                  ("Iptc4xmpCore:Location", "Gratte-Ciel"), ("dc:title", "Pylone")] {
                XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString), path)
            }
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        } else {
            let iptc: [CFString: Any] = [
                kCGImagePropertyIPTCCity: "Villeurbanne", kCGImagePropertyIPTCSubLocation: "Gratte-Ciel",
                kCGImagePropertyIPTCProvinceState: "Rhone-Alpes", kCGImagePropertyIPTCCountryPrimaryLocationName: "Lointainpays",
            ]
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyIPTCDictionary: iptc] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Noms de lieu en clair (décision du 04/11, messagerie et fil) : le XMP (dans un HEIC,
    /// son item `mime` à part) et l'IPTC sont mis à zéro en entier, jusque dans les octets.
    func testPlaceNamesAreRemovedToo() throws {
        let names = ["Villeurbanne", "Gratte-Ciel", "Lointainpays"]
        for type in [UTType.jpeg, .png, .heic] {
            for xmp in [false, true] {
                let label = "\(type.identifier) xmp=\(xmp)"
                let original = try placeNamedImage(type, xmp: xmp)
                XCTAssertTrue(names.contains { original.range(of: Data($0.utf8)) != nil }, label)
                XCTAssertTrue(MediaLocationStripper.hasLocation(original), label)
                let clean = MediaLocationStripper.strippedImage(original)
                XCTAssertEqual(clean.count, original.count, label)
                XCTAssertFalse(MediaLocationStripper.hasLocation(clean), label)
                for name in names {
                    XCTAssertNil(clean.range(of: Data(name.utf8)), "\(label) \(name)")
                }
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(clean as CFData, nil)), 0, nil), label)
            }
        }
    }

    /// JPEG de Pixel : un second JPEG (gain map HDR) ou la vidéo d'une Motion Photo suit
    /// l'image principale, invisible à ImageIO, et peut porter un lieu. Nettoyé et gardé
    /// (« Nettoyer, tout garder », 04/11), même quand l'image principale n'a pas de lieu ;
    /// la date et le modèle restent (§7.7).
    func testJPEGCleansWhatFollowsItsPrimaryImageAndKeepsIt() throws {
        let place = Data("+45.7578+004.8320/".utf8)
        let video = box("ftyp", Data("isom".utf8) + Data(count: 4))
            + box("moov", box("udta", box("\u{A9}xyz", Data([0, 18, 0x15, 0xC7]) + place)))
        for primaryHasGPS in [false, true] {
            let label = "primaryHasGPS=\(primaryHasGPS)"
            let primary = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(primary, UTType.jpeg.identifier as CFString, 1, nil))
            var properties: [CFString: Any] = [
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:04 09:00:00"],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Pixel 9"],
            ]
            if primaryHasGPS {
                properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 45.7578, kCGImagePropertyGPSLatitudeRef: "N"]
            }
            CGImageDestinationAddImage(destination, try XCTUnwrap(solidImage()), properties as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let gainMap = try geotaggedImage(.jpeg)
            let original = (primary as Data) + gainMap + video
            XCTAssertEqual(MediaLocationStripper.hasLocation(primary as Data), primaryHasGPS, label)
            XCTAssertTrue(MediaLocationStripper.hasLocation(gainMap), label)
            XCTAssertNotNil(original.range(of: place), label)

            let clean = MediaLocationStripper.strippedImage(original)
            XCTAssertEqual(clean.count, original.count, label)
            XCTAssertNil(clean.range(of: place), label)
            XCTAssertFalse(MediaLocationStripper.hasLocation(clean.subdata(in: 0..<primary.length)), label)
            let cleanGainMap = clean.subdata(in: primary.length..<primary.length + gainMap.count)
            XCTAssertFalse(MediaLocationStripper.hasLocation(cleanGainMap), label)
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(cleanGainMap as CFData, nil)), 0, nil), label)
            // La vidéo reste là, sa structure intacte : seul le corps de `©xyz` (longueur, langue,
            // valeur) passe à zéro.
            let body = place.count + 4
            XCTAssertEqual(Data(clean.suffix(video.count).prefix(video.count - body)), Data(video.prefix(video.count - body)), label)
            XCTAssertEqual(Data(clean.suffix(body)), Data(count: body), label)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(clean as CFData, nil))
            let read = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual((read[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String, "Pixel 9")
            XCTAssertEqual((read[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String,
                           "2026:11:04 09:00:00")
        }
    }

    /// HEIF fait main dont les deux items ont un `item_name` non vide : `content_type` ne se
    /// trouve qu'après son zéro terminal (le HEIC d'ImageIO a des noms vides, et une lecture
    /// à décalage fixe y réussirait par accident). La description des items reste.
    func testHEIFItemsAreFoundPastANonEmptyItemName() throws {
        let jpeg = try geotaggedImage(.jpeg)
        let exifStart = try XCTUnwrap(jpeg.range(of: Data("Exif\0\0".utf8))).upperBound
        let exifLength = Int(jpeg[exifStart - 8]) << 8 | Int(jpeg[exifStart - 7])
        let tiff = jpeg.subdata(in: exifStart..<exifStart - 8 + 2 + exifLength)
        let exifBody = Data(count: 4) + tiff
        let xmpBody = Data("<x:xmpmeta><photoshop:City>Testville</photoshop:City></x:xmpmeta>".utf8)
        func u16(_ value: Int) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
        func u32(_ value: Int) -> Data { u16(value >> 16) + u16(value & 0xFFFF) }
        func infe(_ id: Int, _ type: String, _ name: String, _ contentType: String?) -> Data {
            var payload = Data([2, 0, 0, 0]) + u16(id) + u16(0)
            payload += Data(type.utf8) + Data(name.utf8) + Data([0])
            if let contentType { payload += Data(contentType.utf8) + Data([0]) }
            return box("infe", payload)
        }
        func file(exifAt: Int, xmpAt: Int) -> Data {
            let iinf = box("iinf", Data(count: 4) + u16(2) + infe(1, "Exif", "Exif metadata", nil)
                + infe(2, "mime", "XMP metadata payload", "application/rdf+xml"))
            // iloc version 0 : offset et longueur sur 4 octets, pas de base ; deux items d'une étendue.
            var entries = Data(count: 4) + Data([0x44, 0x00]) + u16(2)
            for (id, at, length) in [(1, exifAt, exifBody.count), (2, xmpAt, xmpBody.count)] {
                entries += u16(id) + u16(0) + u16(1)
                entries += u32(at) + u32(length)
            }
            let iloc = box("iloc", entries)
            return box("ftyp", Data("heic".utf8) + Data(count: 4)) + box("meta", Data(count: 4) + iinf + iloc)
        }
        let header = file(exifAt: 0, xmpAt: 0).count + 8
        let original = file(exifAt: header, xmpAt: header + exifBody.count) + box("mdat", exifBody + xmpBody)
        XCTAssertNotNil(original.range(of: Data("Testville".utf8)))

        let plan = MediaLocationScrubber.plan(for: original)
        var gps: [Range<Int>] = []
        MediaLocationScrubber.gpsRanges([UInt8](original), tiff: header + 4, end: header + exifBody.count, into: &gps)
        XCTAssertFalse(gps.isEmpty, "Le corps Exif doit porter un bloc GPS")
        XCTAssertEqual(plan.zeroed, [header + exifBody.count ..< original.count] + gps)
        let clean = MediaLocationScrubber.scrubbed(original)
        XCTAssertNil(clean.range(of: Data("Testville".utf8)), "La ville de l'item XMP est encore lisible")
        XCTAssertNotNil(clean.range(of: Data("application/rdf+xml".utf8)))
    }

    /// Boîte ISO BMFF : taille sur 32 bits, type, contenu.
    private func box(_ type: String, _ payload: Data) -> Data {
        let size = UInt32(8 + payload.count)
        return Data([UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
            + Data(type.unicodeScalars.map { UInt8($0.value) }) + payload
    }

    func testNonImageDataIsUntouched() {
        let text = Data("bonjour".utf8)
        XCTAssertEqual(MediaLocationStripper.strippedImage(text), text)
    }
}
