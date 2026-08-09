import CarPlay
import CoreLocation
import XCTest
@testable import SignalQuest

/// Verrouille les destinations récentes CarPlay.
///
/// Cette liste n'est pas un confort : sur les véhicules où le système bloque le
/// clavier au-delà d'une certaine vitesse, c'est la SEULE source de destination
/// encore utilisable en roulant. Elle doit donc rester courte, ordonnée, et sans
/// doublons.
@MainActor
final class CarPlayDestinationTests: XCTestCase {

    private let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() { super.setUp(); CarPlayDestinationStore.reset() }
    override func tearDown() { CarPlayDestinationStore.reset(); super.tearDown() }

    func testNothingIsRecordedByDefault() {
        XCTAssertTrue(CarPlayDestinationStore.all().isEmpty)
    }

    /// La plus récente en tête : c'est celle qu'on veut rejoindre à nouveau.
    func testMostRecentComesFirst() {
        CarPlayDestinationStore.record(title: "Maison", coordinate: paris, now: t0)
        CarPlayDestinationStore.record(
            title: "Bureau",
            coordinate: CLLocationCoordinate2D(latitude: 48.87, longitude: 2.37),
            now: t0.addingTimeInterval(60)
        )
        XCTAssertEqual(CarPlayDestinationStore.all().first?.title, "Bureau")
    }

    /// Une destination déjà connue REMONTE au lieu de créer un doublon — sinon
    /// un trajet quotidien saturerait la liste à lui seul.
    func testRepeatedDestinationMovesUpInsteadOfDuplicating() {
        CarPlayDestinationStore.record(title: "Maison", coordinate: paris, now: t0)
        CarPlayDestinationStore.record(
            title: "Bureau",
            coordinate: CLLocationCoordinate2D(latitude: 48.87, longitude: 2.37),
            now: t0.addingTimeInterval(60)
        )
        CarPlayDestinationStore.record(title: "Maison", coordinate: paris, now: t0.addingTimeInterval(120))

        let all = CarPlayDestinationStore.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.title, "Maison")
    }

    /// Le GPS d'un parking ne rend jamais deux fois la même coordonnée : sans
    /// tolérance, le même endroit apparaîtrait plusieurs fois.
    func testNearbyCoordinatesCountAsTheSamePlace() {
        CarPlayDestinationStore.record(title: "Maison", coordinate: paris, now: t0)
        // ~35 m plus loin.
        CarPlayDestinationStore.record(
            title: "Maison (autre entrée)",
            coordinate: CLLocationCoordinate2D(latitude: 48.85691, longitude: 2.35225),
            now: t0.addingTimeInterval(60)
        )
        XCTAssertEqual(CarPlayDestinationStore.all().count, 1)
    }

    /// Deux endroits distincts restent distincts.
    func testDistantCoordinatesAreKeptApart() {
        CarPlayDestinationStore.record(title: "Maison", coordinate: paris, now: t0)
        CarPlayDestinationStore.record(
            title: "Bureau",
            coordinate: CLLocationCoordinate2D(latitude: 48.90, longitude: 2.40),
            now: t0.addingTimeInterval(60)
        )
        XCTAssertEqual(CarPlayDestinationStore.all().count, 2)
    }

    /// Au-delà du plafond, une liste ne se parcourt plus au volant.
    func testListIsCapped() {
        for index in 0..<20 {
            CarPlayDestinationStore.record(
                title: "Lieu \(index)",
                coordinate: CLLocationCoordinate2D(latitude: 48.0 + Double(index) / 10, longitude: 2.0),
                now: t0.addingTimeInterval(Double(index))
            )
        }
        let all = CarPlayDestinationStore.all()
        XCTAssertEqual(all.count, CarPlayDestinationStore.maxEntries)
        // C'est le PLUS ANCIEN qui doit disparaître, pas le plus récent.
        XCTAssertEqual(all.first?.title, "Lieu 19")
    }

    /// Liste vide : on explique plutôt que de laisser un écran nu.
    func testEmptyListExplainsItself() {
        let template = RecentDestinationsTemplateBuilder.make([]) { _ in }
        XCTAssertTrue(template.sections.flatMap(\.items).isEmpty)
        XCTAssertFalse(template.emptyViewTitleVariants.isEmpty)
        XCTAssertFalse(template.emptyViewSubtitleVariants.isEmpty)
    }

    /// Chaque entrée doit s'ouvrir : une liste dont les lignes ne font rien
    /// serait pire qu'absente.
    func testEveryEntryIsSelectable() {
        CarPlayDestinationStore.record(title: "Maison", coordinate: paris, now: t0)
        let template = RecentDestinationsTemplateBuilder.make(CarPlayDestinationStore.all()) { _ in }
        let items = template.sections.flatMap(\.items).compactMap { $0 as? CPListItem }
        XCTAssertEqual(items.count, 1)
        XCTAssertNotNil(items.first?.handler)
    }
}
