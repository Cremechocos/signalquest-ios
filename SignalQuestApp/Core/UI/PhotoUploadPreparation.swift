import Foundation
import UIKit
import ImageIO

/// Préparation d'une photo avant upload, en deux temps :
/// 1. **Extraction** des métadonnées EXIF utiles (GPS, date de prise, appareil, orientation,
///    dimensions) au format attendu par le backend (champ multipart `exifMetadata`, fusionné
///    par `mergeClientPhotoExifMetadata` — clés camelCase de `ExtractedPhotoExifMetadata`,
///    parité Android). On RÉCUPÈRE donc les données que Prisma/Android exploitent.
/// 2. **Re-encodage downscalé** de l'image, qui retire l'EXIF BRUT embarqué (vie privée +
///    poids), puisque les métadonnées utiles sont désormais transmises explicitement.
enum PhotoUploadPreparation {
    struct Prepared {
        let jpeg: Data
        /// Métadonnées EXIF extraites, sérialisées JSON pour le champ multipart `exifMetadata`.
        let exifJSON: String?
    }

    /// Extrait les métadonnées PUIS re-encode (à exécuter hors du thread principal).
    static func prepare(from original: Data, maxSide: CGFloat = 1600, quality: CGFloat = 0.85) -> Prepared? {
        let exif = extractMetadata(from: original)
        guard let jpeg = downscaledJPEG(from: original, maxSide: maxSide, quality: quality) else { return nil }
        let json = exif.flatMap { dict -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let string = String(data: data, encoding: .utf8) else { return nil }
            return string
        }
        return Prepared(jpeg: jpeg, exifJSON: json)
    }

    /// Dictionnaire de métadonnées client (clés acceptées par le backend) : `gpsLatitude`/
    /// `gpsLongitude` signés (+ refs), `gpsAltitude`, `gpsImgDirection`, `dateTimeOriginal`
    /// (ISO 8601), `cameraMake`/`cameraModel`, `orientation`, `width`/`height`, `originalMimeType`.
    static func extractMetadata(from data: Data) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }

        var out: [String: Any] = [:]

        if let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue { out["width"] = w }
        if let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue { out["height"] = h }
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue { out["orientation"] = o }

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake] as? String { out["cameraMake"] = make }
            if let model = tiff[kCGImagePropertyTIFFModel] as? String { out["cameraModel"] = model }
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let dto = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let iso = isoDate(fromExif: dto) {
                out["dateTimeOriginal"] = iso
            }
            if out["width"] == nil, let pxw = (exif[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue { out["width"] = pxw }
            if out["height"] == nil, let pxh = (exif[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue { out["height"] = pxh }
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue {
                let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String
                out["gpsLatitude"] = (ref == "S") ? -lat : lat
                if let ref { out["gpsLatitudeRef"] = ref }
            }
            if let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
                let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String
                out["gpsLongitude"] = (ref == "W") ? -lon : lon
                if let ref { out["gpsLongitudeRef"] = ref }
            }
            if let alt = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue {
                let ref = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue
                out["gpsAltitude"] = (ref == 1) ? -alt : alt
            }
            if let dir = (gps[kCGImagePropertyGPSImgDirection] as? NSNumber)?.doubleValue { out["gpsImgDirection"] = dir }
        }

        out["originalMimeType"] = mimeType(of: source)
        out["parser"] = "ios.imageio"
        out["exifDetected"] = !out.isEmpty

        return out.isEmpty ? nil : out
    }

    /// Downscale + re-encode JPEG via UIGraphicsImageRenderer (qui n'embarque AUCUNE
    /// métadonnée), bornant le plus grand côté à `maxSide`.
    static func downscaledJPEG(from data: Data, maxSide: CGFloat, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let largest = max(image.size.width, image.size.height)
        let scale = largest > maxSide ? maxSide / largest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: quality)
    }

    private static func mimeType(of source: CGImageSource) -> String {
        guard let uti = CGImageSourceGetType(source) as String? else { return "image/jpeg" }
        if uti.contains("png") { return "image/png" }
        if uti.contains("heic") || uti.contains("heif") { return "image/heic" }
        return "image/jpeg"
    }

    /// Convertit "yyyy:MM:dd HH:mm:ss" (format EXIF) en ISO 8601.
    private static func isoDate(fromExif exif: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: exif) else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }
}
