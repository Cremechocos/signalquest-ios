import XCTest

/// Passe l'auditeur d'accessibilité d'Apple sur les écrans principaux.
///
/// `performAccessibilityAudit` détecte ce qu'une relecture manque
/// systématiquement : élément sans description, texte tronqué aux grandes
/// tailles, contraste insuffisant, cible tactile trop petite, élément
/// interactif non détecté. C'est la façon la moins coûteuse de mesurer la
/// progression sur 60 000 lignes.
///
/// Les surfaces couvertes ici sont bloquantes : une régression de contraste,
/// Dynamic Type, description ou cible tactile fait échouer la CI. La QA
/// VoiceOver humaine reste complémentaire, elle n'est pas simulée par l'audit.
@MainActor
final class AccessibilityAuditTests: XCTestCase {

    @available(iOS 17.0, *)
    private static var auditedTypes: XCUIAccessibilityAuditType {
        [.contrast, .dynamicType, .elementDetection, .hitRegion,
         .sufficientElementDescription, .textClipped]
    }

    @available(iOS 17.0, *)
    private static var renderedLargeTextTypes: XCUIAccessibilityAuditType {
        [.contrast, .elementDetection, .hitRegion,
         .sufficientElementDescription, .textClipped]
    }

    /// `XCUIAccessibilityAuditType` s'affiche en brut (`rawValue: 131072`),
    /// illisible dans un rapport qu'on relit à froid.
    @available(iOS 17.0, *)
    private static func name(for type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: return "contraste"
        case .elementDetection: return "élément non détecté"
        case .hitRegion: return "cible tactile"
        case .sufficientElementDescription: return "description insuffisante"
        case .textClipped: return "texte tronqué"
        case .dynamicType: return "Dynamic Type"
        default: return "\(type.rawValue)"
        }
    }

    /// L'API est iOS 17+ alors que l'app cible iOS 16 : l'ancien runtime est
    /// explicitement ignoré par les tests appelants, jamais compté comme vert.
    @available(iOS 17.0, *)
    private func audit(
        _ app: XCUIApplication, screen: String, blocking: Bool,
        types: XCUIAccessibilityAuditType? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var issues: [String] = []
        var exclusions: [String] = []
        func exclude(_ reason: String, _ name: String, _ type: XCUIAccessibilityAuditType) -> Bool {
            exclusions.append("[\(Self.name(for: type))] « \(name) » : \(reason)")
            return true
        }
        let tabBar = app.tabBars.firstMatch
        let tabBarTop = tabBar.exists ? tabBar.frame.minY : nil
        let customDock = app.descendants(matching: .any)["main.navigation"]
        let customDockTop = customDock.exists ? customDock.frame.minY : nil
        let navigationTop = [tabBarTop, customDockTop].compactMap { $0 }.min()
        do {
          try app.performAccessibilityAudit(for: types ?? Self.auditedTypes) { issue in
            // `identifier` vaut souvent "" — non-nil, donc un `??` ne basculerait
            // jamais sur le libellé. On prend la première valeur NON VIDE, sans
            // quoi le rapport ne permet de localiser aucun élément.
            let element = issue.element
            let name = [element?.identifier, element?.label, element?.value as? String]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "sans nom"
            let frame = element.map { "\($0.frame)" } ?? ""
            let detail = (issue.detailedDescription ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            // Contrôle système MapKit fourni par Apple. Sa cible et son rendu ne
            // sont pas modifiables par l'application ; il ouvre les attributions
            // légales et reste correctement nommé par le framework.
            // Le Drive Test pose la même carte MapKit que l'onglet Carte (Lot 4c).
            let showsMapKit = screen.hasPrefix("Carte") || screen.hasPrefix("Drive Test")
            if showsMapKit, name == "Mentions légales" {
                return exclude("contrôle système MapKit nommé par Apple", name, issue.auditType)
            }
            // La barre Liquid Glass native recouvre volontairement la fin des
            // ScrollView. L'auditeur iOS 27 inspecte aussi les nœuds dont le
            // centre est déjà derrière cette barre et leur attribue alors le
            // contraste du verre, pas celui de leur surface. `isHittable` peut
            // encore être vrai pour la seule ligne exposée au-dessus du verre.
            // Les textes couverts dans Réglages et le rail de stories sont
            // contrôlés après défilement ; leurs jetons passent le test de contraste.
            let verifiedAfterScroll = screen.hasPrefix("Réglages") ||
                (screen.hasPrefix("Communauté") && name == "feed.story.name")
            if let navigationTop, let element, element.frame.midY >= navigationTop,
               (!element.isHittable || verifiedAfterScroll),
               (issue.auditType == .contrast || issue.auditType == .hitRegion) {
                let reason = verifiedAfterScroll
                    ? "centre derrière la navigation ; visibilité vérifiée après défilement"
                    : "nœud non atteignable derrière la navigation"
                return exclude(reason, name, issue.auditType)
            }
            // MapKit dessine ses libellés de fond dans le raster de la carte :
            // ils n'ont ni XCUIElement ni frame. La carte expose séparément ses
            // annotations et contrôles applicatifs ; on n'invente pas de nœud
            // pour le texte cartographique fourni par Apple.
            if showsMapKit, name == "sans nom", element == nil,
               issue.auditType == .elementDetection {
                return exclude("libellé raster MapKit sans nœud accessible", name, issue.auditType)
            }
            if showsMapKit, name == "sans nom", element == nil,
               issue.auditType == .dynamicType {
                return exclude("libellé raster MapKit sans nœud accessible", name, issue.auditType)
            }
            // Les traits et graduations du cadran sont décoratifs et masqués ;
            // la valeur, l'unité et la phase sont exposées par le nœud combiné.
            if screen.hasPrefix("Tester"), name == "sans nom", element == nil,
               issue.auditType == .contrast {
                return exclude("graduation décorative ; valeur combinée accessible", name, issue.auditType)
            }
            // iOS 27 signale à tort ces composants SwiftUI même lorsque leurs
            // polices sont des styles système (`body`, `headline`, `caption`).
            // La passe `— texte accessibilité` ci-dessous les rend réellement à
            // AX XXL et conserve textClipped/hitRegion comme garde-fous.
            let semanticDynamicIdentifiers = [
                "home.action.title.", "home.action.subtitle.", "community.header.action.",
                "community.networkPulse", "feed.metadata", "feed.tag", "feed.metric.label",
                "feed.metric.value", "feed.speedtest.subtitle",
                "feed.story.name", "feed.hashtag", "feed.avatar.initial",
                "settings.label.Noir intense (OLED)",
                // Lot 4b : la pastille « Drive Test » cède la place à l'icône aux
                // grandes tailles (ViewThatFits) ; la passe AX XXL la vérifie.
                "speedtest.driveTest.label",
                // Lot 4c : le panneau du Drive Test défile aux grandes tailles
                // (ViewThatFits) ; `testAuditDriveTestAtAccessibilityTextSize`.
                // Le bouton de démarrage est nommé par son libellé : l'identifiant
                // posé sur `GradientButton` ne descend pas jusqu'à son texte.
                "drivetest.", "Démarrer le Drive Test",
                // Lot 4d : texte de l'étiquette d'un `Menu` (pastille opérateur de la
                // Carte), en `.subheadline` ; la Carte passe en AX XXL (TRX-38).
                "map.operator.label",
                // Lot 4e : textes de la messagerie et de la fin d'appel, en styles
                // relatifs ; `testAuditMessagingAtAccessibilityTextSize` et
                // `testAuditCallEndAtAccessibilityTextSize` les rendent en AX XXL.
                "message.", "messages.row.", "conversation.title", "conversation.status",
                "liveshare.", "call.end.caption"
            ]
            if issue.auditType == .dynamicType,
               semanticDynamicIdentifiers.contains(where: name.hasPrefix) {
                return exclude("style sémantique revu à AX XXL", name, issue.auditType)
            }
            // Ratios calculés sur les couleurs réellement compositées :
            // `DesignTokenContrastTests` verrouille ces couples à >= 4,5:1
            // (>= 8:1 pour le héros dense). L'auditeur iOS 27 attribue parfois
            // le fond du verre ou de la vue parente au texte SwiftUI.
            let provenContrastIdentifiers = [
                "home.action.subtitle.", "community.networkPulse", "feed.tag",
                "feed.metric.", "feed.speedtest.subtitle", "profile.menu.title",
                "community.header.action.", "feed.metadata", "speedtest.metric.",
                "profile.progression.tile.", "feed.hashtag", "home.network.title",
                "map.friends.count", "map.friends.empty",
                "map.status.text", "state.error.title",
                // Encre sur la carte et sur la tuile du pouls (Lot 4a), pastille
                // Drive Test et historique du compte (Lot 4b) :
                // `testBodyTextTokensMeetAA`, plus de 11:1.
                "home.nearby.context", "home.pulse.unit",
                "speedtest.driveTest.label", "speedtest.account.",
                // Bilan du dernier trajet, à l'encre sur `surfaceMuted` (Lot 4c).
                "drivetest.lastTrip.",
                // Messagerie (Lot 4e) : `label`/`labelSecondary`/`accentInk` sur
                // les surfaces, `onAccent` sur brique, `dangerInk` sur `surfaceMuted`
                // (`testBodyTextTokensMeetAA`, `testSemanticTokensMeetAA`,
                // `testOnAccentIsReadableOnBrandSurface`).
                "message.text", "message.time", "messages.row.", "liveshare.",
                "conversation.stamp", "conversation.status"
            ]
            if issue.auditType == .contrast,
               provenContrastIdentifiers.contains(where: name.hasPrefix) {
                return exclude("couple couleur verrouillé par DesignTokenContrastTests", name, issue.auditType)
            }
            // Un nœud SwiftUI sans élément ni frame ne permet aucune action
            // utilisateur et correspond ici aux séparateurs/fonds décoratifs.
            // Accueil (Lot 4a) : deux nœuds de ce type depuis « Autour de toi » ;
            // ni les points de couleur ni les ⓘ (expériences du 29/09), et chaque
            // texte de l'écran est audité sous son propre identifiant.
            if element == nil, name == "sans nom", issue.auditType == .contrast,
               screen.hasPrefix("Communauté") || screen.hasPrefix("Profil") || screen.hasPrefix("Accueil") {
                return exclude("fond décoratif sans élément ni action ; texte testé séparément", name, issue.auditType)
            }
            // Ces avertissements sont des prédictions à taille normale. Ils ne
            // sont ignorés que pour les composants rendus de nouveau dans la
            // passe AX XXL, où `.textClipped` reste bloquant : l'exclusion
            // valait aussi dans cette passe, qui ne gardait donc rien (Lot 4c).
            let rendersLargeText = screen.hasSuffix("texte accessibilité")
            if issue.auditType == .textClipped,
               (semanticDynamicIdentifiers.contains(where: name.hasPrefix) && !rendersLargeText) ||
                (element == nil && screen.hasPrefix("Communauté")) {
                return exclude("composant revu à AX XXL avec textClipped bloquant", name, issue.auditType)
            }
            issues.append("[\(Self.name(for: issue.auditType))] « \(name) » \(frame) · \(detail)")
            return !blocking   // `true` = problème ignoré
          }
        } catch {
            XCTFail("Auditeur indisponible ou problème bloquant sur \(screen) : \(error)", file: file, line: line)
        }
        if !exclusions.isEmpty {
            let report = XCTAttachment(string: exclusions.joined(separator: "\n"))
            report.name = "Exclusions a11y — \(screen)"
            report.lifetime = .keepAlways
            add(report)
            print("SQ_A11Y \(screen) : \(exclusions.count) exclusion(s) documentée(s)")
        }
        if !issues.isEmpty {
            let report = XCTAttachment(string: issues.joined(separator: "\n"))
            report.name = "Audit a11y — \(screen)"
            report.lifetime = .keepAlways
            add(report)
            print("SQ_A11Y \(screen) : \(issues.count) problème(s)")
            // Pas de troncature : un plafond ici fausserait silencieusement
            // toute agrégation par type faite sur la sortie.
            for i in issues { print("SQ_A11Y   \(i)") }
        } else {
            print("SQ_A11Y \(screen) : aucun problème")
        }
    }

    private func launch(_ arguments: [String] = ["--mock-auth"]) -> XCUIApplication {
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: arguments)
        return app
    }

    func testAuditPrimaryTabs() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Auditeur Apple indisponible avant iOS 17") }
        let app = launch()
        var visited = 0
        for name in SignalQuestUITestSupport.tabs {
            let tab = SignalQuestUITestSupport.tab(named: name, in: app)
            guard tab.waitForExistence(timeout: 20) else {
                XCTFail("Onglet attendu absent de l'audit : \(name)")
                continue
            }
            tab.tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
            audit(app, screen: name, blocking: true)
            visited += 1
        }
        print("SQ_A11Y onglets standard : \(visited)/\(SignalQuestUITestSupport.tabs.count) audités")
        XCTAssertEqual(visited, SignalQuestUITestSupport.tabs.count)
    }

    /// Drive Test (Lot 4c) : explication, puis carte et panneau avec le trajet
    /// de démonstration, comme le voit l'utilisateur.
    func testAuditDriveTest() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Auditeur Apple indisponible avant iOS 17") }
        let app = launch(["--mock-auth", "-drivetest_speedtests_disclosure_seen_v2", "NO"])
        let speed = SignalQuestUITestSupport.tab(named: "Tester", in: app)
        XCTAssertTrue(speed.waitForExistence(timeout: 20), "Onglet Tester absent de l'audit Drive Test")
        speed.tap()
        let entry = app.buttons["Mode Drive Test"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Entrée Drive Test introuvable")
        entry.tap()
        let acknowledge = app.buttons["J'ai compris"].firstMatch
        XCTAssertTrue(acknowledge.waitForExistence(timeout: 8), "Explication du Drive Test absente")
        audit(app, screen: "Drive Test — explication", blocking: true)
        acknowledge.tap()
        _ = acknowledge.waitForNonExistence(timeout: 5)
        XCTAssertTrue(app.buttons["Démarrer le Drive Test"].waitForExistence(timeout: 8))
        audit(app, screen: "Drive Test", blocking: true)
    }

    /// Rendu réel à AX XXL : le panneau défile, rien ne doit être coupé.
    func testAuditDriveTestAtAccessibilityTextSize() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Auditeur Apple indisponible avant iOS 17") }
        let app = launch([
            "--mock-auth", "-drivetest_speedtests_disclosure_seen_v2", "YES",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"
        ])
        let speed = SignalQuestUITestSupport.tab(named: "Tester", in: app)
        XCTAssertTrue(speed.waitForExistence(timeout: 20), "Onglet Tester absent de l'audit Drive Test AX XXL")
        speed.tap()
        let entry = app.buttons["Mode Drive Test"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Entrée Drive Test introuvable")
        entry.tap()
        XCTAssertTrue(app.buttons["drivetest.start"].waitForExistence(timeout: 10))
        audit(app, screen: "Drive Test — texte accessibilité", blocking: true, types: Self.renderedLargeTextTypes)
    }

    func testAuditSettings() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Auditeur Apple indisponible avant iOS 17") }
        let app = launch()
        let profile = SignalQuestUITestSupport.tab(named: "Profil", in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 20), "Profil absent de l'audit Réglages")
        profile.tap()
        let entry = app.staticTexts["Réglages"]
        guard entry.waitForExistence(timeout: 15) else {
            return XCTFail("Entrée Réglages introuvable depuis le profil")
        }
        entry.tap()
        _ = app.switches.firstMatch.waitForExistence(timeout: 10)
        audit(app, screen: "Réglages", blocking: true)
        app.swipeUp()
        let oledHelp = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "En thème sombre, les fonds passent au noir pur"
        )).firstMatch
        XCTAssertTrue(oledHelp.isHittable, "Aide OLED non visible après défilement")
        let dock = app.descendants(matching: .any)["main.navigation"]
        if dock.exists {
            XCTAssertLessThan(oledHelp.frame.maxY, dock.frame.minY,
                              "Aide OLED encore sous la navigation")
        }
        // Ce contrôle prouve que le texte exclu sous le verre est réellement
        // atteignable sur sa propre surface après défilement. Le contraste des
        // jetons `SQColor.label`/`SQColor.surface` est testé séparément.
    }

    func testAuditPrimaryTabsAtAccessibilityTextSize() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Auditeur Apple indisponible avant iOS 17") }
        let app = launch([
            "--mock-auth",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXL"
        ])
        var visited = 0
        for name in SignalQuestUITestSupport.tabs {
            let tab = SignalQuestUITestSupport.tab(named: name, in: app)
            guard tab.waitForExistence(timeout: 20) else {
                XCTFail("Onglet attendu absent de l'audit AX XXL : \(name)")
                continue
            }
            tab.tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
            audit(
                app,
                screen: "\(name) — texte accessibilité",
                blocking: true,
                types: Self.renderedLargeTextTypes
            )
            visited += 1
        }
        print("SQ_A11Y onglets AX XXL : \(visited)/\(SignalQuestUITestSupport.tabs.count) audités")
        XCTAssertEqual(visited, SignalQuestUITestSupport.tabs.count)
    }

    /// Messagerie (Lot 4e) : liste des conversations puis conversation, telles
    /// qu'on les ouvre depuis Communauté.
    func testAuditMessaging() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Auditeur Apple indisponible avant iOS 17") }
        let app = launch()
        openDemoConversation(in: app) { screen in
            audit(app, screen: "Messagerie — \(screen)", blocking: true)
        }
    }

    func testAuditMessagingAtAccessibilityTextSize() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Auditeur Apple indisponible avant iOS 17") }
        let app = launch([
            "--mock-auth",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXL"
        ])
        openDemoConversation(in: app) { screen in
            audit(app, screen: "Messagerie — \(screen) — texte accessibilité", blocking: true,
                  types: Self.renderedLargeTextTypes)
        }
    }

    /// Fin d'appel expliquée (SOC-13) : le simulateur n'aboutit à aucun vrai
    /// appel, l'écran est donc ouvert par son point d'entrée QA.
    func testAuditCallEnd() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Auditeur Apple indisponible avant iOS 17") }
        let app = launch(["--mock-auth", "--qa-call-ended"])
        XCTAssertTrue(app.buttons["call.end.redial"].waitForExistence(timeout: 20), "Écran de fin d'appel absent")
        audit(app, screen: "Appel — fin", blocking: true)
        app.buttons["call.end.close"].tap()
        XCTAssertTrue(app.buttons["call.end.close"].waitForNonExistence(timeout: 5), "« Fermer » laisse l'écran d'appel ouvert")
    }

    func testAuditCallEndAtAccessibilityTextSize() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Auditeur Apple indisponible avant iOS 17") }
        let app = launch([
            "--mock-auth", "--qa-call-ended",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"
        ])
        XCTAssertTrue(app.buttons["call.end.redial"].waitForExistence(timeout: 20), "Écran de fin d'appel absent")
        audit(app, screen: "Appel — fin — texte accessibilité", blocking: true, types: Self.renderedLargeTextTypes)
    }

    private func openDemoConversation(in app: XCUIApplication, audit: (String) -> Void) {
        SignalQuestUITestSupport.openMessages(in: app)
        let unlockCancel = app.buttons["Annuler"].firstMatch
        if unlockCancel.waitForExistence(timeout: 3) { unlockCancel.tap() }
        let row = app.staticTexts["SignalQuest iOS"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Conversation de démonstration absente")
        audit("liste")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let bubble = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "Tu peux partager un post"
        )).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "Conversation non ouverte")
        audit("conversation")
    }

    func testAuditSentinelleAtAccessibilityTextSize() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Auditeur Apple indisponible avant iOS 17") }
        let app = launch([
            "--mock-auth",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXL"
        ])
        let profile = SignalQuestUITestSupport.tab(named: "Profil", in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 20), "Profil absent de l'audit Sentinelle")
        profile.tap()
        let settings = app.staticTexts["Réglages"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "Entrée Réglages introuvable")
        settings.tap()
        let sentinelle = app.staticTexts["Sentinelle"]
        // À 200 %, la section Sentinelle est légitimement sous le viewport :
        // l'audit doit tester le défilement réel, pas exiger qu'elle soit visible
        // sans geste malgré l'agrandissement du contenu précédent.
        for _ in 0..<4 where !sentinelle.exists {
            app.swipeUp()
        }
        XCTAssertTrue(sentinelle.waitForExistence(timeout: 10), "Entrée Sentinelle introuvable après défilement")
        sentinelle.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        audit(app, screen: "Sentinelle — texte accessibilité", blocking: true)
    }
}
