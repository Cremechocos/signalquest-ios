import XCTest
@testable import SignalQuest

/// TRX-39 : aucune clé observée par @AppStorage n'a de point, et les valeurs des
/// anciennes clés suivent leurs utilisateurs à la mise à jour.
final class SQObservedDefaultsKeysTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SQObservedDefaultsKeysTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testOldValuesMoveToTheNewKeysOnce() {
        defaults.set(true, forKey: "sq.hasCompletedOnboarding")
        defaults.set(true, forKey: "sq.fieldMode.enabled")
        defaults.set(120.0, forKey: "sq.security.appLockGraceSeconds")
        // Déjà écrite sous la nouvelle clé : elle l'emporte.
        defaults.set(true, forKey: "sq.browseAsGuest")
        defaults.set(false, forKey: RootView.guestPreferenceKey)

        SQObservedDefaultsKeys.migrate(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: OnboardingEntryState.completionKey), "L'onboarding vu ne revient pas")
        XCTAssertTrue(defaults.bool(forKey: SQFieldMode.storageKey))
        XCTAssertEqual(defaults.double(forKey: AppLockSettings.lockGraceKey), 120)
        XCTAssertFalse(defaults.bool(forKey: RootView.guestPreferenceKey), "La nouvelle clé déjà écrite l'emporte")
        XCTAssertNil(defaults.object(forKey: AppLockSettings.enabledKey), "Rien d'inventé sans ancienne valeur")
        XCTAssertTrue(defaults.bool(forKey: "sq.hasCompletedOnboarding"), "L'ancienne reste pour une version antérieure")
    }

    func testNoObservedKeyHasADot() throws {
        let constants = SQObservedDefaultsKeys.renamed.map(\.new) + [SQOledPalette.storageKey, MapBackdrop.storageKey]
        for key in constants {
            XCTAssertFalse(key.contains("."), key)
        }
        // Les clés écrites en toutes lettres dans le code.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = repository.appendingPathComponent("SignalQuestApp")
        let pattern = try NSRegularExpression(pattern: #"@AppStorage\("([^"]+)""#)
        var checked = 0
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = String(text[try XCTUnwrap(Range(match.range(at: 1), in: text))])
                XCTAssertFalse(key.contains("."), "\(file.lastPathComponent) : \(key)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 5, "Le relevé a bien trouvé des clés")
    }
}
