import XCTest
@testable import SignalQuest

/// Vérifie le manifeste de scènes réellement EMBARQUÉ dans l'app (Lot 0 et 9).
///
/// Ces déclarations n'ont aucun effet visible tant qu'un véhicule n'est pas
/// branché : une clé mal orthographiée, un nom de délégué qui ne correspond plus
/// après un renommage de classe, et CarPlay ne se connecte tout simplement
/// jamais — sans erreur, sans log, sans rien. C'est le genre de défaut qu'on
/// découvre dans une voiture, au pire moment.
final class CarPlaySceneManifestTests: XCTestCase {

    private var manifest: [String: Any] {
        Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any] ?? [:]
    }

    private var configurations: [String: Any] {
        manifest["UISceneConfigurations"] as? [String: Any] ?? [:]
    }

    private func configuration(forRole role: String) -> [String: Any]? {
        (configurations[role] as? [[String: Any]])?.first
    }

    /// CarPlay exige le multi-scènes. À `false`, UIKit refuse de créer la scène
    /// du véhicule et rien ne se connecte.
    func testMultipleScenesAreEnabled() {
        XCTAssertEqual(manifest["UIApplicationSupportsMultipleScenes"] as? Bool, true)
    }

    /// La scène principale CarPlay, avec sa classe et son délégué.
    func testCarPlaySceneIsDeclared() throws {
        let scene = try XCTUnwrap(
            configuration(forRole: "CPTemplateApplicationSceneSessionRoleApplication"),
            "Sans ce rôle, l'app n'apparaît pas dans le véhicule"
        )
        XCTAssertEqual(scene["UISceneClassName"] as? String, "CPTemplateApplicationScene")
        // `UISceneConfigurationName` est obligatoire : UIKit s'en sert comme clé
        // d'identité de session, et l'omettre est une cause classique de « la
        // scène ne se connecte jamais ».
        XCTAssertFalse((scene["UISceneConfigurationName"] as? String ?? "").isEmpty)
        XCTAssertEqual(scene["UISceneDelegateClassName"] as? String,
                       "SignalQuest.CarPlaySceneDelegate")
    }

    /// Le Dashboard N'EST PAS déclaré : il relève de `carplay-maps`, alors
    /// qu'Apple a accordé la catégorie « Driving Task ». Une scène que le système
    /// ne connectera jamais n'apporte rien et attire l'attention en revue.
    ///
    /// Ce test vaut rappel : le jour où la catégorie navigation serait obtenue,
    /// c'est lui qui devra être inversé, en même temps que la clé d'entitlement.
    func testDashboardSceneIsNotDeclaredWithoutTheMapsEntitlement() {
        XCTAssertNil(configurations["CPTemplateApplicationDashboardSceneSessionRoleApplication"])
    }


    /// Les classes nommées dans le plist doivent EXISTER sous ce nom exact :
    /// c'est `NSClassFromString` qui les résout au démarrage, donc un renommage
    /// de classe ne casserait rien à la compilation.
    func testDeclaredDelegateClassesResolveAtRuntime() throws {
        // Parcourt les rôles RÉELLEMENT déclarés plutôt qu'une liste en dur :
        // le Dashboard va et vient selon la catégorie CarPlay accordée, et ce
        // test doit rester juste dans les deux cas.
        XCTAssertFalse(configurations.isEmpty, "Aucune scène déclarée : CarPlay ne se connecterait pas")
        for (role, _) in configurations {
            let scene = try XCTUnwrap(configuration(forRole: role))
            let className = try XCTUnwrap(scene["UISceneDelegateClassName"] as? String)
            XCTAssertNotNil(NSClassFromString(className),
                            "\(className) est déclarée pour \(role) mais introuvable à l'exécution")
        }
    }

    /// On NE déclare PAS le rôle fenêtre : SwiftUI fournit sa propre
    /// configuration pour le `WindowGroup`. Le déclarer obligerait à nommer une
    /// classe de délégué de fenêtre et à reprendre à la main un chemin que
    /// SwiftUI gère — avec le risque de l'incident `@Sendable` documenté dans
    /// `SignalQuestApp.swift`.
    func testWindowSceneRoleIsLeftToSwiftUI() {
        XCTAssertNil(configurations["UIWindowSceneSessionRoleApplication"])
    }
}
