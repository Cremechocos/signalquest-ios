import CarPlay
import SwiftUI
import UIKit

/// Images dessinées pour l'écran du véhicule.
///
/// Le catalogue d'assets de l'app ne contient que le logo : tout le reste de
/// l'iconographie est en SF Symbols ou en SwiftUI, dont rien n'est utilisable
/// dans un template CarPlay. D'où ce générateur.
///
/// Deux familles, choisies par Alexandre sur planche (12/11) :
///
/// - les rangées de liste portent une **pastille douce** : le symbole SF à la
///   couleur du sens, dans un disque de la même teinte très allégée. C'est la
///   règle du design system (« icônes SF Symbols posées dans des pastilles
///   circulaires teintées »), qui remplace des disques pleins à l'encre tantôt
///   noire, tantôt blanche ;
/// - les épingles de la carte sont **le point de la carte iPhone** : pastille
///   pleine à la couleur de l'opérateur (camembert si le support est partagé),
///   liseré crème, ombre courte, anneau 5G, sans pictogramme pour une antenne.
///   Les autres couches gardent leur symbole (panne, projet, évolution).
///
/// CarPlay bascule en clair ou en sombre selon le VÉHICULE, pas selon
/// l'iPhone : chaque image réunit ses deux variantes (`dynamicImage`). Les
/// dimensions viennent de CarPlay, qui redimensionne le reste et le rend flou.
@MainActor
enum CarPlayImageFactory {
    /// Liseré des points, le crème de la carte iPhone (`SQMapKitMarkerView`).
    static let outlineColor = UIColor(red: 0xFB / 255, green: 0xF7 / 255, blue: 0xEF / 255, alpha: 1)

    // MARK: - Épingles

    /// Point d'antenne, comme sur la carte de l'iPhone.
    ///
    /// - Parameters:
    ///   - fills: une couleur par opérateur du support ; plusieurs = camembert.
    ///   - fiveG: le support émet en 5G → anneau fin à la couleur du premier
    ///     opérateur, comme l'anneau 5G de l'iPhone.
    ///   - selected: le point mis en avant par la liste. CarPlay publie une
    ///     taille plus grande ; le dessin reste le même, à l'échelle.
    static func antennaPin(fills: [UIColor], fiveG: Bool = false, selected: Bool = false) -> UIImage {
        let palette = fills.isEmpty ? [SQNetworkColors.unknownUIColor] : fills
        return pin(selected: selected, ring: fiveG ? palette[0] : nil) { style, rect in
            pie(palette.map { resolve($0, style) }, in: rect)
        }
    }

    /// Point d'une couche autre que les antennes : même point, rempli de la
    /// couleur de la couche (rouge d'une panne, ambre d'un projet…), et son
    /// symbole, pour qu'on sache ce que montre la carte sans relire son titre.
    static func symbolPin(color: UIColor, symbol: String, selected: Bool = false) -> UIImage {
        pin(selected: selected, ring: nil) { style, rect in
            let fill = resolve(color, style)
            fill.setFill()
            UIBezierPath(ovalIn: rect).fill()
            let configuration = UIImage.SymbolConfiguration(pointSize: rect.height * 0.46, weight: .bold)
            guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                .withTintColor(inkColor(on: fill), renderingMode: .alwaysOriginal) else { return }
            glyph.draw(in: centered(glyph.size, in: rect))
        }
    }

    /// Gabarit commun des points : liseré crème et ombre courte (22 % de noir,
    /// comme l'iPhone), centré sur le site, avec de la marge pour l'ombre et
    /// l'anneau 5G.
    private static func pin(selected: Bool, ring: UIColor?,
                            content: @escaping (UIUserInterfaceStyle, CGRect) -> Void) -> UIImage {
        let size = selected ? selectedPinSize : pinSize
        return dynamicImage { style in
            UIGraphicsImageRenderer(size: size).image { context in
                let cg = context.cgContext
                let side = min(size.width, size.height)
                let diameter = side * 0.6
                let border = max(2.5, side * 0.07)
                let rect = CGRect(x: size.width / 2 - diameter / 2, y: size.height / 2 - diameter / 2,
                                  width: diameter, height: diameter)
                if let ring {
                    resolve(ring, style).setStroke()
                    let path = UIBezierPath(ovalIn: rect.insetBy(dx: -border - 3, dy: -border - 3))
                    path.lineWidth = 2
                    path.stroke()
                }
                cg.saveGState()
                cg.setShadow(offset: CGSize(width: 0, height: side * 0.04), blur: side * 0.1,
                             color: UIColor.black.withAlphaComponent(0.22).cgColor)
                outlineColor.setFill()
                UIBezierPath(ovalIn: rect.insetBy(dx: -border, dy: -border)).fill()
                cg.restoreGState()
                content(style, rect)
            }
        }
    }

    // MARK: - Pastilles de liste

    /// Carmin Halo de l'app (`BrandRed`), clair et sombre.
    static var brandColor: UIColor {
        UIColor(named: "BrandRed") ?? SQNetworkColors.uiColor(0xA8123A)
    }

    /// Pastille douce : symbole SF à la couleur du sens, dans un disque de la
    /// même teinte allégée.
    ///
    /// - Parameter variableValue: remplissage d'un symbole variable
    ///   (`cellularbars`), pour que le nombre de barres dise le verdict.
    static func badge(fill: UIColor, symbol: String, variableValue: Double? = nil) -> UIImage {
        softDisc(tint: fill) { style, rect in
            let configuration = UIImage.SymbolConfiguration(pointSize: rect.height * 0.42, weight: .semibold)
            let symbolImage = variableValue.map {
                UIImage(systemName: symbol, variableValue: $0, configuration: configuration)
            } ?? UIImage(systemName: symbol, withConfiguration: configuration)
            guard let glyph = symbolImage?.withTintColor(glyphColor(for: fill, style: style),
                                                          renderingMode: .alwaysOriginal) else { return }
            glyph.draw(in: centered(glyph.size, in: rect))
        }
    }

    /// Pastille douce portant un texte court (« 5G »), à la couleur de sa
    /// génération.
    static func badge(fill: UIColor, text: String) -> UIImage {
        softDisc(tint: fill) { style, rect in
            let font = UIFont.systemFont(ofSize: rect.height * (text.count > 2 ? 0.3 : 0.36), weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: glyphColor(for: fill, style: style),
            ]
            let string = text as NSString
            string.draw(in: centered(string.size(withAttributes: attributes), in: rect), withAttributes: attributes)
        }
    }

    /// Pastille d'antenne pour une rangée : le point de la carte (couleur ou
    /// camembert des opérateurs, liseré crème) posé dans une pastille neutre.
    /// On reconnaît l'antenne comme sur la carte, sans pictogramme.
    static func operatorBadge(fills: [UIColor]) -> UIImage {
        let palette = fills.isEmpty ? [SQNetworkColors.unknownUIColor] : fills
        return softDisc(tint: .systemGray) { style, rect in
            let dot = rect.insetBy(dx: rect.width * 0.22, dy: rect.height * 0.22)
            let border = max(2, rect.width * 0.055)
            guard let cg = UIGraphicsGetCurrentContext() else { return }
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                         color: UIColor.black.withAlphaComponent(0.2).cgColor)
            outlineColor.setFill()
            UIBezierPath(ovalIn: dot.insetBy(dx: -border, dy: -border)).fill()
            cg.restoreGState()
            pie(palette.map { resolve($0, style) }, in: dot)
        }
    }

    /// Encre lisible sur un fond plein, au seuil WCAG de l'app (symbole d'un point).
    static func inkColor(on fill: UIColor) -> UIColor {
        UIColor(SQBrand.operatorBadgeForeground(for: Color(uiColor: fill), colorScheme: .light))
    }

    /// Couleur du symbole d'une pastille douce : la teinte elle-même, assombrie
    /// en clair ou éclaircie en sombre jusqu'à 4,5:1 sur la pastille. Le jaune
    /// « Moyen » ne se lirait pas tel quel sur un fond clair.
    static func glyphColor(for tint: UIColor, style: UIUserInterfaceStyle) -> UIColor {
        let base = resolve(tint, style)
        let backdrop = softBackdrop(for: base, style: style)
        let target: UIColor = style == .dark ? .white : .black
        var color = base
        var step: CGFloat = 0
        while contrast(color, backdrop) < 4.5 && step < 1 {
            step += 0.05
            color = mix(base, target, step)
        }
        return color
    }

    /// Ce sur quoi se lit le symbole : la teinte allégée posée sur le fond des
    /// rangées CarPlay (gris très clair en clair, gris anthracite en sombre,
    /// relevés au CarPlay Simulator).
    static func softBackdrop(for tint: UIColor, style: UIUserInterfaceStyle) -> UIColor {
        let row = style == .dark
            ? UIColor(red: 0.17, green: 0.18, blue: 0.20, alpha: 1)
            : UIColor(white: 0.95, alpha: 1)
        return mix(row, resolve(tint, style), softAlpha(style))
    }

    private static func softAlpha(_ style: UIUserInterfaceStyle) -> CGFloat { style == .dark ? 0.26 : 0.16 }

    private static func softDisc(tint: UIColor,
                                 content: @escaping (UIUserInterfaceStyle, CGRect) -> Void) -> UIImage {
        let size = listImageSize
        return dynamicImage { style in
            UIGraphicsImageRenderer(size: size).image { _ in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.04, dy: size.height * 0.04)
                resolve(tint, style).withAlphaComponent(softAlpha(style)).setFill()
                UIBezierPath(ovalIn: rect).fill()
                content(style, rect)
            }
        }
    }

    // MARK: - Outils

    /// Une part par couleur, la première en haut.
    private static func pie(_ fills: [UIColor], in rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let step = 2 * CGFloat.pi / CGFloat(max(fills.count, 1))
        for (index, color) in fills.enumerated() {
            let start = -CGFloat.pi / 2 + step * CGFloat(index)
            let wedge = UIBezierPath()
            wedge.move(to: center)
            wedge.addArc(withCenter: center, radius: rect.width / 2,
                         startAngle: start, endAngle: start + step, clockwise: true)
            wedge.close()
            color.setFill()
            wedge.fill()
        }
    }

    private static func resolve(_ color: UIColor, _ style: UIUserInterfaceStyle) -> UIColor {
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private static func mix(_ from: UIColor, _ to: UIColor, _ amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        from.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        to.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                       blue: b1 + (b2 - b1) * amount, alpha: 1)
    }

    /// Rapport de contraste WCAG entre deux couleurs opaques.
    static func contrast(_ first: UIColor, _ second: UIColor) -> CGFloat {
        func luminance(_ color: UIColor) -> CGFloat {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            func linear(_ channel: CGFloat) -> CGFloat {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Variante claire et sombre réunies : CarPlay suit l'apparence du
    /// VÉHICULE, et une couleur dynamique (le carmin) n'a pas la même valeur
    /// dans les deux.
    private static func dynamicImage(_ render: (UIUserInterfaceStyle) -> UIImage) -> UIImage {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let asset = UIImageAsset()
        asset.register(render(.light), with: light)
        asset.register(render(.dark), with: UITraitCollection(userInterfaceStyle: .dark))
        return asset.image(with: light)
    }

    private static func centered(_ size: CGSize, in rect: CGRect) -> CGRect {
        CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
               width: size.width, height: size.height)
    }

    // MARK: - Dimensions

    /// Taille d'image d'une rangée de liste, publiée par CarPlay.
    static var listImageSize: CGSize {
        let published = CPListItem.maximumImageSize
        return published.width > 0 ? published : CGSize(width: 44, height: 44)
    }

    /// CarPlay publie les tailles attendues, mais elles valent `.zero` hors d'un
    /// véhicule connecté — en test, notamment. Le repli garde un dessin correct
    /// plutôt qu'un renderer à zéro, qui lèverait une exception.
    private static var pinSize: CGSize {
        let published = CPPointOfInterest.pinImageSize
        return published.width > 0 ? published : CGSize(width: 44, height: 44)
    }

    private static var selectedPinSize: CGSize {
        let published = CPPointOfInterest.selectedPinImageSize
        return published.width > 0 ? published : CGSize(width: 64, height: 64)
    }
}
