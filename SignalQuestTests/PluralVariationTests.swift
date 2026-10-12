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

    func testAppAndExtensionsUseEnglishFallbackAndKeepFrench() throws {
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugIns.appendingPathComponent("SignalQuestWidget.appex")))
        let notifications = try XCTUnwrap(Bundle(url: plugIns.appendingPathComponent("SignalQuestNotificationService.appex")))
        for bundle in [Bundle.main, widget, notifications] {
            XCTAssertEqual(bundle.developmentLocalization, "en", bundle.bundlePath)
            for locale in ["fr", "en"] {
                XCTAssertNotNil(bundle.path(forResource: locale, ofType: "lproj"), "\(locale) absent de \(bundle.bundlePath)")
            }
        }
        for (bundle, key, english, french) in [
            (Bundle.main, "Aucun site sélectionné.", "No site selected.", "Aucun site sélectionné."),
            (widget, "Aucun test", "No test", "Aucun test"),
            (notifications, "Nouveau message chiffré", "New encrypted message", "Nouveau message chiffré"),
        ] {
            for (locale, expected) in [("en", english), ("fr", french)] {
                let localized = try XCTUnwrap(bundle.path(forResource: locale, ofType: "lproj").flatMap(Bundle.init(path:)))
                XCTAssertEqual(localized.localizedString(forKey: key, value: "MISSING", table: nil), expected)
            }
        }
    }

    func testEnglishPermissionPromptsAreCompiled() throws {
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSLocationWhenInUseUsageDescription", "NSFaceIDUsageDescription", "NSPhotoLibraryUsageDescription"] {
            let value = english.localizedString(forKey: key, value: "MISSING", table: "InfoPlist")
            XCTAssertTrue(value.hasPrefix("SignalQuest"), "Traduction anglaise absente : \(key)")
            XCTAssertFalse(value.contains(" utilise "), "Repli français inattendu : \(key)")
        }
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

extension PluralVariationTests {
    private func served(_ key: String.LocalizationValue, _ language: String) throws -> String {
        let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
        return String(localized: key, bundle: bundle, locale: Locale(identifier: language))
    }

    /// Décomptes des relevés radio, de la vie privée, du dock et de l'accueil :
    /// une seule clé au singulier, et chaque langue applique sa propre règle.
    func testCountersFollowEachLanguagePluralRule() throws {
        let cases: [(String.LocalizationValue, String.LocalizationValue, String, String, String, String)] = [
            ("\(0) relevé", "\(2) relevé", "0 relevé", "2 relevés", "0 measurements", "2 measurements"),
            ("\(0) site", "\(1) site", "0 site", "1 site", "0 sites", "1 site"),
            ("\(0) mesure", "\(1) mesure", "0 mesure", "1 mesure", "0 measurements", "1 measurement"),
            ("\(1) conversation non lue", "\(3) conversation non lue", "1 conversation non lue", "3 conversations non lues", "1 unread conversation", "3 unread conversations"),
            ("\(1) lieu détecté automatiquement", "\(2) lieu détecté automatiquement", "1 lieu détecté automatiquement", "2 lieux détectés automatiquement", "1 automatically detected place", "2 automatically detected places"),
            ("\(1) masqué sur la carte", "\(2) masqué sur la carte", "1 masqué sur la carte", "2 masqués sur la carte", "1 hidden on the map", "2 hidden on the map"),
            ("\(1) cellule", "\(2) cellule", "1 cellule", "2 cellules", "1 cell", "2 cells"),
            ("\(1) secteur", "\(3) secteur", "1 secteur", "3 secteurs", "1 sector", "3 sectors"),
            ("\(0) site identifié", "\(2) site identifié", "0 site identifié", "2 sites identifiés", "0 sites identified", "2 sites identified"),
            ("\(1) visite", "\(4) visite", "1 visite", "4 visites", "1 visit", "4 visits"),
            ("+ \(1) autre session", "+ \(2) autre session", "+ 1 autre session", "+ 2 autres sessions", "+ 1 other session", "+ 2 other sessions"),
        ]
        for (first, second, frFirst, frSecond, enFirst, enSecond) in cases {
            XCTAssertEqual(try served(first, "fr"), frFirst)
            XCTAssertEqual(try served(second, "fr"), frSecond)
            XCTAssertEqual(try served(first, "en"), enFirst)
            XCTAssertEqual(try served(second, "en"), enSecond)
        }
        XCTAssertEqual(try served("Dernier état connu conservé.", "en"), "Last known state kept.")
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugIns.appendingPathComponent("SignalQuestWidget.appex")))
        for (language, one, many) in [("fr", "1 test", "3 tests"), ("en", "1 test", "3 tests")] {
            let bundle = try XCTUnwrap(widget.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            XCTAssertEqual(String(localized: "\(1) test", bundle: bundle, locale: Locale(identifier: language)), one)
            XCTAssertEqual(String(localized: "\(3) test", bundle: bundle, locale: Locale(identifier: language)), many)
        }
    }
}
