import CarPlay
import SwiftUI
import UIKit

/// Images dessinées pour l'écran du véhicule.
///
/// Le catalogue d'assets de l'app ne contient que le logo : tout le reste de
/// l'iconographie est en SF Symbols ou en SwiftUI, dont rien n'est utilisable
/// dans un template CarPlay. D'où ce générateur — même approche que la pastille
/// d'état Sentinelle, qui faisait déjà cela dans son coin.
///
/// Deux contraintes dictent les choix de dessin :
///
/// - CarPlay bascule en clair ou en sombre selon le VÉHICULE, pas selon
///   l'iPhone, et le fond de carte change avec lui. Une épingle doit donc se
///   détacher des deux : d'où la pastille pleine cerclée de blanc, plutôt qu'un
///   glyphe teinté posé à nu qui disparaîtrait sur l'un des deux fonds.
/// - Les dimensions ne sont pas libres. CarPlay redimensionne ce qu'on lui
///   donne, et une image dessinée à la mauvaise taille arrive floue sur un
///   écran de voiture.
@MainActor
enum CarPlayImageFactory {
    /// Épingle d'antenne à la couleur de son opérateur.
    ///
    /// - Parameter selected: l'épingle mise en avant par le carrousel. Plus
    ///   grande et plus contrastée, parce qu'elle doit se repérer sans être
    ///   cherchée.
    static func antennaPin(color: UIColor, selected: Bool = false) -> UIImage {
        let size = selected ? selectedPinSize : pinSize
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let inset = size.width * 0.08
            let disc = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)

            // Halo blanc : sans lui, une épingle sombre se perd sur un fond de
            // carte sombre, et une claire sur un fond clair.
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: disc.insetBy(dx: -inset * 0.75, dy: -inset * 0.75))

            cg.setFillColor(color.cgColor)
            cg.fillEllipse(in: disc)

            // Glyphe maison, en blanc : c'est ce qui rend l'épingle
            // reconnaissable comme SignalQuest plutôt que comme un point
            // générique. Les arcs disparaissent sur la petite taille, où ils ne
            // seraient plus qu'un pâté.
            let glyphSide = disc.width * 0.62
            let glyph = SQAntennaGlyph.image(size: glyphSide, color: .white,
                                             showsWaves: selected)
            glyph.draw(in: CGRect(
                x: disc.midX - glyphSide / 2,
                y: disc.midY - glyphSide / 2,
                width: glyphSide,
                height: glyphSide
            ))
        }
    }

    /// Épingle d'une couche autre que les antennes : même pastille cerclée de
    /// blanc, mais un symbole SF à la place du glyphe maison (triangle d'une
    /// panne, coche d'une mise en service…), pour qu'on sache ce que montre la
    /// carte sans relire son titre. Encre noire ou blanche selon le fond, en
    /// variantes claire et sombre : le jaune d'un projet ne porte pas de blanc.
    static func symbolPin(color: UIColor, symbol: String, selected: Bool = false) -> UIImage {
        let size = selected ? selectedPinSize : pinSize
        return dynamicImage { style in
            let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            return UIGraphicsImageRenderer(size: size).image { context in
                let cg = context.cgContext
                let inset = size.width * 0.08
                let disc = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                cg.setFillColor(UIColor.white.cgColor)
                cg.fillEllipse(in: disc.insetBy(dx: -inset * 0.75, dy: -inset * 0.75))
                cg.setFillColor(resolved.cgColor)
                cg.fillEllipse(in: disc)
                let configuration = UIImage.SymbolConfiguration(pointSize: disc.height * 0.42, weight: .bold)
                guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                    .withTintColor(inkColor(on: resolved), renderingMode: .alwaysOriginal) else { return }
                glyph.draw(in: centered(glyph.size, in: disc))
            }
        }
    }

    /// Pastille pleine, pour porter un verdict de couleur dans une liste.
    static func dot(color: UIColor, diameter: CGFloat = 24) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4))
        }
    }

    // MARK: - Pastilles de liste

    /// Carmin Halo de l'app (`BrandRed`), clair et sombre.
    static var brandColor: UIColor {
        UIColor(named: "BrandRed") ?? SQNetworkColors.uiColor(0xA8123A)
    }

    /// Pastille de rangée : disque plein et symbole SF centré.
    ///
    /// L'encre (noire ou blanche) suit la luminance du fond : un glyphe blanc
    /// sur le jaune « Moyen » ne se lirait pas.
    ///
    /// - Parameter variableValue: remplissage d'un symbole variable
    ///   (`cellularbars`), pour que le nombre de barres dise le verdict.
    static func badge(fill: UIColor, symbol: String, variableValue: Double? = nil) -> UIImage {
        dynamicImage { style in
            let resolved = fill.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            return disc(fill: resolved) { rect in
                let configuration = UIImage.SymbolConfiguration(pointSize: rect.height * 0.42, weight: .semibold)
                let symbolImage = variableValue.map {
                    UIImage(systemName: symbol, variableValue: $0, configuration: configuration)
                } ?? UIImage(systemName: symbol, withConfiguration: configuration)
                guard let glyph = symbolImage?.withTintColor(inkColor(on: resolved), renderingMode: .alwaysOriginal)
                else { return }
                glyph.draw(in: centered(glyph.size, in: rect))
            }
        }
    }

    /// Pastille portant un texte court (« 5G »), à la couleur de sa génération.
    static func badge(fill: UIColor, text: String) -> UIImage {
        dynamicImage { style in
            let resolved = fill.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            return disc(fill: resolved) { rect in
                let font = UIFont.systemFont(ofSize: rect.height * (text.count > 2 ? 0.3 : 0.38), weight: .bold)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: inkColor(on: resolved),
                ]
                let string = text as NSString
                string.draw(in: centered(string.size(withAttributes: attributes), in: rect),
                            withAttributes: attributes)
            }
        }
    }

    /// Pastille d'antenne pour une rangée : une part par opérateur sur un
    /// support partagé, glyphe maison par-dessus.
    static func operatorBadge(fills: [UIColor], ink: UIColor) -> UIImage {
        let size = listImageSize
        let palette = fills.isEmpty ? [SQNetworkColors.unknownUIColor] : fills
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.04, dy: size.height * 0.04)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let step = 2 * CGFloat.pi / CGFloat(palette.count)
            for (index, color) in palette.enumerated() {
                let start = -CGFloat.pi / 2 + step * CGFloat(index)
                let wedge = UIBezierPath()
                wedge.move(to: center)
                wedge.addArc(withCenter: center, radius: rect.width / 2,
                             startAngle: start, endAngle: start + step, clockwise: true)
                wedge.close()
                color.setFill()
                wedge.fill()
            }
            let side = rect.width * 0.58
            SQAntennaGlyph.image(size: side, color: ink, showsWaves: true)
                .draw(in: centered(CGSize(width: side, height: side), in: rect))
        }
    }

    /// Encre lisible sur un fond donné, au seuil WCAG de l'app.
    static func inkColor(on fill: UIColor) -> UIColor {
        UIColor(SQBrand.operatorBadgeForeground(for: Color(uiColor: fill), colorScheme: .light))
    }

    private static func disc(fill: UIColor, content: (CGRect) -> Void) -> UIImage {
        let size = listImageSize
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.04, dy: size.height * 0.04)
            fill.setFill()
            UIBezierPath(ovalIn: rect).fill()
            content(rect)
        }
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
