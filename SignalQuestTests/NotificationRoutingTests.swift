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

    /// Types réellement émis par le serveur (préfixés).
    func testServerMessageTypesOpenTheConversation() {
        for type in ["message_new", "message_reaction", "message_mention"] {
            let router = AppRouter()
            router.handle(type: type, conversationId: "conv-9", postId: nil)
            XCTAssertEqual(router.openConversationId, "conv-9", type)
        }
    }

    func testServerSocialTypesOpenThePost() {
        for type in ["social_reaction", "social_comment", "social_repost", "social_mention"] {
            let router = AppRouter()
            router.handle(type: type, conversationId: nil, postId: "post-9")
            XCTAssertEqual(router.openPostId, "post-9", type)
        }
    }

    func testStoryMentionWithoutPostOpensCommunity() {
        let router = AppRouter()
        router.selectedTab = .map
        router.handle(type: "social_mention", conversationId: nil, postId: nil, userId: "actor-1")
        XCTAssertEqual(router.selectedTab, .community)
        XCTAssertNil(router.openPostId)
        XCTAssertNil(router.openUserProfileId)
    }

    func testFollowAndAcceptedFriendOpenTheProfile() {
        for type in ["social_follow", "friend_accepted"] {
            let router = AppRouter()
            router.handle(type: type, conversationId: nil, postId: nil, userId: "user-7")
            XCTAssertEqual(router.openUserProfileId, "user-7", type)
        }
    }

    func testStoryOpensCommunity() {
        let router = AppRouter()
        router.selectedTab = .map
        router.handle(type: "story", conversationId: nil, postId: "story-1")
        XCTAssertEqual(router.selectedTab, .community)
        XCTAssertNil(router.openPostId)
    }
}
