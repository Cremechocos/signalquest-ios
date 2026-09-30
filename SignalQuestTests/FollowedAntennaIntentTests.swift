import XCTest
@testable import SignalQuest

/// Antennes suivies dans Raccourcis et Siri (plan 3, vague 1).
@MainActor
final class FollowedAntennaIntentTests: XCTestCase {
    func testEntityShowsTheSamePresentationAsTheList() {
        let named = FollowedAntennaEntity(FavoriteAntenna(
            siteId: "37199", market: "FR", operator: "ORANGE", name: "Lyon Part-Dieu", address: "40 avenue Leclerc"
        ))
        XCTAssertEqual(named.id, "FR:37199")
        XCTAssertEqual(named.siteId, "37199")
        XCTAssertEqual(named.title, "Lyon Part-Dieu")
        XCTAssertEqual(named.subtitle, "ORANGE · FR")

        let bare = FavoriteAntenna(siteId: "123", market: "CA", operator: nil)
        XCTAssertEqual(FollowedAntennaEntity(bare).title, bare.displayName)
        XCTAssertEqual(FollowedAntennaEntity(bare).subtitle, "CA")
    }

    /// Un même site peut être suivi dans deux marchés : deux entrées distinctes.
    func testSameSiteInTwoMarketsStaysTwoEntities() {
        let france = FollowedAntennaEntity(FavoriteAntenna(siteId: "1", market: "FR", operator: nil))
        let canada = FollowedAntennaEntity(FavoriteAntenna(siteId: "1", market: "CA", operator: nil))
        XCTAssertNotEqual(france.id, canada.id)
    }

    func testOpeningAnAntennaShowsItsSheetOnTheMap() {
        let router = AppRouter()
        let antenna = FollowedAntennaEntity(FavoriteAntenna(siteId: "37199", market: "FR", operator: nil))
        OpenFollowedAntennaIntent.open(antenna, with: router)
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertEqual(router.openSiteId, "37199")
    }
}
