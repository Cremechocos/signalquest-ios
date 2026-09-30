import SwiftUI
import XCTest
@testable import SignalQuest

/// Raccourcis clavier de l'iPad et palette ⌘K (plan 3, vague 1).
@MainActor
final class SQKeyboardActionTests: XCTestCase {
    func testMenuActionsReachTheRightScreen() {
        let router = AppRouter()
        SQKeyboardAction.runTest.perform(on: router)
        XCTAssertEqual(router.selectedTab, .speed)
        XCTAssertTrue(router.pendingSpeedtestStart)

        let drive = AppRouter()
        SQKeyboardAction.driveTest.perform(on: drive)
        XCTAssertEqual(drive.selectedTab, .speed)
        XCTAssertTrue(drive.pendingDriveTest)

        let message = AppRouter()
        SQKeyboardAction.newMessage.perform(on: message)
        XCTAssertEqual(message.selectedTab, .community)
        XCTAssertTrue(message.openMessagesInbox)
        XCTAssertTrue(message.openNewConversation)

        let post = AppRouter()
        SQKeyboardAction.newPost.perform(on: post)
        XCTAssertEqual(post.selectedTab, .community)
        XCTAssertTrue(post.openPostComposer)

        let search = AppRouter()
        SQKeyboardAction.searchMap.perform(on: search)
        XCTAssertEqual(search.selectedTab, .map)
        XCTAssertTrue(search.focusMapSearch)
    }

    func testTabActionsOnlySwitchTabs() {
        let expected: [(SQKeyboardAction, AppRouter.AppTab)] = [
            (.home, .home), (.map, .map), (.speed, .speed), (.community, .community), (.profile, .profile)
        ]
        for (action, tab) in expected {
            let router = AppRouter()
            action.perform(on: router)
            XCTAssertEqual(router.selectedTab, tab)
            XCTAssertFalse(router.hasPendingContentRoute, "\(action) ne doit rien ouvrir d'autre")
        }
    }

    func testShortcutsAreUniqueAndTheMenuLeavesTabsToTheirOwnMenu() {
        let shortcuts = SQKeyboardAction.allCases.map { SQCommandPalette.hint($0.shortcut) }
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count, "Deux actions sur le même raccourci : \(shortcuts)")
        XCTAssertFalse(shortcuts.contains("⌘K"), "⌘K est réservé à la palette")
        XCTAssertEqual(SQKeyboardAction.menu, [.runTest, .driveTest, .newMessage, .newPost, .searchMap])
        XCTAssertEqual(SQCommandPalette.hint(SQKeyboardAction.newPost.shortcut), "⇧⌘N")
    }

    /// Le filtre travaille sur les titres de la langue de l'app : on cherche
    /// chaque action par son propre titre, quelle que soit la langue du test.
    func testPaletteFindsEachActionByItsTitle() {
        XCTAssertEqual(SQKeyboardAction.matching("  "), SQKeyboardAction.allCases)
        for action in SQKeyboardAction.allCases {
            XCTAssertTrue(SQKeyboardAction.matching(action.title).contains(action), action.title)
            XCTAssertTrue(SQKeyboardAction.matching(action.title.uppercased()).contains(action), action.title)
        }
        XCTAssertTrue(SQKeyboardAction.matching("zzzz-aucune").isEmpty)
    }
}
