import XCTest
@testable import SignalQuest

@MainActor
final class SessionGenerationClassificationTests: XCTestCase {
    func testKnownUnknownAndExplicitNoServiceStaySeparate() {
        XCTAssertEqual(SessionDetailViewModel.generationKey("4G"), "4G")
        XCTAssertEqual(SessionDetailViewModel.generationKey("LTE"), "4G")
        XCTAssertEqual(SessionDetailViewModel.generationKey("Inconnu"), "Inconnu")
        XCTAssertEqual(SessionDetailViewModel.generationKey(nil), "Inconnu")
        XCTAssertEqual(SessionDetailViewModel.generationKey("Aucun"), "Aucun")
        XCTAssertEqual(SessionDetailViewModel.generationKey("no service"), "Aucun")
    }
}
