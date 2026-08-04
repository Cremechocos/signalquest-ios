import Foundation

/// Extraction du jeton d'un lien de partage Sentinelle.
///
/// Port de `extractShareSlug` côté Android : les deux doivent accepter et
/// refuser les mêmes entrées, sans quoi un lien collé marcherait sur un
/// téléphone et pas sur l'autre.
///
/// Accepte l'URL complète (`https://signalquest.fr/sentinelle/p/AbC123`), avec
/// ou sans paramètres, et le code seul. Ce qu'on colle depuis un message traîne
/// souvent des espaces ou une ponctuation de fin de phrase : on ne le reproche
/// pas à l'utilisateur, on nettoie.
enum SentinelleShareLink {

    /// Renvoie `nil` si rien ne ressemble à un jeton — mieux vaut refuser tout
    /// de suite que d'envoyer au serveur une requête qui échouera en 404 sans
    /// dire pourquoi.
    static func extractSlug(_ input: String) -> String? {
        let trimmed = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,)>\"'"))
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if let range = trimmed.range(of: "/sentinelle/p/") {
            let tail = trimmed[range.upperBound...]
            candidate = String(tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        } else {
            candidate = String(trimmed.prefix { $0 != "?" && $0 != "#" })
        }

        // Un jeton est opaque et court. Ce garde-fou évite surtout qu'une phrase
        // entière parte telle quelle dans une URL de requête.
        guard !candidate.isEmpty, candidate.count <= 64 else { return nil }
        let allowed = candidate.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return allowed ? candidate : nil
    }
}

enum SentinelleShareLinkError: LocalizedError {
    case invalid

    var errorDescription: String? {
        String(localized: "Ce lien ne ressemble pas à un lien de partage Sentinelle.")
    }
}
