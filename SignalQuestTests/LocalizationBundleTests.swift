import Foundation
import XCTest
@testable import SignalQuest

final class LocalizationBundleTests: XCTestCase {
    func testCompiledSettingsAndWidgetQualityLabelsInEnglishAndFrench() throws {
        let app = Bundle.main
        let widgetURL = app.bundleURL.appendingPathComponent("PlugIns/SignalQuestWidget.appex")
        let widget = try XCTUnwrap(Bundle(url: widgetURL))
        // `locale:` ne choisit pas la langue de la table : celle-ci suit la langue
        // de l'app. On lit donc directement le dossier anglais de chaque paquet.
        func englishBundle(_ bundle: Bundle) throws -> Bundle {
            try XCTUnwrap(bundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        }
        let appEnglish = try englishBundle(app)
        let widgetEnglish = try englishBundle(widget)
        let english = Locale(identifier: "en")
        let face = "Face ID"
        let biometricTitle: String.LocalizationValue = "Messagerie chiffrée via \(face)"
        XCTAssertEqual(String(localized: biometricTitle, bundle: appEnglish, locale: english),
            "Encrypted messages with Face ID")

        for (key, value) in ["Alerte zone mal couverte": "Poor coverage alert",
                             "Mode terrain": "Field mode",
                             "Noir intense (OLED)": "Pure black (OLED)"] {
            XCTAssertEqual(String(localized: String.LocalizationValue(key), bundle: appEnglish,
                locale: english), value)
        }
        for (key, value) in ["Très bon": "Very good", "Bon": "Good",
                             "Moyen": "Fair", "Lent": "Slow", "Très lent": "Very slow"] {
            XCTAssertEqual(String(localized: String.LocalizationValue(key), bundle: widgetEnglish,
                locale: english), value)
        }

        func frenchStrings(_ bundle: Bundle) throws -> [String: String] {
            let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings",
                subdirectory: "fr.lproj"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), options: [], format: nil) as? [String: String])
        }
        let appFrench = try frenchStrings(app)
        let widgetFrench = try frenchStrings(widget)
        XCTAssertEqual(appFrench["Alerte zone mal couverte"], "Alerte zone mal couverte")
        XCTAssertEqual(widgetFrench["Très bon"], "Très bon")
    }

    /// Chaque variante au vous (`SQFormal|<clé>`) garde exactement les mêmes
    /// substitutions que la chaîne française d'origine : sinon un `String(format:)`
    /// lirait un argument de travers dès que le vouvoiement est actif.
    func testFormalVariantsKeepTheFrenchPlaceholders() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
            subdirectory: "fr.lproj"))
        let french = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil) as? [String: String])
        let pattern = try NSRegularExpression(
            pattern: "%(?:\\d+\\$)?[-+ 0#]*\\d*(?:\\.\\d+)?(?:ll|l|h)?[@dDuUxXfFeEgGcCsSp]")
        func placeholders(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            // Xcode numérote parfois les substitutions à la génération (`%1$@`) : la
            // position ne compte pas ici, seulement le genre et le nombre.
            return pattern.matches(in: text, range: range)
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                .map { $0.replacingOccurrences(of: "\\d+\\$", with: "", options: .regularExpression) }
                .sorted()
        }
        let prefix = SQAddress.formalKeyPrefix
        let formal = french.filter { $0.key.hasPrefix(prefix) }
        XCTAssertGreaterThan(formal.count, 500)
        for (formalKey, value) in formal {
            let key = String(formalKey.dropFirst(prefix.count))
            XCTAssertEqual(placeholders(value), placeholders(french[key] ?? key), "Substitutions : \(key)")
        }
    }

    /// App Store Connect refuse de reconnaître une langue privée (ITMS-90176) :
    /// l'app et ses extensions n'embarquent que le français, l'anglais et Base.
    func testBundlesShipOnlyRecognisedLanguages() throws {
        let app = Bundle.main
        let plugIns = try FileManager.default.contentsOfDirectory(
            at: app.bundleURL.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)
        for bundle in [app] + plugIns.compactMap(Bundle.init(url:)) {
            XCTAssertTrue(Set(bundle.localizations).isSubset(of: ["fr", "en", "Base"]),
                "\(bundle.bundleURL.lastPathComponent) : \(bundle.localizations.sorted())")
        }
    }

    /// L'anglais de l'appareil choisit l'orthographe : ce que Foundation range sous
    /// en-GB (France, Belgique, Suisse, Australie…) lit le britannique, en-CA le
    /// canadien, le reste l'américain. Rejoué sur iOS, quelle que soit la langue du test.
    func testEnglishSpellingFollowsTheDeviceEnglish() {
        let cases: [([String], SQEnglishSpelling)] = [
            (["en-US"], .american), (["en"], .american), (["en-GB"], .british), (["en-FR"], .british),
            (["en-BE"], .british), (["en-CH"], .british), (["en-AU"], .british), (["en-IE"], .british),
            (["en-CA"], .canadian), (["fr-CA", "en-CA"], .canadian), (["fr-FR", "en-GB"], .british)]
        for (preferences, expected) in cases {
            XCTAssertEqual(SQEnglishSpelling.resolve(appLanguage: "en", preferences: preferences), expected, "\(preferences)")
        }
        XCTAssertNil(SQEnglishSpelling.resolve(appLanguage: "fr", preferences: ["en-GB"]))
    }

    /// Paquet britannique ou canadien : la variante quand elle existe, l'anglais
    /// américain sinon (jamais le français), pluriels compris ; sans dépendre de la
    /// langue du test.
    func testEnglishVariantBundlesFallBackToAmericanEnglish() throws {
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(english.localizedString(forKey: "Couleur des points", value: nil, table: nil), "Point color")
        let count = 4
        for (prefix, authorised, postcode) in [("SQEnGB|", "Authorised sites", "Postcode"),
                                               ("SQEnCA|", "Authorized sites", "Postal code")] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SQEnglishTest-\(UUID().uuidString).bundle", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = try XCTUnwrap(SQAddress.makeVariantBundle(from: .main, at: root, language: "en", keyPrefix: prefix))
            XCTAssertEqual(String(localized: "Couleur des points", bundle: bundle), "Point colour", prefix)
            XCTAssertEqual(String(localized: "Sites autorisés", bundle: bundle), authorised, prefix)
            XCTAssertEqual(String(localized: "Code postal", bundle: bundle), postcode, prefix)
            XCTAssertEqual(String(localized: "Annuler", bundle: bundle), "Cancel", prefix)
            XCTAssertEqual(String(localized: "Partagé · \(count) opérateurs", bundle: bundle), "Shared · 4 operators", prefix)
        }
    }

    /// Dans l'app, `NSLocalizedString`, `Bundle.main` (dont la version attribuée que lit
    /// SwiftUI) et `String(localized:)` lisent la même orthographe ; une clé sans
    /// variante garde l'anglais américain.
    func testAppLookupsUseTheDeviceEnglishSpelling() throws {
        guard let spelling = SQEnglishSpelling.current else {
            throw XCTSkip("Test à lancer avec -testLanguage en, en-GB ou en-CA")
        }
        SQAddress.install()
        let colour = spelling == .american ? "Point color" : "Point colour"
        XCTAssertEqual(NSLocalizedString("Couleur des points", comment: ""), colour)
        XCTAssertEqual(Bundle.main.localizedString(forKey: "Couleur des points", value: nil, table: nil), colour)
        XCTAssertEqual(Bundle.main.__localizedAttributedString(forKey: "Couleur des points", value: nil, table: nil).string, colour)
        XCTAssertEqual(String(localized: "Couleur des points"), colour)
        XCTAssertEqual(String(localized: "Sites autorisés"), spelling == .british ? "Authorised sites" : "Authorized sites")
        XCTAssertEqual(NSLocalizedString("Annuler", comment: ""), "Cancel")
        XCTAssertEqual(String(localized: "Annuler"), "Cancel")
        let count = 4
        XCTAssertEqual(String(localized: "Partagé · \(count) opérateurs"), "Shared · 4 operators")
    }

    /// L'anglais de base s'écrit à l'américaine ; `SQEnGB|` à la britannique, `SQEnCA|`
    /// à la canadienne (-our, -re, licence, catalogue, cancelled, mais -ize). Chaque
    /// orthographe est lue telle que l'app la voit : la variante, sinon l'américain.
    /// Une nouvelle chaîne écrite avec « color » ou « canceled » fait échouer ce test
    /// tant que ses clés `SQEnGB|` et `SQEnCA|` manquent.
    func testEachEnglishSpellingKeepsItsOwnWords() throws {
        func leaves(_ value: Any) -> [String] {
            if let text = value as? String { return [text] }
            guard let dict = value as? [String: Any] else { return [] }
            return dict.filter { !$0.key.hasPrefix("NSStringFormat") }.values.flatMap(leaves)
        }
        var table: [String: [String]] = [:]
        for ext in ["strings", "stringsdict"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: ext, subdirectory: "en.lproj"))
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), options: [], format: nil) as? [String: Any])
            for (key, value) in plist { table[key] = leaves(value) }
        }
        let prefixes = [SQAddress.formalKeyPrefix, "SQEnGB|", "SQEnCA|"]
        let american = table.filter { entry in !prefixes.contains { entry.key.hasPrefix($0) } }
        XCTAssertGreaterThan(american.count, 5000)
        func variant(_ prefix: String) -> [String: [String]] {
            let own = Dictionary(uniqueKeysWithValues: table.filter { $0.key.hasPrefix(prefix) }
                .map { (String($0.key.dropFirst(prefix.count)), $0.value) })
            XCTAssertGreaterThan(own.count, 50, prefix)
            XCTAssertEqual(own.keys.filter { american[$0] == nil }.sorted(), [], "\(prefix) sans clé de base")
            return american.merging(own) { $1 }
        }
        let british = variant("SQEnGB|")
        let canadian = variant("SQEnCA|")

        let stems = ["recogni", "authori", "organi", "customi", "optimi", "prioriti", "summari", "synchroni",
                     "minimi", "maximi", "initiali", "anonymi", "personali", "visuali", "categori", "finali",
                     "reali", "normali", "standardi", "locali", "memori", "apologi", "emphasi", "utili",
                     "characteri", "seriali", "randomi", "moneti", "stabili", "centrali", "digiti"]
        let endings = ["e", "es", "ed", "ing", "ation", "ations", "er", "ers", "able"]
        // « analyses » manque exprès : c'est aussi le pluriel d'« analysis » en américain.
        let ise = stems.flatMap { stem in endings.map { stem + "s" + $0 } } + ["analyse", "analysed", "analysing"]
        let ize = stems.flatMap { stem in endings.map { stem + "z" + $0 } } + ["analyze", "analyzes", "analyzed", "analyzing"]
        // -our, -re, -ll, -ce, -ogue : commun au britannique et au canadien.
        let commonwealth = ["colour", "colours", "neighbour", "neighbours", "neighbouring", "favourite", "favourites",
                            "centre", "centres", "centred", "recentre", "metre", "metres", "kilometre", "kilometres",
                            "cancelled", "cancelling", "travelled", "travelling", "grey", "licence", "licences",
                            "catalogue", "catalogues"]
        let us = ["color", "colors", "neighbor", "neighbors", "neighboring", "favorite", "favorites",
                  "center", "centers", "centered", "recenter", "meter", "meters", "kilometer", "kilometers",
                  "canceled", "canceling", "traveled", "traveling", "gray", "license", "licenses",
                  "catalog", "catalogs"]

        func offenders(_ table: [String: [String]], _ words: [String]) -> [String] {
            let forbidden = Set(words)
            return table.flatMap { key, values in
                values.flatMap { value -> [String] in
                    // Nom de fonction Apple, écrit comme Apple l'écrit en anglais US.
                    let text = value.replacingOccurrences(of: "Control Center", with: "")
                    return text.lowercased().components(separatedBy: CharacterSet.letters.inverted)
                        .filter(forbidden.contains).map { "\($0) ← \(key)" }
                }
            }.sorted()
        }
        XCTAssertEqual(offenders(american, commonwealth + ise + ["programme", "postcode", "motorway", "ticked"]), [], "anglais US")
        XCTAssertEqual(offenders(british, us + ize), [], "britannique : il manque une clé SQEnGB|")
        XCTAssertEqual(offenders(canadian, us + ise + ["programme"]), [], "canadien : il manque une clé SQEnCA|")
    }

    /// En français, le vouvoiement actif redirige `NSLocalizedString` vers les clés
    /// `SQFormal|` ; une clé sans variante reste en tutoiement.
    func testFormalToneRoutesBundleLookups() throws {
        try XCTSkipUnless(SQAddress.appIsFrench, "Test à lancer avec -testLanguage fr")
        SQAddress.install()
        defer { SQAddress.setFormal(false) }
        let key = "Tu préfères qu’on te tutoie ou qu’on vous vouvoie ?"
        let formalText = "Préférez-vous que l’on vous tutoie ou que l’on vous vouvoie ?"

        SQAddress.setFormal(false)
        XCTAssertEqual(Bundle.main.localizedString(forKey: key, value: nil, table: nil), key)
        SQAddress.setFormal(true)
        XCTAssertEqual(Bundle.main.localizedString(forKey: key, value: nil, table: nil), formalText)
        XCTAssertEqual(NSLocalizedString(key, comment: ""), formalText)
        XCTAssertEqual(Bundle.main.localizedString(forKey: "Tutoiement", value: nil, table: nil), "Tutoiement")
    }

    /// Le paquet au vous reprend chaque table française et y pose les variantes
    /// `SQFormal|`, singulier comme pluriel, sans dépendre de la langue du test.
    func testFormalBundleSwapsInTheFormalVariants() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQFormalTest-\(UUID().uuidString).bundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let formal = try XCTUnwrap(SQAddress.makeFormalBundle(from: .main, at: root))
        let name = "Alex"
        XCTAssertEqual(String(localized: "\(name) partage avec toi", bundle: formal), "Alex partage avec vous")
        XCTAssertEqual(String(localized: "Reconnecte-toi pour modifier le verrouillage de SignalQuest.", bundle: formal),
                       "Reconnectez-vous pour modifier le verrouillage de SignalQuest.")
        let count = 3
        XCTAssertEqual(String(localized: "Autour de toi · \(count) jours", bundle: formal), "Autour de vous · 3 jours")
        // Sans variante, la chaîne française d'origine.
        XCTAssertEqual(String(localized: "Tutoiement", bundle: formal), "Tutoiement")
        // Une variante au vous garde les formes plurielles de l'original.
        let conflicts = 2
        XCTAssertEqual(String(AttributedString(localized: "**\(conflicts) identification en conflit** : un autre site a plus de validations sur cette antenne. Vérifie-la ou retire-la.", bundle: formal).characters),
                       "2 identifications en conflit : d’autres sites ont plus de validations sur ces antennes. Vérifiez-les ou retirez-les.")
    }

    /// Invitations faites à un invité sur la carte des changements et le comparatif de zone
    /// (`EmptyStateView`, clés lues à l'exécution) : au vous dans le paquet formel, et en anglais.
    func testGuestInvitationsHaveFormalAndEnglishText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQFormalTest-\(UUID().uuidString).bundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let formal = try XCTUnwrap(SQAddress.makeFormalBundle(from: .main, at: root))
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let cases: [(key: String, formal: String, english: String)] = [
            ("Réservé aux membres", "Réservé aux membres", "Members only"),
            ("Connecte-toi pour voir sur la carte les sites qui ont changé. Créer un compte est gratuit.",
             "Connectez-vous pour voir sur la carte les sites qui ont changé. Créer un compte est gratuit.",
             "Sign in to see the sites that changed on the map. Creating an account is free."),
            ("Connecte-toi pour comparer les antennes, les débits et le signal autour d’un point. Créer un compte est gratuit.",
             "Connectez-vous pour comparer les antennes, les débits et le signal autour d’un point. Créer un compte est gratuit.",
             "Sign in to compare antennas, throughput and signal around a point. Creating an account is free.")
        ]
        for item in cases {
            XCTAssertEqual(String(localized: String.LocalizationValue(item.key), bundle: formal), item.formal)
            XCTAssertEqual(english.localizedString(forKey: item.key, value: nil, table: nil), item.english)
        }
    }

    /// En français, le vouvoiement actif s'applique aussi aux phrases construites
    /// par `String(localized:)`, que `SQAddressBundle` ne voit pas.
    func testFormalToneRoutesStringLocalized() throws {
        try XCTSkipUnless(SQAddress.appIsFrench, "Test à lancer avec -testLanguage fr")
        SQAddress.install()
        defer { SQAddress.setFormal(false) }
        let name = "Alex"
        SQAddress.setFormal(false)
        XCTAssertEqual(String(localized: "\(name) partage avec toi"), "Alex partage avec toi")
        SQAddress.setFormal(true)
        XCTAssertEqual(String(localized: "\(name) partage avec toi"), "Alex partage avec vous")
        let count = 1
        XCTAssertEqual(String(AttributedString(localized: "**\(count) identification en conflit** : un autre site a plus de validations sur cette antenne. Vérifie-la ou retire-la.").characters),
                       "1 identification en conflit : un autre site a plus de validations sur cette antenne. Vérifiez-la ou retirez-la.")
    }

    /// `GradientButton` cherche déjà son titre `String` dans le catalogue. Un titre
    /// passé par `String(localized:)` serait traduit deux fois : en anglais, la
    /// traduction relue comme une clé donnait « Corriger » → « Correct » → « Okay »
    /// et « Relief » → « Terrain » → « Field ». Titre statique : la clé littérale ;
    /// titre construit : `GradientButton(verbatim:)`.
    func testGradientButtonTitlesAreNotLocalizedTwice() throws {
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(english.localizedString(forKey: "Corriger", value: nil, table: nil), "Correct")
        XCTAssertEqual(english.localizedString(forKey: "Correct", value: nil, table: nil), "Okay")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SignalQuestApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("GradientButton(String(localized:") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertGreaterThan(scanned, 100)
        XCTAssertEqual(offenders, [], "GradientButton(\"clé\") ou GradientButton(verbatim:)")
    }
}
