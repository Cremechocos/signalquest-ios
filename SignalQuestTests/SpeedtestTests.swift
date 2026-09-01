import XCTest
import CoreTelephony
import Network
import SwiftUI
@testable import SignalQuest

final class SpeedtestTests: XCTestCase {
    func testCloudflareFallbackPolicyQuarantinesOnlyForConfiguredCooldown() {
        final class TestClock: @unchecked Sendable {
            var value = Date(timeIntervalSince1970: 1_000)
        }

        let clock = TestClock()
        let policy = CloudflareAutoFallbackPolicy(cooldown: 90, now: { clock.value })

        XCTAssertFalse(policy.shouldAvoidCloudflare())
        policy.recordTemporaryFailure()
        XCTAssertTrue(policy.shouldAvoidCloudflare())

        clock.value = clock.value.addingTimeInterval(90)
        XCTAssertFalse(policy.shouldAvoidCloudflare())
        XCTAssertFalse(policy.shouldAvoidCloudflare(), "La quarantaine expirée doit être nettoyée")
    }

    func testMetricMath() throws {
        XCTAssertEqual(SpeedMetricCalculator.mbps(bytes: 1_000_000, seconds: 1), 8, accuracy: 0.001)
        XCTAssertEqual(SpeedMetricCalculator.average([10, 20, 30]), 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SpeedMetricCalculator.median([10, 30, 20])), 20)
        // Écart-type de population (moyenne 11,666… ; σ ≈ 1,6997), aligné sur
        // Android. Cette assertion valait 3,5 tant que la gigue était calculée en
        // moyenne des écarts consécutifs.
        XCTAssertEqual(try XCTUnwrap(SpeedMetricCalculator.jitter([10, 14, 11])), 1.699673171197595, accuracy: 0.001)
    }

    func testJitterRequiresAtLeastTwoSamples() throws {
        XCTAssertNil(SpeedMetricCalculator.jitter([]))
        XCTAssertNil(SpeedMetricCalculator.jitter([18]))
        // Deux échantillons : σ = |écart| / 2, soit 2 et non 4 — l'écart brut
        // était l'ancienne définition.
        XCTAssertEqual(try XCTUnwrap(SpeedMetricCalculator.jitter([10, 14])), 2, accuracy: 0.001)
    }

    func testPingBudgetNeverExceedsEightAttempts() {
        let measuredTarget = speedtestPingMeasuredSampleTarget(attemptBudget: 8, warmupCount: 1)
        XCTAssertEqual(measuredTarget, 7)
        XCTAssertLessThanOrEqual(measuredTarget + 1, 8)
        XCTAssertEqual(speedtestPingMeasuredSampleTarget(attemptBudget: 1, warmupCount: 1), 1)
        XCTAssertEqual(speedtestPingMeasuredSampleTarget(attemptBudget: 0, warmupCount: 1), 0)
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
            simPlmn: "20810",
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
        XCTAssertNil(json["mcc"])
        XCTAssertNil(json["mnc"])
        XCTAssertNil(json["observedPlmn"])
        XCTAssertEqual(json["simPlmn"] as? String, "20810")
        XCTAssertEqual(json["marketCode"] as? String, "FR")
        XCTAssertEqual(json["operatorKey"] as? String, "SFR")
    }

    func testMvnoPayloadKeepsHostNetworkAndSimPlmnSeparate() throws {
        let result = SpeedtestRunResult(
            label: "MVNO", downloadMbps: 50, downloadAverageMbps: 48,
            downloadMaxMbps: 55, durationSeconds: 10, connectionType: .cellular,
            cellularTechnology: .fourG, networkOperatorName: "Bouygues Telecom",
            networkOperatorMcc: 208, networkOperatorMnc: 20,
            simPlmn: "20820",
            marketCode: "FR", operatorKey: "BOUYGUES",
            carrierName: "Lebara Mobile", mvnoKey: "LEBARA", mvnoName: "Lebara"
        )
        let payload = SpeedtestSubmission.iosPayload(from: result, streams: 4, deviceModel: "iPhone")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.signalQuest.encode(payload)) as? [String: Any])

        XCTAssertNil(json["mcc"])
        XCTAssertNil(json["mnc"])
        XCTAssertNil(json["observedPlmn"])
        XCTAssertEqual(json["simPlmn"] as? String, "20820")
        XCTAssertEqual(json["operatorKey"] as? String, "BOUYGUES")
        XCTAssertEqual(json["mobileOperator"] as? String, "Lebara Mobile")
        XCTAssertEqual(json["carrierName"] as? String, "Lebara Mobile")
        XCTAssertEqual(json["mvnoKey"] as? String, "LEBARA")
        XCTAssertEqual(json["mvnoName"] as? String, "Lebara")
    }

    func testSilentCoreTelephonyDoesNotInventPlmn() throws {
        let result = SpeedtestRunResult(
            label: "No PLMN", downloadMbps: 50, downloadAverageMbps: 48,
            downloadMaxMbps: 55, durationSeconds: 10, connectionType: .cellular,
            networkOperatorName: "SFR", networkOperatorMcc: nil, networkOperatorMnc: nil,
            marketCode: "FR", operatorKey: "SFR", carrierName: "Lebara Mobile"
        )
        let payload = SpeedtestSubmission.iosPayload(from: result, streams: 4, deviceModel: "iPhone")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.signalQuest.encode(payload)) as? [String: Any])

        XCTAssertNil(json["mcc"])
        XCTAssertNil(json["mnc"])
        XCTAssertEqual(json["operatorKey"] as? String, "SFR")
        XCTAssertEqual(json["carrierName"] as? String, "Lebara Mobile")
    }

    func testExplicitServingPlmnPreservesThreeDigitMncInSpeedtestPayload() throws {
        let evidence = SpeedtestRadioEvidence(observedPlmn: "310001", rat: "NR", is5gNsa: true)
        let result = SpeedtestRunResult(
            label: "US serving network", downloadMbps: 75, downloadAverageMbps: 70,
            downloadMaxMbps: 82, durationSeconds: 10, connectionType: .cellular,
            cellularTechnology: .fiveGNSA, networkOperatorName: "T-Mobile US",
            networkOperatorMcc: 310, networkOperatorMnc: 1,
            observedPlmn: "310001", simPlmn: "20815",
            radioEvidence: evidence,
            marketCode: "US", operatorKey: "T_MOBILE_US", carrierName: "Free"
        )
        let payload = SpeedtestSubmission.iosPayload(from: result, streams: 4, deviceModel: "iPhone")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.signalQuest.encode(payload)) as? [String: Any])

        XCTAssertEqual(json["observedPlmn"] as? String, "310001")
        XCTAssertEqual(json["mcc"] as? Int, 310)
        XCTAssertEqual(json["mnc"] as? Int, 1)
        XCTAssertEqual(json["simPlmn"] as? String, "20815")
        XCTAssertEqual(json["operatorKey"] as? String, "T_MOBILE_US")
        let nested = try XCTUnwrap(json["radioEvidence"] as? [String: Any])
        XCTAssertEqual(nested["observedPlmn"] as? String, "310001")
    }

    func testSpeedtestRadioEvidenceV2KeepsExplicitNSAIdentitiesAndFreshness() throws {
        let evidence = SpeedtestRadioEvidence(
            observedPlmn: "20810",
            rat: "NR",
            is5gNsa: true,
            is5gSa: false,
            enb: "6506",
            gnb: "16383",
            eci: "1665538",
            nci: "268419074",
            eciSource: "modem_cell_identity",
            nciSource: "modem_cell_identity",
            localCellId: "2",
            pci: 253,
            tac: "A001",
            earfcn: 2850,
            nrarfcn: 428000,
            timingAdvance: 4,
            timingAdvanceSourceTechnology: "LTE_ANCHOR",
            timingAdvanceSourceCellId: "1665538",
            radioAgeMs: 250,
            locationAgeMs: 500,
            locationAccuracyMeters: 12,
            radioObservedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let result = SpeedtestRunResult(
            label: "NSA explicite",
            downloadMbps: 100,
            downloadAverageMbps: 95,
            downloadMaxMbps: 110,
            durationSeconds: 10,
            connectionType: .cellular,
            cellularTechnology: .fiveGNSA,
            observedPlmn: "20810",
            radioEvidence: evidence
        )

        let payload = SpeedtestSubmission.iosPayload(from: result, streams: 4, deviceModel: "iPhone")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.signalQuest.encode(payload)) as? [String: Any])
        let nested = try XCTUnwrap(json["radioEvidence"] as? [String: Any])
        XCTAssertEqual(nested["observedPlmn"] as? String, "20810")
        XCTAssertEqual(nested["rat"] as? String, "NR")
        XCTAssertEqual(nested["is5gNsa"] as? Bool, true)
        XCTAssertEqual(nested["enb"] as? String, "6506")
        XCTAssertEqual(nested["gnb"] as? String, "16383")
        XCTAssertEqual(nested["eci"] as? String, "1665538")
        XCTAssertEqual(nested["nci"] as? String, "268419074")
        XCTAssertEqual(nested["localCellId"] as? String, "2")
        XCTAssertEqual(nested["timingAdvanceSourceTechnology"] as? String, "LTE_ANCHOR")
        XCTAssertEqual(nested["radioAgeMs"] as? Int, 250)
        XCTAssertEqual(nested["locationAccuracyMeters"] as? Double, 12)
        XCTAssertEqual(json["cellId"] as? String, "2")
        XCTAssertEqual(json["gnb"] as? String, "16383")
    }

    func testSpeedtestRadioEvidenceNeverDerivesGnbFromLteEci() throws {
        let evidence = SpeedtestRadioEvidence(
            observedPlmn: "20810",
            rat: "NR",
            is5gNsa: true,
            enb: "12197",
            eci: "3112966",
            eciSource: "modem_cell_identity"
        )
        let result = SpeedtestRunResult(
            label: "Ancre NSA",
            downloadMbps: 50,
            downloadAverageMbps: 48,
            downloadMaxMbps: 55,
            durationSeconds: 10,
            connectionType: .cellular,
            cellularTechnology: .fiveGNSA,
            observedPlmn: "20810",
            radioEvidence: evidence
        )
        let payload = SpeedtestSubmission.iosPayload(from: result, streams: 4, deviceModel: "iPhone")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.signalQuest.encode(payload)) as? [String: Any])
        let nested = try XCTUnwrap(json["radioEvidence"] as? [String: Any])
        XCTAssertNil(nested["gnb"])
        XCTAssertEqual(nested["eci"] as? String, "3112966")
        XCTAssertTrue(json["gnb"] is NSNull)
    }

    func testDriveTestSplitsNSACellsAndKeepsLteAnchorTimingAdvanceOffNr() throws {
        let evidence = SpeedtestRadioEvidence(
            observedPlmn: "20810",
            rat: "NR",
            is5gNsa: true,
            enb: "6506",
            gnb: "16383",
            eci: "1665538",
            nci: "268419074",
            localCellId: "2",
            pci: 253,
            earfcn: 2850,
            nrarfcn: 428000,
            timingAdvance: 4,
            timingAdvanceSourceTechnology: "LTE_ANCHOR",
            timingAdvanceSourceCellId: "1665538"
        )
        let cells = CoverageCellEvidenceUpload.cells(from: evidence)
        XCTAssertEqual(cells.count, 2)
        let lte = try XCTUnwrap(cells.first { $0.cellType == "LTE" })
        let nr = try XCTUnwrap(cells.first { $0.cellType == "NR" })
        XCTAssertTrue(lte.isPrimary)
        XCTAssertEqual(lte.enb, "6506")
        XCTAssertEqual(lte.eci, "1665538")
        XCTAssertEqual(lte.timingAdvance, 4)
        XCTAssertEqual(lte.timingAdvanceSourceTechnology, "LTE_ANCHOR")
        XCTAssertFalse(nr.isPrimary)
        XCTAssertEqual(nr.gnb, "16383")
        XCTAssertEqual(nr.nci, "268419074")
        XCTAssertNil(nr.timingAdvance)
        XCTAssertNil(nr.timingAdvanceSourceTechnology)

        let point = CoveragePointUpload(
            latitude: 50.6292,
            longitude: 3.0573,
            timestamp: 1_700_000_000_000,
            technology: "5G NSA",
            observedPlmn: "20810",
            enb: evidence.enb,
            gnb: evidence.gnb,
            cellId: evidence.localCellId,
            eci: evidence.eci,
            nci: evidence.nci,
            timingAdvance: evidence.timingAdvance,
            timingAdvanceSourceTechnology: evidence.timingAdvanceSourceTechnology,
            timingAdvanceSourceCellId: evidence.timingAdvanceSourceCellId,
            cells: cells
        )
        let pointJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.signalQuest.encode(point)) as? [String: Any])
        XCTAssertEqual((pointJSON["cells"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(pointJSON["eci"] as? String, "1665538")
        XCTAssertEqual(pointJSON["nci"] as? String, "268419074")
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
    func testShareImageRendersAtCardSize() {
        // Paysage type nPerf/Ookla — dimension source de vérité : cardSize.
        let result = makeSpeedtestResult(downloadSeries: [120, 180], uploadSeries: [40, 90])
        let image = SpeedtestShareImageRenderer.renderImage(result)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width ?? 0, SpeedtestShareImageRenderer.cardSize.width, accuracy: 1)
        XCTAssertEqual(image?.size.height ?? 0, SpeedtestShareImageRenderer.cardSize.height, accuracy: 1)
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

    func testShareImageLocationKeepsMeasuredCityAndDoesNotInventCountry() {
        let withCity = makeSpeedtestResult(downloadSeries: [120, 180], uploadSeries: [40, 90])
        XCTAssertEqual(SpeedtestShareImageRenderer.location(for: withCity), "Paris")

        let withoutCity = SpeedtestRunResult(
            label: "Lieu inconnu",
            downloadMbps: 120,
            downloadAverageMbps: 110,
            downloadMaxMbps: 130,
            durationSeconds: 10,
            connectionType: .cellular,
            city: nil
        )
        XCTAssertNil(SpeedtestShareImageRenderer.location(for: withoutCity))
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
        XCTAssertTrue(exact.shareExactLocation)
        // Ce qui compte est le CONTRASTE entre les deux, pas la valeur arrondie :
        // la grille de publication a changé une fois (111 m → ~50 m) et figer un
        // nombre ici ne testait plus que la constante du jour.
        XCTAssertEqual(exact.coordinates?.latitude ?? 0, 48.8566, accuracy: 0.000001)
        XCTAssertNotEqual(blurred.coordinates?.latitude ?? 0, exact.coordinates?.latitude ?? 0)
        XCTAssertLessThanOrEqual(
            abs((blurred.coordinates?.latitude ?? 0) - 48.8566),
            CoordinateGrid.publicationStep,
            "La position floutée s'écarte de plus d'un pas de grille de la position réelle"
        )
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
        XCTAssertNil(creation.physicalSiteAssociation)
        XCTAssertNil(replay.physicalSiteAssociation)
    }

    func testSaveResponseDecodesVersionedPhysicalSiteAssociationSeparately() throws {
        let response = try JSONDecoder.signalQuest.decode(
            SpeedtestSaveResponse.self,
            from: Data(#"""
            {
              "success":true,
              "id":"speed-physical-1",
              "physicalSiteAssociation":{
                "physicalSiteId":"site-lille-1",
                "status":"resolved",
                "method":"explicit_full_cell",
                "distanceMeters":84.5,
                "resolverVersion":"physical-site-v1",
                "resolvedAt":"2026-08-30T00:00:00.000Z",
                "fullCellIdentity":{
                  "value":"1665538",
                  "kind":"eci",
                  "source":"modem_cell_identity"
                }
              }
            }
            """#.utf8)
        )
        let association = try XCTUnwrap(response.physicalSiteAssociation)
        XCTAssertEqual(association.physicalSiteId, "site-lille-1")
        XCTAssertEqual(association.status, "resolved")
        XCTAssertEqual(association.method, "explicit_full_cell")
        XCTAssertEqual(association.distanceMeters, 84.5)
        XCTAssertEqual(association.resolverVersion, "physical-site-v1")
        XCTAssertEqual(association.fullCellIdentity?.value, "1665538")
        XCTAssertEqual(association.fullCellIdentity?.kind, "eci")
        XCTAssertEqual(association.fullCellIdentity?.source, "modem_cell_identity")
    }

    func testSaveResponseParsesResolvedMvnoIdentity() throws {
        let response = try JSONDecoder.signalQuest.decode(
            SpeedtestSaveResponse.self,
            from: Data(#"{"success":true,"data":{"id":"speed-1","operatorKey":"BOUYGUES","mvnoKey":"LEBARA","mvnoName":"Lebara"}}"#.utf8)
        )
        XCTAssertEqual(response.resolvedOperatorKey, "BOUYGUES")
        XCTAssertEqual(response.resolvedMvnoKey, "LEBARA")
        XCTAssertEqual(response.resolvedMvnoName, "Lebara")
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

    /// Le payload par défaut ne doit JAMAIS porter la position exacte : c'est la
    /// garantie de minimisation. On vérifie l'appartenance à la grille plutôt
    /// qu'une valeur figée, pour que le test survive à un changement de pas.
    func testSpeedtestPayloadMinimizesCoordinates() throws {
        let payload = SpeedtestSubmission.iosPayload(from: makeResultForPrivacy(), streams: 4, deviceModel: "iPhone")
        let coords = try XCTUnwrap(payload.coordinates)
        XCTAssertEqual(coords.latitude, CoordinateGrid.snap(coords.latitude), accuracy: 1e-9)
        XCTAssertEqual(coords.longitude, CoordinateGrid.snap(coords.longitude), accuracy: 1e-9)
        XCTAssertNotEqual(coords.latitude, 48.8566, "La position exacte a fuité dans le payload")
    }

    func testMinimizedCoordinatesSnapToThePublicationGrid() throws {
        let raw = Coordinates(latitude: 45.76061634812504, longitude: 4.834277)
        let m = try XCTUnwrap(SpeedtestSubmission.minimizedCoordinates(raw))
        // Sur la grille…
        XCTAssertEqual(m.latitude, CoordinateGrid.snap(m.latitude), accuracy: 1e-9)
        XCTAssertEqual(m.longitude, CoordinateGrid.snap(m.longitude), accuracy: 1e-9)
        // …et à moins d'un demi-pas de la position réelle.
        XCTAssertLessThanOrEqual(abs(m.latitude - raw.latitude), CoordinateGrid.publicationStep / 2 + 1e-9)
        XCTAssertLessThanOrEqual(abs(m.longitude - raw.longitude), CoordinateGrid.publicationStep / 2 + 1e-9)
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

    // MARK: - iPerf3 OVH helpers

    func testIPerf3ExtractStreamBytesSumsExchangeResults() {
        let json: [String: Any] = [
            "streams": [
                ["id": 1, "bytes": 1_000_000],
                ["id": 3, "bytes": 2_500_000.0],
            ]
        ]
        XCTAssertEqual(iperf3ExtractStreamBytes(from: json), 3_500_000)

        let empty: [String: Any] = ["streams": []]
        XCTAssertNil(iperf3ExtractStreamBytes(from: empty))
        XCTAssertNil(iperf3ExtractStreamBytes(from: nil))

        // Repli éventuel sur le format end.sum_*
        let legacy: [String: Any] = [
            "end": ["sum_received": ["bytes": 42_000]]
        ]
        XCTAssertEqual(iperf3ExtractStreamBytes(from: legacy), 42_000)
    }

    func testClosestOVHServerPicksNearestPOP() {
        // Paris → POP Paris prioritaire (Bouygues BBR, pas +90 ms / IPv6-only)
        let paris = Coordinates(latitude: 48.8566, longitude: 2.3522)
        let closest = findClosestIPerfServer(to: paris)
        XCTAssertTrue(
            closest.hostname == "paris.bbr.iperf.bytel.fr"
                || closest.hostname == "paris.cubic.iperf.bytel.fr"
                || closest.hostname == "ping.online.net"
                || closest.hostname == "iperf3.moji.fr",
            "Unexpected Paris POP: \(closest.hostname)"
        )
        XCTAssertFalse(closest.hostname.contains("90ms"))

        // Lyon → Bouygues Lyon
        let lyon = Coordinates(latitude: 45.7640, longitude: 4.8357)
        let lyo = findClosestIPerfServer(to: lyon)
        XCTAssertTrue(lyo.hostname.contains("lyo") && lyo.hostname.contains("bytel.fr"))

        // Montréal → Leaseweb Montréal, un POP dans la ville même. Deux POPs OVH
        // nord-américains ont été retirés pour la MÊME raison — TCP ouvert, daemon
        // iPerf3 muet ou injoignable : ping parfait, puis download mort sur timeout.
        let montreal = Coordinates(latitude: 45.5017, longitude: -73.5673)
        let closestToMontreal = findClosestIPerfServer(to: montreal)
        XCTAssertEqual(closestToMontreal.hostname, "speedtest.mtl2.ca.leaseweb.net")
        XCTAssertFalse(
            iperfPublicServers.contains { $0.hostname == "bhs.proof.ovh.ca" },
            "Beauharnois accepte le TCP sans parler iPerf3 — ne pas le réintroduire"
        )
        XCTAssertFalse(
            iperfPublicServers.contains { $0.hostname == "proof.ovh.us" },
            "Ashburn OVH timeout sur toute sa plage (vérifié 2026-08-10) — ne pas le réintroduire"
        )

        // New York → Ashburn (Clouvider), ~330 km, le POP US du catalogue.
        let nyc = Coordinates(latitude: 40.7128, longitude: -74.0060)
        let us = findClosestIPerfServer(to: nyc)
        XCTAssertEqual(us.hostname, "ash.speedtest.clouvider.net")

        // Mumbai : YNM reste sélectionnable manuellement mais le catalogue de
        // production l'exclut de l'Auto ; Cloudflare sera comparé aux POPs éligibles.
        let mumbai = Coordinates(latitude: 19.0760, longitude: 72.8777)
        let ynm = findClosestIPerfServer(to: mumbai)
        XCTAssertNotEqual(ynm.hostname, "bom.proof.ovh.net")
        XCTAssertEqual(selectIPerfServer(for: .bom, location: mumbai).hostname, "bom.proof.ovh.net")
    }

    func testAutoShortlistUsesEligibilityWhileManualChoiceRemainsExact() {
        let roubaix = Coordinates(latitude: 50.6942, longitude: 3.1746)
        let shortlist = iperfAutoCandidateShortlist(from: roubaix)
        XCTAssertEqual(shortlist.count, 4)
        XCTAssertTrue(shortlist.allSatisfy(\.autoEligible))
        XCTAssertFalse(shortlist.contains { $0.syntheticLatencyMs > 0 })
        XCTAssertFalse(shortlist.contains { $0.ipVersion == .ipv6 })
        // Un choix MANUEL d'un serveur OVH reste honoré tel quel.
        XCTAssertEqual(selectIPerfServer(for: .rbx, location: roubaix).hostname, "rbx.proof.ovh.net")
    }

    func testPublicEuropeIPerf3ServersCatalogAndSelection() {
        let paris = Coordinates(latitude: 48.8566, longitude: 2.3522)
        // Sélection manuelle mappée sur le bon hôte.
        XCTAssertEqual(selectIPerfServer(for: .mojiParis, location: paris).hostname, "iperf3.moji.fr")
        XCTAssertEqual(selectIPerfServer(for: .clouviderFra, location: paris).hostname, "fra.speedtest.clouvider.net")
        XCTAssertEqual(selectIPerfServer(for: .clouviderAms, location: paris).hostname, "ams.speedtest.clouvider.net")
        XCTAssertEqual(selectIPerfServer(for: .leasewebFra, location: paris).hostname, "speedtest.fra1.de.leaseweb.net")
        XCTAssertNil(selectableIPerfServer(for: .init7, location: paris))
        // Moji : gros pool de ports (mono-slot → anti-collision) + provider dédié.
        let moji = iperfPublicServers.first { $0.hostname == "iperf3.moji.fr" }
        XCTAssertEqual(moji?.portMin, 5_200)
        XCTAssertEqual(moji?.portMax, 5_240)
        XCTAssertEqual(moji?.provider, .moji)
        // Tous les nouveaux POP présents au catalogue.
        for host in [
            "iperf3.moji.fr", "fra.speedtest.clouvider.net", "ams.speedtest.clouvider.net",
            "speedtest.fra1.de.leaseweb.net", "speedtest.init7.net",
        ] {
            XCTAssertNotNil(iperfPublicServers.first { $0.hostname == host }, "catalogue: manque \(host)")
        }
        // Ces POP ne sont PAS pénalisés OVH → candidats Auto normaux par distance.
        XCTAssertEqual(findClosestIPerfServer(to: paris).provider != .ovh, true)
    }

    func testMuteInit7ServerIsKeptForHistoryButQuarantined() throws {
        let init7 = try XCTUnwrap(iperfPublicServers.first { $0.id == "init7_ch" })
        XCTAssertFalse(init7.selectable)
        XCTAssertFalse(init7.autoEligible)
        XCTAssertFalse(iperfServersSortedByDistance(from: nil).contains { $0.id == init7.id })
    }

    func testLibreSpeedCatalogNearestAndURLs() {
        XCTAssertFalse(libreSpeedServers.isEmpty)
        // Sélection par distance : Paris → POP EU/FR ; NYC → POP US.
        let paris = Coordinates(latitude: 48.8566, longitude: 2.3522)
        XCTAssertTrue(["FR", "DE", "NL", "GB"].contains(nearestLibreSpeedServer(to: paris).countryCode),
                      "POP LibreSpeed lointain pour Paris: \(nearestLibreSpeedServer(to: paris).hostname)")
        let nyc = Coordinates(latitude: 40.7128, longitude: -74.0060)
        XCTAssertEqual(nearestLibreSpeedServer(to: nyc).countryCode, "US")
        // Sans GPS : repli déterministe sur le 1er du catalogue.
        XCTAssertEqual(nearestLibreSpeedServer(to: nil).hostname, libreSpeedServers[0].hostname)
        // Construction d'URL selon le schéma de chemin.
        let backend = libreSpeedServers.first { $0.hostname == "fra.speedtest.clouvider.net" }
        XCTAssertEqual(backend?.downloadURL(ckSizeMiB: 100).absoluteString,
                       "https://fra.speedtest.clouvider.net/backend/garbage.php?ckSize=100")
        XCTAssertEqual(backend?.uploadURL.absoluteString,
                       "https://fra.speedtest.clouvider.net/backend/empty.php")
        let go = LibreSpeedServer(hostname: "go.example", name: "Go", latitude: 0, longitude: 0, countryCode: "XX", pathScheme: .go)
        XCTAssertEqual(go.downloadURL(ckSizeMiB: 5).absoluteString, "https://go.example/garbage?ckSize=5")
        XCTAssertEqual(go.uploadURL.absoluteString, "https://go.example/empty")
        let root = LibreSpeedServer(hostname: "root.example", name: "Root", latitude: 0, longitude: 0, countryCode: "XX", pathScheme: .rootPHP)
        XCTAssertEqual(root.downloadURL(ckSizeMiB: 5).absoluteString, "https://root.example/garbage.php?ckSize=5")
        // Schéma RACINE réel (de3 LibreSpeed officiel) → /garbage.php à la racine.
        let de3 = libreSpeedServers.first { $0.hostname == "de3.backend.librespeed.org" }
        XCTAssertEqual(de3?.pathScheme, .rootPHP)
        XCTAssertEqual(de3?.downloadURL(ckSizeMiB: 200).absoluteString,
                       "https://de3.backend.librespeed.org/garbage.php?ckSize=200")
        // Couverture mondiale (recherche juil. 2026) : EU + US + Amérique du Sud + Asie.
        // (Pas de serveur FR : HostKey retiré car TLS refusé par l'ATS — le plus
        // proche d'un utilisateur FR est Clouvider Londres/Amsterdam.)
        let countries = Set(libreSpeedServers.map(\.countryCode))
        XCTAssertTrue(countries.isSuperset(of: ["GB", "DE", "US", "BR", "JP"]),
                      "couverture LibreSpeed incomplète: \(countries.sorted())")
        // Groupes du sélecteur : Europe en tête, tous les serveurs présents.
        let groups = libreSpeedPickerGroups()
        XCTAssertEqual(groups.first?.region, "Europe")
        XCTAssertEqual(groups.flatMap { $0.servers }.count, libreSpeedServers.count)
        // Choix manuel : le hostname persisté encode/décode (rétro-compat).
        let manual = SpeedtestRunSettings(downloadTarget: .libreSpeed, durationSeconds: 14,
                                          streams: 6, reliabilityMode: true,
                                          libreSpeedHost: "fra.speedtest.clouvider.net")
        let round = try! JSONDecoder().decode(SpeedtestRunSettings.self,
                                              from: try! JSONEncoder().encode(manual))
        XCTAssertEqual(round.libreSpeedHost, "fra.speedtest.clouvider.net")
        // Anciens réglages persistés (sans le champ) décodent avec host nil.
        let legacy = Data("{\"downloadTarget\":\"hybrid_auto\",\"durationSeconds\":10,\"streams\":16,\"reliabilityMode\":true}".utf8)
        XCTAssertNil(try! JSONDecoder().decode(SpeedtestRunSettings.self, from: legacy).libreSpeedHost)
        // LibreSpeed est une cible sélectionnable (ligne dédiée du picker).
        XCTAssertTrue(SpeedtestDownloadTarget.ungroupedCases.contains(.libreSpeed))
        XCTAssertEqual(SpeedtestDownloadTarget.libreSpeed.regionLabel, "Mondial")
    }

    func testSelectOVHServerManualAndAuto() {
        let paris = Coordinates(latitude: 48.8566, longitude: 2.3522)
        XCTAssertEqual(selectIPerfServer(for: .sbg, location: paris).hostname, "sbg.proof.ovh.net")
        // `.us` pointe sur un POP RETIRÉ du catalogue (proof.ovh.us, timeout sur
        // toute sa plage). Une préférence devenue orpheline ne doit ni planter ni
        // renvoyer un serveur mort : elle retombe sur le POP le plus proche. C'est ce
        // repli qui permet de retirer un POP sans migrer les réglages utilisateur.
        let orphaned = selectIPerfServer(for: .us, location: paris)
        XCTAssertNotEqual(orphaned.hostname, "proof.ovh.us")
        XCTAssertEqual(orphaned.countryCode, "FR", "Repli attendu sur un POP proche de Paris")
        XCTAssertEqual(selectIPerfServer(for: .bytelLyoBbr, location: paris).hostname, "lyo.bbr.iperf.bytel.fr")
        XCTAssertEqual(selectIPerfServer(for: .bytelParisCubic, location: paris).portMin, 9_200)
        XCTAssertEqual(selectIPerfServer(for: .bytelParisCubic, location: paris).portMax, 9_240)
        // Auto / legacy → POP Paris proche (bytel ou Scaleway, pas 90 ms)
        let auto = selectIPerfServer(for: .hybridAuto, location: paris)
        XCTAssertTrue(
            auto.hostname.contains("bytel.fr") || auto.hostname == "ping.online.net"
                || auto.hostname == "iperf3.moji.fr",
            "Unexpected auto POP: \(auto.hostname)"
        )
        XCTAssertEqual(selectIPerfServer(for: .cloudflareR2, location: paris).hostname, auto.hostname)
        // Host bytel mort → migré Auto
        XCTAssertEqual(
            selectIPerfServer(for: .bytelPoiCubic, location: paris).hostname,
            auto.hostname
        )
    }

    func testIPerf3ResultAverageMbps() {
        let result = IPerf3Result(
            measuredBytes: 125_000_000, // 125 Mo
            clientBytes: 125_000_000,
            serverBytes: 124_000_000,
            measuredDuration: 10,
            wallDuration: 11
        )
        // 125e6 * 8 / 1e6 / 10 = 100 Mbps
        XCTAssertEqual(result.averageMbps, 100, accuracy: 0.01)
        XCTAssertEqual(result.duration, 10, accuracy: 0.001)
    }

    func testDownloadTargetPickerMetadata() {
        XCTAssertEqual(SpeedtestDownloadTarget.hybridAuto.displayName, "Auto")
        XCTAssertFalse(SpeedtestDownloadTarget.rbx.subtitle.isEmpty)
        // Auto + 4 OVH sains (Beauharnois ET Ashburn retirés) + 13 Bouygues sains
        // + 2 Scaleway + 1 MilkyWan + 7 POP iPerf3 FR/EU + 2 Amérique du Nord
        // + 1 Cloudflare + 1 LibreSpeed. Les 2 cibles Scaleway « +90 ms » (latence
        // artificielle, debug) ne sont pas proposées : 32 entrées.
        XCTAssertEqual(SpeedtestDownloadTarget.selectableCases.count, 32)
        XCTAssertEqual(SpeedtestDownloadTarget.ovhCases.count, 4)
        XCTAssertFalse(SpeedtestDownloadTarget.ovhCases.contains(.bhs))
        XCTAssertEqual(SpeedtestDownloadTarget.bhs.migrated, .hybridAuto)
        // `proof.ovh.us` ne répond plus sur AUCUN port de sa plage (handshake
        // vérifié le 2026-08-10). Il restait pourtant proposé, et son case pointait
        // toujours vers l'hôte mort : un utilisateur iOS pouvait le choisir et
        // attendre indéfiniment. Android le migrait déjà.
        XCTAssertFalse(SpeedtestDownloadTarget.ovhCases.contains(.us))
        XCTAssertEqual(SpeedtestDownloadTarget.us.migrated, .hybridAuto)
        // Ces deux POPs comblent le trou nord-américain. Ils n'existaient que dans
        // l'enum Android : iOS les reléguait dans « Catalogue » au lieu de leur
        // groupe, alors que les deux apps servent le même catalogue.
        XCTAssertEqual(SpeedtestDownloadTarget.publicAmericaCases.count, 2)
        XCTAssertEqual(SpeedtestDownloadTarget.clouviderAsh.regionLabel, "iPerf3 · Amérique du Nord")
        XCTAssertEqual(SpeedtestDownloadTarget.leasewebMtl.regionLabel, "iPerf3 · Amérique du Nord")
        XCTAssertEqual(SpeedtestDownloadTarget.bouyguesCases.count, 13)
        XCTAssertEqual(SpeedtestDownloadTarget.scalewayCases.count, 2)
        XCTAssertEqual(SpeedtestDownloadTarget.onlineNet90ms.migrated, .hybridAuto)
        XCTAssertEqual(SpeedtestDownloadTarget.onlineNet6_90ms.migrated, .hybridAuto)
        XCTAssertEqual(SpeedtestDownloadTarget.milkywanCases.count, 1)
        XCTAssertEqual(SpeedtestDownloadTarget.publicEuropeCases.count, 7)
        XCTAssertEqual(SpeedtestDownloadTarget.cloudflareCases.count, 1)
        XCTAssertFalse(SpeedtestDownloadTarget.bouyguesCases.contains(.bytelPoiCubic))
        XCTAssertEqual(SpeedtestDownloadTarget.bom.regionLabel, "OVH")
        XCTAssertEqual(SpeedtestDownloadTarget.bytelMrsBbr.regionLabel, "Bouygues Telecom")
        XCTAssertEqual(SpeedtestDownloadTarget.bytelRenCubic.displayName, "Rennes · CUBIC")
        XCTAssertEqual(SpeedtestDownloadTarget.onlineNet.regionLabel, "Scaleway")
        XCTAssertEqual(SpeedtestDownloadTarget.onlineNet.displayName, "Paris · Scaleway")
        XCTAssertEqual(SpeedtestDownloadTarget.milkywan.regionLabel, "MilkyWan")
        XCTAssertEqual(SpeedtestDownloadTarget.milkywan.displayName, "Croissy-Beaubourg")
        XCTAssertEqual(SpeedtestDownloadTarget.cloudflare.regionLabel, "Mondial")
        XCTAssertEqual(SpeedtestDownloadTarget.cloudflare.displayName, "Cloudflare")
        XCTAssertEqual(SpeedtestDownloadTarget.bytelPoiCubic.migrated, .hybridAuto)
        // Le nouveau case ne se confond pas avec le legacy CDN (migré Auto).
        XCTAssertEqual(SpeedtestDownloadTarget.cloudflare.migrated, .cloudflare)
        XCTAssertEqual(SpeedtestDownloadTarget.cloudflareR2.migrated, .hybridAuto)
    }

    /// Garde-fou : tout serveur sélectionnable doit être ATTEIGNABLE dans le
    /// sélecteur (ligne toujours visible ou accordéon d'un fournisseur).
    /// Sans ce test, un serveur ajouté au catalogue reste invisible dans l'UI.
    func testEverySelectableTargetIsReachableInPicker() {
        let grouped = SpeedtestDownloadTarget.pickerGroups.flatMap { $0.targets }
        let reachable = Set(SpeedtestDownloadTarget.ungroupedCases + grouped)
        XCTAssertEqual(
            reachable,
            Set(SpeedtestDownloadTarget.selectableCases),
            "Serveurs sélectionnables absents du sélecteur"
        )
        // Chaque groupe porte le regionLabel de ses cibles (accordéon cohérent).
        for group in SpeedtestDownloadTarget.pickerGroups {
            for target in group.targets {
                XCTAssertEqual(target.regionLabel, group.region)
            }
        }
    }

    func testMilkywanServerIsInCatalogWithPortRange() {
        let servers = iperfPublicServers.filter { $0.provider == .milkywan }
        XCTAssertEqual(servers.count, 1)
        guard let milkywan = servers.first else { return }
        XCTAssertEqual(milkywan.hostname, "speedtest.milkywan.fr")
        XCTAssertEqual(milkywan.portMin, 9_200)
        XCTAssertEqual(milkywan.portMax, 9_240)
        XCTAssertEqual(milkywan.countryCode, "FR")
        XCTAssertEqual(selectIPerfServer(for: .milkywan, location: nil).hostname, "speedtest.milkywan.fr")
    }

    /// L'edge Cloudflare refuse `__down` avec un 403 dès `bytes >= 1e8`
    /// (limite vérifiée en ligne). Une taille au-delà fait échouer TOUTES les
    /// requêtes du download → « serveurs injoignables » trompeur.
    func testCloudflareDownloadRequestStaysUnderEndpointCap() {
        XCTAssertLessThan(
            CloudflareSpeedtestConfig.downloadBytesPerRequest,
            CloudflareSpeedtestConfig.downloadMaxBytesPerRequest,
            "__down renvoie 403 au-delà du plafond de l'edge"
        )
        XCTAssertGreaterThan(CloudflareSpeedtestConfig.downloadBytesPerRequest, 10_000_000)
        // L'URL construite doit porter la taille exacte demandée.
        let url = CloudflareSpeedtestConfig.downURL(bytes: 90_000_000)
        XCTAssertEqual(url.absoluteString, "https://speed.cloudflare.com/__down?bytes=90000000")
        XCTAssertEqual(CloudflareSpeedtestConfig.downURL(bytes: 0).absoluteString, "https://speed.cloudflare.com/__down?bytes=0")
        // Pas de taille négative (bytes=-1 → 403).
        XCTAssertEqual(CloudflareSpeedtestConfig.downURL(bytes: -5).absoluteString, "https://speed.cloudflare.com/__down?bytes=0")
    }

    func testCloudflareTraceColoParsing() {
        let trace = """
        fl=123abc
        h=speed.cloudflare.com
        ip=2001:db8::1
        colo=cdg
        http=http/2
        """
        XCTAssertEqual(cloudflareParseColo(fromTrace: trace), "CDG")
        XCTAssertNil(cloudflareParseColo(fromTrace: "h=speed.cloudflare.com\nip=1.2.3.4"))
        XCTAssertNil(cloudflareParseColo(fromTrace: "colo=\nip=1.2.3.4"))
    }

    func testCloudflareServerNameMapsKnownColos() {
        XCTAssertEqual(cloudflareServerName(colo: "CDG"), "Cloudflare · Paris (CDG)")
        XCTAssertEqual(cloudflareServerName(colo: "yul"), "Cloudflare · Montréal (YUL)")
        XCTAssertEqual(cloudflareServerName(colo: "XXX"), "Cloudflare · XXX")
        XCTAssertEqual(cloudflareServerName(colo: nil), "Cloudflare · edge anycast")
    }

    func testBouyguesServersAreInCatalogWithPortRange() {
        let servers = iperfPublicServers.filter { $0.provider == .bouygues }
        XCTAssertEqual(servers.count, 13)
        for server in servers {
            XCTAssertEqual(server.portMin, 9_200)
            XCTAssertEqual(server.portMax, 9_240)
            XCTAssertTrue(server.hostname.hasSuffix("iperf.bytel.fr"))
        }
        XCTAssertNotNil(iperfPublicServers.first(where: { $0.hostname == "paris.bbr.iperf.bytel.fr" }))
        XCTAssertNotNil(iperfPublicServers.first(where: { $0.hostname == "ren.cubic.iperf.bytel.fr" }))
        XCTAssertNil(iperfPublicServers.first(where: { $0.hostname == "poi.cubic.iperf.bytel.fr" }))
    }

    func testScalewayServersAreInCatalogWithPortRange() {
        let servers = iperfPublicServers.filter { $0.provider == .scaleway }
        XCTAssertEqual(servers.count, 4)
        for server in servers {
            XCTAssertEqual(server.portMin, 5_200)
            XCTAssertEqual(server.portMax, 5_209)
        }
        XCTAssertEqual(selectIPerfServer(for: .onlineNet, location: nil).hostname, "ping.online.net")
        XCTAssertEqual(selectIPerfServer(for: .onlineNet6, location: nil).hostname, "ping6.online.net")
        let diagnostics = servers.filter { $0.syntheticLatencyMs > 0 }
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertTrue(diagnostics.allSatisfy { !$0.selectable && !$0.autoEligible })
        XCTAssertNil(selectableIPerfServer(for: .onlineNet90ms, location: nil))
        XCTAssertNil(selectableIPerfServer(for: .onlineNet6_90ms, location: nil))
    }

    func testIperfSiblingPortWrapsWithinRange() {
        XCTAssertEqual(iperfSiblingPort(preferred: 5_200, min: 5_200, max: 5_209), 5_201)
        XCTAssertEqual(iperfSiblingPort(preferred: 5_209, min: 5_200, max: 5_209), 5_200)
        XCTAssertEqual(iperfSiblingPort(preferred: 5_201, min: 5_201, max: 5_201), 5_201)
    }

    func testWidePortDiscoveryPrioritizesRealBouyguesNeighbors() {
        let discovered = iperfDiscoveryPorts(min: 9_200, max: 9_240, preferred: 9_201)
        XCTAssertLessThanOrEqual(discovered.count, 18)
        XCTAssertEqual(discovered.first, 9_200)
        XCTAssertEqual(discovered.last, 9_240)
        XCTAssertTrue(discovered.contains(9_202), "9202 était sauté par l'ancien stride")
        XCTAssertTrue(discovered.contains(9_204), "9204 était sauté par l'ancien stride")

        let siblings = iperfSiblingCandidatePorts(
            preferred: 9_201,
            min: 9_200,
            max: 9_240
        )
        XCTAssertFalse(siblings.contains(9_201))
        XCTAssertLessThanOrEqual(siblings.count, 17)
        XCTAssertTrue(siblings.contains(9_202))
        XCTAssertTrue(siblings.contains(9_204))
    }

    func testFirstIPerfControlStateTimeoutIsShorterThanTransferTimeout() {
        XCTAssertGreaterThan(iperfFirstControlStateTimeoutSeconds, 0)
        XCTAssertLessThanOrEqual(iperfFirstControlStateTimeoutSeconds, 3)
        XCTAssertGreaterThan(
            iperfSubsequentControlStateTimeoutSeconds,
            iperfFirstControlStateTimeoutSeconds
        )
    }

    /// La sonde de latence chargée vise le HAUT de la plage : le download part du bas
    /// et l'upload prend le voisin immédiat, donc le haut n'entre en concurrence avec
    /// aucun des deux — ni avec le port-walk.
    func testLoadedLatencyProbeTargetsTopOfRange() {
        XCTAssertEqual(
            iperfLoadedLatencyProbePort(avoiding: [5_201], min: 5_200, max: 5_209),
            5_209
        )
        // Le haut de plage est déjà pris : on descend d'un cran, jamais sur un actif.
        XCTAssertEqual(
            iperfLoadedLatencyProbePort(avoiding: [5_209], min: 5_200, max: 5_209),
            5_208
        )
        // Deux ports de données occupés pendant l'upload.
        XCTAssertEqual(
            iperfLoadedLatencyProbePort(avoiding: [5_209, 5_208], min: 5_200, max: 5_209),
            5_207
        )
    }

    /// Le cas qui motive tout le correctif : sur un POP mono-port, l'ancienne
    /// `iperfSiblingPort` renvoyait LE PORT DE DONNÉES ACTIF — la sonde ouvrait donc
    /// une connexion dessus et faisait tomber le démon en pleine mesure. Plusieurs
    /// POPs publics du catalogue n'exposent qu'un seul port : on renonce désormais à
    /// l'échantillon plutôt que de fausser latence ET débit.
    func testLoadedLatencyProbeGivesUpRatherThanHittingActivePort() {
        XCTAssertNil(iperfLoadedLatencyProbePort(avoiding: [5_201], min: 5_201, max: 5_201))
        // Plage à deux ports, tous deux occupés : rien de libre, on renonce.
        XCTAssertNil(
            iperfLoadedLatencyProbePort(avoiding: [5_200, 5_201], min: 5_200, max: 5_201)
        )
        // Comparaison directe avec l'ancien comportement, pour mémoire.
        XCTAssertEqual(iperfSiblingPort(preferred: 5_201, min: 5_201, max: 5_201), 5_201)
    }

    // MARK: Catalogue iPerf3 servi par l'API

    private func catalogServer(
        id: String = "pop_test",
        host: String = "iperf.example.net",
        provider: String = "clouvider",
        portMin: Int = 5_200,
        portMax: Int = 5_209,
        portPreferred: Int = 5_207,
        selectable: Bool? = true,
        autoEligible: Bool? = true,
        autoPenaltyKm: Double? = 0,
        ipVersion: String? = "ipv4",
        linkGbps: Double? = 10,
        syntheticLatencyMs: Int? = 0
    ) -> IPerfCatalogPayload.ServerDTO {
        IPerfCatalogPayload.ServerDTO(
            id: id, host: host, name: "POP de test", code: "TST",
            provider: provider, city: "Test", countryCode: "FR",
            lat: 48.8566, lon: 2.3522,
            portMin: portMin, portMax: portMax, portPreferred: portPreferred,
            selectable: selectable, autoEligible: autoEligible,
            autoPenaltyKm: autoPenaltyKm, ipVersion: ipVersion,
            linkGbps: linkGbps, syntheticLatencyMs: syntheticLatencyMs
        )
    }

    private func catalogPayload(
        schemaVersion: Int = 1,
        servers: [IPerfCatalogPayload.ServerDTO]
    ) -> IPerfCatalogPayload {
        IPerfCatalogPayload(
            schemaVersion: schemaVersion, revision: "abc123", ttlSeconds: 21_600,
            providers: [], servers: servers
        )
    }

    func testCatalogValidatorAcceptsWellFormedPayload() {
        let servers = IPerfCatalogValidator.validate(
            catalogPayload(servers: [catalogServer()])
        )
        XCTAssertEqual(servers?.count, 1)
        // Le port vérifié par handshake doit survivre au transport : c'est lui qui
        // évite de démarrer chaque test sur un port muet.
        XCTAssertEqual(servers?.first?.portPreferred, 5_207)
        XCTAssertEqual(servers?.first?.id, "pop_test")
        XCTAssertEqual(servers?.first?.selectable, true)
        XCTAssertEqual(servers?.first?.autoEligible, true)
        XCTAssertEqual(servers?.first?.ipVersion, .ipv4)
        XCTAssertEqual(servers?.first?.linkGbps, 10)
    }

    /// Un fournisseur que ce binaire ne connaît pas ne doit PAS faire disparaître le
    /// POP : pouvoir en introduire un côté serveur sans release est tout l'intérêt
    /// du catalogue distant.
    func testCatalogValidatorKeepsServersFromUnknownProvider() {
        let servers = IPerfCatalogValidator.validate(
            catalogPayload(servers: [catalogServer(provider: "un-hebergeur-inedit")])
        )
        XCTAssertEqual(servers?.count, 1)
        XCTAssertEqual(servers?.first?.provider, .community)
    }

    /// Une version de schéma plus récente est refusée en bloc plutôt que décodée au
    /// mieux : mieux vaut l'embarqué qu'une lecture approximative d'un format inconnu.
    func testCatalogValidatorRejectsFutureSchemaVersion() {
        XCTAssertNil(
            IPerfCatalogValidator.validate(
                catalogPayload(schemaVersion: 2, servers: [catalogServer()])
            )
        )
    }

    /// Le payload décrit des hôtes vers lesquels on ouvrira des sockets. Une plage de
    /// ports démesurée transformerait le port-walk en balayage de ports — ce qui
    /// ressemble à du scan vu du réseau de l'opérateur. Le rejet est EN BLOC : un
    /// catalogue à moitié appliqué serait indébogable.
    func testCatalogValidatorRejectsWholePayloadOnAbsurdPortRange() {
        let servers = IPerfCatalogValidator.validate(
            catalogPayload(servers: [
                catalogServer(id: "sain"),
                catalogServer(id: "aberrant", portMin: 1, portMax: 65_535, portPreferred: 1),
            ])
        )
        XCTAssertNil(servers, "un seul POP douteux doit invalider tout le catalogue")
    }

    func testCatalogValidatorRejectsMalformedHosts() {
        for host in ["iperf.example.net:5201", "http://iperf.example.net", "iperf example.net", ""] {
            XCTAssertNil(
                IPerfCatalogValidator.validate(catalogPayload(servers: [catalogServer(host: host)])),
                "hôte accepté à tort : \(host)"
            )
        }
    }

    func testCatalogValidatorRejectsInconsistentPreferredPort() {
        // Hors de [portMin, portMax] : le port-walk partirait hors plage.
        XCTAssertNil(
            IPerfCatalogValidator.validate(
                catalogPayload(servers: [catalogServer(portMin: 5_200, portMax: 5_209, portPreferred: 5_300)])
            )
        )
    }

    func testCatalogValidatorRejectsDuplicateIdsAndEmptyCatalog() {
        // Deux POPs de même id rendraient la préférence utilisateur ambiguë.
        XCTAssertNil(
            IPerfCatalogValidator.validate(
                catalogPayload(servers: [catalogServer(id: "doublon"), catalogServer(id: "doublon")])
            )
        )
        XCTAssertNil(IPerfCatalogValidator.validate(catalogPayload(servers: [])))
    }

    /// Le catalogue actif retombe sur l'embarqué quand rien n'a été chargé, et un
    /// catalogue vide ne doit jamais l'écraser — sans quoi l'app se retrouverait
    /// sans aucun serveur.
    func testActiveCatalogFallsBackToBundledAndIgnoresEmpty() {
        setActiveIPerfServers(nil)
        XCTAssertEqual(activeIPerfServers.count, iperfPublicServers.count)

        setActiveIPerfServers([])
        XCTAssertEqual(activeIPerfServers.count, iperfPublicServers.count, "un catalogue vide ne doit pas s'appliquer")

        let remote = IPerfCatalogValidator.validate(catalogPayload(servers: [catalogServer()]))
        setActiveIPerfServers(remote)
        XCTAssertEqual(activeIPerfServers.count, 1)
        XCTAssertEqual(activeIPerfServers.first?.id, "pop_test")

        // Ne pas laisser fuir l'état sur les autres tests.
        setActiveIPerfServers(nil)
    }

    /// Contrat client/serveur : ce JSON est un extrait EXACT de la réponse de
    /// production de `GET /api/speedtest/servers` (2026-08-10). Il verrouille deux
    /// choses : que le modèle décode le format réel, et qu'il tolère les champs
    /// qu'il ne connaît pas encore (`markets`, `zones`, `linkGbps`…) — le serveur
    /// doit pouvoir enrichir le payload sans casser les binaires déjà déployés.
    func testCatalogDecodesRealProductionPayload() throws {
        let json = """
        {
          "schemaVersion": 1,
          "revision": "bfa6aac78835",
          "ttlSeconds": 21600,
          "providers": [{ "key": "bouygues", "label": "Bouygues Telecom", "order": 10 }],
          "servers": [{
            "markets": [], "zones": [], "selectable": true, "autoEligible": true,
            "autoPenaltyKm": 0, "ipVersion": "ipv4", "linkGbps": 10, "syntheticLatencyMs": 0,
            "id": "clouvider_lon", "host": "lon.speedtest.clouvider.net",
            "name": "Londres (Clouvider)", "code": "LON-CLV", "provider": "clouvider",
            "city": "Londres", "countryCode": "GB", "lat": 51.5074, "lon": -0.1278,
            "portMin": 5200, "portMax": 5209, "portPreferred": 5207
          }]
        }
        """
        let payload = try JSONDecoder.signalQuest.decode(
            IPerfCatalogPayload.self, from: Data(json.utf8)
        )
        let servers = try XCTUnwrap(IPerfCatalogValidator.validate(payload))
        XCTAssertEqual(servers.count, 1)
        let lon = try XCTUnwrap(servers.first)
        XCTAssertEqual(lon.id, "clouvider_lon")
        XCTAssertEqual(lon.provider, .clouvider)
        // Le POP qui motive tout le lot : 5200-5206 sont MUETS, seul 5207 répond.
        // Sans ce port transporté jusqu'ici, l'app repart sur 5200 et conclut à tort
        // que le serveur est mort, puis bascule sur Cloudflare.
        XCTAssertEqual(lon.portPreferred, 5_207)
        XCTAssertEqual(lon.defaultPort, 5_207)
        XCTAssertEqual(lon.portMin, 5_200)
        XCTAssertEqual(lon.portMax, 5_209)
        XCTAssertTrue(lon.selectable)
        XCTAssertTrue(lon.autoEligible)
        XCTAssertEqual(lon.ipVersion, .ipv4)
        XCTAssertEqual(lon.linkGbps, 10)
        XCTAssertEqual(lon.syntheticLatencyMs, 0)
    }

    func testCatalogFlagsHideDiagnosticsAndExcludeManualOnlyServersFromAuto() throws {
        let servers = try XCTUnwrap(IPerfCatalogValidator.validate(catalogPayload(servers: [
            catalogServer(id: "automatic", host: "auto.example.net"),
            catalogServer(
                id: "manual_only", host: "manual.example.net",
                selectable: true, autoEligible: false
            ),
            catalogServer(
                id: "diag_90ms", host: "diag-90ms.example.net",
                selectable: false, autoEligible: false, syntheticLatencyMs: 90
            ),
        ])))

        XCTAssertEqual(servers.first { $0.id == "manual_only" }?.selectable, true)
        XCTAssertEqual(servers.first { $0.id == "manual_only" }?.autoEligible, false)
        XCTAssertEqual(servers.first { $0.id == "diag_90ms" }?.syntheticLatencyMs, 90)
        XCTAssertEqual(
            iperfServersSortedByDistance(from: nil, servers: servers).map(\.id),
            ["automatic"]
        )
        XCTAssertNil(selectableIPerfServer(
            for: .iperfCatalog,
            location: nil,
            catalogId: "diag_90ms",
            servers: servers
        ))
        XCTAssertEqual(selectableIPerfServer(
            for: .iperfCatalog,
            location: nil,
            catalogId: "manual_only",
            servers: servers
        )?.id, "manual_only")
    }

    func testLegacyCatalogInfersSyntheticAndIPv6Guards() throws {
        let json = """
        {
          "schemaVersion": 1, "revision": "legacy", "providers": [],
          "servers": [{
            "id": "online_net6_90ms", "host": "ping6-90ms.online.net",
            "name": "Diagnostic", "code": "D90", "provider": "scaleway",
            "city": "Paris", "countryCode": "fr", "lat": 48.8566, "lon": 2.3522,
            "portMin": 5200, "portMax": 5209, "portPreferred": 5201
          }]
        }
        """
        let payload = try JSONDecoder.signalQuest.decode(IPerfCatalogPayload.self, from: Data(json.utf8))
        let server = try XCTUnwrap(IPerfCatalogValidator.validate(payload)?.first)
        XCTAssertFalse(server.selectable)
        XCTAssertFalse(server.autoEligible)
        XCTAssertEqual(server.ipVersion, .ipv6)
        XCTAssertEqual(server.syntheticLatencyMs, 90)
        XCTAssertEqual(server.countryCode, "FR")
    }

    func testCatalogRejectsContradictorySafetyFlags() {
        XCTAssertNil(IPerfCatalogValidator.validate(catalogPayload(servers: [
            catalogServer(selectable: false, autoEligible: true),
        ])))
        XCTAssertNil(IPerfCatalogValidator.validate(catalogPayload(servers: [
            catalogServer(
                id: "diag_90ms", host: "diag-90ms.example.net",
                selectable: true, autoEligible: false, syntheticLatencyMs: 90
            ),
        ])))
        XCTAssertNil(IPerfCatalogValidator.validate(catalogPayload(servers: [
            catalogServer(ipVersion: "satellite"),
        ])))
    }

    func testAutoCandidateRankingUsesMeasuredLatencyAndStableFallbackOrder() throws {
        let servers = try XCTUnwrap(IPerfCatalogValidator.validate(catalogPayload(servers: [
            catalogServer(id: "first", host: "first.example.net"),
            catalogServer(id: "second", host: "second.example.net"),
            catalogServer(id: "third", host: "third.example.net"),
        ])))
        let ranked = rankIPerfLatencyCandidates([
            IPerfLatencyCandidate(server: servers[0], latencyMs: nil, sourceOrder: 0),
            IPerfLatencyCandidate(server: servers[1], latencyMs: 42, sourceOrder: 1),
            IPerfLatencyCandidate(server: servers[2], latencyMs: 12, sourceOrder: 2),
        ])
        XCTAssertEqual(ranked.map { $0.server.id }, ["third", "second", "first"])

        let tied = rankIPerfLatencyCandidates([
            IPerfLatencyCandidate(server: servers[1], latencyMs: 20, sourceOrder: 1),
            IPerfLatencyCandidate(server: servers[0], latencyMs: 20, sourceOrder: 0),
        ])
        XCTAssertEqual(tied.map { $0.server.id }, ["first", "second"])
    }

    func testIPerfEndpointCacheIncludesCatalogPortConfiguration() async {
        let cache = IPerfEndpointCache()
        let original = IPerfPublicServer(
            id: "original",
            hostname: "same-host.example.net",
            name: "Original",
            latitude: 0,
            longitude: 0,
            code: "ORG",
            countryCode: "FR",
            provider: .community,
            portMin: 5_200,
            portMax: 5_209,
            portPreferred: 5_207
        )
        let revised = IPerfPublicServer(
            id: "revised",
            hostname: original.hostname,
            name: "Revised",
            latitude: 0,
            longitude: 0,
            code: "REV",
            countryCode: "FR",
            provider: .community,
            portMin: 9_200,
            portMax: 9_240,
            portPreferred: 9_201
        )

        await cache.store(IPerfEndpoint(port: 5_207), for: original)

        let originalHit = await cache.cached(original)
        let revisedHit = await cache.cached(revised)
        XCTAssertEqual(originalHit.flatMap { $0 }?.port, 5_207)
        guard case .none = revisedHit else {
            XCTFail("une nouvelle plage de ports ne doit jamais réutiliser l'endpoint de l'ancienne révision")
            return
        }
    }

    func testRunSettingsRoundTripPreservesRemoteCatalogServerId() throws {
        let settings = SpeedtestRunSettings(
            downloadTarget: .iperfCatalog,
            durationSeconds: 14,
            streams: 16,
            reliabilityMode: true,
            iperfServerId: "goco_mtl"
        )
        let data = try JSONEncoder.signalQuest.encode(settings)
        let restored = try JSONDecoder.signalQuest.decode(SpeedtestRunSettings.self, from: data)
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.iperfServerId, "goco_mtl")
    }

    /// La propriété qui justifie tout le catalogue distant : un POP servi par l'API
    /// et ABSENT de l'enum doit être sélectionnable et résolu. Sans elle, ajouter un
    /// serveur côté serveur n'aurait aucun effet tant que l'app n'est pas mise à jour.
    func testCatalogOnlyServerIsSelectableWithoutAnEnumCase() {
        let unknownId = "pop_inedit_2026"
        XCTAssertNil(
            SpeedtestDownloadTarget(rawValue: unknownId),
            "ce test n'a de sens que si l'id est bien INCONNU de l'enum"
        )

        let remote = IPerfCatalogValidator.validate(
            catalogPayload(servers: [
                catalogServer(id: unknownId, host: "pop-inedit.example.net", provider: "un-nouvel-hebergeur"),
            ])
        )
        setActiveIPerfServers(remote)
        defer { setActiveIPerfServers(nil) }

        let resolved = selectIPerfServer(for: .iperfCatalog, location: nil, catalogId: unknownId)
        XCTAssertEqual(resolved.id, unknownId)
        XCTAssertEqual(resolved.hostname, "pop-inedit.example.net")
        XCTAssertEqual(resolved.provider, .community)
        XCTAssertEqual(resolved.portPreferred, 5_207)
    }

    /// Un id qui ne correspond à rien — catalogue pas encore chargé, ou POP retiré
    /// depuis que l'utilisateur l'a choisi — ne doit ni planter ni renvoyer un
    /// serveur arbitraire : on retombe sur le plus proche.
    func testCatalogTargetWithStaleIdFallsBackToClosest() {
        setActiveIPerfServers(nil)
        let paris = Coordinates(latitude: 48.8566, longitude: 2.3522)
        let resolved = selectIPerfServer(for: .iperfCatalog, location: paris, catalogId: "pop_disparu")
        XCTAssertEqual(resolved.countryCode, "FR", "repli attendu sur un POP proche de Paris")
    }

    // MARK: Méthodologie commune aux deux plateformes

    /// ⚠️ VECTEUR PARTAGÉ AVEC ANDROID. Le même tableau est vérifié dans
    /// `SpeedtestJitterMethodologyTest.kt` avec le même résultat attendu : c'est ce
    /// qui garantit que les gigues des deux apps sont comparables. Toute évolution
    /// de la formule doit toucher les deux côtés, sinon les agrégats mélangent des
    /// mesures qui ne veulent pas dire la même chose.
    func testJitterIsPopulationStandardDeviationLikeAndroid() {
        // moyenne = 20 ; variance = (100 + 0 + 100) / 3 ; σ = √66,666… ≈ 8,1650
        let jitter = try? XCTUnwrap(SpeedMetricCalculator.jitter([10, 20, 30]))
        XCTAssertEqual(jitter ?? 0, 8.16496580927726, accuracy: 1e-9)

        // Série constante : aucune variabilité.
        XCTAssertEqual(SpeedMetricCalculator.jitter([42, 42, 42, 42]) ?? -1, 0, accuracy: 1e-12)

        // Un seul échantillon ne permet aucune dispersion.
        XCTAssertNil(SpeedMetricCalculator.jitter([12]))
        XCTAssertNil(SpeedMetricCalculator.jitter([]))
    }

    /// L'écart-type ne dépend PAS de l'ordre des échantillons — c'est ce qui le rend
    /// robuste aux trous, alors que l'ancienne formule (moyenne des écarts
    /// consécutifs) changeait de résultat selon la place des valeurs manquantes.
    /// En 4G/5G, 10 à 30 % des échantillons expirent : ce n'est pas un cas limite.
    func testJitterIsIndependentOfSampleOrder() {
        let ordered = SpeedMetricCalculator.jitter([10, 20, 30, 40]) ?? 0
        let shuffled = SpeedMetricCalculator.jitter([40, 10, 30, 20]) ?? 0
        XCTAssertEqual(ordered, shuffled, accuracy: 1e-12)

        // L'ancienne formule IPDV, elle, donnait 10 sur la série ordonnée et 20 sur
        // la seconde : deux réseaux identiques auraient reçu deux gigues différentes.
        XCTAssertNotEqual(ordered, 10, accuracy: 1e-9)
    }

    func testConnectionResetIsRetryableIPerfError() {
        let reset = NWError.posix(.ECONNRESET)
        XCTAssertTrue(isRetryableIPerfTransportError(reset))
        XCTAssertTrue(isRetryableIPerfTransportError(IPerf3Error.accessDenied))
        XCTAssertFalse(isRetryableIPerfTransportError(IPerf3Error.invalidJSON))
    }
}
