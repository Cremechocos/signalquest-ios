import Foundation

/// App-wide navigation coordinator. Push notifications (and, later, universal
/// links) write an intent here; the SwiftUI tree observes it to switch tab and
/// open the relevant content. Keeping routing in one observable object means a
/// notification tap always lands somewhere sensible instead of nowhere.
@MainActor
final class AppRouter: ObservableObject {
    enum AppTab: Hashable { case home, map, speed, community, profile }

    @Published var selectedTab: AppTab
    /// Set to request opening a specific conversation on the Messages tab.
    @Published var openConversationId: String?
    /// Ouvre la boîte Messages dans l'onglet Communauté, même sans conversation ciblée.
    @Published var openMessagesInbox = false
    /// Set to request opening a specific post on the Feed tab.
    @Published var openPostId: String?
    /// Set to request opening a user profile on the Feed tab (notification de follow).
    @Published var openUserProfileId: String?
    /// Set to request opening a site sheet on the Map tab (deep link carte).
    @Published var openSiteId: String?
    /// Demande d'ouverture DIRECTE du fil de discussion d'un signalement d'antenne
    /// (tap sur une notification `antenna_report_reply`). Consommé par ProfileView,
    /// racine de l'onglet Profil qui héberge « Mes signalements d'antenne ».
    @Published var openAntennaReportId: String?
    /// Coordonnée à cadrer sur la carte (posée depuis un test de l'historique,
    /// consommée par MapExplorerView une fois l'onglet carte actif).
    @Published var pendingMapFocus: Coordinates?
    /// Demande de présentation du mode Drive Test (posée par l'App Intent F4 ;
    /// consommée par SpeedtestView une fois l'onglet Speed actif).
    @Published var pendingDriveTest = false
    /// Masque le dock flottant (conversation ouverte : le composer prend le bas).
    /// Posé par les écrans plein-bas (ConversationDetailView) à l'apparition.
    @Published var isDockHidden = false
    /// Dock rétracté en pastille après un scroll vers le bas ; redéployé en
    /// remontant, en changeant d'onglet ou en tapant la pastille.
    @Published var isDockMinimized = false

    init() {
        let args = ProcessInfo.processInfo.arguments
        if AppEnvironment.runsSpeedtestQA {
            selectedTab = .speed
        } else if AppEnvironment.startsOnMap
                    || args.contains("--qa-demo-photos")
                    || args.contains("--qa-demo-friends")
                    || args.contains("--qa-map-layers")
                    || args.contains("--qa-open-antenna") {
            selectedTab = .map
        } else if args.contains("--qa-tab-messages") {
            selectedTab = .community
        } else if ProcessInfo.processInfo.arguments.contains("--qa-anfr-map") ||
                    ProcessInfo.processInfo.arguments.contains("--qa-anfr-stats") {
            selectedTab = .profile
        } else {
            selectedTab = .home
        }
    }

    /// Routes from an already-parsed APNs payload. The caller extracts the fields
    /// off the (non-Sendable) `userInfo` dictionary so only `String?` values cross
    /// the actor boundary. The backend uses Firebase-style payloads, so callers
    /// look identifiers up under both camelCase and snake_case.
    func handle(type rawType: String?, conversationId: String?, postId: String?, userId: String? = nil, siteId: String? = nil, reportId: String? = nil) {
        switch rawType?.lowercased() {
        case "message", "conversation", "call", "dm":
            route(toConversation: conversationId)
        case "post", "reaction", "comment", "like", "favorite", "repost", "mention", "story":
            route(toPost: postId)
        case "follow", "friend", "friend_request", "profile":
            route(toUserProfile: userId)
        case "antenna_report_reply", "antenna_report", "site_report":
            route(toAntennaReport: reportId)
        case "site", "antenna", "validation":
            route(toSite: siteId)
        default:
            if reportId != nil {
                route(toAntennaReport: reportId)
            } else if conversationId != nil {
                route(toConversation: conversationId)
            } else if postId != nil {
                route(toPost: postId)
            } else if userId != nil {
                route(toUserProfile: userId)
            } else if siteId != nil {
                route(toSite: siteId)
            }
        }
    }

    func route(toConversation id: String?) {
        selectedTab = .community
        openMessagesInbox = true
        if let id { openConversationId = id }
    }

    func route(toPost id: String?) {
        selectedTab = .community
        if let id { openPostId = id }
    }

    func route(toUserProfile id: String?) {
        selectedTab = .community
        if let id { openUserProfileId = id }
    }

    func route(toSite id: String?) {
        selectedTab = .map
        if let id { openSiteId = id }
    }

    func route(toAntennaReport id: String?) {
        selectedTab = .profile
        if let id { openAntennaReportId = id }
    }
}
