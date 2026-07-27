import Foundation

/// Détecte le jeton `@…` ou `#…` en cours de frappe et applique le
/// remplacement.
///
/// Logique PURE, sans SwiftUI ni réseau : c'est la partie qui casse en silence.
/// Un jeton mal délimité insère la suggestion au mauvais endroit, découpe un mot
/// ou duplique le `@` — des défauts qu'aucune compilation ne signale et qu'un
/// test visuel rate une fois sur deux.
enum MentionAutocomplete {

    enum Kind: Equatable {
        case mention   // @pseudo
        case hashtag   // #tag

        var prefix: Character { self == .mention ? "@" : "#" }
    }

    struct Token: Equatable {
        let kind: Kind
        /// Texte saisi APRÈS le préfixe, sans le `@` ni le `#`.
        let query: String
        /// Plage du jeton complet, préfixe inclus.
        let range: Range<String.Index>
    }

    /// Longueur minimale avant d'interroger le serveur. Sous ce seuil, la
    /// requête ramènerait la moitié de la base pour rien.
    static let minimumQueryLength = 1

    /// Jeton actif à la position du curseur.
    ///
    /// `nil` dès que le curseur n'est plus dans un jeton — c'est ce qui ferme la
    /// liste de suggestions au bon moment. Un espace termine le jeton ; une
    /// adresse e-mail n'en ouvre pas (le `@` doit suivre un début de mot).
    static func activeToken(in text: String, cursor: String.Index) -> Token? {
        guard cursor <= text.endIndex else { return nil }
        var index = cursor
        var scanned = ""

        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]

            if character == "@" || character == "#" {
                // Le préfixe doit être en début de texte ou précédé d'une
                // séparation. Sans cette garde, « contact@site » proposerait des
                // mentions au milieu d'une adresse e-mail.
                let isStart = previous == text.startIndex
                let followsSeparator = !isStart && {
                    let before = text[text.index(before: previous)]
                    return before.isWhitespace || before.isNewline || before == "(" || before == "\n"
                }()
                guard isStart || followsSeparator else { return nil }
                return Token(
                    kind: character == "@" ? .mention : .hashtag,
                    query: String(scanned.reversed()),
                    range: previous..<cursor
                )
            }

            // Un jeton ne franchit ni espace ni saut de ligne.
            if character.isWhitespace || character.isNewline { return nil }
            // Ni ponctuation terminale : « @nora, » a fini d'être saisi.
            if character == "," || character == ";" || character == "." { return nil }

            scanned.append(character)
            index = previous
            // Garde-fou : au-delà, ce n'est plus un pseudo mais du texte.
            if scanned.count > 40 { return nil }
        }
        return nil
    }

    /// Remplace le jeton par la valeur choisie et renvoie le texte + la nouvelle
    /// position du curseur.
    ///
    /// Une espace est ajoutée après l'insertion : sans elle, la frappe suivante
    /// rouvrirait immédiatement la liste sur le jeton qu'on vient de compléter.
    static func apply(
        _ replacement: String,
        to text: String,
        token: Token
    ) -> (text: String, cursorOffset: Int) {
        let inserted = "\(token.kind.prefix)\(replacement) "
        var updated = text
        updated.replaceSubrange(token.range, with: inserted)
        let offset = text.distance(from: text.startIndex, to: token.range.lowerBound) + inserted.count
        return (updated, offset)
    }

    /// Extrait les pseudos mentionnés dans un texte finalisé, pour notifier les
    /// bonnes personnes à la publication.
    static func mentionedHandles(in text: String) -> [String] {
        var handles: [String] = []
        var current = ""
        var collecting = false
        var previous: Character?

        for character in text {
            if character == "@" {
                let atStart = previous == nil
                let afterSeparator = previous.map { $0.isWhitespace || $0.isNewline } ?? true
                collecting = atStart || afterSeparator
                current = ""
            } else if collecting {
                if character.isLetter || character.isNumber || character == "_" || character == "." || character == "-" {
                    current.append(character)
                } else {
                    if !current.isEmpty { handles.append(current) }
                    collecting = false
                    current = ""
                }
            }
            previous = character
        }
        if collecting, !current.isEmpty { handles.append(current) }
        // Dédoublonné en préservant l'ordre : mentionner deux fois la même
        // personne ne doit pas produire deux notifications.
        var seen = Set<String>()
        return handles.filter { seen.insert($0.lowercased()).inserted }
    }
}
