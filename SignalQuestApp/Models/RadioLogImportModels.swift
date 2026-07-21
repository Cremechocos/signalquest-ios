import Foundation

/// Une ligne de log radio parsée depuis un export « eNB Analytics » (CSV `ExportV5`)
/// ou un fichier `.ntm` (format NetMonster). Miroir Swift du `NormalizedRadioLogSample`
/// Android, avec la MÊME logique d'identité cellule :
///  - LTE : `ci = eNB×256 + CID` (ECI, split 8 bits imposé par la 3GPP).
///  - NR  : `ci = NCI` (36 bits), `gnb = NCI >> 14` (convention identique au serveur).
struct ParsedRadioLogRow: Identifiable, Sendable, Codable {
    var id = UUID()
    let lineNumber: Int
    /// "LTE" ou "NR" (nil si indéterminable).
    let technology: String?
    /// Nom d'opérateur brut ("Orange", "SFR", "ZB"…) quand la source le fournit.
    let operatorName: String?
    let mcc: String?
    let mnc: String?
    let enb: String?
    let gnb: String?
    /// Identité cellule complète (ECI en LTE, NCI en NR).
    let ci: Int64?
    /// Cellule locale (bits bas), telle qu'affichée par la source.
    let cellId: String?
    let pci: Int?
    let tac: Int?
    let earfcn: Int?
    let band: Int?
    let rsrp: Int?
    let latitude: Double?
    let longitude: Double?

    var hasLocation: Bool { latitude != nil && longitude != nil }

    var hasRadioIdentity: Bool {
        !(enb ?? "").isEmpty || !(gnb ?? "").isEmpty || !(cellId ?? "").isEmpty || ci != nil || pci != nil
    }

    /// Est-ce une cellule 5G ? (utilisé pour router techno/nœud.)
    var isNr: Bool {
        (technology ?? "").uppercased().contains("NR") || (technology ?? "").uppercased().contains("5G") || gnb != nil
    }
}

// MARK: - Résolution opérateur → MCC/MNC + marché (miroir de OperatorNetworkFallback.kt)

/// Table minimale opérateur→(MCC, MNC) pour les exports CSV qui ne portent qu'un NOM
/// d'opérateur (pas de MCC/MNC). « ZB » (Zone Blanche) est intrinsèquement FR mais
/// sans opérateur unique → pas de MNC, marché FR. Le backend connaît le code « ZB ».
enum RadioLogOperatorResolver {
    static func mccMnc(forOperator name: String?) -> (mcc: String, mnc: String)? {
        switch normalize(name) {
        case "SFR": return ("208", "10")
        case "BOUYGUES", "BYTEL": return ("208", "20")
        case "ORANGE": return ("208", "1")
        case "FREE": return ("208", "15")
        default: return nil
        }
    }

    /// Marché du log : FR pour les opérateurs FR et pour « ZB » (Zone Blanche).
    static func marketCode(forOperator name: String?, mcc: String?) -> String? {
        if mcc == "208" { return "FR" }
        switch normalize(name) {
        case "SFR", "BOUYGUES", "BYTEL", "ORANGE", "FREE", "ZB", "ZONE BLANCHE": return "FR"
        default: return nil
        }
    }

    private static func normalize(_ value: String?) -> String {
        (value ?? "")
            .folding(options: .diacriticInsensitive, locale: .init(identifier: "fr_FR"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }
}

// MARK: - /api/android/map/identify/quick/batch (résolution en lot, lecture seule)

struct QuickIdentifyBatchItem: Encodable, Sendable {
    let id: String
    let `operator`: String?
    let market: String?
    let mcc: String?
    let mnc: String?
    let enb: String?
    let gnb: String?
    let pci: String?
    let cellId: String?
    let ci: String?
    let lat: Double?
    let lng: Double?
    let band: Int?
    let earfcn: Int?
    let tech: String?
}

struct QuickIdentifyBatchRequest: Encodable, Sendable {
    let items: [QuickIdentifyBatchItem]
}

struct QuickIdentifyBatchResponse: Decodable, Sendable {
    let ok: Bool
    let count: Int
    let results: [QuickIdentifyBatchResult]
}

struct QuickIdentifyBatchResult: Decodable, Sendable {
    let id: String?
    let ok: Bool
    /// Payload identique au GET `identify/quick` en cas de succès, `{error, code}` sinon.
    /// Tous les champs sont optionnels : un résultat d'erreur laisse `found`/`siteId` à nil.
    let result: QuickIdentifyResolution?
}

struct QuickIdentifyResolution: Decodable, Sendable {
    let found: Bool?
    let siteId: String?
    let canonicalSiteId: String?
    let market: String?
    let operatorMatched: Bool?
    let distanceMeters: Double?
}

// MARK: - État d'import (aperçu + résultat d'écriture)

/// Une ligne parsée + son verdict de résolution serveur (site rattachable ou non).
struct ResolvedRadioLogRow: Identifiable, Sendable {
    let id: UUID
    let row: ParsedRadioLogRow
    let siteId: String?
    let matched: Bool
    let distanceMeters: Double?
}

/// Statut d'identification d'une cellule pour l'affichage (miroir simplifié des badges
/// Android : Vérif. / Rattachable / Non identifié / Identifié).
enum RadioLogImportCellStatus: Sendable, Equatable {
    case pending
    case identifiable(siteId: String, distanceMeters: Double?)
    case notFound
    case identified

    var label: String {
        switch self {
        case .pending: return "Vérif."
        case .identifiable: return "Rattachable"
        case .notFound: return "Non identifié"
        case .identified: return "Identifié"
        }
    }
}

/// Résultat de l'écriture (identify/direct par ligne rattachée).
struct RadioLogImportOutcome: Sendable {
    var submitted: Int = 0
    var failed: Int = 0
}
