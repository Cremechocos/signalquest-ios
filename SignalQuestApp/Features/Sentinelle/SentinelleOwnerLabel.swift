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
        /// Texte ENREGISTRÉ et partagé avec le web et Android : il reste en
        /// français quelle que soit la langue de l'app.
        let value: String
        let emoji: String
        var id: String { value }

        /// Texte AFFICHÉ sur la pastille, dans la langue de l'app.
        var title: String {
            switch value {
            case "Moi": return String(localized: "Moi")
            case "Mes parents": return String(localized: "Mes parents")
            case "Mes grands-parents": return String(localized: "Mes grands-parents")
            case "Mon enfant": return String(localized: "Mon enfant")
            case "Un ami": return String(localized: "Un ami")
            case "Ma résidence secondaire": return String(localized: "Ma résidence secondaire")
            case "Mon bureau": return String(localized: "Mon bureau")
            case "Mon association": return String(localized: "Mon association")
            default: return value
            }
        }
    }

    static let suggestions: [Suggestion] = [
        Suggestion(value: "Moi", emoji: "🏠"),
        Suggestion(value: "Mes parents", emoji: "👪"),
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
        "🏠", "👪", "👵", "🧒", "🙂", "🏖️", "💼", "🤝",
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
        return suggestions.filter { $0.value.lowercased().contains(needle) || $0.title.lowercased().contains(needle) }
    }
}
