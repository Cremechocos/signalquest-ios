import XCTest

/// Passe l'auditeur d'accessibilité d'Apple sur les écrans principaux.
///
/// `performAccessibilityAudit` détecte ce qu'une relecture manque
/// systématiquement : élément sans description, texte tronqué aux grandes
/// tailles, contraste insuffisant, cible tactile trop petite, élément
/// interactif non détecté. C'est la façon la moins coûteuse de mesurer la
/// progression sur 60 000 lignes.
///
/// Démarré en mode RAPPORT : les problèmes sont journalisés et attachés au
/// résultat, sans faire échouer la suite. Chaque écran passe en mode bloquant
/// au fil de sa mise en conformité — sinon l'ensemble resterait rouge et on
/// cesserait de le regarder.
@MainActor
final class AccessibilityAuditTests: XCTestCase {

    @available(iOS 17.0, *)
    private static var auditedTypes: XCUIAccessibilityAuditType {
        [.contrast, .dynamicType, .elementDetection, .hitRegion,
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

    /// L'API est iOS 17+ alors que l'app cible iOS 16 : sur un simulateur plus
    /// ancien le test ne rapporte rien plutôt que d'échouer.
    private func audit(
        _ app: XCUIApplication, screen: String, blocking: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard #available(iOS 17.0, *) else {
            return print("SQ_A11Y \(screen) : audit indisponible avant iOS 17")
        }
        var issues: [String] = []
        try? app.performAccessibilityAudit(for: Self.auditedTypes) { issue in
            // `identifier` vaut souvent "" — non-nil, donc un `??` ne basculerait
            // jamais sur le libellé. On prend la première valeur NON VIDE, sans
            // quoi le rapport ne permet de localiser aucun élément.
            let element = issue.element
            let name = [element?.identifier, element?.label, element?.value as? String]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "sans nom"
            let frame = element.map { "\($0.frame)" } ?? ""
            let detail = (issue.detailedDescription ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            issues.append("[\(Self.name(for: issue.auditType))] « \(name) » \(frame) · \(detail)")
            return !blocking   // `true` = problème ignoré
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

    func testAuditPrimaryTabs() {
        let app = launch()
        for name in SignalQuestUITestSupport.tabs {
            let tab = SignalQuestUITestSupport.tab(named: name, in: app)
            guard tab.waitForExistence(timeout: 20) else { continue }
            tab.tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
            audit(app, screen: name, blocking: false)
        }
    }

    func testAuditSettings() {
        let app = launch()
        SignalQuestUITestSupport.tab(named: "Profil", in: app).tap()
        let entry = app.staticTexts["Réglages"]
        guard entry.waitForExistence(timeout: 15) else {
            return XCTFail("Entrée Réglages introuvable depuis le profil")
        }
        entry.tap()
        _ = app.switches.firstMatch.waitForExistence(timeout: 10)
        audit(app, screen: "Réglages", blocking: false)
    }
}
