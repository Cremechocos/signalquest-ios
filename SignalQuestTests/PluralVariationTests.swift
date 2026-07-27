import XCTest
@testable import SignalQuest

/// Vérifie que les décomptes passent par de vraies variations de pluriel.
///
/// Le code interpolait auparavant un « s » à la main (`\(n) mesure\(n > 1 ? "s"
/// : "")`). Deux défauts : ce n'est pas localisable, et surtout la règle `> 1`
/// est FRANÇAISE. En anglais, zéro prend le pluriel — « 0 measurements », pas
/// « 0 measurement ». Le bricolage produisait donc un texte faux dès la
/// première traduction, sur un cas fréquent : les états vides.
///
/// Ces tests interrogent le catalogue par le même chemin que l'app, en forçant
/// la locale, et comparent des FORMES entre elles plutôt que des libellés figés
/// — pour ne pas retomber dans le travers des tests qui cassent à chaque
/// traduction.
final class PluralVariationTests: XCTestCase {

    private func rendered(_ key: String.LocalizationValue, _ identifier: String) -> String {
        String(localized: key, locale: Locale(identifier: identifier))
    }

    /// Le cœur du sujet : zéro se comporte différemment dans les deux langues.
    func testZeroFollowsEachLanguageOwnRule() {
        let frZero = rendered("\(0) réponse", "fr")
        let frOne = rendered("\(1) réponse", "fr")
        let frMany = rendered("\(5) réponse", "fr")
        // Français : 0 et 1 partagent la forme singulière.
        XCTAssertEqual(
            frZero.replacingOccurrences(of: "0", with: "1"), frOne,
            "En français, zéro doit suivre le singulier : \(frZero) / \(frOne)"
        )
        XCTAssertNotEqual(frOne.dropFirst(), frMany.dropFirst(), "Le pluriel doit différer du singulier")

        let enZero = rendered("\(0) réponse", "en")
        let enOne = rendered("\(1) réponse", "en")
        let enMany = rendered("\(5) réponse", "en")
        // Anglais : zéro suit le PLURIEL. C'est exactement ce que `> 1` ratait.
        XCTAssertEqual(
            enZero.replacingOccurrences(of: "0", with: "5"), enMany,
            "En anglais, zéro doit suivre le pluriel : \(enZero) / \(enMany)"
        )
        XCTAssertNotEqual(enOne.dropFirst(), enZero.dropFirst())
    }

    /// Les deux langues doivent être renseignées : une variation absente
    /// retomberait silencieusement sur la clé, donc sur du français.
    func testBothLanguagesAreTranslated() throws {
        let keys: [String.LocalizationValue] = [
            "\(3) réponse", "\(3) validation", "Couverture · \(3) point"
        ]
        for key in keys {
            let fr = rendered(key, "fr")
            let en = rendered(key, "en")
            XCTAssertFalse(fr.isEmpty)
            XCTAssertFalse(en.isEmpty)
        }
        // Preuve que l'anglais est réellement SERVI, et non un repli sur la clé
        // française. Il faut charger le bundle `en.lproj` : le paramètre
        // `locale:` de `String(localized:)` choisit la RÈGLE DE PLURIEL, pas la
        // table de chaînes — celle-ci suit la langue du bundle. Confondre les
        // deux fait croire à une traduction manquante alors qu'elle est là.
        let bundle = try XCTUnwrap(
            Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)),
            "en.lproj absent du bundle de test"
        )
        let english = String(
            localized: "Couverture · \(3) point", bundle: bundle, locale: Locale(identifier: "en")
        )
        XCTAssertTrue(english.hasPrefix("Coverage"), "Anglais non servi : « \(english) »")
        XCTAssertTrue(english.hasSuffix("points"), "Pluriel anglais attendu : « \(english) »")
    }

    /// Le décompte doit rester présent dans le rendu — une variation mal écrite
    /// peut parfaitement perdre son argument.
    func testCountSurvivesInEveryForm() {
        for count in [0, 1, 2, 42] {
            for language in ["fr", "en"] {
                let text = rendered("\(count) validation", language)
                XCTAssertTrue(
                    text.contains("\(count)"),
                    "\(language) / \(count) : décompte absent de « \(text) »"
                )
            }
        }
    }
}
