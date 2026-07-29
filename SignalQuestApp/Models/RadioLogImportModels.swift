import Foundation

/// Une ligne de log radio parsée depuis un export « eNB Analytics » (CSV `ExportV5`)
/// ou un fichier `.ntm` (format NetMonster). Miroir Swift du `NormalizedRadioLogSample`
/// Android, avec la MÊME logique d'identité cellule :
///  - LTE : `ci = eNB×256 + CID` (ECI, split 8 bits imposé par la 3GPP).
///  - NR  : `ci = NCI` (36 bits), `gnb = NCI >> 14` (convention identique au serveur).
struct ParsedRadioLogRow: Identifiable, Sendable, Codable {
    var id = UUID()
    let lineNumber: Int
    /// "LTE" ou "NR" (nil si indéterminable).
    let technology: String?
    /// Nom d'opérateur brut ("Orange", "SFR", "ZB"…) quand la source le fournit.
    let operatorName: String?
    let mcc: String?
    let mnc: String?
    let enb: String?
    let gnb: String?
    /// Identité cellule complète (ECI en LTE, NCI en NR).
    let ci: Int64?
    /// Cellule locale (bits bas), telle qu'affichée par la source.
    let cellId: String?
    let pci: Int?
    let tac: Int?
    let earfcn: Int?
    let band: Int?
    let rsrp: Int?
    let latitude: Double?
    let longitude: Double?

    var hasLocation: Bool { latitude != nil && longitude != nil }

    var hasRadioIdentity: Bool {
        !(enb ?? "").isEmpty || !(gnb ?? "").isEmpty || !(cellId ?? "").isEmpty || ci != nil || pci != nil
    }

    /// Est-ce une cellule 5G ? (utilisé pour router techno/nœud.)
    var isNr: Bool {
        (technology ?? "").uppercased().contains("NR") || (technology ?? "").uppercased().contains("5G") || gnb != nil
    }
}

// MARK: - Résolution opérateur → MCC/MNC + marché (miroir de OperatorNetworkFallback.kt)

/// Table minimale opérateur→(MCC, MNC) pour les exports CSV qui ne portent qu'un NOM
/// d'opérateur (pas de MCC/MNC). « ZB » (Zone Blanche) est intrinsèquement FR mais
/// sans opérateur unique → pas de MNC, marché FR. Le backend connaît le code « ZB ».
enum RadioLogOperatorResolver {
    static func mccMnc(forOperator name: String?) -> (mcc: String, mnc: String)? {
        switch normalize(name) {
        case "SFR": return ("208", "10")
        case "BOUYGUES", "BYTEL", "BOUYGUES TELECOM": return ("208", "20")
        case "ORANGE": return ("208", "1")
        case "FREE", "FREE MOBILE": return ("208", "15")
        default: return nil
        }
    }

    /// Clé d'opérateur attendue par l'API (`SFR`, `ORANGE`, `BOUYGUES`, `FREE`,
    /// `ZB`), à partir du nom porté par le log.
    ///
    /// Le journal écrit « Orange » ou « Bouygues Telecom » selon la source, là où
    /// les routes carte attendent la clé canonique. Passer le nom brut en
    /// `?operator=` renvoie une liste vide — et l'écran d'identification n'aurait
    /// alors aucune antenne à proposer, sans dire pourquoi.
    static func operatorKey(forOperator name: String?) -> String? {
        switch normalize(name) {
        case "SFR": return "SFR"
        case "BOUYGUES", "BYTEL", "BOUYGUES TELECOM": return "BOUYGUES"
        case "ORANGE": return "ORANGE"
        case "FREE", "FREE MOBILE": return "FREE"
        case "ZB", "ZONE BLANCHE": return "ZB"
        default: return nil
        }
    }

    /// Marché du log : FR pour les opérateurs FR et pour « ZB » (Zone Blanche).
    static func marketCode(forOperator name: String?, mcc: String?) -> String? {
        if mcc == "208" { return "FR" }
        switch normalize(name) {
        case "SFR", "BOUYGUES", "BYTEL", "BOUYGUES TELECOM",
             "ORANGE", "FREE", "FREE MOBILE", "ZB", "ZONE BLANCHE": return "FR"
        default: return nil
        }
    }

    private static func normalize(_ value: String?) -> String {
        (value ?? "")
            .folding(options: .diacriticInsensitive, locale: .init(identifier: "fr_FR"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }
}

// MARK: - /api/android/map/identify/quick/batch (résolution en lot, lecture seule)

struct QuickIdentifyBatchItem: Encodable, Sendable {
    let id: String
    let `operator`: String?
    let market: String?
    let mcc: String?
    let mnc: String?
    let enb: String?
    let gnb: String?
    let pci: String?
    let cellId: String?
    let ci: String?
    let lat: Double?
    let lng: Double?
    let band: Int?
    let earfcn: Int?
    let tech: String?
}

struct QuickIdentifyBatchRequest: Encodable, Sendable {
    let items: [QuickIdentifyBatchItem]
}

struct QuickIdentifyBatchResponse: Decodable, Sendable {
    let ok: Bool
    let count: Int
    let results: [QuickIdentifyBatchResult]
}

struct QuickIdentifyBatchResult: Decodable, Sendable {
    let id: String?
    let ok: Bool
    /// Payload identique au GET `identify/quick` en cas de succès, `{error, code}` sinon.
    /// Tous les champs sont optionnels : un résultat d'erreur laisse `found`/`siteId` à nil.
    let result: QuickIdentifyResolution?
}

struct QuickIdentifyResolution: Decodable, Sendable {
    let found: Bool?
    let siteId: String?
    let canonicalSiteId: String?
    let market: String?
    let operatorMatched: Bool?
    let distanceMeters: Double?
    /// Identifiants radio que le serveur a RECONNUS (`[{type,value}]`, types `enb`,
    /// `gnb`, `pci`, `cellid`). Vide quand la résolution ne vient pas d'une
    /// correspondance radio (repli proximité) — c'est ce qui distingue « ce nœud
    /// est connu » de « il y a une antenne dans le coin ».
    let matchedRadio: [QuickIdentifyMatchedRadio]
    /// `proximity`, `community_user_site`… — d'où vient la résolution.
    let resolutionMode: String?
    let source: String?
    /// Vrai quand le serveur signale lui-même qu'il ne fait que proposer.
    let requiresUserConfirmation: Bool?
    let hypothesis: QuickIdentifyHypothesis?

    enum CodingKeys: String, CodingKey {
        case found, siteId, canonicalSiteId, market, operatorMatched, distanceMeters
        case matchedRadio, matchedRadioTypes, resolutionMode, source, requiresUserConfirmation, hypothesis
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        found = try? c.decodeIfPresent(Bool.self, forKey: .found)
        siteId = c.decodeFlexibleString(forKey: .siteId)
        canonicalSiteId = c.decodeFlexibleString(forKey: .canonicalSiteId)
        market = c.decodeFlexibleString(forKey: .market)
        operatorMatched = try? c.decodeIfPresent(Bool.self, forKey: .operatorMatched)
        distanceMeters = try? c.decodeIfPresent(Double.self, forKey: .distanceMeters)
        let primary = c.decodeLossyArray([QuickIdentifyMatchedRadio].self, forKey: .matchedRadio)
        matchedRadio = primary.isEmpty
            ? c.decodeLossyArray([QuickIdentifyMatchedRadio].self, forKey: .matchedRadioTypes)
            : primary
        resolutionMode = c.decodeFlexibleString(forKey: .resolutionMode)
        source = c.decodeFlexibleString(forKey: .source)
        requiresUserConfirmation = try? c.decodeIfPresent(Bool.self, forKey: .requiresUserConfirmation)
        hypothesis = try? c.decodeIfPresent(QuickIdentifyHypothesis.self, forKey: .hypothesis)
    }

    /// Types d'identifiants reconnus, normalisés en minuscules.
    var matchedTypes: Set<String> { Set(matchedRadio.map { $0.type.lowercased() }) }
}

struct QuickIdentifyMatchedRadio: Decodable, Sendable {
    let type: String
    let value: String?

    enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        // Le serveur envoie `{type, value}` ; certaines réponses historiques
        // n'envoient que la chaîne du type. On accepte les deux.
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            type = raw
            value = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.decodeFlexibleString(forKey: .type) ?? ""
        value = c.decodeFlexibleString(forKey: .value)
    }
}

/// Hypothèse de site, telle que `serializeRankedHypothesis` la rend côté serveur.
struct QuickIdentifyHypothesis: Decodable, Sendable {
    let siteId: String?
    let canonicalSiteId: String?
    let operatorName: String?
    let latitude: Double?
    let longitude: Double?
    let commune: String?
    let address: String?
    let distanceMeters: Double?
    let sector: Int?
    let confidenceScore: Int?
    let confidence: String?

    enum CodingKeys: String, CodingKey {
        case siteId, canonicalSiteId, latitude, longitude, commune, address
        case distanceMeters, sector, confidenceScore, confidence
        case `operator`
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        siteId = c.decodeFlexibleString(forKey: .siteId)
        canonicalSiteId = c.decodeFlexibleString(forKey: .canonicalSiteId)
        operatorName = c.decodeFlexibleString(forKey: .operator)
        latitude = try? c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .longitude)
        commune = c.decodeFlexibleString(forKey: .commune)
        address = c.decodeFlexibleString(forKey: .address)
        distanceMeters = try? c.decodeIfPresent(Double.self, forKey: .distanceMeters)
        sector = try? c.decodeIfPresent(Int.self, forKey: .sector)
        confidenceScore = try? c.decodeIfPresent(Int.self, forKey: .confidenceScore)
        confidence = c.decodeFlexibleString(forKey: .confidence)
    }
}

// MARK: - État d'import (aperçu + résultat d'écriture)

/// Une ligne parsée + son verdict de résolution serveur (site rattachable ou non).
struct ResolvedRadioLogRow: Identifiable, Sendable {
    let id: UUID
    let row: ParsedRadioLogRow
    let siteId: String?
    let matched: Bool
    let distanceMeters: Double?
}

/// Statut d'identification d'une cellule pour l'affichage (miroir simplifié des badges
/// Android : Vérif. / Rattachable / Non identifié / Identifié). `Codable` pour le cache
/// disque (voir `RadioLogImportStatusStore`) — évite de tout re-résoudre à chaque ouverture.
enum RadioLogImportCellStatus: Sendable, Equatable, Codable {
    case pending
    case identifiable(siteId: String, distanceMeters: Double?)
    case notFound
    case identified

    var label: String {
        switch self {
        case .pending: return String(localized: "Vérif.")
        case .identifiable: return "Rattachable"
        case .notFound: return String(localized: "Non identifié")
        case .identified: return String(localized: "Identifié")
        }
    }

    private enum Kind: String, Codable { case pending, identifiable, notFound, identified }
    private enum CodingKeys: String, CodingKey { case kind, siteId, distanceMeters }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .pending: self = .pending
        case .identifiable:
            self = .identifiable(
                siteId: (try? c.decode(String.self, forKey: .siteId)) ?? "",
                distanceMeters: try? c.decodeIfPresent(Double.self, forKey: .distanceMeters)
            )
        case .notFound: self = .notFound
        case .identified: self = .identified
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending: try c.encode(Kind.pending, forKey: .kind)
        case let .identifiable(siteId, distance):
            try c.encode(Kind.identifiable, forKey: .kind)
            try c.encode(siteId, forKey: .siteId)
            try c.encodeIfPresent(distance, forKey: .distanceMeters)
        case .notFound: try c.encode(Kind.notFound, forKey: .kind)
        case .identified: try c.encode(Kind.identified, forKey: .kind)
        }
    }
}

extension ParsedRadioLogRow {
    /// Clé d'identité cellule STABLE (opérateur + nœud + cellule) — survit au ré-import,
    /// contrairement à `id` (UUID régénéré). Sert de clé au cache de statut d'identification.
    var stableIdentityKey: String {
        [mcc ?? "", mnc ?? "", enb ?? "", gnb ?? "",
         ci.map(String.init) ?? "", pci.map(String.init) ?? ""].joined(separator: "|")
    }
}

/// Statut d'identification caché sur disque (clé = `stableIdentityKey`) + horodatage
/// pour le TTL (revalidation périodique, façon stale-while-revalidate Android).
struct CachedRadioLogStatus: Codable, Sendable {
    let status: RadioLogImportCellStatus
    let updatedAtMs: Int
}

/// Résultat de l'écriture (identify/direct par ligne rattachée).
struct RadioLogImportOutcome: Sendable {
    var submitted: Int = 0
    var failed: Int = 0
}
