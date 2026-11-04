import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Retire le lieu de prise de vue d'une image ou d'une vidéo avant l'envoi, sans
/// réencoder : une pièce jointe ne doit jamais trahir où elle a été prise (règle de
/// la révision 17 du chiffrement, et déjà vraie en clair).
enum MediaLocationStripper {
    enum StripError: Error { case unreadable, exportFailed }

    /// Noms de lieu en clair, retirés comme les coordonnées dans la messagerie et le fil,
    /// jamais des photos d'antenne (décision d'Alexandre du 04/11, révision des formats).
    private static let placeNameIPTCKeys: [String] = [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
        kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
    ].map { $0 as String }
    /// Formats dont la relecture montre tout ce que la copie garde. En PNG (sur iOS) et
    /// en TIFF, la copie garde les noms de lieu dans un paquet XMP ou des balises brutes
    /// qu'ImageIO ne relit plus : ces formats, sans perte, passent par la réécriture.
    private static let copyVerifiableTypes: Set<String> = [
        UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier, UTType.gif.identifier,
    ]
    private static let placeNameXMPTags: Set<String> = [
        "photoshop:City", "photoshop:State", "photoshop:Country", "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode",
    ]

    /// Copie de l'image sans lieu (GPS EXIF et XMP, noms de lieu IPTC et XMP), pixels
    /// inchangés. `nil` si l'image porte un lieu qu'on ne sait pas retirer : mieux vaut
    /// refuser que l'envoyer.
    static func strippedImage(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return data }
        guard hasLocation(data) else { return data }
        let count = CGImageSourceGetCount(source)
        // 1. Copie sans réencodage. ImageIO ne retire le GPS ainsi que du JPEG : le
        //    HEIC et le PNG le gardent, d'où la vérification du résultat.
        //    Les noms de lieu sont retirés de la copie des métadonnées, qui remplace l'originale.
        var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            options[kCGImageDestinationMetadata] = locationFreeMetadata(metadata)
            options[kCGImageDestinationMergeMetadata] = false
        }
        let copied = NSMutableData()
        if copyVerifiableTypes.contains(type as String),
           let destination = CGImageDestinationCreateWithData(copied, type, count, nil),
           CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil),
           !hasLocation(copied as Data) {
            return copied as Data
        }
        // 2. Réécriture image par image, sans dictionnaire GPS ni IPTC.
        let rewritten = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(rewritten, type, count, nil) else { return nil }
        for index in 0..<count {
            let properties: [CFString: Any] = [kCGImagePropertyGPSDictionary: kCFNull as Any,
                                               kCGImagePropertyIPTCDictionary: kCFNull as Any,
                                               kCGImageDestinationLossyCompressionQuality: 0.95]
            CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination), !hasLocation(rewritten as Data) else { return nil }
        return rewritten as Data
    }

    /// GIF ou WebP animé sans lieu, ses images et leurs délais intacts, avec la taille de
    /// sa première image et son type ; `nil` pour une image fixe ou un autre format, qui
    /// partent en JPEG. Le serveur ne garde l'animation que de ces deux formats.
    static func animatedImage(_ data: Data) -> (data: Data, width: Int, height: Int, type: UTType)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = [UTType.gif, UTType.webP].first(where: { $0.identifier == identifier }),
              CGImageSourceGetCount(source) > 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let clean = strippedImage(data) else { return nil }
        return (clean, width, height, type)
    }

    /// L'image porte un lieu : coordonnées GPS (EXIF ou XMP) ou nom de lieu (IPTC ou XMP).
    static func hasLocation(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        for index in 0..<CGImageSourceGetCount(source) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] {
                if properties[kCGImagePropertyGPSDictionary] != nil { return true }
                if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [String: Any],
                   placeNameIPTCKeys.contains(where: { iptc[$0] != nil }) { return true }
            }
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
               let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag],
               tags.contains(where: isLocationTag) {
                return true
            }
        }
        return false
    }

    private static func isLocationTag(_ tag: CGImageMetadataTag) -> Bool {
        guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
              let name = CGImageMetadataTagCopyName(tag) as String? else { return false }
        return (prefix == "exif" && name.hasPrefix("GPS")) || placeNameXMPTags.contains("\(prefix):\(name)")
    }

    /// Les métadonnées sans balise de lieu.
    private static func locationFreeMetadata(_ metadata: CGImageMetadata) -> CGImageMetadata {
        guard let mutable = CGImageMetadataCreateMutableCopy(metadata),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return metadata }
        for tag in tags where isLocationTag(tag) {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            CGImageMetadataRemoveTagWithPath(mutable, nil, "\(prefix):\(name)" as CFString)
        }
        return mutable
    }

    /// Copie de la vidéo sans ses métadonnées d'identification (lieu QuickTime
    /// `©xyz` et `com.apple.quicktime.location.ISO6709` compris), pistes recopiées
    /// sans réencodage. Le fichier rendu est temporaire : à supprimer après usage.
    static func strippedMovie(at url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw StripError.unreadable
        }
        let fileType: AVFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-\(UUID().uuidString)")
            .appendingPathExtension(fileType == .mp4 ? "mp4" : "mov")
        session.outputURL = output
        session.outputFileType = fileType
        session.metadataItemFilter = .forSharing()
        session.shouldOptimizeForNetworkUse = true
        let box = ExportBox(session)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { continuation.resume() }
        }
        guard box.session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw StripError.exportFailed
        }
        return output
    }

    /// Données d'une vidéo sans lieu, passées par un fichier temporaire.
    static func strippedMovie(data: Data, fileExtension: String) async throws -> Data {
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-in-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension.isEmpty ? "mov" : fileExtension)
        try data.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = try await strippedMovie(at: input)
        defer { try? FileManager.default.removeItem(at: output) }
        return try Data(contentsOf: output, options: .mappedIfSafe)
    }

    /// La session d'export n'est pas `Sendable` ; elle n'est touchée qu'avant le
    /// lancement et après la fin de l'export.
    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }
}
