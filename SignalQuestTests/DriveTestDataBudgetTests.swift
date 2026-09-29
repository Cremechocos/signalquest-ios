import XCTest
import CoreLocation
import MapKit
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

    /// MES-27 : passé 500 mesures, le nombre de points ne bouge plus, le dernier si.
    func testFullTrailStillRefreshesItsDiamonds() throws {
        func point() throws -> DriveSpeedtestPoint {
            let result = SpeedtestRunResult(label: "Drive Test", downloadMbps: 80,
                downloadAverageMbps: 80, downloadMaxMbps: 90, durationSeconds: 10,
                connectionType: .cellular, coordinate: Coordinates(latitude: 48.85, longitude: 2.35))
            return try XCTUnwrap(DriveSpeedtestPoint(result: result))
        }
        var trail = try (0..<500).map { _ in try point() }
        let before = DriveTestMapView.Coordinator.SpeedtestTrailSignature(trail)
        trail.removeFirst()
        trail.append(try point())
        XCTAssertEqual(trail.count, 500)
        XCTAssertNotEqual(DriveTestMapView.Coordinator.SpeedtestTrailSignature(trail), before)
    }

    func testUnlocatedSpeedtestCreatesNoMapPoint() {
        let result = SpeedtestRunResult(label: "Drive Test", downloadMbps: 80,
            downloadAverageMbps: 80, downloadMaxMbps: 90, durationSeconds: 10,
            connectionType: .cellular)
        XCTAssertNil(DriveSpeedtestPoint(result: result))
    }

    func testLostGpsDoesNotStartUnlimitedSpeedtests() {
        func decide(count: Int, seconds: Int) -> DriveTestCadence.Decision {
            DriveTestCadence.decide(testCount: count, secondsSinceLastTest: seconds, metersMoved: nil,
                                    stationarySeconds: nil, intervalMeters: 500)
        }
        XCTAssertEqual(decide(count: 0, seconds: 0), .testNow)
        XCTAssertEqual(decide(count: 1, seconds: 0), .waitForTime(secondsRemaining: 30))
        XCTAssertEqual(decide(count: 1, seconds: 29), .waitForTime(secondsRemaining: 1))
        XCTAssertEqual(decide(count: 1, seconds: 30), .testNow)
    }

    func testStandingStillNoLongerTestsEveryThirtySecondsAndPauses() {
        // Position connue, pas de déplacement : plus aucune mesure au temps (MES-03).
        XCTAssertEqual(DriveTestCadence.decide(testCount: 3, secondsSinceLastTest: 600, metersMoved: 10,
                                               stationarySeconds: 120, intervalMeters: 500),
                       .waitForDistance(metersRemaining: 490))
        XCTAssertEqual(DriveTestCadence.decide(testCount: 3, secondsSinceLastTest: 600, metersMoved: 10,
                                               stationarySeconds: 180, intervalMeters: 500),
                       .pausedStationary)
    }

    func testDistanceTriggersWithAMinimumSpacing() {
        XCTAssertEqual(DriveTestCadence.decide(testCount: 3, secondsSinceLastTest: 12, metersMoved: 600,
                                               stationarySeconds: 0, intervalMeters: 500),
                       .waitForSpacing(secondsRemaining: 8))
        XCTAssertEqual(DriveTestCadence.decide(testCount: 3, secondsSinceLastTest: 20, metersMoved: 600,
                                               stationarySeconds: 0, intervalMeters: 500),
                       .testNow)
    }

    func testStationaryAnchorFollowsMovementAndMeasuresStillness() {
        func fix(_ latitude: Double, _ seconds: TimeInterval) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 5.0), altitude: 0,
                       horizontalAccuracy: 10, verticalAccuracy: -1,
                       timestamp: Date(timeIntervalSince1970: 1_000 + seconds))
        }
        var anchor = DriveTestCadence.StationaryAnchor()
        XCTAssertNil(anchor.stationarySeconds(now: Date(timeIntervalSince1970: 1_000)))
        anchor.update(with: fix(45.0, 0))
        // Dérive d'une vingtaine de mètres : l'ancre ne bouge pas.
        anchor.update(with: fix(45.00018, 60))
        XCTAssertEqual(anchor.stationarySeconds(now: Date(timeIntervalSince1970: 1_200)), 200)
        // Cent mètres plus loin : l'ancre suit, l'arrêt repart de zéro.
        anchor.update(with: fix(45.0009, 210))
        XCTAssertEqual(anchor.stationarySeconds(now: Date(timeIntervalSince1970: 1_215)), 5)
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
        model.recordResolvedOperator(market: "FR", operatorKey: "SFR",
            source: .internetAccess, label: "SFR") // ancien accès
        let measured = SpeedtestRunResult(label: "Drive Test", downloadMbps: 80,
            downloadAverageMbps: 80, downloadMaxMbps: 90, durationSeconds: 10,
            connectionType: .cellular, networkOperatorName: "Bouygues",
            simPlmn: "20801", marketCode: "FR", operatorKey: "BOUYGUES")
        XCTAssertTrue(model.reconcileOperatorFromSpeedtest(measured,
            currentConnection: .cellular, viaVPN: false),
            "ASN B doit remplacer l'ancien ASN sans changement de connexion ni de SIM")
        XCTAssertEqual(model.displayedOperatorKey, "BOUYGUES")
        XCTAssertEqual(SpeedtestSubmission.iosPayload(from: measured, streams: 4,
            deviceModel: "iPhone").operatorKey, "BOUYGUES")
        XCTAssertFalse(model.observeOperatorContext(connection: .cellular, viaVPN: false))
        XCTAssertEqual(model.displayedOperatorKey, "BOUYGUES")

        let unconfirmed = SpeedtestRunResult(label: "Drive Test", downloadMbps: 70,
            downloadAverageMbps: 70, downloadMaxMbps: 75, durationSeconds: 10,
            connectionType: .cellular, simPlmn: "20801")
        XCTAssertTrue(model.reconcileOperatorFromSpeedtest(unconfirmed,
            currentConnection: .cellular, viaVPN: false))
        XCTAssertNil(model.displayedOperatorKey,
            "Un ASN indisponible ne doit pas conserver l'ancien ni reprendre le filtre ORANGE")
        model.recordResolvedOperator(market: "FR", operatorKey: "BOUYGUES",
            source: .sim, label: "Bouygues") // seul PLMN SIM disponible

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

final class DriveTestTraceTests: XCTestCase {
    func testLongSessionKeepsBothEndsAndMajorTurnWithinMapLimit() {
        var trace: [CLLocationCoordinate2D] = []
        let corner = CLLocationCoordinate2D(latitude: 48.95, longitude: 2.38)
        let coordinates = (0..<1_201).map { index -> CLLocationCoordinate2D in
            if index == 300 { return corner }
            return CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35 + Double(index) * 0.0001)
        }

        for coordinate in coordinates {
            DriveTraceSampler.append(coordinate, to: &trace, maxPoints: 600)
            XCTAssertLessThanOrEqual(trace.count, 600)
        }

        XCTAssertEqual(trace.first?.longitude, coordinates.first?.longitude)
        XCTAssertEqual(trace.last?.longitude, coordinates.last?.longitude)
        XCTAssertTrue(trace.contains { $0.latitude == corner.latitude && $0.longitude == corner.longitude })
        XCTAssertTrue(trace.contains { $0.longitude < 2.40 && $0.longitude > 2.35 },
            "Le parcours ancien ne doit pas disparaître lorsque la limite est atteinte")
    }

    @MainActor
    func testMapRedrawsLatestPositionWhenTraceCountStaysAtLimit() throws {
        let map = MKMapView(frame: .zero)
        let coordinator = DriveTestMapView.Coordinator(onSelectSite: { _ in }, onSelectSpeedtest: { _ in })
        var trace = (0..<600).map {
            CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35 + Double($0) * 0.0001)
        }
        func sync() {
            coordinator.sync(antennas: [], trace: trace, speedtestTrail: [],
                highlightedSiteId: nil, userLocation: nil, operatorPalette: [:], displayedKey: nil, on: map)
        }

        sync()
        let firstLine = try XCTUnwrap(map.overlays.compactMap { $0 as? MKPolyline }.first)
        let next = CLLocationCoordinate2D(latitude: 48.86, longitude: 2.42)
        DriveTraceSampler.append(next, to: &trace, maxPoints: 600)
        XCTAssertEqual(trace.count, 600)
        sync()

        let currentLine = try XCTUnwrap(map.overlays.compactMap { $0 as? MKPolyline }.first)
        XCTAssertFalse(firstLine === currentLine)
        var last = CLLocationCoordinate2D()
        currentLine.getCoordinates(&last, range: NSRange(location: currentLine.pointCount - 1, length: 1))
        XCTAssertEqual(last.latitude, next.latitude, accuracy: 0.0000001)
        XCTAssertEqual(last.longitude, next.longitude, accuracy: 0.0000001)
    }
}
