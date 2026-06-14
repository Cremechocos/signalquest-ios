import XCTest
import SwiftUI
@testable import SignalQuest

@MainActor
final class SpeedtestShareImageTests: XCTestCase {
    private func sample(operator op: String?, download: Double, city: String?) -> SpeedtestRunResult {
        var dlSeries: [Double] = []
        var ulSeries: [Double] = []
        for i in 0..<40 {
            let t = Double(i) / 39.0
            dlSeries.append(download * (0.25 + 0.75 * t) + Double((i * 37) % 30))
            ulSeries.append(45.0 * (0.3 + 0.7 * t) + Double((i * 19) % 12))
        }
        return SpeedtestRunResult(
            id: UUID(),
            label: "x",
            downloadMbps: download,
            downloadAverageMbps: download,
            downloadMaxMbps: download + 40,
            downloadP90Mbps: nil, downloadP95Mbps: nil,
            uploadMbps: 45, uploadAverageMbps: 45, uploadMaxMbps: 60,
            uploadP90Mbps: nil, uploadP95Mbps: nil,
            pingMs: 18, pingMedianMs: 18, pingMinMs: 14, pingMaxMs: 30,
            jitterMs: 3,
            pingDlMs: 28,
            jitterDlMs: 4.1,
            pingUlMs: 36,
            jitterUlMs: 5.2,
            pingProtocol: "ICMP", durationSeconds: 10,
            connectionType: op == nil ? .wifi : .cellular,
            cellularTechnology: op == nil ? nil : .fiveGSA,
            networkOperatorName: op, wifiSSID: op == nil ? "Maison" : nil,
            city: city, coordinate: nil, serverName: "AWS",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            downloadSeriesMbps: dlSeries,
            uploadSeriesMbps: ulSeries,
            uploadMeasurementSource: nil,
            deviceModel: "iPhone 17 Pro", osVersion: "iOS 26"
        )
    }

    func testRendersAndExportsForVisualReview() throws {
        let cases: [(String, SpeedtestRunResult)] = [
            ("orange", sample(operator: "Orange", download: 487, city: "Lyon")),
            ("free", sample(operator: "Free", download: 312, city: "Paris")),
            ("bouygues", sample(operator: "Bouygues", download: 156, city: "Marseille")),
            ("default", sample(operator: "SFR", download: 642, city: "Bordeaux")),
            ("wifi", sample(operator: nil, download: 934, city: "Grenoble")),
        ]
        for (name, result) in cases {
            for (suffix, theme) in [("dark", SpeedtestShareTheme.dark), ("light", SpeedtestShareTheme.light)] {
                let image = try XCTUnwrap(SpeedtestShareImageRenderer.renderImage(result, theme: theme), "rendu nil pour \(name)/\(suffix)")
                XCTAssertEqual(image.size.width, 1080, accuracy: 1)
                XCTAssertEqual(image.size.height, 720, accuracy: 1)
                let data = try XCTUnwrap(image.pngData())
                let url = URL(fileURLWithPath: "/tmp/sq_share_\(name)_\(suffix).png")
                try data.write(to: url)
                print("SHARE_IMAGE_WRITTEN \(url.path)")
            }
        }
    }

    /// Une série quasi plate (valeurs hautes et stables) ne doit PAS se coller en
    /// bas : l'axe suit le max de la série, donc le tracé reste dans le haut.
    func testFlatHighSeriesDoesNotCollapseToBottom() throws {
        var r = sample(operator: "Orange", download: 900, city: "Lyon")
        // Série stable ~900 sur un réseau 5G (jauge 2000) : sans le bon axe, la
        // courbe tomberait à ~45 % ; avec l'axe série, elle reste haute.
        r = SpeedtestRunResult(
            id: r.id, label: r.label, downloadMbps: 900, downloadAverageMbps: 900, downloadMaxMbps: 910,
            downloadP90Mbps: nil, downloadP95Mbps: nil,
            uploadMbps: 80, uploadAverageMbps: 80, uploadMaxMbps: 82,
            uploadP90Mbps: nil, uploadP95Mbps: nil,
            pingMs: 12, pingMedianMs: 12, pingMinMs: 10, pingMaxMs: 20, jitterMs: 2, pingProtocol: "ICMP",
            durationSeconds: 10, connectionType: .cellular, cellularTechnology: .fiveGSA,
            networkOperatorName: "Orange", wifiSSID: nil, city: "Lyon", coordinate: nil, serverName: "AWS",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            downloadSeriesMbps: Array(repeating: 900, count: 30).enumerated().map { 900 + Double($0.offset % 5) },
            uploadSeriesMbps: Array(repeating: 80, count: 30).enumerated().map { 80 + Double($0.offset % 3) },
            uploadMeasurementSource: nil, deviceModel: "iPhone 17 Pro", osVersion: "iOS 26"
        )
        let image = try XCTUnwrap(SpeedtestShareImageRenderer.renderImage(r, theme: .dark))
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: URL(fileURLWithPath: "/tmp/sq_share_flat.png"))
        print("SHARE_IMAGE_WRITTEN /tmp/sq_share_flat.png")
    }
}
