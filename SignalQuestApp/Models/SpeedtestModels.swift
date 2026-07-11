import Foundation

struct SpeedtestSessionResponse: Codable, Equatable {
    let sessionToken: String
    let sessionId: String
    let expiresAt: Date?
    let expiresAtEpochMs: Double?
    let downloadUrl: URL
    let uploadUrl: URL
    let uploadBeginUrl: URL?
    let uploadFinalizeUrl: URL?
    let maxDownloadBytesPerRequest: Int?
    let maxUploadBytesPerRequest: Int?
    let sessionMaxDownloadBytes: Int?
    let sessionMaxUploadBytes: Int?
    let maxStreams: Int?
    let requestedStreams: Int?
    let durationSec: Int?
    let maxDurationSec: Int?
    let selectedServer: SpeedtestServer?
}

struct SpeedtestServer: Codable, Equatable {
    let id: String?
    let name: String?
    let host: String?
    let location: String?
    let lat: Double?
    let lon: Double?
    let country: String?
}

enum SpeedtestDownloadTarget: String, Codable, CaseIterable, Identifiable {
    /// Sélection automatique (défaut) : préflight au début de la phase DL —
    /// 256 Ko lus sur chaque candidat, le plus rapide gagne (parité Android
    /// `hybrid_auto`). Le ping suit la cible retenue.
    case hybridAuto = "hybrid_auto"
    case cloudflareR2 = "cloudflare_r2"
    case awsCloudFront = "aws_cloudfront"
    /// Cible retirée des choix (TTFB 2× supérieur aux CDN) : le case reste
    /// pour décoder les préférences déjà stockées, migrées vers `.hybridAuto`.
    /// Le VPS reste le serveur d'UPLOAD (mesure certifiée) et le repli DL si
    /// les CDN sont injoignables.
    case vpsInternal = "vps_internal"

    var id: String { rawValue }

    /// Cases proposés à l'utilisateur (réglages).
    static var selectableCases: [SpeedtestDownloadTarget] {
        [.hybridAuto, .cloudflareR2, .awsCloudFront]
    }

    /// Migration douce : une préférence VPS stockée redevient « Auto ».
    var migrated: SpeedtestDownloadTarget {
        self == .vpsInternal ? .hybridAuto : self
    }

    var displayName: String {
        switch self {
        case .hybridAuto: return "Auto"
        case .cloudflareR2: return "Cloudflare"
        case .awsCloudFront: return "AWS CloudFront"
        case .vpsInternal: return "VPS OVH Gravelines"
        }
    }
}

struct SpeedtestRunSettings: Codable, Equatable {
    var downloadTarget: SpeedtestDownloadTarget
    var durationSeconds: Int
    var streams: Int
    var reliabilityMode: Bool

    static let androidDefault = SpeedtestRunSettings(
        downloadTarget: .hybridAuto,
        durationSeconds: 10,
        streams: 16,
        reliabilityMode: true
    )
}

struct SpeedtestRunResult: Codable, Identifiable, Equatable {
    let id: UUID
    let label: String
    let downloadMbps: Double
    let downloadAverageMbps: Double
    let downloadMaxMbps: Double
    let downloadP90Mbps: Double?
    let downloadP95Mbps: Double?
    let uploadMbps: Double?
    let uploadAverageMbps: Double?
    let uploadMaxMbps: Double?
    let uploadP90Mbps: Double?
    let uploadP95Mbps: Double?
    let pingMs: Double?
    let pingMedianMs: Double?
    let pingMinMs: Double?
    let pingMaxMs: Double?
    let jitterMs: Double?
    let pingDlMs: Double?
    let jitterDlMs: Double?
    let pingUlMs: Double?
    let jitterUlMs: Double?
    let pingProtocol: String?
    let durationSeconds: Double
    let connectionType: NetworkConnectionKind
    let cellularTechnology: CellularRadioTechnology?
    let networkOperatorName: String?
    let networkOperatorMcc: Int?
    let networkOperatorMnc: Int?
    let marketCode: String?
    let operatorKey: String?
    let wifiSSID: String?
    let city: String?
    /// Adresse (rue + commune) reverse-géocodée du point de mesure. Envoyée au
    /// backend pour situer le test ; volontairement sans numéro de voirie pour
    /// rester cohérent avec la minimisation des coordonnées (RGPD art. 5.1.c).
    let address: String?
    let coordinate: Coordinates?
    /// Serveur de MESURE (VPS sélectionné par la session). C'est lui qui réalise
    /// l'upload et sert de référence pour la latence/le partage.
    let serverName: String?
    /// Origine des octets de download (ex. CDN CloudFront) quand elle diffère du
    /// serveur de mesure. Distinct de `serverName` pour ne plus afficher « AWS »
    /// comme serveur de test.
    let downloadServerName: String?
    /// Id de cible CDN soumis au backend (cloudflare_r2 / aws_cloudfront /
    /// vps_internal) + code POP edge réel (x-amz-cf-pop / cf-ray) — télémétrie
    /// de diagnostic des chemins CDN (parité Android).
    let downloadServerId: String?
    let downloadServerCode: String?
    let createdAt: Date
    let downloadSeriesMbps: [Double]?
    let uploadSeriesMbps: [Double]?
    let uploadMeasurementSource: String?
    let deviceModel: String?
    let osVersion: String?

    init(
        id: UUID = UUID(),
        label: String,
        downloadMbps: Double,
        downloadAverageMbps: Double,
        downloadMaxMbps: Double,
        downloadP90Mbps: Double? = nil,
        downloadP95Mbps: Double? = nil,
        uploadMbps: Double? = nil,
        uploadAverageMbps: Double? = nil,
        uploadMaxMbps: Double? = nil,
        uploadP90Mbps: Double? = nil,
        uploadP95Mbps: Double? = nil,
        pingMs: Double? = nil,
        pingMedianMs: Double? = nil,
        pingMinMs: Double? = nil,
        pingMaxMs: Double? = nil,
        jitterMs: Double? = nil,
        pingDlMs: Double? = nil,
        jitterDlMs: Double? = nil,
        pingUlMs: Double? = nil,
        jitterUlMs: Double? = nil,
        pingProtocol: String? = nil,
        durationSeconds: Double,
        connectionType: NetworkConnectionKind,
        cellularTechnology: CellularRadioTechnology? = nil,
        networkOperatorName: String? = nil,
        networkOperatorMcc: Int? = nil,
        networkOperatorMnc: Int? = nil,
        marketCode: String? = nil,
        operatorKey: String? = nil,
        wifiSSID: String? = nil,
        city: String? = nil,
        address: String? = nil,
        coordinate: Coordinates? = nil,
        serverName: String? = nil,
        downloadServerName: String? = nil,
        downloadServerId: String? = nil,
        downloadServerCode: String? = nil,
        createdAt: Date = Date(),
        downloadSeriesMbps: [Double]? = nil,
        uploadSeriesMbps: [Double]? = nil,
        uploadMeasurementSource: String? = nil,
        deviceModel: String? = nil,
        osVersion: String? = nil
    ) {
        self.id = id
        self.label = label
        self.downloadMbps = downloadMbps
        self.downloadAverageMbps = downloadAverageMbps
        self.downloadMaxMbps = downloadMaxMbps
        self.downloadP90Mbps = downloadP90Mbps
        self.downloadP95Mbps = downloadP95Mbps
        self.uploadMbps = uploadMbps
        self.uploadAverageMbps = uploadAverageMbps
        self.uploadMaxMbps = uploadMaxMbps
        self.uploadP90Mbps = uploadP90Mbps
        self.uploadP95Mbps = uploadP95Mbps
        self.pingMs = pingMs
        self.pingMedianMs = pingMedianMs
        self.pingMinMs = pingMinMs
        self.pingMaxMs = pingMaxMs
        self.jitterMs = jitterMs
        self.pingDlMs = pingDlMs
        self.jitterDlMs = jitterDlMs
        self.pingUlMs = pingUlMs
        self.jitterUlMs = jitterUlMs
        self.pingProtocol = pingProtocol
        self.durationSeconds = durationSeconds
        self.connectionType = connectionType
        self.cellularTechnology = cellularTechnology
        self.networkOperatorName = networkOperatorName
        self.networkOperatorMcc = networkOperatorMcc
        self.networkOperatorMnc = networkOperatorMnc
        self.marketCode = marketCode
        self.operatorKey = operatorKey
        self.wifiSSID = wifiSSID
        self.city = city
        self.address = address
        self.coordinate = coordinate
        self.serverName = serverName
        self.downloadServerName = downloadServerName
        self.downloadServerId = downloadServerId
        self.downloadServerCode = downloadServerCode
        self.createdAt = createdAt
        self.downloadSeriesMbps = downloadSeriesMbps
        self.uploadSeriesMbps = uploadSeriesMbps
        self.uploadMeasurementSource = uploadMeasurementSource
        self.deviceModel = deviceModel
        self.osVersion = osVersion
    }

    var networkDisplayName: String {
        switch connectionType {
        case .wifi:
            return "WiFi"
        case .cellular:
            return cellularTechnology?.displayName ?? "Cellulaire"
        case .wired:
            return "Ethernet"
        case .other:
            return "Autre"
        }
    }

    var networkShareDisplayName: String {
        switch connectionType {
        case .wifi:
            // Affiche le FAI (résolu par IP, porté par networkOperatorName) plutôt
            // que le SSID — plus parlant et évite d'exposer le nom du réseau privé.
            if let fai = networkOperatorName?.trimmingCharacters(in: .whitespacesAndNewlines), !fai.isEmpty {
                return "\(fai) • WiFi"
            }
            return "WiFi"
        case .cellular:
            let technology = cellularTechnology?.displayName
            switch (networkOperatorName, technology) {
            case let (.some(operatorName), .some(technology)):
                return "\(operatorName) \(technology)"
            case let (.some(operatorName), .none):
                return operatorName
            case let (.none, .some(technology)):
                return technology
            case (.none, .none):
                return "Cellulaire"
            }
        case .wired, .other:
            return networkDisplayName
        }
    }

    var speedtestConnectionType: String {
        switch connectionType {
        case .cellular:
            return cellularTechnology?.displayName ?? connectionType.rawValue
        default:
            return connectionType.rawValue
        }
    }

    static let empty = SpeedtestRunResult(
        id: UUID(),
        label: "iOS speedtest — métriques radio non disponibles",
        downloadMbps: 0,
        downloadAverageMbps: 0,
        downloadMaxMbps: 0,
        downloadP90Mbps: nil,
        downloadP95Mbps: nil,
        uploadMbps: nil,
        uploadAverageMbps: nil,
        uploadMaxMbps: nil,
        uploadP90Mbps: nil,
        uploadP95Mbps: nil,
        pingMs: nil,
        pingMedianMs: nil,
        pingMinMs: nil,
        pingMaxMs: nil,
        jitterMs: nil,
        pingDlMs: nil,
        jitterDlMs: nil,
        pingUlMs: nil,
        jitterUlMs: nil,
        pingProtocol: nil,
        durationSeconds: 0,
        connectionType: .other,
        cellularTechnology: nil,
        networkOperatorName: nil,
        networkOperatorMcc: nil,
        networkOperatorMnc: nil,
        marketCode: nil,
        operatorKey: nil,
        wifiSSID: nil,
        city: nil,
        coordinate: nil,
        serverName: nil,
        downloadServerName: nil,
        downloadServerId: nil,
        downloadServerCode: nil,
        createdAt: Date(),
        downloadSeriesMbps: nil,
        uploadSeriesMbps: nil,
        uploadMeasurementSource: nil,
        deviceModel: nil,
        osVersion: nil
    )
}

enum NetworkConnectionKind: String, Codable, Equatable, CaseIterable, Sendable {
    case cellular = "CELLULAR"
    case wifi = "WIFI"
    case wired = "WIRED"
    case other = "OTHER"
}

struct Coordinates: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct DeviceInfo: Codable, Equatable {
    let type: String
    let model: String
}

struct SpeedtestSubmission: Encodable, Equatable {
    let clientSubmissionId: String
    let downloadSpeed: Double
    let averageSpeed: Double
    let maxSpeed: Double
    let uploadSpeed: Double?
    let uploadAvg: Double?
    let uploadMax: Double?
    let downloadAvg: Double
    let downloadP90: Double?
    let downloadP95: Double?
    let downloadPeakMbps: Double?
    let downloadMax: Double?
    let uploadP90: Double?
    let uploadP95: Double?
    let uploadPeakMbps: Double?
    let ping: Double?
    let pingAvg: Double?
    let pingMedian: Double?
    let pingMin: Double?
    let pingMax: Double?
    let pingProtocol: String?
    let jitter: Double?
    let pingDl: Double?
    let jitterDl: Double?
    let pingUl: Double?
    let jitterUl: Double?
    let testDuration: Double
    let streams: Int
    let connectionType: String
    let networkType: String
    let coordinates: Coordinates?
    let city: String?
    let address: String?
    let mobileOperator: String?
    let mcc: Int?
    let mnc: Int?
    let marketCode: String?
    let operatorKey: String?
    let device: DeviceInfo
    let deviceType: String
    let deviceModel: String
    let isVisibleOnMap: Bool
    let shareExactLocation: Bool
    let guestDeleteToken: String?
    let server: String?
    let downloadServerName: String?
    let downloadServerId: String?
    let downloadServerCode: String?

    enum CodingKeys: String, CodingKey {
        case clientSubmissionId, downloadSpeed, averageSpeed, maxSpeed, uploadSpeed, uploadAvg, uploadMax, downloadAvg, downloadP90, downloadP95, downloadPeakMbps, downloadMax, uploadP90, uploadP95, uploadPeakMbps, ping, pingAvg, pingMedian, pingMin, pingMax, pingProtocol, jitter, testDuration, streams, connectionType, networkType, coordinates, city, address, mobileOperator, mcc, mnc, marketCode, operatorKey, device, deviceType, deviceModel, isVisibleOnMap, shareExactLocation, guestDeleteToken, server, downloadServerName, downloadServerId, downloadServerCode
        case rsrp, rsrq, snr, cellId, pci, enb, gnb, radioSnapshots
        case pingDl, jitterDl, pingUl, jitterUl
    }

    /// Réduit la précision des coordonnées avant tout envoi au backend, pour
    /// respecter la minimisation (RGPD art. 5.1.c). 3 décimales ≈ 111 m, cohérent
    /// avec `kCLLocationAccuracyHundredMeters` utilisé par LocationService.
    static func minimizedCoordinates(_ coordinate: Coordinates?) -> Coordinates? {
        guard let coordinate else { return nil }
        func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        return Coordinates(
            latitude: round3(coordinate.latitude),
            longitude: round3(coordinate.longitude)
        )
    }

    static func iosPayload(
        from result: SpeedtestRunResult,
        streams: Int,
        deviceModel: String,
        mobileOperator: String? = nil,
        isVisibleOnMap: Bool = false,
        shareExactLocation: Bool = false,
        guestDeleteToken: String? = nil
    ) -> SpeedtestSubmission {
        SpeedtestSubmission(
            clientSubmissionId: result.id.uuidString,
            downloadSpeed: result.downloadAverageMbps,
            averageSpeed: result.downloadAverageMbps,
            maxSpeed: result.downloadP90Mbps ?? result.downloadAverageMbps,
            uploadSpeed: result.uploadAverageMbps,
            uploadAvg: result.uploadAverageMbps,
            uploadMax: result.uploadMaxMbps,
            downloadAvg: result.downloadAverageMbps,
            downloadP90: result.downloadP90Mbps,
            downloadP95: result.downloadP95Mbps,
            downloadPeakMbps: result.downloadMaxMbps,
            downloadMax: result.downloadMaxMbps,
            uploadP90: result.uploadP90Mbps,
            uploadP95: result.uploadP95Mbps,
            uploadPeakMbps: result.uploadMaxMbps,
            ping: result.pingMinMs ?? result.pingMs,
            pingAvg: result.pingMs,
            pingMedian: result.pingMedianMs,
            pingMin: result.pingMinMs,
            pingMax: result.pingMaxMs,
            pingProtocol: result.pingProtocol,
            jitter: result.jitterMs,
            pingDl: result.pingDlMs,
            jitterDl: result.jitterDlMs,
            pingUl: result.pingUlMs,
            jitterUl: result.jitterUlMs,
            testDuration: result.durationSeconds,
            streams: streams,
            connectionType: result.speedtestConnectionType,
            networkType: result.connectionType.rawValue,
            coordinates: shareExactLocation ? result.coordinate : minimizedCoordinates(result.coordinate),
            city: result.city,
            address: result.address,
            mobileOperator: mobileOperator ?? result.networkOperatorName,
            mcc: result.networkOperatorMcc,
            mnc: result.networkOperatorMnc,
            marketCode: result.marketCode,
            operatorKey: result.operatorKey,
            device: DeviceInfo(type: "iPhone", model: deviceModel),
            deviceType: "iPhone",
            deviceModel: deviceModel,
            isVisibleOnMap: isVisibleOnMap,
            shareExactLocation: shareExactLocation,
            guestDeleteToken: guestDeleteToken,
            server: result.serverName,
            downloadServerName: result.downloadServerName ?? result.serverName,
            downloadServerId: result.downloadServerId,
            downloadServerCode: result.downloadServerCode
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientSubmissionId, forKey: .clientSubmissionId)
        try c.encode(downloadSpeed, forKey: .downloadSpeed)
        try c.encode(averageSpeed, forKey: .averageSpeed)
        try c.encode(maxSpeed, forKey: .maxSpeed)
        try c.encodeIfPresent(uploadSpeed, forKey: .uploadSpeed)
        try c.encodeIfPresent(uploadAvg, forKey: .uploadAvg)
        try c.encodeIfPresent(uploadMax, forKey: .uploadMax)
        try c.encode(downloadAvg, forKey: .downloadAvg)
        try c.encodeIfPresent(downloadP90, forKey: .downloadP90)
        try c.encodeIfPresent(downloadP95, forKey: .downloadP95)
        try c.encodeIfPresent(downloadPeakMbps, forKey: .downloadPeakMbps)
        try c.encodeIfPresent(downloadMax, forKey: .downloadMax)
        try c.encodeIfPresent(uploadP90, forKey: .uploadP90)
        try c.encodeIfPresent(uploadP95, forKey: .uploadP95)
        try c.encodeIfPresent(uploadPeakMbps, forKey: .uploadPeakMbps)
        try c.encodeIfPresent(ping, forKey: .ping)
        try c.encodeIfPresent(pingAvg, forKey: .pingAvg)
        try c.encodeIfPresent(pingMedian, forKey: .pingMedian)
        try c.encodeIfPresent(pingMin, forKey: .pingMin)
        try c.encodeIfPresent(pingMax, forKey: .pingMax)
        try c.encodeIfPresent(pingProtocol, forKey: .pingProtocol)
        try c.encodeIfPresent(jitter, forKey: .jitter)
        try c.encodeIfPresent(pingDl, forKey: .pingDl)
        try c.encodeIfPresent(jitterDl, forKey: .jitterDl)
        try c.encodeIfPresent(pingUl, forKey: .pingUl)
        try c.encodeIfPresent(jitterUl, forKey: .jitterUl)
        try c.encode(testDuration, forKey: .testDuration)
        try c.encode(streams, forKey: .streams)
        try c.encode(connectionType, forKey: .connectionType)
        try c.encode(networkType, forKey: .networkType)
        try c.encodeIfPresent(coordinates, forKey: .coordinates)
        try c.encodeIfPresent(city, forKey: .city)
        try c.encodeIfPresent(address, forKey: .address)
        try c.encodeIfPresent(mobileOperator, forKey: .mobileOperator)
        try c.encodeIfPresent(mcc, forKey: .mcc)
        try c.encodeIfPresent(mnc, forKey: .mnc)
        try c.encodeIfPresent(marketCode, forKey: .marketCode)
        try c.encodeIfPresent(operatorKey, forKey: .operatorKey)
        try c.encode(device, forKey: .device)
        try c.encode(deviceType, forKey: .deviceType)
        try c.encode(deviceModel, forKey: .deviceModel)
        try c.encode(isVisibleOnMap, forKey: .isVisibleOnMap)
        try c.encode(shareExactLocation, forKey: .shareExactLocation)
        try c.encodeIfPresent(guestDeleteToken, forKey: .guestDeleteToken)
        try c.encodeIfPresent(server, forKey: .server)
        try c.encodeIfPresent(downloadServerName, forKey: .downloadServerName)
        try c.encodeIfPresent(downloadServerId, forKey: .downloadServerId)
        try c.encodeIfPresent(downloadServerCode, forKey: .downloadServerCode)
        try c.encodeNil(forKey: .rsrp)
        try c.encodeNil(forKey: .rsrq)
        try c.encodeNil(forKey: .snr)
        try c.encodeNil(forKey: .cellId)
        try c.encodeNil(forKey: .pci)
        try c.encodeNil(forKey: .enb)
        try c.encodeNil(forKey: .gnb)
        try c.encodeNil(forKey: .radioSnapshots)
    }
}

struct SpeedtestSaveResponse: Codable {
    let success: Bool
    let id: String?
    let data: JSONValue?
    let requestId: String?
    /// Renvoyé uniquement à la création anonyme. Le serveur n'en conserve que le hash.
    let deleteToken: String?

    /// Le backend historique renvoie `data.id` lors de la création et `id` lors
    /// d'un rejeu idempotent. Accepter les deux évite de perdre le reçu invité
    /// précisément lorsque le premier POST a réussi.
    var resolvedID: String? {
        if let id, !id.isEmpty { return id }
        guard case .object(let object) = data,
              case .string(let nestedID) = object["id"],
              !nestedID.isEmpty else { return nil }
        return nestedID
    }
}

struct SpeedtestDetail: Decodable, Identifiable, Equatable {
    let id: String
    let timestamp: Date?
    let createdAt: Date?
    let downloadSpeed: Double?
    let maxSpeed: Double?
    let averageSpeed: Double?
    let downloadAvg: Double?
    let downloadP90: Double?
    let downloadP95: Double?
    let downloadMax: Double?
    let downloadPeakMbps: Double?
    let testDuration: Double?
    let streams: Int?
    let uploadSpeed: Double?
    let uploadAvg: Double?
    let uploadMax: Double?
    let uploadP90: Double?
    let uploadP95: Double?
    let uploadPeakMbps: Double?
    let ping: Double?
    let pingAvg: Double?
    let pingMedian: Double?
    let pingMin: Double?
    let pingMax: Double?
    let pingProtocol: String?
    let jitter: Double?
    let pingDl: Double?
    let jitterDl: Double?
    let pingUl: Double?
    let jitterUl: Double?
    let server: String?
    let downloadServerId: String?
    let downloadServerName: String?
    let connectionType: String?
    let networkType: String?
    let mobileOperator: String?
    let mcc: Int?
    let mnc: Int?
    let latitude: Double?
    let longitude: Double?
    let address: String?
    let locationBlurred: Bool?
    let deviceType: String?
    let deviceModel: String?
    let isPublic: Bool?
    let isVisibleOnMap: Bool?
    let shareExactLocation: Bool?
    let isOwner: Bool?
    let rsrp: Double?
    let rsrq: Double?
    let snr: Double?
    let timingAdvance: Double?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, createdAt, downloadSpeed, maxSpeed, averageSpeed, downloadAvg, downloadP90, downloadP95, downloadMax, downloadPeakMbps, testDuration, streams, uploadSpeed, uploadAvg, uploadMax, uploadP90, uploadP95, uploadPeakMbps, ping, pingAvg, pingMedian, pingMin, pingMax, pingProtocol, jitter, server, downloadServerId, downloadServerName, connectionType, networkType, mobileOperator, mcc, mnc, latitude, longitude, address, locationBlurred, deviceType, deviceModel, isPublic, isVisibleOnMap, shareExactLocation, isOwner, rsrp, rsrq, snr, timingAdvance
        case pingDl, jitterDl, pingUl, jitterUl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        timestamp = try? c.decodeIfPresent(Date.self, forKey: .timestamp)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        downloadSpeed = try? c.decodeIfPresent(Double.self, forKey: .downloadSpeed)
        maxSpeed = try? c.decodeIfPresent(Double.self, forKey: .maxSpeed)
        averageSpeed = try? c.decodeIfPresent(Double.self, forKey: .averageSpeed)
        downloadAvg = try? c.decodeIfPresent(Double.self, forKey: .downloadAvg)
        downloadP90 = try? c.decodeIfPresent(Double.self, forKey: .downloadP90)
        downloadP95 = try? c.decodeIfPresent(Double.self, forKey: .downloadP95)
        downloadMax = try? c.decodeIfPresent(Double.self, forKey: .downloadMax)
        downloadPeakMbps = try? c.decodeIfPresent(Double.self, forKey: .downloadPeakMbps)
        testDuration = try? c.decodeIfPresent(Double.self, forKey: .testDuration)
        streams = try? c.decodeIfPresent(Int.self, forKey: .streams)
        uploadSpeed = try? c.decodeIfPresent(Double.self, forKey: .uploadSpeed)
        uploadAvg = try? c.decodeIfPresent(Double.self, forKey: .uploadAvg)
        uploadMax = try? c.decodeIfPresent(Double.self, forKey: .uploadMax)
        uploadP90 = try? c.decodeIfPresent(Double.self, forKey: .uploadP90)
        uploadP95 = try? c.decodeIfPresent(Double.self, forKey: .uploadP95)
        uploadPeakMbps = try? c.decodeIfPresent(Double.self, forKey: .uploadPeakMbps)
        ping = try? c.decodeIfPresent(Double.self, forKey: .ping)
        pingAvg = try? c.decodeIfPresent(Double.self, forKey: .pingAvg)
        pingMedian = try? c.decodeIfPresent(Double.self, forKey: .pingMedian)
        pingMin = try? c.decodeIfPresent(Double.self, forKey: .pingMin)
        pingMax = try? c.decodeIfPresent(Double.self, forKey: .pingMax)
        pingProtocol = c.decodeFlexibleString(forKey: .pingProtocol)
        jitter = try? c.decodeIfPresent(Double.self, forKey: .jitter)
        pingDl = try? c.decodeIfPresent(Double.self, forKey: .pingDl)
        jitterDl = try? c.decodeIfPresent(Double.self, forKey: .jitterDl)
        pingUl = try? c.decodeIfPresent(Double.self, forKey: .pingUl)
        jitterUl = try? c.decodeIfPresent(Double.self, forKey: .jitterUl)
        server = c.decodeFlexibleString(forKey: .server)
        downloadServerId = c.decodeFlexibleString(forKey: .downloadServerId)
        downloadServerName = c.decodeFlexibleString(forKey: .downloadServerName)
        connectionType = c.decodeFlexibleString(forKey: .connectionType)
        networkType = c.decodeFlexibleString(forKey: .networkType)
        mobileOperator = c.decodeFlexibleString(forKey: .mobileOperator)
        mcc = try? c.decodeIfPresent(Int.self, forKey: .mcc)
        mnc = try? c.decodeIfPresent(Int.self, forKey: .mnc)
        latitude = try? c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .longitude)
        address = c.decodeFlexibleString(forKey: .address)
        locationBlurred = try? c.decodeIfPresent(Bool.self, forKey: .locationBlurred)
        deviceType = c.decodeFlexibleString(forKey: .deviceType)
        deviceModel = c.decodeFlexibleString(forKey: .deviceModel)
        isPublic = try? c.decodeIfPresent(Bool.self, forKey: .isPublic)
        isVisibleOnMap = try? c.decodeIfPresent(Bool.self, forKey: .isVisibleOnMap)
        shareExactLocation = try? c.decodeIfPresent(Bool.self, forKey: .shareExactLocation)
        isOwner = try? c.decodeIfPresent(Bool.self, forKey: .isOwner)
        rsrp = try? c.decodeIfPresent(Double.self, forKey: .rsrp)
        rsrq = try? c.decodeIfPresent(Double.self, forKey: .rsrq)
        snr = try? c.decodeIfPresent(Double.self, forKey: .snr)
        timingAdvance = try? c.decodeIfPresent(Double.self, forKey: .timingAdvance)
    }
}

enum SpeedtestPhase: Equatable {
    case idle
    case ping
    case download
    case upload
    case saving
    case finished
    case failed(String)
}

struct SpeedMetricCalculator {
    static func mbps(bytes: Int, seconds: TimeInterval) -> Double {
        guard seconds > 0 else { return 0 }
        return (Double(bytes) * 8.0 / 1_000_000.0) / seconds
    }

    static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    static func jitter(_ pings: [Double]) -> Double? {
        guard pings.count > 1 else { return nil }
        let deltas = zip(pings.dropFirst(), pings).map { abs($0 - $1) }
        return average(deltas)
    }

    static func percentile(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }
}
