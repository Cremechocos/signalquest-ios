import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Retire le lieu de prise de vue d'une image ou d'une vidéo avant l'envoi, sans
/// réencoder : une pièce jointe ne doit jamais trahir où elle a été prise (règle de
/// la révision 17 du chiffrement, et déjà vraie en clair). Les octets de lieu sont mis
/// à zéro par `MediaLocationScrubber`, aux mêmes plages qu'Android (E2EE-AUTO §7.7).
enum MediaLocationStripper {
    /// Noms de lieu en clair, retirés comme les coordonnées dans la messagerie et le fil,
    /// jamais des photos d'antenne (décision d'Alexandre du 04/11, révision des formats).
    private static let placeNameIPTCKeys: [String] = [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
        kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
    ].map { $0 as String }
    private static let placeNameXMPTags: Set<String> = [
        "photoshop:City", "photoshop:State", "photoshop:Country", "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode",
    ]

    /// L'image sans lieu (GPS EXIF et XMP, noms de lieu IPTC et XMP), de même taille, tout
    /// le reste intact : pixels, orientation, date, modèle, gain map HDR, vidéo d'une Motion
    /// Photo. Une structure illisible part telle quelle, comme sur Android : jamais de refus.
    static func strippedImage(_ original: Data) -> Data {
        MediaLocationScrubber.scrubbed(original)
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
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (strippedImage(data), width, height, type)
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

    /// La vidéo sans lieu (`©xyz`, `com.apple.quicktime.location.ISO6709`), de même
    /// taille, pistes et autres métadonnées intactes.
    static func strippedMovie(_ data: Data) -> Data {
        MediaLocationScrubber.scrubbed(data)
    }
}
