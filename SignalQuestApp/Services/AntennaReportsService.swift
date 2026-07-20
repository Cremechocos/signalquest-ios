import Foundation

/// Accès réseau aux signalements d'antenne (parité Android/web). Contrat backend
/// déjà en prod — cf. `docs/backend-ios-additive-routes.md` :
/// - `POST /api/antennas/reports` : émettre un signalement.
/// - `GET  /api/antennas/reports` : lister MES signalements.
/// - `GET  /api/antennas/reports/{id}/comments` : fil de discussion.
/// - `POST /api/antennas/reports/{id}/comments` : répondre (texte + images).
protocol AntennaReportsServicing: Sendable {
    @discardableResult
    func submit(
        siteId: String,
        reportType: AntennaReportType,
        currentValue: String?,
        suggestedValue: String?,
        reason: String?,
        sector: Int?
    ) async throws -> AntennaReportSubmissionResult

    func myReports() async throws -> [AntennaReport]
    func comments(reportId: String) async throws -> [AntennaReportComment]

    @discardableResult
    func addComment(reportId: String, content: String, images: [String]) async throws -> AntennaReportComment
}

final class AntennaReportsService: AntennaReportsServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    @discardableResult
    func submit(
        siteId: String,
        reportType: AntennaReportType,
        currentValue: String?,
        suggestedValue: String?,
        reason: String?,
        sector: Int?
    ) async throws -> AntennaReportSubmissionResult {
        let body = AntennaReportSubmission(
            siteId: siteId,
            reportType: reportType.rawValue,
            currentValue: currentValue.nonBlank,
            suggestedValue: suggestedValue.nonBlank,
            reason: reason.nonBlank,
            sector: sector
        )
        // Clé d'idempotence : un double-tap « Envoyer » ne crée pas deux signalements
        // (le backend renvoie alors le même résultat, `duplicate` géré côté serveur).
        return try await api.requestJSON(
            "/api/antennas/reports",
            body: body,
            idempotencyKey: "antenna-report-\(siteId)-\(reportType.rawValue)-\(UUID().uuidString)"
        )
    }

    func myReports() async throws -> [AntennaReport] {
        try await api.request(
            APIEndpoint(path: "/api/antennas/reports"),
            as: AntennaReportsEnvelope.self
        ).reports
    }

    func comments(reportId: String) async throws -> [AntennaReportComment] {
        let encoded = reportId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? reportId
        return try await api.request(
            APIEndpoint(path: "/api/antennas/reports/\(encoded)/comments"),
            as: AntennaReportCommentsEnvelope.self
        ).comments
    }

    @discardableResult
    func addComment(reportId: String, content: String, images: [String]) async throws -> AntennaReportComment {
        struct Body: Encodable {
            let content: String
            let images: [String]?
        }
        let encoded = reportId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? reportId
        let envelope: AntennaReportCommentEnvelope = try await api.requestJSON(
            "/api/antennas/reports/\(encoded)/comments",
            body: Body(content: content, images: images.isEmpty ? nil : images)
        )
        return try envelope.comment
    }
}

// MARK: - Enveloppes tolérantes

/// Le backend peut renvoyer soit un tableau nu, soit `{ reports: [...] }` /
/// `{ items: [...] }`. On accepte les deux et on ignore les éléments malformés
/// (parité avec `NotificationsService`, robustesse ROB-03).
private struct AntennaReportsEnvelope: Decodable {
    let reports: [AntennaReport]

    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([FailableDecodable<AntennaReport>].self) {
            reports = array.compactMap(\.value)
            return
        }
        let c = try decoder.container(keyedBy: DynamicKey.self)
        for key in ["reports", "items", "data"] {
            if let dyn = DynamicKey(stringValue: key),
               let array = try? c.decode([FailableDecodable<AntennaReport>].self, forKey: dyn) {
                reports = array.compactMap(\.value)
                return
            }
        }
        reports = []
    }
}

private struct AntennaReportCommentsEnvelope: Decodable {
    let comments: [AntennaReportComment]

    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([FailableDecodable<AntennaReportComment>].self) {
            comments = array.compactMap(\.value)
            return
        }
        let c = try decoder.container(keyedBy: DynamicKey.self)
        for key in ["comments", "items", "data"] {
            if let dyn = DynamicKey(stringValue: key),
               let array = try? c.decode([FailableDecodable<AntennaReportComment>].self, forKey: dyn) {
                comments = array.compactMap(\.value)
                return
            }
        }
        comments = []
    }
}

/// Réponse du POST : le commentaire créé, nu ou enveloppé (`{ comment }`).
private struct AntennaReportCommentEnvelope: Decodable {
    private let stored: AntennaReportComment?

    var comment: AntennaReportComment {
        get throws {
            guard let stored else { throw APIError.decoding("Réponse de commentaire vide.") }
            return stored
        }
    }

    init(from decoder: Decoder) throws {
        if let direct = try? decoder.singleValueContainer().decode(AntennaReportComment.self) {
            stored = direct
            return
        }
        let c = try decoder.container(keyedBy: DynamicKey.self)
        for key in ["comment", "data", "result"] {
            if let dyn = DynamicKey(stringValue: key),
               let value = try? c.decode(AntennaReportComment.self, forKey: dyn) {
                stored = value
                return
            }
        }
        stored = nil
    }
}

/// Élément tolérant : décode `T` ou `nil` (ignore un élément malformé).
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(T.self)
    }
}

/// Clé de codage dynamique, pour sonder plusieurs noms d'enveloppe possibles.
private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension Optional where Wrapped == String {
    /// Chaîne non vide après trim, sinon `nil` — pour n'envoyer que des champs utiles.
    var nonBlank: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
