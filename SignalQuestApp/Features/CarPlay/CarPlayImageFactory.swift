import CarPlay
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

    /// Pastille pleine, pour porter un verdict de couleur dans une liste.
    static func dot(color: UIColor, diameter: CGFloat = 24) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4))
        }
    }

    // MARK: - Dimensions

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
