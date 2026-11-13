import CarPlay
import XCTest
@testable import SignalQuest

/// Verrouille les racines CarPlay.
///
/// Ces tests existent parce que la surface CarPlay est invérifiable autrement :
/// le système ne fournit un `CPInterfaceController` que dans un véhicule, et
/// XCUITest ne voit pas l'écran CarPlay, rendu hors du process de l'app. Les
/// templates, eux, s'instancient librement — c'est là que la logique doit vivre.
@MainActor
final class CarPlayTemplateTests: XCTestCase {

    /// CarPlay exige un template racine sans délai : un écran vide pendant
    /// l'amorçage donnerait une app figée au démarrage du véhicule.
    func testLoadingTemplateIsNeverEmpty() {
        let template = CarPlayRootTemplateBuilder.loading()
        XCTAssertEqual(template.sections.count, 1)
        XCTAssertEqual(template.sections.first?.items.count, 1)
    }

    /// Pas de parcours de connexion au volant : un écran de login dans le
    /// véhicule serait refusé en revue, et impraticable en conduisant. Le
    /// message constate l'état sans demander de prendre l'iPhone (règle 2 du
    /// CarPlay Developer Guide).
    func testSignedOutStatesTheConditionWithoutAskingToUseThePhone() {
        let items = CarPlayRootTemplateBuilder.signedOut()
            .sections.flatMap(\.items).compactMap { $0 as? CPListItem }
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].text?.isEmpty ?? true)
        let detail = try? XCTUnwrap(items[0].detailText)
        XCTAssertFalse(detail?.isEmpty ?? true, "l'état doit être dit, sinon l'écran est un cul-de-sac")
        XCTAssertFalse(detail?.localizedCaseInsensitiveContains("iPhone") ?? true)
    }

    // MARK: - Racine de repli

    /// Posée si le véhicule refuse les onglets : une racine sans entrée
    /// cliquable ouvrirait sur un écran inerte.
    func testListRootIsNavigable() {
        var opened: [CarPlayRootTemplateBuilder.Entry] = []
        let template = CarPlayRootTemplateBuilder.list { opened.append($0) }
        let items = template.sections.flatMap(\.items).compactMap { $0 as? CPListItem }

        XCTAssertEqual(items.count, CarPlayRootTemplateBuilder.Entry.allCases.count)
        for item in items {
            XCTAssertNotNil(item.handler, "« \(item.text ?? "?") » n'ouvre rien")
        }
    }

    /// Chaque entrée doit se présenter : un titre et ce qu'elle apporte.
    func testEveryEntryDescribesItself() {
        for entry in CarPlayRootTemplateBuilder.Entry.allCases {
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertFalse(entry.subtitle.isEmpty)
            XCTAssertNotNil(UIImage(systemName: entry.systemImageName),
                            "Symbole introuvable pour \(entry) : l'entrée s'afficherait sans icône")
        }
    }

    /// L'ordre suit l'utilité au volant : ce qui est autour, puis ce qu'on
    /// capte, puis les outils.
    func testEntriesStartWithWhatIsAround() {
        XCTAssertEqual(CarPlayRootTemplateBuilder.Entry.allCases.first, .nearby)
    }

    /// Garde-fou contre la troncature SILENCIEUSE : au-delà de
    /// `maximumItemCount`, CarPlay n'affiche que les premiers éléments sans rien
    /// signaler. Le défaut ne se verrait donc qu'en voiture.
    func testRootStaysWithinCarPlayItemLimits() {
        let template = CarPlayRootTemplateBuilder.list { _ in }
        let total = template.sections.reduce(0) { $0 + $1.items.count }
        XCTAssertLessThanOrEqual(total, CPListTemplate.maximumItemCount)
        XCTAssertLessThanOrEqual(template.sections.count, CPListTemplate.maximumSectionCount)
    }
}
