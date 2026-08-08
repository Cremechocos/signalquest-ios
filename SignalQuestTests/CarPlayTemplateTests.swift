import CarPlay
import XCTest
@testable import SignalQuest

/// Verrouille la construction des templates CarPlay (Lot 0).
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

    /// Pas de parcours de connexion au volant : on renvoie vers l'iPhone. Un
    /// écran de login dans le véhicule serait refusé en revue, et de toute façon
    /// impraticable en conduisant.
    func testUnauthenticatedRootPointsToThePhoneInsteadOfOfferingLogin() {
        let template = CarPlayRootTemplateBuilder.root(isAuthenticated: false, showsMap: true)
        let items = template.sections.flatMap(\.items).compactMap { $0 as? CPListItem }
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].text?.isEmpty ?? true)
        // Le détail doit expliquer où agir, sinon l'écran est un cul-de-sac.
        XCTAssertFalse(items[0].detailText?.isEmpty ?? true)
    }

    /// Le repli sans carte doit se DIRE : sans explication, l'utilisateur croit
    /// à un bug alors qu'Apple n'a simplement pas accordé la catégorie
    /// navigation.
    func testListFallbackExplainsWhyTheMapIsMissing() {
        let withMap = CarPlayRootTemplateBuilder.root(isAuthenticated: true, showsMap: true)
        let withoutMap = CarPlayRootTemplateBuilder.root(isAuthenticated: true, showsMap: false)

        let mapItem = withMap.sections.flatMap(\.items).compactMap { $0 as? CPListItem }.first
        let listItem = withoutMap.sections.flatMap(\.items).compactMap { $0 as? CPListItem }.first

        XCTAssertNil(mapItem?.detailText, "En mode carte, rien à justifier")
        XCTAssertFalse(listItem?.detailText?.isEmpty ?? true, "Le repli doit être expliqué")
        XCTAssertNotEqual(mapItem?.text, listItem?.text)
    }

    /// Garde-fou contre la troncature SILENCIEUSE : au-delà de
    /// `maximumItemCount`, CarPlay n'affiche que les premiers éléments sans rien
    /// signaler. Le défaut ne se verrait donc qu'en voiture.
    func testRootStaysWithinCarPlayItemLimits() {
        for authenticated in [true, false] {
            for showsMap in [true, false] {
                let template = CarPlayRootTemplateBuilder.root(
                    isAuthenticated: authenticated,
                    showsMap: showsMap
                )
                let total = template.sections.reduce(0) { $0 + $1.items.count }
                XCTAssertLessThanOrEqual(total, CPListTemplate.maximumItemCount)
                XCTAssertLessThanOrEqual(template.sections.count, CPListTemplate.maximumSectionCount)
            }
        }
    }
}
