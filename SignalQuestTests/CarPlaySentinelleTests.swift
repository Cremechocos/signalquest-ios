import CarPlay
import XCTest
@testable import SignalQuest

/// Verrouille l'écran Sentinelle CarPlay (Lot 6).
///
/// L'enjeu principal n'est pas l'affichage mais la COHÉRENCE : le tri des box
/// est partagé avec le web, Android et l'app iPhone, et `SentinelleListOrder`
/// porte en commentaire que les plateformes doivent trier identiquement. CarPlay
/// ne doit pas devenir l'exception qui range la même liste autrement.
@MainActor
final class CarPlaySentinelleTests: XCTestCase {

    private func target(id: String, label: String, status: String,
                        emoji: String? = nil, owner: String? = nil) throws -> SentinelleTarget {
        let json = """
        {"id":"\(id)","label":"\(label)","status":"\(status)","hostname":"box.example",
         \(emoji.map { "\"ownerEmoji\":\"\($0)\"," } ?? "")
         \(owner.map { "\"ownerLabel\":\"\($0)\"," } ?? "")
         "statusSince":"2026-08-08T10:00:00Z"}
        """
        return try JSONDecoder.signalQuest.decode(SentinelleTarget.self, from: Data(json.utf8))
    }

    /// Le pire en tête : c'est la raison d'ouvrir cet écran. Une liste qui
    /// commence par ce qui va bien oblige à chercher ce qui ne va pas.
    func testDownBoxesComeFirst() throws {
        let up = try target(id: "1", label: "Maison", status: "up")
        let down = try target(id: "2", label: "Parents", status: "down")
        let template = SentinelleTemplateBuilder.list(targets: [up, down]) { _ in }
        let titles = template.sections.flatMap(\.items).compactMap { ($0 as? CPListItem)?.text }
        XCTAssertEqual(titles.first, "Parents")
    }

    /// Le tri CarPlay doit être EXACTEMENT celui des autres plateformes.
    func testOrderMatchesTheSharedRule() throws {
        let boxes = [
            try target(id: "1", label: "A", status: "up"),
            try target(id: "2", label: "B", status: "degraded"),
            try target(id: "3", label: "C", status: "down"),
        ]
        let expected = SentinelleListOrder.sorted(boxes, by: .state).map(\.label)
        let template = SentinelleTemplateBuilder.list(targets: boxes) { _ in }
        let actual = template.sections.flatMap(\.items).compactMap { ($0 as? CPListItem)?.text }
        XCTAssertEqual(actual, expected)
    }

    /// L'emoji précède le nom, comme dans l'app : c'est ce qui permet de repérer
    /// « la box des parents » sans lire.
    func testOwnerEmojiPrefixesTheLabel() throws {
        let box = try target(id: "1", label: "Parents", status: "up", emoji: "👴")
        XCTAssertEqual(SentinelleTemplateBuilder.title(for: box), "👴 Parents")
        let plain = try target(id: "2", label: "Maison", status: "up")
        XCTAssertEqual(SentinelleTemplateBuilder.title(for: plain), "Maison")
    }

    /// Chaque état doit avoir une phrase : un statut inconnu affiché brut
    /// (« degraded ») serait du jargon serveur au tableau de bord.
    func testEveryStatusHasAReadableLabel() {
        for status in ["up", "down", "degraded", "n'importe quoi"] {
            let label = SentinelleTemplateBuilder.statusLabel(status)
            XCTAssertFalse(label.isEmpty)
            XCTAssertNotEqual(label, status, "Le statut brut ne doit pas fuiter à l'écran")
        }
    }

    /// Une pastille par état, et des couleurs distinctes : au volant, la couleur
    /// se lit avant le texte.
    func testStatusDotsDifferByState() {
        let up = SentinelleTemplateBuilder.statusDot(for: "up")
        let down = SentinelleTemplateBuilder.statusDot(for: "down")
        XCTAssertNotEqual(up.pngData(), down.pngData())
    }

    func testDetailStaysWithinCarPlayLimits() throws {
        let box = try target(id: "1", label: "Maison", status: "down", emoji: "🏠", owner: "Moi")
        let template = SentinelleTemplateBuilder.detail(box)
        XCTAssertLessThanOrEqual(template.items.count, CarPlayDetailTemplateBuilder.maxItems)
    }

    /// Liste vide : on dit quoi faire plutôt que d'afficher un écran nu.
    func testEmptyListExplainsWhatToDo() {
        let template = SentinelleTemplateBuilder.list(targets: []) { _ in }
        XCTAssertTrue(template.sections.flatMap(\.items).isEmpty)
        XCTAssertFalse(template.emptyViewTitleVariants.isEmpty)
        XCTAssertFalse(template.emptyViewSubtitleVariants.isEmpty)
    }

    /// La grille reste dans le plafond CarPlay une fois toutes les entrées
    /// ajoutées — au-delà, les dernières disparaîtraient en silence.
    func testGridStaysWithinLimitWithEveryEntryAdded() {
        let grid = LayersGridBuilder.make(current: [.antenna], onToggle: { _ in },
                                          onSentinelle: {}, onSearch: {}, onRecents: {})
        XCTAssertLessThanOrEqual(grid.gridButtons.count, Int(CPGridTemplateMaximumItems),
                                 "La grille déborde : des entrées seraient tronquées sans avertissement")
    }

    /// « Récents » doit survivre à une éventuelle troncature : sur les véhicules
    /// où le clavier se bloque en roulant, c'est la seule source de destination
    /// encore utilisable.
    func testRecentsComesBeforeSearchAndSentinelle() {
        let grid = LayersGridBuilder.make(current: [], onToggle: { _ in },
                                          onSentinelle: {}, onSearch: {}, onRecents: {})
        let titles = grid.gridButtons.compactMap(\.titleVariants.first)
        guard let recents = titles.firstIndex(of: String(localized: "Récents")),
              let search = titles.firstIndex(of: String(localized: "Rechercher")) else {
            return XCTFail("Entrées de destination absentes de la grille")
        }
        XCTAssertLessThan(recents, search)
    }

    /// En mode liste, aucune destination n'est proposée : sans carte, il n'y a
    /// pas de session de navigation à démarrer derrière un résultat.
    func testNoDestinationEntriesWithoutMap() {
        let grid = LayersGridBuilder.make(current: [], onToggle: { _ in }, onSentinelle: {})
        let titles = grid.gridButtons.compactMap(\.titleVariants.first)
        XCTAssertFalse(titles.contains(String(localized: "Rechercher")))
        XCTAssertFalse(titles.contains(String(localized: "Récents")))
    }
}
