import SwiftUI

/// Réaction du Feed : le serveur stocke un emoji, l'app dessine un symbole SF
/// (Halo : symboles plutôt qu'emojis, lot F, F-27). L'emoji reste la valeur
/// envoyée et lue, pour rester compatible avec Android, le Web et l'existant.
enum FeedReaction: String, CaseIterable {
    case like = "❤️"
    case fire = "🔥"
    case clap = "👏"
    case rocket = "🚀"
    case bolt = "⚡"
    case antenna = "📡"

    /// Emoji stocké → réaction connue, avec ou sans sélecteur de variante (U+FE0F).
    init?(emoji: String) {
        let bare = { (value: String) in value.unicodeScalars.filter { $0.value != 0xFE0F }.map(String.init).joined() }
        guard let match = Self.allCases.first(where: { bare($0.rawValue) == bare(emoji) }) else { return nil }
        self = match
    }

    var symbol: String {
        switch self {
        case .like: "heart.fill"
        case .fire: "flame.fill"
        case .clap: "hands.clap.fill"
        // Pas de fusée parmi les symboles SF : le compteur dit « rapide ».
        case .rocket: "speedometer"
        case .bolt: "bolt.fill"
        case .antenna: "antenna.radiowaves.left.and.right"
        }
    }

    var name: String {
        switch self {
        case .like: String(localized: "J’aime")
        case .fire: String(localized: "Génial")
        case .clap: String(localized: "Bravo")
        case .rocket: String(localized: "Rapide")
        case .bolt: String(localized: "Fulgurant")
        case .antenna: String(localized: "Bon réseau")
        }
    }

    var tint: Color { self == .like ? SQColor.like : SQColor.accentInk }

    /// Symbole d'un emoji stocké quelconque : un emoji posé par une autre app
    /// et inconnu ici reste compté, sous un visage neutre.
    static func symbol(for emoji: String) -> String {
        FeedReaction(emoji: emoji)?.symbol ?? "face.smiling"
    }

    static func name(for emoji: String) -> String {
        FeedReaction(emoji: emoji)?.name ?? String(localized: "Autre réaction")
    }
}
