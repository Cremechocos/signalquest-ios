import XCTest
@testable import SignalQuest

/// Stories masquées d'un membre : préférence locale, par compte (vague 1).
final class HiddenStoryAuthorsStoreTests: XCTestCase {
    private let alice = "user:" + String(repeating: "a", count: 64)
    private let bruno = "user:" + String(repeating: "b", count: 64)
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "HiddenStoryAuthorsStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testHideUnhideKeepsMostRecentFirstWithoutDuplicates() {
        HiddenStoryAuthorsStore.hide(authorId: "u1", displayName: "Camille", ownerScopeId: alice, defaults: defaults)
        HiddenStoryAuthorsStore.hide(authorId: "u2", displayName: "Nora", ownerScopeId: alice, defaults: defaults)
        HiddenStoryAuthorsStore.hide(authorId: "u1", displayName: "Camille L.", ownerScopeId: alice, defaults: defaults)
        XCTAssertEqual(
            HiddenStoryAuthorsStore.entries(ownerScopeId: alice, defaults: defaults),
            [.init(authorId: "u1", displayName: "Camille L."), .init(authorId: "u2", displayName: "Nora")]
        )
        HiddenStoryAuthorsStore.unhide(authorId: "u1", ownerScopeId: alice, defaults: defaults)
        XCTAssertEqual(HiddenStoryAuthorsStore.hiddenIds(ownerScopeId: alice, defaults: defaults), ["u2"])
    }

    func testPreferenceBelongsToOneAccountAndIsPurgedAtLogout() {
        HiddenStoryAuthorsStore.hide(authorId: "u1", displayName: "Camille", ownerScopeId: alice, defaults: defaults)
        XCTAssertTrue(HiddenStoryAuthorsStore.hiddenIds(ownerScopeId: bruno, defaults: defaults).isEmpty)
        HiddenStoryAuthorsStore.purge(ownerScopeId: alice, defaults: defaults)
        XCTAssertTrue(HiddenStoryAuthorsStore.entries(ownerScopeId: alice, defaults: defaults).isEmpty)
    }

    func testGuestCannotHideAndChangesAreAnnounced() {
        HiddenStoryAuthorsStore.hide(authorId: "u1", displayName: "Camille", ownerScopeId: "guest", defaults: defaults)
        XCTAssertTrue(HiddenStoryAuthorsStore.entries(ownerScopeId: "guest", defaults: defaults).isEmpty)
        let announced = expectation(forNotification: HiddenStoryAuthorsStore.didChange, object: nil)
        HiddenStoryAuthorsStore.hide(authorId: "u1", displayName: "Camille", ownerScopeId: alice, defaults: defaults)
        wait(for: [announced], timeout: 1)
    }
}
