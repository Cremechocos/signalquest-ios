import Foundation

/// Identité membre v1 (contrat serveur `docs/contracts/user-identity-v1.md`, 13/11) :
/// le nom d'utilisateur (`handle`) est unique et public, le nom affiché (`name`) facultatif.
enum MemberIdentity {
    /// Repli d'affichage commun à toute l'app : nom affiché, sinon « @nom d'utilisateur ».
    /// `nil` quand le membre n'a ni l'un ni l'autre : l'appelant choisit sa formule, souvent
    /// `someone`. Jamais l'e-mail d'un autre membre.
    static func name(_ name: String?, handle: String?) -> String? {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        guard let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else { return nil }
        return handle.hasPrefix("@") ? handle : "@\(handle)"
    }

    /// Le nom lu partout : nom affiché, sinon « @nom d'utilisateur », sinon « Quelqu'un ».
    static func displayName(_ name: String?, handle: String?) -> String {
        self.name(name, handle: handle) ?? someone
    }

    static var someone: String { String(localized: "Quelqu’un") }
}

/// Nom d'utilisateur : la normalisation du serveur (`normalizeUserHandle`), reprise à
/// l'identique et vérifiée sur les vecteurs partagés `user-handle-vectors.json`.
enum UserHandle {
    static let minLength = 2
    static let maxLength = 32

    /// Transforme au lieu de refuser : bords et « @ » de tête retirés, minuscules, accents
    /// retirés, toute autre suite de caractères devient « - », « - . _ » retirés en bord,
    /// coupe à 32 caractères PUIS retrait des « - . _ » de fin.
    static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        let withoutAt = String(String.UnicodeScalarView(trimmed.drop { $0 == "@" }))
        var result = ""
        var inRun = false
        for scalar in withoutAt.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            // Diacritiques combinants (U+0300 à U+036F) : « é » décomposé devient « e ».
            if (0x300...0x36F).contains(scalar.value) { continue }
            if isAllowed(scalar) {
                result.unicodeScalars.append(scalar)
                inRun = false
            } else if !inRun {
                result.append("-")
                inRun = true
            }
        }
        let separators: Set<Character> = ["-", ".", "_"]
        while let first = result.first, separators.contains(first) { result.removeFirst() }
        while let last = result.last, separators.contains(last) { result.removeLast() }
        result = String(result.prefix(maxLength))
        while let last = result.last, separators.contains(last) { result.removeLast() }
        return result
    }

    /// Valide une forme déjà normalisée : 2 à 32 caractères.
    static func isValid(normalized: String) -> Bool {
        (minLength...maxLength).contains(normalized.count)
    }

    /// Lien public du profil, montré sous le champ.
    static func profileLink(_ normalized: String) -> String { "signalquest.fr/u/\(normalized)" }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x61...0x7A, 0x30...0x39: return true // a-z, 0-9
        case 0x2D, 0x2E, 0x5F: return true // - . _
        default: return false
        }
    }
}
