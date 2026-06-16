import Foundation

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

    enum CodingKeys: String, CodingKey {
        case id, siteId, type, enb, gnb, cellId, pci, ci, tech, band
        case `operator`, operatorMcc, operatorMnc, marketCode, sectors, validations, source
        case createdAt, lastValidated, conflict
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFlexibleString(forKey: .id) ?? UUID().uuidString
        siteId = c.decodeFlexibleString(forKey: .siteId) ?? ""
        type = (c.decodeFlexibleString(forKey: .type) ?? "enb").lowercased()
        enb = c.decodeFlexibleString(forKey: .enb)
        gnb = c.decodeFlexibleString(forKey: .gnb)
        cellId = c.decodeFlexibleString(forKey: .cellId)
        pci = try? c.decodeIfPresent(Int.self, forKey: .pci)
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
    }

    /// Catégorie radio normalisée pour le filtrage / affichage.
    enum Kind: String { case enb, gnb, pci, cellid, other }
    var kind: Kind { Kind(rawValue: type) ?? .other }

    /// Identifiant de nœud lisible (« eNB 12345 », « gNB 678 », « PCI 42 »…).
    var nodeLabel: String {
        switch kind {
        case .enb: return "eNB \(enb ?? cellId ?? "—")"
        case .gnb: return "gNB \(gnb ?? cellId ?? "—")"
        case .pci: return "PCI \(pci.map(String.init) ?? "—")"
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
