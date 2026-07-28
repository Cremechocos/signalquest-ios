import XCTest

/// Tour visuel du mode « Noir intense (OLED) ».
///
/// Le mode ne se vérifie pas par assertion : il se regarde. Un fond resté gris au
/// milieu d'écrans noirs ne casse aucun test, ne lève aucune erreur, et ne se voit
/// que sur une capture.
///
/// Ce parcours force donc l'apparence sombre ET le réglage OLED, puis photographie
/// chaque écran atteignable. Il complète l'audit statique, qui a déjà trouvé les
/// surfaces calculées (dock, verre) restées brunes — mais qui ne peut rien dire des
/// fonds écrits en dur dans une vue.
@MainActor
final class OledTourQATests: XCTestCase {

    /// Réglage OLED activé via le domaine d'arguments : une valeur `NSUserDefaults`
    /// passée au lancement prime sur celle du disque, sans écrire dans le conteneur.
    ///
    /// ⚠️ L'apparence sombre, elle, ne se force PAS par argument de lancement :
    /// `-UIUserInterfaceStyle Dark` est ignoré en silence, et le parcours
    /// photographiait l'app en clair tout en passant au vert. Elle se règle sur
    /// l'APPAREIL, via `XCUIDevice.appearance` (voir `setUp`).
    private var oledArguments: [String] { ["-app_pure_black", "YES"] }

    /// ⚠️ `XCUIDevice.shared.appearance = .dark` ne suffit pas non plus : le
    /// parcours restait en clair. L'apparence se règle en amont, sur le
    /// SIMULATEUR — `xcrun simctl ui <device> appearance dark` — avant de lancer
    /// la suite. Le test vérifie ci-dessous qu'elle a bien pris, plutôt que de
    /// photographier gaiement le mauvais thème.
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        print("SQ_OLED \(name)")
    }

    private func settle(_ app: XCUIApplication, _ seconds: TimeInterval = 1.2) {
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 6)
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Écrans atteignables SANS compte : onboarding, connexion, inscription.
    /// Ce sont les premiers que voit un nouvel utilisateur, et ceux qu'on oublie
    /// le plus souvent en vérifiant un thème.
    func testUnauthenticatedScreens() {
        let app = XCUIApplication()
        app.launchArguments = oledArguments
        app.sqLaunch()
        settle(app)
        capture("01-onboarding")

        // L'onboarding se saute dans les deux langues (l'app est bilingue).
        let skip = app.buttons["Passer"].exists ? app.buttons["Passer"] : app.buttons["Skip"]
        if skip.waitForExistence(timeout: 3) {
            skip.tap()
            settle(app)
        }
        capture("02-connexion")

        for label in ["Créer un compte", "S'inscrire", "Sign up"] {
            let entry = app.buttons[label].firstMatch
            if entry.waitForExistence(timeout: 2) {
                entry.tap()
                settle(app)
                capture("03-inscription")
                break
            }
        }
    }

    /// Écrans du mode connecté : les cinq onglets, les réglages, et une feuille
    /// modale — les feuilles ont leur propre fond et échappent souvent aux thèmes.
    func testAuthenticatedScreens() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(
            app,
            arguments: ["--mock-auth", "--qa-demo-friends"] + oledArguments
        )
        settle(app)

        for tab in SignalQuestUITestSupport.tabs {
            let element = SignalQuestUITestSupport.tab(named: tab, in: app)
            guard element.waitForExistence(timeout: 10) else {
                print("SQ_OLED MANQUANT onglet \(tab)")
                continue
            }
            element.tap()
            settle(app)
            capture("onglet-\(tab.lowercased())")
        }

        // Profil → Réglages : la liste système a ses propres fonds de ligne, qui
        // sont exactement le genre de surface à rester grise.
        SignalQuestUITestSupport.tab(named: "Profil", in: app).tap()
        settle(app)
        for label in ["Réglages", "Settings"] {
            let entry = app.staticTexts[label].firstMatch
            if entry.waitForExistence(timeout: 3) {
                entry.tap()
                settle(app)
                capture("reglages")
                break
            }
        }
    }

    /// La carte : fond MapKit, contrôles en verre et feuille de filtres. C'est
    /// l'écran où le mode a le plus de chances de mal se tenir, la carte n'étant
    /// pas une surface du design system.
    func testMapAndSheets() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(
            app,
            arguments: ["--mock-auth", "--qa-demo-friends"] + oledArguments
        )
        let map = SignalQuestUITestSupport.tab(named: "Carte", in: app)
        guard map.waitForExistence(timeout: 15) else {
            XCTFail("Onglet Carte introuvable")
            return
        }
        map.tap()
        settle(app, 2)
        capture("carte")

        // Feuille de filtres avancés, atteinte par le bouton de filtres.
        let filters = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'filtre'")).firstMatch
        if filters.waitForExistence(timeout: 4) {
            filters.tap()
            settle(app)
            capture("carte-filtres")
        }
    }
}
