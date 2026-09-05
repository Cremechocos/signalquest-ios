import SwiftUI

/// Accumulateur O(1) pour une session de rafale continue : agrège les moyennes /
/// max / min au fil des tests sans conserver chaque `SpeedtestRunResult`.
/// Internal (pas `private`) : partagé avec le mode Drive Test.
struct ContinuousSessionAccumulator {
    private(set) var count = 0
    var sumDownload = 0.0
    var maxDownload = 0.0
    var sumUpload = 0.0
    var uploadCount = 0
    var minPing = Double.greatestFiniteMagnitude

    mutating func add(_ result: SpeedtestRunResult) {
        count += 1
        sumDownload += result.downloadAverageMbps
        maxDownload = max(maxDownload, result.downloadAverageMbps)
        if let upload = result.uploadAverageMbps {
            sumUpload += upload
            uploadCount += 1
        }
        if let ping = result.primaryPingMs {
            minPing = min(minPing, ping)
        }
    }

    func summary(truncatedAt: Int?) -> SpeedtestBurstSummary {
        SpeedtestBurstSummary(
            count: count,
            avgDownload: count == 0 ? 0 : sumDownload / Double(count),
            maxDownload: maxDownload,
            avgUpload: uploadCount == 0 ? 0 : sumUpload / Double(uploadCount),
            minPing: minPing == .greatestFiniteMagnitude ? 0 : minPing,
            truncatedAt: truncatedAt
        )
    }
}
