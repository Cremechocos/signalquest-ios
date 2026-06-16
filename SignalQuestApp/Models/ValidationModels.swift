import Foundation

/// Validations communautaires d'un site, groupées par type d'identifiant radio
/// (`GET /api/validations?siteId=`). Décodage tolérant.
struct SiteValidations: Decodable, Equatable {
    let enb: [ValidationEntry]
    let pci: [ValidationEntry]
    let cellid: [ValidationEntry]
    let gnb: [ValidationEntry]

    enum CodingKeys: String, CodingKey { case enb, pci, cellid, gnb }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enb = c.decodeLossyArray([ValidationEntry].self, forKey: .enb)
        pci = c.decodeLossyArray([ValidationEntry].self, forKey: .pci)
        cellid = c.decodeLossyArray([ValidationEntry].self, forKey: .cellid)
        gnb = c.decodeLossyArray([ValidationEntry].self, forKey: .gnb)
    }

    var isEmpty: Bool { enb.isEmpty && pci.isEmpty && cellid.isEmpty && gnb.isEmpty }
}

struct ValidationEntry: Decodable, Identifiable, Equatable {
    let value: String
    let validations: Int
    let rejections: Int

    var id: String { value }

    enum CodingKeys: String, CodingKey { case value, validations, rejections, votes, count }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = c.decodeFlexibleString(forKey: .value) ?? "?"
        validations = (try? c.decodeIfPresent(Int.self, forKey: .validations))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .votes))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .count))
            ?? 0
        rejections = (try? c.decodeIfPresent(Int.self, forKey: .rejections)) ?? 0
    }
}

/// Résultat d'une identification cellule→site (`POST /api/android/map/identify/direct`).
struct IdentifyResult: Decodable, Equatable {
    let success: Bool
    let siteId: String?
    let message: String?

    enum CodingKeys: String, CodingKey { case success, ok, siteId, matchedSiteId, message, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = (try? c.decodeIfPresent(Bool.self, forKey: .success))
            ?? (try? c.decodeIfPresent(Bool.self, forKey: .ok))
            ?? false
        siteId = c.decodeFlexibleString(forKey: .siteId) ?? c.decodeFlexibleString(forKey: .matchedSiteId)
        message = c.decodeFlexibleString(forKey: .message) ?? c.decodeFlexibleString(forKey: .error)
    }
}
