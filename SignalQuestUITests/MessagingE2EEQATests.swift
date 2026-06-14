import XCTest

/// QA d'interopérabilité E2EE contre la prod, pilotée par
/// TestArtifacts/interop/e2ee-interop.mjs (le pair "web").
/// Nécessite : SQ_AUTH_TOKEN (compte A) + SQ_E2EE_PASSWORD + SQ_E2EE_QA_PHASE.
///
/// Phases :
///  - "create" : première ouverture — le sheet E2EE passe en mode création,
///    on crée la clé de A avec le mot de passe fourni.
///  - "reply"  : déverrouille, vérifie que le message chiffré envoyé par le
///    client web se lit en clair, puis répond.
@MainActor
final class MessagingE2EEQATests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testE2EEInteropPhase() throws {
        let token = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"] ?? ""
        let password = ProcessInfo.processInfo.environment["SQ_E2EE_PASSWORD"] ?? ""
        let phase = ProcessInfo.processInfo.environment["SQ_E2EE_QA_PHASE"] ?? ""
        try XCTSkipUnless(!token.isEmpty && !password.isEmpty && !phase.isEmpty, "QA E2EE: variables d'env manquantes")

        let app = XCUIApplication()
        app.launchEnvironment["SQ_AUTH_TOKEN"] = token
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Messages"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Messages"].tap()

        // Le sheet E2EE se présente automatiquement quand une conversation
        // chiffrée existe et que la clé n'est pas déverrouillée.
        let secureField = app.secureTextFields.firstMatch

        if phase == "create" {
            XCTAssertTrue(secureField.waitForExistence(timeout: 15), "Sheet E2EE absent")
            XCTAssertTrue(app.staticTexts["Créer ta clé"].waitForExistence(timeout: 10), "Mode création attendu (pas de clé serveur)")
            secureField.tap()
            secureField.typeText(password)
            let createButton = app.buttons["Créer et activer"]
            XCTAssertTrue(createButton.waitForExistence(timeout: 5))
            createButton.tap()
            // Le sheet se ferme une fois la clé enregistrée côté serveur.
            XCTAssertTrue(secureField.waitForNonExistence(timeout: 20), "La création de clé n'a pas abouti")
            print("E2EE_QA_CREATE_OK")
            return
        }

        // phases "reply"/"realtime" — la clé peut être restée déverrouillée
        // (Keychain) : le sheet n'apparaît alors pas, on continue directement.
        if secureField.waitForExistence(timeout: 8) {
            secureField.tap()
            secureField.typeText(password)
            let unlockButton = app.buttons["Déverrouiller"].firstMatch
            XCTAssertTrue(unlockButton.waitForExistence(timeout: 5))
            unlockButton.tap()
            XCTAssertTrue(secureField.waitForNonExistence(timeout: 20), "Déverrouillage échoué")
        }

        if phase == "realtime" {
            // Ouvre la conversation et attend un message envoyé par le pair web
            // PENDANT l'écoute — sa latence d'apparition mesure le SSE (le
            // polling de secours ne tire qu'à 12 s).
            let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "SQ Web Test B")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20), "Conversation introuvable")
            row.tap()
            XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10))
            print("REALTIME_READY")
            let markerText = ProcessInfo.processInfo.environment["SQ_E2EE_QA_MARKER"] ?? "ping temps réel"
            let marker = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", markerText)).firstMatch
            let started = Date()
            XCTAssertTrue(marker.waitForExistence(timeout: 75), "Message temps réel jamais reçu")
            print("REALTIME_OK elapsed_since_open=\(Int(Date().timeIntervalSince(started)))s")
            return
        }

        // L'aperçu du dernier message (un « ping … » envoyé par le pair web)
        // doit apparaître DÉCHIFFRÉ dans la liste des conversations.
        let preview = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ping ")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 25), "Aperçu déchiffré introuvable dans la liste")
        print("E2EE_QA_PREVIEW_OK")

        // Ouvre la conversation, vérifie un message en clair, répond.
        let row = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "SQ Web Test B")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Conversation introuvable")
        row.tap()
        let bubble = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ping ")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "Message déchiffré introuvable dans la conversation")

        let composer = app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Réponse chiffrée depuis iOS ✅")
        let sendButton = app.buttons["paperplane.fill"].firstMatch
        if sendButton.exists {
            sendButton.tap()
        } else {
            // Fallback : dernier bouton du composer.
            app.buttons.matching(NSPredicate(format: "isEnabled == true")).allElementsBoundByIndex.last?.tap()
        }
        let sent = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Réponse chiffrée depuis iOS")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 15), "La réponse n'apparaît pas dans le fil")
        print("E2EE_QA_REPLY_OK")
        // Laisse le temps au POST de se terminer avant de tuer l'app.
        Thread.sleep(forTimeInterval: 2)
    }
}
