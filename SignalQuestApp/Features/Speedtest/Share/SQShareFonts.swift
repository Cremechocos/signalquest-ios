import CoreText
import UIKit

/// Polices de la carte de partage — pendant iOS de `ShareFonts` (Android).
///
/// La carte doit être IDENTIQUE sur les deux plateformes. Android la compose en
/// **Sora** (masthead et chiffres de débit) et **JetBrains Mono** (kickers, bande
/// basse, pied technique) ; iOS n'embarquait ni l'une ni l'autre. Les deux fichiers
/// ont donc rejoint le bundle, réservés à cette image — l'interface continue
/// d'utiliser Figtree et Bricolage Grotesque.
///
/// ## Pourquoi ce n'est pas un simple `UIFont(name:size:)`
///
/// Ce sont des polices **variables** : un seul fichier porte tout l'axe de graisse
/// (`wght`, 100 à 800), et aucune instance nommée « Bold » n'existe dedans.
/// `Typeface.create(tf, weight, false)` d'Android règle l'axe nativement ; sur iOS
/// il faut le poser à la main via `kCTFontVariationAttribute`, sinon TOUTES les
/// graisses sortent en 400 et la carte perd la hiérarchie qui fait sa lisibilité —
/// un défaut qui ne lève aucune erreur et ne se voit qu'à l'œil sur l'image finale.
enum SQShareFonts {

    /// Identifiant de l'axe de graisse OpenType (`wght`), attendu en entier
    /// quatre octets par Core Text.
    private static let weightAxis: Int = 0x77676874   // 'w','g','h','t'

    /// Noms **PostScript**, et non noms de famille ni de fichier — les trois
    /// diffèrent ici. `UIFont(name:)` renvoie `nil` sur un nom de famille pour ces
    /// polices variables, ce qui provoquerait un repli silencieux sur Helvetica :
    ///
    /// | fichier                     | famille        | PostScript              |
    /// |-----------------------------|----------------|-------------------------|
    /// | `Sora-Variable.ttf`         | Sora           | `Sora-Regular`          |
    /// | `JetBrainsMono-Variable.ttf`| JetBrains Mono | `JetBrainsMono-Regular` |
    ///
    /// Le suffixe « Regular » ne fige rien : c'est l'instance par défaut du
    /// fichier variable, dont l'axe de graisse est ensuite déplacé ci-dessous.
    private static let soraPostScriptName = "Sora-Regular"
    private static let monoPostScriptName = "JetBrainsMono-Regular"

    /// Police d'affichage (Sora) à la graisse demandée.
    static func display(size: CGFloat, weight: CGFloat) -> UIFont {
        font(family: soraPostScriptName, size: size, weight: weight, fallback: .systemFont(ofSize: size, weight: .heavy))
    }

    /// Police à chasse fixe (JetBrains Mono) à la graisse demandée.
    static func mono(size: CGFloat, weight: CGFloat) -> UIFont {
        font(family: monoPostScriptName, size: size, weight: weight, fallback: .monospacedSystemFont(ofSize: size, weight: .regular))
    }

    /// Vrai si les deux polices sont réellement dans le bundle. Sert au test de
    /// non-régression : un `UIAppFonts` mal renseigné se traduirait par une carte
    /// composée en Helvetica, ce qu'aucune compilation ne signale.
    static var areEmbedded: Bool {
        UIFont(name: soraPostScriptName, size: 12) != nil && UIFont(name: monoPostScriptName, size: 12) != nil
    }

    private static func font(family: String, size: CGFloat, weight: CGFloat, fallback: UIFont) -> UIFont {
        guard let base = UIFont(name: family, size: size) else { return fallback }
        let descriptor = base.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [weightAxis: weight]
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
}
