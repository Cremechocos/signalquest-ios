import Foundation

/// Langue du compte (`POST /api/locale`). Le serveur rédige ses notifications
/// dans la langue enregistrée sur le compte, pas dans celle de l'appareil : sans
/// cet envoi, un iPhone en anglais recevrait les textes du site en français.
/// L'app n'a que deux langues : le français, et l'anglais pour tout le reste.
enum AccountLocaleSync {
    static var appLocale: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true ? "fr" : "en"
    }

    static func sentKey(ownerScopeId: String) -> String { "fr.signalquest.ios.accountLocale.\(ownerScopeId)" }

    /// `force` à la connexion, sinon seulement quand la langue de l'app diffère
    /// du dernier envoi réussi pour ce compte. Un échec réessaie au lancement suivant.
    static func sync(api: APIClient, force: Bool) async {
        guard let session = LocalAccountScope.sessionSnapshot() else { return }
        await sync(ownerScopeId: session.ownerScopeId, isCurrent: { session.isCurrent }, force: force) { locale in
            try await api.requestJSON("/api/locale", body: ["locale": locale])
        }
    }

    static func sync(
        ownerScopeId: String,
        locale: String = appLocale,
        isCurrent: () -> Bool,
        force: Bool,
        defaults: UserDefaults = .standard,
        send: (String) async throws -> Void
    ) async {
        let key = sentKey(ownerScopeId: ownerScopeId)
        guard force || defaults.string(forKey: key) != locale else { return }
        do {
            try await send(locale)
            guard isCurrent() else { return }
            defaults.set(locale, forKey: key)
        } catch {}
    }
}
