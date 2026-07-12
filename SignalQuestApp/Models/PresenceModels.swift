import Foundation

/// Statut de présence sociale, aligné sur le contrat backend
/// (`/api/social/presence`) et le client Android. `invisible` masque la présence
/// sans couper les autres partages ; `offline` est publié best-effort à l'arrêt.
enum SocialPresenceStatus: String, Codable, Sendable, CaseIterable {
    case online
    case away
    case dnd
    case offline
    case invisible

    /// Libellé humain (fiche ami, réglages).
    var label: String {
        switch self {
        case .online: return "En ligne"
        case .away: return "Absent"
        case .dnd: return "Ne pas déranger"
        case .offline: return "Hors ligne"
        case .invisible: return "Invisible"
        }
    }
}

/// Mode de partage de la position en direct avec les amis. Réglage **local**
/// (comme Android `social_live_mode`), jamais transmis au backend : il pilote
/// seulement QUAND l'app publie, pas ce que le serveur re-sert.
enum LiveShareMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Position publiée uniquement pendant que la carte des amis est ouverte
    /// (défaut). Économe, aucune permission « Toujours » requise.
    case mapOpenOnly = "map_open_only"
    /// Position publiée en continu via un suivi de premier plan, même carte
    /// fermée. Exige la localisation « Toujours » + un usage background.
    case foregroundLive = "foreground_live"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mapOpenOnly: return "Carte ouverte seulement"
        case .foregroundLive: return "Continu en arrière-plan"
        }
    }

    var detail: String {
        switch self {
        case .mapOpenOnly:
            return "Ta position n'est partagée que lorsque tu consultes la carte des amis."
        case .foregroundLive:
            return "Ta position reste partagée même l'app fermée, tant que le partage est actif."
        }
    }
}

/// Persistance locale du mode de partage (UserDefaults). Défaut : carte-ouverte.
enum LiveShareModeStore {
    private static let key = "social_live_mode"

    static func load() -> LiveShareMode {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let mode = LiveShareMode(rawValue: raw) else {
            return .mapOpenOnly
        }
        return mode
    }

    static func save(_ mode: LiveShareMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }
}

// MARK: - Corps des requêtes d'émission

/// Coordonnées jointes à `POST /api/social/presence`. `accuracy`/`heading`/`speed`
/// omis quand indisponibles (le backend les traite comme null).
struct PresenceLocationPayload: Encodable, Sendable {
    let lat: Double
    let lng: Double
    let accuracy: Double?
    let heading: Double?
    let speed: Double?
}

/// `POST /api/social/presence`. Le serveur met à jour la présence + `lastSeenAt`,
/// puis stocke la position UNIQUEMENT si `shareLiveLocationWithFriends` est actif
/// (sinon il purge la position obsolète). On envoie tout de même le toggle miroir
/// côté client pour ne pas transmettre de coordonnées quand le partage est coupé.
struct PresencePublishRequest: Encodable, Sendable {
    let status: String
    let customStatus: String?
    let location: PresenceLocationPayload?
}

/// `POST /api/social/radio-snapshot`. iOS n'expose pas le signal radio brut
/// (RSRP/RSRQ…) : on ne transmet que la technologie et l'opérateur résolus par
/// `NetworkPathMonitor`, plus lat/lng pour que le serveur résolve la ville.
/// Gated serveur par `shareRadioDataWithFriends` (403 sinon).
struct RadioSnapshotPublishRequest: Encodable, Sendable {
    let technology: String?
    let `operator`: String?
    let lat: Double?
    let lng: Double?

    enum CodingKeys: String, CodingKey {
        case technology
        case `operator`
        case lat
        case lng
    }
}

/// Réponse de `POST /api/social/presence`. `observed`/`nextIntervalMs` pilotent le
/// « boost à la demande » : cadence rapide tant qu'un ami regarde ma position,
/// lente sinon. Champs absents sur un backend antérieur → l'app retombe sur ses
/// cadences par défaut (rétro-compatible).
struct PresenceAck: Decodable, Sendable {
    let ok: Bool?
    let observed: Bool?
    let nextIntervalMs: Int?
}
