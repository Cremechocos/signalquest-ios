import SwiftUI

/// Agrégat d'une rafale de tests (moyennes + extrêmes).
struct SpeedtestBurstSummary {
    let count: Int
    let avgDownload: Double
    let maxDownload: Double
    let avgUpload: Double
    let minPing: Double
    /// Index où la rafale a été tronquée (arrière-plan / annulation), sinon nil.
    let truncatedAt: Int?

    init(results: [SpeedtestRunResult], truncatedAt: Int? = nil) {
        count = results.count
        let downloads = results.map { $0.downloadAverageMbps }
        avgDownload = downloads.isEmpty ? 0 : downloads.reduce(0, +) / Double(downloads.count)
        maxDownload = downloads.max() ?? 0
        let uploads = results.compactMap { $0.uploadAverageMbps }
        avgUpload = uploads.isEmpty ? 0 : uploads.reduce(0, +) / Double(uploads.count)
        let pings = results.compactMap { $0.pingMinMs ?? $0.pingMs }
        minPing = pings.min() ?? 0
        self.truncatedAt = truncatedAt
    }

    /// Init memberwise — alimenté par un accumulateur O(1) (mode continu illimité)
    /// pour ne pas retenir tous les résultats en mémoire pendant une longue session.
    init(count: Int, avgDownload: Double, maxDownload: Double, avgUpload: Double, minPing: Double, truncatedAt: Int?) {
        self.count = count
        self.avgDownload = avgDownload
        self.maxDownload = maxDownload
        self.avgUpload = avgUpload
        self.minPing = minPing
        self.truncatedAt = truncatedAt
    }
}
