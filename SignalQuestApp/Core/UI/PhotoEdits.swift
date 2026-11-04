import UIKit

/// Retouches d'une photo avant publication (éditeur « Modifier », E1).
///
/// Non destructives : l'original reste intact, rouvrir l'éditeur retrouve le
/// cadre et les zones. À l'envoi, `PhotoEditRenderer` cuit une copie.
///
/// Tout est exprimé dans l'**espace de base** : l'image droite après ses quarts
/// de tour, en coordonnées normalisées (0…1, origine en haut à gauche). Le cadre
/// survit donc à un changement de redressement ou de cadre ; les zones de flou gardent
/// le redressement sous lequel elles ont été tracées (`blurAngle`) et suivent la photo.
struct PhotoEdits: Equatable, Sendable {
    /// Quarts de tour à gauche (0…3).
    var quarterTurns = 0
    /// Redressement en degrés, de −45 à +45 ; positif = sens horaire.
    var straighten: Double = 0
    /// Cadre retenu, normalisé dans l'espace de base.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Zones floutées, normalisées dans l'espace de base redressé de `blurAngle`.
    var blurRegions: [CGRect] = []
    /// Redressement sous lequel les zones ont été tracées ou repérées.
    var blurAngle: Double = 0
    /// Les visages ont déjà été cherchés : rouvrir l'éditeur ne rajoute pas ceux qu'on a retirés.
    var facesChecked = false
    /// Filtre prédéfini et son intensité (0…1), puis réglages (E2).
    var filter: PhotoFilter = .none
    var filterStrength: Double = 1
    var adjustments = PhotoAdjustments()

    static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    static let straightenLimit: Double = 45

    var hasGeometryChanges: Bool { quarterTurns % 4 != 0 || straighten != 0 || crop != Self.fullFrame }
    var hasBlur: Bool { !blurRegions.isEmpty }
    var hasFilter: Bool { filter != .none && filterStrength > 0 }
    var hasAdjustments: Bool { !adjustments.isNeutral }
    var hasColorChanges: Bool { hasFilter || hasAdjustments }
    /// Rien à cuire : l'original peut partir tel quel.
    var isIdentity: Bool { !hasGeometryChanges && !hasBlur && !hasColorChanges }

    /// Filtre à son intensité, puis réglages, en une seule matrice.
    var colorMatrix: PhotoColorMatrix {
        // Sans retouche, l'identité exacte : les calculs en flottants n'y retombent pas toujours.
        guard hasColorChanges else { return .identity }
        let filtered = hasFilter ? filter.matrix.strength(filterStrength) : .identity
        return hasAdjustments ? filtered.then(adjustments.matrix) : filtered
    }

    /// Taille de l'espace de base pour une image droite de taille `upright`.
    func baseSize(for upright: CGSize) -> CGSize {
        quarterTurns % 2 == 0 ? upright : CGSize(width: upright.height, height: upright.width)
    }

    /// Quart de tour à gauche : le cadre et les zones tournent avec l'image.
    mutating func rotateLeft() {
        quarterTurns = (quarterTurns + 1) % 4
        crop = Self.rotatedLeft(crop)
        blurRegions = blurRegions.map(Self.rotatedLeft)
    }

    /// Zones à l'angle de redressement actuel. Le contenu sous une zone tourne et grossit
    /// avec le redressement : la zone le suit, élargie à son rectangle englobant pour ne
    /// jamais rien laisser dépasser.
    func blurRegionsStraightened(base: CGSize) -> [CGRect] {
        guard straighten != blurAngle, base.width > 0, base.height > 0 else { return blurRegions }
        let scale = Self.straightenScale(for: base, degrees: straighten) / Self.straightenScale(for: base, degrees: blurAngle)
        let transform = CGAffineTransform(rotationAngle: CGFloat((straighten - blurAngle) * .pi / 180))
            .scaledBy(x: scale, y: scale)
        return blurRegions.map { region in
            let corners = [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                           CGPoint(x: region.minX, y: region.maxY), CGPoint(x: region.maxX, y: region.maxY)]
                .map { CGPoint(x: ($0.x - 0.5) * base.width, y: ($0.y - 0.5) * base.height).applying(transform) }
                .map { CGPoint(x: $0.x / base.width + 0.5, y: $0.y / base.height + 0.5) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    /// Ramène les zones à l'angle actuel, avant d'en tracer ou d'en repérer d'autres.
    mutating func anchorBlurRegions(base: CGSize) {
        blurRegions = blurRegionsStraightened(base: base)
        blurAngle = straighten
    }

    /// Un point (x, y) de l'ancienne base devient (y, 1 − x) après un quart de tour à gauche.
    static func rotatedLeft(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
    }

    /// Agrandissement qui évite les coins vides : l'image tournée de `degrees`
    /// couvre encore tout le rectangle `size`.
    static func straightenScale(for size: CGSize, degrees: Double) -> CGFloat {
        guard size.width > 0, size.height > 0, degrees != 0 else { return 1 }
        let angle = abs(degrees) * .pi / 180
        let c = CGFloat(cos(angle)), s = CGFloat(sin(angle))
        return max((size.width * c + size.height * s) / size.width,
                   (size.width * s + size.height * c) / size.height)
    }

    /// Plus grand cadre de proportions `aspect` (largeur / hauteur, en pixels) centré
    /// sur `center` et contenu dans la base de taille `base`.
    static func largestCrop(aspect: CGFloat, in base: CGSize, centeredOn center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> CGRect {
        guard aspect > 0, base.width > 0, base.height > 0 else { return fullFrame }
        var width: CGFloat = 1
        var height = base.width / (aspect * base.height)
        if height > 1 {
            width = 1 / height
            height = 1
        }
        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        return clampedInside(rect)
    }

    /// Ramène un cadre dans 0…1 sans changer sa taille (sauf s'il déborde de partout).
    static func clampedInside(_ rect: CGRect) -> CGRect {
        let width = min(rect.width, 1), height = min(rect.height, 1)
        return CGRect(x: min(max(rect.minX, 0), 1 - width), y: min(max(rect.minY, 0), 1 - height),
                      width: width, height: height)
    }
}

/// Cuit `PhotoEdits` dans une copie : quarts de tour et redressement, puis couleur,
/// puis flou, puis cadre. Le flou passe avant le cadre sur l'image entière ; le résultat est le
/// même qu'après, et une zone à cheval sur le bord reste floutée jusqu'au bord.
enum PhotoEditRenderer {
    /// `maxSide` borne le plus grand côté de la sortie, en pixels.
    static func render(_ image: UIImage, edits: PhotoEdits, maxSide: CGFloat? = nil) -> UIImage {
        guard !edits.isIdentity else { return image }
        let upright = image.size
        guard upright.width > 0, upright.height > 0 else { return image }
        let base = edits.baseSize(for: upright)
        // Taille en pixels : borne de sortie appliquée au cadre, pas à la base entière.
        let cropPixels = CGSize(width: base.width * edits.crop.width, height: base.height * edits.crop.height)
        let pixelScale = image.scale * min(1, (maxSide ?? .greatestFiniteMagnitude) / max(cropPixels.width * image.scale, cropPixels.height * image.scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = pixelScale
        format.opaque = true

        let straightened = UIGraphicsImageRenderer(size: base, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: base.width / 2, y: base.height / 2)
            cg.rotate(by: CGFloat(-Double(edits.quarterTurns) * .pi / 2 + edits.straighten * .pi / 180))
            let scale = PhotoEdits.straightenScale(for: base, degrees: edits.straighten)
            cg.scaleBy(x: scale, y: scale)
            image.draw(in: CGRect(x: -upright.width / 2, y: -upright.height / 2, width: upright.width, height: upright.height))
        }
        let colored = PhotoColor.render(straightened, matrix: edits.colorMatrix)
        let blurred = PhotoBlur.render(colored, regions: edits.blurRegionsStraightened(base: base))
        guard edits.crop != PhotoEdits.fullFrame, let source = blurred.cgImage else { return blurred }
        let pixels = CGSize(width: source.width, height: source.height)
        let rect = CGRect(x: edits.crop.minX * pixels.width, y: edits.crop.minY * pixels.height,
                          width: edits.crop.width * pixels.width, height: edits.crop.height * pixels.height)
            .integral.intersection(CGRect(origin: .zero, size: pixels))
        guard rect.width >= 1, rect.height >= 1, let cropped = source.cropping(to: rect) else { return blurred }
        return UIImage(cgImage: cropped, scale: blurred.scale, orientation: .up)
    }
}
