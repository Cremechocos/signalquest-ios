import CarPlay
import XCTest
@testable import SignalQuest

/// Verrouille les racines CarPlay et le relais du Dashboard.
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
    func testSignedOutPointsToThePhoneInsteadOfOfferingLogin() {
        let items = CarPlayRootTemplateBuilder.signedOut()
            .sections.flatMap(\.items).compactMap { $0 as? CPListItem }
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].text?.isEmpty ?? true)
        // Le détail doit expliquer où agir, sinon l'écran est un cul-de-sac.
        XCTAssertFalse(items[0].detailText?.isEmpty ?? true)
    }

    // MARK: - Mode liste (sans carte)

    /// Si Apple accorde `driving-task` au lieu de `carplay-maps`, cette liste EST
    /// l'application. Une racine sans entrée cliquable ouvrirait sur un écran
    /// inerte alors que fiches, speedtest, « Ici » et Sentinelle existent déjà —
    /// c'est exactement le défaut que ce test interdit.
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

    // MARK: - Relais du Dashboard

    /// Les deux scènes sont indépendantes : un raccourci pressé alors que la
    /// scène principale n'est pas installée doit malgré tout arriver.
    func testDashboardRouteIsHandedOver() {
        CarPlayDashboardRoute.request(.here)
        XCTAssertEqual(CarPlayDashboardRoute.consume(), .here)
    }

    /// Consommée une fois, et une seule : sinon l'écran se rouvrirait au retour
    /// de chaque sous-écran.
    func testDashboardRouteIsConsumedOnlyOnce() {
        CarPlayDashboardRoute.request(.map)
        _ = CarPlayDashboardRoute.consume()
        XCTAssertNil(CarPlayDashboardRoute.consume())
    }

    func testNoDashboardRouteByDefault() {
        _ = CarPlayDashboardRoute.consume()
        XCTAssertNil(CarPlayDashboardRoute.consume())
    }
}

extension CarPlayDashboardRoute.Destination: Equatable {}
