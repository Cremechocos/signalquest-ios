import Foundation

/// Sentinelle — à qui appartient une connexion surveillée.
///
/// Port de `apps/web/lib/sentinelle/owner-label.ts`. Les trois listes — web,
/// Android, iOS — doivent rester identiques : une box attribuée « Mes parents »
/// depuis l'iPhone doit produire la même phrase sur la page partagée, qui est
/// rendue par le web.
///
/// Ce champ existe pour une raison de langue, pas de rangement : le verdict dit
/// « Votre connexion est en ligne », ce qui est juste chez soi et FAUX sur un
/// lien partagé, où celui qui lit regarde la connexion de quelqu'un d'autre.
enum SentinelleOwnerLabel {

    static let labelMax = 40

    struct Suggestion: Identifiable, Hashable, Sendable {
        let value: String
        let emoji: String
        var id: String { value }
    }

    static let suggestions: [Suggestion] = [
        Suggestion(value: "Moi", emoji: "🏠"),
        Suggestion(value: "Mes parents", emoji: "👨‍👩‍👦"),
        Suggestion(value: "Mes grands-parents", emoji: "👵"),
        Suggestion(value: "Mon enfant", emoji: "🧒"),
        Suggestion(value: "Un ami", emoji: "🙂"),
        Suggestion(value: "Ma résidence secondaire", emoji: "🏖️"),
        Suggestion(value: "Mon bureau", emoji: "💼"),
        Suggestion(value: "Mon association", emoji: "🤝"),
    ]

    /// Palette du sélecteur, volontairement COURTE : un sélecteur d'emoji
    /// complet est un composant à lui seul, et l'objet ici est de repérer une
    /// box d'un coup d'œil dans une liste, pas de s'exprimer.
    static let emojiPalette: [String] = [
        "🏠", "👨‍👩‍👦", "👵", "🧒", "🙂", "🏖️", "💼", "🤝",
        "🏡", "🏢", "🛖", "⛺", "🚐", "🐈", "🐕", "🌱",
        "📚", "🎮", "🎣", "⚓", "🍇", "☕",
    ]

    /// Espaces rognés, longueur bornée, vide = non renseigné.
    static func normalise(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(labelMax))
    }

    /// Les suggestions qui contiennent la saisie ; toutes si elle est vide.
    static func filter(_ query: String) -> [Suggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return suggestions }
        return suggestions.filter { $0.value.lowercased().contains(needle) }
    }
}
