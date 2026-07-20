import Foundation

// MARK: - Type de signalement

/// Types de problème signalables sur une antenne (parité Android/web). Les
/// `rawValue` correspondent EXACTEMENT à l'enum accepté par le backend
/// `POST /api/antennas/reports` — ne pas renommer sans coordonner le serveur.
enum AntennaReportType: String, CaseIterable, Identifiable, Codable {
    case incorrectEnb = "incorrect_enb"
    case incorrectGnb = "incorrect_gnb"
    case incorrectCellId = "incorrect_cellid"
    case incorrectPci = "incorrect_pci"
    case incorrectSector = "incorrect_sector"
    case incorrectLeader = "incorrect_leader"
    case wrongLocation = "wrong_location"
    case duplicate = "duplicate"
    case incorrectLocation = "incorrect_location"
    case incorrectOperator = "incorrect_operator"
    case incorrectTech = "incorrect_tech"
    case other = "other"

    var id: String { rawValue }

    /// Libellé court affiché (chips de statut, en-têtes de fil).
    var label: String {
        switch self {
        case .incorrectEnb: return "eNB incorrect"
        case .incorrectGnb: return "gNB incorrect"
        case .incorrectCellId: return "Cell ID incorrect"
        case .incorrectPci: return "PCI incorrect"
        case .incorrectSector: return "Secteur incorrect"
        case .incorrectLeader: return "Opérateur porteur incorrect"
        case .wrongLocation: return "Mauvais emplacement"
        case .duplicate: return "Doublon"
        case .incorrectLocation: return "Coordonnées incorrectes"
        case .incorrectOperator: return "Opérateur incorrect"
        case .incorrectTech: return "Technologie incorrecte"
        case .other: return "Autre problème"
        }
    }

    /// Icône SF Symbol posée dans la pastille teintée du type.
    var systemImage: String {
        switch self {
        case .incorrectEnb, .incorrectGnb, .incorrectCellId, .incorrectPci: return "number"
        case .incorrectSector: return "safari"
        case .incorrectLeader, .incorrectOperator: return "building.2"
        case .wrongLocation, .incorrectLocation: return "mappin.slash"
        case .duplicate: return "square.on.square"
        case .incorrectTech: return "antenna.radiowaves.left.and.right"
        case .other: return "exclamationmark.bubble"
        }
    }

    /// Champs « valeur » pertinents pour ce type (pilote l'affichage du bloc
    /// « valeur actuelle / valeur correcte » du formulaire). `other` et les types
    /// de localisation n'appellent pas de couple de valeurs discrètes.
    var suggestsValues: Bool {
        switch self {
        case .other, .wrongLocation, .incorrectLocation, .duplicate: return false
        default: return true
        }
    }
}

// MARK: - Statut

/// Statut de traitement d'un signalement (renvoyé par le backend).
enum AntennaReportStatus: String, Codable {
    case pending
    case resolved
    case dismissed

    /// Statut inconnu / non renseigné → traité comme « en attente ».
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "pending"
        self = AntennaReportStatus(rawValue: raw.lowercased()) ?? .pending
    }

    var label: String {
        switch self {
        case .pending: return "En attente"
        case .resolved: return "Résolu"
        case .dismissed: return "Rejeté"
        }
    }

    var systemImage: String {
        switch self {
        case .pending: return "clock"
        case .resolved: return "checkmark.seal.fill"
        case .dismissed: return "xmark.circle"
        }
    }
}

// MARK: - Signalement

/// Un signalement d'antenne tel que renvoyé par `GET /api/antennas/reports`.
struct AntennaReport: Decodable, Identifiable, Equatable {
    let id: String
    let siteId: String
    let reportType: AntennaReportType
    let reason: String?
    let currentValue: String?
    let suggestedValue: String?
    let sector: Int?
    let status: AntennaReportStatus
    let createdAt: Date?
    let reviewedAt: Date?
    let reviewComment: String?
    let confirmCount: Int?
    let disputeCount: Int?
    let communityConfirmed: Bool?

    enum CodingKeys: String, CodingKey {
        case id, siteId, reportType, reason, currentValue, suggestedValue, sector
        case status, createdAt, reviewedAt, reviewComment
        case confirmCount, disputeCount, communityConfirmed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        siteId = (try? c.decodeIfPresent(String.self, forKey: .siteId)) ?? ""
        // Un `reportType` inconnu ne doit pas casser toute la liste : repli sur `.other`.
        reportType = (try? c.decodeIfPresent(AntennaReportType.self, forKey: .reportType)) ?? .other
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        currentValue = try? c.decodeIfPresent(String.self, forKey: .currentValue)
        suggestedValue = try? c.decodeIfPresent(String.self, forKey: .suggestedValue)
        sector = try? c.decodeIfPresent(Int.self, forKey: .sector)
        status = (try? c.decodeIfPresent(AntennaReportStatus.self, forKey: .status)) ?? .pending
        // `try?` : la stratégie de date jette sur une chaîne non parsable — on ne
        // veut pas qu'une date invalide vide toute la liste (cf. AppNotification/ROB-03).
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        reviewedAt = try? c.decodeIfPresent(Date.self, forKey: .reviewedAt)
        reviewComment = try? c.decodeIfPresent(String.self, forKey: .reviewComment)
        confirmCount = try? c.decodeIfPresent(Int.self, forKey: .confirmCount)
        disputeCount = try? c.decodeIfPresent(Int.self, forKey: .disputeCount)
        communityConfirmed = try? c.decodeIfPresent(Bool.self, forKey: .communityConfirmed)
    }

    /// Init mémoire (aperçus, tests) — n'entre pas dans le chemin de décodage.
    init(
        id: String,
        siteId: String,
        reportType: AntennaReportType,
        reason: String? = nil,
        currentValue: String? = nil,
        suggestedValue: String? = nil,
        sector: Int? = nil,
        status: AntennaReportStatus = .pending,
        createdAt: Date? = nil,
        reviewedAt: Date? = nil,
        reviewComment: String? = nil,
        confirmCount: Int? = nil,
        disputeCount: Int? = nil,
        communityConfirmed: Bool? = nil
    ) {
        self.id = id
        self.siteId = siteId
        self.reportType = reportType
        self.reason = reason
        self.currentValue = currentValue
        self.suggestedValue = suggestedValue
        self.sector = sector
        self.status = status
        self.createdAt = createdAt
        self.reviewedAt = reviewedAt
        self.reviewComment = reviewComment
        self.confirmCount = confirmCount
        self.disputeCount = disputeCount
        self.communityConfirmed = communityConfirmed
    }
}

// MARK: - Corps d'envoi

/// Corps JSON de `POST /api/antennas/reports`. Les champs optionnels à `nil` sont
/// omis (Codable synthétise `encodeIfPresent` pour les optionnels). `radioContext`
/// n'est pas transmis : iOS ne lit aucune métrique radio (cf. CLAUDE.md).
struct AntennaReportSubmission: Encodable {
    let siteId: String
    let reportType: String
    let currentValue: String?
    let suggestedValue: String?
    let reason: String?
    let sector: Int?
}

/// Réponse de `POST /api/antennas/reports` : `duplicate == true` signale que
/// l'utilisateur avait déjà émis ce type pour ce site (HTTP 200, pas une erreur).
struct AntennaReportSubmissionResult: Decodable {
    let success: Bool?
    let duplicate: Bool?
    let report: AntennaReport?
    let message: String?
}

// MARK: - Discussion

/// Auteur d'un message de discussion (`{ id, name }`), optionnel côté backend.
struct AntennaReportCommentAuthor: Decodable, Equatable {
    let id: String?
    let name: String?
}

/// Un message du fil de discussion d'un signalement
/// (`GET/POST /api/antennas/reports/{id}/comments`).
struct AntennaReportComment: Decodable, Identifiable, Equatable {
    let id: String
    let content: String
    let images: [String]
    let isAdmin: Bool
    let createdAt: Date?
    let author: AntennaReportCommentAuthor?

    enum CodingKeys: String, CodingKey {
        case id, content, images, isAdmin, createdAt, author
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        images = (try? c.decodeIfPresent([String].self, forKey: .images)) ?? []
        isAdmin = (try? c.decodeIfPresent(Bool.self, forKey: .isAdmin)) ?? false
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        author = try? c.decodeIfPresent(AntennaReportCommentAuthor.self, forKey: .author)
    }

    init(
        id: String,
        content: String,
        images: [String] = [],
        isAdmin: Bool = false,
        createdAt: Date? = nil,
        author: AntennaReportCommentAuthor? = nil
    ) {
        self.id = id
        self.content = content
        self.images = images
        self.isAdmin = isAdmin
        self.createdAt = createdAt
        self.author = author
    }
}
