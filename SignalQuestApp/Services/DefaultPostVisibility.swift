import Foundation
import Combine

/// Audience par défaut des nouveaux posts (contrat PRIVACY-DPV v1,
/// `docs/default-post-visibility-contract.md`, vecteur
/// `contracts/social/default-post-visibility-v1.json`).
///
/// Le serveur applique le réglage à la création de chaque post ; l'app ne fait
/// que le lire, le choisir et préremplir le composer avec lui.
enum DefaultPostVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case publicWorld = "public"
    case friends
    case privateOnly = "private"

    var id: String { rawValue }

    var label: String { DefaultPostVisibilityText.text("audience.\(rawValue)") }

    var icon: String {
        switch self {
        case .auto: "wand.and.stars"
        case .publicWorld: "globe"
        case .friends: "person.2.fill"
        case .privateOnly: "lock.fill"
        }
    }

    /// Audience préremplie dans le composer (§8) : « Automatique » vaut amis,
    /// comme un texte écrit à la main sans visibilité.
    var composerVisibility: SocialVisibility {
        switch self {
        case .publicWorld: .publicWorld
        case .privateOnly: .privateOnly
        case .auto, .friends: .friends
        }
    }

    /// La case « Appliquer aussi… » ne change rien avec « Automatique » (§7) :
    /// elle est masquée.
    var allowsApplyingToExistingPosts: Bool { self != .auto }

    /// Phrase sous le choix (§9) : celle de la case cochée remplace la phrase
    /// par défaut ; « Automatique » n'en a pas.
    func existingPostsNote(applying: Bool) -> String {
        guard applying, allowsApplyingToExistingPosts else { return DefaultPostVisibilityText.text("note.existingKept") }
        return DefaultPostVisibilityText.text("note.existingApplied.\(rawValue)")
    }
}

/// Réglage servi avec `include=posts` : valeur effective et « à demander ».
struct DefaultPostVisibilityState: Equatable, Sendable {
    let value: DefaultPostVisibility
    let pending: Bool
}

/// Réponse d'un PATCH du réglage. `appliedToExistingPosts` n'existe que si la
/// case était cochée (0 possible), à la racine du corps (§7).
struct DefaultPostVisibilityUpdate: Equatable, Sendable {
    let settings: SocialPrivacy
    let appliedToExistingPosts: Int?
}

/// Textes du §9, repris à l'octet du vecteur en tu, en vous et en anglais.
///
/// Ils vivent ici plutôt que dans le catalogue pour que le vecteur se rejoue
/// dans les trois formes quel que soit le simulateur, comme les phrases de
/// l'image d'un test d'expérience.
enum DefaultPostVisibilityText {
    enum Form: String, CaseIterable, Sendable {
        case frTu = "fr-tu", frVous = "fr-vous", en

        static var current: Self {
            guard Bundle.main.preferredLocalizations.first != "en" else { return .en }
            return SQAddress.isFormal ? .frVous : .frTu
        }
    }

    static func text(_ key: String, form: Form = .current) -> String {
        guard let entry = entries[key] else {
            assertionFailure("Clé DPV inconnue : \(key)")
            return key
        }
        switch form {
        case .frTu: return entry.0
        case .frVous: return entry.1
        case .en: return entry.2
        }
    }

    /// (fr-tu, fr-vous, en)
    static let entries: [String: (String, String, String)] = [
        "audience.auto": ("Automatique", "Automatique", "Automatic"),
        "audience.public": ("Public", "Public", "Public"),
        "audience.friends": ("Amis", "Amis", "Friends"),
        "audience.private": ("Privé", "Privé", "Private"),
        "note.privateZone": (
            "Dans une zone privée active, tes posts restent visibles de toi seul.",
            "Dans une zone privée active, vos posts restent visibles de vous seul.",
            "In an active private zone, your posts stay visible only to you."
        ),
        "note.existingKept": (
            "Tes publications déjà en ligne gardent leur audience.",
            "Vos publications déjà en ligne gardent leur audience.",
            "Your posts already online keep their audience."
        ),
        "note.existingApplied.public": (
            "Tes publications automatiques déjà en ligne passeront aussi en public, sauf celles dont tu as changé l'audience.",
            "Vos publications automatiques déjà en ligne passeront aussi en public, sauf celles dont vous avez changé l'audience.",
            "Your automatic posts already online will also become public, except those whose audience you changed."
        ),
        "note.existingApplied.friends": (
            "Tes publications automatiques déjà en ligne seront aussi réservées à tes amis, sauf celles dont tu as changé l'audience.",
            "Vos publications automatiques déjà en ligne seront aussi réservées à vos amis, sauf celles dont vous avez changé l'audience.",
            "Your automatic posts already online will also be limited to your friends, except those whose audience you changed."
        ),
        "note.existingApplied.private": (
            "Tes publications automatiques déjà en ligne passeront aussi en privé, sauf celles dont tu as changé l'audience.",
            "Vos publications automatiques déjà en ligne passeront aussi en privé, sauf celles dont vous avez changé l'audience.",
            "Your automatic posts already online will also become private, except those whose audience you changed."
        ),
        "choice.closeNote": (
            "Si tu fermes sans choisir, tes prochaines publications seront privées. Tu pourras changer ce choix plus tard dans les Réglages.",
            "Si vous fermez sans choisir, vos prochaines publications seront privées. Vous pourrez changer ce choix plus tard dans les Réglages.",
            "If you close without choosing, your next posts will be private. You can change this later in Settings."
        ),
        "error.applyRetry": (
            "La mise à jour de tes publications a pris trop de temps. Rien n'a changé : réessaie.",
            "La mise à jour de vos publications a pris trop de temps. Rien n'a changé : réessayez.",
            "Updating your posts took too long. Nothing changed: try again."
        ),
    ]

    /// Message d'un échec d'enregistrement : le 503 du §7 a sa phrase, le
    /// reste suit les messages habituels.
    static func failureMessage(_ error: Error) -> String {
        if case APIError.http(503, "PRIVACY_APPLY_RETRY"?, _, _, _) = error { return text("error.applyRetry") }
        return error.userFacingMessage
    }
}

/// Dernier réglage connu du compte, partagé par le fil (page de choix), le
/// composer (préremplissage) et Réglages › Confidentialité.
///
/// Rien n'est gardé sur disque : la page de choix ne s'ouvre que sur un GET
/// frais (§6), et le composer retombe sur amis tant que rien n'est chargé (§8).
@MainActor
final class DefaultPostVisibilityStore: ObservableObject {
    /// Par compte (`ownerScopeId`). Absent = pas encore lu.
    @Published private(set) var states: [String: DefaultPostVisibilityState] = [:]
    /// Comptes dont le serveur ne sert pas le réglage (ancien serveur) : ni
    /// page, ni lien vers le réglage.
    @Published private(set) var unsupportedOwners: Set<String> = []
    /// Le GET frais qui décide de la page n'a lieu qu'une fois par lancement.
    private var launchChecked: Set<String> = []

    func state(owner: String = LocalAccountScope.currentOwnerScopeId) -> DefaultPostVisibilityState? {
        states[owner]
    }

    func isUnsupported(owner: String = LocalAccountScope.currentOwnerScopeId) -> Bool {
        unsupportedOwners.contains(owner)
    }

    /// Audience préremplie d'un nouveau post : amis tant que rien n'est connu.
    func composerPrefill(owner: String = LocalAccountScope.currentOwnerScopeId) -> SocialVisibility {
        states[owner]?.value.composerVisibility ?? .friends
    }

    /// Enregistre ce qu'une réponse `include=posts` a servi.
    func record(_ settings: SocialPrivacy, owner: String) {
        if let value = settings.defaultPostVisibility, let pending = settings.defaultPostVisibilityPending {
            states[owner] = DefaultPostVisibilityState(value: value, pending: pending)
            unsupportedOwners.remove(owner)
        } else {
            states[owner] = nil
            unsupportedOwners.insert(owner)
        }
    }

    func needsLaunchCheck(owner: String) -> Bool { !launchChecked.contains(owner) }
    func markLaunchChecked(owner: String) { launchChecked.insert(owner) }
}
