import Foundation
import CoreLocation

struct SocialMapSnapshot: Codable, Equatable {
    let timestamp: Date?
    let friends: [SocialFriendLive]
    let photos: [SocialPhotoLive]
    let validations: [SocialValidationLive]
    let sessions: [SocialSessionLive]
    let coveragePoints: [SocialCoveragePointLive]
    let speedtests: [SocialSpeedtestLive]
    let photosCount: Int
    let validationsCount: Int
    let sessionsCount: Int
    let coveragePointsCount: Int
    let speedtestsCount: Int
    let rawCoveragePointsCount: Int?
    let logicalCoveragePointsCount: Int?
}

struct SocialPresence: Codable, Equatable {
    let status: String?
    let customStatus: String?
    let lastSeenAt: Date?
    let isOnline: Bool?
}

struct SocialLiveLocation: Codable, Equatable {
    let lat: Double
    let lng: Double
    let accuracy: Double?
    let heading: Double?
    let speed: Double?
    let updatedAt: Date?
}

struct SocialRadioSnapshot: Codable, Equatable {
    let technology: String?
    let rsrp: Double?
    let rsrq: Double?
    let snr: Double?
    let pci: Int?
    let enb: String?
    let gnb: String?
    let cellId: String?
    let band: Int?
    let `operator`: String?
    let city: String?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case technology, rsrp, rsrq, snr, pci, enb, gnb, cellId, band, city, updatedAt
        case `operator` = "operator"
    }
}

struct SocialPrivacySettings: Codable, Equatable {
    let shareLiveLocationWithFriends: Bool?
    let shareRadioDataWithFriends: Bool?
    let shareSessionsWithFriends: Bool?
    let sharePhotosOnFriendMap: Bool?
    let lastSeenVisibility: String?
    let messageRequestPolicy: String?
}

struct SocialFriendLive: Codable, Identifiable, Equatable {
    let id: String
    let name: String?
    let avatarUrl: URL?
    let presence: SocialPresence?
    let location: SocialLiveLocation?
    let radio: SocialRadioSnapshot?
    let privacy: SocialPrivacySettings?

    enum CodingKeys: String, CodingKey { case id, name, avatarUrl, presence, location, radio, privacy }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = c.decodeFlexibleString(forKey: .name)
        avatarUrl = c.decodeLossyURL(forKey: .avatarUrl)
        presence = try c.decodeIfPresent(SocialPresence.self, forKey: .presence)
        location = try c.decodeIfPresent(SocialLiveLocation.self, forKey: .location)
        radio = try c.decodeIfPresent(SocialRadioSnapshot.self, forKey: .radio)
        privacy = try c.decodeIfPresent(SocialPrivacySettings.self, forKey: .privacy)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try c.encodeIfPresent(presence, forKey: .presence)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(radio, forKey: .radio)
        try c.encodeIfPresent(privacy, forKey: .privacy)
    }

    /// Init mémberwise (le `init(from:)` custom empêche sa synthèse) — utilisé par
    /// les tests et l'injection de démo QA.
    init(
        id: String,
        name: String?,
        avatarUrl: URL?,
        presence: SocialPresence?,
        location: SocialLiveLocation?,
        radio: SocialRadioSnapshot?,
        privacy: SocialPrivacySettings?
    ) {
        self.id = id
        self.name = name
        self.avatarUrl = avatarUrl
        self.presence = presence
        self.location = location
        self.radio = radio
        self.privacy = privacy
    }
}

extension SocialFriendLive {
    /// Statut de présence dérivé (backend `presence.status` + `isOnline`).
    var presenceStatus: SocialPresenceStatus {
        if let raw = presence?.status?.lowercased(),
           let status = SocialPresenceStatus(rawValue: raw) {
            return status
        }
        return presence?.isOnline == true ? .online : .offline
    }

    /// Vrai quand la dernière position remonte à plus de `maxAge` (défaut 3 min,
    /// = TTL serveur). Un ami « périmé » est rendu estompé sur la carte.
    func hasStaleLocation(maxAge: TimeInterval = 180, now: Date = Date()) -> Bool {
        guard let updatedAt = location?.updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > maxAge
    }
}

struct SocialPhotoLive: Codable, Identifiable, Equatable {
    let id: String
    let userId: String?
    let siteId: String?
    let lat: Double?
    let lng: Double?
    let imageUrl: URL?
    let thumbnailUrl: URL?
    let uploadedAt: Date?
    let description: String?

    enum CodingKeys: String, CodingKey { case id, userId, siteId, lat, lng, latitude, longitude, imageUrl, thumbnailUrl, uploadedAt, description }

    init(id: String, userId: String?, siteId: String?, lat: Double?, lng: Double?, imageUrl: URL?, thumbnailUrl: URL?, uploadedAt: Date?, description: String?) {
        self.id = id
        self.userId = userId
        self.siteId = siteId
        self.lat = lat
        self.lng = lng
        self.imageUrl = imageUrl
        self.thumbnailUrl = thumbnailUrl
        self.uploadedAt = uploadedAt
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        userId = c.decodeFlexibleString(forKey: .userId)
        siteId = c.decodeFlexibleString(forKey: .siteId)
        lat = (try? c.decodeIfPresent(Double.self, forKey: .lat)) ?? (try? c.decodeIfPresent(Double.self, forKey: .latitude))
        lng = (try? c.decodeIfPresent(Double.self, forKey: .lng)) ?? (try? c.decodeIfPresent(Double.self, forKey: .longitude))
        imageUrl = c.decodeLossyURL(forKey: .imageUrl)
        thumbnailUrl = c.decodeLossyURL(forKey: .thumbnailUrl)
        uploadedAt = try c.decodeIfPresent(Date.self, forKey: .uploadedAt)
        description = c.decodeFlexibleString(forKey: .description)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(userId, forKey: .userId)
        try c.encodeIfPresent(siteId, forKey: .siteId)
        try c.encodeIfPresent(lat, forKey: .lat)
        try c.encodeIfPresent(lng, forKey: .lng)
        try c.encodeIfPresent(imageUrl, forKey: .imageUrl)
        try c.encodeIfPresent(thumbnailUrl, forKey: .thumbnailUrl)
        try c.encodeIfPresent(uploadedAt, forKey: .uploadedAt)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

struct SocialValidationLive: Codable, Identifiable, Equatable {
    let id: String
    let userId: String?
    let siteId: String?
    let lat: Double?
    let lng: Double?
    let type: String?
    let value: String?
    let pci: String?
    let cellId: String?
    let `operator`: String?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, userId, siteId, lat, lng, type, value, pci, cellId, createdAt
        case `operator` = "operator"
    }
}

struct SocialSessionLive: Codable, Identifiable, Equatable {
    let id: String
    let userId: String?
    let lat: Double?
    let lng: Double?
    let startTime: Date?
    let endTime: Date?
    let isActive: Bool?
    let totalPoints: Int?
    let distance: Double?
    let technologiesDetected: [String]
}

struct SocialCoveragePointLive: Codable, Identifiable, Equatable {
    let id: String
    let pointGroupId: String?
    let userId: String?
    let sessionId: String?
    let lat: Double
    let lng: Double
    let rsrp: Double?
    let technology: String?
    let band: Int?
    let timestamp: Date?
}

struct SocialSpeedtestLive: Codable, Identifiable, Equatable {
    let id: String
    let userId: String?
    let latitude: Double?
    let longitude: Double?
    let averageSpeed: Double
    let uploadAvg: Double?
    let pingAvg: Double?
    let timestamp: Date?
    let networkType: String?
    let mobileOperator: String?

    enum CodingKeys: String, CodingKey {
        case id, userId, latitude, longitude, lat, lng, averageSpeed, downloadSpeed, uploadAvg, pingAvg, timestamp, networkType, mobileOperator
    }

    init(
        id: String,
        userId: String?,
        latitude: Double?,
        longitude: Double?,
        averageSpeed: Double,
        uploadAvg: Double?,
        pingAvg: Double?,
        timestamp: Date?,
        networkType: String?,
        mobileOperator: String?
    ) {
        self.id = id
        self.userId = userId
        self.latitude = latitude
        self.longitude = longitude
        self.averageSpeed = averageSpeed
        self.uploadAvg = uploadAvg
        self.pingAvg = pingAvg
        self.timestamp = timestamp
        self.networkType = networkType
        self.mobileOperator = mobileOperator
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        userId = c.decodeFlexibleString(forKey: .userId)
        latitude = (try? c.decodeIfPresent(Double.self, forKey: .latitude)) ?? (try? c.decodeIfPresent(Double.self, forKey: .lat))
        longitude = (try? c.decodeIfPresent(Double.self, forKey: .longitude)) ?? (try? c.decodeIfPresent(Double.self, forKey: .lng))
        averageSpeed = (try? c.decodeIfPresent(Double.self, forKey: .averageSpeed))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .downloadSpeed))
            ?? 0
        uploadAvg = try c.decodeIfPresent(Double.self, forKey: .uploadAvg)
        pingAvg = try c.decodeIfPresent(Double.self, forKey: .pingAvg)
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp)
        networkType = c.decodeFlexibleString(forKey: .networkType)
        mobileOperator = c.decodeFlexibleString(forKey: .mobileOperator)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(userId, forKey: .userId)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encode(averageSpeed, forKey: .averageSpeed)
        try c.encodeIfPresent(uploadAvg, forKey: .uploadAvg)
        try c.encodeIfPresent(pingAvg, forKey: .pingAvg)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(networkType, forKey: .networkType)
        try c.encodeIfPresent(mobileOperator, forKey: .mobileOperator)
    }
}

/// Statut d'activation d'un site prévisionnel, croisé côté backend avec le
/// référentiel ANFR — identique au contrat Android (`activation.status`).
/// `active` : toutes les technos prévues sont en service. `upgradePending` :
/// site en service mais une bande prévue (ex. 5G 3500) pas encore allumée.
/// `declared` : station enregistrée sans émetteur actif. `planned` : pas
/// (encore) construit. Toute valeur inconnue retombe sur `.planned`.
enum PlannedActivationStatus: String, Equatable, Sendable, CaseIterable {
    case active
    case upgradePending
    case declared
    case planned

    init(apiValue: String?) {
        switch apiValue?.lowercased() {
        case "active": self = .active
        case "upgrade_pending", "upgradepending": self = .upgradePending
        case "declared": self = .declared
        default: self = .planned
        }
    }

    /// Le site émet déjà (au moins partiellement) sur le terrain.
    var isOnAir: Bool { self == .active || self == .upgradePending }
}

struct PlannedSiteActivation: Decodable, Equatable, Sendable {
    let status: PlannedActivationStatus
    let matchType: String?
    let activeTechnologies: [String]
    let plannedTechnologies: [String]
    let confirmedTechnologies: [String]
    let pendingTechnologies: [String]
    /// Distance (m) entre le point prévisionnel et l'antenne ANFR appariée.
    let distanceM: Double?
    /// Dernière mise en service connue de l'antenne appariée (date jour-seul).
    let lastInServiceDate: Date?

    enum CodingKeys: String, CodingKey {
        case status, matchType, activeTechnologies, plannedTechnologies, confirmedTechnologies, pendingTechnologies, distanceM, lastInServiceDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = PlannedActivationStatus(apiValue: try? c.decodeIfPresent(String.self, forKey: .status))
        matchType = c.decodeFlexibleString(forKey: .matchType)
        activeTechnologies = c.decodeLossyArray([String].self, forKey: .activeTechnologies)
        plannedTechnologies = c.decodeLossyArray([String].self, forKey: .plannedTechnologies)
        confirmedTechnologies = c.decodeLossyArray([String].self, forKey: .confirmedTechnologies)
        pendingTechnologies = c.decodeLossyArray([String].self, forKey: .pendingTechnologies)
        distanceM = (try? c.decodeIfPresent(Double.self, forKey: .distanceM)) ?? nil
        lastInServiceDate = (try? c.decodeIfPresent(Date.self, forKey: .lastInServiceDate)) ?? nil
    }
}

struct PlannedSiteLive: Decodable, Identifiable, Equatable {
    let id: String
    let `operator`: String?
    let lat: Double?
    let lon: Double?
    let codeSite: String?
    let idStation: String?
    let plannedKey: String?
    let referenceId: String?
    let departement: String?
    let commune: String?
    let date5g: Date?
    let sourceUpdatedAt: Date?
    let technologies: [String]
    /// Croisement ANFR (active / upgrade en attente / déclarée / prévue), comme Android.
    let activation: PlannedSiteActivation?

    enum CodingKeys: String, CodingKey {
        case `operator` = "operator"
        case lat, lon, codeSite, idStation, plannedKey, referenceId, departement, commune, date5g, sourceUpdatedAt, technologies, activation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        `operator` = try c.decodeIfPresent(String.self, forKey: .operator)
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        codeSite = c.decodeFlexibleString(forKey: .codeSite)
        idStation = c.decodeFlexibleString(forKey: .idStation)
        plannedKey = c.decodeFlexibleString(forKey: .plannedKey)
        referenceId = c.decodeFlexibleString(forKey: .referenceId)
        departement = c.decodeFlexibleString(forKey: .departement)
        commune = try c.decodeIfPresent(String.self, forKey: .commune)
        // Décodage TOLÉRANT : un format de date inattendu ne doit jamais faire
        // échouer tout le tableau de sites prévisionnels (cf. bug couche vide).
        date5g = (try? c.decodeIfPresent(Date.self, forKey: .date5g)) ?? nil
        sourceUpdatedAt = (try? c.decodeIfPresent(Date.self, forKey: .sourceUpdatedAt)) ?? nil
        if let array = try? c.decodeIfPresent([String].self, forKey: .technologies) {
            technologies = array
        } else if let object = try? c.decodeIfPresent([String: Bool].self, forKey: .technologies) {
            technologies = object.filter(\.value).map(\.key).sorted()
        } else {
            technologies = []
        }
        activation = try? c.decodeIfPresent(PlannedSiteActivation.self, forKey: .activation)
        id = plannedKey ?? referenceId ?? idStation ?? codeSite ?? UUID().uuidString
    }
}

struct PlannedSitesResponse: Decodable, Equatable {
    let sites: [PlannedSiteLive]
}

/// État d'un service réseau sur un site en panne (ex. « Data 4G » → « HS »).
struct OutageService: Equatable, Sendable {
    let label: String
    /// Statut brut backend : "HS" (hors service), "DE" (dégradé), "OK".
    let status: String
}

struct OutageSiteLive: Decodable, Identifiable, Equatable {
    let id: String
    let `operator`: String?
    let siteId: String?
    let lat: Double?
    let lon: Double?
    let commune: String?
    let departement: String?
    /// "down" | "maintenance" | "degraded" (contrat `/api/android/map/incidents`).
    let issueType: String?
    let reason: String?
    let detail: String?
    let startedAt: String?
    let estimatedEnd: String?
    /// Services impactés (voix/data 2G→5G) avec leur statut, pour la sheet.
    let services: [OutageService]

    /// Libellé court affiché en métrique du marqueur.
    var status: String? { reason ?? issueType }

    enum CodingKeys: String, CodingKey {
        // Clés `/api/android/map/incidents` : lat/lon minuscules, code_site_op,
        // issueType. On garde des replis (Lat/Lon majuscules, sup_id…) pour rester
        // robuste si la source bascule sur `/api/sites-hs`.
        case id, siteId, sup_id, codeSite, code_site_op
        case lat, latitude, Lat, lon, lng, longitude, Lon
        case commune, departement, issueType, raison, reason, detail, debut, fin_prev, status, updatedAt
        case voix2g = "2Gvoix", voix3g = "3Gvoix", voix4g = "4Gvoix"
        case data3g = "3Gdata", data4g = "4Gdata", data5g = "5Gdata"
        case `operator` = "operator"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        siteId = c.decodeFlexibleString(forKey: .code_site_op)
            ?? c.decodeFlexibleString(forKey: .siteId)
            ?? c.decodeFlexibleString(forKey: .sup_id)
            ?? c.decodeFlexibleString(forKey: .codeSite)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? siteId ?? UUID().uuidString
        `operator` = try c.decodeIfPresent(String.self, forKey: .operator)
        lat = (try? c.decodeIfPresent(Double.self, forKey: .lat))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .latitude))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .Lat))
        lon = (try? c.decodeIfPresent(Double.self, forKey: .lon))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .lng))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .longitude))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .Lon))
        commune = try c.decodeIfPresent(String.self, forKey: .commune)
        departement = c.decodeFlexibleString(forKey: .departement)
        issueType = c.decodeFlexibleString(forKey: .issueType)
        reason = c.decodeFlexibleString(forKey: .raison)
            ?? c.decodeFlexibleString(forKey: .reason)
            ?? c.decodeFlexibleString(forKey: .status)
        detail = c.decodeFlexibleString(forKey: .detail)
        startedAt = c.decodeFlexibleString(forKey: .debut)
        estimatedEnd = c.decodeFlexibleString(forKey: .fin_prev)

        let serviceFields: [(CodingKeys, String)] = [
            (.voix2g, "Voix 2G"), (.voix3g, "Voix 3G"), (.voix4g, "Voix 4G"),
            (.data3g, "Data 3G"), (.data4g, "Data 4G"), (.data5g, "Data 5G")
        ]
        services = serviceFields.compactMap { key, label in
            guard let raw = c.decodeFlexibleString(forKey: key)?.uppercased() else { return nil }
            // "NE" = non équipé ; on ne l'affiche pas.
            guard raw != "NE" else { return nil }
            return OutageService(label: label, status: raw)
        }
    }
}

struct OutageSitesResponse: Decodable, Equatable {
    let sites: [OutageSiteLive]
}

struct CoveragePointsResponse: Decodable, Equatable {
    let points: [CoverageHeatPoint]
}

/// Photo publique d'un membre, placée sur la carte (coords résolues côté backend
/// via le site). `operator` = opérateur DE LA PHOTO (sert le filtre opérateur) ;
/// `isFriend` indique si l'auteur fait partie des amis (mode « Amis »).
struct MapPublicPhoto: Decodable, Identifiable, Equatable {
    let id: String
    let siteId: String?
    let lat: Double
    let lng: Double
    let thumbnailUrl: URL?
    let `operator`: String?
    let authorId: String?
    let uploadedAt: Date?
    let isFriend: Bool

    enum CodingKeys: String, CodingKey {
        case id, siteId, lat, lng, thumbnailUrl, authorId, uploadedAt, isFriend
        case `operator` = "operator"
    }

    init(id: String, siteId: String?, lat: Double, lng: Double, thumbnailUrl: URL?, operator: String?, authorId: String?, uploadedAt: Date?, isFriend: Bool) {
        self.id = id
        self.siteId = siteId
        self.lat = lat
        self.lng = lng
        self.thumbnailUrl = thumbnailUrl
        self.`operator` = `operator`
        self.authorId = authorId
        self.uploadedAt = uploadedAt
        self.isFriend = isFriend
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        siteId = c.decodeFlexibleString(forKey: .siteId)
        lat = (try? c.decode(Double.self, forKey: .lat)) ?? 0
        lng = (try? c.decode(Double.self, forKey: .lng)) ?? 0
        thumbnailUrl = c.decodeLossyURL(forKey: .thumbnailUrl)
        `operator` = c.decodeFlexibleString(forKey: .operator)
        authorId = c.decodeFlexibleString(forKey: .authorId)
        uploadedAt = (try? c.decodeIfPresent(Date.self, forKey: .uploadedAt)) ?? nil
        isFriend = (try? c.decodeIfPresent(Bool.self, forKey: .isFriend)) ?? false
    }
}

struct MapPublicPhotosResponse: Decodable, Equatable {
    let photos: [MapPublicPhoto]
}

struct CoverageHeatPoint: Decodable, Identifiable, Equatable {
    let id: String
    let latitude: Double
    let longitude: Double
    let signalStrength: Double?
    let technology: String?
    let networkType: String?
    let band: Int?
    let frequency: String?
    let timestamp: Date?
    /// 'ios' = point de couverture génération-seule (sans RSRP) — exclu de la couche
    /// SIGNAL/RSRP côté client (n'apparaît que sur la couche génération).
    let source: String?
}

struct AndroidMapTile: Codable, Equatable, Hashable, Sendable {
    let z: Int
    let x: Int
    let y: Int
}

struct AndroidMapCluster: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let lat: Double
    let lng: Double
    let count: Int
    let avgRsrp: Double?
    let tech: String?
    /// 'ios' = cluster de couverture génération-seule (sans RSRP) ; sinon 'android'.
    /// Exclu de la couche RSRP/qualité (comme les points).
    let source: String?
    let latestTimestamp: Date?

    enum CodingKeys: String, CodingKey {
        case id, lat, lng, count, avgRsrp, tech, source, latestTimestamp
    }

    init(id: String, lat: Double, lng: Double, count: Int, avgRsrp: Double? = nil, tech: String? = nil, source: String? = nil, latestTimestamp: Date? = nil) {
        self.id = id
        self.lat = lat
        self.lng = lng
        self.count = count
        self.avgRsrp = avgRsrp
        self.tech = tech
        self.source = source
        self.latestTimestamp = latestTimestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        lat = (try? c.decode(Double.self, forKey: .lat)) ?? 0
        lng = (try? c.decode(Double.self, forKey: .lng)) ?? 0
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
        avgRsrp = try? c.decodeIfPresent(Double.self, forKey: .avgRsrp)
        tech = c.decodeFlexibleString(forKey: .tech)
        source = c.decodeFlexibleString(forKey: .source)
        latestTimestamp = try? c.decodeIfPresent(Date.self, forKey: .latestTimestamp)
    }
}

struct AndroidAntennaTileResponse: Decodable, Equatable, Sendable {
    let tile: AndroidMapTile
    let market: String?
    let clusters: [AndroidMapCluster]
    let markers: [AndroidAntennaMarker]
}

struct AndroidAntennaMarker: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let supId: String?
    let anfrCode: String?
    let lat: Double
    let lng: Double
    let `operator`: String?
    let operators: [String]
    let sharingType: String?
    let crozonLeader: String?
    let zbLeader: String?
    let technologies: [String]
    let azimuts: [Double]
    /// Azimuts par opérateur, présent uniquement sur un support PARTAGÉ vu en
    /// « Tous ». Sans lui, `azimuts` ne porte que ceux du premier opérateur
    /// fusionné : la carte montrait donc les secteurs d'un seul, sans le dire.
    /// Absent des tuiles servies avant le déploiement → vide, rendu inchangé.
    let azimutsByOperator: [String: [Double]]
    /// Opérateurs du support qui émettent en 5G. `technologies` fusionné dit
    /// seulement qu'il y a de la 5G quelque part sur le pylône, pas à qui elle
    /// appartient. Vide sur un site mono-opérateur ou un backend antérieur.
    let operators5G: [String]
    let bands: [Int]
    let address: String?
    let isZTD: Bool
    /// Nombre de photos/validations publiques sur le site (ajouté par le backend
    /// au zoom ≥ 13). Sert le badge « photos disponibles » sur le marqueur.
    let photoCount: Int
    let validationCount: Int
    /// eNB / gNB du site identifiés par la communauté (backend, zoom ≥ 13).
    /// Absents des tuiles servies avant le déploiement de l'enrichissement →
    /// `false`, et le marqueur se rend simplement sans coche.
    let hasEnb: Bool
    let hasGnb: Bool

    /// Hauteur et nature du support, telles que les tuiles les portent déjà.
    ///
    /// Sans elles, la fiche s'ouvrait sans aucune hauteur et calculait sa ligne
    /// de visée sur une valeur par défaut de 25 m, le temps que l'appel détail
    /// réponde. Le profil était donc faux au premier affichage.
    let supportHeightMeters: Double?
    let supportNature: String?
    /// Systèmes radio déclarés (« LTE 800 », « 5G NR 3500 ») : ils donnent la
    /// bande la plus basse, celle qui sert au calcul de Fresnel.
    let radioSystems: [String]

    enum CodingKeys: String, CodingKey {
        case id, supId, anfrCode, lat, lng, `operator`, operators, sharingType, crozonLeader, zbLeader, technologies, azimuts, azimutsByOperator, operators5G, bands, address, isZTD, photoCount, validationCount, hasEnb, hasGnb
        // Le backend n'émet PAS de clé `address` : il envoie les composants ANFR
        // séparément. Sans eux, l'adresse d'un site venu des tuiles restait vide.
        case adrLbAdd1 = "adr_lb_add1"
        case adrLbLieu = "adr_lb_lieu"
        case adrNmCp = "adr_nm_cp"
        case commune
        case supportInfo = "support_info"
        case emrLbSysteme = "emr_lb_systeme"
    }

    private struct SupportInfo: Decodable {
        let hauteur: String?
        let nature: String?

        enum CodingKeys: String, CodingKey { case hauteur, nature }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hauteur = c.decodeFlexibleString(forKey: .hauteur)
            nature = c.decodeFlexibleString(forKey: .nature)
        }

        /// « 52,2 » → 52,2. La virgule décimale est celle de l'ANFR.
        var meters: Double? {
            guard let hauteur else { return nil }
            return Double(hauteur.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." })
        }

        /// Nature du support, SEULEMENT si c'est un libellé.
        ///
        /// Les tuiles métropolitaines renvoient « Monument religieux », mais les
        /// DROM renvoient le code ANFR brut (« 23 ») et le Canada le code de
        /// structure ISED (« T »). Les afficher tels quels donnerait « Ce 23
        /// mesure 38 m » dans la fiche, et choisirait la mauvaise silhouette. La
        /// fiche détaillée, elle, résout les libellés : on l'attend plutôt que
        /// d'inventer.
        var resolvedNature: String? {
            guard let nature = nature?.trimmingCharacters(in: .whitespaces), nature.count > 3 else { return nil }
            return nature.contains(where: { $0.isLetter }) ? nature : nil
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? c.decodeFlexibleString(forKey: .supId) ?? UUID().uuidString
        supId = c.decodeFlexibleString(forKey: .supId)
        anfrCode = c.decodeFlexibleString(forKey: .anfrCode)
        lat = (try? c.decode(Double.self, forKey: .lat)) ?? 0
        lng = (try? c.decode(Double.self, forKey: .lng)) ?? 0
        `operator` = c.decodeFlexibleString(forKey: .operator)
        operators = c.decodeLossyArray([String].self, forKey: .operators)
        sharingType = c.decodeFlexibleString(forKey: .sharingType)
        crozonLeader = c.decodeFlexibleString(forKey: .crozonLeader)
        zbLeader = c.decodeFlexibleString(forKey: .zbLeader)
        technologies = c.decodeLossyArray([String].self, forKey: .technologies)
        azimuts = c.decodeLossyArray([Double].self, forKey: .azimuts)
        azimutsByOperator = ((try? c.decodeIfPresent([String: [Double]].self, forKey: .azimutsByOperator)) ?? nil) ?? [:]
        operators5G = c.decodeLossyArray([String].self, forKey: .operators5G)
        bands = c.decodeLossyArray([Int].self, forKey: .bands)
        address = Self.composedAddress(from: c)
        isZTD = (try? c.decodeIfPresent(Bool.self, forKey: .isZTD)) ?? false
        photoCount = (try? c.decodeIfPresent(Int.self, forKey: .photoCount)) ?? 0
        validationCount = (try? c.decodeIfPresent(Int.self, forKey: .validationCount)) ?? 0
        hasEnb = (try? c.decodeIfPresent(Bool.self, forKey: .hasEnb)) ?? false
        hasGnb = (try? c.decodeIfPresent(Bool.self, forKey: .hasGnb)) ?? false
        let support = (try? c.decodeIfPresent(SupportInfo.self, forKey: .supportInfo)) ?? nil
        supportHeightMeters = support?.meters
        supportNature = support?.resolvedNature
        radioSystems = c.decodeLossyArray([String].self, forKey: .emrLbSysteme)
    }

    /// Adresse lisible reconstituée depuis les champs ANFR : rue (ou lieu-dit),
    /// puis code postal et commune. `nil` si rien d'exploitable — mieux vaut pas
    /// de ligne qu'une ligne vide dans la fiche.
    private static func composedAddress(from c: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let direct = c.decodeFlexibleString(forKey: .address), !direct.isEmpty { return direct }
        let street = c.decodeFlexibleString(forKey: .adrLbAdd1) ?? c.decodeFlexibleString(forKey: .adrLbLieu)
        let city = [c.decodeFlexibleString(forKey: .adrNmCp), c.decodeFlexibleString(forKey: .commune)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let parts = [street, city.isEmpty ? nil : city].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

struct AndroidSpeedtestTileResponse: Decodable, Equatable, Sendable {
    let tile: AndroidMapTile
    let clusters: [AndroidMapCluster]
    let markers: [AndroidSpeedtestMarker]
    var stats: AndroidSpeedtestStats?

    init(tile: AndroidMapTile, clusters: [AndroidMapCluster], markers: [AndroidSpeedtestMarker], stats: AndroidSpeedtestStats? = nil) {
        self.tile = tile
        self.clusters = clusters
        self.markers = markers
        self.stats = stats
    }
}

/// Pagination des tuiles speedtest (`stats.hasMore` / `nextOffset`). Le backend
/// plafonne chaque page à `limit` (5000) ; on enchaîne les offsets pour TOUT
/// récupérer, sans cluster ni cap d'affichage (comportement Android).
struct AndroidSpeedtestStats: Decodable, Equatable, Sendable {
    let returnedCount: Int?
    let hasMore: Bool?
    let nextOffset: Int?
    let truncated: Bool?
}

struct AndroidSpeedtestMarker: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let lat: Double
    let lng: Double
    let downloadMbps: Double
    let uploadMbps: Double?
    let pingMs: Double?
    let tech: String?
    let band: Int?
    let frequency: String?
    let timestamp: Date?
    let `operator`: String?

    enum CodingKeys: String, CodingKey {
        case id, lat, lng, downloadMbps, uploadMbps, pingMs, tech, band, frequency, timestamp
        case `operator` = "operator"
    }
}

struct AndroidCoverageTileResponse: Decodable, Equatable, Sendable {
    let tile: AndroidMapTile
    let points: [AndroidCoveragePoint]
    let stats: AndroidCoverageStats?
    let clusters: [AndroidMapCluster]
}

struct AndroidCoveragePoint: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let lat: Double
    let lng: Double
    let rsrp: Double?
    let rsrq: Double?
    let snr: Double?
    let tech: String?
    let timestamp: Date?
    let band: Int?
    let groupId: String?
    let isPrimary: Bool?
    let cellType: String?
    /// Source de la session : "ios" = couverture génération-seule (sans RSRP), sinon
    /// "coverage"/"drive_test" (Android). Sert à exclure les points iOS de la couche
    /// SIGNAL/RSRP (ils n'apparaissent que sur la couche génération).
    let source: String?
}

struct AndroidCommunitySiteTileResponse: Decodable, Equatable, Sendable {
    let tile: AndroidMapTile
    let clusters: [AndroidMapCluster]
    let markers: [AndroidCommunitySiteMarker]

    enum CodingKeys: String, CodingKey {
        case tile, clusters, markers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tile = (try? c.decode(AndroidMapTile.self, forKey: .tile)) ?? AndroidMapTile(z: 0, x: 0, y: 0)
        clusters = c.decodeLossyArray([AndroidMapCluster].self, forKey: .clusters)
        markers = c.decodeLossyArray([AndroidCommunitySiteMarker].self, forKey: .markers)
    }
}

/// Site probable / cellule observée par la communauté
/// (GET /api/android/map/tiles/community-sites/{z}/{x}/{y}).
struct AndroidCommunitySiteMarker: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let candidateKey: String?
    /// "community_probable" ou "observed_cell".
    let candidateKind: String?
    let marketCode: String?
    let operatorKey: String?
    let networkGroupKey: String?
    let radioNodeType: String?
    let enb: String?
    let gnb: String?
    /// Identité radio complète. Sans elle on ne peut pas pré-remplir un site à
    /// partir d'une cellule : l'eNB seul ne suffit ni à décrire la porteuse, ni
    /// à retrouver l'opérateur par PLMN.
    let cellId: String?
    let ci: String?
    let pci: Int?
    let tac: String?
    let earfcn: Int?
    let nrarfcn: Int?
    let band: Int?
    let mcc: Int?
    let mnc: Int?
    let firstObservedAt: Date?
    let lat: Double
    let lng: Double
    let radiusMeters: Double?
    let confidenceScore: Double?
    let confidenceLevel: String?
    let observationCount: Int?
    let distinctUserCount: Int?
    /// Précision GPS médiane des mesures : dit à quel point le centroïde est sûr.
    let medianAccuracyMeters: Double?
    let lastObservedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, candidateKey, candidateKind, marketCode, operatorKey, networkGroupKey
        case radioNodeType, enb, gnb, lat, lng, radiusMeters, confidenceScore
        case confidenceLevel, observationCount, distinctUserCount, lastObservedAt
        case cellId, ci, pci, tac, earfcn, nrarfcn, band, mcc, mnc, firstObservedAt
        case medianAccuracyMeters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id)
            ?? c.decodeFlexibleString(forKey: .candidateKey)
            ?? UUID().uuidString
        candidateKey = c.decodeFlexibleString(forKey: .candidateKey)
        candidateKind = c.decodeFlexibleString(forKey: .candidateKind)
        marketCode = c.decodeFlexibleString(forKey: .marketCode)
        operatorKey = c.decodeFlexibleString(forKey: .operatorKey)
        networkGroupKey = c.decodeFlexibleString(forKey: .networkGroupKey)
        radioNodeType = c.decodeFlexibleString(forKey: .radioNodeType)
        enb = c.decodeFlexibleString(forKey: .enb)
        gnb = c.decodeFlexibleString(forKey: .gnb)
        lat = (try? c.decode(Double.self, forKey: .lat)) ?? 0
        lng = (try? c.decode(Double.self, forKey: .lng)) ?? 0
        radiusMeters = (try? c.decodeIfPresent(Double.self, forKey: .radiusMeters)) ?? nil
        confidenceScore = (try? c.decodeIfPresent(Double.self, forKey: .confidenceScore)) ?? nil
        confidenceLevel = c.decodeFlexibleString(forKey: .confidenceLevel)
        observationCount = (try? c.decodeIfPresent(Int.self, forKey: .observationCount)) ?? nil
        distinctUserCount = (try? c.decodeIfPresent(Int.self, forKey: .distinctUserCount)) ?? nil
        lastObservedAt = (try? c.decodeIfPresent(Date.self, forKey: .lastObservedAt)) ?? nil
        cellId = c.decodeFlexibleString(forKey: .cellId)
        ci = c.decodeFlexibleString(forKey: .ci)
        pci = (try? c.decodeIfPresent(Int.self, forKey: .pci)) ?? nil
        tac = c.decodeFlexibleString(forKey: .tac)
        earfcn = (try? c.decodeIfPresent(Int.self, forKey: .earfcn)) ?? nil
        nrarfcn = (try? c.decodeIfPresent(Int.self, forKey: .nrarfcn)) ?? nil
        band = (try? c.decodeIfPresent(Int.self, forKey: .band)) ?? nil
        mcc = (try? c.decodeIfPresent(Int.self, forKey: .mcc)) ?? nil
        mnc = (try? c.decodeIfPresent(Int.self, forKey: .mnc)) ?? nil
        firstObservedAt = (try? c.decodeIfPresent(Date.self, forKey: .firstObservedAt)) ?? nil
        medianAccuracyMeters = (try? c.decodeIfPresent(Double.self, forKey: .medianAccuracyMeters)) ?? nil
    }
}

/// Sites ajoutés à la main par les membres
/// (GET /api/android/map/tiles/custom-sites/{z}/{x}/{y}).
///
/// Distincts des `AndroidCommunitySiteMarker`, qui sont *déduits* des mesures :
/// ici quelqu'un a pointé un pylône, l'a nommé, parfois photographié, et y a
/// attaché les identifiants radio relevés. C'est la seule couche d'antennes qui
/// existe dans les pays sans open data (Bosnie, Portugal, Espagne…), d'où son
/// affichage sur TOUS les marchés.
struct AndroidCustomSiteTileResponse: Decodable, Equatable, Sendable {
    let tile: AndroidMapTile
    let markers: [AndroidCustomSiteMarker]

    enum CodingKeys: String, CodingKey {
        case tile, markers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tile = (try? c.decode(AndroidMapTile.self, forKey: .tile)) ?? AndroidMapTile(z: 0, x: 0, y: 0)
        markers = c.decodeLossyArray([AndroidCustomSiteMarker].self, forKey: .markers)
    }
}

/// Identifiants radio relevés sur un site personnalisé. Tous optionnels : un
/// membre peut n'avoir noté que l'eNB, ou rien du tout.
struct AndroidCustomSiteRadio: Decodable, Equatable, Sendable {
    let enb: String?
    let gnb: String?
    let cellId: String?
    let pci: Int?
    let tac: String?
    let earfcn: Int?
    let nrarfcn: Int?
    let band: Int?
    let mcc: Int?
    let mnc: Int?
    let operatorName: String?
    let technology: String?

    enum CodingKeys: String, CodingKey {
        case enb, gnb, cellId, pci, tac, earfcn, nrarfcn, band, mcc, mnc
        case operatorName = "operator"
        case technology
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `decodeFlexibleString` : le backend émet ces champs tantôt en nombre,
        // tantôt en chaîne selon la saisie du membre.
        enb = c.decodeFlexibleString(forKey: .enb)
        gnb = c.decodeFlexibleString(forKey: .gnb)
        cellId = c.decodeFlexibleString(forKey: .cellId)
        pci = (try? c.decodeIfPresent(Int.self, forKey: .pci)) ?? nil
        tac = c.decodeFlexibleString(forKey: .tac)
        earfcn = (try? c.decodeIfPresent(Int.self, forKey: .earfcn)) ?? nil
        nrarfcn = (try? c.decodeIfPresent(Int.self, forKey: .nrarfcn)) ?? nil
        band = (try? c.decodeIfPresent(Int.self, forKey: .band)) ?? nil
        mcc = (try? c.decodeIfPresent(Int.self, forKey: .mcc)) ?? nil
        mnc = (try? c.decodeIfPresent(Int.self, forKey: .mnc)) ?? nil
        operatorName = c.decodeFlexibleString(forKey: .operatorName)
        technology = c.decodeFlexibleString(forKey: .technology)
    }

    /// PLMN « 218-90 », quand les deux moitiés sont là.
    var plmn: String? {
        guard let mcc, let mnc else { return nil }
        return String(format: "%03d-%02d", mcc, mnc)
    }

    var isEmpty: Bool {
        enb == nil && gnb == nil && cellId == nil && pci == nil && tac == nil
            && earfcn == nil && nrarfcn == nil && band == nil && plmn == nil
            && operatorName == nil && technology == nil
    }
}

struct AndroidCustomSiteMarker: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let lat: Double
    let lng: Double
    let name: String?
    /// Type déclaré : "PYLONE", "TOIT", "CHATEAU_EAU"… (majuscules côté backend).
    let type: String?
    let description: String?
    let createdByUserId: String?
    let createdByDisplayName: String?
    let createdAt: Date?
    let photoCount: Int
    let primaryPhotoUrl: String?
    /// "validated" dès qu'une identification non automatique existe, sinon "pending".
    let validationStatus: String?
    /// Clé registre de l'opérateur propriétaire de l'infra, quand le backend
    /// l'émet. Plus fiable que `radio.operator`, qui peut être un nom libre.
    let operatorKey: String?
    let radio: AndroidCustomSiteRadio?

    enum CodingKeys: String, CodingKey {
        case id, lat, lng, name, type, description, createdByUserId
        case createdByDisplayName, createdAt, photoCount, primaryPhotoUrl
        case validationStatus, radio
        case operatorKey, infraOwnerOperator
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        lat = (try? c.decode(Double.self, forKey: .lat)) ?? 0
        lng = (try? c.decode(Double.self, forKey: .lng)) ?? 0
        name = c.decodeFlexibleString(forKey: .name)
        type = c.decodeFlexibleString(forKey: .type)
        description = c.decodeFlexibleString(forKey: .description)
        createdByUserId = c.decodeFlexibleString(forKey: .createdByUserId)
        createdByDisplayName = c.decodeFlexibleString(forKey: .createdByDisplayName)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
        photoCount = (try? c.decodeIfPresent(Int.self, forKey: .photoCount)) ?? 0
        primaryPhotoUrl = c.decodeFlexibleString(forKey: .primaryPhotoUrl)
        validationStatus = c.decodeFlexibleString(forKey: .validationStatus)
        operatorKey = c.decodeFlexibleString(forKey: .operatorKey)
            ?? c.decodeFlexibleString(forKey: .infraOwnerOperator)
        radio = (try? c.decodeIfPresent(AndroidCustomSiteRadio.self, forKey: .radio)) ?? nil
    }

    var isValidated: Bool {
        validationStatus?.caseInsensitiveCompare("validated") == .orderedSame
    }

    /// Libellé humain du type déclaré. Le backend stocke des constantes en
    /// majuscules sans accents : les afficher telles quelles donnerait
    /// « CHATEAU_EAU » au milieu d'une fiche en français.
    var typeLabel: String? {
        guard let raw = type?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw.uppercased() {
        case "PYLONE", "PYLON": return "Pylône"
        case "TOIT", "ROOFTOP", "TOITURE": return "Toit-terrasse"
        case "CHATEAU_EAU", "WATER_TOWER": return "Château d'eau"
        case "MAT", "MAST": return "Mât"
        case "EGLISE", "CHURCH": return "Clocher"
        case "SILO": return "Silo"
        case "IMMEUBLE", "BUILDING": return "Immeuble"
        case "AUTRE", "OTHER": return "Autre"
        default:
            // Type inconnu : on rend la constante lisible plutôt que de la masquer.
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct AndroidCoverageStats: Decodable, Equatable, Sendable {
    let avgRsrp: Double?
    let sampleCount: Int
    let returnedCount: Int?
    let returnedClusters: Int?
    let totalClusters: Int?
    let limit: Int?
    let offset: Int?
    let hasMore: Bool?
    let truncated: Bool?
    let representation: String?
}

struct MapDisplayItem: Identifiable, Equatable {
    enum Kind: String {
        case friend
        case photo
        case validation
        case session
        case coverage
        case speedtest
        case outage
        case planned
        case antenna
        case communitySite
        case customSite
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let metric: String?
    let backendId: String?
    let details: MapItemDetails?

    init(
        id: String,
        kind: Kind,
        title: String,
        subtitle: String,
        coordinate: CLLocationCoordinate2D,
        metric: String?,
        backendId: String? = nil,
        details: MapItemDetails? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.metric = metric
        self.backendId = backendId
        self.details = details
    }

    static func == (lhs: MapDisplayItem, rhs: MapDisplayItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.kind == rhs.kind &&
        lhs.title == rhs.title &&
        lhs.subtitle == rhs.subtitle &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.metric == rhs.metric &&
        lhs.backendId == rhs.backendId &&
        lhs.details == rhs.details
    }
}

struct MapItemDetails: Equatable {
    let downloadMbps: Double?
    let uploadMbps: Double?
    let pingMs: Double?
    let rsrp: Double?
    let rsrq: Double?
    let snr: Double?
    let avgRsrp: Double?
    let tech: String?
    let band: Int?
    let timestamp: Date?
    let operatorName: String?
    let clusterCount: Int?
    let sampleCount: Int?
    let returnedClusters: Int?
    let totalClusters: Int?
    let representation: String?
    let groupId: String?
    let isPrimary: Bool?
    let cellType: String?
    let note: String?

    init(
        downloadMbps: Double? = nil,
        uploadMbps: Double? = nil,
        pingMs: Double? = nil,
        rsrp: Double? = nil,
        rsrq: Double? = nil,
        snr: Double? = nil,
        avgRsrp: Double? = nil,
        tech: String? = nil,
        band: Int? = nil,
        timestamp: Date? = nil,
        operatorName: String? = nil,
        clusterCount: Int? = nil,
        sampleCount: Int? = nil,
        returnedClusters: Int? = nil,
        totalClusters: Int? = nil,
        representation: String? = nil,
        groupId: String? = nil,
        isPrimary: Bool? = nil,
        cellType: String? = nil,
        note: String? = nil
    ) {
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.pingMs = pingMs
        self.rsrp = rsrp
        self.rsrq = rsrq
        self.snr = snr
        self.avgRsrp = avgRsrp
        self.tech = tech
        self.band = band
        self.timestamp = timestamp
        self.operatorName = operatorName
        self.clusterCount = clusterCount
        self.sampleCount = sampleCount
        self.returnedClusters = returnedClusters
        self.totalClusters = totalClusters
        self.representation = representation
        self.groupId = groupId
        self.isPrimary = isPrimary
        self.cellType = cellType
        self.note = note
    }
}
