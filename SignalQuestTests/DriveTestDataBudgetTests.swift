import XCTest
@testable import SignalQuest

/// Compteur de données d'un Drive Test.
///
/// Le plafond ne vaut que ce que vaut le compteur : s'il sous-estime, la session
/// dépasse le forfait ; s'il double-compte, elle s'arrête pour rien. Les moteurs
/// passent des TOTAUX CUMULÉS à l'échantillonneur, jamais des deltas — l'erreur
/// naturelle serait de les additionner tels quels.
final class DriveTestDataBudgetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SpeedtestDataMeter.shared.reset()
    }

    override func tearDown() {
        SpeedtestDataMeter.shared.reset()
        super.tearDown()
    }

    /// Un échantillonneur reçoit une suite croissante : le compteur doit retenir
    /// le DERNIER total, pas leur somme.
    func testCumulativeTotalsAreNotSummed() {
        let sampler = SpeedtestLiveSampler()
        for (index, total) in [1_000, 5_000, 20_000, 50_000].enumerated() {
            _ = sampler.observe(totalBytes: total, elapsedMs: Double((index + 1) * 200))
        }
        XCTAssertEqual(
            SpeedtestDataMeter.shared.bytes, 50_000,
            "Les totaux cumulés ont été additionnés au lieu d'être dérivés"
        )
    }

    /// Deux phases (descendant puis montant) = deux échantillonneurs, chacun
    /// repartant de zéro. Les volumes doivent s'ajouter.
    func testPhasesAccumulate() {
        let download = SpeedtestLiveSampler()
        let upload = SpeedtestLiveSampler()
        _ = download.observe(totalBytes: 300_000, elapsedMs: 500)
        _ = download.observe(totalBytes: 900_000, elapsedMs: 1_000)
        _ = upload.observe(totalBytes: 100_000, elapsedMs: 1_500)
        _ = upload.observe(totalBytes: 250_000, elapsedMs: 2_000)
        XCTAssertEqual(SpeedtestDataMeter.shared.bytes, 1_150_000)
    }

    /// Les tout premiers ticks sortent tôt de `observe` (moins de deux points) :
    /// leurs octets ne doivent pas pour autant échapper au comptage.
    func testFirstTickIsCounted() {
        let sampler = SpeedtestLiveSampler()
        _ = sampler.observe(totalBytes: 42_000, elapsedMs: 100)
        XCTAssertEqual(SpeedtestDataMeter.shared.bytes, 42_000)
    }

    /// Un total qui régresse (remise à zéro d'un compteur amont) ne doit jamais
    /// retrancher du volume déjà consommé.
    func testRegressionDoesNotSubtract() {
        let sampler = SpeedtestLiveSampler()
        _ = sampler.observe(totalBytes: 800_000, elapsedMs: 500)
        _ = sampler.observe(totalBytes: 10_000, elapsedMs: 1_000)
        XCTAssertEqual(
            SpeedtestDataMeter.shared.bytes, 800_000,
            "Une régression du total a fait DIMINUER le volume consommé"
        )
    }

    func testResetClearsSession() {
        let sampler = SpeedtestLiveSampler()
        _ = sampler.observe(totalBytes: 1_000_000, elapsedMs: 500)
        SpeedtestDataMeter.shared.reset()
        XCTAssertEqual(SpeedtestDataMeter.shared.bytes, 0)
    }

    /// Le volume affiché doit rester lisible : on vérifie la présence de l'unité
    /// et du chiffre, pas un libellé figé (il suit la langue de l'appareil).
    func testFormattedBytesIsReadable() {
        let small = DriveTestViewModel.formattedBytes(45_000_000)
        let large = DriveTestViewModel.formattedBytes(5_400_000_000)
        XCTAssertTrue(small.contains("45"), "Volume illisible : « \(small) »")
        XCTAssertTrue(large.contains("5"), "Volume illisible : « \(large) »")
        XCTAssertNotEqual(small, large)
        XCTAssertFalse(DriveTestViewModel.formattedBytes(-1).isEmpty, "Un volume négatif ne doit pas produire du vide")
    }

    func testMovingDeviceDoesNotRelocateTheMeasuredSpeedtest() throws {
        let measuredFix = Coordinates(latitude: 48.8566, longitude: 2.3522,
            accuracy: 8, observedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let laterFix = Coordinates(latitude: 48.8666, longitude: 2.3622)
        let result = SpeedtestRunResult(label: "Drive Test", downloadMbps: 80,
            downloadAverageMbps: 80, downloadMaxMbps: 90, durationSeconds: 10,
            connectionType: .cellular, coordinate: measuredFix)
            .withDriveTestContext(runID: UUID())

        let point = try XCTUnwrap(DriveSpeedtestPoint(result: result))
        let payload = SpeedtestSubmission.iosPayload(from: result, streams: 4, deviceModel: "iPhone")
        XCTAssertEqual(point.id, result.id)
        XCTAssertEqual(point.coordinate.latitude, measuredFix.latitude)
        XCTAssertEqual(point.coordinate.longitude, measuredFix.longitude)
        XCTAssertEqual(payload.coordinates, measuredFix)
        XCTAssertNotEqual(point.coordinate.latitude, laterFix.latitude)
        XCTAssertEqual(point.result.coordinate, result.coordinate)
        XCTAssertEqual(point.result.runOrigin, "drive_test")

        let restored = try JSONDecoder().decode(SpeedtestRunResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(restored.coordinate?.latitude, point.coordinate.latitude)
        XCTAssertEqual(restored.coordinate?.longitude, point.coordinate.longitude)
        XCTAssertEqual(SpeedtestSubmission.iosPayload(from: restored, streams: 4,
            deviceModel: "iPhone").coordinates, restored.coordinate)
    }

    func testUnlocatedSpeedtestCreatesNoMapPoint() {
        let result = SpeedtestRunResult(label: "Drive Test", downloadMbps: 80,
            downloadAverageMbps: 80, downloadMaxMbps: 90, durationSeconds: 10,
            connectionType: .cellular)
        XCTAssertNil(DriveSpeedtestPoint(result: result))
    }

    func testLostGpsDoesNotStartUnlimitedSpeedtests() {
        XCTAssertTrue(DriveTestViewModel.isAutomaticTestDue(testCount: 0, secondsWaited: 0, metersMoved: nil,
                          intervalMeters: 500, maxSeconds: 30))
        XCTAssertFalse(DriveTestViewModel.isAutomaticTestDue(testCount: 1, secondsWaited: 0, metersMoved: nil,
                           intervalMeters: 500, maxSeconds: 30))
        XCTAssertFalse(DriveTestViewModel.isAutomaticTestDue(testCount: 1, secondsWaited: 29, metersMoved: nil,
                           intervalMeters: 500, maxSeconds: 30))
        XCTAssertTrue(DriveTestViewModel.isAutomaticTestDue(testCount: 1, secondsWaited: 30, metersMoved: nil,
                          intervalMeters: 500, maxSeconds: 30))
        XCTAssertTrue(DriveTestViewModel.isAutomaticTestDue(testCount: 1, secondsWaited: 0, metersMoved: 500,
                          intervalMeters: 500, maxSeconds: 30))
    }

    @MainActor
    func testMapFilterNeverBecomesDetectedOperatorAfterNetworkOrVPNChange() {
        let defaults = UserDefaults.standard
        let previousMarket = defaults.object(forKey: MapMarketStore.marketKey)
        let previousOperator = defaults.object(forKey: MapMarketStore.operatorKey)
        defer {
            if let previousMarket { defaults.set(previousMarket, forKey: MapMarketStore.marketKey) }
            else { defaults.removeObject(forKey: MapMarketStore.marketKey) }
            if let previousOperator { defaults.set(previousOperator, forKey: MapMarketStore.operatorKey) }
            else { defaults.removeObject(forKey: MapMarketStore.operatorKey) }
        }
        MapMarketStore.save(market: "FR", operator: "ORANGE") // filtre de consultation A

        let model = DriveTestViewModel(services: AppServices(config: .test))
        XCTAssertTrue(model.observeOperatorContext(connection: .cellular, viaVPN: false))
        model.recordResolvedOperator(market: "FR", operatorKey: "BOUYGUES",
            source: .internetAccess, label: "Bouygues") // accès détecté B
        XCTAssertEqual(model.displayedOperatorKey, "BOUYGUES")
        XCTAssertFalse(model.observeOperatorContext(connection: .cellular, viaVPN: false))
        XCTAssertEqual(model.displayedOperatorKey, "BOUYGUES")

        XCTAssertTrue(model.observeOperatorContext(connection: .cellular, viaVPN: true))
        XCTAssertNil(model.displayedOperatorKey, "Le filtre ORANGE ne doit pas remplacer l'accès devenu inconnu")
        XCTAssertNil(model.operatorSource)
        model.recordResolvedOperator(market: "FR", operatorKey: "BOUYGUES",
            source: .sim, label: "Bouygues") // seul PLMN SIM disponible
        XCTAssertEqual(model.displayedOperatorKey, "BOUYGUES")

        XCTAssertTrue(model.observeOperatorContext(connection: .wifi, viaVPN: true))
        XCTAssertNil(model.displayedOperatorKey)
        XCTAssertNil(model.operatorSource)
        XCTAssertTrue(model.observeOperatorContext(connection: .cellular, viaVPN: false))
        XCTAssertNil(model.displayedOperatorKey, "Une reprise cellulaire exige une nouvelle attribution")
    }
}
