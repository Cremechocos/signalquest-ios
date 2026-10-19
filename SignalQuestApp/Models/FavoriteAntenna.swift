import Foundation

/// Une antenne suivie.
///
/// Un suivi n'est pas un marque-page : c'est une demande d'être prévenu. Il vise un site ET un
/// opérateur : un pylône partagé se suit opérateur par opérateur, depuis la fiche de chacun. La
/// liste vient de `/api/me/follows` (suivis de sites) ; les anciens favoris restent lisibles dans
/// le cache disque tant que cette liste n'a pas été relue.
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
    /// Clé canonique du site côté serveur, quand il la donne : deux alias d'un même support
    /// (code ANFR, numéro de support) mènent au même suivi.
    let siteKey: String?

    /// Un site est suivi PAR MARCHÉ : le même identifiant peut exister en FR et au Canada.
    var id: String { Self.key(siteId: siteId, market: market) }

    /// Un suivi est propre à un opérateur : le même site suivi chez deux opérateurs donne deux lignes.
    var followKey: String { Self.followKey(siteId: siteId, market: market, operator: `operator`) }

    /// Le site (marché compris) correspond à cette clé, par son identifiant ou par sa clé canonique.
    func isSameSite(key target: String) -> Bool {
        id == target || siteKey.map { Self.key(siteId: $0, market: market) == target } == true
    }

    /// Ce suivi porte sur ce site ET sur cet opérateur.
    func isFollowed(siteKey target: String, operator other: String?) -> Bool {
        isSameSite(key: target) && Self.operatorToken(`operator`) == Self.operatorToken(other)
    }

    /// « ORANGE », « Bouygues Telecom » et « bouygues-telecom » désignent le même opérateur.
    static func operatorToken(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .replacingOccurrences(of: "[\\s-]+", with: "_", options: .regularExpression)
    }

    /// Un suivi vise un opérateur précis : l'absence d'opérateur et « ALL » n'en désignent aucun.
    static func isFollowableOperator(_ value: String?) -> Bool {
        let token = operatorToken(value)
        return !token.isEmpty && token != "ALL"
    }

    static func followKey(siteId: String, market: String, operator: String?) -> String {
        "\(key(siteId: siteId, market: market))|\(operatorToken(`operator`))"
    }

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
        updatedAt: String? = nil,
        siteKey: String? = nil
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
        self.siteKey = siteKey
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
///
/// `upsert`, `remove` et `preferences` sont les écritures de l'ancienne passerelle : elles ne
/// servent plus qu'à vider les intentions déjà en file avant la bascule vers les suivis de sites.
/// `follow` et `unfollow` sont les gestes d'aujourd'hui (`/api/me/follows`), propres à un opérateur.
struct FavoriteAntennaIntent: Codable, Equatable, Sendable, Identifiable {
    enum Operation: String, Codable, Sendable { case upsert, remove, preferences, follow, unfollow }
    let requestId: String
    let operation: Operation
    let favorite: FavoriteAntenna?
    let siteId: String?
    let market: String?
    let notifyFavoriteAntennaIssuesPush: Bool?
    var id: String { requestId }
    var targetKey: String {
        switch operation {
        case .preferences: return "preferences"
        case .follow, .unfollow: return favorite?.followKey ?? ""
        case .upsert, .remove: return siteKey
        }
    }
    /// Le site visé, sans l'opérateur : la clé des intentions de l'ancienne passerelle.
    var siteKey: String {
        favorite?.id ?? FavoriteAntenna.key(siteId: siteId ?? "", market: market ?? "")
    }

    static func favorite(_ favorite: FavoriteAntenna, present: Bool) -> Self {
        Self(requestId: UUID().uuidString.lowercased(), operation: present ? .upsert : .remove,
            favorite: present ? favorite : nil, siteId: present ? nil : favorite.siteId,
            market: present ? nil : favorite.market, notifyFavoriteAntennaIssuesPush: nil)
    }

    /// Suivre (ou ne plus suivre) le site de `favorite` pour son opérateur.
    static func follow(_ favorite: FavoriteAntenna, present: Bool) -> Self {
        Self(requestId: UUID().uuidString.lowercased(), operation: present ? .follow : .unfollow,
            favorite: favorite, siteId: nil, market: nil, notifyFavoriteAntennaIssuesPush: nil)
    }

    static func notifications(_ enabled: Bool) -> Self {
        Self(requestId: UUID().uuidString.lowercased(), operation: .preferences, favorite: nil, siteId: nil,
            market: nil, notifyFavoriteAntennaIssuesPush: enabled)
    }
}

/// `GET /api/me/follows` : seuls les suivis de sites servent ici (opérateurs et zones sont ignorés).
struct SiteFollowsResponse: Decodable, Equatable, Sendable {
    struct Site: Decodable, Equatable, Sendable {
        let id: String
        let market: String
        let `operator`: String
        let siteId: String
        let siteKey: String?
        let label: String?
        let lat: Double?
        let lon: Double?
        let createdAt: String?

        var antenna: FavoriteAntenna {
            FavoriteAntenna(siteId: siteId, market: market, operator: `operator`, name: label,
                latitude: lat, longitude: lon, updatedAt: createdAt, siteKey: siteKey)
        }
    }
    let sites: [Site]

    /// 500 suivis de sites au plus, la limite du serveur.
    func validate() throws {
        guard sites.count <= 500,
              sites.allSatisfy({ !$0.siteId.filter { !$0.isWhitespace }.isEmpty && !$0.market.isEmpty && !$0.operator.isEmpty }) else {
            throw APIError.decoding("invalid-follows-snapshot")
        }
    }

    /// Un suivi par (site, opérateur).
    var antennas: [FavoriteAntenna] {
        var seen = Set<String>()
        return sites.map(\.antenna).filter { seen.insert($0.followKey).inserted }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
