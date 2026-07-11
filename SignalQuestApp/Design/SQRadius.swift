import CoreGraphics

/// Échelle de rayons. DA « Crème & Terre cuite » = grands arrondis doux :
/// 22 pt de référence sur les cartes, 14 pt sur les tuiles internes, capsules
/// (pill) pour tout ce qui se touche. Continuité `.continuous` partout.
enum SQRadius {
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 22
    static let xxl: CGFloat = 26
    static let pill: CGFloat = 999
}
