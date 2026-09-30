import Foundation

/// Ce qu'on a consulté récemment sur cet appareil : sites, lieux et profils,
/// vingt de chaque au plus, le plus récent d'abord (plan 3, vague 1).
///
/// Rien ne part au serveur. Chaque compte a son historique, effacé à sa
/// déconnexion ; un invité garde le sien jusqu'à ce qu'il l'efface. Les noms
/// sont ceux du moment de la consultation : ils peuvent vieillir,
/// l'identifiant fait foi.
enum RecentlyViewedStore {
    enum Kind: String, Codable, Sendable {
        case site, place, profile
    }

    struct Item: Codable, Equatable, Identifiable, Sendable {
        let kind: Kind
        /// Identifiant du site, du lieu ou du membre.
        let targetId: String
        /// Lieu : son nom ; membre : son nom affiché ; site : son adresse, vide
        /// sans adresse (l'écran le nomme alors par son numéro, dans la langue
        /// du moment).
        let title: String
        var subtitle: String?
        var latitude: Double?
        var longitude: Double?
        /// Site : marché de la carte lors de la consultation. La fiche se charge
        /// dans ce marché ; la carte ne la repropose donc que dans celui-ci.
        var market: String?
        /// Site : de quoi rouvrir la fiche avant que son détail réponde.
        var siteNumber: String?
        var anfrCode: String?
        var operators: [String]?
        var technologies: [String]?
        var owner: String?
        /// Membre.
        var handle: String?
        var avatarURL: URL?
        var viewedAt: Date

        var id: String { "\(kind.rawValue):\(targetId)" }
    }

    static let didChange = Notification.Name("SignalQuest.RecentlyViewedDidChange")
    static let maxPerKind = 20
    private static let prefix = "SignalQuest.RecentlyViewed.v1"

    private static func key(_ ownerScopeId: String) -> String {
        "\(prefix).\(LocalAccountScope.storageNamespace(for: ownerScopeId))"
    }

    static func items(
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) -> [Item] {
        guard let data = defaults.data(forKey: key(ownerScopeId)),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return list
    }

    static func record(
        _ item: Item,
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) {
        guard !item.targetId.isEmpty else { return }
        var list = items(ownerScopeId: ownerScopeId, defaults: defaults).filter { $0.id != item.id }
        list.insert(item, at: 0)
        // Vingt par sorte : une série de sites ne chasse pas les profils.
        var counts: [Kind: Int] = [:]
        list = list.filter { entry in
            counts[entry.kind, default: 0] += 1
            return counts[entry.kind, default: 0] <= maxPerKind
        }
        save(list, ownerScopeId: ownerScopeId, defaults: defaults)
    }

    /// Retire une entrée, par exemple un membre qu'on vient de bloquer.
    static func remove(
        _ kind: Kind,
        targetId: String,
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) {
        let list = items(ownerScopeId: ownerScopeId, defaults: defaults)
            .filter { !($0.kind == kind && $0.targetId == targetId) }
        save(list, ownerScopeId: ownerScopeId, defaults: defaults)
    }

    /// « Effacer » : chaque écran efface les sortes qu'il affiche.
    static func clear(
        _ kinds: Set<Kind>,
        ownerScopeId: String = LocalAccountScope.currentOwnerScopeId,
        defaults: UserDefaults = .standard
    ) {
        let list = items(ownerScopeId: ownerScopeId, defaults: defaults).filter { !kinds.contains($0.kind) }
        save(list, ownerScopeId: ownerScopeId, defaults: defaults)
    }

    /// À la déconnexion : l'historique appartient au compte qui s'en va.
    static func purge(ownerScopeId: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(ownerScopeId))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func save(_ list: [Item], ownerScopeId: String, defaults: UserDefaults) {
        if list.isEmpty {
            defaults.removeObject(forKey: key(ownerScopeId))
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key(ownerScopeId))
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

extension RecentlyViewedStore.Item {
    static func site(_ site: AntennaSite, market: String, viewedAt: Date = Date()) -> Self {
        Self(
            kind: .site, targetId: site.id, title: site.address ?? "",
            latitude: site.latitude, longitude: site.longitude, market: market,
            siteNumber: site.siteId, anfrCode: site.anfrCode, operators: site.operators,
            technologies: site.technologies, owner: site.owner, viewedAt: viewedAt
        )
    }

    static func place(_ place: PlaceResult, viewedAt: Date = Date()) -> Self {
        Self(
            kind: .place, targetId: place.id, title: place.name, subtitle: place.subtitle,
            latitude: place.latitude, longitude: place.longitude, viewedAt: viewedAt
        )
    }

    static func profile(
        id: String, name: String, handle: String?, avatarURL: URL?, viewedAt: Date = Date()
    ) -> Self {
        Self(kind: .profile, targetId: id, title: name, handle: handle, avatarURL: avatarURL, viewedAt: viewedAt)
    }

    /// Fiche rebâtie depuis l'historique. Secteurs et bandes arrivent avec le
    /// détail, que la fiche recharge à l'ouverture.
    var antennaSite: AntennaSite? {
        guard kind == .site else { return nil }
        return AntennaSite(
            id: targetId, siteId: siteNumber, anfrCode: anfrCode,
            latitude: latitude, longitude: longitude,
            operators: operators ?? [], technologies: technologies ?? [],
            bands: [], azimuths: [], sharingType: nil, crozonLeader: nil,
            address: title.isEmpty ? nil : title, height: nil, owner: owner
        )
    }

    var placeResult: PlaceResult? {
        guard kind == .place, let latitude, let longitude else { return nil }
        return PlaceResult(id: targetId, name: title, subtitle: subtitle, latitude: latitude, longitude: longitude)
    }
}
