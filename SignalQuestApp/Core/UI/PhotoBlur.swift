import UIKit
import Vision

/// Flou avant publication (plan 3, vague 1).
///
/// Les visages sont repérés sur l'appareil (Vision) et d'autres zones
/// s'ajoutent à la main. Le flou est cuit dans les pixels avant le
/// ré-encodage : chaque zone est réduite à quelques échantillons puis
/// agrandie en lissant. L'information d'origine est détruite, là où un flou
/// gaussien seul peut être en partie inversé. Rien ne part au serveur avant
/// l'envoi, et l'original ne quitte pas l'appareil.
///
/// Les zones sont en coordonnées normalisées de l'image droite (0…1, origine
/// en haut à gauche), indépendantes de sa taille d'affichage ou d'envoi.
enum PhotoBlur {
    /// Échantillons gardés sur le plus grand côté d'une zone.
    static let samplesPerSide: CGFloat = 8
    /// Marge ajoutée autour d'un visage repéré, pour couvrir cheveux et menton.
    static let faceMargin: CGFloat = 0.3

    /// Visages repérés, en coordonnées normalisées. Vide si Vision échoue :
    /// les zones à la main restent possibles.
    static func detectFaces(in image: UIImage) async -> [CGRect] {
        guard let source = upright(image) else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let request = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: source, options: [:]).perform([request])
            return (request.results ?? []).map { face in
                // Vision compte depuis le bas ; l'écran et l'image, depuis le haut.
                let box = face.boundingBox
                return expanded(CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                                by: faceMargin)
            }
        }.value
    }

    /// Image droite, avec les zones floutées de façon irréversible.
    static func render(_ image: UIImage, regions: [CGRect]) -> UIImage {
        let usable = regions.map(clamped).filter { $0.width > 0 && $0.height > 0 }
        guard !usable.isEmpty, let source = upright(image) else { return image }
        let size = CGSize(width: source.width, height: source.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIImage(cgImage: source).draw(in: CGRect(origin: .zero, size: size))
            for region in usable {
                let rect = CGRect(
                    x: region.minX * size.width, y: region.minY * size.height,
                    width: region.width * size.width, height: region.height * size.height
                ).integral.intersection(CGRect(origin: .zero, size: size))
                guard rect.width >= 2, rect.height >= 2,
                      let crop = source.cropping(to: rect),
                      let tiny = downscaled(crop, longestSide: samplesPerSide) else { continue }
                context.cgContext.saveGState()
                // Coins arrondis : un rectangle net attire l'œil sur la zone.
                UIBezierPath(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.2).addClip()
                context.cgContext.interpolationQuality = .high
                UIImage(cgImage: tiny).draw(in: rect)
                context.cgContext.restoreGState()
            }
        }
    }

    #if DEBUG
    /// Image de recette : bandes de couleur, sans visage à repérer.
    static func qaSample() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 900), format: format).image { context in
            let colors: [UIColor] = [.systemTeal, .systemOrange, .systemIndigo, .systemGreen]
            for (index, color) in colors.enumerated() {
                color.setFill()
                context.fill(CGRect(x: CGFloat(index) * 300, y: 0, width: 300, height: 900))
            }
        }
    }
    #endif

    static func expanded(_ rect: CGRect, by margin: CGFloat) -> CGRect {
        clamped(rect.insetBy(dx: -rect.width * margin / 2, dy: -rect.height * margin / 2))
    }

    static func clamped(_ rect: CGRect) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clipped = rect.standardized.intersection(unit)
        return clipped.isNull ? .zero : clipped
    }

    /// Pixels droits : une photo tenue en portrait arrive souvent pivotée par
    /// son orientation EXIF, alors que les zones sont dessinées sur l'image
    /// telle qu'on la voit.
    private static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage { return cgImage }
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .cgImage
    }

    private static func downscaled(_ image: CGImage, longestSide: CGFloat) -> CGImage? {
        let longest = CGFloat(max(image.width, image.height))
        let size = CGSize(
            width: max(1, (CGFloat(image.width) / longest * longestSide).rounded()),
            height: max(1, (CGFloat(image.height) / longest * longestSide).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}
