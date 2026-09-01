import XCTest
@testable import SignalQuest

/// Vérrouille la persistance locale des couches de la carte (Lot M2) : couches
/// par défaut, aller-retour exact, état « tout désactivé » respecté, et
/// réinjection unique de la couche « Sites ajoutés ».
final class MapFilterStoreTests: XCTestCase {

    override func setUp() { super.setUp(); MapFilterStore.reset() }
    override func tearDown() { MapFilterStore.reset(); super.tearDown() }

    /// Les sites ajoutés à la main restent visibles dans les pays sans open data,
    /// et la carte sociale affiche les amis dès son premier lancement.
    func testDefaultShowsAntennasCustomSitesAndFriends() {
        XCTAssertEqual(MapFilterStore.defaultFilters, [.antenna, .customSite, .friend])
    }

    /// Un jeu enregistré par une version antérieure ne peut pas contenir
    /// `.customSite` : on l'ajoute une fois, puis on respecte le choix suivant.
    func testCustomSiteLayerIsInjectedOnceIntoLegacyFilters() {
        UserDefaults.standard.set([MapDisplayItem.Kind.antenna.rawValue], forKey: MapFilterStore.key)
        XCTAssertEqual(MapFilterStore.lastFilters(), [.antenna, .customSite])
        // Deuxième lecture : le drapeau est posé, plus rien n'est réinjecté.
        UserDefaults.standard.set([MapDisplayItem.Kind.antenna.rawValue], forKey: MapFilterStore.key)
        XCTAssertEqual(MapFilterStore.lastFilters(), [.antenna])
    }

    /// Décocher volontairement la couche doit tenir : `save` pose le drapeau.
    func testExplicitlyDisablingCustomSitesIsHonored() {
        MapFilterStore.save([.antenna])
        XCTAssertEqual(MapFilterStore.lastFilters(), [.antenna])
    }

    func testNilWhenNeverSaved() {
        XCTAssertNil(MapFilterStore.lastFilters())
    }

    func testRoundTrip() {
        let set: Set<MapDisplayItem.Kind> = [.antenna, .coverage, .speedtest]
        MapFilterStore.save(set)
        XCTAssertEqual(MapFilterStore.lastFilters(), set)
    }

    func testEmptySelectionIsHonored() {
        // Tout désactivé est un choix valide (≠ « jamais enregistré »).
        MapFilterStore.save([])
        XCTAssertEqual(MapFilterStore.lastFilters(), [])
    }

    func testUnknownRawValuesAreIgnored() {
        MapFilterStore.save([.antenna, .coverage])
        XCTAssertEqual(MapFilterStore.lastFilters(), [.antenna, .coverage])
    }
}
