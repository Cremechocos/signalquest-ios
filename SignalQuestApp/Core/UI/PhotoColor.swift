import CoreImage
import SwiftUI
import UIKit

/// Matrice de couleur 4×5, rangée ligne par ligne (E2, convention commune avec le web) :
/// R' = r0·R + r1·G + r2·B + r3·A + r4, puis G', B', A'.
///
/// Entrées, sorties et décalage (5e colonne) sont normalisés dans [0, 1], et non en
/// 0–255 comme le ColorMatrix d'Android. La matrice s'applique aux valeurs sRGB
/// **gamma** (non linéaires), une seule fois, et le résultat est borné à [0, 1] à la fin.
/// CoreImage calcule en linéaire par défaut : `PhotoColor.context` fixe donc son espace
/// de travail en sRGB, sinon les couleurs différeraient de celles du web.
struct PhotoColorMatrix: Equatable, Sendable {
    /// 20 coefficients, 4 lignes de 5.
    var values: [Double]

    static let identity = PhotoColorMatrix(values: [
        1, 0, 0, 0, 0,
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 1, 0,
    ])

    /// Poids de luminance Rec. 709, ceux de la saturation et du noir et blanc.
    static let luma = (r: 0.2126, g: 0.7152, b: 0.0722)

    func value(row: Int, column: Int) -> Double { values[row * 5 + column] }

    /// `self` appliquée d'abord, puis `next`.
    func then(_ next: PhotoColorMatrix) -> PhotoColorMatrix {
        var result = [Double](repeating: 0, count: 20)
        for row in 0..<4 {
            for column in 0..<5 {
                var sum = 0.0
                for k in 0..<4 { sum += next.value(row: row, column: k) * value(row: k, column: column) }
                // Le décalage de `self` passe par `next`, puis s'ajoute celui de `next`.
                if column == 4 { sum += next.value(row: row, column: 4) }
                result[row * 5 + column] = sum
            }
        }
        return PhotoColorMatrix(values: result)
    }

    /// Mélange avec l'identité : 0 rend la photo intacte, 1 la matrice entière.
    func strength(_ amount: Double) -> PhotoColorMatrix {
        let t = min(max(amount, 0), 1)
        if t == 1 { return self }
        return PhotoColorMatrix(values: zip(values, Self.identity.values).map { $1 + t * ($0 - $1) })
    }

    /// Pixel (r, g, b, a) dans [0, 1] après la matrice, borné à [0, 1].
    func apply(_ pixel: (Double, Double, Double, Double)) -> (Double, Double, Double, Double) {
        let input = [pixel.0, pixel.1, pixel.2, pixel.3]
        let out = (0..<4).map { row in
            min(max((0..<4).reduce(value(row: row, column: 4)) { $0 + value(row: row, column: $1) * input[$1] }, 0), 1)
        }
        return (out[0], out[1], out[2], out[3])
    }

    // MARK: Briques

    /// Saturation : 0 donne le noir et blanc, 1 ne change rien.
    static func saturation(_ s: Double) -> PhotoColorMatrix {
        let (lr, lg, lb) = luma
        return PhotoColorMatrix(values: [
            lr + s * (1 - lr), lg - s * lg, lb - s * lb, 0, 0,
            lr - s * lr, lg + s * (1 - lg), lb - s * lb, 0, 0,
            lr - s * lr, lg - s * lg, lb + s * (1 - lb), 0, 0,
            0, 0, 0, 1, 0,
        ])
    }

    /// Contraste autour du gris moyen 0,5.
    static func contrast(_ c: Double) -> PhotoColorMatrix {
        let offset = 0.5 * (1 - c)
        return PhotoColorMatrix(values: [
            c, 0, 0, 0, offset,
            0, c, 0, 0, offset,
            0, 0, c, 0, offset,
            0, 0, 0, 1, 0,
        ])
    }

    /// Gains par canal.
    static func gains(r: Double, g: Double, b: Double) -> PhotoColorMatrix {
        PhotoColorMatrix(values: [
            r, 0, 0, 0, 0,
            0, g, 0, 0, 0,
            0, 0, b, 0, 0,
            0, 0, 0, 1, 0,
        ])
    }

    /// Décalage ajouté aux trois canaux.
    static func offset(_ o: Double) -> PhotoColorMatrix {
        PhotoColorMatrix(values: [
            1, 0, 0, 0, o,
            0, 1, 0, 0, o,
            0, 0, 1, 0, o,
            0, 0, 0, 1, 0,
        ])
    }
}

/// Filtres prédéfinis (E2). Les couleurs font référence pour le web et Android :
/// toute modification d'une matrice change les pixels témoins des tests.
enum PhotoFilter: String, CaseIterable, Identifiable, Sendable {
    case none, vivid, warm, cool, soft, mono, noir

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .none: return "Original"
        case .vivid: return "Vif"
        case .warm: return "Chaud"
        case .cool: return "Froid"
        case .soft: return "Doux"
        case .mono: return "Mono"
        case .noir: return "Noir"
        }
    }

    var matrix: PhotoColorMatrix {
        typealias M = PhotoColorMatrix
        switch self {
        case .none: return .identity
        case .vivid: return M.saturation(1.35).then(.contrast(1.1))
        case .warm: return M.gains(r: 1.08, g: 1.0, b: 0.88)
        case .cool: return M.gains(r: 0.9, g: 1.0, b: 1.1)
        case .soft: return M.saturation(0.8).then(.contrast(0.85)).then(.offset(0.04))
        case .mono: return M.saturation(0)
        case .noir: return M.saturation(0).then(.contrast(1.35))
        }
    }
}

/// Réglages (E2), chacun de −1 à +1, 0 = inchangé.
struct PhotoAdjustments: Equatable, Sendable {
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var warmth: Double = 0

    enum Kind: CaseIterable, Identifiable {
        case brightness, contrast, saturation, warmth
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .brightness: return "Luminosité"
            case .contrast: return "Contraste"
            case .saturation: return "Saturation"
            case .warmth: return "Chaleur"
            }
        }

        var symbol: String {
            switch self {
            case .brightness: return "sun.max"
            case .contrast: return "circle.lefthalf.filled"
            case .saturation: return "drop"
            case .warmth: return "thermometer.medium"
            }
        }
    }

    subscript(kind: Kind) -> Double {
        get {
            switch kind {
            case .brightness: return brightness
            case .contrast: return contrast
            case .saturation: return saturation
            case .warmth: return warmth
            }
        }
        set {
            let value = min(max(newValue, -1), 1)
            switch kind {
            case .brightness: brightness = value
            case .contrast: contrast = value
            case .saturation: saturation = value
            case .warmth: warmth = value
            }
        }
    }

    var isNeutral: Bool { self == PhotoAdjustments() }

    /// Ordre fixe : chaleur, saturation, contraste, puis luminosité.
    var matrix: PhotoColorMatrix {
        PhotoColorMatrix.gains(r: 1 + 0.1 * warmth, g: 1, b: 1 - 0.1 * warmth)
            .then(.saturation(1 + saturation))
            .then(.contrast(1 + 0.5 * contrast))
            .then(.offset(0.2 * brightness))
    }
}

enum PhotoColor {
    /// Espace de travail sRGB gamma : la matrice voit les mêmes valeurs que sur le web.
    static let context: CIContext = {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) as Any
        return CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])
    }()

    /// Image droite passée par la matrice. Rendue telle quelle si la matrice est l'identité.
    static func render(_ image: UIImage, matrix: PhotoColorMatrix) -> UIImage {
        guard matrix != .identity, let source = upright(image) else { return image }
        let v = matrix.values.map { CGFloat($0) }
        let input = CIImage(cgImage: source)
        let filter = CIFilter(name: "CIColorMatrix")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(x: v[0], y: v[1], z: v[2], w: v[3]), forKey: "inputRVector")
        filter?.setValue(CIVector(x: v[5], y: v[6], z: v[7], w: v[8]), forKey: "inputGVector")
        filter?.setValue(CIVector(x: v[10], y: v[11], z: v[12], w: v[13]), forKey: "inputBVector")
        filter?.setValue(CIVector(x: v[15], y: v[16], z: v[17], w: v[18]), forKey: "inputAVector")
        filter?.setValue(CIVector(x: v[4], y: v[9], z: v[14], w: v[19]), forKey: "inputBiasVector")
        guard let output = filter?.outputImage?.clampedToExtent().cropped(to: input.extent)
                .applyingFilter("CIColorClamp"),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let rendered = context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: sRGB)
        else { return image }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: .up)
    }

    /// Petite copie pour les vignettes et l'aperçu, `longestSide` en pixels.
    static func thumbnail(_ image: UIImage, longestSide: CGFloat) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixels.width, pixels.height)
        guard longest > longestSide, longest > 0 else { return image }
        let size = CGSize(width: (pixels.width / longest * longestSide).rounded(),
                          height: (pixels.height / longest * longestSide).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

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
}
