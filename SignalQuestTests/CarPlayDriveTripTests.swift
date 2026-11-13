import CarPlay
import XCTest
@testable import SignalQuest

/// Verrouille l'onglet Trajet CarPlay (lot 4, choix d'Alexandre du 13/11) :
/// une pression pour démarrer, un avertissement qui ne bloque pas, un blocage
/// qui remplace le bouton par une raison neutre, et pendant le trajet la durée
/// puis six valeurs toujours à la même place.
@MainActor
final class CarPlayDriveTripTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func running(completedTests: Int = 2, lastDownload: Double? = 187.4,
                         warnings: [DriveTestPreflightIssue] = [],
                         isPaused: Bool = false) -> DriveTripTemplateBuilder.Running {
        .init(startedAt: now.addingTimeInterval(-12 * 60), isPaused: isPaused, distanceMeters: 4_200,
              completedTests: completedTests, lastDownloadMbps: lastDownload, network: "Bouygues 5G",
              weakZones: 1, status: "Prochain test dans 300 m", warnings: warnings)
    }

    private func issue(_ id: DriveTestPreflightIssue.ID, _ severity: DriveTestPreflightIssue.Severity,
                       value: Int? = nil) -> DriveTestPreflightIssue {
        DriveTestPreflightIssue(id: id, severity: severity, action: .none, value: value)
    }

    // MARK: - Au repos

    /// Une seule pression lance le trajet : pas de réglage, pas de saisie.
    func testRestOffersASingleStartButton() {
        let template = DriveTripTemplateBuilder.make(state: .idle(lastTrip: nil, notice: nil),
                                                     actions: .init(start: {}, stop: {}))
        XCTAssertEqual(template.actions.map(\.title), [String(localized: "Démarrer")])
        XCTAssertEqual(template.title, String(localized: "Trajet"))
        XCTAssertEqual(template.items.count, 1, "sans trajet passé, une phrase dit ce que fait l'onglet")
        let detail = template.items[0].detail ?? ""
        XCTAssertFalse(detail.isEmpty)
        // Deux lignes d'une vingtaine de caractères en taille Minimum (13/11).
        XCTAssertLessThanOrEqual(detail.count, 40, detail)
    }

    /// Le dernier trajet se relit avec sa date en titre.
    func testLastTripCarriesItsDateAndItsFigures() {
        let recap = DriveTestViewModel.SessionRecap(
            endedAt: now.addingTimeInterval(-2 * 3_600), distanceMeters: 18_400, testCount: 9, bytes: 0,
            stoppedByDataCap: false, vpnActive: false,
            startedAt: now.addingTimeInterval(-2 * 3_600 - 1_500), averageDownloadMbps: 96)
        let state = DriveTripTemplateBuilder.State.idle(lastTrip: recap, notice: nil)

        let when = SpeedtestTemplateBuilder.relativeDate(recap.endedAt, now: now)
        XCTAssertEqual(DriveTripTemplateBuilder.title(for: state, now: now),
                       String(localized: "Dernier trajet · \(when)"))
        XCTAssertEqual(DriveTripTemplateBuilder.items(for: state).map(\.title),
                       [String(localized: "Distance"), String(localized: "Durée"),
                        String(localized: "Tests"), String(localized: "Débit moyen")])
    }

    /// Un départ refusé à l'instant (un speedtest mesure déjà) dit pourquoi,
    /// en tête, sans retirer le bouton : la cause est passagère.
    func testRefusedStartExplainsAndKeepsTheButton() {
        let template = DriveTripTemplateBuilder.make(
            state: .idle(lastTrip: nil, notice: "Un speedtest est déjà en cours."),
            actions: .init(start: {}, stop: {}))
        XCTAssertEqual(template.items.first?.title, String(localized: "Impossible de démarrer"))
        XCTAssertEqual(template.items.first?.detail, "Un speedtest est déjà en cours.")
        XCTAssertEqual(template.actions.count, 1)
    }

    // MARK: - Blocages

    /// Un vrai blocage remplace le bouton par sa raison, sans consigne :
    /// l'écran du véhicule ne renvoie pas le conducteur sur son iPhone.
    func testBlockedReplacesTheButtonWithANeutralReason() {
        let cases: [DriveTestPreflightIssue] = [issue(.locationPermission, .blocking),
                                                issue(.storage, .blocking, value: 80),
                                                issue(.connectivity, .blocking)]
        for blocking in cases {
            let template = DriveTripTemplateBuilder.make(state: .blocked(.preflight(blocking)),
                                                         actions: .init(start: {}, stop: {}))
            XCTAssertTrue(template.actions.isEmpty, "\(blocking.id)")
            XCTAssertEqual(template.items.count, 1)
            let text = [template.items[0].title, template.items[0].detail].compactMap { $0 }.joined(separator: " ")
            XCTAssertFalse(text.localizedCaseInsensitiveContains("iPhone"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("Réglages"), text)
        }
        XCTAssertTrue(DriveTestHandsFreeStart.reason(.preflight(issue(.storage, .blocking, value: 80)))
            .detail.contains("80"))
    }

    // MARK: - En roulant

    /// La durée en titre, puis les six valeurs de la maquette, et « Arrêter ».
    func testRunningShowsDurationSixValuesAndAStopButton() {
        let state = DriveTripTemplateBuilder.State.running(running())
        let template = DriveTripTemplateBuilder.make(state: state, actions: .init(start: {}, stop: {}), now: now)

        let elapsed = DriveTripTemplateBuilder.duration(12 * 60)
        XCTAssertEqual(template.title, String(localized: "En cours · \(elapsed)"))
        XCTAssertTrue(elapsed.contains("12"), elapsed)
        XCTAssertEqual(template.items.map(\.title),
                       [String(localized: "Distance"), String(localized: "Tests"), String(localized: "Dernier débit"),
                        String(localized: "Réseau"), String(localized: "Zones faibles"), String(localized: "État")])
        XCTAssertEqual(template.items[1].detail, "2")
        XCTAssertEqual(template.items[2].detail, SpeedtestTemplateBuilder.mbps(187.4))
        XCTAssertEqual(template.items[5].detail, "Prochain test dans 300 m")
        XCTAssertEqual(template.actions.map(\.title), [String(localized: "Arrêter")])
    }

    func testPausedTripSaysSoInTheTitle() {
        let title = DriveTripTemplateBuilder.title(for: .running(running(isPaused: true)), now: now)
        XCTAssertEqual(title, String(localized: "En pause · \(DriveTripTemplateBuilder.duration(12 * 60))"))
    }

    /// Une valeur encore inconnue garde sa place : les rangées ne sautent pas
    /// quand le premier test aboutit.
    func testUnknownValuesKeepTheirPlace() {
        var first = running(completedTests: 0, lastDownload: nil)
        first.network = nil
        let items = DriveTripTemplateBuilder.runningItems(first)
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items[2].detail, "—")
        XCTAssertEqual(items[3].detail, "—")
    }

    /// Un avertissement du départ (batterie, GPS) s'affiche sans bloquer, et
    /// s'efface au premier test réussi. Le Wi-Fi n'en est pas un : l'état
    /// « En pause — Wi-Fi détecté » le dit déjà.
    func testStartWarningsShowUntilTheFirstTest() {
        let warnings = [issue(.battery, .warning, value: 12), issue(.wifi, .warning)]
        let before = DriveTripTemplateBuilder.runningItems(running(completedTests: 0, warnings: warnings))
        XCTAssertEqual(before.last?.title, String(localized: "Attention"))
        XCTAssertEqual(before.last?.detail, String(localized: "Batterie faible"))

        let after = DriveTripTemplateBuilder.runningItems(running(completedTests: 1, warnings: warnings))
        XCTAssertEqual(after.count, 6)

        let wifiOnly = DriveTripTemplateBuilder.runningItems(running(completedTests: 0,
                                                                     warnings: [issue(.wifi, .warning)]))
        XCTAssertEqual(wifiOnly.count, 6)
    }

    func testBusiestStateStaysWithinCarPlayLimits() {
        let warnings = [issue(.gpsFix, .warning), issue(.battery, .warning, value: 10),
                        issue(.storage, .warning, value: 150), issue(.constrainedNetwork, .warning)]
        let template = DriveTripTemplateBuilder.make(state: .running(running(completedTests: 0, warnings: warnings)),
                                                     actions: .init(start: {}, stop: {}))
        XCTAssertLessThanOrEqual(template.items.count, CarPlayDetailTemplateBuilder.maxItems)
        XCTAssertLessThanOrEqual(template.actions.count, 3)
    }

    /// Même format que l'onglet Speedtest : nom court et génération, ou Wi-Fi.
    func testNetworkReadsShortCarrierAndGenerationOrWiFi() {
        XCTAssertEqual(DriveTripTemplateBuilder.networkLabel(connection: .cellular, operatorLabel: "Bouygues Telecom",
                                                             technology: .fiveGNSA), "Bouygues 5G")
        XCTAssertEqual(DriveTripTemplateBuilder.networkLabel(connection: .wifi, operatorLabel: "Orange",
                                                             technology: .fourG), "Wi-Fi")
        XCTAssertNil(DriveTripTemplateBuilder.networkLabel(connection: .other, operatorLabel: nil, technology: nil))
    }

    /// La seconde ne se lit pas en conduisant ; au-delà d'une heure, les heures.
    func testDurationIsInMinutesThenHours() {
        XCTAssertFalse(DriveTripTemplateBuilder.duration(12 * 60 + 40).contains("40"))
        let long = DriveTripTemplateBuilder.duration(3_600 + 5 * 60)
        XCTAssertTrue(long.contains("1") && long.contains("5"), long)
    }

    // MARK: - Cycle de vie avec le coordinateur

    /// Position autorisée par un faux pilote : sans lui, le trajet dépend de
    /// l'autorisation réelle du simulateur et ne démarre pas là où elle est refusée.
    private func makeServices() -> AppServices {
        AppServices(config: .test, location: LocationService(manager: LocationTestDriver(),
                                                             makeOneShotManager: { LocationTestDriver() }))
    }

    private func makeCoordinator(services: AppServices) -> CarPlayCoordinator {
        CarPlayCoordinator(interface: FakeCarPlayInterface(), services: services,
                           session: AuthSessionViewModel(service: MockAuthService()))
    }

    /// Débrancher la voiture arrête le trajet qu'elle a lancé, avec son bilan.
    func testUnpluggingStopsATripStartedFromTheCar() {
        let services = makeServices()
        let coordinator = makeCoordinator(services: services)
        coordinator.start()
        services.driveTest.startFromCarPlay()
        XCTAssertTrue(services.driveTest.isRunning)
        XCTAssertTrue(services.driveTest.startedFromCarPlay)

        coordinator.stop()

        XCTAssertFalse(services.driveTest.isRunning)
        XCTAssertFalse(services.driveTest.startedFromCarPlay)
    }

    /// Un trajet lancé sur l'iPhone garde sa règle : la voiture qui se
    /// débranche ne le coupe pas.
    func testUnpluggingKeepsATripStartedOnTheIPhone() {
        let services = makeServices()
        let coordinator = makeCoordinator(services: services)
        coordinator.start()
        services.driveTest.start()

        coordinator.stop()

        XCTAssertTrue(services.driveTest.isRunning)
        services.driveTest.stop()
    }

    /// Alertes zone faible : actives pendant un drive test même réglage
    /// éteint, retirées à son arrêt (choix d'Alexandre du 12/11).
    func testCoverageAlertsFollowTheDriveTest() async {
        let wasEnabled = CarPlayAlertSettings.coverageAlertsEnabled
        UserDefaults.standard.set(false, forKey: CarPlayAlertSettings.coverageAlertsKey)
        defer { UserDefaults.standard.set(wasEnabled, forKey: CarPlayAlertSettings.coverageAlertsKey) }
        let services = makeServices()
        let coordinator = makeCoordinator(services: services)
        coordinator.start()
        XCTAssertFalse(coordinator.isObservingCoverageAlerts)

        services.driveTest.startFromCarPlay()
        await settle()
        XCTAssertTrue(coordinator.isObservingCoverageAlerts)

        services.driveTest.stop()
        await settle()
        XCTAssertFalse(coordinator.isObservingCoverageAlerts)
        coordinator.stop()
    }

    /// Laisse passer la boucle principale : le coordinateur reçoit l'état du
    /// drive test sur le tour suivant (`receive(on:)`).
    private func settle() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                RunLoop.main.perform { continuation.resume() }
            }
        }
    }
}
