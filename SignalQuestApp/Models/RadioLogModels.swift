import Foundation

// MARK: - Journal radio synchronisé (GET /api/android/radio-logs/pull)

/// Une ligne du journal radio PRIVÉ du compte, telle que la renvoie le serveur.
/// Miroir Swift du modèle Prisma `RadioLogEntry`, poussé depuis Android puis relu
/// ici : iOS est en LECTURE SEULE sur ce journal (aucun `push` n'est émis).
///
/// ⚠️ `ci` arrive en **chaîne** et non en nombre : c'est un `BigInt` côté serveur,
/// que `JSON.stringify` refuse de sérialiser. Le décoder en `Int64` depuis un
/// nombre ferait échouer la ligne entière.
struct RadioLogEntry: Codable, Identifiable, Sendable, Equatable {
    /// Identifiant serveur (cuid). Sert aussi de second critère au curseur keyset.
    let id: String
    /// Clé portable de déduplication calculée par l'appareil émetteur.
    let dedupeKey: String
    /// `cap` (capture terrain) ou `imp` (import de fichier) — les deux cohabitent.
    let scope: String
    let logSource: String?
    let sourceApp: String?
    let sourceFileName: String?

    // Identité radio
    let technology: String
    let operatorName: String?
    private let mccMncValue: JSONValue?
    var mccMnc: String? { RadioLogPlmn.rawText(mccMncValue) }
    /// Identité réseau v2. Le PLMN servant observé prime toujours sur la SIM.
    let rawOperatorName: String?
    let canonicalOperatorKey: String?
    let canonicalOperatorName: String?
    private let observedPlmnValue: JSONValue?
    private let observedMccValue: JSONValue?
    private let observedMncValue: JSONValue?
    /// Le serveur neutralise les projections ambiguës et expose leurs jetons
    /// historiques séparément. Ils doivent survivre au cache sans redevenir PLMN.
    private let legacyMccMncValue: JSONValue?
    private let legacyMccValue: JSONValue?
    private let legacyMncValue: JSONValue?
    var observedPlmn: String? { RadioLogPlmn.rawText(observedPlmnValue) }
    var observedMcc: String? { RadioLogPlmn.rawText(observedMccValue) }
    var observedMnc: String? { RadioLogPlmn.rawText(observedMncValue) }
    var legacyMccMnc: String? { RadioLogPlmn.rawText(legacyMccMncValue) }
    var legacyMcc: String? { RadioLogPlmn.rawText(legacyMccValue) }
    var legacyMnc: String? { RadioLogPlmn.rawText(legacyMncValue) }
    /// Cache historique : un ancien tuple numérique a pu être réécrit en chaînes.
    /// Le relevé brut reste lisible, mais seule une nouvelle lecture serveur lève ce doute.
    var plmnEvidenceRequiresRefresh: Bool
    var cellIdentityEvidenceRequiresRefresh: Bool
    let simPlmn: String?
    let simOperatorName: String?
    let mvnoKey: String?
    let mvnoName: String?
    let marketCode: String?
    let countryCode: String?
    let isRoaming: Bool?
    let networkIdentitySource: String?
    let networkIdentityConfidence: String?
    let networkIdentityObservedAt: Date?
    let nodeIdentityKind: String?
    let nodeIdentityRaw: String?
    let enb: String?
    let gnb: String?
    let eciCellId: String?
    /// Identité cellule complète : ECI en LTE, NCI en NR. Reçue en CHAÎNE.
    let ci: Int64?
    let pci: Int?
    let tac: Int?
    let earfcn: Int?
    let band: Int?

    // Mesure
    let rsrp: Int?
    let rsrq: Int?
    let sinr: Int?
    let rssi: Int?
    let timingAdvance: Int?
    let timingAdvanceSourceTechnology: String?
    let timingAdvanceSourceCellId: String?

    // Position du relevé
    let latitude: Double?
    let longitude: Double?

    // Temps
    let observedAt: Date
    let firstSeenAt: Date?
    let lastSeenAt: Date?
    let updatedAt: Date
    /// Pierre tombale : non nul = la ligne a été supprimée sur un autre appareil.
    /// Elle est PRÉSENTE dans la réponse, pas absente — c'est ce qui permet de
    /// propager la suppression au lieu de la deviner.
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, dedupeKey, scope, technology, mccMnc, enb, gnb, eciCellId, ci, pci, tac, earfcn, band
        case logSource, sourceApp, sourceFileName
        case rawOperatorName, canonicalOperatorKey, canonicalOperatorName, observedPlmn
        case legacyMccMnc, legacyMcc, legacyMnc
        case observedMcc = "mcc"
        case observedMnc = "mnc"
        case simPlmn, simOperatorName, mvnoKey, mvnoName, marketCode, countryCode, isRoaming
        case networkIdentitySource, networkIdentityConfidence, networkIdentityObservedAt
        case nodeIdentityKind, nodeIdentityRaw, plmnEvidenceRequiresRefresh, cellIdentityEvidenceRequiresRefresh
        case rsrp, rsrq, sinr, rssi, timingAdvance, timingAdvanceSourceTechnology, timingAdvanceSourceCellId
        case latitude, longitude
        case observedAt, firstSeenAt, lastSeenAt, updatedAt, deletedAt
        case `operator`
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `dedupeKey` est EXIGÉ, seul champ à l'être.
        //
        // C'est la clé d'unicité côté serveur (`@@unique([userId, dedupeKey])`),
        // donc toute ligne réelle la porte. Le reste du décodage est tolérant :
        // sans cette exigence, un objet parasite — un `{"id":42}` d'une réponse
        // dégradée — franchissait tous les replis et entrait dans le journal
        // comme un relevé de plus. Invisible dans la liste (aucun nœud), mais
        // compté dans « N relevés ». Ici, il est simplement ignoré par le
        // décodage tolérant du tableau.
        guard let dedupeKey = c.decodeFlexibleString(forKey: .dedupeKey) else {
            throw DecodingError.keyNotFound(
                CodingKeys.dedupeKey,
                DecodingError.Context(codingPath: c.codingPath, debugDescription: "dedupeKey manquant")
            )
        }
        self.dedupeKey = dedupeKey
        id = c.decodeFlexibleString(forKey: .id) ?? dedupeKey
        scope = c.decodeFlexibleString(forKey: .scope) ?? "cap"
        logSource = c.decodeFlexibleString(forKey: .logSource)
        sourceApp = c.decodeFlexibleString(forKey: .sourceApp)
        sourceFileName = c.decodeFlexibleString(forKey: .sourceFileName)
        technology = c.decodeFlexibleString(forKey: .technology) ?? "unknown"
        operatorName = c.decodeFlexibleString(forKey: .operator)
        mccMncValue = try? c.decodeIfPresent(JSONValue.self, forKey: .mccMnc)
        rawOperatorName = c.decodeFlexibleString(forKey: .rawOperatorName) ?? operatorName
        canonicalOperatorKey = c.decodeFlexibleString(forKey: .canonicalOperatorKey)
        canonicalOperatorName = c.decodeFlexibleString(forKey: .canonicalOperatorName)
        observedPlmnValue = try? c.decodeIfPresent(JSONValue.self, forKey: .observedPlmn)
        observedMccValue = try? c.decodeIfPresent(JSONValue.self, forKey: .observedMcc)
        observedMncValue = try? c.decodeIfPresent(JSONValue.self, forKey: .observedMnc)
        legacyMccMncValue = try? c.decodeIfPresent(JSONValue.self, forKey: .legacyMccMnc)
        legacyMccValue = try? c.decodeIfPresent(JSONValue.self, forKey: .legacyMcc)
        legacyMncValue = try? c.decodeIfPresent(JSONValue.self, forKey: .legacyMnc)
        plmnEvidenceRequiresRefresh = (try? c.decodeIfPresent(Bool.self, forKey: .plmnEvidenceRequiresRefresh)) ?? false
        cellIdentityEvidenceRequiresRefresh = (try? c.decodeIfPresent(Bool.self, forKey: .cellIdentityEvidenceRequiresRefresh)) ?? false
        simPlmn = c.decodeFlexibleString(forKey: .simPlmn)
        simOperatorName = c.decodeFlexibleString(forKey: .simOperatorName)
        mvnoKey = c.decodeFlexibleString(forKey: .mvnoKey)
        mvnoName = c.decodeFlexibleString(forKey: .mvnoName)
        marketCode = c.decodeFlexibleString(forKey: .marketCode)
        countryCode = c.decodeFlexibleString(forKey: .countryCode)
        isRoaming = try? c.decodeIfPresent(Bool.self, forKey: .isRoaming)
        networkIdentitySource = c.decodeFlexibleString(forKey: .networkIdentitySource)
        networkIdentityConfidence = c.decodeFlexibleString(forKey: .networkIdentityConfidence)
        networkIdentityObservedAt = (try? c.decodeIfPresent(Date.self, forKey: .networkIdentityObservedAt)) ?? nil
        nodeIdentityKind = c.decodeFlexibleString(forKey: .nodeIdentityKind)
        nodeIdentityRaw = c.decodeFlexibleString(forKey: .nodeIdentityRaw)
        enb = c.decodeFlexibleString(forKey: .enb)?.nilIfBlank
        gnb = c.decodeFlexibleString(forKey: .gnb)?.nilIfBlank
        eciCellId = c.decodeFlexibleString(forKey: .eciCellId)?.nilIfBlank
        // Chaîne d'abord (contrat serveur), nombre en repli défensif.
        ci = c.decodeFlexibleString(forKey: .ci).flatMap(Int64.init)
            ?? (try? c.decodeIfPresent(Int64.self, forKey: .ci)) ?? nil
        pci = try? c.decodeIfPresent(Int.self, forKey: .pci)
        tac = try? c.decodeIfPresent(Int.self, forKey: .tac)
        earfcn = try? c.decodeIfPresent(Int.self, forKey: .earfcn)
        band = try? c.decodeIfPresent(Int.self, forKey: .band)
        rsrp = try? c.decodeIfPresent(Int.self, forKey: .rsrp)
        rsrq = try? c.decodeIfPresent(Int.self, forKey: .rsrq)
        sinr = try? c.decodeIfPresent(Int.self, forKey: .sinr)
        rssi = try? c.decodeIfPresent(Int.self, forKey: .rssi)
        timingAdvance = try? c.decodeIfPresent(Int.self, forKey: .timingAdvance)
        timingAdvanceSourceTechnology = c.decodeFlexibleString(forKey: .timingAdvanceSourceTechnology)
        timingAdvanceSourceCellId = c.decodeFlexibleString(forKey: .timingAdvanceSourceCellId)
        latitude = try? c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .longitude)
        observedAt = (try? c.decodeIfPresent(Date.self, forKey: .observedAt)) ?? Date(timeIntervalSince1970: 0)
        firstSeenAt = (try? c.decodeIfPresent(Date.self, forKey: .firstSeenAt)) ?? nil
        lastSeenAt = (try? c.decodeIfPresent(Date.self, forKey: .lastSeenAt)) ?? nil
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? observedAt
        deletedAt = (try? c.decodeIfPresent(Date.self, forKey: .deletedAt)) ?? nil
    }

    /// Encodage pour le cache disque uniquement — jamais renvoyé au serveur.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(dedupeKey, forKey: .dedupeKey)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(logSource, forKey: .logSource)
        try c.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try c.encodeIfPresent(sourceFileName, forKey: .sourceFileName)
        try c.encode(technology, forKey: .technology)
        try c.encodeIfPresent(operatorName, forKey: .operator)
        try c.encodeIfPresent(mccMncValue, forKey: .mccMnc)
        try c.encodeIfPresent(rawOperatorName, forKey: .rawOperatorName)
        try c.encodeIfPresent(canonicalOperatorKey, forKey: .canonicalOperatorKey)
        try c.encodeIfPresent(canonicalOperatorName, forKey: .canonicalOperatorName)
        try c.encodeIfPresent(observedPlmnValue, forKey: .observedPlmn)
        try c.encodeIfPresent(observedMccValue, forKey: .observedMcc)
        try c.encodeIfPresent(observedMncValue, forKey: .observedMnc)
        try c.encodeIfPresent(legacyMccMncValue, forKey: .legacyMccMnc)
        try c.encodeIfPresent(legacyMccValue, forKey: .legacyMcc)
        try c.encodeIfPresent(legacyMncValue, forKey: .legacyMnc)
        if plmnEvidenceRequiresRefresh { try c.encode(true, forKey: .plmnEvidenceRequiresRefresh) }
        if cellIdentityEvidenceRequiresRefresh { try c.encode(true, forKey: .cellIdentityEvidenceRequiresRefresh) }
        try c.encodeIfPresent(simPlmn, forKey: .simPlmn)
        try c.encodeIfPresent(simOperatorName, forKey: .simOperatorName)
        try c.encodeIfPresent(mvnoKey, forKey: .mvnoKey)
        try c.encodeIfPresent(mvnoName, forKey: .mvnoName)
        try c.encodeIfPresent(marketCode, forKey: .marketCode)
        try c.encodeIfPresent(countryCode, forKey: .countryCode)
        try c.encodeIfPresent(isRoaming, forKey: .isRoaming)
        try c.encodeIfPresent(networkIdentitySource, forKey: .networkIdentitySource)
        try c.encodeIfPresent(networkIdentityConfidence, forKey: .networkIdentityConfidence)
        try c.encodeIfPresent(networkIdentityObservedAt, forKey: .networkIdentityObservedAt)
        try c.encodeIfPresent(nodeIdentityKind, forKey: .nodeIdentityKind)
        try c.encodeIfPresent(nodeIdentityRaw, forKey: .nodeIdentityRaw)
        try c.encodeIfPresent(enb, forKey: .enb)
        try c.encodeIfPresent(gnb, forKey: .gnb)
        try c.encodeIfPresent(eciCellId, forKey: .eciCellId)
        // Symétrique du décodage : on réécrit une CHAÎNE, pas un nombre.
        try c.encodeIfPresent(ci.map(String.init), forKey: .ci)
        try c.encodeIfPresent(pci, forKey: .pci)
        try c.encodeIfPresent(tac, forKey: .tac)
        try c.encodeIfPresent(earfcn, forKey: .earfcn)
        try c.encodeIfPresent(band, forKey: .band)
        try c.encodeIfPresent(rsrp, forKey: .rsrp)
        try c.encodeIfPresent(rsrq, forKey: .rsrq)
        try c.encodeIfPresent(sinr, forKey: .sinr)
        try c.encodeIfPresent(rssi, forKey: .rssi)
        try c.encodeIfPresent(timingAdvance, forKey: .timingAdvance)
        try c.encodeIfPresent(timingAdvanceSourceTechnology, forKey: .timingAdvanceSourceTechnology)
        try c.encodeIfPresent(timingAdvanceSourceCellId, forKey: .timingAdvanceSourceCellId)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encodeIfPresent(firstSeenAt, forKey: .firstSeenAt)
        try c.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }

    var isDeleted: Bool { deletedAt != nil }

    /// Sentinelle propre au format NTM, pas au logiciel ni à la technologie.
    /// Hors fichier .ntm, ce même nombre peut être une NCI NR valide.
    var isNtmUnknownCellIdentity: Bool {
        ci == 2_147_483_647 && sourceFileName?.lowercased().hasSuffix(".ntm") == true
    }

    /// La génération d'affichage n'est pas une preuve du type de CI. Une ancre
    /// LTE en NSA ne devient jamais NR par la seule présence d'un ancien gNB.
    var isNr: Bool {
        hasExplicitNrSource || (
            !technology.uppercased().contains("NSA") &&
                (technology.uppercased().contains("NR") || technology.uppercased().contains("5G"))
        )
    }

    var hasExplicitNrSource: Bool {
        let tokens = Set(technology.uppercased().split { !$0.isLetter && !$0.isNumber })
        return !tokens.contains("NSA") && tokens.contains("SA") && (tokens.contains("5G") || tokens.contains("NR"))
    }

    var plmnEvidence: RadioLogPlmnEvidence {
        if plmnEvidenceRequiresRefresh { return .legacyAmbiguous }
        if [networkIdentitySource, networkIdentityConfidence].contains(where: {
            $0?.uppercased().contains("AMBIGUOUS") == true
        }) { return .legacyAmbiguous }
        if networkIdentitySource?.uppercased() == "SIM_ONLY" { return .missing }
        return RadioLogPlmn.resolve(
            observedPlmn: observedPlmnValue, mcc: observedMccValue,
            mnc: observedMncValue, legacyPlmn: mccMncValue
        )
    }

    /// Les composantes proviennent du même PLMN validé : des champs historiques
    /// contradictoires ne remplacent jamais une partie du PLMN observé.
    var servingPlmn: String? { plmnEvidence.components?.plmn }
    var mcc: String? { plmnEvidence.components?.mcc }
    var mnc: String? { plmnEvidence.components?.mnc }

    /// Clé de regroupement seulement, jamais une identité de réseau servant.
    /// Garder le type JSON évite de fusionner 208/1 numérique et 208/01 textuel.
    var unresolvedNetworkKey: String {
        let values = [observedPlmnValue, observedMccValue, observedMncValue, mccMncValue,
                      legacyMccMncValue, legacyMccValue, legacyMncValue,
                      rawOperatorName.map(JSONValue.string)].map { $0 ?? .null }
        let encoded = try? JSONEncoder().encode(values)
        return "UNRESOLVED:" + (encoded.flatMap { String(data: $0, encoding: .utf8) } ?? dedupeKey)
    }

    var cellIdentityKind: String {
        if hasExplicitNrSource || (isNr && (canonicalCellIdentity ?? 0) > 268_435_455) { return "NCI" }
        let tech = technology.uppercased()
        return tech.contains("LTE") || tech.contains("4G") || tech.contains("NSA") ? "ECI" : "CI"
    }

    /// Identité complète utilisable par l'agrégateur. Les champs bruts restent
    /// inchangés dans le cache ; seule cette projection applique le contrat v2.
    var canonicalCellIdentity: Int64? {
        guard !isNtmUnknownCellIdentity, !cellIdentityEvidenceRequiresRefresh else { return nil }
        return RadioCellIdentityNormalizer.canonicalFullCellIdentity(
            cellId: eciCellId,
            ci: ci,
            enb: enb,
            gnb: gnb,
            technology: technology,
            observedPlmn: servingPlmn,
            nodeIdentityKind: nodeIdentityKind
        )
    }

    /// Seuls les anciens tuples sans PLMN complet ont perdu une information
    /// irréversible dans le cache v0. Les preuves explicites restent exploitables.
    var legacyCacheNeedsPlmnRefresh: Bool {
        RadioLogPlmn.split(observedPlmn) == nil && RadioLogPlmn.split(mccMnc) == nil &&
            (observedMcc != nil || observedMnc != nil)
    }

    var legacyCacheNeedsCellIdentityRefresh: Bool {
        scope == "imp" && ci == 2_147_483_647 && sourceFileName == nil
    }
    var displayOperatorName: String? {
        canonicalOperatorName?.nilIfBlank ?? operatorName?.nilIfBlank ?? rawOperatorName?.nilIfBlank
    }

    var hasCoordinate: Bool {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite else { return false }
        return !(latitude == 0 && longitude == 0)
    }
}

/// Normalisation pure et commune aux fixtures, au cache et à l'agrégateur radio.
/// Une NCI déjà observée est conservée ; une reconstruction gNB + cellule locale
/// exige simultanément un PLMN exact documenté et `GNB_REPORTED`.
enum RadioCellIdentityNormalizer {
    private static let lteLocalCellMax: Int64 = 255
    private static let nrLocalCellMax: Int64 = 16_383
    private static let lteFullCellMax: Int64 = 268_435_455
    private static let nrFullCellMax: Int64 = 68_719_476_735
    private static let nrLocalBits: Int64 = 14

    static func canonicalFullCellIdentity(
        cellId: String?,
        ci: Int64?,
        enb: String?,
        gnb: String?,
        technology: String?,
        observedPlmn: String?,
        nodeIdentityKind: String?
    ) -> Int64? {
        let normalizedTechnology = normalize(technology)
        if let ci {
            let maximum = isLteOnly(normalizedTechnology) ? lteFullCellMax : nrFullCellMax
            return (0...maximum).contains(ci) ? ci : nil
        }

        guard let local = nonNegative(cellId) else { return nil }
        let nrIdentity = isNrIdentity(gnb: gnb, enb: enb, technology: normalizedTechnology)
        let lteIdentity = isLteIdentity(enb: enb, technology: normalizedTechnology)

        if nrIdentity, local <= nrLocalCellMax {
            guard normalize(nodeIdentityKind) == "GNB_REPORTED",
                  hasConfirmedNrStrategy(observedPlmn),
                  let node = positive(gnb),
                  node <= (nrFullCellMax >> nrLocalBits) else { return nil }
            return (node << nrLocalBits) + local
        }
        if lteIdentity, local <= lteLocalCellMax {
            guard let node = positive(enb), node <= (lteFullCellMax >> 8) else { return nil }
            return (node << 8) + local
        }
        if nrIdentity { return local <= nrFullCellMax ? local : nil }
        if lteIdentity { return local <= lteFullCellMax ? local : nil }
        if normalizedTechnology.contains("NSA") {
            return local > nrLocalCellMax && local <= nrFullCellMax ? local : nil
        }
        return local <= nrFullCellMax ? local : nil
    }

    static func localCellIdentity(
        cellId: String?,
        ci: Int64?,
        enb: String?,
        gnb: String?,
        technology: String?,
        observedPlmn: String?
    ) -> String? {
        let normalizedTechnology = normalize(technology)
        let explicit = nonNegative(cellId)
        let rawCi = ci.flatMap { (0...nrFullCellMax).contains($0) ? $0 : nil }
        let full = rawCi ?? explicit
        let nrIdentity = isNrIdentity(
            gnb: gnb, enb: enb, technology: normalizedTechnology, fullIdentity: full
        )
        let lteIdentity = isLteIdentity(enb: enb, technology: normalizedTechnology)
        let localMaximum = lteIdentity && !nrIdentity ? lteLocalCellMax : nrLocalCellMax

        if let explicit, explicit <= localMaximum { return String(explicit) }
        if ci != nil, rawCi == nil { return nil }
        if nrIdentity {
            guard hasConfirmedNrStrategy(observedPlmn), let full else { return nil }
            let nodeMatches = rawCi != nil || positive(gnb).map { (full >> nrLocalBits) == $0 } == true
            return nodeMatches ? String(full & nrLocalCellMax) : nil
        }
        if lteIdentity {
            guard let full, full <= lteFullCellMax else { return nil }
            let nodeMatches = rawCi != nil || positive(enb).map { (full >> 8) == $0 } == true
            return nodeMatches ? String(full & lteLocalCellMax) : nil
        }
        if normalizedTechnology.contains("NSA") { return nil }
        return full.map(String.init)
    }

    static func derivedNrNodeIdentity(
        ci: Int64?, technology: String?, observedPlmn: String?
    ) -> String? {
        guard let ci, ci > nrLocalCellMax, ci <= nrFullCellMax,
              hasConfirmedNrStrategy(observedPlmn) else { return nil }
        let normalizedTechnology = normalize(technology)
        guard !isLteOnly(normalizedTechnology),
              ci > lteFullCellMax || isExplicitNrTechnology(normalizedTechnology) else { return nil }
        let node = ci >> nrLocalBits
        return node > 0 ? String(node) : nil
    }

    private static func hasConfirmedNrStrategy(_ observedPlmn: String?) -> Bool {
        guard let observedPlmn,
              RadioLogPlmn.split(observedPlmn) != nil else { return false }
        return RadioLogOperatorResolver.servingNetwork(observedPlmn: observedPlmn).hasConfirmedNrLocalWidth
    }

    private static func isNrIdentity(
        gnb: String?, enb: String?, technology: String, fullIdentity: Int64? = nil
    ) -> Bool {
        if isLteOnly(technology) { return false }
        if let fullIdentity, fullIdentity > lteFullCellMax, fullIdentity <= nrFullCellMax { return true }
        if technology.contains("NSA") { return false }
        if technology.contains("NR") { return true }
        if technology.contains("LTE") || technology.contains("4G") { return false }
        return positive(enb) == nil && (technology.contains("5G") || positive(gnb) != nil)
    }

    private static func isLteIdentity(enb: String?, technology: String) -> Bool {
        positive(enb) != nil || technology.contains("LTE") || technology.contains("4G")
    }

    private static func isLteOnly(_ technology: String) -> Bool {
        (technology.contains("LTE") || technology.contains("4G")) && !technology.contains("NR")
    }

    private static func isExplicitNrTechnology(_ technology: String) -> Bool {
        technology == "NR" || ((technology.contains("NR") || technology.contains("5G")) &&
            technology.contains("SA") && !technology.contains("NSA"))
    }

    private static func positive(_ value: String?) -> Int64? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = Int64(normalized), parsed > 0 else { return nil }
        return parsed
    }

    private static func nonNegative(_ value: String?) -> Int64? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = Int64(normalized), parsed >= 0 else { return nil }
        return parsed
    }

    private static func normalize(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    }
}

/// Découpe d'un `mccMnc` en ses deux composantes.
///
/// Le champ arrive sous plusieurs formes selon l'émetteur (« 208-10 », « 208/10 »,
/// « 20810 »). Le MCC fait TOUJOURS 3 chiffres, le MNC 2 ou 3 : la forme collée est
/// donc décidable sans ambiguïté.
enum RadioLogPlmnEvidence: Equatable, Sendable {
    case exact(mcc: String, mnc: String)
    case legacyAmbiguous
    case invalid
    case missing

    var components: (mcc: String, mnc: String, plmn: String)? {
        guard case let .exact(mcc, mnc) = self else { return nil }
        return (mcc, mnc, mcc + mnc)
    }
}

enum RadioLogPlmn {
    static func split(_ raw: String?) -> (mcc: String, mnc: String)? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let separators = CharacterSet(charactersIn: "-/_ :")
        let parts = raw.components(separatedBy: separators).filter { !$0.isEmpty }
        if parts.count == 2, asciiDigits(parts[0], lengths: [3]), asciiDigits(parts[1], lengths: [2, 3]) {
            return (parts[0], parts[1])
        }
        guard asciiDigits(raw, lengths: [5, 6]) else { return nil }
        let mcc = String(raw.prefix(3))
        let mnc = String(raw.dropFirst(3))
        return (mcc, mnc)
    }

    static func resolve(
        observedPlmn: JSONValue?, mcc: JSONValue?, mnc: JSONValue?, legacyPlmn: JSONValue? = nil
    ) -> RadioLogPlmnEvidence {
        if hasValue(observedPlmn) { return evidence(for: observedPlmn) }
        if hasValue(mcc) || hasValue(mnc) {
            guard case let .string(mccText) = mcc, case let .string(mncText) = mnc else {
                return .legacyAmbiguous
            }
            return evidence(for: .string(mccText.trimmingCharacters(in: .whitespacesAndNewlines) + "-" +
                mncText.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return evidence(for: legacyPlmn)
    }

    static func rawText(_ value: JSONValue?) -> String? {
        switch value {
        case let .string(text): return text.nilIfBlank
        case let .number(number):
            // PLMN/MCC/MNC ne sont jamais des identités 64 bits. Cette conversion
            // ne sert qu'au diagnostic ; un nombre reste ambigu dans resolve().
            return number.isFinite ? String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), number) : nil
        default: return nil
        }
    }

    private static func evidence(for value: JSONValue?) -> RadioLogPlmnEvidence {
        guard hasValue(value) else { return .missing }
        guard case let .string(text) = value else {
            if case .number = value { return .legacyAmbiguous }
            return .invalid
        }
        if let parsed = split(text) { return .exact(mcc: parsed.mcc, mnc: parsed.mnc) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: "-/_ :")).filter { !$0.isEmpty }
        if asciiDigits(trimmed, lengths: [4]) ||
            (parts.count == 2 && asciiDigits(parts[0], lengths: [3]) && asciiDigits(parts[1], lengths: [1])) {
            return .legacyAmbiguous
        }
        return .invalid
    }

    private static func hasValue(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null: return false
        case let .string(text): return text.nilIfBlank != nil
        default: return true
        }
    }

    private static func asciiDigits(_ value: String, lengths: Set<Int>) -> Bool {
        lengths.contains(value.utf8.count) && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

/// Curseur KEYSET de lecture incrémentale. Position de la DERNIÈRE LIGNE
/// réellement renvoyée — jamais une heure serveur : `updatedAt` est posé à
/// l'écriture applicative et non au commit, si bien qu'une transaction lente peut
/// committer après une plus récente. Un curseur sur l'horodatage seul perdrait
/// définitivement la ligne lente.
struct RadioLogCursor: Codable, Sendable, Equatable {
    let sinceAt: Date
    let sinceId: String

    enum CodingKeys: String, CodingKey { case sinceAt, sinceId }

    init(sinceAt: Date, sinceId: String) {
        self.sinceAt = sinceAt
        self.sinceId = sinceId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sinceAt = try c.decode(Date.self, forKey: .sinceAt)
        sinceId = c.decodeFlexibleString(forKey: .sinceId) ?? ""
    }

    /// `sinceAt` au format attendu par la route (ISO 8601 avec fraction, UTC).
    var sinceAtParameter: String { RadioLogCursor.formatter.string(from: sinceAt) }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Une page de `GET /api/android/radio-logs/pull`.
struct RadioLogPullPage: Decodable, Sendable {
    let items: [RadioLogEntry]
    let nextCursor: RadioLogCursor?
    let hasMore: Bool
    /// Vrai quand l'abonnement est en période de grâce : la lecture reste ouverte,
    /// l'écriture non. iOS ne pousse rien, on s'en sert pour l'informer à l'écran.
    let readOnly: Bool

    enum CodingKeys: String, CodingKey { case items, nextCursor, hasMore, readOnly }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.decodeLossyArray([RadioLogEntry].self, forKey: .items)
        nextCursor = try? c.decodeIfPresent(RadioLogCursor.self, forKey: .nextCursor)
        hasMore = (try? c.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
        readOnly = (try? c.decodeIfPresent(Bool.self, forKey: .readOnly)) ?? false
    }
}

/// Échecs propres à la synchronisation du journal.
enum RadioLogSyncError: Error, Equatable {
    /// 403 `PREMIUM_REQUIRED` : la sauvegarde cloud est réservée aux membres
    /// Premium. À distinguer d'un échec réseau — ce n'est pas un incident.
    case premiumRequired(String)
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
