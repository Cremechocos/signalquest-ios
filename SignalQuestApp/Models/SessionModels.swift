import Foundation
import CoreLocation

// MARK: - Session (liste + détail)

/// Opérateur agrégé d'une session (`operators: [{key,label,color,count}]`) tel que
/// renvoyé par `GET /api/coverage/sessions` (liste). Couleur = teinte de marque
/// fournie par le backend (hex).
struct SessionOperator: Decodable, Equatable, Identifiable {
    let key: String
    let label: String
    let colorHex: String?
    let count: Int?

    var id: String { key }

    enum CodingKeys: String, CodingKey { case key, label, color, count }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let k = c.decodeFlexibleString(forKey: .key)
        let l = c.decodeFlexibleString(forKey: .label)
        key = k ?? l ?? "?"
        label = l ?? k ?? "?"
        colorHex = c.decodeFlexibleString(forKey: .color)
        count = try? c.decodeIfPresent(Int.self, forKey: .count)
    }

    init(key: String, label: String, colorHex: String?, count: Int?) {
        self.key = key
        self.label = label
        self.colorHex = colorHex
        self.count = count
    }
}

/// Session de mesure (drive-test ou couverture) enregistrée par l'utilisateur —
/// potentiellement depuis l'app Android (mêmes données, compte partagé côté
/// serveur). iOS les CONSULTE et permet d'identifier/valider, sans enregistrer
/// la radio fine (limite Apple). Décodage tolérant (tout optionnel).
///
/// Clés réelles du backend (`app/api/coverage/sessions/route.ts`) : type via
/// `source == "drive_test"`, `distance` en **km**, `operators` = tableau d'objets,
/// RSRP moyen sous `avgSignalStrength`, dates `startTime`/`endTime`.
struct CoverageSession: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let sessionDescription: String?
    let source: String?
    let operatorKey: String?
    let startTime: Date?
    let endTime: Date?
    let durationSeconds: Double?
    let totalPoints: Int?
    let distanceKm: Double?
    let avgSignalStrength: Double?
    let minSignalStrength: Double?
    let maxSignalStrength: Double?
    let operators: [SessionOperator]
    let technologies: [String]
    let showOnMap: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, description, source, operatorKey
        case startTime, startedAt, createdAt, endTime, endedAt, duration
        case totalPoints, pointCount, distance
        case avgSignalStrength, minSignalStrength, maxSignalStrength
        case operators, technologies, technologiesDetected, showOnMap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        name = c.decodeFlexibleString(forKey: .name)
        sessionDescription = c.decodeFlexibleString(forKey: .description)
        source = c.decodeFlexibleString(forKey: .source)
        operatorKey = c.decodeFlexibleString(forKey: .operatorKey)
        startTime = (try? c.decodeIfPresent(Date.self, forKey: .startTime))
            ?? (try? c.decodeIfPresent(Date.self, forKey: .startedAt))
            ?? (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
        endTime = (try? c.decodeIfPresent(Date.self, forKey: .endTime))
            ?? (try? c.decodeIfPresent(Date.self, forKey: .endedAt)) ?? nil
        durationSeconds = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? nil
        totalPoints = (try? c.decodeIfPresent(Int.self, forKey: .totalPoints))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .pointCount)) ?? nil
        distanceKm = (try? c.decodeIfPresent(Double.self, forKey: .distance)) ?? nil
        avgSignalStrength = (try? c.decodeIfPresent(Double.self, forKey: .avgSignalStrength)) ?? nil
        minSignalStrength = (try? c.decodeIfPresent(Double.self, forKey: .minSignalStrength)) ?? nil
        maxSignalStrength = (try? c.decodeIfPresent(Double.self, forKey: .maxSignalStrength)) ?? nil
        operators = Self.decodeOperators(c)
        technologies = {
            let t = c.decodeLossyArray([String].self, forKey: .technologies)
            return t.isEmpty ? c.decodeLossyArray([String].self, forKey: .technologiesDetected) : t
        }()
        showOnMap = (try? c.decodeIfPresent(Bool.self, forKey: .showOnMap)) ?? nil
    }

    /// Décode `operators` comme tableau d'objets `{key,label,color,count}` ; repli
    /// sur un tableau de chaînes (forme historique) si nécessaire.
    private static func decodeOperators(_ c: KeyedDecodingContainer<CodingKeys>) -> [SessionOperator] {
        if let objects = try? c.decodeIfPresent([SessionOperator].self, forKey: .operators), !objects.isEmpty {
            return objects
        }
        let strings = c.decodeLossyArray([String].self, forKey: .operators)
        return strings.map { SessionOperator(key: $0, label: $0, colorHex: nil, count: nil) }
    }

    /// Drive-test (mobile) vs couverture (statique) — clé backend `source`.
    var isDriveTest: Bool {
        let s = (source ?? "").lowercased()
        return s == "drive_test" || s.contains("drive")
    }

    /// Couverture contribuée par iOS : GÉNÉRATION seulement, pas de signal radio.
    /// iOS n'expose pas le RSRP → le backend stocke une sentinelle. Ces sessions
    /// doivent être colorées par génération, pas par RSRP (sinon tous les points
    /// tombent dans le gris « aucun signal »).
    var isIosCoverage: Bool {
        (source ?? "").lowercased() == "ios"
    }

    /// Libellé court de durée (« 12 min », « 1 h 04 ») si disponible.
    var durationLabel: String? {
        guard let d = durationSeconds, d > 0 else { return nil }
        let minutes = Int(d / 60)
        if minutes < 60 { return "\(max(1, minutes)) min" }
        return String(format: "%d h %02d", minutes / 60, minutes % 60)
    }
}

/// Point de mesure d'une session (position + radio). Clés réelles : `latitude` /
/// `longitude`, RSRP sous `signalStrength`, techno sous `technology`.
struct CoverageSessionPoint: Decodable, Identifiable, Equatable {
    let id: String
    let lat: Double
    let lng: Double
    let signalStrength: Double?
    let enb: String?
    let gnb: String?
    let pci: String?
    let cellId: String?
    let tech: String?
    let operatorKey: String?
    let timestamp: Date?

    enum CodingKeys: String, CodingKey {
        case id, latitude, lat, longitude, lng
        case signalStrength, rsrp, enb, gnb, pci, cellId
        case technology, networkType, operatorKey, mobileOperator, timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        lat = (try? c.decode(Double.self, forKey: .latitude)) ?? (try? c.decode(Double.self, forKey: .lat)) ?? 0
        lng = (try? c.decode(Double.self, forKey: .longitude)) ?? (try? c.decode(Double.self, forKey: .lng)) ?? 0
        signalStrength = (try? c.decodeIfPresent(Double.self, forKey: .signalStrength))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .rsrp)) ?? nil
        enb = c.decodeFlexibleString(forKey: .enb)
        gnb = c.decodeFlexibleString(forKey: .gnb)
        pci = c.decodeFlexibleString(forKey: .pci)
        cellId = c.decodeFlexibleString(forKey: .cellId)
        tech = c.decodeFlexibleString(forKey: .technology) ?? c.decodeFlexibleString(forKey: .networkType)
        operatorKey = c.decodeFlexibleString(forKey: .operatorKey) ?? c.decodeFlexibleString(forKey: .mobileOperator)
        timestamp = (try? c.decodeIfPresent(Date.self, forKey: .timestamp)) ?? nil
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
    var hasValidCoordinate: Bool { lat != 0 || lng != 0 }
}

/// Speedtest rattaché à une session Drive Test — renvoyé par le backend SOUS
/// `session.speedtests` (même niveau que `session.points`). Décodage tolérant.
struct SessionSpeedtest: Decodable, Identifiable, Equatable {
    let id: String
    let lat: Double?
    let lng: Double?
    let downloadMbps: Double?
    let uploadMbps: Double?
    let pingMs: Double?
    let jitterMs: Double?
    let mobileOperator: String?
    let operatorKey: String?
    /// Génération/type de connexion au moment du test (ex. "5G", "4G", "LTE").
    let networkType: String?
    let timestamp: Date?

    enum CodingKeys: String, CodingKey {
        case id, latitude, longitude, lat, lng
        case downloadSpeed, averageSpeed, uploadAvg, uploadSpeed
        case ping, pingMin, jitter
        case mobileOperator, operatorKey, connectionType, networkType, timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        lat = (try? c.decodeIfPresent(Double.self, forKey: .latitude))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .lat)) ?? nil
        lng = (try? c.decodeIfPresent(Double.self, forKey: .longitude))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .lng)) ?? nil
        // Débit : moyenne si dispo, sinon valeur brute (mêmes replis que le web).
        downloadMbps = (try? c.decodeIfPresent(Double.self, forKey: .averageSpeed))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .downloadSpeed)) ?? nil
        uploadMbps = (try? c.decodeIfPresent(Double.self, forKey: .uploadAvg))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .uploadSpeed)) ?? nil
        pingMs = (try? c.decodeIfPresent(Double.self, forKey: .pingMin))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .ping)) ?? nil
        jitterMs = (try? c.decodeIfPresent(Double.self, forKey: .jitter)) ?? nil
        mobileOperator = c.decodeFlexibleString(forKey: .mobileOperator)
        operatorKey = c.decodeFlexibleString(forKey: .operatorKey)
        networkType = c.decodeFlexibleString(forKey: .connectionType)
            ?? c.decodeFlexibleString(forKey: .networkType)
        timestamp = (try? c.decodeIfPresent(Date.self, forKey: .timestamp)) ?? nil
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng, lat != 0 || lng != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

// MARK: - Antenne desservante

/// État d'identification d'une antenne desservante, dérivé de
/// `identificationStatus` (confirmed/auto/uncertain/insufficient_data) + `source`
/// + présence d'une `hypothesis`.
enum ServingStatus: String, Equatable {
    case identified   // confirmed / auto → site confirmé
    case hypothesis   // uncertain → meilleure hypothèse
    case proximity    // insufficient_data + source proximity → site ANFR le plus proche
    case unknown

    var label: String {
        switch self {
        case .identified: return "Identifiée"
        case .hypothesis: return "Hypothèse"
        case .proximity: return "Proximité ANFR"
        case .unknown: return "Indéterminée"
        }
    }
}

/// Antenne desservante d'une session. Aplatie depuis le wrapper backend
/// `{ id, ok, result }` où l'antenne réelle vit sous `result.antenna`
/// (`EnrichedAntennaResponse`).
struct ServingAntenna: Identifiable, Equatable {
    let id: String
    let lat: Double
    let lng: Double
    let operatorName: String?
    let status: ServingStatus
    /// Niveau de confiance backend : "HIGH" | "MEDIUM" | "LOW".
    let confidenceLabel: String?
    /// Distance à la trace, en kilomètres.
    let distanceKm: Double?
    let siteId: String?
    let displayName: String?
    let commune: String?
    let evidence: [String]
    let enb: String?
    let gnb: String?
    let pci: String?
    let cellId: String?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
    var hasValidCoordinate: Bool { lat != 0 || lng != 0 }

    /// Confiance traduite (HAUTE / MOYENNE / FAIBLE).
    var confidenceFR: String? {
        switch (confidenceLabel ?? "").uppercased() {
        case "HIGH": return "haute"
        case "MEDIUM": return "moyenne"
        case "LOW": return "faible"
        default: return nil
        }
    }

    /// L'antenne n'est pas encore confirmée → on propose de l'identifier.
    var isUnconfirmed: Bool { status != .identified }

    init?(wrapper: ServingAntennaWrapper) {
        guard wrapper.ok != false, let r = wrapper.result else { return nil }
        let a = r.antenna
        let lat = a?.latitude ?? 0
        let lng = a?.longitude ?? 0
        let resolvedSiteId = a?.supId ?? a?.siteKey ?? r.canonicalSiteId ?? r.hypothesis?.siteId
        // Il faut au moins une coordonnée OU un identifiant de site exploitable.
        guard lat != 0 || lng != 0 || resolvedSiteId != nil else { return nil }

        self.lat = lat
        self.lng = lng
        self.siteId = resolvedSiteId
        self.operatorName = a?.operatorName ?? r.hypothesis?.operatorName ?? a?.operators?.first
        self.status = ServingAntenna.resolveStatus(r)
        self.confidenceLabel = r.confidence ?? r.hypothesis?.confidence
        self.distanceKm = r.distance ?? r.hypothesis?.distanceMeters.map { $0 / 1000 }
        self.displayName = a?.displayName
        self.commune = a?.commune
        self.evidence = r.hypothesis?.evidence.isEmpty == false ? r.hypothesis!.evidence : (r.confidenceReason ?? [])
        self.enb = a?.enb ?? r.hypothesis?.enb
        self.gnb = a?.gnb
        self.pci = a?.pci
        self.cellId = a?.cellId
        self.id = wrapper.id ?? resolvedSiteId ?? "\(lat),\(lng)"
    }

    private static func resolveStatus(_ r: ServingAntennaResult) -> ServingStatus {
        switch (r.identificationStatus ?? "").lowercased() {
        case "confirmed", "auto": return .identified
        case "uncertain": return .hypothesis
        case "insufficient_data":
            if r.source?.lowercased() == "proximity" { return .proximity }
            return r.hypothesis != nil ? .hypothesis : .proximity
        default:
            if r.identified == true { return .identified }
            if r.hypothesis != nil { return .hypothesis }
            if r.source?.lowercased() == "proximity" { return .proximity }
            return .unknown
        }
    }
}

// MARK: - Wrappers de décodage (formes backend brutes)

/// Wrapper `{ id, ok, result }` d'un lot `lookup-by-enb`. Décodage non-throwing
/// (un élément malformé devient `ok == nil`/`result == nil` puis est filtré, sans
/// faire échouer toute la liste).
struct ServingAntennaWrapper: Decodable {
    let id: String?
    let ok: Bool?
    let result: ServingAntennaResult?

    enum CodingKeys: String, CodingKey { case id, ok, result }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            id = nil; ok = false; result = nil; return
        }
        id = c.decodeFlexibleString(forKey: .id)
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? nil
        result = try? c.decodeIfPresent(ServingAntennaResult.self, forKey: .result) ?? nil
    }
}

struct ServingAntennaResult: Decodable {
    let found: Bool?
    let identified: Bool?
    let identificationStatus: String?
    let source: String?
    let confidence: String?
    let confidenceReason: [String]?
    let distance: Double?
    let canonicalSiteId: String?
    let antenna: ServingAntennaCore?
    let hypothesis: ServingAntennaHypothesis?

    enum CodingKeys: String, CodingKey {
        case found, identified, identificationStatus, source, confidence, confidenceReason
        case distance, canonicalSiteId, antenna, hypothesis
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            found = nil; identified = nil; identificationStatus = nil; source = nil
            confidence = nil; confidenceReason = nil; distance = nil; canonicalSiteId = nil
            antenna = nil; hypothesis = nil; return
        }
        found = (try? c.decodeIfPresent(Bool.self, forKey: .found)) ?? nil
        identified = (try? c.decodeIfPresent(Bool.self, forKey: .identified)) ?? nil
        identificationStatus = c.decodeFlexibleString(forKey: .identificationStatus)
        source = c.decodeFlexibleString(forKey: .source)
        confidence = c.decodeFlexibleString(forKey: .confidence)
        confidenceReason = try? c.decodeIfPresent([String].self, forKey: .confidenceReason) ?? nil
        distance = (try? c.decodeIfPresent(Double.self, forKey: .distance)) ?? nil
        canonicalSiteId = c.decodeFlexibleString(forKey: .canonicalSiteId)
        antenna = try? c.decodeIfPresent(ServingAntennaCore.self, forKey: .antenna) ?? nil
        hypothesis = try? c.decodeIfPresent(ServingAntennaHypothesis.self, forKey: .hypothesis) ?? nil
    }
}

struct ServingAntennaCore: Decodable {
    let latitude: Double?
    let longitude: Double?
    let operatorName: String?
    let operators: [String]?
    let displayName: String?
    let commune: String?
    let siteKey: String?
    let supId: String?
    let enb: String?
    let gnb: String?
    let cellId: String?
    let pci: String?

    enum CodingKeys: String, CodingKey {
        case latitude, longitude, operators, displayName, commune, siteKey
        case operatorName = "operator"
        case supId = "sup_id"
        case enb, gnb, cellId, pci
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            latitude = nil; longitude = nil; operatorName = nil; operators = nil
            displayName = nil; commune = nil; siteKey = nil; supId = nil
            enb = nil; gnb = nil; cellId = nil; pci = nil; return
        }
        latitude = (try? c.decodeIfPresent(Double.self, forKey: .latitude)) ?? nil
        longitude = (try? c.decodeIfPresent(Double.self, forKey: .longitude)) ?? nil
        operatorName = c.decodeFlexibleString(forKey: .operatorName)
        operators = try? c.decodeIfPresent([String].self, forKey: .operators) ?? nil
        displayName = c.decodeFlexibleString(forKey: .displayName)
        commune = c.decodeFlexibleString(forKey: .commune)
        siteKey = c.decodeFlexibleString(forKey: .siteKey)
        supId = c.decodeFlexibleString(forKey: .supId)
        enb = c.decodeFlexibleString(forKey: .enb)
        gnb = c.decodeFlexibleString(forKey: .gnb)
        cellId = c.decodeFlexibleString(forKey: .cellId)
        pci = c.decodeFlexibleString(forKey: .pci)
    }
}

struct ServingAntennaHypothesis: Decodable {
    let siteId: String?
    let operatorName: String?
    let confidence: String?
    let distanceMeters: Double?
    let evidence: [String]
    let enb: String?

    enum CodingKeys: String, CodingKey {
        case siteId, confidence, distanceMeters, evidence, enb
        case operatorName = "operator"
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            siteId = nil; operatorName = nil; confidence = nil
            distanceMeters = nil; evidence = []; enb = nil; return
        }
        siteId = c.decodeFlexibleString(forKey: .siteId)
        operatorName = c.decodeFlexibleString(forKey: .operatorName)
        confidence = c.decodeFlexibleString(forKey: .confidence)
        distanceMeters = (try? c.decodeIfPresent(Double.self, forKey: .distanceMeters)) ?? nil
        evidence = c.decodeLossyArray([String].self, forKey: .evidence)
        enb = c.decodeFlexibleString(forKey: .enb)
    }
}

// MARK: - Réponses

struct SessionsListResponse: Decodable {
    let sessions: [CoverageSession]
    let pagination: SessionsPagination?

    enum CodingKeys: String, CodingKey { case sessions, pagination }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = c.decodeLossyArray([CoverageSession].self, forKey: .sessions)
        pagination = try? c.decodeIfPresent(SessionsPagination.self, forKey: .pagination) ?? nil
    }
}

struct SessionsPagination: Decodable {
    let total: Int?
    let limit: Int?
    let offset: Int?
    let hasMore: Bool?
}

/// Détail d'une session : enveloppe `{ session, servingAntennas }`. Les points
/// vivent sous `session.points` ; `servingAntennas` est un tableau de wrappers
/// `{id,ok,result}` à plat.
struct CoverageSessionDetail: Decodable {
    let session: CoverageSession
    let points: [CoverageSessionPoint]
    let speedtests: [SessionSpeedtest]
    let servingAntennas: [ServingAntenna]

    enum CodingKeys: String, CodingKey { case session, points, servingAntennas, antennas }
    enum SessionInnerKeys: String, CodingKey { case points, speedtests }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? c.decodeIfPresent(CoverageSession.self, forKey: .session) {
            session = nested
            // Les points ET les speedtests sont imbriqués sous `session`.
            if let inner = try? c.nestedContainer(keyedBy: SessionInnerKeys.self, forKey: .session) {
                points = inner.decodeLossyArray([CoverageSessionPoint].self, forKey: .points)
                speedtests = inner.decodeLossyArray([SessionSpeedtest].self, forKey: .speedtests)
            } else {
                points = []
                speedtests = []
            }
        } else {
            // Repli : session au niveau racine, points au niveau racine.
            session = try CoverageSession(from: decoder)
            points = c.decodeLossyArray([CoverageSessionPoint].self, forKey: .points)
            speedtests = []
        }
        let wrappers = c.decodeLossyArray([ServingAntennaWrapper].self, forKey: .servingAntennas)
        let fallback = wrappers.isEmpty ? c.decodeLossyArray([ServingAntennaWrapper].self, forKey: .antennas) : wrappers
        servingAntennas = fallback.compactMap(ServingAntenna.init(wrapper:))
    }
}
