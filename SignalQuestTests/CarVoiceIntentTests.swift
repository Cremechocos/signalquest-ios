import XCTest
@testable import SignalQuest

/// Verrouille les raccourcis vocaux du lot 5 CarPlay (choix d'Alexandre du
/// 13/11) : un drive test qui part de la voiture aux mêmes règles que l'onglet
/// Trajet, présentation du premier trajet comprise ; des réponses parlées qui
/// tiennent en une phrase, refus compris, sans renvoyer vers l'iPhone ; et le
/// plafond de 10 raccourcis d'Apple. Les phrases dépendent de la langue du
/// test : on compare à `String(localized:)` ou aux valeurs, pas aux mots.
@MainActor
final class CarVoiceIntentTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func issue(_ id: DriveTestPreflightIssue.ID, _ severity: DriveTestPreflightIssue.Severity,
                       value: Int? = nil) -> DriveTestPreflightIssue {
        DriveTestPreflightIssue(id: id, severity: severity, action: .none, value: value)
    }

    private func recap(endedAt: Date, distance: Double = 18_400, tests: Int = 9) -> DriveTestViewModel.SessionRecap {
        DriveTestViewModel.SessionRecap(endedAt: endedAt, distanceMeters: distance, testCount: tests, bytes: 0,
                                        stoppedByDataCap: false, vpnActive: false)
    }

    private func quality(level: CoverageQualityBand) -> NearbyNetworkQuality {
        NearbyNetworkQuality(
            level: level, signalBand: level, speedBand: level,
            medianRsrpDbm: -98, medianDownloadMbps: 40,
            operatorLabel: "Bouygues", operatorKey: "BOUYGUES", operatorSource: .ipAsn,
            sampleCount: 214, radiusMeters: 1000
        )
    }

    // MARK: - Départ sans écran

    /// La présentation du premier trajet passe avant tout le reste : sans
    /// elle, un trajet publierait sur la carte sans que l'utilisateur sache quoi.
    func testFirstTripPresentationComesBeforeThePreflight() {
        let blocked = DriveTestPreflightReport(issues: [issue(.locationPermission, .blocking)])
        XCTAssertEqual(DriveTestHandsFreeStart.refusal(disclosureSeen: false, report: blocked), .disclosureNotSeen)
        XCTAssertEqual(DriveTestHandsFreeStart.refusal(disclosureSeen: false, report: .init(issues: [])),
                       .disclosureNotSeen)
        XCTAssertEqual(DriveTestHandsFreeStart.refusal(disclosureSeen: true, report: blocked),
                       .preflight(issue(.locationPermission, .blocking)))
    }

    /// Un simple avertissement (batterie, GPS, Wi-Fi) ne refuse pas le départ.
    func testWarningsDoNotRefuseTheStart() {
        let report = DriveTestPreflightReport(issues: [issue(.battery, .warning, value: 12), issue(.wifi, .warning)])
        XCTAssertNil(DriveTestHandsFreeStart.refusal(disclosureSeen: true, report: report))
    }

    /// Écran du véhicule comme Siri : la raison dit pourquoi, sans consigne.
    func testFirstTripRefusalIsNeutral() {
        let reason = DriveTestHandsFreeStart.reason(.disclosureNotSeen)
        for text in [reason.title, reason.detail] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("iPhone"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("Réglages"), text)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("ouvre"), text)
        }

        let template = DriveTripTemplateBuilder.make(state: .blocked(.disclosureNotSeen),
                                                     actions: .init(start: {}, stop: {}))
        XCTAssertTrue(template.actions.isEmpty, "pas de « Démarrer » tant que le premier trajet n'est pas présenté")
        XCTAssertEqual(template.items.map(\.title), [reason.title])
    }

    /// Par la voix, le refus est la même phrase que sur l'écran du véhicule,
    /// et rien ne démarre.
    func testVoiceStartRefusesWhileTheFirstTripIsNotPresented() {
        let key = DriveTestDisclosureView.seenKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let services = AppServices(config: .test)

        let answer = DriveTestVoice.start(services: services, isSignedIn: true)

        XCTAssertEqual(answer, DriveTestVoice.spoken(DriveTestHandsFreeStart.reason(.disclosureNotSeen)))
        XCTAssertFalse(services.driveTest.isRunning)
    }

    func testVoiceStartNeedsAnAccount() {
        let services = AppServices(config: .test)
        XCTAssertEqual(DriveTestVoice.start(services: services, isSignedIn: false),
                       String(localized: "Aucun compte connecté sur SignalQuest."))
        XCTAssertFalse(services.driveTest.isRunning)
    }

    // MARK: - Réponses parlées

    /// Les avertissements du départ se disent : ils ne bloquent pas, mais le
    /// conducteur doit les entendre. Le Wi-Fi n'en est pas un (le trajet se
    /// met en pause et le dit).
    func testStartedAnswerReadsTheWarnings() {
        XCTAssertEqual(DriveTestVoice.startedAnswer(warnings: []), String(localized: "Drive test lancé."))
        XCTAssertEqual(DriveTestVoice.startedAnswer(warnings: [issue(.wifi, .warning)]),
                       String(localized: "Drive test lancé."))

        let battery = String(localized: "Batterie faible")
        let answer = DriveTestVoice.startedAnswer(warnings: [issue(.battery, .warning, value: 12)])
        XCTAssertNotEqual(answer, String(localized: "Drive test lancé."))
        XCTAssertTrue(answer.localizedCaseInsensitiveContains(battery), answer)
    }

    /// Le bilan lu est celui du trajet qui vient de finir : `stop()` remet
    /// l'ancien en place quand le trajet était trop court pour être gardé.
    func testStoppedAnswerReadsOnlyTheTripThatJustEnded() {
        let fresh = DriveTestVoice.stoppedAnswer(recap: recap(endedAt: now.addingTimeInterval(-1)), now: now)
        XCTAssertTrue(fresh.contains(SQUnits.distance(meters: 18_400)), fresh)
        XCTAssertTrue(fresh.contains("9"), fresh)

        let tooShort = String(localized: "Drive test arrêté, trop court pour être enregistré.")
        XCTAssertEqual(DriveTestVoice.stoppedAnswer(recap: recap(endedAt: now.addingTimeInterval(-3_600)), now: now),
                       tooShort, "un bilan d'il y a une heure n'est pas celui de ce trajet")
        XCTAssertEqual(DriveTestVoice.stoppedAnswer(recap: nil, now: now), tooShort)
    }

    /// Verdict, opérateur en entier et base de mesures, en une phrase : comme
    /// l'onglet Ici, jamais un verdict sans son opérateur ni son nombre de mesures.
    func testNetworkHereReadsVerdictCarrierAndSamples() {
        let answer = NetworkHereVoice.answer(quality(level: .fair))
        XCTAssertTrue(answer.hasPrefix(NearestAntennaTemplateBuilder.verdictTitle(.fair)), answer)
        XCTAssertTrue(answer.contains("Bouygues Telecom"), answer)
        XCTAssertTrue(answer.contains("214"), answer)
    }

    func testNetworkHereSaysWhenThereIsTooLittleData() {
        let tooLittle = String(localized: "Pas assez de mesures ici pour juger le réseau.")
        XCTAssertEqual(NetworkHereVoice.answer(nil), tooLittle)
        XCTAssertEqual(NetworkHereVoice.answer(quality(level: .unknown)), tooLittle)
    }

    // MARK: - Raccourcis

    /// Apple refuse au-delà de 10 raccourcis : en ajouter un en retire un.
    func testShortcutsStayWithinApplesLimit() {
        XCTAssertLessThanOrEqual(SignalQuestShortcuts.appShortcuts.count, 10)
    }
}
