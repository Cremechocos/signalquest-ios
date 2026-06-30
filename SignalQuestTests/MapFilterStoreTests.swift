import XCTest
@testable import SignalQuest

/// Vérrouille la persistance locale des couches de la carte (Lot M2) : défaut
/// « antennes seule », aller-retour exact, et état « tout désactivé » respecté.
final class MapFilterStoreTests: XCTestCase {

    override func setUp() { super.setUp(); MapFilterStore.reset() }
    override func tearDown() { MapFilterStore.reset(); super.tearDown() }

    func testDefaultIsAntennaOnly() {
        XCTAssertEqual(MapFilterStore.defaultFilters, [.antenna])
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
