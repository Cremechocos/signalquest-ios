import Foundation

/// Une antenne suivie.
///
/// Un favori n'est pas un marque-page : c'est une demande d'être prévenu. C'est la seule cohorte
/// que le serveur notifie AVANT confirmation d'une panne — les autres attendent que la communauté
/// corrobore, les favoris sont prévenus dès le premier signalement, parce qu'ils ont explicitement
/// demandé à suivre ce site.
struct FavoriteAntenna: Codable, Identifiable, Equatable, Sendable {
    let siteId: String
    let market: String
    let `operator`: String?
    let name: String?
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let technologies: String?
    let updatedAt: String?

    /// Un site est suivi PAR MARCHÉ : le même identifiant peut exister en FR et au Canada.
    var id: String { Self.key(siteId: siteId, market: market) }

    static func key(siteId: String, market: String) -> String {
        let siteKey = siteId.filter { !$0.isWhitespace }.uppercased()
        return "\(market.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()):\(siteKey)"
    }

    /// Ce qu'on affiche dans la liste. Le nom s'il existe, sinon l'adresse, sinon l'identifiant.
    var displayName: String {
        name?.nilIfBlank ?? address?.nilIfBlank ?? String(localized: "Site \(siteId)")
    }

    init(
        siteId: String,
        market: String,
        operator: String?,
        name: String? = nil,
        address: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        technologies: String? = nil,
        updatedAt: String? = nil
    ) {
        self.siteId = siteId
        self.market = market
        self.operator = `operator`
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.technologies = technologies
        self.updatedAt = updatedAt
    }
}

/// `GET /api/android/favorite-antennas`.
///
/// La préférence de notification voyage AVEC la liste : le serveur la sert au même endroit parce
/// que suivre des antennes sans vouloir être prévenu n'a guère de sens, et l'écran a besoin des
/// deux pour se dessiner d'un seul appel.
struct FavoriteAntennasResponse: Decodable, Equatable, Sendable {
    let favorites: [FavoriteAntenna]
    let notifyFavoriteAntennaIssuesPush: Bool
    let revision: String
    let success: Bool?
    let idempotent: Bool?

    func validate() throws {
        guard !revision.isEmpty, favorites.count <= 500,
              Set(favorites.map(\.id)).count == favorites.count,
              favorites.allSatisfy({ !$0.siteId.filter { !$0.isWhitespace }.isEmpty && !$0.market.isEmpty }) else {
            throw APIError.decoding("invalid-favorites-snapshot")
        }
    }
}

/// Intention atomique durable. requestId est réutilisé après une perte de réponse
/// ou un redémarrage ; le reçu serveur empêche de rejouer un ancien ajout après
/// un retrait ultérieur effectué sur un autre appareil.
struct FavoriteAntennaIntent: Codable, Equatable, Sendable, Identifiable {
    enum Operation: String, Codable, Sendable { case upsert, remove, preferences }
    let requestId: String
    let operation: Operation
    let favorite: FavoriteAntenna?
    let siteId: String?
    let market: String?
    let notifyFavoriteAntennaIssuesPush: Bool?
    var id: String { requestId }
    var targetKey: String {
        if operation == .preferences { return "preferences" }
        return favorite?.id ?? FavoriteAntenna.key(siteId: siteId ?? "", market: market ?? "")
    }

    static func favorite(_ favorite: FavoriteAntenna, present: Bool) -> Self {
        Self(requestId: UUID().uuidString.lowercased(), operation: present ? .upsert : .remove,
            favorite: present ? favorite : nil, siteId: present ? nil : favorite.siteId,
            market: present ? nil : favorite.market, notifyFavoriteAntennaIssuesPush: nil)
    }

    static func notifications(_ enabled: Bool) -> Self {
        Self(requestId: UUID().uuidString.lowercased(), operation: .preferences, favorite: nil, siteId: nil,
            market: nil, notifyFavoriteAntennaIssuesPush: enabled)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
