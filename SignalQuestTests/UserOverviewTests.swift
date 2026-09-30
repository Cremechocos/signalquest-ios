import XCTest
@testable import SignalQuest

/// Plan 3, vague 2 : « À faire » du Profil, lu dans l'aperçu de l'espace
/// personnel du serveur.
final class UserOverviewTests: XCTestCase {
    func testServerOverviewIsReadAndOnlyPendingThingsBecomeTodos() throws {
        let json = Data(#"""
        {"level":{"level":12,"points":4250},"streakDays":3,"reliability":0.91,"monthlyRank":42,
         "hiddenFromLeaderboard":false,"badges":{"unlocked":9,"total":40},
         "identifications":{"total":37,"conflicts":2,"firstConflict":{"siteId":"s1","kind":"enb","value":"123456"}},
         "photos":{"total":14,"pending":0},
         "speedtests":{"total":128,"medianDownloadMbps":212.4},
         "sessions":{"total":6,"distanceKm":84.2,"unpublished":null},
         "missions":{"claimable":3,"rewardXp":200}}
        """#.utf8)
        let overview = try JSONDecoder().decode(UserOverview.self, from: json)
        XCTAssertEqual(overview.todos, [
            .claimMissions(count: 3, rewardXp: 200),
            .identificationConflicts(count: 2)
        ], "Aucune photo en attente : pas de ligne pour elles")
    }

    func testNothingPendingMeansNoSection() {
        let overview = UserOverview(
            photos: .init(total: 3, pending: 0),
            identifications: .init(total: 0, conflicts: 0),
            missions: .init(claimable: 0, rewardXp: 0)
        )
        XCTAssertTrue(overview.todos.isEmpty)
        XCTAssertTrue(UserOverview(photos: nil, identifications: nil, missions: nil).todos.isEmpty)
    }
}
