import XCTest

/// Tour de captures sur l'en-tête « carte de visite » du profil public.
///
/// Tourne en `--demo-data` : la composition à vérifier (identité centrée, bio,
/// barre empilée des réseaux, trois mesures, Suivre + Message) ne dépend pas du
/// compte. Le profil démo porte volontairement deux réseaux qui ne totalisent
/// PAS 100 %, pour que la piste résiduelle de la barre soit exercée.
@MainActor
final class ProfileCardQATests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testPublicProfileCard() throws {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--demo-data"])

        let community = SignalQuestUITestSupport.tab(named: "Communauté", in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 25), "Onglet Communauté absent")
        community.tap()
        Thread.sleep(forTimeInterval: 2)

        // L'auteur du premier post démo ouvre son profil public.
        let author = app.staticTexts["Camille"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 15), "Auteur « Camille » absent du fil")
        author.tap()
        Thread.sleep(forTimeInterval: 3)
        snap(app, "profil-01-carte")

        // Identité : le pseudo et le pays sur la même ligne.
        XCTAssertTrue(app.staticTexts["@camille"].waitForExistence(timeout: 10), "Pseudo absent")

        // Réseaux mesurés : le libellé de section et la légende chiffrée.
        // ⚠️ Le libellé ne doit JAMAIS dire « opérateur » : la répartition des
        // mesures n'établit pas un abonnement.
        XCTAssertTrue(
            SignalQuestUITestSupport.scrollToHittable(app.staticTexts["Réseaux mesurés"], in: app),
            "Section « Réseaux mesurés » absente"
        )
        XCTAssertFalse(
            app.staticTexts["Opérateur"].exists,
            "Un libellé « Opérateur » s'est glissé dans l'en-tête"
        )
        // Chaque pastille de légende est un élément d'accessibilité FUSIONNÉ :
        // son `accessibilityLabel` remplace le texte affiché, donc on interroge
        // ce libellé et non « Orange 52 % ».
        //
        // « SFR » et non « Sfr » : les noms d'opérateurs sont des sigles, ils
        // passent par le registre de marque.
        // Un MVNO porte SON nom, pas celui de son hôte — c'est ce que la personne
        // lit sur son téléphone. L'hôte n'est pas perdu : il passe dans le
        // libellé d'accessibilité, pour ne pas réserver l'information à qui sait
        // décoder une couleur.
        //
        // « Free 4 % » est là exprès : l'ancien plancher à 5 % masquait des
        // réseaux réellement mesurés sans le dire.
        // ⚠️ Les noms attendus sont ceux de `SQBrand` (« Bouygues », « Free »),
        // PAS ceux du registre backend (« Bouygues Telecom », « Free Mobile ») :
        // iOS affiche les noms courts. Deux sources de libellés, ne pas les
        // confondre en écrivant un test.
        for legend in [
            "Orange : 52 % des mesures",
            "SFR : 30 % des mesures",
            "Lebara, sur le réseau Bouygues : 8 % des mesures",
            "Free : 4 % des mesures"
        ] {
            XCTAssertTrue(
                app.otherElements[legend].exists || app.staticTexts[legend].exists,
                "Légende « \(legend) » absente de la barre empilée"
            )
        }

        // Les trois mesures de contribution.
        for label in ["Points", "Tests", "Validations"] {
            XCTAssertTrue(app.staticTexts[label].exists, "Mesure « \(label) » absente")
        }

        // Les deux actions côte à côte. Les deux boutons portent un
        // `accessibilityLabel` qui NOMME la personne (« Suivre Camille »,
        // « Envoyer un message à Camille ») : c'est ce libellé qui est
        // interrogeable, pas le titre affiché.
        XCTAssertTrue(app.buttons["Suivre Camille"].exists, "Bouton Suivre absent")
        XCTAssertTrue(
            app.buttons["Envoyer un message à Camille"].exists,
            "Bouton Message absent"
        )

        // Abonnés / abonnements n'ont pas disparu : ils sont passés en pastilles.
        XCTAssertTrue(
            SignalQuestUITestSupport.scrollToHittable(app.staticTexts["128 abonnés"], in: app),
            "La pastille « abonnés » manque — la refonte ne doit rien retirer"
        )
        snap(app, "profil-02-pastilles")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
