import Foundation

/// SECTOR-ORIGIN r1 (contrat `contracts/identify/sector-status-v1.json`) : d'où vient le secteur
/// d'une ligne pci/cellid. Servi sur chaque ligne de `identify/mine?v=2` et sur les entrées de la
/// fiche. `nil` côté app : secteur vide, ou serveur plus ancien qui ne le sert pas.
enum SectorStatus: Equatable, Sendable {
    case verifiedOnSite
    case confirmed
    case manualEdit
    case operatorRule
    case azimuth
    case client
    case legacyMatchesRule
    case legacyDiffersRule
    case legacyUnknown
    /// Liste fermée mais extensible : une valeur inconnue s'affiche « Origine inconnue ».
    case unrecognized

    init?(raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw {
        case "verified_on_site": self = .verifiedOnSite
        case "confirmed": self = .confirmed
        case "manual_edit": self = .manualEdit
        case "operator_rule": self = .operatorRule
        case "azimuth": self = .azimuth
        case "client": self = .client
        case "legacy_matches_rule": self = .legacyMatchesRule
        case "legacy_differs_rule": self = .legacyDiffersRule
        case "legacy_unknown": self = .legacyUnknown
        default: self = .unrecognized
        }
    }

}

/// Source de la preuve de présence trouvée par le serveur au moment de la confirmation.
enum SectorConfirmProof: String, Equatable, Sendable {
    case radioLog = "radio_log"
    case coverage
    case speedtest
}

/// Réponse 200 de `POST /api/android/map/identify/confirm-sector`.
struct ConfirmSectorResult: Decodable, Equatable, Sendable {
    let confirmed: Int
    /// Lignes CI du PCI qui portent un autre secteur : laissées telles quelles (r1.1).
    let skipped: Int
    let scope: String?
    let sectorStatus: SectorStatus?
    /// `nil` : confirmé sans preuve, ou preuve d'un genre inconnu.
    let proof: SectorConfirmProof?

    enum CodingKeys: String, CodingKey { case confirmed, skipped, scope, sectorStatus, proof }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        confirmed = (try? c.decodeIfPresent(Int.self, forKey: .confirmed)) ?? 0
        skipped = (try? c.decodeIfPresent(Int.self, forKey: .skipped)) ?? 0
        scope = c.decodeFlexibleString(forKey: .scope)
        sectorStatus = SectorStatus(raw: c.decodeFlexibleString(forKey: .sectorStatus))
        proof = c.decodeFlexibleString(forKey: .proof).flatMap(SectorConfirmProof.init(rawValue:))
    }

    init(confirmed: Int, skipped: Int = 0, scope: String? = nil, sectorStatus: SectorStatus?, proof: SectorConfirmProof?) {
        self.confirmed = confirmed
        self.skipped = skipped
        self.scope = scope
        self.sectorStatus = sectorStatus
        self.proof = proof
    }
}

/// Comptes servis par la fiche pour un même secteur : membres distincts, sans identité.
struct SectorConfirmCounts: Equatable, Sendable {
    let members: Int
    let verified: Int

    /// Les comptes d'une ligne du membre, pris sur les entrées de la fiche qui portent la même
    /// valeur (PCI ou cellule), le même secteur et le même nœud. Une même personne peut figurer
    /// sous deux bandes : on garde le plus grand compte, jamais la somme.
    static func lookup(
        in identifiers: AntennaCellIdentifiers,
        pci: Int?, cellId: String?, enb: String?, gnb: String?, sectors: [Int]
    ) -> SectorConfirmCounts? {
        guard sectors.count == 1, let sector = sectors.first else { return nil }
        func sameNode(_ entryEnb: String?, _ entryGnb: String?) -> Bool {
            if let enb, let entryEnb { return enb == entryEnb }
            if let gnb, let entryGnb { return gnb == entryGnb }
            return true
        }
        var best: SectorConfirmCounts?
        func keep(_ members: Int?, _ verified: Int?) {
            guard let members, members > 0 else { return }
            let counts = SectorConfirmCounts(members: members, verified: min(verified ?? 0, members))
            if best.map({ counts.members > $0.members }) ?? true { best = counts }
        }
        if let cellId = cellId?.trimmingCharacters(in: .whitespaces), !cellId.isEmpty {
            for entry in identifiers.cellId where entry.value == cellId && entry.sector == sector
                && sameNode(entry.enb, entry.gnb) {
                keep(entry.sectorConfirmations, entry.sectorVerifiedConfirmations)
            }
        } else if let pci {
            for entry in identifiers.pci where entry.value == String(pci) && entry.sector == sector
                && sameNode(entry.enb, entry.gnb) {
                keep(entry.sectorConfirmations, entry.sectorVerifiedConfirmations)
            }
        }
        return best
    }
}
