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

    func testSiteFollowOpensTheSiteInItsMarket() {
        let router = AppRouter()
        router.handle(type: "site_follow", conversationId: nil, postId: nil, siteId: "DROM:97100001", market: "DROM")
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertEqual(router.openSiteId, "DROM:97100001")
        XCTAssertEqual(router.openSiteMarket, "DROM")
    }

    func testANFRUpdateOpensTheANFRScreen() {
        let router = AppRouter()
        router.handle(type: "anfr_update", conversationId: nil, postId: nil)
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertTrue(router.openANFRMap)
        XCTAssertTrue(router.hasPendingContentRoute)
    }

    func testANFRUpdateWithoutDetailsKeepsTheCurrentBehaviour() {
        let router = AppRouter()
        router.handle(type: "anfr_update", conversationId: nil, postId: nil)
        XCTAssertNil(router.pendingANFRFocus)
    }

    func testANFRUpdateCarriesTheWeekAndTheWatchedZone() {
        let focus = ANFRFocus.parse(date: "2026-10-08", latitude: "45.7578", longitude: "4.832", radiusMeters: "1500")
        let router = AppRouter()
        router.handle(type: "anfr_update", conversationId: nil, postId: nil, anfrFocus: focus)
        XCTAssertTrue(router.openANFRMap)
        XCTAssertEqual(router.pendingANFRFocus?.date, "2026-10-08")
        XCTAssertEqual(router.pendingANFRFocus?.zoneLatitude, 45.7578)
        XCTAssertEqual(router.pendingANFRFocus?.zoneLongitude, 4.832)
        XCTAssertEqual(router.pendingANFRFocus?.radiusMeters, 1500)
    }

    func testANFRFocusIgnoresUnusableFields() {
        XCTAssertNil(ANFRFocus.parse(date: "", latitude: nil, longitude: nil, radiusMeters: nil))
        XCTAssertNil(ANFRFocus.parse(date: "not-a-date", latitude: "x", longitude: "y", radiusMeters: "z"))
        // Une latitude sans longitude, ou hors bornes, ou 0/0 : pas de zone, mais le relevé reste.
        XCTAssertNil(ANFRFocus.parse(date: nil, latitude: "45.7", longitude: nil, radiusMeters: "500"))
        XCTAssertNil(ANFRFocus.parse(date: nil, latitude: "95", longitude: "4", radiusMeters: nil))
        XCTAssertNil(ANFRFocus.parse(date: nil, latitude: "0", longitude: "0", radiusMeters: nil))
        let dateOnly = ANFRFocus.parse(date: "2026-10-08", latitude: "999", longitude: "4", radiusMeters: nil)
        XCTAssertEqual(dateOnly?.date, "2026-10-08")
        XCTAssertFalse(dateOnly?.hasZone ?? true)
        // Décimale à la virgule et rayon borné.
        let comma = ANFRFocus.parse(date: nil, latitude: "45,5", longitude: "4,5", radiusMeters: "5")
        XCTAssertEqual(comma?.zoneLatitude, 45.5)
        XCTAssertEqual(comma?.radiusMeters, 200)
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
