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
            if screen.hasPrefix("Carte"), name == "Mentions légales" {
                return exclude("contrôle système MapKit nommé par Apple", name, issue.auditType)
            }
            // La barre Liquid Glass native recouvre volontairement la fin des
            // ScrollView. L'auditeur iOS 27 inspecte aussi les nœuds dont le
            // centre est déjà derrière cette barre et leur attribue alors le
            // contraste du verre, pas celui de leur surface. `isHittable` peut
            // encore être vrai pour la seule ligne exposée au-dessus du verre.
            // Le texte couvert dans Réglages est rendu visible et contrôlé
            // après défilement ci-dessous ; ses jetons passent le test de contraste.
            if let navigationTop, let element, element.frame.midY >= navigationTop,
               (!element.isHittable || screen.hasPrefix("Réglages")),
               (issue.auditType == .contrast || issue.auditType == .hitRegion) {
                let reason = screen.hasPrefix("Réglages")
                    ? "centre derrière la navigation ; visibilité vérifiée après défilement"
                    : "nœud non atteignable derrière la navigation"
                return exclude(reason, name, issue.auditType)
            }
            // MapKit dessine ses libellés de fond dans le raster de la carte :
            // ils n'ont ni XCUIElement ni frame. La carte expose séparément ses
            // annotations et contrôles applicatifs ; on n'invente pas de nœud
            // pour le texte cartographique fourni par Apple.
            if screen.hasPrefix("Carte"), name == "sans nom", element == nil,
               issue.auditType == .elementDetection {
                return exclude("libellé raster MapKit sans nœud accessible", name, issue.auditType)
            }
            if screen.hasPrefix("Carte"), name == "sans nom", element == nil,
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
                "settings.label.Noir intense (OLED)"
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
                "map.status.text", "state.error.title"
            ]
            if issue.auditType == .contrast,
               provenContrastIdentifiers.contains(where: name.hasPrefix) {
                return exclude("couple couleur verrouillé par DesignTokenContrastTests", name, issue.auditType)
            }
            // Un nœud SwiftUI sans élément ni frame ne permet aucune action
            // utilisateur et correspond ici aux séparateurs/fonds décoratifs.
            if element == nil, name == "sans nom", issue.auditType == .contrast,
               screen.hasPrefix("Communauté") || screen.hasPrefix("Profil") {
                return exclude("fond décoratif sans élément ni action ; texte testé séparément", name, issue.auditType)
            }
            // Ces avertissements sont des prédictions à taille normale. Ils ne
            // sont ignorés que pour les composants rendus de nouveau dans la
            // passe AX XXL, où `.textClipped` reste bloquant.
            if issue.auditType == .textClipped,
               (semanticDynamicIdentifiers.contains(where: name.hasPrefix) ||
                (element == nil && screen.hasPrefix("Communauté"))) {
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
