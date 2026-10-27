import XCTest
@testable import SignalQuest

/// Lot international : langue du compte, unités par région.
final class InternationalTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "InternationalTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRegionPicksImperialOnlyWhereRoadsUseMiles() {
        XCTAssertEqual(SQUnits.regionDefault(Locale(identifier: "en_US")), .imperial)
        XCTAssertEqual(SQUnits.regionDefault(Locale(identifier: "en_GB")), .imperial)
        XCTAssertEqual(SQUnits.regionDefault(Locale(identifier: "fr_FR")), .metric)
        XCTAssertEqual(SQUnits.regionDefault(Locale(identifier: "en_CA")), .metric)
    }

    /// Le serveur rend « metric » par défaut : sans choix, la région l'emporte ;
    /// une valeur impériale, jamais par défaut, vaut choix.
    func testAccountUnitsWinOnlyWhenChosen() {
        XCTAssertEqual(SQUnits.effective(account: .metric, chosen: false, region: .imperial), .imperial)
        XCTAssertEqual(SQUnits.effective(account: .metric, chosen: true, region: .imperial), .metric)
        XCTAssertEqual(SQUnits.effective(account: .imperial, chosen: false, region: .metric), .imperial)
        XCTAssertEqual(SQUnits.effective(account: .metric, chosen: false, region: .metric), .metric)
    }

    func testLocaleIsSentAtSignInAndWhenTheAppLanguageChanges() async {
        var sent: [String] = []
        func sync(_ locale: String, force: Bool) async {
            await AccountLocaleSync.sync(ownerScopeId: "user:a", locale: locale, isCurrent: { true }, force: force,
                                         defaults: defaults) { sent.append($0) }
        }
        await sync("fr", force: false)
        await sync("fr", force: false)
        XCTAssertEqual(sent, ["fr"], "rien de neuf au lancement suivant")
        await sync("en", force: false)
        XCTAssertEqual(sent, ["fr", "en"], "la langue de l'app a changé")
        await sync("en", force: true)
        XCTAssertEqual(sent, ["fr", "en", "en"], "chaque connexion renvoie la langue")
    }

    func testAFailedOrStaleSendIsRetriedLater() async {
        var attempts = 0
        await AccountLocaleSync.sync(ownerScopeId: "user:b", locale: "en", isCurrent: { true }, force: false,
                                     defaults: defaults) { _ in attempts += 1; throw URLError(.notConnectedToInternet) }
        await AccountLocaleSync.sync(ownerScopeId: "user:b", locale: "en", isCurrent: { false }, force: false,
                                     defaults: defaults) { _ in attempts += 1 }
        await AccountLocaleSync.sync(ownerScopeId: "user:b", locale: "en", isCurrent: { true }, force: false,
                                     defaults: defaults) { _ in attempts += 1 }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(defaults.string(forKey: AccountLocaleSync.sentKey(ownerScopeId: "user:b")), "en")
    }
}
