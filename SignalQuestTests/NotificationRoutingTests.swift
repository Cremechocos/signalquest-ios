import XCTest
@testable import SignalQuest

/// Toucher une notification ouvre le bon écran (SOC-25).
@MainActor
final class NotificationRoutingTests: XCTestCase {

    func testMessageReactionOpensTheConversation() {
        let router = AppRouter()
        router.handle(type: "reaction", conversationId: "conv-1", postId: nil)
        XCTAssertEqual(router.openConversationId, "conv-1")
        XCTAssertNil(router.openPostId)
    }

    func testPostReactionStillOpensThePost() {
        let router = AppRouter()
        router.handle(type: "reaction", conversationId: nil, postId: "post-1")
        XCTAssertEqual(router.openPostId, "post-1")
        XCTAssertNil(router.openConversationId)
    }

    func testMessageMentionOpensTheConversation() {
        let router = AppRouter()
        router.handle(type: "mention", conversationId: "conv-2", postId: nil)
        XCTAssertEqual(router.openConversationId, "conv-2")
    }

    func testFriendRequestOpensTheFriendsList() {
        let router = AppRouter()
        router.handle(type: "friend_request", conversationId: nil, postId: nil, userId: "user-1")
        XCTAssertEqual(router.selectedTab, .community)
        XCTAssertTrue(router.openFriendRequests)
        XCTAssertNil(router.openUserProfileId)
    }

    func testStoryOpensCommunity() {
        let router = AppRouter()
        router.selectedTab = .map
        router.handle(type: "story", conversationId: nil, postId: "story-1")
        XCTAssertEqual(router.selectedTab, .community)
        XCTAssertNil(router.openPostId)
    }
}
