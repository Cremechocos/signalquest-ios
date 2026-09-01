import CarPlay
import CoreLocation
import XCTest
@testable import SignalQuest

/// Pile de templates factice.
///
/// `CPInterfaceController` n'est jamais instanciable hors d'un véhicule, ce qui
/// laissait `CarPlayCoordinator` — 900 lignes, tout l'orchestration et tout le
/// cycle de vie — sans le moindre test. Le protocole d'indirection existait
/// pourtant depuis le début pour permettre exactement ça.
///
/// Le fake simule aussi le PLAFOND DE PROFONDEUR : les apps de catégorie
/// « driving task » sont limitées à deux templates empilés (trois depuis
/// iOS 26.4). Au-delà, le système refuse le push — et, si aucun bloc de
/// complétion n'est fourni, lève une exception. C'est la contrainte la plus
/// serrée que la surface doit respecter, et elle est invisible au simulateur si
/// l'on ne la reproduit pas.
@MainActor
final class FakeCarPlayInterface: CarPlayInterfaceControlling {
    enum Failure: Error { case depthExceeded }

    /// Profondeur autorisée, racine comprise.
    var maximumDepth = 2

    private(set) var stack: [CPTemplate] = []
    private(set) var presented: CPTemplate?
    /// Templates que le système a refusé d'empiler, par nom de classe.
    private(set) var refused: [String] = []

    var templateCount: Int { stack.count }

    func setRoot(_ template: CPTemplate, animated: Bool, completion: CarPlayNavigationCompletion?) {
        stack = [template]
        completion?(true, nil)
    }

    func push(_ template: CPTemplate, animated: Bool, completion: CarPlayNavigationCompletion?) {
        guard stack.count < maximumDepth else {
            refused.append(String(describing: type(of: template)))
            completion?(false, Failure.depthExceeded)
            return
        }
        stack.append(template)
        completion?(true, nil)
    }

    func pop(animated: Bool, completion: CarPlayNavigationCompletion?) {
        let popped = stack.count > 1
        if popped { stack.removeLast() }
        completion?(popped, nil)
    }

    func present(_ template: CPTemplate, animated: Bool, completion: CarPlayNavigationCompletion?) {
        presented = template
        completion?(true, nil)
    }

    func dismiss(animated: Bool, completion: CarPlayNavigationCompletion?) {
        let dismissed = presented != nil
        presented = nil
        completion?(dismissed, nil)
    }
}

@MainActor
final class CarPlayCoordinatorTests: XCTestCase {
    private var alertsWereEnabled = false

    override func setUp() {
        super.setUp()
        alertsWereEnabled = CarPlayAlertSettings.coverageAlertsEnabled
    }

    override func tearDown() {
        UserDefaults.standard.set(alertsWereEnabled, forKey: CarPlayAlertSettings.coverageAlertsKey)
        // Le relais est un état de PROCESSUS : le laisser installé ferait fuir
        // un coordinateur d'un test dans le suivant.
        CarPlayDashboardRoute.setListener(nil)
        _ = CarPlayDashboardRoute.consume()
        super.tearDown()
    }

    private func makeCoordinator(interface: FakeCarPlayInterface,
                                 services: AppServices = AppServices(config: .test)) -> CarPlayCoordinator {
        CarPlayCoordinator(
            interface: interface,
            services: services,
            session: AuthSessionViewModel(service: MockAuthService()),
            // Nil = catégorie « driving task », la configuration réellement
            // livrée. C'est celle qu'il faut tester.
            carWindow: nil
        )
    }

    // MARK: - Cycle de vie

    /// CarPlay exige une racine sans délai : laisser l'écran vide le temps d'un
    /// appel réseau donnerait une app figée au démarrage du véhicule.
    func testRootIsInstalledSynchronouslyOnConnect() {
        let interface = FakeCarPlayInterface()
        let coordinator = makeCoordinator(interface: interface)

        coordinator.start()

        XCTAssertEqual(interface.templateCount, 1, "la racine doit être posée sans attendre le réseau")
        XCTAssertTrue(interface.stack.first is CPListTemplate)
    }

    /// Sans `carplay-maps`, la scène est connectée mais INCAPABLE de guider.
    /// L'iPhone doit le savoir, sinon il détourne « Y aller » vers un véhicule
    /// qui ne fera rien — et n'ouvre plus Plan non plus.
    func testGuidanceIsNotAdvertisedWithoutAMap() {
        let services = AppServices(config: .test)
        let coordinator = makeCoordinator(interface: FakeCarPlayInterface(), services: services)

        coordinator.start()

        XCTAssertTrue(services.isCarPlayConnected)
        XCTAssertFalse(services.isCarPlayGuidanceAvailable,
                       "en mode liste, aucun guidage n'est possible")
    }

    func testNavigationWithoutLocationShowsAnActionableAlert() {
        let interface = FakeCarPlayInterface()
        let coordinator = makeCoordinator(interface: interface)

        coordinator.startNavigation(
            to: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
            title: "Destination"
        )

        XCTAssertTrue(interface.presented is CPAlertTemplate)
    }

    // MARK: - Alertes de couverture

    /// Le réglage existait dans l'app et n'avait AUCUN effet : l'observateur
    /// n'était posé que par `installMap`, jamais appelé sans `carplay-maps`.
    func testCoverageAlertsAreObservedWithoutAMap() {
        UserDefaults.standard.set(true, forKey: CarPlayAlertSettings.coverageAlertsKey)
        let services = AppServices(config: .test)
        let coordinator = makeCoordinator(interface: FakeCarPlayInterface(), services: services)

        coordinator.start()

        XCTAssertTrue(services.location.wantsTracking,
                      "s'abonner aux positions doit suffire à les recevoir")
    }

    /// Le pendant : au débranchement, le GPS haute précision et
    /// `allowsBackgroundLocationUpdates` doivent retomber. Ils restaient actifs
    /// indéfiniment, pour un écran qui n'existe plus.
    func testStopReleasesLocationTracking() {
        UserDefaults.standard.set(true, forKey: CarPlayAlertSettings.coverageAlertsKey)
        let services = AppServices(config: .test)
        let coordinator = makeCoordinator(interface: FakeCarPlayInterface(), services: services)
        coordinator.start()
        XCTAssertTrue(services.location.wantsTracking)

        coordinator.stop()

        XCTAssertFalse(services.location.wantsTracking,
                       "le suivi doit s'arrêter quand le dernier abonné se retire")
        XCTAssertFalse(services.isCarPlayConnected)
        XCTAssertFalse(services.isCarPlayGuidanceAvailable)
    }

    /// Alertes désactivées : on ne doit RIEN allumer. Une app qui suit la
    /// position sans raison est un problème de batterie et de vie privée.
    func testNoTrackingWhenCoverageAlertsAreOff() {
        UserDefaults.standard.set(false, forKey: CarPlayAlertSettings.coverageAlertsKey)
        let services = AppServices(config: .test)
        let coordinator = makeCoordinator(interface: FakeCarPlayInterface(), services: services)

        coordinator.start()

        XCTAssertFalse(services.location.wantsTracking)
    }

    // MARK: - Profondeur de pile

    /// Garde-fou du harnais : sans lui, les tests de navigation valideraient une
    /// arborescence que le véhicule refuse.
    func testFakeRefusesPushesBeyondTheAllowedDepth() {
        let interface = FakeCarPlayInterface()
        interface.setRoot(CPListTemplate(title: "racine", sections: []), animated: false)
        interface.push(CPListTemplate(title: "niveau 2", sections: []), animated: false)

        interface.push(CPInformationTemplate(title: "niveau 3", layout: .twoColumn,
                                             items: [], actions: []), animated: false)

        XCTAssertEqual(interface.templateCount, 2)
        XCTAssertEqual(interface.refused, ["CPInformationTemplate"],
                       "le troisième niveau doit être refusé, comme dans un véhicule")
    }

    /// Un refus ne doit jamais interrompre l'app. Le contrat CarPlay est
    /// explicite : sans bloc de complétion, un échec de présentation LÈVE une
    /// exception — donc un crash au volant. Le protocole en fournit un partout.
    func testRefusedPushIsReportedAndSurvived() {
        let interface = FakeCarPlayInterface()
        interface.maximumDepth = 1
        interface.setRoot(CPListTemplate(title: "racine", sections: []), animated: false)

        var reported: (any Error)?
        interface.push(CPListTemplate(title: "trop profond", sections: []), animated: false) { success, error in
            XCTAssertFalse(success)
            reported = error
        }

        XCTAssertNotNil(reported, "le refus doit remonter à l'appelant, pas disparaître")
    }

    // MARK: - Relais depuis l'iPhone

    /// Le cas nominal, et celui qui était cassé : véhicule DÉJÀ branché, scène
    /// déjà installée. L'intention dormait jusqu'à la prochaine connexion.
    func testIntentReachesAnAlreadyInstalledScene() {
        var received: [CarPlayDashboardRoute.Destination] = []
        CarPlayDashboardRoute.setListener { received.append($0) }

        CarPlayDashboardRoute.request(.here)

        XCTAssertEqual(received.count, 1)
        XCTAssertNil(CarPlayDashboardRoute.consume(),
                     "servie au vol, l'intention ne doit pas rester en attente")
    }

    /// L'inverse : intention déposée avant que la scène n'existe. Elle doit être
    /// servie à l'installation, et une seule fois.
    func testIntentDepositedBeforeInstallIsServedOnce() {
        CarPlayDashboardRoute.request(.map)

        var received: [CarPlayDashboardRoute.Destination] = []
        CarPlayDashboardRoute.setListener { received.append($0) }

        XCTAssertEqual(received.count, 1)
        XCTAssertNil(CarPlayDashboardRoute.consume())
    }

    // MARK: - États de liste

    /// Trois états, pas deux : un échec réseau annonçait « Aucune box
    /// surveillée », c'est-à-dire un fait faux présenté comme certain.
    func testFailureOffersRetryInsteadOfClaimingEmptiness() {
        let template = CPListTemplate(title: "Sentinelle", sections: [])
        var retried = false

        CarPlayListPlaceholder.applyFailure(to: template) { retried = true }

        let items = template.sections.flatMap(\.items)
        XCTAssertEqual(items.count, 1, "l'échec doit offrir une action, pas un message inerte")
        let item = try? XCTUnwrap(items.first as? CPListItem)
        item?.handler?(item!) {}
        XCTAssertTrue(retried)
    }

    func testLoadingIsNotPresentedAsEmptiness() {
        let template = CPListTemplate(title: "Sentinelle", sections: [])
        CarPlayListPlaceholder.applyEmpty(to: template, title: "Aucune box surveillée", subtitle: "…")

        CarPlayListPlaceholder.applyLoading(to: template)

        XCTAssertEqual(template.emptyViewTitleVariants, ["Chargement…"])
        XCTAssertTrue(template.emptyViewSubtitleVariants.isEmpty,
                      "pendant le chargement, on n'affirme rien sur le contenu")
    }
}
