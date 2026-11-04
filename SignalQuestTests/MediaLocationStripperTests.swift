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
    /// son item `mime` à part ; dans un TIFF, les tags 0x02BC et 0x83BB) et l'IPTC sont mis à
    /// zéro en entier, jusque dans les octets.
    func testPlaceNamesAreRemovedToo() throws {
        let names = ["Villeurbanne", "Gratte-Ciel", "Lointainpays"]
        for type in [UTType.jpeg, .png, .heic, .tiff] {
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
        XCTAssertEqual(plan.zeroed, (gps + [header + exifBody.count ..< original.count]).sorted { $0.lowerBound < $1.lowerBound })
        let clean = MediaLocationScrubber.scrubbed(original)
        XCTAssertNil(clean.range(of: Data("Testville".utf8)), "La ville de l'item XMP est encore lisible")
        XCTAssertNotNil(clean.range(of: Data("application/rdf+xml".utf8)))
    }

    /// TIFF fait main (II) dont le lieu n'est atteint que par des sous-IFD : le GPS pointé
    /// depuis l'ExifIFD (0x8769), un XMP dans le second élément d'un tableau SubIFDs (0x014A).
    func testTIFFSubIFDsAreCleanedToo() throws {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
        func u32(_ value: Int) -> [UInt8] { u16(value & 0xFFFF) + u16(value >> 16) }
        func ifd(_ entries: [(tag: Int, type: Int, count: Int, value: Int)]) -> [UInt8] {
            u16(entries.count) + entries.flatMap { u16($0.tag) + u16($0.type) + u32($0.count) + u32($0.value) } + u32(0)
        }
        let place = Array("Place Sous-IFD".utf8)
        let latitude = u32(12) + u32(1) + u32(34) + u32(1) + u32(56) + u32(1)
        // Agencement : en-tête 8, IFD0 8 (2 entrées, 30 o), ExifIFD 38 (1 entrée, 18 o),
        // GPS 56 (2 entrées, 30 o), latitude 86 (24 o), tableau SubIFDs 110 (8 o),
        // sous-IFD A 118 (0 entrée, 6 o), sous-IFD B 124 (1 entrée, 18 o), XMP 142.
        var file: [UInt8] = [0x49, 0x49, 0x2A, 0x00] + u32(8)
        file += ifd([(0x014A, 4, 2, 110), (0x8769, 4, 1, 38)])
        file += ifd([(0x8825, 4, 1, 56)])
        file += ifd([(0x0001, 2, 2, 0x4E), (0x0002, 5, 3, 86)])
        file += latitude + u32(118) + u32(124)
        file += ifd([])
        file += ifd([(0x02BC, 1, place.count, 142)]) + place
        let original = Data(file)
        XCTAssertNotNil(original.range(of: Data(latitude)))
        XCTAssertNotNil(original.range(of: Data(place)))

        XCTAssertEqual(MediaLocationScrubber.plan(for: original).zeroed, [56..<58, 58..<82, 86..<110, 142..<142 + place.count])
        let clean = MediaLocationStripper.strippedImage(original)
        XCTAssertEqual(clean.count, original.count)
        XCTAssertNil(clean.range(of: Data(latitude)), "Le GPS pointé par l'ExifIFD est encore là")
        XCTAssertNil(clean.range(of: Data(place)), "Le XMP du second SubIFD est encore là")
    }

    /// HEIF fait main dont l'item Exif a deux étendues, séparées par l'item XMP, et dont le
    /// bloc GPS est à cheval sur la frontière : lues bout à bout, plages reportées sur le fichier.
    func testHEIFExifItemSpreadOverTwoExtents() throws {
        let jpeg = try geotaggedImage(.jpeg)
        let exifStart = try XCTUnwrap(jpeg.range(of: Data("Exif\0\0".utf8))).upperBound
        let exifLength = Int(jpeg[exifStart - 8]) << 8 | Int(jpeg[exifStart - 7])
        let exifBody = Data(count: 4) + jpeg.subdata(in: exifStart..<exifStart - 8 + 2 + exifLength)
        var gps: [Range<Int>] = []
        MediaLocationScrubber.gpsRanges([UInt8](exifBody), tiff: 4, end: exifBody.count, into: &gps)
        let entries = try XCTUnwrap(gps.first { $0.count > 2 })
        let split = entries.lowerBound + entries.count / 2
        let xmpBody = Data("<x:xmpmeta><photoshop:City>Testville</photoshop:City></x:xmpmeta>".utf8)
        func u16(_ value: Int) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
        func u32(_ value: Int) -> Data { u16(value >> 16) + u16(value & 0xFFFF) }
        func infe(_ id: Int, _ type: String, _ name: String, _ contentType: String?) -> Data {
            var payload = Data([2, 0, 0, 0]) + u16(id) + u16(0)
            payload += Data(type.utf8) + Data(name.utf8) + Data([0])
            if let contentType { payload += Data(contentType.utf8) + Data([0]) }
            return box("infe", payload)
        }
        func file(_ mdat: Int) -> Data {
            let iinf = box("iinf", Data(count: 4) + u16(2) + infe(1, "Exif", "Exif metadata", nil)
                + infe(2, "mime", "XMP metadata payload", "application/rdf+xml"))
            var entries = Data(count: 4) + Data([0x44, 0x00]) + u16(2)
            entries += u16(1) + u16(0) + u16(2)
            entries += u32(mdat) + u32(split)
            entries += u32(mdat + split + xmpBody.count) + u32(exifBody.count - split)
            entries += u16(2) + u16(0) + u16(1)
            entries += u32(mdat + split) + u32(xmpBody.count)
            return box("ftyp", Data("heic".utf8) + Data(count: 4)) + box("meta", Data(count: 4) + iinf + box("iloc", entries))
        }
        let mdat = file(0).count + 8
        let original = file(mdat) + box("mdat", exifBody.prefix(split) + xmpBody + exifBody.suffix(from: split))

        // Chaque plage du corps, décalée de sa place dans le fichier ; celle des entrées coupée en deux.
        let second = mdat + split + xmpBody.count
        var expected: [Range<Int>] = [mdat + split ..< second]
        for range in gps {
            if range.upperBound <= split { expected.append(mdat + range.lowerBound ..< mdat + range.upperBound) }
            else if range.lowerBound >= split { expected.append(second + range.lowerBound - split ..< second + range.upperBound - split) }
            else { expected += [mdat + range.lowerBound ..< mdat + split, second ..< second + range.upperBound - split] }
        }
        expected.sort { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }
        XCTAssertEqual(MediaLocationScrubber.plan(for: original).zeroed, expected)
        XCTAssertTrue(expected.contains { $0.lowerBound >= second && $0.upperBound <= original.count }, "Rien d'effacé dans la seconde étendue")
    }

    /// Boîte ISO BMFF : taille sur 32 bits, type, contenu.
    private func box(_ type: String, _ payload: Data) -> Data {
        let size = UInt32(8 + payload.count)
        return Data([UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
            + Data(type.unicodeScalars.map { UInt8($0.value) }) + payload
    }

    /// Trouvé par fuzzing : un segment plus court que son identifiant (l'identifiant déborde
    /// sur le segment suivant) ne fait pas planter l'envoi et n'efface rien hors du segment.
    func testSegmentShorterThanItsIdentifierIsIgnored() {
        let xmp = Data("http://ns.adobe.com/xap/1.0/\0<x>Testville</x>".utf8)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x04]) + xmp + Data([0xFF, 0xD9])
        XCTAssertTrue(MediaLocationScrubber.plan(for: jpeg).zeroed.isEmpty)
        XCTAssertEqual(MediaLocationStripper.strippedImage(jpeg), jpeg)
    }

    /// Contrat r17 (a014cdf19) : un iloc tronqué après l'entrée de l'item Exif garde cette
    /// entrée ; le débordement n'arrête que la lecture de l'iloc, l'Exif déjà lu reste effacé.
    func testTruncatedIlocKeepsTheExifItemAlreadyRead() throws {
        let jpeg = try geotaggedImage(.jpeg)
        let exifStart = try XCTUnwrap(jpeg.range(of: Data("Exif\0\0".utf8))).upperBound
        let exifLength = Int(jpeg[exifStart - 8]) << 8 | Int(jpeg[exifStart - 7])
        let exifBody = Data(count: 4) + jpeg.subdata(in: exifStart..<exifStart - 8 + 2 + exifLength)
        func u16(_ value: Int) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
        func u32(_ value: Int) -> Data { u16(value >> 16) + u16(value & 0xFFFF) }
        func file(_ mdat: Int) -> Data {
            var infe = Data([2, 0, 0, 0]) + u16(1) + u16(0)
            infe += Data("Exif".utf8) + Data([0])
            // Deux items annoncés, une seule entrée : l'iloc s'arrête net après l'item Exif.
            var entries = Data(count: 4) + Data([0x44, 0x00]) + u16(2)
            entries += u16(1) + u16(0) + u16(1) + u32(mdat) + u32(exifBody.count)
            return box("ftyp", Data("heic".utf8) + Data(count: 4))
                + box("meta", Data(count: 4) + box("iinf", Data(count: 4) + u16(1) + box("infe", infe)) + box("iloc", entries))
        }
        let mdat = file(0).count + 8
        let original = file(mdat) + box("mdat", exifBody)
        var gps: [Range<Int>] = []
        MediaLocationScrubber.gpsRanges([UInt8](original), tiff: mdat + 4, end: mdat + exifBody.count, into: &gps)
        XCTAssertFalse(gps.isEmpty)
        XCTAssertEqual(MediaLocationScrubber.plan(for: original).zeroed, gps.sorted { $0.lowerBound < $1.lowerBound })
    }

    /// Trouvé par fuzzing : une entrée d'IFD tronquée en fin de fichier, à valeur en ligne,
    /// ne donne aucune plage hors du fichier.
    func testInlineValueOfATruncatedEntryStaysInTheFile() {
        // II, IFD0 à 8 : une entrée XMP (0x02BC, BYTE, 4) dont la valeur manque.
        let tiff = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01, 0x00, 0xBC, 0x02, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00, 0x41])
        let plan = MediaLocationScrubber.plan(for: tiff)
        XCTAssertTrue(plan.zeroed.allSatisfy { $0.upperBound <= tiff.count })
        XCTAssertEqual(MediaLocationStripper.strippedImage(tiff).count, tiff.count)
    }

    func testNonImageDataIsUntouched() {
        let text = Data("bonjour".utf8)
        XCTAssertEqual(MediaLocationStripper.strippedImage(text), text)
    }

    /// GIF 1 × 1 sans palette globale, autour des extensions données.
    private func handmadeGIF(_ extensions: [UInt8]) -> Data {
        var bytes = Array("GIF89a".utf8) + [1, 0, 1, 0, 0, 0, 0]
        bytes += extensions
        bytes += [0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B]
        return Data(bytes)
    }

    /// Disposition réelle : un premier sous-bloc de 11 octets (identifiant et code
    /// d'authentification), puis les données dans les sous-blocs suivants. Seules
    /// les données partent, jamais les octets de longueur ; une autre extension
    /// d'application, ou un identifiant à cheval sur deux sous-blocs, reste intacte.
    func testGIFXMPDataIsZeroedInItsOwnSubBlocksOnly() {
        let place = Array("<x>Testville 45.1</x>".utf8)
        let netscape: [UInt8] = [0x21, 0xFF, 11] + Array("NETSCAPE2.0".utf8) + [3, 1, 0, 0, 0]
        let xmp: [UInt8] = [0x21, 0xFF, 11] + Array("XMP DataXMP".utf8)
            + [UInt8(place.count)] + place + [2, 0x41, 0x42, 0]
        let data = handmadeGIF(netscape + xmp)
        let start = 13 + netscape.count + 3 + 11
        XCTAssertEqual(MediaLocationScrubber.plan(for: data).zeroed, [start + 1 ..< start + 1 + place.count, start + 2 + place.count ..< start + 4 + place.count])
        let cleaned = MediaLocationScrubber.scrubbed(data)
        XCTAssertEqual(cleaned.count, data.count)
        XCTAssertNil(cleaned.range(of: Data("Testville".utf8)))
        XCTAssertNotNil(cleaned.range(of: Data("NETSCAPE2.0".utf8)), "autre extension intacte")
        XCTAssertEqual(cleaned[start], UInt8(place.count), "longueur de sous-bloc gardée")

        // Identifiant éclaté : « X » seul, puis la longueur 77 (« M ») et « P DataXMP »… : 79 octets d'« XMP DataXMP » qui ne sont pas l'identifiant.
        let straddling: [UInt8] = [0x21, 0xFF, 1, 0x58, 77] + Array("P DataXMP".utf8) + [67] + [UInt8](repeating: 0x55, count: 67) + [0]
        XCTAssertTrue(MediaLocationScrubber.plan(for: handmadeGIF(straddling)).zeroed.isEmpty)
    }
}
