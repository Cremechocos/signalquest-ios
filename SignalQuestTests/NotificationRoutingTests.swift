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

    /// Bugs et idées : chaque notification de l'équipe ouvre le signalement.
    func testBugNotificationsOpenTheReport() {
        for type in ["bug_status_change", "bug_response", "bug_comment", "bug_resolved_reward"] {
            let router = AppRouter()
            router.selectedTab = .map
            router.handle(type: type, conversationId: nil, postId: nil, bugId: "bug-1")
            XCTAssertEqual(router.selectedTab, .profile, type)
            XCTAssertEqual(router.openBugId, "bug-1", type)
            XCTAssertTrue(router.hasPendingContentRoute, type)
        }
        let router = AppRouter()
        router.handle(type: "bug_response", conversationId: nil, postId: nil)
        XCTAssertEqual(router.selectedTab, .profile)
        XCTAssertNil(router.openBugId, "Sans identifiant, la liste reste à portée dans le Profil")
    }

    /// Un nouveau bug, adressé aux administrateurs, ouvre lui aussi le signalement.
    func testNewBugOpensTheReport() {
        let router = AppRouter()
        router.handle(type: "new_bug", conversationId: nil, postId: nil, bugId: "bug-2")
        XCTAssertEqual(router.selectedTab, .profile)
        XCTAssertEqual(router.openBugId, "bug-2")
    }

    func testAntennaAlertsOpenTheSite() {
        for type in ["favorite_antenna_issue", "zone_antenna_issue"] {
            let router = AppRouter()
            router.handle(type: type, conversationId: nil, postId: nil, siteId: "0382203")
            XCTAssertEqual(router.selectedTab, .map, type)
            XCTAssertEqual(router.openSiteId, "0382203", type)
        }
    }

    func testANFRUpdateOpensTheANFRScreen() {
        let router = AppRouter()
        router.handle(type: "anfr_update", conversationId: nil, postId: nil)
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertTrue(router.openANFRMap)
        XCTAssertTrue(router.hasPendingContentRoute)
    }

    func testSentinelleNotificationsOpenTheBox() {
        for type in ["sentinelle", "sentinelle_incident"] {
            let router = AppRouter()
            router.handle(type: type, conversationId: nil, postId: nil, targetId: "box-1")
            XCTAssertTrue(router.openSentinelle, type)
            XCTAssertEqual(router.openSentinelleTargetId, "box-1", type)
        }
        let router = AppRouter()
        router.handle(type: "sentinelle_follower", conversationId: nil, postId: nil)
        XCTAssertTrue(router.openSentinelle)
        XCTAssertNil(router.openSentinelleTargetId)
    }

    func testProfileScreensFromNotifications() {
        let cases: [(String, AppRouter.ProfileScreen)] = [
            ("improvement", .photos), ("status_change", .photos), ("photo_comment", .photos),
            ("badge", .progression), ("badge_unlocked", .progression), ("level_up", .progression),
            ("streak_milestone", .progression), ("coverage_session_auto_closed", .sessions),
            ("supporter_granted", .subscription),
        ]
        for (type, screen) in cases {
            let router = AppRouter()
            router.handle(type: type, conversationId: nil, postId: nil)
            XCTAssertEqual(router.selectedTab, .profile, type)
            XCTAssertEqual(router.openProfileScreen, screen, type)
        }
    }

    /// Retiré d'un groupe : la boîte de réception, pas la conversation quittée.
    func testGroupRemovalOpensTheInbox() {
        let router = AppRouter()
        router.handle(type: "GROUP_MEMBER_REMOVED", conversationId: "conv-3", postId: nil)
        XCTAssertTrue(router.openMessagesInbox)
        XCTAssertNil(router.openConversationId)
    }

    /// Un message signalé ne doit jamais ouvrir la conversation d'un autre membre.
    func testModerationReportsDoNotOpenTheConversation() {
        let router = AppRouter()
        router.handle(type: "message_report", conversationId: "conv-4", postId: nil)
        XCTAssertNil(router.openConversationId)
        XCTAssertFalse(router.hasPendingContentRoute)
    }

    func testModerationNotificationsOpenTheAdminWebPage() {
        let base = URL(string: "https://signalquest.fr")!
        XCTAssertEqual(
            NotificationsCenterView.adminWebURL(type: "photo_reported", link: "/admin/moderation", base: base)?.absoluteString,
            "https://signalquest.fr/admin/moderation"
        )
        XCTAssertEqual(
            NotificationsCenterView.adminWebURL(type: "message_report", link: "/admin?tab=reports&sub=messages", base: base)?.absoluteString,
            "https://signalquest.fr/admin?tab=reports&sub=messages"
        )
        XCTAssertNil(NotificationsCenterView.adminWebURL(type: "photo_reported", link: "//example.com/admin", base: base))
        XCTAssertNil(NotificationsCenterView.adminWebURL(type: "message_new", link: "/admin/moderation", base: base))
        XCTAssertNil(NotificationsCenterView.adminWebURL(type: "photo_appeal", link: nil, base: base))
    }
}
