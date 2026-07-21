import Foundation

/// Identification d'une cellule observée → site ANFR/ISED
/// (`POST /api/android/map/identify/direct`). Le serveur croise les
/// identifiants radio + position et confirme l'antenne.
protocol IdentifyServicing: Sendable {
    func identify(
        siteId: String?,
        enb: String?,
        gnb: String?,
        pci: String?,
        cellId: String?,
        operatorName: String?,
        mcc: String?,
        mnc: String?,
        lat: Double,
        lng: Double
    ) async throws -> IdentifyResult

    /// Liste des identifications de l'utilisateur (compte partagé Android/iOS).
    /// `includeRelated` ajoute les lignes PCI/Cell ID en plus des nœuds eNB/gNB.
    func mine(includeRelated: Bool) async throws -> [MyIdentification]

    /// Retrait (soft) d'une identification de l'utilisateur. Idempotent.
    func withdraw(
        siteId: String,
        enb: String?,
        gnb: String?,
        pci: String?,
        cellId: String?,
        ci: String?,
        tech: String?,
        reason: String?
    ) async throws -> WithdrawResult

    /// Suppression DÉFINITIVE (hard delete) des contributions SOLO de l'utilisateur pour un
    /// nœud/cellule. Les lignes confirmées par autrui sont seulement retirées (soft) — jamais
    /// effacées. Owner-scoped, irréversible pour les lignes solo. Idempotent.
    func delete(
        siteId: String,
        enb: String?,
        gnb: String?,
        pci: String?,
        cellId: String?,
        ci: String?,
        tech: String?,
        reason: String?
    ) async throws -> DeleteResult

    /// Ré-attribue un nœud eNB/gNB de l'utilisateur vers un AUTRE site (cascade
    /// toutes ses cellules). Owner-scoped, idempotent.
    func editSite(
        fromSiteId: String,
        toSiteId: String,
        enb: String?,
        gnb: String?,
        reason: String?
    ) async throws -> EditSiteResult

    /// Corrige le(s) secteur(s) d'une cellule (PCI/CellID). En France le secteur est
    /// auto-déduit → réponse `applied=false, reason="AUTO_DERIVED"`.
    func editSectors(
        siteId: String,
        enb: String?,
        gnb: String?,
        pci: String?,
        cellId: String?,
        ci: String?,
        tech: String?,
        operatorName: String,
        marketCode: String?,
        sectors: [Int]
    ) async throws -> EditSectorsResult
}

final class IdentifyService: IdentifyServicing {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    func identify(
        siteId: String?,
        enb: String?,
        gnb: String?,
        pci: String?,
        cellId: String?,
        operatorName: String?,
        mcc: String?,
        mnc: String?,
        lat: Double,
        lng: Double
    ) async throws -> IdentifyResult {
        struct Body: Encodable {
            let siteId: String?
            let enb: String?
            let gnb: String?
            let pci: String?
            let cellId: String?
            let `operator`: String?
            let mcc: String?
            let mnc: String?
            let userLat: Double
            let userLng: Double
        }
        return try await api.requestJSON(
            "/api/android/map/identify/direct",
            method: .post,
            body: Body(
                siteId: siteId, enb: enb, gnb: gnb, pci: pci, cellId: cellId,
                operator: operatorName, mcc: mcc, mnc: mnc, userLat: lat, userLng: lng
            )
        )
    }

    func mine(includeRelated: Bool = false) async throws -> [MyIdentification] {
        var query: [URLQueryItem] = []
        if includeRelated { query.append(URLQueryItem(name: "include", value: "related")) }
        let response = try await api.request(
            APIEndpoint(path: "/api/android/map/identify/mine", query: query),
            as: MyIdentificationsResponse.self
        )
        return response.identifications
    }

    func withdraw(
        siteId: String,
        enb: String?,
        gnb: String?,
        pci: String?,
        cellId: String?,
        ci: String?,
        tech: String?,
        reason: String?
    ) async throws -> WithdrawResult {
        struct Body: Encodable {
            let siteId: String
            let enb: String?
            let gnb: String?
            let pci: String?
            let cellId: String?
            let ci: String?
            let tech: String?
            let reason: String?
        }
        return try await api.requestJSON(
            "/api/android/map/identify/withdraw",
            method: .post,
            body: Body(siteId: siteId, enb: enb, gnb: gnb, pci: pci, cellId: cellId, ci: ci, tech: tech, reason: reason)
        )
    }

    func delete(
        siteId: String,
        enb: String?,
        gnb: String?,
        pci: String?,
        cellId: String?,
        ci: String?,
        tech: String?,
        reason: String?
    ) async throws -> DeleteResult {
        struct Body: Encodable {
            let siteId: String
            let enb: String?
            let gnb: String?
            let pci: String?
            let cellId: String?
            let ci: String?
            let tech: String?
            let reason: String?
        }
        return try await api.requestJSON(
            "/api/android/map/identify/delete",
            method: .post,
            body: Body(siteId: siteId, enb: enb, gnb: gnb, pci: pci, cellId: cellId, ci: ci, tech: tech, reason: reason)
        )
    }

    func editSite(
        fromSiteId: String,
        toSiteId: String,
        enb: String?,
        gnb: String?,
        reason: String?
    ) async throws -> EditSiteResult {
        struct Body: Encodable {
            let fromSiteId: String
            let toSiteId: String
            let enb: String?
            let gnb: String?
            let reason: String?
        }
        return try await api.requestJSON(
            "/api/android/map/identify/edit-site",
            method: .post,
            body: Body(fromSiteId: fromSiteId, toSiteId: toSiteId, enb: enb, gnb: gnb, reason: reason)
        )
    }

    func editSectors(
        siteId: String,
        enb: String?,
        gnb: String?,
        pci: String?,
        cellId: String?,
        ci: String?,
        tech: String?,
        operatorName: String,
        marketCode: String?,
        sectors: [Int]
    ) async throws -> EditSectorsResult {
        struct Body: Encodable {
            let siteId: String
            let enb: String?
            let gnb: String?
            let pci: String?
            let cellId: String?
            let ci: String?
            let tech: String?
            let `operator`: String
            let marketCode: String?
            let sectors: [Int]
        }
        return try await api.requestJSON(
            "/api/android/map/identify/edit-sectors",
            method: .post,
            body: Body(
                siteId: siteId, enb: enb, gnb: gnb, pci: pci, cellId: cellId, ci: ci,
                tech: tech, operator: operatorName, marketCode: marketCode, sectors: sectors
            )
        )
    }
}
