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
    /// Panne communautaire dont la feuille doit s'ouvrir sur la carte, posée par la page
    /// « Pannes signalées ». L'objet ENTIER et non son identifiant : cette page est paginée sans
    /// tenir compte de l'emprise, donc la carte n'a en général pas chargé la panne demandée et
    /// n'aurait rien à retrouver.
    @Published var openCommunityOutage: CommunityOutage?
    /// Identifiant d'une panne à ouvrir, posé par le tap sur une notification. L'identifiant SEUL
    /// ici, contrairement au champ ci-dessus : un push ne transporte que des chaînes, c'est donc à
    /// la carte d'aller chercher la fiche.
    @Published var openCommunityOutageId: String?
    /// Demande d'ouverture DIRECTE du fil de discussion d'un signalement d'antenne
    /// (tap sur une notification `antenna_report_reply`). Consommé par ProfileView,
    /// racine de l'onglet Profil qui héberge « Mes signalements d'antenne ».
    @Published var openAntennaReportId: String?
    /// Demande E2EE v2 validée issue d'une notification. L'identifiant opaque est
    /// consommé par ProfileView, puis revérifié côté serveur avant toute approbation.
    @Published var openE2EEDeviceApprovalId: String?
    /// Box Sentinelle à ouvrir (tap sur une notification de coupure). Consommé
    /// par ProfileView : Sentinelle vit sous l'onglet Profil, dans les réglages.
    /// Sans identifiant, l'écran s'ouvre quand même — sur son accueil.
    @Published var openSentinelleTargetId: String?
    @Published var openSentinelle = false
    /// Jeton d'un lien de partage ouvert depuis l'extérieur (lien universel).
    @Published var openSentinelleShareSlug: String?
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
        // Tous les drapeaux passent par AppEnvironment : en Release ce sont des
        // constantes `false`, donc l'onglet initial est toujours `.home` et
        // aucun argument de lancement ne peut détourner la navigation.
        if let qaTab = Self.qaInitialTab(
            profile: AppEnvironment.startsOnProfileQA,
            community: AppEnvironment.startsOnCommunityQA
        ) {
            selectedTab = qaTab
        } else if AppEnvironment.runsSpeedtestQA || AppEnvironment.showsSpeedtestSharePreviewQA {
            selectedTab = .speed
        } else if AppEnvironment.startsOnMap
                    || AppEnvironment.usesDemoPhotos
                    || AppEnvironment.usesDemoFriends
                    || AppEnvironment.opensMapLayers
                    || AppEnvironment.opensAntennaSheet {
            selectedTab = .map
        } else if AppEnvironment.opensMessagesTab {
            selectedTab = .community
        } else if AppEnvironment.opensANFRMap ||
                    AppEnvironment.opensANFRStats {
            // Les écrans ANFR ont quitté le menu Profil pour l'onglet Carte,
            // où l'on va naturellement chercher une carte d'antennes.
            selectedTab = .map
        } else {
            selectedTab = .home
        }
    }

    /// Sélection initiale réservée aux parcours UI Debug. Gardée pure pour que
    /// la priorité des deux arguments soit testable sans modifier ProcessInfo.
    static func qaInitialTab(profile: Bool, community: Bool) -> AppTab? {
        if profile { return .profile }
        if community { return .community }
        return nil
    }

    /// Routes from an already-parsed APNs payload. The caller extracts the fields
    /// off the (non-Sendable) `userInfo` dictionary so only `String?` values cross
    /// the actor boundary. The backend uses Firebase-style payloads, so callers
    /// look identifiers up under both camelCase and snake_case.
    func handle(
        type rawType: String?,
        conversationId: String?,
        postId: String?,
        userId: String? = nil,
        siteId: String? = nil,
        reportId: String? = nil,
        targetId: String? = nil,
        outageId: String? = nil,
        e2eeDeviceApprovalId: String? = nil
    ) {
        switch rawType?.lowercased() {
        case "message", "conversation", "call", "dm", "e2ee_v2_envelope":
            route(toConversation: conversationId)
        case "post", "reaction", "comment", "like", "favorite", "repost", "mention", "story":
            route(toPost: postId)
        case "follow", "friend", "friend_request", "profile":
            route(toUserProfile: userId)
        case "antenna_report_reply", "antenna_report", "site_report":
            route(toAntennaReport: reportId)
        case "site", "antenna", "validation":
            route(toSite: siteId)
        // Panne communautaire : le fan-out serveur (`lib/outages/fanout.ts`) envoie
        // `type: "community_outage"`, `outageId` et `siteId: outage.targetId`.
        // Le cas était déjà servi par le repli plus bas, mais par accident : ce
        // repli teste `reportId` puis `conversationId` avant `siteId`, et une clé
        // ajoutée au payload le détournerait sans qu'on s'en aperçoive.
        case "community_outage":
            route(toCommunityOutageId: outageId, fallbackSiteId: siteId)
        case "sentinelle":
            route(toSentinelle: targetId)
        case "e2ee_v2_device_approval":
            route(toE2EEDeviceApproval: e2eeDeviceApprovalId)
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

    /// Une alerte de coupure doit mener à LA box concernée : quand on en
    /// surveille plusieurs, un écran d'accueil oblige à chercher laquelle.
    func route(toSentinelle id: String?) {
        selectedTab = .profile
        openSentinelleTargetId = id
        openSentinelle = true
    }

    /// Un lien de partage reçu par message ouvre la box, pas Safari.
    func route(toSentinelleShare slug: String) {
        selectedTab = .profile
        openSentinelleShareSlug = slug
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

    /// Une ligne de « Pannes signalées » renvoie à la carte, cadrée sur le site, feuille ouverte.
    ///
    /// La feuille de PANNE et non la fiche antenne : « une cible = une destination », et c'est la
    /// panne qu'on vient de lire dans la liste. Le cadrage passe par `pendingMapFocus` plutôt que
    /// par `openSiteId` pour deux raisons : une panne peut viser un `targetKind = "geo"`, c'est-à-
    /// dire un pylône hors référentiel dont aucun `siteId` n'est cherchable ; et la panne porte
    /// déjà sa position, ce qui évite l'aller-retour de recherche d'antenne.
    func route(toCommunityOutage outage: CommunityOutage) {
        selectedTab = .map
        openCommunityOutage = outage
        // Une position à (0, 0) est le repli du décodeur, pas un lieu : cadrer dessus enverrait la
        // carte au large du golfe de Guinée. La feuille, elle, s'ouvre quand même.
        if outage.latitude != 0 || outage.longitude != 0 {
            pendingMapFocus = Coordinates(latitude: outage.latitude, longitude: outage.longitude)
        }
    }

    /// Tap sur une notification de panne : la feuille de PANNE, pas la fiche antenne.
    ///
    /// La notification parle d'une panne précise — « Panne confirmée sur… », « Rétabli sur… » — et
    /// c'est elle qu'on vient lire ; ouvrir la fiche du site obligerait à la retrouver dedans, et
    /// une notification de rétablissement n'y figurerait même plus (la fiche ne montre que les
    /// pannes ouvertes). Sans `outageId` — un payload plus ancien — on retombe sur le site, qui
    /// reste mieux que rien.
    func route(toCommunityOutageId id: String?, fallbackSiteId siteId: String?) {
        guard let id, !id.isEmpty else {
            route(toSite: siteId)
            return
        }
        selectedTab = .map
        openCommunityOutageId = id
    }

    func route(toAntennaReport id: String?) {
        selectedTab = .profile
        if let id { openAntennaReportId = id }
    }

    func route(toE2EEDeviceApproval id: String?) {
        guard let id, !id.isEmpty else { return }
        selectedTab = .profile
        openE2EEDeviceApprovalId = id
    }
}
