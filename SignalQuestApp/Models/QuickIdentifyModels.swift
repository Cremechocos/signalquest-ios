import Foundation

/// Résolution d'opérateur et contrat `identify/quick` — le socle partagé de
/// l'identification.
///
/// Ces types vivaient dans `RadioLogImportModels.swift`, aux côtés de l'import
/// de fichiers de logs. Cet écran a été retiré ; ce qui reste ici n'a jamais
/// été propre à l'import, c'est la page « Logs antennes » qui s'en sert
/// aujourd'hui pour balayer le catalogue et proposer des sites.

// MARK: - Résolution opérateur → MCC/MNC + marché (miroir de OperatorNetworkFallback.kt)

/// Compatibilité des anciens exports, sans jamais fabriquer un PLMN depuis un nom
/// modem seul. « ZB » (Zone Blanche) reste intrinsèquement FR mais sans MNC.
enum RadioLogOperatorResolver {
    struct ServingNetwork {
        let operatorKey: String?
        let operatorName: String?
        let marketCode: String?
        let countryCode: String?
    }

    /// Même référentiel exact que les autres clients. Chargé une seule fois ;
    /// l'agrégateur mémoïse ensuite chaque PLMN distinct du lot.
    private static let radioReference: MarketRegistryPayload = {
        guard let url = Bundle.main.url(forResource: "market_registry_fallback", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder.signalQuest.decode(MarketRegistryPayload.self, from: data) else {
            return .empty
        }
        return registry
    }()

    static func servingNetwork(observedPlmn: String) -> ServingNetwork {
        let market = radioReference.market(forObservedPlmn: observedPlmn)
        let key = market?.radioOperatorKey(observedPlmn: observedPlmn)
        let radioOperator = market?.radioOperators.first { $0.key == key }
        return ServingNetwork(
            operatorKey: key, operatorName: radioOperator?.label,
            marketCode: market?.marketCode, countryCode: market?.countryCode
        )
    }

    static func mccMnc(forOperator name: String?, marketCode: String? = nil) -> (mcc: String, mnc: String)? {
        guard normalizedMarket(marketCode) == "FR" else { return nil }
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
    static func operatorKey(
        forOperator name: String?,
        marketCode: String? = nil,
        mcc: String? = nil
    ) -> String? {
        let normalizedName = normalize(name)
        if normalizedName == "ZB" || normalizedName == "ZONE BLANCHE" { return "ZB" }
        guard normalizedMarket(marketCode) == "FR" || mcc?.trimmingCharacters(in: .whitespacesAndNewlines) == "208" else {
            return nil
        }
        switch normalizedName {
        case "SFR": return "SFR"
        case "BOUYGUES", "BYTEL", "BOUYGUES TELECOM": return "BOUYGUES"
        case "ORANGE": return "ORANGE"
        case "FREE", "FREE MOBILE": return "FREE"
        default: return nil
        }
    }

    /// Marché du log : MCC observé ou marché stocké en premier. Un nom opérateur
    /// n'est jamais une preuve de pays ; ZB reste l'unique exception sémantique.
    static func marketCode(
        forOperator name: String?,
        mcc: String?,
        explicitMarketCode: String? = nil
    ) -> String? {
        if let explicit = normalizedMarket(explicitMarketCode) { return explicit }
        if mcc?.trimmingCharacters(in: .whitespacesAndNewlines) == "208" { return "FR" }
        let normalizedName = normalize(name)
        return normalizedName == "ZB" || normalizedName == "ZONE BLANCHE" ? "FR" : nil
    }

    private static func normalizedMarket(_ value: String?) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(), !normalized.isEmpty else {
            return nil
        }
        return normalized
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
