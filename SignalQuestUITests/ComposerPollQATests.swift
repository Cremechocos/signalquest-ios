import XCTest

/// SOC-01 : supprimer une option de sondage PENDANT sa saisie faisait planter
/// l'app (« Index out of range ») quand les options étaient éditées par index.
/// Ce parcours reproduit exactement ce geste, en mode démo.
@MainActor
final class ComposerPollQATests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testRemovingAnOptionWhileTypingDoesNotCrash() {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth", "--qa-demo-friends"], locale: "fr")

        let community = SignalQuestUITestSupport.tab(named: "Communauté", in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 25))
        community.tap()

        let publish = app.descendants(matching: .any)
            .matching(identifier: "community.header.action.publish").firstMatch
        XCTAssertTrue(publish.waitForExistence(timeout: 10), "Bouton « Publier » introuvable")
        publish.tap()

        let pollToggle = app.buttons["Sondage"].firstMatch
        XCTAssertTrue(pollToggle.waitForExistence(timeout: 10), "Bouton « Sondage » introuvable")
        pollToggle.tap()

        // Trois options : la dernière sera supprimée pendant sa saisie.
        let addOption = app.buttons["Ajouter une option"].firstMatch
        XCTAssertTrue(addOption.waitForExistence(timeout: 5))
        addOption.tap()

        let first = app.textFields["Choix 1"].firstMatch
        let second = app.textFields["Choix 2"].firstMatch
        let third = app.textFields["Choix 3"].firstMatch
        XCTAssertTrue(third.waitForExistence(timeout: 5), "Troisième option absente")
        first.tap(); first.typeText("4G")
        second.tap(); second.typeText("5G")
        third.tap(); third.typeText("Pas de réseau")

        // Suppression de l'option en cours d'édition (clavier ouvert).
        let removeThird = app.buttons["Supprimer l'option 3"].firstMatch
        XCTAssertTrue(removeThird.waitForExistence(timeout: 5))
        removeThird.tap()

        XCTAssertTrue(third.waitForNonExistence(timeout: 5), "L'option supprimée est toujours là")
        XCTAssertEqual(app.state, .runningForeground, "L'app a quitté l'avant-plan (crash)")
        XCTAssertEqual(first.value as? String, "4G", "Le texte de l'option 1 a été décalé")
        XCTAssertEqual(second.value as? String, "5G", "Le texte de l'option 2 a été décalé")

        // Suppression au milieu, puis ajout : les textes restants ne bougent pas.
        addOption.tap()
        let removeFirst = app.buttons["Supprimer l'option 1"].firstMatch
        XCTAssertTrue(removeFirst.waitForExistence(timeout: 5))
        removeFirst.tap()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(app.textFields["Choix 1"].firstMatch.value as? String, "5G")
    }
}
