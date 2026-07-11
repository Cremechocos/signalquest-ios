import XCTest
import CoreTelephony
import SwiftUI
@testable import SignalQuest

final class SpeedtestTests: XCTestCase {
    func testMetricMath() throws {
        XCTAssertEqual(SpeedMetricCalculator.mbps(bytes: 1_000_000, seconds: 1), 8, accuracy: 0.001)
        XCTAssertEqual(SpeedMetricCalculator.average([10, 20, 30]), 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SpeedMetricCalculator.median([10, 30, 20])), 20)
        XCTAssertEqual(try XCTUnwrap(SpeedMetricCalculator.jitter([10, 14, 11])), 3.5, accuracy: 0.001)
    }

    func testJitterRequiresAtLeastTwoSamples() throws {
        XCTAssertNil(SpeedMetricCalculator.jitter([]))
        XCTAssertNil(SpeedMetricCalculator.jitter([18]))
        XCTAssertEqual(try XCTUnwrap(SpeedMetricCalculator.jitter([10, 14])), 4, accuracy: 0.001)
    }

    func testPingBudgetNeverExceedsEightAttempts() {
        let measuredTarget = speedtestPingMeasuredSampleTarget(attemptBudget: 8, warmupCount: 1)
        XCTAssertEqual(measuredTarget, 7)
        XCTAssertLessThanOrEqual(measuredTarget + 1, 8)
        XCTAssertEqual(speedtestPingMeasuredSampleTarget(attemptBudget: 1, warmupCount: 1), 1)
        XCTAssertEqual(speedtestPingMeasuredSampleTarget(attemptBudget: 0, warmupCount: 1), 0)
    }

    func testMeasuredTransferRequiresUsefulBytes() {
        XCTAssertNil(measuredTransferMbps(effectiveBytes: 0, durationMs: 1_000))
        XCTAssertNil(measuredTransferMbps(effectiveBytes: 1_024, durationMs: 0))
        XCTAssertEqual(try XCTUnwrap(measuredTransferMbps(effectiveBytes: 1_000_000, durationMs: 1_000)), 8, accuracy: 0.001)
    }

    func testUploadRequestSizeUsesServerLimitWithoutTinyOrHugePayloads() {
        XCTAssertEqual(boundedUploadRequestBytes(32 * 1_024 * 1_024), 32 * 1_024 * 1_024)
        XCTAssertEqual(boundedUploadRequestBytes(64 * 1_024 * 1_024), 32 * 1_024 * 1_024)
        XCTAssertEqual(boundedUploadRequestBytes(64 * 1_024), 256 * 1_024)
    }

    func testUploadConfirmedBytesNeverExceedClientOrServerCounts() {
        XCTAssertEqual(computeConfirmedUploadBytes(clientWrittenBytes: 4_000, serverConfirmedBytes: 3_000), 3_000)
        XCTAssertEqual(computeConfirmedUploadBytes(clientWrittenBytes: 4_000, serverConfirmedBytes: 5_000), 4_000)
        XCTAssertEqual(computeConfirmedUploadBytes(clientWrittenBytes: 4_000, serverConfirmedBytes: nil), 4_000)
        XCTAssertEqual(computeConfirmedUploadBytes(clientWrittenBytes: 4_000, serverConfirmedBytes: -1), 0)
    }

    func testCloudFrontGuardRejectsProtectedSessionDownloadEndpoint() throws {
        let protected = try XCTUnwrap(URL(string: "https://speedtest.signalquest.fr/download"))
        let session = try XCTUnwrap(URL(string: "https://speedtest.signalquest.fr/download"))
        let base = try XCTUnwrap(URL(string: "https://speedtest.signalquest.fr"))
        let cloudFront = try XCTUnwrap(URL(string: "https://d2d31ihf1e95ah.cloudfront.net/1000MB.bin"))

        XCTAssertTrue(isProtectedSpeedtestDownloadURL(protected, protectedDownloadURL: protected, sessionDownloadURL: session, speedtestBaseURL: base))
        XCTAssertFalse(isProtectedSpeedtestDownloadURL(cloudFront, protectedDownloadURL: protected, sessionDownloadURL: session, speedtestBaseURL: base))
    }

    func testUploadServerMeasurementRequiresCompleteNonZeroServerData() throws {
        let usable = try XCTUnwrap(UploadServerMeasurement(data: Data("""
        {
          "serverBytesReceived": 32000000,
          "serverDurationMs": 10000,
          "serverAvgMbps": 25.6,
          "serverMeasuredWindows": 8,
          "serverMeasurementComplete": true
        }
        """.utf8)))
        XCTAssertTrue(usable.isUsable(expectedUsefulDurationMs: 10_000))

        let incomplete = try XCTUnwrap(UploadServerMeasurement(data: Data("""
        {
          "serverBytesReceived": 32000000,
          "serverDurationMs": 10000,
          "serverAvgMbps": 25.6,
          "serverMeasuredWindows": 8,
          "serverMeasurementComplete": false
        }
        """.utf8)))
        XCTAssertTrue(incomplete.isUsable(expectedUsefulDurationMs: 10_000)) // Now allowed and usable!

        let zeroBytes = try XCTUnwrap(UploadServerMeasurement(data: Data("""
        {
          "serverBytesReceived": 0,
          "serverDurationMs": 10000,
          "serverAvgMbps": 25.6,
          "serverMeasuredWindows": 8,
          "serverMeasurementComplete": true
        }
        """.utf8)))
        XCTAssertFalse(zeroBytes.isUsable(expectedUsefulDurationMs: 10_000))

        // Run tronqué côté serveur : fenêtre non représentative → la mesure
        // serveur ne doit PAS être autoritaire (repli client confirmé).
        let truncated = try XCTUnwrap(UploadServerMeasurement(data: Data("""
        {
          "serverBytesReceived": 32000000,
          "serverDurationMs": 10000,
          "serverAvgMbps": 25.6,
          "serverMeasuredWindows": 8,
          "serverRunTruncated": true
        }
        """.utf8)))
        XCTAssertFalse(truncated.isUsable(expectedUsefulDurationMs: 10_000))
    }

    func testUploadAverageIsServerAuthoritativeWhenUsable() throws {
        // Mesure serveur utilisable → serverAvgMbps DIRECT (octets et durée de
        // la MÊME fenêtre serveur), pas le mix min(client, serveur)/durée
        // serveur qui mélangeait deux fenêtres et sous-estimait.
        let usable = try XCTUnwrap(UploadServerMeasurement(data: Data("""
        {"serverBytesReceived": 320000000, "serverDurationMs": 10000, "serverAvgMbps": 256.0, "serverMeasuredWindows": 10}
        """.utf8)))
        XCTAssertEqual(
            resolvedUploadAverageMbps(serverMeasurement: usable, expectedUsefulDurationMs: 10_000, clientAverageMbps: 180),
            256, accuracy: 0.001
        )

        // Pas de réponse serveur → repli client (borné par les octets confirmés
        // en amont : l'anti-triche reste intact).
        XCTAssertEqual(
            resolvedUploadAverageMbps(serverMeasurement: nil, expectedUsefulDurationMs: 10_000, clientAverageMbps: 42),
            42, accuracy: 0.001
        )

        // Run tronqué → la moyenne serveur n'est pas autoritaire.
        let truncated = try XCTUnwrap(UploadServerMeasurement(data: Data("""
        {"serverBytesReceived": 320000000, "serverDurationMs": 10000, "serverAvgMbps": 256.0, "serverMeasuredWindows": 10, "serverRunTruncated": true}
        """.utf8)))
        XCTAssertEqual(
            resolvedUploadAverageMbps(serverMeasurement: truncated, expectedUsefulDurationMs: 10_000, clientAverageMbps: 42),
            42, accuracy: 0.001
        )
    }

    func testUploadFinalizeBodyCarriesRunIdAndEffectiveWarmup() throws {
        // Le finalize doit transmettre le warm-up réellement appliqué (grace
        // adaptative), pas seulement l'uploadRunId.
        let body = speedtestUploadFinalizeBody(runId: "run-42", warmupMs: 3_500)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["uploadRunId"] as? String, "run-42")
        XCTAssertEqual(json["warmupMs"] as? Int, 3_500)
    }

    func testAdaptiveGraceExtendsOnFastOrRisingLinks() {
        // > 200 Mbps : 2 s de slow-start pèsent trop lourd → extension.
        XCTAssertTrue(speedtestShouldExtendGrace(recentMbps: 320, earlierMbps: 315))
        // Débit encore nettement croissant en fin de warm-up → extension.
        XCTAssertTrue(speedtestShouldExtendGrace(recentMbps: 90, earlierMbps: 60))
        // Débit stabilisé sous le seuil → warm-up de base suffisant.
        XCTAssertFalse(speedtestShouldExtendGrace(recentMbps: 80, earlierMbps: 78))
        // Pas de débit mesurable ou pas d'historique → pas d'extension.
        XCTAssertFalse(speedtestShouldExtendGrace(recentMbps: 0, earlierMbps: nil))
        XCTAssertFalse(speedtestShouldExtendGrace(recentMbps: 150, earlierMbps: nil))
    }

    func testAdaptivePhaseWindowExtendsOnceBeforeBoundaryAndShiftsDeadline() {
        let deadline = Date(timeIntervalSince1970: 1_000)
        let window = SpeedtestAdaptivePhaseWindow(graceMs: 2_000, deadline: deadline)

        // Trop tard (frontière de grace déjà passée) : refusé — les octets
        // seraient déjà marqués « utiles ».
        XCTAssertFalse(window.extendGrace(to: 3_500, ifNotPastMs: 2_100))
        XCTAssertEqual(window.graceMs, 2_000)

        // Avant la frontière : accepté, l'échéance glisse du même délai pour
        // préserver la durée utile de mesure.
        XCTAssertTrue(window.extendGrace(to: 3_500, ifNotPastMs: 1_850))
        XCTAssertEqual(window.graceMs, 3_500)
        XCTAssertTrue(window.wasExtended)
        XCTAssertEqual(window.deadline.timeIntervalSince(deadline), 1.5, accuracy: 0.001)

        // Une seule extension par phase.
        XCTAssertFalse(window.extendGrace(to: 4_000, ifNotPastMs: 1_900))
        XCTAssertEqual(window.graceMs, 3_500)
    }

    func testLiveSamplerTracksInstantaneousRateOverSlidingWindow() {
        // smoothing 1.0 → valeur brute de la fenêtre glissante (sans EMA), pour
        // vérifier la fenêtre elle-même.
        let sampler = SpeedtestLiveSampler(windowMs: 1_000, smoothing: 1.0)
        var total = 0
        var value = 0.0
        // 12,5 Mo/s (= 100 Mbps) pendant 3 s, tick toutes les 150 ms.
        for tick in 1...20 {
            total += 1_875_000
            value = sampler.observe(totalBytes: total, elapsedMs: Double(tick) * 150)
        }
        XCTAssertEqual(value, 100, accuracy: 5)
        XCTAssertEqual(sampler.lastInstantMbps, 100, accuracy: 5)

        // Le débit DOUBLE : l'aiguille doit suivre le débit INSTANTANÉ (~200),
        // pas la moyenne cumulée (~150 après autant de temps à 100 puis 200).
        for tick in 21...40 {
            total += 3_750_000
            value = sampler.observe(totalBytes: total, elapsedMs: Double(tick) * 150)
        }
        XCTAssertEqual(value, 200, accuracy: 10)
    }

    func testUploadScalingRatioCorrection() {
        // Supposons que le client a écrit 32 Mo en local (buffer bloat),
        // mais que le serveur n'a reçu et confirmé que 2 Mo.
        let clientWrittenBytes = 32_000_000
        let serverConfirmedBytes = 2_000_000
        
        let clientWrittenBytesMax = max(1, clientWrittenBytes)
        let scaleRatio = min(1.0, Double(serverConfirmedBytes) / Double(clientWrittenBytesMax))
        
        // La vitesse moyenne du client calculée sur 10s serait de 25.6 Mbps
        // Mais recalibrée à 2 Mo confirmés, elle doit être de 1.6 Mbps
        let durationMs: Double = 10_000
        let clientAverageWithBloat = (Double(clientWrittenBytes) * 8.0 / 1_000_000.0) / (durationMs / 1_000.0) // 25.6
        let correctedAverage = clientAverageWithBloat * scaleRatio // 1.6
        
        XCTAssertEqual(scaleRatio, 0.0625, accuracy: 0.001)
        XCTAssertEqual(correctedAverage, 1.6, accuracy: 0.001)
        
        // Les pics de débit et la série graphique doivent aussi être mis à l'échelle
        let statsPeak = 28.0 // pic mesuré par le client (tamponné)
        let statsSeries = [12.0, 24.0, 28.0]
        
        let scaledPeak = statsPeak * scaleRatio
        let scaledSeries = statsSeries.map { $0 * scaleRatio }
        
        XCTAssertEqual(scaledPeak, 1.75, accuracy: 0.001)
        XCTAssertEqual(scaledSeries.count, 3)
        XCTAssertEqual(scaledSeries[0], 0.75, accuracy: 0.001)
        XCTAssertEqual(scaledSeries[1], 1.5, accuracy: 0.001)
        XCTAssertEqual(scaledSeries[2], 1.75, accuracy: 0.001)
    }

    func testNetworkPathMapping() {
        let cellular = NetworkPathStatus.map(NetworkPathSnapshot(usesWiFi: false, usesCellular: true, usesWired: false, isExpensive: true, isConstrained: false))
        XCTAssertEqual(cellular.connection, .cellular)
        XCTAssertTrue(cellular.isExpensive)
        XCTAssertEqual(NetworkPathStatus.map(NetworkPathSnapshot(usesWiFi: false, usesCellular: true, usesWired: false, isExpensive: true, isConstrained: false), cellularTechnology: .fiveGNSA).displayName, "5G NSA")
        XCTAssertEqual(NetworkPathStatus.map(NetworkPathSnapshot(usesWiFi: false, usesCellular: true, usesWired: false, isExpensive: true, isConstrained: false), cellularTechnology: .fiveGNSA, operatorName: "SFR").shareDisplayName, "SFR 5G NSA")
        XCTAssertEqual(NetworkPathStatus.map(NetworkPathSnapshot(usesWiFi: true, usesCellular: false, usesWired: false, isExpensive: false, isConstrained: false), cellularTechnology: .fiveGNSA, operatorName: "SFR").shareDisplayName, "WiFi")
        XCTAssertEqual(CellularRadioTechnology.map(CTRadioAccessTechnologyEdge), .twoG)
        XCTAssertEqual(CellularRadioTechnology.map(CTRadioAccessTechnologyWCDMA), .threeG)
        XCTAssertEqual(CellularRadioTechnology.map(CTRadioAccessTechnologyLTE), .fourG)
        XCTAssertEqual(CellularRadioTechnology.map(CTRadioAccessTechnologyNRNSA), .fiveGNSA)
        XCTAssertEqual(CellularRadioTechnology.map(CTRadioAccessTechnologyNR), .fiveGSA)
    }

    func testNetworkShareDisplayNameFallsBackToTechnology() {
        // Opérateur connu → « Orange 5G NSA ».
        let withOperator = makeSpeedtestResult(downloadSeries: nil, uploadSeries: nil, connectionType: .cellular, cellularTechnology: .fiveGNSA, networkOperatorName: "Orange")
        XCTAssertEqual(withOperator.networkShareDisplayName, "Orange 5G NSA")

        // Opérateur indisponible (API iOS muette) → techno seule, JAMAIS le
        // parasite « Cellulaire 5G NSA » de l'ancien fallback.
        let noOperator = makeSpeedtestResult(downloadSeries: nil, uploadSeries: nil, connectionType: .cellular, cellularTechnology: .fiveGNSA, networkOperatorName: nil)
        XCTAssertEqual(noOperator.networkShareDisplayName, "5G NSA")
        XCTAssertFalse(noOperator.networkShareDisplayName.contains("Cellulaire"))

        // Ni opérateur ni techno → « Cellulaire » seul.
        let bare = makeSpeedtestResult(downloadSeries: nil, uploadSeries: nil, connectionType: .cellular, cellularTechnology: nil, networkOperatorName: nil)
        XCTAssertEqual(bare.networkShareDisplayName, "Cellulaire")

        // WiFi : affiche le FAI (résolu par IP), pas le SSID (plus parlant + évite
        // d'exposer le nom du réseau privé).
        let wifi = makeSpeedtestResult(downloadSeries: nil, uploadSeries: nil, connectionType: .wifi, networkOperatorName: "Orange", wifiSSID: "Livebox-1234")
        XCTAssertEqual(wifi.networkShareDisplayName, "Orange • WiFi")
        XCTAssertFalse(wifi.networkShareDisplayName.contains("Livebox"))

        // WiFi sans FAI résolu → « WiFi » seul (pas de SSID exposé).
        let wifiNoFai = makeSpeedtestResult(downloadSeries: nil, uploadSeries: nil, connectionType: .wifi, networkOperatorName: nil, wifiSSID: "Livebox-1234")
        XCTAssertEqual(wifiNoFai.networkShareDisplayName, "WiFi")
    }

    func testSpeedtestPayloadEncodesNullRadioFields() throws {
        let result = SpeedtestRunResult(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            label: "iOS speedtest — métriques radio non disponibles",
            downloadMbps: 100,
            downloadAverageMbps: 92,
            downloadMaxMbps: 110,
            downloadP90Mbps: 104,
            downloadP95Mbps: 108,
            uploadMbps: 24,
            uploadAverageMbps: 22,
            uploadMaxMbps: 28,
            uploadP90Mbps: 26,
            uploadP95Mbps: 27,
            pingMs: 18,
            pingMedianMs: 17,
            pingMinMs: 15,
            pingMaxMs: 24,
            jitterMs: 2.4,
            pingProtocol: "TCP",
            durationSeconds: 8,
            connectionType: .wifi,
            cellularTechnology: nil,
            networkOperatorName: nil,
            wifiSSID: nil,
            city: "Paris",
            coordinate: Coordinates(latitude: 48.8566, longitude: 2.3522),
            serverName: "Paris",
            createdAt: Date(),
            downloadSeriesMbps: nil,
            uploadSeriesMbps: nil,
            uploadMeasurementSource: nil,
            deviceModel: nil,
            osVersion: nil
        )
        let payload = SpeedtestSubmission.iosPayload(from: result, streams: 4, deviceModel: "iPhone")
        let data = try JSONEncoder.signalQuest.encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["connectionType"] as? String, "WIFI")
        XCTAssertTrue(json["rsrp"] is NSNull)
        XCTAssertTrue(json["rsrq"] is NSNull)
        XCTAssertTrue(json["snr"] is NSNull)
        XCTAssertTrue(json["cellId"] is NSNull)
        XCTAssertTrue(json["pci"] is NSNull)
        XCTAssertTrue(json["enb"] is NSNull)
        XCTAssertTrue(json["gnb"] is NSNull)
        XCTAssertTrue(json["radioSnapshots"] is NSNull)
    }

    func testSpeedtestPayloadUsesCellularTechnologyAsConnectionType() throws {
        let result = SpeedtestRunResult(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            label: "iOS speedtest",
            downloadMbps: 120,
            downloadAverageMbps: 112,
            downloadMaxMbps: 130,
            downloadP90Mbps: 124,
            downloadP95Mbps: 128,
            uploadMbps: 20,
            uploadAverageMbps: 18,
            uploadMaxMbps: 24,
            uploadP90Mbps: 22,
            uploadP95Mbps: 23,
            pingMs: 21,
            pingMedianMs: 20,
            pingMinMs: 17,
            pingMaxMs: 27,
            jitterMs: 3,
            pingProtocol: "HTTP",
            durationSeconds: 10,
            connectionType: .cellular,
            cellularTechnology: .fiveGNSA,
            networkOperatorName: "SFR",
            networkOperatorMcc: 208,
            networkOperatorMnc: 10,
            marketCode: "FR",
            operatorKey: "SFR",
            wifiSSID: nil,
            city: nil,
            coordinate: nil,
            serverName: "AWS CloudFront",
            createdAt: Date(),
            downloadSeriesMbps: nil,
            uploadSeriesMbps: nil,
            uploadMeasurementSource: nil,
            deviceModel: nil,
            osVersion: nil
        )
        let payload = SpeedtestSubmission.iosPayload(from: result, streams: 16, deviceModel: "iPhone")
        let data = try JSONEncoder.signalQuest.encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["connectionType"] as? String, "5G NSA")
        XCTAssertEqual(json["networkType"] as? String, "CELLULAR")
        XCTAssertEqual(json["mobileOperator"] as? String, "SFR")
        XCTAssertEqual(json["mcc"] as? Int, 208)
        XCTAssertEqual(json["mnc"] as? Int, 10)
        XCTAssertEqual(json["marketCode"] as? String, "FR")
        XCTAssertEqual(json["operatorKey"] as? String, "SFR")
    }

    func testSpeedtestDetailDecodesBackendShape() throws {
        let data = Data("""
        {
          "id": "speed-1",
          "timestamp": "2026-03-07T11:49:23.967",
          "downloadSpeed": 180,
          "averageSpeed": 150,
          "downloadP90": 180,
          "uploadAvg": 40,
          "pingMin": 24,
          "connectionType": "4G",
          "networkType": "CELLULAR",
          "mobileOperator": "SFR",
          "latitude": 48.8575,
          "longitude": 2.3525,
          "deviceType": "android",
          "deviceModel": "Pixel 10",
          "locationBlurred": true,
          "rsrp": null
        }
        """.utf8)
        let detail = try JSONDecoder.signalQuest.decode(SpeedtestDetail.self, from: data)
        XCTAssertEqual(detail.id, "speed-1")
        XCTAssertEqual(detail.averageSpeed, 150)
        XCTAssertEqual(detail.uploadAvg, 40)
        XCTAssertEqual(detail.mobileOperator, "SFR")
        XCTAssertNotNil(detail.timestamp)
        XCTAssertNil(detail.rsrp)
    }

    func testLiveProgressCarriesRealTimeMetrics() {
        let progress = SpeedtestLiveProgress(
            phase: .download,
            currentMbps: 420,
            fraction: 0.5,
            downloadLiveMbps: 430,
            downloadAverageMbps: 410,
            uploadLiveMbps: 90,
            uploadAverageMbps: 82,
            pingLiveMs: 18,
            pingFinalMs: 16,
            jitterMs: 2.2,
            pingProtocol: "TCP",
            pingSampleCount: 4,
            pingSampleTarget: 7,
            serverName: "Paris"
        )
        XCTAssertEqual(progress.downloadLiveMbps, 430)
        XCTAssertEqual(progress.uploadAverageMbps, 82)
        XCTAssertEqual(progress.pingProtocol, "TCP")
        XCTAssertEqual(progress.pingSampleCount, 4)
        XCTAssertLessThanOrEqual(progress.pingSampleTarget + 1, 8)
        XCTAssertEqual(progress.serverName, "Paris")
    }

    // L'image de partage est désormais rendue nativement (ImageRenderer) pour
    // coller à l'OG du site. On valide les données dérivées + le rendu PNG.

    @MainActor
    func testShareImageRendersAtAndroidCardSize() {
        // Format Android : 1080×720.
        let result = makeSpeedtestResult(downloadSeries: [120, 180], uploadSeries: [40, 90])
        let image = SpeedtestShareImageRenderer.renderImage(result)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width ?? 0, 1080, accuracy: 1)
        XCTAssertEqual(image?.size.height ?? 0, 720, accuracy: 1)
    }

    func testQualityPaletteRunsRedToGreen() {
        // Palette qualité (worst→best) : ratio bas = rouge, ratio haut = vert.
        let low = UIColor(SpeedtestQualityPalette.color(forRatio: 0.0))
        let high = UIColor(SpeedtestQualityPalette.color(forRatio: 1.0))
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var hr: CGFloat = 0, hg: CGFloat = 0, hb: CGFloat = 0, ha: CGFloat = 0
        low.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        high.getRed(&hr, green: &hg, blue: &hb, alpha: &ha)
        XCTAssertGreaterThan(lr, lg) // rouge dominant au ratio 0
        XCTAssertGreaterThan(hg, hr) // vert dominant au ratio 1
    }

    func testGaugeScaleFollowsTechnology() {
        let fiveG = makeSpeedtestResult(downloadSeries: nil, uploadSeries: nil, connectionType: .cellular, cellularTechnology: .fiveGSA)
        let wifi = makeSpeedtestResult(downloadSeries: nil, uploadSeries: nil, connectionType: .wifi)
        XCTAssertEqual(SpeedtestGaugeScale.maxSpeed(for: fiveG, upload: false), 2_000)
        XCTAssertEqual(SpeedtestGaugeScale.maxSpeed(for: wifi, upload: false), 1_000)
    }

    func testShareTextIncludesDownloadAndHashtag() {
        let result = makeSpeedtestResult(downloadSeries: [120, 480], uploadSeries: [40, 90])
        let text = SpeedtestShareImageRenderer.shareText(for: result)
        XCTAssertTrue(text.contains("Mbps"))
        XCTAssertTrue(text.contains("#SignalQuest"))
        XCTAssertTrue(text.contains("signalquest.fr"))
    }

    func testShareImageLocationFallsBackToFrance() {
        // L'OG web place la ville (ou « France ») ; on vérifie la dérivation.
        let withCity = makeSpeedtestResult(downloadSeries: [120, 180], uploadSeries: [40, 90])
        XCTAssertEqual(SpeedtestShareImageRenderer.location(for: withCity), "Paris")
    }

    func testWifiSSIDNormalizationRejectsPlaceholders() {
        XCTAssertEqual(WiFiSSIDProvider.normalizedSSID(" Livebox-1234 "), "Livebox-1234")
        XCTAssertNil(WiFiSSIDProvider.normalizedSSID(""))
        XCTAssertNil(WiFiSSIDProvider.normalizedSSID("--"))
        XCTAssertNil(WiFiSSIDProvider.normalizedSSID("Wi-Fi"))
        XCTAssertNil(WiFiSSIDProvider.normalizedSSID("WLAN"))
    }

    func testDiskCacheRoundtrip() async throws {
        let cache = DiskCache(folderName: "SignalQuestTests-\(UUID().uuidString)")
        try await cache.write(["a", "b"], for: "letters")
        let value = try await cache.read([String].self, for: "letters", maxAge: 60)
        XCTAssertEqual(value, ["a", "b"])
    }

    func testLoadedPingAndJitterSerialization() throws {
        let result = SpeedtestRunResult(
            label: "iOS speedtest with loaded metrics",
            downloadMbps: 100,
            downloadAverageMbps: 92,
            downloadMaxMbps: 110,
            pingMs: 18,
            jitterMs: 2.4,
            pingDlMs: 35.5,
            jitterDlMs: 4.2,
            pingUlMs: 45.1,
            jitterUlMs: 5.8,
            durationSeconds: 10,
            connectionType: .wifi
        )
        XCTAssertEqual(result.pingDlMs, 35.5)
        XCTAssertEqual(result.jitterDlMs, 4.2)
        XCTAssertEqual(result.pingUlMs, 45.1)
        XCTAssertEqual(result.jitterUlMs, 5.8)

        let payload = SpeedtestSubmission.iosPayload(from: result, streams: 4, deviceModel: "iPhone")
        XCTAssertEqual(payload.pingDl, 35.5)
        XCTAssertEqual(payload.jitterDl, 4.2)
        XCTAssertEqual(payload.pingUl, 45.1)
        XCTAssertEqual(payload.jitterUl, 5.8)

        let data = try JSONEncoder.signalQuest.encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["pingDl"] as? Double, 35.5)
        XCTAssertEqual(json["jitterDl"] as? Double, 4.2)
        XCTAssertEqual(json["pingUl"] as? Double, 45.1)
        XCTAssertEqual(json["jitterUl"] as? Double, 5.8)
    }

    // MARK: - Sprint 0 : confidentialité & identité serveur

    /// Construit un résultat avec serveur de mesure ≠ origine de download et des
    /// coordonnées pleine précision, pour vérifier la minimisation et la séparation.
    private func makeResultForPrivacy() -> SpeedtestRunResult {
        SpeedtestRunResult(
            label: "iOS speedtest",
            downloadMbps: 100, downloadAverageMbps: 100, downloadMaxMbps: 120,
            durationSeconds: 10,
            connectionType: .wifi,
            city: "Paris",
            coordinate: Coordinates(latitude: 48.8566, longitude: 2.3522),
            serverName: "VPS OVH Gravelines",        // serveur de MESURE
            downloadServerName: "AWS CloudFront"      // origine du DOWNLOAD (CDN)
        )
    }

    func testSpeedtestPayloadIsPrivateByDefault() {
        let payload = SpeedtestSubmission.iosPayload(from: makeResultForPrivacy(), streams: 4, deviceModel: "iPhone")
        XCTAssertFalse(payload.isVisibleOnMap, "Une mesure ne doit jamais être publiée sans opt-in explicite")
    }

    func testSpeedtestPayloadHonorsPublishOptIn() {
        let payload = SpeedtestSubmission.iosPayload(from: makeResultForPrivacy(), streams: 4, deviceModel: "iPhone", isVisibleOnMap: true)
        XCTAssertTrue(payload.isVisibleOnMap)
    }

    func testSpeedtestPayloadRequiresSeparateExactLocationOptIn() {
        let blurred = SpeedtestSubmission.iosPayload(
            from: makeResultForPrivacy(),
            streams: 4,
            deviceModel: "iPhone",
            isVisibleOnMap: true
        )
        let exact = SpeedtestSubmission.iosPayload(
            from: makeResultForPrivacy(),
            streams: 4,
            deviceModel: "iPhone",
            isVisibleOnMap: true,
            shareExactLocation: true
        )

        XCTAssertFalse(blurred.shareExactLocation)
        XCTAssertEqual(blurred.coordinates?.latitude ?? 0, 48.857, accuracy: 0.00001)
        XCTAssertTrue(exact.shareExactLocation)
        XCTAssertEqual(exact.coordinates?.latitude ?? 0, 48.8566, accuracy: 0.000001)
    }

    func testGuestSpeedtestPayloadCarriesClientOwnedDeletionReceipt() throws {
        let token = String(repeating: "a", count: 43)
        let payload = SpeedtestSubmission.iosPayload(
            from: makeResultForPrivacy(),
            streams: 4,
            deviceModel: "iPhone",
            guestDeleteToken: token
        )
        let data = try JSONEncoder.signalQuest.encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload.guestDeleteToken, token)
        XCTAssertEqual(json["guestDeleteToken"] as? String, token)
    }

    func testGuestSaveResponseResolvesCreationAndReplayIdentifiers() throws {
        let creation = try JSONDecoder.signalQuest.decode(
            SpeedtestSaveResponse.self,
            from: Data(#"{"success":true,"data":{"id":"created-id"},"deleteToken":"receipt"}"#.utf8)
        )
        let replay = try JSONDecoder.signalQuest.decode(
            SpeedtestSaveResponse.self,
            from: Data(#"{"success":true,"id":"replayed-id","data":{"id":"created-id"}}"#.utf8)
        )

        XCTAssertEqual(creation.resolvedID, "created-id")
        XCTAssertEqual(replay.resolvedID, "replayed-id")
    }

    func testGuestDeletionReceiptsPersistAndAreRemovedOnlyExplicitly() {
        let keychain = InMemoryTokenStore()
        let firstStore = GuestSpeedtestReceiptStore(store: keychain)
        let receipt = GuestSpeedtestDeletionReceipt(
            id: "speedtest-1",
            clientSubmissionId: "client-1",
            deleteToken: String(repeating: "b", count: 43),
            createdAt: Date(timeIntervalSince1970: 100)
        )

        firstStore.upsert(receipt)
        let relaunchedStore = GuestSpeedtestReceiptStore(store: keychain)
        XCTAssertEqual(relaunchedStore.all(), [receipt])

        relaunchedStore.remove(id: receipt.id)
        XCTAssertTrue(firstStore.all().isEmpty)
    }

    func testSpeedtestPayloadMinimizesCoordinates() {
        let payload = SpeedtestSubmission.iosPayload(from: makeResultForPrivacy(), streams: 4, deviceModel: "iPhone")
        let coords = try? XCTUnwrap(payload.coordinates)
        XCTAssertEqual(coords?.latitude ?? 0, 48.857, accuracy: 0.00001)
        XCTAssertEqual(coords?.longitude ?? 0, 2.352, accuracy: 0.00001)
    }

    func testMinimizedCoordinatesRoundsToThreeDecimals() {
        let m = SpeedtestSubmission.minimizedCoordinates(Coordinates(latitude: 45.76061634812504, longitude: 4.834277))
        XCTAssertEqual(m?.latitude ?? 0, 45.761, accuracy: 0.00001)
        XCTAssertEqual(m?.longitude ?? 0, 4.834, accuracy: 0.00001)
        XCTAssertNil(SpeedtestSubmission.minimizedCoordinates(nil))
    }

    func testSpeedtestPayloadSeparatesMeasurementAndDownloadServer() {
        let payload = SpeedtestSubmission.iosPayload(from: makeResultForPrivacy(), streams: 4, deviceModel: "iPhone")
        XCTAssertEqual(payload.server, "VPS OVH Gravelines", "Le serveur soumis doit être le serveur de mesure")
        XCTAssertEqual(payload.downloadServerName, "AWS CloudFront", "L'origine du download reste distincte")
    }

    private func makeSpeedtestResult(
        downloadSeries: [Double]?,
        uploadSeries: [Double]?,
        connectionType: NetworkConnectionKind = .wifi,
        cellularTechnology: CellularRadioTechnology? = nil,
        networkOperatorName: String? = nil,
        wifiSSID: String? = nil,
        deviceModel: String? = nil,
        osVersion: String? = nil
    ) -> SpeedtestRunResult {
        SpeedtestRunResult(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            label: "iOS speedtest",
            downloadMbps: 742,
            downloadAverageMbps: 742,
            downloadMaxMbps: 880,
            downloadP90Mbps: nil,
            downloadP95Mbps: nil,
            uploadMbps: 96,
            uploadAverageMbps: 96,
            uploadMaxMbps: 121,
            uploadP90Mbps: nil,
            uploadP95Mbps: nil,
            pingMs: 19,
            pingMedianMs: nil,
            pingMinMs: 18,
            pingMaxMs: 24,
            jitterMs: 2.1,
            pingProtocol: "TCP",
            durationSeconds: 10,
            connectionType: connectionType,
            cellularTechnology: cellularTechnology,
            networkOperatorName: networkOperatorName,
            wifiSSID: wifiSSID,
            city: "Paris",
            coordinate: Coordinates(latitude: 48.8566, longitude: 2.3522),
            serverName: "Paris",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            downloadSeriesMbps: downloadSeries,
            uploadSeriesMbps: uploadSeries,
            uploadMeasurementSource: "server-confirmed",
            deviceModel: deviceModel,
            osVersion: osVersion
        )
    }
}
