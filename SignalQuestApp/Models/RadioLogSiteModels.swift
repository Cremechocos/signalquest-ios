import Foundation

/// Nature du nœud radio. L'unité de la page Logs est le SITE (eNB/gNB), jamais la
/// cellule : `identify/quick` rend le même `siteId` avec ou sans PCI, donc
/// l'identification porte sur le nœud. Les PCI/ECI n'en sont que la composition.
enum RadioLogNodeKind: String, Codable, Sendable, Equatable {
    case enb = "eNB"
    case gnb = "gNB"

    /// Génération réseau associée, telle qu'affichée en pastille.
    var techLabel: String { self == .gnb ? "5G" : "4G" }
}

/// Une cellule relevée sous un site. **Descriptive et rien d'autre** : aucun statut
/// d'identification n'est calculé à ce niveau, donc aucune action n'y est possible.
struct RadioLogCell: Identifiable, Sendable, Equatable {
    let id: String
    let pci: Int?
    /// Identité complète (ECI en LTE, NCI en NR).
    let ci: Int64?
    let eciCellId: String?
    let band: Int?
    let earfcn: Int?
    /// Meilleur RSRP observé sur cette cellule (le moins négatif).
    let bestRsrp: Int?
    let logCount: Int

    /// `PCI 35` — l'étiquette de tête de rangée, à largeur fixe dans la maquette.
    var pciLabel: String { pci.map { "PCI \($0)" } ?? "PCI —" }

    /// `ECI 160466202` / `NCI …` — l'identité complète de la cellule.
    var identityLabel: String? {
        if let ci { return "\(ci > 268_435_455 ? "NCI" : "ECI") \(ci)" }
        if let eciCellId { return "Cell \(eciCellId)" }
        return nil
    }

    /// `B3 · 1300` — bande et porteuse, quand elles sont connues.
    var bandLabel: String? {
        let parts = [band.map { "B\($0)" }, earfcn.map(String.init)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Un site du journal : un eNB/gNB, ses cellules, et ce qu'on en a relevé.
struct RadioLogSite: Identifiable, Sendable, Equatable {
    /// Clé STABLE `operateur|mcc|mnc|kind|node` — survit à une resynchronisation,
    /// contrairement aux `id` serveur des lignes. Sert de clé au cache de statut
    /// ET d'identifiant d'item dans le lot `identify/quick/batch`.
    let id: String
    let kind: RadioLogNodeKind
    let node: String
    let operatorName: String?
    let mcc: String?
    let mnc: String?
    let cells: [RadioLogCell]
    /// Nombre de lignes de journal rattachées au site.
    let logCount: Int
    let firstSeenAt: Date
    let lastSeenAt: Date
    /// Position MÉDIANE des relevés positionnés (médiane par axe, pas centroïde :
    /// un fix GPS aberrant ne doit pas déplacer le point de plusieurs kilomètres).
    let latitude: Double?
    let longitude: Double?
    /// Bande et porteuse représentatives (les plus fréquentes) — alimentent le
    /// match fréquence du serveur lors de l'identification.
    let band: Int?
    let earfcn: Int?
    /// Techno normalisée envoyée au serveur (`4G` / `5G`).
    var techLabel: String { kind.techLabel }

    /// `eNB 626821` — le titre de la carte.
    var nodeLabel: String { "\(kind.rawValue) \(node)" }

    /// Nombre de PCI distincts relevés sous ce site.
    var distinctPciCount: Int { Set(cells.compactMap(\.pci)).count }

    /// Étiquettes PCI DISTINCTES, dans l'ordre des cellules.
    ///
    /// Un site porte souvent plusieurs cellules sur le même PCI (bandes ou
    /// secteurs différents) : lister les cellules une à une affichait « PCI 261 »
    /// quatre fois de suite, en contradiction directe avec le « 3 PCI » annoncé
    /// juste au-dessus. Les pastilles décrivent le site, pas ses lignes.
    var distinctPciLabels: [String] {
        var seen = Set<Int>()
        return cells.compactMap { cell in
            guard let pci = cell.pci, seen.insert(pci).inserted else { return nil }
            return "PCI \(pci)"
        }
    }

    var hasCoordinate: Bool { latitude != nil && longitude != nil }

    /// `3 cellules · 2 PCI` — la ligne de méta de la maquette.
    var compositionLabel: String {
        let cellPart = cells.count <= 1 ? "\(cells.count) cellule" : "\(cells.count) cellules"
        let pciCount = distinctPciCount
        guard pciCount > 0 else { return cellPart }
        return "\(cellPart) · \(pciCount) PCI"
    }
}

// MARK: - Agrégation

enum RadioLogSiteBuilder {
    /// Regroupe les lignes du journal en sites.
    ///
    /// La règle de nœud est celle de `IdentifiedNodeGroup.group` : en 5G le gNB
    /// prime, sinon l'eNB. Une ligne sans aucun nœud est ignorée — elle ne peut
    /// ni s'afficher ni s'identifier, et la garder gonflerait les compteurs d'une
    /// matière sur laquelle la page ne sait rien dire.
    static func build(from entries: [RadioLogEntry]) -> [RadioLogSite] {
        struct Accumulator {
            let kind: RadioLogNodeKind
            let node: String
            var operatorName: String?
            var mcc: String?
            var mnc: String?
            var cells: [String: RadioLogCell] = [:]
            var logCount = 0
            var firstSeenAt: Date
            var lastSeenAt: Date
            var latitudes: [Double] = []
            var longitudes: [Double] = []
            var bandCounts: [Int: Int] = [:]
            var earfcnCounts: [Int: Int] = [:]
        }

        var accumulators: [String: Accumulator] = [:]

        for entry in entries where !entry.isDeleted {
            guard let (kind, node) = nodeIdentity(of: entry) else { continue }
            let plmn = RadioLogPlmn.split(entry.mccMnc)
            let key = siteKey(
                operatorName: entry.operatorName,
                mcc: plmn?.mcc,
                mnc: plmn?.mnc,
                kind: kind,
                node: node
            )
            let seenAt = entry.firstSeenAt ?? entry.observedAt
            let lastAt = entry.lastSeenAt ?? entry.observedAt

            var accumulator = accumulators[key] ?? Accumulator(
                kind: kind,
                node: node,
                operatorName: entry.operatorName,
                mcc: plmn?.mcc,
                mnc: plmn?.mnc,
                firstSeenAt: seenAt,
                lastSeenAt: lastAt
            )

            accumulator.logCount += 1
            accumulator.firstSeenAt = min(accumulator.firstSeenAt, seenAt)
            accumulator.lastSeenAt = max(accumulator.lastSeenAt, lastAt)
            if accumulator.operatorName == nil { accumulator.operatorName = entry.operatorName }
            if accumulator.mcc == nil { accumulator.mcc = plmn?.mcc }
            if accumulator.mnc == nil { accumulator.mnc = plmn?.mnc }
            if entry.hasCoordinate, let lat = entry.latitude, let lng = entry.longitude {
                accumulator.latitudes.append(lat)
                accumulator.longitudes.append(lng)
            }
            if let band = entry.band, band > 0 { accumulator.bandCounts[band, default: 0] += 1 }
            if let earfcn = entry.earfcn, earfcn >= 0 { accumulator.earfcnCounts[earfcn, default: 0] += 1 }

            let cellKey = cellIdentity(of: entry)
            if let existing = accumulator.cells[cellKey] {
                accumulator.cells[cellKey] = RadioLogCell(
                    id: existing.id,
                    pci: existing.pci ?? entry.pci,
                    ci: existing.ci ?? entry.ci,
                    eciCellId: existing.eciCellId ?? entry.eciCellId,
                    band: existing.band ?? entry.band,
                    earfcn: existing.earfcn ?? entry.earfcn,
                    bestRsrp: bestRsrp(existing.bestRsrp, entry.rsrp),
                    logCount: existing.logCount + 1
                )
            } else {
                accumulator.cells[cellKey] = RadioLogCell(
                    id: "\(key)#\(cellKey)",
                    pci: entry.pci,
                    ci: entry.ci,
                    eciCellId: entry.eciCellId,
                    band: entry.band,
                    earfcn: entry.earfcn,
                    bestRsrp: entry.rsrp,
                    logCount: 1
                )
            }

            accumulators[key] = accumulator
        }

        return accumulators.map { key, accumulator in
            RadioLogSite(
                id: key,
                kind: accumulator.kind,
                node: accumulator.node,
                operatorName: accumulator.operatorName,
                mcc: accumulator.mcc,
                mnc: accumulator.mnc,
                cells: accumulator.cells.values.sorted(by: cellOrder),
                logCount: accumulator.logCount,
                firstSeenAt: accumulator.firstSeenAt,
                lastSeenAt: accumulator.lastSeenAt,
                latitude: median(accumulator.latitudes),
                longitude: median(accumulator.longitudes),
                band: mostFrequent(accumulator.bandCounts),
                earfcn: mostFrequent(accumulator.earfcnCounts)
            )
        }
    }

    /// Clé de site — recomposable à l'identique depuis un `RadioLogSite`.
    static func siteKey(
        operatorName: String?,
        mcc: String?,
        mnc: String?,
        kind: RadioLogNodeKind,
        node: String
    ) -> String {
        [
            operatorName?.uppercased() ?? "",
            mcc ?? "",
            mnc ?? "",
            kind.rawValue,
            node
        ].joined(separator: "|")
    }

    private static func nodeIdentity(of entry: RadioLogEntry) -> (RadioLogNodeKind, String)? {
        if entry.isNr, let gnb = entry.gnb { return (.gnb, gnb) }
        if let enb = entry.enb { return (.enb, enb) }
        if let gnb = entry.gnb { return (.gnb, gnb) }
        return nil
    }

    /// Identité d'une cellule DANS son site : le couple (PCI, identité complète).
    /// Deux relevés du même PCI sur des ECI différents restent deux rangées —
    /// c'est bien deux cellules physiques.
    private static func cellIdentity(of entry: RadioLogEntry) -> String {
        let identity = entry.ci.map(String.init) ?? entry.eciCellId ?? ""
        return "\(entry.pci.map(String.init) ?? "")/\(identity)"
    }

    /// Le meilleur RSRP est le MOINS négatif (−78 dBm bat −105 dBm).
    private static func bestRsrp(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (value?, nil): return value
        case let (nil, value?): return value
        case let (left?, right?): return max(left, right)
        default: return nil
        }
    }

    /// Rangées triées par PCI puis par identité — un ordre stable, lisible en
    /// diagonale, et qui ne bouge pas d'une synchronisation à l'autre.
    private static func cellOrder(_ lhs: RadioLogCell, _ rhs: RadioLogCell) -> Bool {
        switch (lhs.pci, rhs.pci) {
        case let (left?, right?) where left != right: return left < right
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        return (lhs.ci ?? 0) < (rhs.ci ?? 0)
    }

    /// Médiane par axe. Robuste au fix GPS aberrant, contrairement à la moyenne :
    /// une seule position fausse à 40 km déplace un centroïde de 400 m sur cent
    /// relevés, la médiane ne bouge pas.
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func mostFrequent(_ counts: [Int: Int]) -> Int? {
        counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }?.key
    }
}

// MARK: - Statut d'identification d'un site

/// Réponse à l'unique question que pose la page : « ce site est-il déjà identifié ? ».
///
/// Un SEUL critère — l'eNB/gNB est connu du serveur. Pas de troisième état
/// « hypothèse » ici : une hypothèse de proximité coûte 3,7× plus cher à
/// résoudre (elle exige la position) et ne répond pas à cette question. Elle a sa
/// place là où l'on regarde UN site à la fois, c'est-à-dire dans la feuille
/// d'identification et la file en chaîne.
enum RadioLogSiteState: Codable, Sendable, Equatable {
    /// Jamais soumis au balayage, ou balayage en cours.
    case unchecked
    case identified(siteId: String)
    case unidentified

    var isIdentified: Bool { if case .identified = self { return true }; return false }
    var isUnidentified: Bool { self == .unidentified }
    var isChecked: Bool { self != .unchecked }

    var siteId: String? { if case let .identified(siteId) = self { return siteId }; return nil }

    var label: String {
        switch self {
        case .unchecked: return String(localized: "Vérification…")
        case .identified: return String(localized: "Identifié")
        case .unidentified: return String(localized: "Non identifié")
        }
    }

    private enum Kind: String, Codable { case unchecked, identified, unidentified }
    private enum CodingKeys: String, CodingKey { case kind, siteId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .unchecked: self = .unchecked
        case .identified: self = .identified(siteId: (try? c.decode(String.self, forKey: .siteId)) ?? "")
        case .unidentified: self = .unidentified
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unchecked: try c.encode(Kind.unchecked, forKey: .kind)
        case let .identified(siteId):
            try c.encode(Kind.identified, forKey: .kind)
            try c.encode(siteId, forKey: .siteId)
        case .unidentified: try c.encode(Kind.unidentified, forKey: .kind)
        }
    }
}

/// Statut caché sur disque, avec son horodatage pour le TTL.
struct CachedRadioLogSiteState: Codable, Sendable {
    let state: RadioLogSiteState
    let updatedAtMs: Int
}

/// Hypothèse de site proposée par le serveur pour un site NON identifié.
/// Résolue à la demande (`identify/quick` avec position), jamais pendant le
/// balayage : c'est une piste à confirmer, pas une identification.
struct RadioLogSiteHypothesis: Sendable, Equatable {
    let siteId: String
    let latitude: Double?
    let longitude: Double?
    let confidenceScore: Int?
    let distanceMeters: Int?
    let sector: Int?
    /// `proximity`, `exact_operator`… — dit d'où vient la piste.
    let resolutionMode: String?

    /// `confiance 88 % · 2,9 km` — la ligne de méta de l'état « hypothèse ».
    var summaryLabel: String? {
        var parts: [String] = []
        if let confidenceScore { parts.append("confiance \(confidenceScore) %") }
        if let distanceMeters {
            parts.append(SQUnits.distance(meters: Double(distanceMeters)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
