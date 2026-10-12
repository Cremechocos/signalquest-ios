import CoreGraphics

/// Spacing scale token. Use everywhere padding/gap literals appear.
enum SQSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
    static let huge: CGFloat = 40
    /// Paliers intermédiaires (ex-calculs `xs + 2`, `sm + 2`, `md + 2`), à
    /// réserver aux ajustements d'une rangée ou d'une pastille.
    static let xs2: CGFloat = 6
    static let sm2: CGFloat = 10
    static let md2: CGFloat = 14
    /// Marge interne d'une carte de contenu (Halo, téléphone : 14 pt).
    static let cardPadding: CGFloat = 14
    /// Hauteur des boutons pilules (Halo, cible tactile : 44 pt ; 52 en mode terrain).
    static let primaryActionHeight: CGFloat = 44
}
