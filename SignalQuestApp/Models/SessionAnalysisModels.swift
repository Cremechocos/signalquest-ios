import Foundation

/// Analyse d'un trajet calculée et figée par le serveur (contrat
/// DRIVE-ANALYSIS-1 v1, figé le 10/11) : `GET /api/coverage/sessions/analysis`.
///
/// Les trois apps affichent la même chose : le serveur calcule, l'app compose
/// la phrase à partir des codes, dans sa langue. Un trajet double SIM donne une
/// entrée par série dans `operators`, et il n'y a pas de note globale : une
/// ligne par opérateur, sans moyenne entre eux.
///
/// Seuls les champs affichés sont décodés ; le reste du contrat est ignoré.
/// Les codes restent des chaînes : une valeur inconnue n'empêche pas de lire
/// les autres.
struct SessionAnalysisResponse: Decodable, Sendable {
    let analysis: SessionAnalysis?
}

struct SessionAnalysis: Decodable, Equatable, Sendable {
    let contractVersion: Int?
    let formulaVersion: Int?
    /// `ready`, `live` (trajet en cours) ou `unavailable` (`no_points`, `too_short`).
    let status: String?
    let reason: String?
    let noRecord: NoRecord?
    let operators: [Series]

    struct NoRecord: Decodable, Equatable, Sendable {
        let totalSec: Int?
        let fractionOfDuration: Double?
        let count: Int?
        let km: Double?
        /// `client` (trous envoyés par le téléphone) ou `server_estimate`.
        let source: String?
    }

    /// Une série SIM du trajet. `seriesKey` est opaque et n'est jamais affiché.
    struct Series: Decodable, Equatable, Sendable, Identifiable {
        /// Clé de liste seulement (rendue unique par l'analyse), jamais affichée.
        fileprivate(set) var id: String
        let operatorKey: String?
        let marketCode: String?
        /// 1, 2… seulement quand deux séries ont le même opérateur.
        let operatorRank: Int?
        let pointCount: Int?
        let quality: Quality?
        let verdict: Verdict?
        let spotsTotal: Int?

        struct Quality: Decodable, Equatable, Sendable {
            let score: Int?
            let level: String?
            /// Part du trajet (en km) où cette série a des relevés.
            let recordedFraction: Double?
        }

        struct Verdict: Decodable, Equatable, Sendable {
            let level: String?
            let holes: Int?
            /// `OK`, `WITH_HOLES` ou `UNRELIABLE`.
            let headlineCode: String?
        }

        private enum CodingKeys: String, CodingKey {
            case seriesKey, operatorKey, marketCode, operatorRank, pointCount, quality, verdict, spotsTotal
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            operatorKey = try? c.decodeIfPresent(String.self, forKey: .operatorKey)
            marketCode = try? c.decodeIfPresent(String.self, forKey: .marketCode)
            operatorRank = try? c.decodeIfPresent(Int.self, forKey: .operatorRank)
            pointCount = try? c.decodeIfPresent(Int.self, forKey: .pointCount)
            quality = try? c.decodeIfPresent(Quality.self, forKey: .quality)
            verdict = try? c.decodeIfPresent(Verdict.self, forKey: .verdict)
            spotsTotal = try? c.decodeIfPresent(Int.self, forKey: .spotsTotal)
            let seriesKey = try? c.decodeIfPresent(String.self, forKey: .seriesKey)
            id = seriesKey ?? [operatorKey ?? "unknown", operatorRank.map(String.init) ?? ""].joined(separator: "#")
        }

        /// Analyse calculée mais sur trop peu de mesures : à dire avec prudence.
        var isUnreliable: Bool { verdict?.headlineCode == "UNRELIABLE" }
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion, formulaVersion, status, reason, noRecord, operators
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try? c.decodeIfPresent(Int.self, forKey: .contractVersion)
        formulaVersion = try? c.decodeIfPresent(Int.self, forKey: .formulaVersion)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        noRecord = try? c.decodeIfPresent(NoRecord.self, forKey: .noRecord)
        // Une série illisible ne fait pas tomber les autres.
        let raw = (try? c.decodeIfPresent([FailableSeries].self, forKey: .operators)) ?? []
        var seen = Set<String>()
        operators = raw.compactMap(\.value).enumerated().map { position, series in
            var series = series
            if !seen.insert(series.id).inserted { series.id += "#\(position)" }
            return series
        }
    }

    private struct FailableSeries: Decodable {
        let value: Series?
        init(from decoder: Decoder) throws { value = try? Series(from: decoder) }
    }

    /// À afficher : analyse prête et au moins une série notée. `live` et
    /// `unavailable` (trajet iOS sans points, trop court) cachent le bloc.
    var isDisplayable: Bool {
        status == "ready" && operators.contains { $0.verdict != nil || $0.quality != nil }
    }
}
