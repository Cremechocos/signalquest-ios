import Foundation

/// Les écrans nourris par l'app Android — trajets enregistrés, Logs antennes,
/// identifications — ne s'affichent dans le Profil que si le compte a de telles
/// données (décision du 29/09, TRX-22). Sinon, une ligne les présente.
///
/// Règle prudente : on ne masque que si les trois sources disent « rien ».
/// Une erreur ou une réponse incomplète compte comme « peut-être » : cacher
/// par erreur des données de l'utilisateur serait pire qu'une ligne en trop.
@MainActor
final class AndroidDataPresence: ObservableObject {
    @Published private(set) var showsAndroidScreens: Bool

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: () -> Date
    /// Un « rien » se revérifie une fois par jour : les données peuvent
    /// arriver dès que l'app Android se synchronise.
    static let negativeLifetime: TimeInterval = 24 * 3600

    init(ownerScope: String, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.storageKey = "profile.androidData.\(ownerScope)"
        self.now = now
        // Aucune réponse connue : on montre, en attendant la vérification.
        showsAndroidScreens = (defaults.dictionary(forKey: storageKey)?["has"] as? Bool) ?? true
    }

    /// Décision pure (tests) : `nil` = inconnu.
    nonisolated static func hasAndroidData(sessionsTotal: Int?, identifications: Int?, hasLocalLogs: Bool) -> Bool {
        guard let sessionsTotal, let identifications else { return true }
        return sessionsTotal > 0 || identifications > 0 || hasLocalLogs
    }

    /// Vérifie au besoin. Un résultat positif est définitif pour ce compte ;
    /// un négatif est revérifié après `negativeLifetime`.
    func refresh(
        sessionsTotal: () async -> Int?,
        identifications: () async -> Int?,
        hasLocalLogs: () -> Bool
    ) async {
        if let cached = defaults.dictionary(forKey: storageKey), let has = cached["has"] as? Bool {
            if has { showsAndroidScreens = true; return }
            if let checkedAt = cached["at"] as? Date,
               now().timeIntervalSince(checkedAt) < Self.negativeLifetime {
                showsAndroidScreens = false
                return
            }
        }
        if hasLocalLogs() { remember(true); return }
        // La plus légère d'abord : un total de sessions suffit souvent.
        let sessions = await sessionsTotal()
        if let sessions, sessions > 0 { remember(true); return }
        let identified = await identifications()
        let has = Self.hasAndroidData(sessionsTotal: sessions, identifications: identified, hasLocalLogs: false)
        // Une réponse incomplète n'est pas mémorisée : on réessaiera.
        if sessions == nil || identified == nil {
            showsAndroidScreens = true
            return
        }
        remember(has)
    }

    private func remember(_ has: Bool) {
        showsAndroidScreens = has
        defaults.set(["has": has, "at": now()], forKey: storageKey)
    }
}
