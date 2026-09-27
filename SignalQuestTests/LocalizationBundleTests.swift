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
        for (key, value) in ["Très bon": "Very good", "Rapide": "Fast",
                             "Correct": "Fair", "Lent": "Slow", "Faible": "Weak"] {
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
}
