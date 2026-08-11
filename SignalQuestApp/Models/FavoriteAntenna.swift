import Foundation

/// Une antenne suivie.
///
/// Un favori n'est pas un marque-page : c'est une demande d'être prévenu. C'est la seule cohorte
/// que le serveur notifie AVANT confirmation d'une panne — les autres attendent que la communauté
/// corrobore, les favoris sont prévenus dès le premier signalement, parce qu'ils ont explicitement
/// demandé à suivre ce site.
struct FavoriteAntenna: Codable, Identifiable, Equatable {
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
    var id: String { "\(market):\(siteId)" }

    /// Ce qu'on affiche dans la liste. Le nom s'il existe, sinon l'adresse, sinon l'identifiant.
    var displayName: String {
        name?.nilIfBlank ?? address?.nilIfBlank ?? "Site \(siteId)"
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
struct FavoriteAntennasResponse: Decodable, Equatable {
    let favorites: [FavoriteAntenna]
    let notifyFavoriteAntennaIssuesPush: Bool?
}

/// `PUT /api/android/favorite-antennas`.
///
/// ⚠️ Le contrat serveur remplace la liste ENTIÈRE — il n'existe pas d'ajout ni de suppression
/// unitaire. Toute modification renvoie donc l'ensemble, ce qui impose au client de détenir la
/// liste à jour avant d'écrire : envoyer un ajout depuis un état périmé effacerait les favoris
/// ajoutés entre-temps sur un autre appareil.
struct FavoriteAntennasRequest: Encodable {
    let favorites: [FavoriteAntenna]
    let notifyFavoriteAntennaIssuesPush: Bool?
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
