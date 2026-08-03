import SwiftUI
import UIKit

/// Le pictogramme d'antenne de l'app — un pylône et ses ondes.
///
/// `antenna.radiowaves.left.and.right`, le symbole système utilisé jusqu'ici,
/// ne montre PAS d'antenne : c'est un point qui émet, la même image que le Wi-Fi
/// ou le Bluetooth. Sur une carte où chaque marqueur EST un pylône, il ne
/// distingue rien et se confond avec les autres pastilles.
///
/// Celui-ci dessine ce qu'on cherche sur le terrain : un mât, ses haubans, et
/// deux arcs d'émission. Une seule géométrie, deux rendus — `Shape` pour SwiftUI,
/// `UIImage` pour les marqueurs MapKit, qui ne savent afficher qu'une image.
struct SQAntennaGlyph: Shape {
    /// Dessine les arcs d'émission. Désactivé, il ne reste que le pylône —
    /// utile quand le marqueur est petit et que les arcs deviennent du bruit.
    var showsWaves = true

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let centerX = rect.midX
        // Le mât occupe les deux tiers bas ; les arcs se déploient au-dessus.
        let baseY = rect.maxY
        let topY = rect.minY + height * (showsWaves ? 0.34 : 0.06)
        let halfBase = width * 0.19

        // Mât : un trapèze très étroit, plus large au sol.
        path.move(to: CGPoint(x: centerX - halfBase, y: baseY))
        path.addLine(to: CGPoint(x: centerX - width * 0.055, y: topY))
        path.addLine(to: CGPoint(x: centerX + width * 0.055, y: topY))
        path.addLine(to: CGPoint(x: centerX + halfBase, y: baseY))
        path.closeSubpath()

        // Deux traverses, qui donnent la lecture « pylône » plutôt que « poteau ».
        for ratio in [0.42, 0.68] as [CGFloat] {
            let y = topY + (baseY - topY) * ratio
            let halfWidth = halfBase * (0.38 + ratio * 0.62)
            path.move(to: CGPoint(x: centerX - halfWidth, y: y))
            path.addLine(to: CGPoint(x: centerX + halfWidth, y: y))
        }

        guard showsWaves else { return path }

        // Arcs d'émission, symétriques, ouverts vers le haut.
        for index in 0..<2 {
            let radius = width * (0.20 + CGFloat(index) * 0.15)
            let center = CGPoint(x: centerX, y: topY)
            path.addArc(
                center: center,
                radius: radius,
                startAngle: .degrees(202),
                endAngle: .degrees(338),
                clockwise: false
            )
        }
        return path
    }
}

extension SQAntennaGlyph {
    /// Rendu en image, pour les marqueurs MapKit (`MKAnnotationView` ne prend
    /// qu'une `UIImage`). Le trait est dessiné, pas rempli : à 13 pt un aplat
    /// écraserait les traverses et l'antenne redeviendrait une tache.
    static func image(size: CGFloat, color: UIColor, showsWaves: Bool = true) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.06, dy: size * 0.06)
            let path = SQAntennaGlyph(showsWaves: showsWaves).path(in: rect)
            let cg = context.cgContext
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(max(1.2, size * 0.09))
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.addPath(path.cgPath)
            cg.strokePath()
        }
    }
}

/// Marqueur d'antenne complet : pastille + pylône, et les azimuts en éventail.
///
/// Les azimuts sont dessinés AUTOUR de la pastille, pas en superposition sur la
/// carte : une carte de sélection montre une poignée de sites, et un secteur
/// plein de 320 m y masquerait les antennes voisines qu'on veut justement
/// comparer. Ici l'orientation se lit sans rien recouvrir.
struct SQAntennaMarker: View {
    var azimuths: [Double] = []
    var isSelected = false
    var tint: Color = SQColor.brandRed
    var diameter: CGFloat = 34
    /// Pictogramme au centre. Désactivé par défaut : sur une carte d'antennes,
    /// un glyphe d'antenne ne distingue rien — c'est la couleur (opérateur) et
    /// les lobes (orientation) qui portent l'information. Aligné sur le marqueur
    /// de la carte principale (`SQMapKitMarkerView`), qui est un point plein.
    var showsGlyph = false
    /// Portée des lobes, en multiples du diamètre.
    var reachRatio: CGFloat = 1.95

    var body: some View {
        ZStack {
            ForEach(Array(azimuths.enumerated()), id: \.offset) { _, azimuth in
                SQAzimuthWedge()
                    .fill(tint.opacity(isSelected ? 0.38 : 0.28))
                    .frame(width: diameter * reachRatio, height: diameter * reachRatio)
                    // 0° = nord géographique, et l'axe des Y d'un écran descend :
                    // une rotation directe suffit, le repère de la vue est déjà
                    // orienté nord-haut sur une carte non pivotée.
                    .rotationEffect(.degrees(azimuth))
            }
            Circle()
                .fill(tint)
                .frame(width: diameter, height: diameter)
                // Liseré crème CONSTANT : `onAccent`/`onInk` basculent au noir en
                // mode sombre (jetons de texte sur aplat), ce qui borderait le
                // point de noir sur la carte la nuit.
                .overlay(Circle().stroke(Color(hex: 0xFBF7EF), lineWidth: diameter * 0.09))
                .sqShadowSoft()
            if showsGlyph {
                SQAntennaGlyph()
                    .stroke(
                        SQColor.onAccent,
                        style: StrokeStyle(lineWidth: diameter * 0.075, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: diameter * 0.56, height: diameter * 0.56)
            }
        }
        .frame(width: diameter * reachRatio, height: diameter * reachRatio)
        .allowsHitTesting(true)
    }
}

/// Un secteur de 65°, pointe au centre — l'ouverture typique d'une antenne
/// panneau tri-secteur.
struct SQAzimuthWedge: Shape {
    var apertureDegrees: Double = 65

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // −90° : dans le repère écran, l'angle 0 pointe vers la droite alors
        // qu'un azimut de 0 désigne le nord.
        let start = Angle.degrees(-90 - apertureDegrees / 2)
        let end = Angle.degrees(-90 + apertureDegrees / 2)
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.closeSubpath()
        return path
    }
}
