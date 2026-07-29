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

    // Identité radio
    let technology: String
    let operatorName: String?
    let mccMnc: String?
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
        case rsrp, rsrq, sinr, rssi, timingAdvance, latitude, longitude
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
        technology = c.decodeFlexibleString(forKey: .technology) ?? "unknown"
        operatorName = c.decodeFlexibleString(forKey: .operator)
        mccMnc = c.decodeFlexibleString(forKey: .mccMnc)
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
        try c.encode(technology, forKey: .technology)
        try c.encodeIfPresent(operatorName, forKey: .operator)
        try c.encodeIfPresent(mccMnc, forKey: .mccMnc)
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
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encodeIfPresent(firstSeenAt, forKey: .firstSeenAt)
        try c.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }

    var isDeleted: Bool { deletedAt != nil }

    /// Vrai pour une cellule 5G. `technology` porte « NR », « 5G » ou « 5G NSA »
    /// selon la source ; la présence d'un gNB tranche quand le libellé est muet.
    var isNr: Bool {
        let tech = technology.uppercased()
        if tech.contains("NR") || tech.contains("5G") { return true }
        return gnb != nil
    }

    /// MCC extrait de `mccMnc` (« 208-10 », « 20810 »… selon l'émetteur).
    var mcc: String? { RadioLogPlmn.split(mccMnc)?.mcc }
    /// MNC extrait de `mccMnc`.
    var mnc: String? { RadioLogPlmn.split(mccMnc)?.mnc }

    var hasCoordinate: Bool {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite else { return false }
        return !(latitude == 0 && longitude == 0)
    }
}

/// Découpe d'un `mccMnc` en ses deux composantes.
///
/// Le champ arrive sous plusieurs formes selon l'émetteur (« 208-10 », « 208/10 »,
/// « 20810 »). Le MCC fait TOUJOURS 3 chiffres, le MNC 2 ou 3 : la forme collée est
/// donc décidable sans ambiguïté.
enum RadioLogPlmn {
    static func split(_ raw: String?) -> (mcc: String, mnc: String)? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let separators = CharacterSet(charactersIn: "-/_ :")
        let parts = raw.components(separatedBy: separators).filter { !$0.isEmpty }
        if parts.count >= 2, parts[0].count == 3 {
            return (parts[0], parts[1])
        }
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 4, digits.count <= 6 else { return nil }
        let mcc = String(digits.prefix(3))
        let mnc = String(digits.dropFirst(3))
        return (mcc, mnc)
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
