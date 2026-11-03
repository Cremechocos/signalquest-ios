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

    /// DM-REQ-1 : une demande de message ouvre l'écran des demandes, jamais une conversation (répondre
    /// vaudrait acceptation), même si une charge portait un `conversationId`.
    func testMessageRequestOpensTheRequestsScreenAndNeverAConversation() {
        for conversationId in [nil, "conv-1"] as [String?] {
            let router = AppRouter()
            router.handle(type: "message_request", conversationId: conversationId, postId: nil, userId: "sender-1")
            XCTAssertTrue(router.openMessageRequests)
            XCTAssertTrue(router.openMessagesInbox)
            XCTAssertEqual(router.selectedTab, .community)
            XCTAssertNil(router.openConversationId)
            XCTAssertNil(router.openUserProfileId)
            XCTAssertTrue(router.hasPendingContentRoute, "Une destination reçue prime sur le choix de fin d'introduction")
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

    func testFavoriteAlertOpensTheSiteInItsMarketWhenTheChargeGivesIt() {
        let router = AppRouter()
        router.handle(type: "favorite_antenna_issue", conversationId: nil, postId: nil, siteId: "DROM:97100001", market: "DROM")
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertEqual(router.openSiteId, "DROM:97100001")
        XCTAssertEqual(router.openSiteMarket, "DROM")
    }

    func testSiteFollowOpensTheSiteInItsMarket() {
        let router = AppRouter()
        router.handle(type: "site_follow", conversationId: nil, postId: nil, siteId: "DROM:97100001", market: "DROM",
                      operatorKey: "FREE_CARAIBES")
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertEqual(router.openSiteId, "DROM:97100001")
        XCTAssertEqual(router.openSiteMarket, "DROM")
        // Le fil d'un support partagé est celui de l'opérateur suivi.
        XCTAssertEqual(router.openSiteOperator, "FREE_CARAIBES")
    }

    /// Nouveau message sur un site suivi : la fiche s'ouvre sur sa discussion, au message.
    func testSiteFollowMessageCarriesItsComment() {
        let router = AppRouter()
        router.handle(type: "site_follow", conversationId: nil, postId: nil, siteId: "123", market: "FR",
                      operatorKey: "ORANGE", commentId: "c42")
        XCTAssertEqual(router.openSiteCommentId, "c42")
        // Les autres événements du site suivi (activation, bande, panne) n'en portent pas.
        let other = AppRouter()
        other.handle(type: "site_follow", conversationId: nil, postId: nil, siteId: "123", market: "FR", operatorKey: "ORANGE")
        XCTAssertNil(other.openSiteCommentId)
        // Une alerte de zone n'ouvre jamais la discussion.
        let zone = AppRouter()
        zone.handle(type: "zone_new_antenna", conversationId: nil, postId: nil, siteId: "123", market: "FR", commentId: "c42")
        XCTAssertNil(zone.openSiteCommentId)
    }

    /// Réponse à son message dans le fil d'un site (site-thread-v2, Q5) : la fiche sur l'opérateur du
    /// fil, ouverte sur la réponse (le fil la cherche sous son message).
    func testSiteThreadReplyOpensTheReply() {
        let router = AppRouter()
        router.handle(type: "site_thread_reply", conversationId: nil, postId: nil, siteId: "DROM:97100001", market: "DROM",
                      operatorKey: "ORANGE", commentId: "reply-7")
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertEqual(router.openSiteId, "DROM:97100001")
        XCTAssertEqual(router.openSiteMarket, "DROM")
        XCTAssertEqual(router.openSiteOperator, "ORANGE")
        XCTAssertEqual(router.openSiteCommentId, "reply-7")
    }

    /// Une alerte de zone ne vise aucun opérateur : la fiche suit le filtre de la carte.
    func testSiteAlertWithoutFollowKeepsTheMapOperator() {
        let router = AppRouter()
        router.handle(type: "zone_new_antenna", conversationId: nil, postId: nil, siteId: "123", market: "FR",
                      operatorKey: "ORANGE")
        XCTAssertNil(router.openSiteOperator)
    }

    /// Nouvelle antenne ou montée de génération près d'un lieu : le site s'ouvre dans le marché de la charge.
    func testZoneAntennaAlertsOpenTheSiteInTheirMarket() {
        for type in ["zone_new_antenna", "zone_antenna_upgrade"] {
            let router = AppRouter()
            router.handle(type: type, conversationId: nil, postId: nil, siteId: "DROM:97100001", market: "DROM")
            XCTAssertEqual(router.selectedTab, .map, type)
            XCTAssertEqual(router.openSiteId, "DROM:97100001", type)
            XCTAssertEqual(router.openSiteMarket, "DROM", type)
        }
    }

    /// Une panne sans identifiant retombe sur le site, dans son marché.
    func testCommunityOutageWithoutIdFallsBackToTheSiteInItsMarket() {
        let router = AppRouter()
        router.handle(type: "community_outage", conversationId: nil, postId: nil,
                      siteId: "DROM:97100001", market: "DROM")
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertEqual(router.openSiteId, "DROM:97100001")
        XCTAssertEqual(router.openSiteMarket, "DROM")
        XCTAssertNil(router.openCommunityOutageId)

        let withId = AppRouter()
        withId.handle(type: "community_outage", conversationId: nil, postId: nil,
                      siteId: "0382203", outageId: "outage-1", market: "FR")
        XCTAssertEqual(withId.openCommunityOutageId, "outage-1")
        XCTAssertNil(withId.openSiteId)
    }

    func testLiveShareAlertsOpenTheMapOnTheFriendWhenKnown() {
        for type in ["live_share_accepted", "live_share_declined", "live_share_stopped",
                     "live_share_follower_start", "live_share_tracking"] {
            let router = AppRouter()
            router.handle(type: type, conversationId: "conv-1", postId: nil, userId: "friend-1")
            XCTAssertEqual(router.selectedTab, .map, type)
            XCTAssertEqual(router.pendingLiveFriendId, "friend-1", type)
            XCTAssertNil(router.openConversationId, type)
            XCTAssertTrue(router.hasPendingContentRoute, type)

            let anonymous = AppRouter()
            anonymous.handle(type: type, conversationId: "conv-1", postId: nil)
            XCTAssertEqual(anonymous.selectedTab, .map, type)
            XCTAssertNil(anonymous.pendingLiveFriendId, type)
        }
    }

    /// La demande de suivi se traite dans la conversation, où se trouve le bouton Accepter.
    func testLiveShareRequestKeepsOpeningItsConversation() {
        let router = AppRouter()
        router.handle(type: "live_share_request", conversationId: "conv-2", postId: nil)
        XCTAssertEqual(router.selectedTab, .community)
        XCTAssertEqual(router.openConversationId, "conv-2")

        let withoutConversation = AppRouter()
        withoutConversation.handle(type: "live_share_request", conversationId: nil, postId: nil)
        XCTAssertEqual(withoutConversation.selectedTab, .map)
    }

    func testTestPushOpensNothing() {
        let router = AppRouter()
        router.handle(type: "test_push", conversationId: nil, postId: nil, siteId: "0382203")
        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertNil(router.openSiteId)
        XCTAssertFalse(router.hasPendingContentRoute)
    }

    /// Une demande d'ami reçue à froid garde la priorité sur l'onglet d'arrivée de l'introduction.
    func testFriendRequestCountsAsAPendingContentRoute() {
        let router = AppRouter()
        router.handle(type: "friend_request", conversationId: nil, postId: nil)
        XCTAssertTrue(router.hasPendingContentRoute)
        XCTAssertFalse(router.routeFromOnboarding(to: .map))
        XCTAssertEqual(router.selectedTab, .community)
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

    /// ANFR-MONTHLY §7 : la carte mensuelle ouvre la carte ANFR, sans relevé visé.
    func testMonthlyANFRMapUpdateOpensTheANFRScreenWithoutFocus() {
        let router = AppRouter()
        router.pendingANFRFocus = ANFRFocus.parse(date: "2026-10-08", latitude: nil, longitude: nil, radiusMeters: nil)
        router.handle(type: "anfr_map_update", conversationId: nil, postId: nil)
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertTrue(router.openANFRMap)
        XCTAssertNil(router.pendingANFRFocus)
        XCTAssertEqual(NotificationsCenterView.title(for: "anfr_map_update"), String(localized: "Carte des antennes mise à jour"))
    }

    /// Le push de la carte mensuelle arrive en `data_update` + `updateType: "anfr"`.
    func testMonthlyANFRDataUpdatePushRoutesLikeTheMapUpdate() {
        XCTAssertEqual(PushNotificationService.routedType(["type": "data_update", "updateType": "anfr"]), "anfr_map_update")
        XCTAssertEqual(PushNotificationService.routedType(["type": "data_update", "updateType": "coverage"]), "data_update")
        XCTAssertEqual(PushNotificationService.routedType(["type": "data_update"]), "data_update")
        XCTAssertEqual(PushNotificationService.routedType(["type": "anfr_update"]), "anfr_update")
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
