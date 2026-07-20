import XCTest
import CoreTelephony
import Network
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

        // Montréal → Beauharnois OVH
        let montreal = Coordinates(latitude: 45.5017, longitude: -73.5673)
        let bhs = findClosestIPerfServer(to: montreal)
        XCTAssertEqual(bhs.hostname, "bhs.proof.ovh.ca")

        // New York → US proof
        let nyc = Coordinates(latitude: 40.7128, longitude: -74.0060)
        let us = findClosestIPerfServer(to: nyc)
        XCTAssertEqual(us.hostname, "proof.ovh.us")

        // Mumbai → YNM
        let mumbai = Coordinates(latitude: 19.0760, longitude: 72.8777)
        let ynm = findClosestIPerfServer(to: mumbai)
        XCTAssertEqual(ynm.hostname, "bom.proof.ovh.net")
    }

    func testAutoDeprioritizesThrottledOVHWhenNonOVHPOPReachable() {
        // Roubaix : OVH RBX est à ~10 km, mais OVH bride son egress (débit DL
        // fortement sous-évalué) → en mode Auto on préfère un POP non-OVH
        // (Bouygues/MilkyWan/Scaleway) malgré la distance supérieure.
        let roubaix = Coordinates(latitude: 50.6942, longitude: 3.1746)
        let autoNearRBX = findClosestIPerfServer(to: roubaix)
        XCTAssertNotEqual(
            autoNearRBX.provider, .ovh,
            "Auto ne doit pas retomber sur OVH (throttle egress) près de Roubaix : \(autoNearRBX.hostname)"
        )
        // Mais un choix MANUEL d'un serveur OVH reste honoré tel quel.
        XCTAssertEqual(selectIPerfServer(for: .rbx, location: roubaix).hostname, "rbx.proof.ovh.net")
        // Et hors zone de POP non-OVH (Montréal), OVH reste l'iPerf3 le plus proche.
        let montreal = Coordinates(latitude: 45.5017, longitude: -73.5673)
        XCTAssertEqual(findClosestIPerfServer(to: montreal).provider, .ovh)
    }

    func testPublicEuropeIPerf3ServersCatalogAndSelection() {
        let paris = Coordinates(latitude: 48.8566, longitude: 2.3522)
        // Sélection manuelle mappée sur le bon hôte.
        XCTAssertEqual(selectIPerfServer(for: .mojiParis, location: paris).hostname, "iperf3.moji.fr")
        XCTAssertEqual(selectIPerfServer(for: .clouviderFra, location: paris).hostname, "fra.speedtest.clouvider.net")
        XCTAssertEqual(selectIPerfServer(for: .clouviderAms, location: paris).hostname, "ams.speedtest.clouvider.net")
        XCTAssertEqual(selectIPerfServer(for: .leasewebFra, location: paris).hostname, "speedtest.fra1.de.leaseweb.net")
        XCTAssertEqual(selectIPerfServer(for: .init7, location: paris).hostname, "speedtest.init7.net")
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
        XCTAssertEqual(selectIPerfServer(for: .us, location: paris).hostname, "proof.ovh.us")
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
        // Auto + 6 OVH + 13 Bouygues sains + 2 Scaleway + 1 MilkyWan + 7 POP
        // iPerf3 FR/EU publics + 1 Cloudflare + 1 LibreSpeed. Les 2 cibles Scaleway
        // « +90 ms » (latence artificielle, debug) ne sont pas proposées : 32 entrées.
        XCTAssertEqual(SpeedtestDownloadTarget.selectableCases.count, 32)
        XCTAssertEqual(SpeedtestDownloadTarget.ovhCases.count, 6)
        XCTAssertEqual(SpeedtestDownloadTarget.bouyguesCases.count, 13)
        XCTAssertEqual(SpeedtestDownloadTarget.scalewayCases.count, 2)
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
        XCTAssertEqual(selectIPerfServer(for: .onlineNet90ms, location: nil).hostname, "ping-90ms.online.net")
        XCTAssertEqual(selectIPerfServer(for: .onlineNet6_90ms, location: nil).hostname, "ping6-90ms.online.net")
    }

    func testIperfSiblingPortWrapsWithinRange() {
        XCTAssertEqual(iperfSiblingPort(preferred: 5_200, min: 5_200, max: 5_209), 5_201)
        XCTAssertEqual(iperfSiblingPort(preferred: 5_209, min: 5_200, max: 5_209), 5_200)
        XCTAssertEqual(iperfSiblingPort(preferred: 5_201, min: 5_201, max: 5_201), 5_201)
    }

    func testConnectionResetIsRetryableIPerfError() {
        let reset = NWError.posix(.ECONNRESET)
        XCTAssertTrue(isRetryableIPerfTransportError(reset))
        XCTAssertTrue(isRetryableIPerfTransportError(IPerf3Error.accessDenied))
        XCTAssertFalse(isRetryableIPerfTransportError(IPerf3Error.invalidJSON))
    }
}
