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

    enum CodingKeys: String, CodingKey {
        case `operator` = "operator"
        case lat, lon, codeSite, idStation, plannedKey, referenceId, departement, commune, date5g, sourceUpdatedAt, technologies
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
        date5g = try c.decodeIfPresent(Date.self, forKey: .date5g)
        sourceUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .sourceUpdatedAt)
        if let array = try? c.decodeIfPresent([String].self, forKey: .technologies) {
            technologies = array
        } else if let object = try? c.decodeIfPresent([String: Bool].self, forKey: .technologies) {
            technologies = object.filter(\.value).map(\.key).sorted()
        } else {
            technologies = []
        }
        id = plannedKey ?? referenceId ?? idStation ?? codeSite ?? UUID().uuidString
    }
}

struct PlannedSitesResponse: Decodable, Equatable {
    let sites: [PlannedSiteLive]
}

struct OutageSiteLive: Decodable, Identifiable, Equatable {
    let id: String
    let `operator`: String?
    let siteId: String?
    let lat: Double?
    let lon: Double?
    let commune: String?
    let status: String?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, siteId, sup_id, codeSite, lat, latitude, lon, lng, longitude, commune, status, updatedAt
        case `operator` = "operator"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        siteId = c.decodeFlexibleString(forKey: .siteId) ?? c.decodeFlexibleString(forKey: .sup_id) ?? c.decodeFlexibleString(forKey: .codeSite)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? siteId ?? UUID().uuidString
        `operator` = try c.decodeIfPresent(String.self, forKey: .operator)
        lat = (try? c.decodeIfPresent(Double.self, forKey: .lat)) ?? (try? c.decodeIfPresent(Double.self, forKey: .latitude))
        lon = (try? c.decodeIfPresent(Double.self, forKey: .lon)) ?? (try? c.decodeIfPresent(Double.self, forKey: .lng)) ?? (try? c.decodeIfPresent(Double.self, forKey: .longitude))
        commune = try c.decodeIfPresent(String.self, forKey: .commune)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct OutageSitesResponse: Decodable, Equatable {
    let sites: [OutageSiteLive]
}

struct CoveragePointsResponse: Decodable, Equatable {
    let points: [CoverageHeatPoint]
}

struct CoverageHeatPoint: Decodable, Identifiable, Equatable {
    let id: String
    let latitude: Double
    let longitude: Double
    let signalStrength: Double?
    let technology: String?
    let networkType: String?
    let timestamp: Date?
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
    let latestTimestamp: Date?

    enum CodingKeys: String, CodingKey {
        case id, lat, lng, count, avgRsrp, tech, latestTimestamp
    }

    init(id: String, lat: Double, lng: Double, count: Int, avgRsrp: Double? = nil, tech: String? = nil, latestTimestamp: Date? = nil) {
        self.id = id
        self.lat = lat
        self.lng = lng
        self.count = count
        self.avgRsrp = avgRsrp
        self.tech = tech
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
    let bands: [Int]
    let address: String?

    enum CodingKeys: String, CodingKey {
        case id, supId, anfrCode, lat, lng, `operator`, operators, sharingType, crozonLeader, zbLeader, technologies, azimuts, bands, address
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
        bands = c.decodeLossyArray([Int].self, forKey: .bands)
        address = c.decodeFlexibleString(forKey: .address)
    }
}

struct AndroidSpeedtestTileResponse: Decodable, Equatable, Sendable {
    let tile: AndroidMapTile
    let clusters: [AndroidMapCluster]
    let markers: [AndroidSpeedtestMarker]
}

struct AndroidSpeedtestMarker: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let lat: Double
    let lng: Double
    let downloadMbps: Double
    let uploadMbps: Double?
    let pingMs: Double?
    let tech: String?
    let timestamp: Date?
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
    let lat: Double
    let lng: Double
    let radiusMeters: Double?
    let confidenceScore: Double?
    let confidenceLevel: String?
    let observationCount: Int?
    let distinctUserCount: Int?
    let lastObservedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, candidateKey, candidateKind, marketCode, operatorKey, networkGroupKey
        case radioNodeType, enb, gnb, lat, lng, radiusMeters, confidenceScore
        case confidenceLevel, observationCount, distinctUserCount, lastObservedAt
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
