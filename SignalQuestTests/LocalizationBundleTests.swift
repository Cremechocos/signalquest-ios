import Foundation
import XCTest
@testable import SignalQuest

final class LocalizationBundleTests: XCTestCase {
    func testCompiledSettingsAndWidgetQualityLabelsInEnglishAndFrench() throws {
        let app = Bundle.main
        let widgetURL = app.bundleURL.appendingPathComponent("PlugIns/SignalQuestWidget.appex")
        let widget = try XCTUnwrap(Bundle(url: widgetURL))
        let english = Locale(identifier: "en")
        let face = "Face ID"
        let biometricTitle: String.LocalizationValue = "Messagerie chiffrée via \(face)"
        XCTAssertEqual(String(localized: biometricTitle, bundle: app, locale: english),
            "Encrypted messages with Face ID")

        for (key, value) in ["Alerte zone mal couverte": "Poor coverage alert",
                             "Mode terrain": "Field mode",
                             "Noir intense (OLED)": "Pure black (OLED)"] {
            XCTAssertEqual(String(localized: String.LocalizationValue(key), bundle: app,
                locale: english), value)
        }
        for (key, value) in ["Très bon": "Very good", "Bon": "Good",
                             "Moyen": "Fair", "Lent": "Slow", "Très lent": "Very slow"] {
            XCTAssertEqual(String(localized: String.LocalizationValue(key), bundle: widget,
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

    /// Chaque variante `fr-x-formal` garde exactement les mêmes substitutions que la
    /// chaîne française d'origine : sinon un `String(format:)` lirait un argument de
    /// travers dès que le vouvoiement est actif.
    func testFormalVariantsKeepTheFrenchPlaceholders() throws {
        func strings(_ localization: String) throws -> [String: String] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                subdirectory: "\(localization).lproj"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), options: [], format: nil) as? [String: String])
        }
        let pattern = try NSRegularExpression(
            pattern: "%(?:\\d+\\$)?[-+ 0#]*\\d*(?:\\.\\d+)?(?:ll|l|h)?[@dDuUxXfFeEgGcCsSp]")
        func placeholders(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: range)
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
        }
        let formal = try strings(SQAddress.formalLocalization)
        let french = try strings("fr")
        XCTAssertGreaterThan(formal.count, 500)
        for (key, value) in formal {
            XCTAssertEqual(placeholders(value), placeholders(french[key] ?? key), "Substitutions : \(key)")
        }
    }

    /// En français, le vouvoiement actif redirige `NSLocalizedString` et
    /// `String(localized:)` vers `fr-x-formal` ; une clé sans variante reste en tutoiement.
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
        XCTAssertEqual(String(localized: String.LocalizationValue(key)), formalText)
        XCTAssertEqual(Bundle.main.localizedString(forKey: "Tutoiement", value: nil, table: nil), "Tutoiement")
    }
}
