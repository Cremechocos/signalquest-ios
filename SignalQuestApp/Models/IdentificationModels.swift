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

    enum CodingKeys: String, CodingKey {
        case id, siteId, type, enb, gnb, cellId, pci, ci, tech, band
        case `operator`, operatorMcc, operatorMnc, marketCode, sectors, validations, source
        case createdAt, lastValidated, conflict
        case conflictSiteId, conflictSiteAddress, conflictSiteValidations, conflictSiteLat, conflictSiteLng
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
        case .cellid: return "Cell \(cellId ?? "—")"
        case .other: return enb ?? gnb ?? cellId ?? siteId
        }
    }

    /// Génération réseau déduite (5G si gNB, sinon le champ `tech`, sinon 4G).
    var techLabel: String {
        if let t = tech, !t.isEmpty { return t.uppercased() }
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
        if let cellId, !cellId.isEmpty { return "Cell \(cellId)" }
        if let ci, !ci.isEmpty { return "CI \(ci)" }
        return "Cellule"
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

    var title: String { "\(kind.rawValue) \(nodeValue)" }
    var subtitle: String {
        let count = cells.count
        let cellPart = count == 0 ? "aucune cellule" : "\(count) PCI/CI"
        return "\(representative.operatorName ?? "Opérateur inconnu") · \(representative.techLabel) · \(cellPart)"
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
        }

        var values: [String: Acc] = [:]
        for item in items {
            let node: (IdentifiedNodeKind, String)?
            if item.techLabel.uppercased().contains("5G"), let gnb = item.gnb?.nilIfBlank {
                node = (.gnb, gnb)
            } else if let enb = item.enb?.nilIfBlank {
                node = (.enb, enb)
            } else if let gnb = item.gnb?.nilIfBlank {
                node = (.gnb, gnb)
            } else {
                node = nil
            }
            guard let (kind, nodeValue) = node else { continue }
            let key = "\(kind.rawValue):\(nodeValue)"
            var acc = values[key] ?? Acc(kind: kind, nodeValue: nodeValue, representative: item)
            if (item.lastValidated ?? item.createdAt ?? .distantPast) > (acc.representative.lastValidated ?? acc.representative.createdAt ?? .distantPast) {
                acc.representative = item
            }
            acc.validations = max(acc.validations, item.validations)
            acc.sectors.formUnion(item.sectors)
            acc.conflict = acc.conflict || item.conflict
            if item.kind == .pci || item.kind == .cellid || item.pciValue != nil || item.ci != nil || item.cellId != nil {
                let cellId = item.ci.map { "ci:\($0)" }
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

        return values.map { key, acc in
            IdentifiedNodeGroup(
                id: key,
                kind: acc.kind,
                nodeValue: acc.nodeValue,
                representative: acc.representative,
                cells: acc.cells.sorted { $0.label < $1.label },
                validations: acc.validations,
                sectorsUnion: acc.sectors.sorted(),
                conflict: acc.conflict
            )
        }
        .sorted {
            ($0.representative.lastValidated ?? $0.representative.createdAt ?? .distantPast) >
            ($1.representative.lastValidated ?? $1.representative.createdAt ?? .distantPast)
        }
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
}

/// Réponse de `POST /api/android/map/identify/edit-sectors`. En France le secteur
/// est auto-déduit du PCI → `applied=false, reason="AUTO_DERIVED"` + le secteur réel.
struct EditSectorsResult: Decodable, Equatable {
    let applied: Bool
    let updated: Int
    let sectors: [Int]
    let reason: String?

    enum CodingKeys: String, CodingKey { case applied, updated, sectors, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applied = (try? c.decodeIfPresent(Bool.self, forKey: .applied)) ?? false
        updated = (try? c.decodeIfPresent(Int.self, forKey: .updated)) ?? 0
        sectors = c.decodeLossyArray([Int].self, forKey: .sectors)
        reason = c.decodeFlexibleString(forKey: .reason)
    }

    var isAutoDerived: Bool { reason?.uppercased() == "AUTO_DERIVED" }
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
}
