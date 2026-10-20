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
    }
}
