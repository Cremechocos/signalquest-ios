import CoreGraphics

/// Échelle de rayons. DA éditoriale = coins nets (la landing utilise 4px sur
/// les boutons, 6px sur les cartes). Valeurs volontairement plus petites que
/// le glassmorphism précédent.
enum SQRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 6
    static let lg: CGFloat = 8
    static let xl: CGFloat = 10
    static let xxl: CGFloat = 12
    static let pill: CGFloat = 999
}
