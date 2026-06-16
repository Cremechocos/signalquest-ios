import Foundation

struct AntennaSite: Decodable, Identifiable, Equatable {
    let id: String
    let siteId: String?
    let anfrCode: String?
    let latitude: Double?
    let longitude: Double?
    let operators: [String]
    let technologies: [String]
    let bands: [Int]
    let azimuths: [Double]
    let sharingType: String?
    let crozonLeader: String?
    let address: String?
    let height: Double?
    let owner: String?
    /// Contributions publiques sur le site (photos/validations), ajoutées par le
    /// backend au zoom ≥ 13. Pilotent le badge « photos » sur le marqueur.
    var photoCount: Int = 0
    var validationCount: Int = 0

    /// A site is mappable only with finite, in-range coordinates that aren't the
    /// 0,0 "null island" placeholder.
    var hasValidCoordinate: Bool {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite else { return false }
        if latitude == 0 && longitude == 0 { return false }
        return (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    enum CodingKeys: String, CodingKey {
        case id, siteId, sup_id, anfrCode
        case latitude, lat
        case longitude, lng, lon
        case operators, operatorList
        case technologies, techs, emr_lb_systeme, generation
        case bands, bandes, azimuts, azimuths
        case sharingType, crozonLeader
        case address, location, adr_lb_add1, adr_lb_lieu, adr_nm_cp, commune
        case height, sup_nm_haut, hauteur_antenne, structure_height
        case owner, proprietaire, sta_nm_anfr
    }

    init(
        id: String,
        siteId: String?,
        anfrCode: String? = nil,
        latitude: Double?,
        longitude: Double?,
        operators: [String],
        technologies: [String],
        bands: [Int],
        azimuths: [Double],
        sharingType: String?,
        crozonLeader: String?,
        address: String?,
        height: Double?,
        owner: String?
    ) {
        self.id = id
        self.siteId = siteId
        self.anfrCode = anfrCode
        self.latitude = latitude
        self.longitude = longitude
        self.operators = operators
        self.technologies = Self.normalizedTechnologies(technologies)
        self.bands = Self.normalizedBands(bands)
        self.azimuths = Self.normalizedAzimuths(azimuths)
        self.sharingType = sharingType
        self.crozonLeader = crozonLeader
        self.address = address
        self.height = height
        self.owner = owner
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id))
            ?? c.decodeFlexibleString(forKey: .siteId)
            ?? c.decodeFlexibleString(forKey: .sup_id)
            ?? c.decodeFlexibleString(forKey: .anfrCode)
            ?? UUID().uuidString
        siteId = c.decodeFlexibleString(forKey: .siteId) ?? c.decodeFlexibleString(forKey: .sup_id)
        anfrCode = c.decodeFlexibleString(forKey: .anfrCode) ?? c.decodeFlexibleString(forKey: .sta_nm_anfr)
        let latPrimary: Double? = (try? c.decodeIfPresent(Double.self, forKey: .latitude)) ?? nil
        let latFallback: Double? = (try? c.decodeIfPresent(Double.self, forKey: .lat)) ?? nil
        latitude = latPrimary ?? latFallback
        let lonPrimary: Double? = (try? c.decodeIfPresent(Double.self, forKey: .longitude)) ?? nil
        let lonFallback1: Double? = (try? c.decodeIfPresent(Double.self, forKey: .lng)) ?? nil
        let lonFallback2: Double? = (try? c.decodeIfPresent(Double.self, forKey: .lon)) ?? nil
        longitude = lonPrimary ?? lonFallback1 ?? lonFallback2
        operators = c.decodeLossyArray([String].self, forKey: .operators)
            + c.decodeLossyArray([String].self, forKey: .operatorList)
        let decodedTechnologies = c.decodeLossyArray([String].self, forKey: .technologies)
            + c.decodeLossyArray([String].self, forKey: .techs)
            + c.decodeLossyArray([String].self, forKey: .emr_lb_systeme)
            + [c.decodeFlexibleString(forKey: .generation)].compactMap { $0 }
        technologies = Self.normalizedTechnologies(decodedTechnologies)
        bands = Self.normalizedBands(
            c.decodeLossyArray([Int].self, forKey: .bands)
            + c.decodeLossyArray([Int].self, forKey: .bandes)
            + c.decodeLossyArray([String].self, forKey: .bands).compactMap(Self.parseBand)
            + c.decodeLossyArray([String].self, forKey: .bandes).compactMap(Self.parseBand)
        )
        azimuths = Self.normalizedAzimuths(
            c.decodeLossyArray([Double].self, forKey: .azimuts)
            + c.decodeLossyArray([Double].self, forKey: .azimuths)
            + c.decodeLossyArray([Int].self, forKey: .azimuts).map(Double.init)
            + c.decodeLossyArray([Int].self, forKey: .azimuths).map(Double.init)
        )
        sharingType = c.decodeFlexibleString(forKey: .sharingType)
        crozonLeader = c.decodeFlexibleString(forKey: .crozonLeader)
        let addressParts = [
            try? c.decodeIfPresent(String.self, forKey: .adr_lb_add1),
            try? c.decodeIfPresent(String.self, forKey: .adr_lb_lieu),
            try? c.decodeIfPresent(String.self, forKey: .adr_nm_cp),
            try? c.decodeIfPresent(String.self, forKey: .commune)
        ].compactMap { $0 }.filter { !$0.isEmpty }
        address = (try? c.decodeIfPresent(String.self, forKey: .address))
            ?? (try? c.decodeIfPresent(String.self, forKey: .location))
            ?? (addressParts.isEmpty ? nil : addressParts.joined(separator: " "))
        height = (try? c.decodeIfPresent(Double.self, forKey: .height))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .sup_nm_haut))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .hauteur_antenne))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .structure_height))
        let ownerValue = try? c.decodeIfPresent(String.self, forKey: .owner)
        let proprietaireValue = try? c.decodeIfPresent(String.self, forKey: .proprietaire)
        let anfrValue = try? c.decodeIfPresent(String.self, forKey: .sta_nm_anfr)
        owner = ownerValue ?? proprietaireValue ?? anfrValue
    }

    private static func normalizedTechnologies(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let upper = value.uppercased()
            let normalized: String?
            if upper.contains("5G") || upper.contains("NR") {
                normalized = "5G"
            } else if upper.contains("4G") || upper.contains("LTE") {
                normalized = "4G"
            } else if upper.contains("3G") || upper.contains("UMTS") {
                normalized = "3G"
            } else if upper.contains("2G") || upper.contains("GSM") {
                normalized = "2G"
            } else {
                normalized = value
            }
            if let normalized, !result.contains(normalized) {
                result.append(normalized)
            }
        }
        return ["5G", "4G", "3G", "2G"].filter(result.contains) + result.filter { !["5G", "4G", "3G", "2G"].contains($0) }
    }

    private static func parseBand(_ value: String) -> Int? {
        let digits = value.filter(\.isNumber)
        return Int(digits)
    }

    private static func normalizedBands(_ values: [Int]) -> [Int] {
        Array(Set(values.filter { $0 > 0 })).sorted()
    }

    private static func normalizedAzimuths(_ values: [Double]) -> [Double] {
        values
            .filter { $0.isFinite }
            .map { value in
                let normalized = value.truncatingRemainder(dividingBy: 360)
                return normalized < 0 ? normalized + 360 : normalized
            }
    }
}

struct AntennasListResponse: Decodable {
    let antennas: [AntennaSite]

    enum CodingKeys: String, CodingKey { case antennas, items, results }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        antennas = (try? c.decode([AntennaSite].self, forKey: .antennas))
            ?? (try? c.decode([AntennaSite].self, forKey: .items))
            ?? (try? c.decode([AntennaSite].self, forKey: .results))
            ?? []
    }
}

struct AntennaDetails: Decodable {
    let id: String
    let siteId: String?
    let operators: [String]
    let technologies: [String]
    let bands: [String]
    let sectors: [Int]
    let address: String?
    let height: Double?
    let validationsCount: Int?
    let photosCount: Int?
    let speedtestsCount: Int?
    let raw: [String: JSONValue]?
    let core: AntennaCoreDetails?
    let signalStats: AntennaSignalStats?
    let nearbySpeedtests: [NearbySpeedtest]
    let photos: [AntennaPhotoSummary]

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: WrapperKeys.self)
        if root.contains(.details), let nested = try? root.decode(AntennaDetails.self, forKey: .details) {
            self = nested
            return
        }
        if root.contains(.antenna), let antenna = try? root.decode(AntennaCoreDetails.self, forKey: .antenna) {
            let decodedSignalStats = try? root.decodeIfPresent(AntennaSignalStats.self, forKey: .signalStats)
            let decodedSpeedtests = root.decodeLossyArray([NearbySpeedtest].self, forKey: .nearbySpeedtests)
            let decodedPhotos = root.decodeLossyArray([AntennaPhotoSummary].self, forKey: .photos)
            id = antenna.id
            siteId = antenna.supId.isEmpty ? antenna.anfrCode : antenna.supId
            operators = antenna.operators
            technologies = antenna.technologies
            bands = antenna.frequencyBands
            sectors = antenna.azimuts.map { Int($0.rounded()) }
            address = antenna.fullAddress
            height = antenna.siteInfo.supportHeightMeters
                ?? antenna.siteInfo.antennaHeight5g.map(Double.init)
                ?? antenna.siteInfo.antennaHeight4g.map(Double.init)
            validationsCount = decodedSignalStats?.measurementCount
            photosCount = decodedPhotos.count
            speedtestsCount = decodedSpeedtests.count
            raw = nil
            core = antenna
            signalStats = decodedSignalStats
            nearbySpeedtests = decodedSpeedtests
            photos = decodedPhotos
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id))
            ?? c.decodeFlexibleString(forKey: .siteId)
            ?? c.decodeFlexibleString(forKey: .sup_id)
            ?? UUID().uuidString
        siteId = c.decodeFlexibleString(forKey: .siteId) ?? c.decodeFlexibleString(forKey: .sup_id)
        operators = c.decodeLossyArray([String].self, forKey: .operators)
            + c.decodeLossyArray([String].self, forKey: .operatorList)
        technologies = c.decodeLossyArray([String].self, forKey: .technologies)
            + c.decodeLossyArray([String].self, forKey: .techs)
            + c.decodeLossyArray([String].self, forKey: .emr_lb_systeme)
        bands = c.decodeLossyArray([String].self, forKey: .bands)
        sectors = c.decodeLossyArray([Int].self, forKey: .sectors)
            + c.decodeLossyArray([Int].self, forKey: .azimuts)
        address = (try? c.decodeIfPresent(String.self, forKey: .address))
            ?? [try? c.decodeIfPresent(String.self, forKey: .adr_lb_add1), try? c.decodeIfPresent(String.self, forKey: .adr_lb_lieu), try? c.decodeIfPresent(String.self, forKey: .commune)]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        height = (try? c.decodeIfPresent(Double.self, forKey: .height))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .sup_nm_haut))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .hauteur_antenne))
        validationsCount = try c.decodeIfPresent(Int.self, forKey: .validationsCount)
        photosCount = try c.decodeIfPresent(Int.self, forKey: .photosCount)
        speedtestsCount = try c.decodeIfPresent(Int.self, forKey: .speedtestsCount)
        raw = try c.decodeIfPresent([String: JSONValue].self, forKey: .raw)
        core = nil
        signalStats = nil
        nearbySpeedtests = []
        photos = []
    }

    enum CodingKeys: String, CodingKey {
        case id, siteId, sup_id, operators, operatorList, technologies, techs, emr_lb_systeme, bands, sectors, azimuts, address
        case adr_lb_add1, adr_lb_lieu, commune, height, sup_nm_haut, hauteur_antenne, validationsCount, photosCount, speedtestsCount, raw
    }

    enum WrapperKeys: String, CodingKey {
        case details, antenna, signalStats, nearbySpeedtests, photos
    }
}

struct AntennaCoreDetails: Decodable, Equatable {
    let id: String
    let supId: String
    let siteKey: String?
    let anfrCode: String
    let market: String?
    let rawLicenseeName: String?
    let lat: Double
    let lng: Double
    let address: String?
    let commune: String?
    let postalCode: String?
    let operators: [String]
    let operatorScope: String?
    let operatorFacets: [String]
    let sharingKind: String?
    let crozonLeader: String?
    let zbLeader: String?
    let technologies: [String]
    let azimuts: [Double]
    let technical: AntennaTechnicalInfo
    let frequencyBands: [String]
    let radioCarriers: [AntennaRadioCarrier]
    let cellIdentifiers: AntennaCellIdentifiers
    let siteInfo: AntennaSiteInfo

    var fullAddress: String? {
        let values = [address, postalCode, commune]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case id, supId, siteKey, anfrCode, market, rawLicenseeName, lat, lng, address, commune, postalCode, operators, operatorScope, operatorFacets, sharingKind, crozonLeader, zbLeader, technologies, azimuts, technical, frequencyBands, radioCarriers, cellIdentifiers, siteInfo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? c.decodeFlexibleString(forKey: .supId) ?? UUID().uuidString
        supId = c.decodeFlexibleString(forKey: .supId) ?? id
        siteKey = c.decodeFlexibleString(forKey: .siteKey)
        anfrCode = c.decodeFlexibleString(forKey: .anfrCode) ?? ""
        market = c.decodeFlexibleString(forKey: .market)
        rawLicenseeName = c.decodeFlexibleString(forKey: .rawLicenseeName)
        lat = (try? c.decode(Double.self, forKey: .lat)) ?? 0
        lng = (try? c.decode(Double.self, forKey: .lng)) ?? 0
        address = c.decodeFlexibleString(forKey: .address)
        commune = c.decodeFlexibleString(forKey: .commune)
        postalCode = c.decodeFlexibleString(forKey: .postalCode)
        operators = c.decodeLossyArray([String].self, forKey: .operators)
        operatorScope = c.decodeFlexibleString(forKey: .operatorScope)
        operatorFacets = c.decodeLossyArray([String].self, forKey: .operatorFacets)
        sharingKind = c.decodeFlexibleString(forKey: .sharingKind)
        crozonLeader = c.decodeFlexibleString(forKey: .crozonLeader)
        zbLeader = c.decodeFlexibleString(forKey: .zbLeader)
        technologies = c.decodeLossyArray([String].self, forKey: .technologies)
        azimuts = c.decodeLossyArray([Double].self, forKey: .azimuts)
        technical = (try? c.decode(AntennaTechnicalInfo.self, forKey: .technical)) ?? AntennaTechnicalInfo()
        frequencyBands = c.decodeLossyArray([String].self, forKey: .frequencyBands)
        radioCarriers = c.decodeLossyArray([AntennaRadioCarrier].self, forKey: .radioCarriers)
        cellIdentifiers = (try? c.decode(AntennaCellIdentifiers.self, forKey: .cellIdentifiers)) ?? AntennaCellIdentifiers()
        siteInfo = (try? c.decode(AntennaSiteInfo.self, forKey: .siteInfo)) ?? AntennaSiteInfo()
    }
}

struct AntennaRadioCarrier: Decodable, Equatable, Identifiable {
    let id: String
    let source: String?
    let technology: String?
    let band: Int?
    let bandLabel: String?
    let txFrequencyMhz: Double?
    let rxFrequencyMhz: Double?
    let bandwidthMhz: Double?
    let effectiveDownlinkBandwidthMhz: Double?
    let downlinkAllocationPercent: Double?
    let txPowerDbm: Double?
    let sectorAzimuthDeg: Double?
    let sectorBeamwidthDeg: Double?
    let antennaType: String?
    let cellIds: [String]
    let physicalIds: [String]
    let dateLastChanged: String?
}

struct AntennaTechnicalInfo: Decodable, Equatable {
    let generation: String?
    let hasFh: Bool?
    let supportType: String?

    init(generation: String? = nil, hasFh: Bool? = nil, supportType: String? = nil) {
        self.generation = generation
        self.hasFh = hasFh
        self.supportType = supportType
    }
}

struct AntennaCellIdentifiers: Decodable, Equatable {
    let enb: [String]
    let gnb: [String]
    let pci: [AntennaPciEntry]
    let cellId: [AntennaCellIdEntry]

    init(enb: [String] = [], gnb: [String] = [], pci: [AntennaPciEntry] = [], cellId: [AntennaCellIdEntry] = []) {
        self.enb = enb
        self.gnb = gnb
        self.pci = pci
        self.cellId = cellId
    }
}

struct AntennaPciEntry: Decodable, Equatable, Identifiable {
    var id: String { [value, tech, band.map(String.init), sector.map(String.init)].compactMap { $0 }.joined(separator: "-") }
    let value: String
    let sector: Int?
    let tech: String?
    let band: Int?
    let frequency: String?
}

struct AntennaCellIdEntry: Decodable, Equatable, Identifiable {
    var id: String { [value, pci, tech, band.map(String.init)].compactMap { $0 }.joined(separator: "-") }
    let value: String
    let pci: String?
    let tech: String?
    let band: Int?
    let frequency: String?
    let earfcn: Int?
    let arfcn: Int?
}

struct AntennaSiteInfo: Decodable, Equatable {
    let supportType: String?
    let supportHeight: String?
    let supportOwner: String?
    let sectorCount: Int?
    let antennaHeight4g: Int?
    let antennaHeight5g: Int?
    let firstActivation: String?
    let lastCommissioned: String?

    init(
        supportType: String? = nil,
        supportHeight: String? = nil,
        supportOwner: String? = nil,
        sectorCount: Int? = nil,
        antennaHeight4g: Int? = nil,
        antennaHeight5g: Int? = nil,
        firstActivation: String? = nil,
        lastCommissioned: String? = nil
    ) {
        self.supportType = supportType
        self.supportHeight = supportHeight
        self.supportOwner = supportOwner
        self.sectorCount = sectorCount
        self.antennaHeight4g = antennaHeight4g
        self.antennaHeight5g = antennaHeight5g
        self.firstActivation = firstActivation
        self.lastCommissioned = lastCommissioned
    }

    var supportHeightMeters: Double? {
        guard let supportHeight else { return nil }
        let normalized = supportHeight.replacingOccurrences(of: ",", with: ".")
        let value = normalized.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(value)
    }
}

struct AntennaSignalStats: Decodable, Equatable {
    let avgRsrp: Double?
    let avgRsrq: Double?
    let avgSnr: Double?
    let tac: String?
    let measurementCount: Int
    let lastMeasurement: String?
}

struct NearbySpeedtest: Decodable, Equatable, Identifiable {
    let id: String
    let downloadMbps: Double
    let uploadMbps: Double?
    let pingMs: Double?
    let rsrp: Int?
    let rsrq: Int?
    let snr: Double?
    let tech: String?
    let timestamp: String?
}

struct AntennaPhotoSummary: Decodable, Equatable, Identifiable {
    let id: String
    let imageUrl: URL?
    let thumbnailUrl: URL?
    let description: String?
    let uploadedAt: String?
    let likes: Int?
    let userName: String?
    let userReaction: String?
    let socialPostId: String?
    let commentCount: Int?
    let repostsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, imageUrl, thumbnailUrl, description, uploadedAt, likes, userName, userReaction, socialPostId, commentCount, repostsCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        imageUrl = c.decodeLossyURL(forKey: .imageUrl)
        thumbnailUrl = c.decodeLossyURL(forKey: .thumbnailUrl)
        description = c.decodeFlexibleString(forKey: .description)
        uploadedAt = c.decodeFlexibleString(forKey: .uploadedAt)
        likes = try? c.decodeIfPresent(Int.self, forKey: .likes)
        userName = c.decodeFlexibleString(forKey: .userName)
        userReaction = c.decodeFlexibleString(forKey: .userReaction)
        socialPostId = c.decodeFlexibleString(forKey: .socialPostId)
        commentCount = try? c.decodeIfPresent(Int.self, forKey: .commentCount)
        repostsCount = try? c.decodeIfPresent(Int.self, forKey: .repostsCount)
    }
}
