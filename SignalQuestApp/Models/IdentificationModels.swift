import Foundation

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Une identification cellule→site faite par l'utilisateur (`GET /api/android/map/identify/mine`).
/// Le compte étant partagé, on retrouve ici les identifications faites sur Android.
/// Décodage tolérant.
struct MyIdentification: Decodable, Identifiable, Equatable {
    let id: String
    let siteId: String
    let type: String          // enb | gnb | pci | cellid
    let enb: String?
    let gnb: String?
    let cellId: String?
    let pciValue: String?
    let pci: Int?
    let ci: String?
    let tech: String?
    let band: Int?
    let operatorName: String?
    let operatorMcc: Int?
    let operatorMnc: Int?
    let marketCode: String?
    let sectors: [Int]
    let validations: Int
    let source: String?
    let createdAt: Date?
    let lastValidated: Date?
    /// Présent seulement sur les nœuds enb/gnb : un AUTRE site domine ce nœud.
    let conflict: Bool
    /// Site « consensus » communautaire qui domine ce nœud en conflit (clés Android
    /// `conflictSite*` de `mine?include=related`). Permet « Adopter le site communautaire ».
    let conflictSiteId: String?
    let conflictSiteAddress: String?
    let conflictSiteValidations: Int?
    let conflictSiteLat: Double?
    let conflictSiteLng: Double?
    /// Nœuds, v1 et v2 : `unavailable` quand le contrôle de conflit a échoué. Lu
    /// avant `conflict`, qui reste `false` en v1 : on ne conclut jamais « aucun conflit ».
    let conflictStatus: IdentificationCheckStatus?
    /// v2, nœuds : porté ailleurs par le même opérateur, sans y être majoritaire. Signal seul.
    let contested: IdentificationContested?
    /// v2, cellules avec ECI/NCI : la même cellule déclarée ailleurs, ou avec un autre PCI.
    let cellConflict: IdentificationCellConflict?
    /// v2, lignes pci et cellid : secteur stocké comparé à la règle de l'opérateur.
    let sectorCheck: IdentificationSectorCheck?
    /// v2 : cellule qu'aucune ligne nœud active du membre ne porte (pages finales).
    let orphan: Bool
    /// v2 : nœud dont seules les 4 000 cellules les plus récentes sont servies.
    let cellsTruncated: Bool

    enum CodingKeys: String, CodingKey {
        case id, siteId, type, enb, gnb, cellId, pci, ci, tech, band
        case `operator`, operatorMcc, operatorMnc, marketCode, sectors, validations, source
        case createdAt, lastValidated, conflict
        case conflictSiteId, conflictSiteAddress, conflictSiteValidations, conflictSiteLat, conflictSiteLng
        case conflictStatus, contested, cellConflict, sectorCheck, orphan, cellsTruncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        siteId = c.decodeFlexibleString(forKey: .siteId) ?? ""
        type = (c.decodeFlexibleString(forKey: .type) ?? "enb").lowercased()
        enb = c.decodeFlexibleString(forKey: .enb)
        gnb = c.decodeFlexibleString(forKey: .gnb)
        cellId = c.decodeFlexibleString(forKey: .cellId)
        pciValue = c.decodeFlexibleString(forKey: .pci)
        pci = pciValue.flatMap(Int.init)
        ci = c.decodeFlexibleString(forKey: .ci)
        tech = c.decodeFlexibleString(forKey: .tech)
        band = try? c.decodeIfPresent(Int.self, forKey: .band)
        operatorName = c.decodeFlexibleString(forKey: .operator)
        operatorMcc = try? c.decodeIfPresent(Int.self, forKey: .operatorMcc)
        operatorMnc = try? c.decodeIfPresent(Int.self, forKey: .operatorMnc)
        marketCode = c.decodeFlexibleString(forKey: .marketCode)
        sectors = c.decodeLossyArray([Int].self, forKey: .sectors)
        validations = (try? c.decodeIfPresent(Int.self, forKey: .validations)) ?? 0
        source = c.decodeFlexibleString(forKey: .source)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
        lastValidated = (try? c.decodeIfPresent(Date.self, forKey: .lastValidated)) ?? nil
        conflict = (try? c.decodeIfPresent(Bool.self, forKey: .conflict)) ?? false
        conflictSiteId = c.decodeFlexibleString(forKey: .conflictSiteId)
        conflictSiteAddress = c.decodeFlexibleString(forKey: .conflictSiteAddress)
        conflictSiteValidations = try? c.decodeIfPresent(Int.self, forKey: .conflictSiteValidations)
        conflictSiteLat = try? c.decodeIfPresent(Double.self, forKey: .conflictSiteLat)
        conflictSiteLng = try? c.decodeIfPresent(Double.self, forKey: .conflictSiteLng)
        conflictStatus = c.decodeFlexibleString(forKey: .conflictStatus).flatMap(IdentificationCheckStatus.init(rawValue:))
        contested = (try? c.decodeIfPresent(IdentificationContested.self, forKey: .contested)) ?? nil
        cellConflict = (try? c.decodeIfPresent(IdentificationCellConflict.self, forKey: .cellConflict)) ?? nil
        sectorCheck = (try? c.decodeIfPresent(IdentificationSectorCheck.self, forKey: .sectorCheck)) ?? nil
        orphan = (try? c.decodeIfPresent(Bool.self, forKey: .orphan)) ?? false
        cellsTruncated = (try? c.decodeIfPresent(Bool.self, forKey: .cellsTruncated)) ?? false
    }

    /// Le contrôle de conflit de ce nœud n'a pas pu être fait.
    var conflictCheckUnavailable: Bool { conflictStatus == .unavailable }

    /// iOS écrit « 4G »/« 5G », Android et le serveur peuvent renvoyer « LTE »/« NR » :
    /// on ramène les deux vocabulaires à la génération, pour le filtre et le groupement.
    static func normalizedTech(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.contains("5G") || value == "NR" || value.hasPrefix("NR ") || value.hasPrefix("NR-") { return "5G" }
        if value.contains("4G") || value.contains("LTE") { return "4G" }
        return value
    }

    /// Catégorie radio normalisée pour le filtrage / affichage.
    enum Kind: String { case enb, gnb, pci, cellid, other }
    var kind: Kind { Kind(rawValue: type) ?? .other }

    /// Identifiant de nœud lisible (« eNB 12345 », « gNB 678 », « PCI 42 »…).
    var nodeLabel: String {
        switch kind {
        case .enb: return "eNB \(enb ?? cellId ?? "—")"
        case .gnb: return "gNB \(gnb ?? cellId ?? "—")"
        case .pci: return "PCI \(pciValue ?? "—")"
        case .cellid: return String(localized: "Cellule \(cellId ?? "—")")
        case .other: return enb ?? gnb ?? cellId ?? siteId
        }
    }

    /// « Orange » plutôt que la clé serveur « ORANGE » ; hors France, le nom reçu.
    var operatorDisplayName: String? {
        guard let operatorName, !operatorName.isEmpty else { return nil }
        return AntennaLeaderReport.key(operatorName).map(AntennaLeaderReport.displayName) ?? operatorName
    }

    /// Génération réseau déduite (5G si gNB, sinon le champ `tech`, sinon 4G).
    var techLabel: String {
        if let t = tech, !t.isEmpty { return Self.normalizedTech(t) }
        switch kind {
        case .gnb: return "5G"
        case .enb: return "4G"
        default: return "—"
        }
    }
}

enum IdentifiedNodeKind: String, Equatable {
    case enb = "eNB"
    case gnb = "gNB"
    /// Lignes sans eNB ni gNB : regroupées à part pour rester visibles et retirables.
    case unassigned = ""
}

struct IdentifiedCell: Identifiable, Equatable {
    let id: String
    let source: MyIdentification
    let pci: String?
    let ci: String?
    let cellId: String?
    let sectors: [Int]

    var label: String {
        if let pci, !pci.isEmpty { return "PCI \(pci)" }
        if let cellId, !cellId.isEmpty { return String(localized: "Cellule \(cellId)") }
        if let ci, !ci.isEmpty { return "CI \(ci)" }
        return String(localized: "Cellule")
    }
}

struct IdentifiedNodeGroup: Identifiable, Equatable {
    let id: String
    let kind: IdentifiedNodeKind
    let nodeValue: String
    let representative: MyIdentification
    let cells: [IdentifiedCell]
    let validations: Int
    let sectorsUnion: [Int]
    let conflict: Bool
    /// Ligne nœud « contestée » (signal seul, jamais avec `conflict`).
    let contested: Bool
    let cellsTruncated: Bool

    var title: String {
        kind == .unassigned ? String(localized: "Cellules sans nœud") : "\(kind.rawValue) \(nodeValue)"
    }
    var subtitle: String {
        let count = cells.count
        let cellPart = count == 0 ? String(localized: "aucune cellule") : String(localized: "\(count) cellules")
        return "\(representative.operatorDisplayName ?? String(localized: "Opérateur inconnu")) · \(representative.techLabel) · \(cellPart)"
    }

    static func group(_ items: [MyIdentification]) -> [IdentifiedNodeGroup] {
        struct Acc {
            let kind: IdentifiedNodeKind
            let nodeValue: String
            var representative: MyIdentification
            var cells: [IdentifiedCell] = []
            var validations = 0
            var sectors = Set<Int>()
            var conflict = false
            var contested = false
            var cellsTruncated = false
            var order = 0
        }

        var values: [String: Acc] = [:]
        for item in items {
            let node: (IdentifiedNodeKind, String)
            if item.orphan {
                // Orpheline (v2) : aucune ligne nœud active ne la porte, même si
                // elle garde son eNB/gNB. Elle rejoint « Cellules sans nœud ».
                node = (.unassigned, "")
            } else if item.techLabel.uppercased().contains("5G"), let gnb = item.gnb?.nilIfBlank {
                node = (.gnb, gnb)
            } else if let enb = item.enb?.nilIfBlank {
                node = (.enb, enb)
            } else if let gnb = item.gnb?.nilIfBlank {
                node = (.gnb, gnb)
            } else {
                node = (.unassigned, "")
            }
            let (kind, nodeValue) = node
            let key = "\(kind.rawValue):\(nodeValue)"
            var acc = values[key] ?? Acc(kind: kind, nodeValue: nodeValue, representative: item, order: values.count)
            // La ligne du NŒUD (eNB/gNB) représente le groupe dès qu'elle existe :
            // la plus récente pouvait être une cellule PCI, et toucher le nœud ouvrait
            // alors cette cellule, que « Retirer » retirait seule (AF-RAD-15).
            let isNodeRow: (MyIdentification) -> Bool = { $0.kind == .enb || $0.kind == .gnb }
            let newer = (item.lastValidated ?? item.createdAt ?? .distantPast)
                > (acc.representative.lastValidated ?? acc.representative.createdAt ?? .distantPast)
            if isNodeRow(item) != isNodeRow(acc.representative) {
                if isNodeRow(item) { acc.representative = item }
            } else if newer {
                acc.representative = item
            }
            acc.validations = max(acc.validations, item.validations)
            acc.sectors.formUnion(item.sectors)
            acc.conflict = acc.conflict || item.conflict
            acc.contested = acc.contested || item.contested != nil
            acc.cellsTruncated = acc.cellsTruncated || item.cellsTruncated
            if kind == .unassigned || item.kind == .pci || item.kind == .cellid || item.pciValue != nil || item.ci != nil || item.cellId != nil {
                // Sans nœud commun, deux cellules de même PCI peuvent venir de sites
                // différents : la ligne elle-même les distingue.
                let cellId = kind == .unassigned ? item.id
                    : item.ci.map { "ci:\($0)" }
                    ?? item.pciValue.map { "pci:\($0)" }
                    ?? item.cellId.map { "cell:\($0)" }
                    ?? item.id
                let cell = IdentifiedCell(
                    id: "\(key):\(cellId)",
                    source: item,
                    pci: item.pciValue,
                    ci: item.ci,
                    cellId: item.cellId,
                    sectors: item.sectors
                )
                if !acc.cells.contains(where: { $0.id == cell.id }) {
                    acc.cells.append(cell)
                }
            }
            values[key] = acc
        }

        let groups = values.sorted { $0.value.order < $1.value.order }.map { key, acc in
            IdentifiedNodeGroup(
                id: key,
                kind: acc.kind,
                nodeValue: acc.nodeValue,
                representative: acc.representative,
                cells: acc.cells.sorted { $0.label < $1.label },
                validations: acc.validations,
                sectorsUnion: acc.sectors.sorted(),
                conflict: acc.conflict,
                contested: acc.contested,
                cellsTruncated: acc.cellsTruncated
            )
        }
        // Ordre du serveur (createdAt décroissant, stable d'une page à l'autre) :
        // retrier sur `lastValidated` ferait sauter les nœuds pendant le défilement.
        // Les cellules sans nœud ferment la liste.
        return groups.filter { $0.kind != .unassigned } + groups.filter { $0.kind == .unassigned }
    }
}

/// Réponse de `GET /api/android/map/identify/mine`.
struct MyIdentificationsResponse: Decodable {
    let identifications: [MyIdentification]

    enum CodingKeys: String, CodingKey { case identifications }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifications = c.decodeLossyArray([MyIdentification].self, forKey: .identifications)
    }
}

/// État explicite d'un contrôle v2 (`checks`, `conflictStatus`).
enum IdentificationCheckStatus: String, Decodable, Equatable, Sendable {
    case ok, unavailable
}

/// `contested` d'un nœud : signal seul, aucune action proposée.
struct IdentificationContested: Decodable, Equatable, Sendable {
    struct OtherSite: Decodable, Equatable, Sendable {
        let siteId: String
        let validations: Int

        enum CodingKeys: String, CodingKey { case siteId, validations }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            siteId = c.decodeFlexibleString(forKey: .siteId) ?? ""
            validations = (try? c.decodeIfPresent(Int.self, forKey: .validations)) ?? 0
        }
    }

    enum Reason: String, Equatable, Sendable { case tie, minorityElsewhere = "minority_elsewhere" }

    let otherSites: [OtherSite]
    /// `nil` pour une raison inconnue : le signal reste, sans phrase précise.
    let reason: Reason?

    enum CodingKeys: String, CodingKey { case otherSites, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        otherSites = c.decodeLossyArray([OtherSite].self, forKey: .otherSites).filter { !$0.siteId.isEmpty }
        reason = c.decodeFlexibleString(forKey: .reason).flatMap(Reason.init(rawValue:))
    }
}

/// `cellConflict` d'une cellule : même opérateur, lignes retirées ignorées.
struct IdentificationCellConflict: Decodable, Equatable, Sendable {
    enum Reason: String, Equatable, Sendable { case otherSite = "other_site", pciMismatch = "pci_mismatch" }

    let reason: Reason
    let siteId: String?
    let pci: String?

    enum CodingKeys: String, CodingKey { case reason, siteId, pci }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let reason = c.decodeFlexibleString(forKey: .reason).flatMap(Reason.init(rawValue:)) else {
            throw DecodingError.dataCorruptedError(forKey: .reason, in: c, debugDescription: "raison inconnue")
        }
        self.reason = reason
        siteId = c.decodeFlexibleString(forKey: .siteId)
        pci = c.decodeFlexibleString(forKey: .pci)
    }
}

/// `sectorCheck` d'une cellule. `expected` n'existe que pour `mismatch`, dans la
/// numérotation stockée (SFR en base 0, les autres en base 1), comme `sectors`.
struct IdentificationSectorCheck: Decodable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case match, mismatch, notApplicable = "not_applicable", unknown
    }

    let status: Status
    let expected: Int?

    enum CodingKeys: String, CodingKey { case status, expected }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let status = c.decodeFlexibleString(forKey: .status).flatMap(Status.init(rawValue:)) else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "statut inconnu")
        }
        // Un écart sans secteur attendu n'a rien à proposer : on le lit comme inconnu.
        let expected = status == .mismatch ? (try? c.decodeIfPresent(Int.self, forKey: .expected)) ?? nil : nil
        self.status = status == .mismatch && expected == nil ? .unknown : status
        self.expected = expected
    }
}

/// `checks` d'une page v2. Absent ou illisible vaut `unavailable` : sans état
/// explicite, l'app ne conclut jamais « rien à signaler ».
struct IdentificationChecks: Decodable, Equatable, Sendable {
    var conflict: IdentificationCheckStatus
    var cellConflict: IdentificationCheckStatus
    var sectorCheck: IdentificationCheckStatus

    static let unavailable = IdentificationChecks(conflict: .unavailable, cellConflict: .unavailable, sectorCheck: .unavailable)

    init(conflict: IdentificationCheckStatus, cellConflict: IdentificationCheckStatus, sectorCheck: IdentificationCheckStatus) {
        self.conflict = conflict
        self.cellConflict = cellConflict
        self.sectorCheck = sectorCheck
    }

    enum CodingKeys: String, CodingKey { case conflict, cellConflict, sectorCheck }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys) -> IdentificationCheckStatus {
            c.decodeFlexibleString(forKey: key).flatMap(IdentificationCheckStatus.init(rawValue:)) ?? .unavailable
        }
        conflict = read(.conflict)
        cellConflict = read(.cellConflict)
        sectorCheck = read(.sectorCheck)
    }

    /// Plusieurs pages : un contrôle indisponible sur l'une l'est pour la liste.
    func merged(with other: IdentificationChecks) -> IdentificationChecks {
        func worst(_ a: IdentificationCheckStatus, _ b: IdentificationCheckStatus) -> IdentificationCheckStatus {
            a == .unavailable || b == .unavailable ? .unavailable : .ok
        }
        return IdentificationChecks(
            conflict: worst(conflict, other.conflict),
            cellConflict: worst(cellConflict, other.cellConflict),
            sectorCheck: worst(sectorCheck, other.sectorCheck)
        )
    }
}

/// `totals` de la première page : sur toutes les lignes des filtres operator /
/// marketCode, jamais sur la page, et sans tenir compte de `conflict`.
struct IdentificationTotals: Decodable, Equatable, Sendable {
    let nodes: Int
    let enb: Int
    let gnb: Int
    /// Des LIGNES pci/cellid, pas des cellules distinctes.
    let cellRows: Int
    let orphanRows: Int
    /// `nil` : le consensus n'a pas pu être calculé.
    let conflicts: Int?
    let contested: Int?

    enum CodingKeys: String, CodingKey { case nodes, enb, gnb, cellRows, orphanRows, conflicts, contested }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try c.decode(Int.self, forKey: .nodes)
        enb = (try? c.decodeIfPresent(Int.self, forKey: .enb)) ?? 0
        gnb = (try? c.decodeIfPresent(Int.self, forKey: .gnb)) ?? 0
        cellRows = (try? c.decodeIfPresent(Int.self, forKey: .cellRows)) ?? 0
        orphanRows = (try? c.decodeIfPresent(Int.self, forKey: .orphanRows)) ?? 0
        conflicts = (try? c.decodeIfPresent(Int.self, forKey: .conflicts)) ?? nil
        contested = (try? c.decodeIfPresent(Int.self, forKey: .contested)) ?? nil
    }
}

/// Une page de `GET /api/android/map/identify/mine?v=2` (contrat « Mes
/// identifications » v2, `docs/my-identifications-v2-contract.md`).
struct MyIdentificationsPage: Decodable {
    let identifications: [MyIdentification]
    /// `nil` en fin de liste.
    let nextCursor: String?
    let truncated: Bool
    /// La liste a changé pendant le parcours : proposer de recharger.
    let restartAdvised: Bool
    let checks: IdentificationChecks
    /// Première page seulement.
    let totals: IdentificationTotals?

    enum CodingKeys: String, CodingKey { case identifications, nextCursor, truncated, restartAdvised, checks, totals }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifications = c.decodeLossyArray([MyIdentification].self, forKey: .identifications)
        nextCursor = c.decodeFlexibleString(forKey: .nextCursor)
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        restartAdvised = (try? c.decodeIfPresent(Bool.self, forKey: .restartAdvised)) ?? false
        checks = (try? c.decodeIfPresent(IdentificationChecks.self, forKey: .checks)) ?? .unavailable
        totals = (try? c.decodeIfPresent(IdentificationTotals.self, forKey: .totals)) ?? nil
    }
}

/// Réponse de `POST /api/android/map/identify/edit-site` (re-mappe un nœud
/// eNB/gNB vers un autre site).
struct EditSiteResult: Decodable, Equatable {
    let success: Bool
    let moved: Int
    let toSiteId: String?
    let noop: Bool

    enum CodingKeys: String, CodingKey { case success, moved, toSiteId, noop }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = (try? c.decodeIfPresent(Bool.self, forKey: .success)) ?? false
        moved = (try? c.decodeIfPresent(Int.self, forKey: .moved)) ?? 0
        toSiteId = c.decodeFlexibleString(forKey: .toSiteId)
        noop = (try? c.decodeIfPresent(Bool.self, forKey: .noop)) ?? false
    }

    /// Le serveur répond 200 même quand rien ne correspond (`moved: 0`) ; `noop` (site
    /// déjà le bon) compte comme un changement, comme sur le web.
    var changed: Bool { success && (moved > 0 || noop) }
}

/// Réponse de `POST /api/android/map/identify/edit-sectors`. Le secteur saisi est écrit ;
/// pour les opérateurs français le serveur renvoie en plus le secteur déduit du PCI
/// (`derived`) comme référence.
struct EditSectorsResult: Decodable, Equatable {
    let applied: Bool
    let updated: Int
    let sectors: [Int]
    /// Secteur(s) déduit(s) du PCI, vide quand le serveur n'en déduit pas.
    let derived: [Int]
    let reason: String?
    let message: String?

    enum CodingKeys: String, CodingKey { case applied, updated, sectors, derived, reason, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applied = (try? c.decodeIfPresent(Bool.self, forKey: .applied)) ?? false
        updated = (try? c.decodeIfPresent(Int.self, forKey: .updated)) ?? 0
        sectors = c.decodeLossyArray([Int].self, forKey: .sectors)
        derived = c.decodeLossyArray([Int].self, forKey: .derived)
        reason = c.decodeFlexibleString(forKey: .reason)
        message = c.decodeFlexibleString(forKey: .message)
    }

    /// `applied` avec `updated: 0` : aucune ligne n'a changé.
    var changed: Bool { applied && updated > 0 }
}

/// Réponse de `POST /api/android/map/identify/withdraw`.
struct WithdrawResult: Decodable, Equatable {
    let success: Bool
    let siteId: String?
    let withdrawn: Int
    let withdrawnAt: Date?

    enum CodingKeys: String, CodingKey { case success, siteId, withdrawn, withdrawnAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = (try? c.decodeIfPresent(Bool.self, forKey: .success)) ?? false
        siteId = c.decodeFlexibleString(forKey: .siteId)
        withdrawn = (try? c.decodeIfPresent(Int.self, forKey: .withdrawn)) ?? 0
        withdrawnAt = (try? c.decodeIfPresent(Date.self, forKey: .withdrawnAt)) ?? nil
    }

    /// Le retrait ne touche que les lignes de l'auteur et répond toujours 200 :
    /// `withdrawn: 0` veut dire qu'aucune ne correspondait.
    var changed: Bool { success && withdrawn > 0 }
}

/// Réponse de `POST /api/android/map/identify/delete` (suppression DÉFINITIVE).
/// `deleted` = lignes solo hard-supprimées ; `softWithdrawn` = lignes partagées
/// (confirmées par autrui) simplement retirées en soft — jamais effacées.
struct DeleteResult: Decodable, Equatable {
    let success: Bool
    let siteId: String?
    let deleted: Int
    let softWithdrawn: Int

    enum CodingKeys: String, CodingKey { case success, siteId, deleted, softWithdrawn }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = (try? c.decodeIfPresent(Bool.self, forKey: .success)) ?? false
        siteId = c.decodeFlexibleString(forKey: .siteId)
        deleted = (try? c.decodeIfPresent(Int.self, forKey: .deleted)) ?? 0
        softWithdrawn = (try? c.decodeIfPresent(Int.self, forKey: .softWithdrawn)) ?? 0
    }

    var changed: Bool { success && deleted + softWithdrawn > 0 }
}
