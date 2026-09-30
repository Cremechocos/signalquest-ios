import Foundation

/// Membres dont on ne veut plus voir les stories, sur cet appareil et par compte.
///
/// Local seulement : la sourdine du serveur (`/api/social/users/{id}/mute`)
/// masque à la fois les publications et les stories, alors qu'on ne masque ici
/// que les stories. Le nom affiché est gardé pour la liste des Préférences du
/// fil ; il peut vieillir, l'identifiant fait foi.
enum HiddenStoryAuthorsStore {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let authorId: String
        let displayName: String
        var id: String { authorId }
    }

    static let didChange = Notification.Name("SignalQuest.HiddenStoryAuthorsDidChange")
    static let maxEntries = 500
    private static let prefix = "SignalQuest.HiddenStoryAuthors.v1"

    private static func key(_ ownerScopeId: String) -> String {
        "\(prefix).\(LocalAccountScope.storageNamespace(for: ownerScopeId))"
    }

    static func entries(
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) -> [Entry] {
        guard ownerScopeId.hasPrefix("user:"),
              let data = defaults.data(forKey: key(ownerScopeId)),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    static func hiddenIds(
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) -> Set<String> {
        Set(entries(ownerScopeId: ownerScopeId, defaults: defaults).map(\.authorId))
    }

    static func hide(
        authorId: String,
        displayName: String,
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) {
        // Un invité n'a pas de compte auquel rattacher la préférence.
        guard ownerScopeId.hasPrefix("user:"), !authorId.isEmpty else { return }
        var list = entries(ownerScopeId: ownerScopeId, defaults: defaults).filter { $0.authorId != authorId }
        list.insert(Entry(authorId: authorId, displayName: displayName), at: 0)
        save(Array(list.prefix(maxEntries)), ownerScopeId: ownerScopeId, defaults: defaults)
    }

    static func unhide(
        authorId: String,
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) {
        guard ownerScopeId.hasPrefix("user:") else { return }
        let list = entries(ownerScopeId: ownerScopeId, defaults: defaults).filter { $0.authorId != authorId }
        save(list, ownerScopeId: ownerScopeId, defaults: defaults)
    }

    /// À la déconnexion : la préférence appartient au compte qui s'en va.
    static func purge(ownerScopeId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(ownerScopeId))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func save(_ list: [Entry], ownerScopeId: String, defaults: UserDefaults) {
        if list.isEmpty {
            defaults.removeObject(forKey: key(ownerScopeId))
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key(ownerScopeId))
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
