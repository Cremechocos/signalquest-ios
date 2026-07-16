import XCTest
import SwiftUI
@testable import SignalQuest

@MainActor
final class SpeedtestShareImageTests: XCTestCase {
    private func sample(
        operator op: String?,
        download: Double,
        city: String?,
        server: String? = "Paris BBR (Bouygues)",
        hasUpload: Bool = true,
        hasLoadedPings: Bool = true,
        dlSeries: [Double]? = nil,
        ulSeries: [Double]? = nil,
        generateSeries: Bool = true,
        dlGraceCount: Int? = nil,
        ulGraceCount: Int? = nil
    ) -> SpeedtestRunResult {
        var generatedDl: [Double] = []
        var generatedUl: [Double] = []
        for i in 0..<40 {
            let t = Double(i) / 39.0
            generatedDl.append(download * (0.25 + 0.75 * t) + Double((i * 37) % 30))
            generatedUl.append(45.0 * (0.3 + 0.7 * t) + Double((i * 19) % 12))
        }
        let finalDl = dlSeries ?? (generateSeries ? generatedDl : [])
        let finalUl = ulSeries ?? (generateSeries ? generatedUl : [])
        return SpeedtestRunResult(
            id: UUID(),
            label: "x",
            downloadMbps: download,
            downloadAverageMbps: download,
            downloadMaxMbps: download + 40,
            downloadP90Mbps: nil, downloadP95Mbps: nil,
            uploadMbps: hasUpload ? 45 : nil,
            uploadAverageMbps: hasUpload ? 45 : nil,
            uploadMaxMbps: hasUpload ? 60 : nil,
            uploadP90Mbps: nil, uploadP95Mbps: nil,
            pingMs: 18, pingMedianMs: 18, pingMinMs: 14, pingMaxMs: 30,
            jitterMs: 3,
            pingDlMs: hasLoadedPings ? 28 : nil,
            jitterDlMs: hasLoadedPings ? 4.1 : nil,
            pingUlMs: hasLoadedPings ? 36 : nil,
            jitterUlMs: hasLoadedPings ? 5.2 : nil,
            pingProtocol: "TCP", durationSeconds: 10,
            connectionType: op == nil ? .wifi : .cellular,
            cellularTechnology: op == nil ? nil : .fiveGSA,
            networkOperatorName: op, wifiSSID: op == nil ? "Maison" : nil,
            city: city, coordinate: nil, serverName: server,
            downloadServerName: server,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            downloadSeriesMbps: finalDl.isEmpty ? nil : finalDl,
            uploadSeriesMbps: hasUpload ? (finalUl.isEmpty ? nil : finalUl) : nil,
            downloadGraceWindowCount: dlGraceCount,
            uploadGraceWindowCount: ulGraceCount,
            uploadMeasurementSource: nil,
            deviceModel: "iPhone 17 Pro", osVersion: "iOS 26"
        )
    }

    /// Série avec montée en charge : quelques fenêtres de grâce (rampe) puis
    /// le régime établi — le renderer doit tracer la grâce en pointillé.
    private func graceSample() -> SpeedtestRunResult {
        let dlGrace: [Double] = [42, 168, 331, 442]
        var dlUseful: [Double] = []
        var ulUseful: [Double] = []
        for i in 0..<40 {
            let t: Double = Double(i) / 39.0
            let dlNoise: Double = Double((i * 37) % 30)
            let ulNoise: Double = Double((i * 19) % 8)
            dlUseful.append(487.0 * (0.88 + 0.12 * t) + dlNoise)
            ulUseful.append(45.0 * (0.85 + 0.15 * t) + ulNoise)
        }
        let ulGrace: [Double] = [6, 18, 31, 40]
        return sample(
            operator: "Orange",
            download: 487,
            city: "Grenoble",
            dlSeries: dlGrace + dlUseful,
            ulSeries: ulGrace + ulUseful,
            dlGraceCount: dlGrace.count,
            ulGraceCount: ulGrace.count
        )
    }

    func testRendersAndExportsForVisualReview() throws {
        var cases: [(String, SpeedtestRunResult)] = []
        cases.append(("orange", sample(operator: "Orange", download: 487, city: "Lyon")))
        cases.append(("free", sample(operator: "Free", download: 312, city: "Paris")))
        cases.append(("bouygues", sample(operator: "Bouygues", download: 156, city: "Marseille")))
        cases.append(("default", sample(operator: "SFR", download: 642, city: "Bordeaux")))
        cases.append(("wifi", sample(operator: nil, download: 934, city: "Grenoble")))
        cases.append(("longnames", sample(operator: "Bouygues Telecom", download: 231, city: "Saint-Martin-de-Belleville", server: "Marseille CUBIC (Bouygues)")))
        cases.append(("noupload", sample(operator: "Orange", download: 388, city: "Nantes", hasUpload: false)))
        cases.append(("noloadedping", sample(operator: "SFR", download: 214, city: "Lille", hasLoadedPings: false)))
        cases.append(("nocity", sample(operator: "Free", download: 175, city: nil)))
        cases.append(("gigabit", sample(operator: "Orange", download: 1_420, city: "Paris")))
        cases.append(("sparse", sample(operator: "Bouygues", download: 230, city: "Rennes", dlSeries: [], ulSeries: [38], generateSeries: false)))
        cases.append(("grace", graceSample()))
        cases.append(("cloudflare", sample(operator: "Orange", download: 512, city: "Montréal", server: "Cloudflare · Montréal (YUL)")))
        let expected = SpeedtestShareImageRenderer.cardSize
        for (name, result) in cases {
            for (suffix, theme) in [("dark", SpeedtestShareTheme.dark), ("light", SpeedtestShareTheme.light)] {
                let image = try XCTUnwrap(SpeedtestShareImageRenderer.renderImage(result, theme: theme), "rendu nil pour \(name)/\(suffix)")
                XCTAssertEqual(image.size.width, expected.width, accuracy: 1)
                XCTAssertEqual(image.size.height, expected.height, accuracy: 1)
                let data = try XCTUnwrap(image.pngData())
                XCTAssertLessThan(data.count, 8_000_000, "PNG de partage trop lourd (\(name)/\(suffix))")
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
            pingMs: 12, pingMedianMs: 12, pingMinMs: 10, pingMaxMs: 20, jitterMs: 2, pingProtocol: "TCP",
            durationSeconds: 10, connectionType: .cellular, cellularTechnology: .fiveGSA,
            networkOperatorName: "Orange", wifiSSID: nil, city: "Lyon", coordinate: nil,
            serverName: "Paris Scaleway", downloadServerName: "Paris Scaleway",
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
