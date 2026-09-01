import Foundation

/// Charge d'une identification directe (`POST /api/android/map/identify/direct`).
///
/// ⚠️ Le PLMN voyage sous les noms `mobileCountryCode` / `mobileNetworkCode`, PAS
/// `mcc` / `mnc`. Le contrat serveur (`DirectIdentifyBody`) ne déclare que les
/// premiers, et seuls ceux-là sont lus — `mcc`/`mnc` n'apparaissent nulle part
/// dans la route. Envoyer les seconds revient donc à n'envoyer AUCUN PLMN, et le
/// serveur ne peut plus rattacher l'identification au bon opérateur : selon les
/// droits du compte, il refuse (`MISSING_PLMN`, `OPERATOR_NOT_ALLOWED`) ou se
/// rabat sur le champ hérité `operator`. C'était le cas de tous les appels iOS
/// jusqu'ici.
struct IdentifyDirectRequest: Sendable {
    /// Site cible. Obligatoire côté serveur (`MISSING_SITE_ID` sinon).
    var siteId: String
    var enb: String?
    var gnb: String?
    /// Au moins un de `enb`, `gnb`, `pci` doit être présent
    /// (`MISSING_CELL_IDENTIFIERS` sinon).
    var pci: Int?
    var cellId: String?
    /// Identité cellule complète (ECI/NCI). En CHAÎNE : le serveur la relit en
    /// `BigInt`, et un NCI 5G dépasse la précision d'un `Double` JSON.
    var ci: String?
    /// `4G` / `5G`. Le serveur en dérive la canonicalisation NR et le secteur.
    var tech: String?
    var band: Int?
    var earfcn: Int?
    /// Secteur imposé. Laissé nil, le serveur le dérive lui-même (règle PCI/PSS),
    /// ce qui est préférable : sa règle fait autorité sur le calcul client.
    var sectorIndex: Int?
    var operatorName: String?
    /// Clé canonique du réseau servant. `operatorName` reste le champ hérité :
    /// il ne doit jamais être la seule preuve d'identité réseau.
    var operatorKey: String?
    var marketCode: String?
    var rawOperatorName: String?
    /// PLMN servant complet, conservé en chaîne pour préserver les MNC comme
    /// `001`. MCC/MNC restent envoyés séparément pour les anciens serveurs.
    var observedPlmn: String?
    var mcc: String?
    var mnc: String?
    var simPlmn: String?
    var isRoaming: Bool?
    var networkIdentitySource: String?
    var latitude: Double?
    var longitude: Double?

    init(
        siteId: String,
        enb: String? = nil,
        gnb: String? = nil,
        pci: Int? = nil,
        cellId: String? = nil,
        ci: String? = nil,
        tech: String? = nil,
        band: Int? = nil,
        earfcn: Int? = nil,
        sectorIndex: Int? = nil,
        operatorName: String? = nil,
        operatorKey: String? = nil,
        marketCode: String? = nil,
        rawOperatorName: String? = nil,
        observedPlmn: String? = nil,
        mcc: String? = nil,
        mnc: String? = nil,
        simPlmn: String? = nil,
        isRoaming: Bool? = nil,
        networkIdentitySource: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.siteId = siteId
        self.enb = enb
        self.gnb = gnb
        self.pci = pci
        self.cellId = cellId
        self.ci = ci
        self.tech = tech
        self.band = band
        self.earfcn = earfcn
        self.sectorIndex = sectorIndex
        self.operatorName = operatorName
        self.operatorKey = operatorKey
        self.marketCode = marketCode
        self.rawOperatorName = rawOperatorName
        self.observedPlmn = observedPlmn
        self.mcc = mcc
        self.mnc = mnc
        self.simPlmn = simPlmn
        self.isRoaming = isRoaming
        self.networkIdentitySource = networkIdentitySource
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Le PLMN explicite prime. Le couple structuré est un repli sûr car ses
    /// deux composantes ont déjà conservé leur largeur d'origine.
    var resolvedObservedPlmn: String? {
        if let observedPlmn = Self.normalizedPlmn(observedPlmn) { return observedPlmn }
        guard let mcc = Self.normalizedDigits(mcc, allowedLengths: [3]),
              let mnc = Self.normalizedDigits(mnc, allowedLengths: [2, 3]) else {
            return nil
        }
        return mcc + mnc
    }

    private static func normalizedPlmn(_ value: String?) -> String? {
        normalizedDigits(value, allowedLengths: [5, 6])
    }

    private static func normalizedDigits(_ value: String?, allowedLengths: Set<Int>) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              allowedLengths.contains(normalized.count),
              normalized.allSatisfy(\.isNumber) else {
            return nil
        }
        return normalized
    }
}

/// Identification d'une cellule observée → site ANFR/ISED
/// (`POST /api/android/map/identify/direct`). Le serveur croise les
/// identifiants radio + position et confirme l'antenne.
protocol IdentifyServicing: Sendable {
    func identify(_ request: IdentifyDirectRequest) async throws -> IdentifyResult

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

    func identify(_ request: IdentifyDirectRequest) async throws -> IdentifyResult {
        struct Body: Encodable {
            let siteId: String
            let enb: String?
            let gnb: String?
            let pci: Int?
            let cellId: String?
            let ci: String?
            let tech: String?
            let band: Int?
            let earfcn: Int?
            let sectorIndex: Int?
            let `operator`: String?
            let operatorKey: String?
            let marketCode: String?
            let rawOperatorName: String?
            let observedPlmn: String?
            let simPlmn: String?
            let isRoaming: Bool?
            let mobileCountryCode: String?
            let mobileNetworkCode: String?
            let networkIdentitySource: String?
            let userLat: Double?
            let userLng: Double?
        }
        return try await api.requestJSON(
            "/api/android/map/identify/direct",
            method: .post,
            body: Body(
                siteId: request.siteId,
                enb: request.enb,
                gnb: request.gnb,
                pci: request.pci,
                cellId: request.cellId,
                ci: request.ci,
                tech: request.tech,
                band: request.band,
                earfcn: request.earfcn,
                sectorIndex: request.sectorIndex,
                operator: request.operatorName,
                operatorKey: request.operatorKey,
                marketCode: request.marketCode,
                rawOperatorName: request.rawOperatorName,
                observedPlmn: request.resolvedObservedPlmn,
                simPlmn: request.simPlmn,
                isRoaming: request.isRoaming,
                mobileCountryCode: request.mcc,
                mobileNetworkCode: request.mnc,
                networkIdentitySource: request.networkIdentitySource,
                userLat: request.latitude,
                userLng: request.longitude
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
