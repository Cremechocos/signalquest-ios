import Foundation

/// Fusion d'au plus deux réponses portant des plages longitude disjointes.
/// Les compteurs globaux du snapshot lightweight ne sont jamais additionnés.
enum MapSnapshotMerging {
    static func unique<Value>(_ values: [[Value]], id: KeyPath<Value, String>) -> [Value] {
        var seen = Set<String>()
        return values.flatMap { $0 }.filter { seen.insert($0[keyPath: id]).inserted }
    }

    static func social(_ parts: [SocialMapSnapshot], lightweight: Bool) throws -> SocialMapSnapshot {
        guard let last = parts.last else { throw APIError.decoding("Missing social map segments") }
        if parts.count == 1 { return last }
        let photos = unique(parts.map(\.photos), id: \.id)
        let validations = unique(parts.map(\.validations), id: \.id)
        let sessions = unique(parts.map(\.sessions), id: \.id)
        let points = unique(parts.map(\.coveragePoints), id: \.id)
        let speedtests = unique(parts.map(\.speedtests), id: \.id)
        func sum(_ values: [Int]) throws -> Int {
            var total = 0
            for value in values {
                let (next, overflow) = total.addingReportingOverflow(value)
                guard !overflow, value >= 0 else { throw APIError.decoding("Invalid social map count") }
                total = next
            }
            return total
        }
        func optionalSum(_ values: [Int?]) throws -> Int? {
            guard values.allSatisfy({ $0 != nil }) else { return nil }
            return try sum(values.compactMap { $0 })
        }
        return try SocialMapSnapshot(
            timestamp: parts.compactMap(\.timestamp).min(),
            // Les amis ne sont pas bornés par le viewport côté serveur. La dernière
            // liste globale prévaut, y compris lorsqu'un partage vient d'être retiré.
            friends: last.friends, photos: photos, validations: validations,
            sessions: sessions, coveragePoints: points, speedtests: speedtests,
            photosCount: lightweight ? last.photosCount : photos.count,
            validationsCount: lightweight ? last.validationsCount : validations.count,
            sessionsCount: lightweight ? last.sessionsCount : sessions.count,
            coveragePointsCount: lightweight ? sum(parts.map(\.coveragePointsCount)) : points.count,
            speedtestsCount: lightweight ? sum(parts.map(\.speedtestsCount)) : speedtests.count,
            rawCoveragePointsCount: optionalSum(parts.map(\.rawCoveragePointsCount)),
            logicalCoveragePointsCount: lightweight ? optionalSum(parts.map(\.logicalCoveragePointsCount)) : points.count
        )
    }
}
