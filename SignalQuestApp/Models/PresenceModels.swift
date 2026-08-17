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
        case .dnd: return String(localized: "Ne pas déranger")
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
    /// Position publiée en continu tant que l'app est ouverte au premier plan,
    /// même quand la carte des amis est fermée. Ne fonctionne PAS app fermée :
    /// la boucle de présence se suspend en arrière-plan (aucune autorisation
    /// « Toujours » n'est demandée), sauf pendant un Drive Test qui garde l'app
    /// active.
    case foregroundLive = "foreground_live"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mapOpenOnly: return String(localized: "Carte ouverte seulement")
        case .foregroundLive: return String(localized: "Continu (app ouverte)")
        }
    }

    var detail: String {
        switch self {
        case .mapOpenOnly:
            return String(localized: "Ta position n'est partagée que lorsque tu consultes la carte des amis.")
        case .foregroundLive:
            return String(localized: "Ta position reste partagée en continu tant que SignalQuest est ouverte, même sans consulter la carte des amis, ou pendant un Drive Test actif. Le partage se met en pause dès que l'app passe en arrière-plan.")
        }
    }
}

/// Persistance locale du mode de partage (UserDefaults). Défaut : carte-ouverte.
enum LiveShareModeStore {
    private static var key: String {
        "social_live_mode.\(LocalAccountScope.storageNamespace)"
    }

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

/// Préférence locale de présence, synchronisée best-effort par la boucle live.
/// Le serveur reste la source de vérité lorsqu'il répond au lancement.
enum SocialPresencePreferenceStore {
    private static var statusKey: String {
        "social_presence_status.\(LocalAccountScope.storageNamespace)"
    }
    private static var customStatusKey: String {
        "social_presence_custom_status.\(LocalAccountScope.storageNamespace)"
    }

    static func loadStatus() -> SocialPresenceStatus {
        guard let raw = UserDefaults.standard.string(forKey: statusKey),
              let status = SocialPresenceStatus(rawValue: raw),
              status != .offline else {
            return .online
        }
        return status
    }

    static func loadCustomStatus() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: customStatusKey) else { return nil }
        return String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)).nilIfBlank
    }

    static func save(status: SocialPresenceStatus, customStatus: String?) {
        if status != .offline { UserDefaults.standard.set(status.rawValue, forKey: statusKey) }
        let normalized = customStatus.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        }
        if let normalized, !normalized.isEmpty {
            UserDefaults.standard.set(normalized, forKey: customStatusKey)
        } else {
            UserDefaults.standard.removeObject(forKey: customStatusKey)
        }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
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
