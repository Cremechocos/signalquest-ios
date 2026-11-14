import XCTest
import SwiftUI
import MapKit
import CoreLocation
@testable import SignalQuest

/// Le fil envoyait `filter=all` + `ranking=smart` en dur alors que le serveur
/// accepte 11 filtres et 3 classements. Ces tests figent la correspondance : une
/// valeur inventée côté client ne produit pas d'erreur visible, juste un fil qui
/// ignore silencieusement l'onglet choisi.
final class FeedTabsTests: XCTestCase {

    /// Valeurs acceptées par `/api/social/feed` (schéma zod du backend).
    private let validFilters: Set<String> = [
        "all", "posts", "telecom", "media", "following", "friends",
        "mine", "liked", "reposted", "saved", "followed-hashtags"
    ]
    private let validRankings: Set<String> = ["smart", "latest", "foryou"]

    func testEveryTabMapsToParametersTheServerAccepts() {
        for tab in FeedTab.allCases {
            XCTAssertTrue(validFilters.contains(tab.filter), "\(tab): filtre « \(tab.filter) » inconnu du serveur")
            XCTAssertTrue(validRankings.contains(tab.ranking), "\(tab): classement « \(tab.ranking) » inconnu du serveur")
        }
    }

    /// « Pour toi » est le seul à demander le classement personnalisé — c'est ce
    /// qui justifie de collecter les signaux d'engagement.
    func testOnlyForYouRequestsThePersonalisedRanking() {
        let personalised = FeedTab.allCases.filter { $0.ranking == "foryou" }
        XCTAssertEqual(personalised, [.forYou])
    }

    /// « Récent » doit être strictement chronologique : `smart` réordonnerait.
    func testLatestIsChronological() {
        XCTAssertEqual(FeedTab.latest.ranking, "latest")
    }

    /// Deux onglets qui enverraient le MÊME couple afficheraient la même liste —
    /// l'utilisateur croirait à un bug.
    func testNoTwoTabsProduceTheSameRequest() {
        let pairs = FeedTab.allCases.map { "\($0.filter)|\($0.ranking)" }
        XCTAssertEqual(Set(pairs).count, pairs.count, "Onglets indiscernables : \(pairs)")
    }

    /// Un état vide générique (« Ton fil est encore vide ») est faux sur
    /// « Amis » quand on n'a pas d'amis : chaque onglet explique SA vacuité.
    func testEachTabExplainsItsOwnEmptiness() {
        let messages = FeedTab.allCases.map(\.emptyMessage)
        XCTAssertEqual(Set(messages).count, messages.count)
        for message in messages { XCTAssertGreaterThan(message.count, 20) }
    }
}

/// Le collecteur alimente le classement « Pour toi ». Ses défauts sont
/// silencieux : trop de signaux fausse le modèle, trop peu le prive de données,
/// et rien ne le signale à l'écran.
final class FeedSignalsCollectorTests: XCTestCase {

    /// Boîte ACTEUR pour les corps capturés : `NSLock` est interdit en contexte
    /// asynchrone sous Swift 6, et le collecteur envoie depuis une `Task`.
    private actor Recorder {
        private(set) var bodies: [Data] = []
        func append(_ data: Data) { bodies.append(data) }
    }

    /// Client factice : capture les corps envoyés sans réseau.
    private final class SpyAPI: APIClientProtocol, @unchecked Sendable {
        let recorder = Recorder()

        func request<T: Decodable>(_ endpoint: APIEndpoint, as type: T.Type) async throws -> T {
            throw APIError.http(status: 500, code: nil, message: "", requestId: nil, retryAfter: nil)
        }
        func request(_ endpoint: APIEndpoint) async throws {
            await recorder.append(endpoint.body ?? Data())
        }
        func uploadMultipart<T: Decodable>(
            path: String, fields: [String: String], fileField: String,
            fileName: String, mimeType: String, data: Data, as type: T.Type
        ) async throws -> T {
            throw APIError.http(status: 500, code: nil, message: "", requestId: nil, retryAfter: nil)
        }
    }

    private struct Batch: Decodable {
        struct Signal: Decodable { let postId: String; let signalType: String }
        let signals: [Signal]
    }

    private func decode(_ api: SpyAPI) async -> [Batch.Signal] {
        await api.recorder.bodies
            .compactMap { try? JSONDecoder().decode(Batch.self, from: $0) }
            .flatMap(\.signals)
    }

    /// Le défaut le plus coûteux : une cellule qui réapparaît au défilement
    /// enverrait une vue de plus à chaque passage, et gonflerait le score du
    /// post proportionnellement au nombre d'allers-retours.
    func testAViewIsSentOnlyOncePerPost() async {
        let api = SpyAPI()
        let collector = FeedSignalsCollector(api: api)
        for _ in 0..<5 { await collector.onVisibleItems(["p1"]) }
        await collector.flushNow()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let views = await decode(api).filter { $0.signalType == "view" }
        XCTAssertEqual(views.count, 1, "\(views.count) vues envoyées pour un seul post")
    }

    /// Un post à peine croisé au défilement rapide ne doit pas compter comme lu.
    func testDwellIsNotReportedBelowTheThreshold() async {
        let api = SpyAPI()
        let collector = FeedSignalsCollector(api: api)
        await collector.onVisibleItems(["p1"])
        await collector.onVisibleItems([])          // sort immédiatement du viewport
        await collector.flushNow()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let signals = await decode(api)
        XCTAssertTrue(signals.allSatisfy { $0.signalType != "dwell" })
    }

    /// Une carte qui apparaît ne ferme plus la lecture des autres, encore à
    /// l'écran (SOC-19) : la lecture ne se clôt qu'à la disparition.
    func testAppearanceDoesNotCloseOtherVisibleCards() async {
        let api = SpyAPI()
        let collector = FeedSignalsCollector(api: api)
        await collector.didAppear("p1")
        await collector.didAppear("p2")
        await collector.flushNow()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let signals = await decode(api)
        XCTAssertEqual(signals.filter { $0.signalType == "view" }.map(\.postId).sorted(), ["p1", "p2"])
    }

    /// Une carte à peine croisée ne compte pas comme lue, même avec l'API
    /// apparition / disparition.
    func testQuickDisappearanceSendsNoDwell() async {
        let api = SpyAPI()
        let collector = FeedSignalsCollector(api: api)
        await collector.didAppear("p1")
        await collector.didDisappear("p1")
        await collector.flushNow()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let signals = await decode(api)
        XCTAssertTrue(signals.allSatisfy { $0.signalType != "dwell" })
    }

    func testExplicitActionsAreRecorded() async {
        let api = SpyAPI()
        let collector = FeedSignalsCollector(api: api)
        await collector.record(postId: "p1", type: "like")
        await collector.record(postId: "p1", type: "share")
        await collector.flushNow()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let types = Set(await decode(api).map(\.signalType))
        XCTAssertEqual(types, ["like", "share"])
    }

    /// Un vidage à vide ne doit pas produire de requête : le fil est consulté
    /// souvent, et une requête inutile par passage en arrière-plan se paierait
    /// en batterie.
    func testFlushingAnEmptyBufferSendsNothing() async {
        let api = SpyAPI()
        let collector = FeedSignalsCollector(api: api)
        await collector.flushNow()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let bodies = await api.recorder.bodies
        XCTAssertTrue(bodies.isEmpty)
    }

    /// Les constantes doivent rester alignées sur Android : deux clients qui
    /// pondèrent différemment apprendraient deux modèles.
    func testConstantsMatchTheAndroidCollector() {
        XCTAssertEqual(FeedSignalsCollector.dwellThreshold, 1.8)
        XCTAssertEqual(FeedSignalsCollector.flushInterval, 30)
        XCTAssertEqual(FeedSignalsCollector.maxBuffer, 80)
    }
}

/// `isMine` et `pinnedAt` étaient envoyés par le backend et ignorés par le
/// modèle : iOS ne pouvait ni savoir qu'un post lui appartenait, ni afficher son
/// état d'épinglage. Un champ ignoré ne produit aucune erreur — d'où ces tests.
final class FeedItemOwnershipTests: XCTestCase {

    private func decode(_ json: String) throws -> UnifiedSocialFeedItem {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UnifiedSocialFeedItem.self, from: Data(json.utf8))
    }

    private func payload(isMine: String, pinnedAt: String) -> String {
        """
        {"id":"p1","kind":"post","author":{"id":"u1"},"text":"bonjour",
         "commentsCount":0,"repostsCount":0,"favoritesCount":0,
         "likedByMe":false,"favoritedByMe":false,"repostedByMe":false,
         "isMine":\(isMine),"pinnedAt":\(pinnedAt)}
        """
    }

    func testOwnershipAndPinAreDecoded() throws {
        let item = try decode(payload(isMine: "true", pinnedAt: "\"2026-07-27T10:00:00Z\""))
        XCTAssertTrue(item.canManage)
        XCTAssertTrue(item.isPinned)
    }

    func testAPostFromSomeoneElseCannotBeManaged() throws {
        let item = try decode(payload(isMine: "false", pinnedAt: "null"))
        XCTAssertFalse(item.canManage)
        XCTAssertFalse(item.isPinned)
    }

    /// Champs absents : le décodage ne doit pas échouer, et l'app doit se
    /// comporter comme si le post n'était PAS gérable — masquer une action est
    /// bénin, l'offrir à tort renvoie un 403 à l'utilisateur.
    func testMissingFieldsFallBackToNotManageable() throws {
        let item = try decode("""
        {"id":"p1","kind":"post","author":{"id":"u1"},"text":"bonjour",
         "commentsCount":0,"repostsCount":0,"favoritesCount":0,
         "likedByMe":false,"favoritedByMe":false,"repostedByMe":false}
        """)
        XCTAssertFalse(item.canManage)
        XCTAssertFalse(item.isPinned)
    }
}

/// Lot F (F1) : ce qui ne doit jamais s'afficher au fil.
final class FeedPrivacyTests: XCTestCase {

    private func decode(_ extra: String) throws -> UnifiedSocialFeedItem {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UnifiedSocialFeedItem.self, from: Data("""
        {"id":"p1","kind":"photo","author":{"id":"u1"},"text":"",
         "commentsCount":0,"repostsCount":0,"favoritesCount":0,
         "likedByMe":false,"favoritedByMe":false,"repostedByMe":false,
         "isMine":true\(extra)}
        """.utf8))
    }

    func testAGeneratedPostCannotBeEditedButStaysManageable() throws {
        let item = try decode(#","generated":true"#)
        XCTAssertTrue(item.canManage)
        XCTAssertFalse(item.canEdit)
    }

    func testAWrittenPostCanBeEdited() throws {
        XCTAssertTrue(try decode(#","generated":false"#).canEdit)
        // Serveur antérieur à #694 : le champ manque, le 403 reste rattrapé par le message.
        XCTAssertTrue(try decode("").canEdit)
    }

    func testASiteCodeIsNeverShownAsThePlace() throws {
        XCTAssertNil(try decode(#","placeLabel":"ANFR-0381234","metadata":{"siteId":"ANFR-0381234"}"#).readablePlaceLabel)
        XCTAssertNil(try decode(#","placeLabel":"812345","metadata":{"enb":812345}"#).readablePlaceLabel)
        XCTAssertNil(try decode(#","placeLabel":"  ""#).readablePlaceLabel)
        XCTAssertEqual(try decode(#","placeLabel":"Grenoble","metadata":{"siteId":"ANFR-0381234"}"#).readablePlaceLabel, "Grenoble")
    }
}

/// Lot F (F2) : un post automatique se lit dans son metadata, une carte par famille.
final class FeedActivityTests: XCTestCase {

    private func item(kind: String, text: String = "", mine: Bool = false, _ metadata: String) throws -> UnifiedSocialFeedItem {
        try JSONDecoder().decode(UnifiedSocialFeedItem.self, from: Data("""
        {"id":"a1","kind":"\(kind)","author":{"id":"u1"},"text":\(String(reflecting: text)),
         "commentsCount":0,"repostsCount":0,"favoritesCount":0,
         "likedByMe":false,"favoritedByMe":false,"repostedByMe":false,
         "isMine":\(mine),"metadata":{\(metadata)}}
        """.utf8))
    }

    /// feed-text-keys v4 (§4) : un post en zone privée de son auteur ne se partage à personne ;
    /// champ absent ou autre valeur, partage inchangé.
    func testAPrivateZonePostIsNotShareable() throws {
        XCTAssertFalse(try item(kind: "validation", mine: true, #""authorOnlyReason":"private_zone""#).isShareable)
        XCTAssertTrue(try item(kind: "validation", mine: true, #""authorOnlyReason":"other""#).isShareable)
        XCTAssertTrue(try item(kind: "validation", #""activityType":"validation""#).isShareable)
    }

    /// #835 : le détail d'une quête atteinte vient du catalogue ; les points gagnés restent `points`,
    /// jamais `rewardXp` ; la consigne, française, n'apparaît qu'en français ; une clé retirée du
    /// catalogue n'a aucun champ et garde le repli sur le texte.
    func testAClaimedQuestCarriesItsCatalogDetail() throws {
        let metadata = #""activityType":"quest_claim","questKey":"weekly_trace","points":120,"rewardXp":999,"#
            + #""questTitle":"Trace 10 km","questDescription":"Terminer 10 km de sessions couverture ou drive test.","#
            + #""questMetric":"coverage_distance_km","questTargetValue":10,"cadence":"weekly","specialty":"coverage""#
        let french = try XCTUnwrap(FeedActivity(item: item(kind: "badge", text: "Quête terminée", metadata), appIsFrench: true))
        XCTAssertEqual(french.subtitle, "Trace 10 km")
        XCTAssertEqual(french.points, 120, "points earned, never the catalog reward")
        let quest = try XCTUnwrap(french.quest)
        XCTAssertEqual(quest.cadence, .weekly)
        XCTAssertEqual(quest.goal, FeedActivity.questGoal(metric: "coverage_distance_km", target: 10))
        XCTAssertEqual(quest.description, "Terminer 10 km de sessions couverture ou drive test.")
        // La suite tourne en français (comme le runner) : le pluriel du catalogue est résolu.
        XCTAssertEqual(FeedActivity.questGoal(metric: "coverage_points", target: 1), "1 point de couverture")
        XCTAssertEqual(FeedActivity.questGoal(metric: "coverage_points", target: 25), "25 points de couverture")

        let english = try XCTUnwrap(FeedActivity(item: item(kind: "badge", metadata), appIsFrench: false))
        XCTAssertNil(english.quest?.description, "the French-only description is not shown in English")
        XCTAssertNotNil(english.quest?.goal)

        let eventCount = try XCTUnwrap(FeedActivity(item: item(kind: "badge",
            #""activityType":"quest_claim","questKey":"daily_outage_arbiter","questMetric":"event_count","questTargetValue":3"#)))
        XCTAssertNil(eventCount.quest, "an event count has no name of its own, and nothing else is known")

        let retired = try XCTUnwrap(FeedActivity(item: item(kind: "badge", text: #"Quête "Ancienne quête" terminée"#,
            #""activityType":"quest_claim","questKey":"retired","points":40"#)))
        XCTAssertNil(retired.quest)
        XCTAssertEqual(retired.subtitle, "Ancienne quête")
        XCTAssertEqual(retired.points, 40)
    }

    func testEachFamilyIsReadFromItsActivityType() throws {
        let level = try XCTUnwrap(FeedActivity(item: item(kind: "badge", text: "Niveau 12 atteint !",
            #""activityType":"level_up","newLevel":12,"points":10"#)))
        XCTAssertEqual(level.family, .level)
        XCTAssertTrue(level.title.contains("12"))
        XCTAssertEqual(level.points, 10)

        let quest = try XCTUnwrap(FeedActivity(item: item(kind: "badge", text: #"Quête "Explorer le réseau" terminée"#,
            #""activityType":"quest_claim","questKey":"explore-week""#)))
        XCTAssertEqual(quest.family, .quest)
        XCTAssertEqual(quest.subtitle, "Explorer le réseau")
        XCTAssertNil(quest.points, "no points key, no tag")

        let streak = try XCTUnwrap(FeedActivity(item: item(kind: "badge", #""activityType":"streak_bonus","streak":7"#)))
        XCTAssertEqual(streak.family, .streak)
        XCTAssertTrue(streak.title.contains("7"))

        let badge = try XCTUnwrap(FeedActivity(item: item(kind: "badge", text: #"Badge "Chasseur de 5G" obtenu !"#,
            #""activityType":"badge_earned","badgeId":"ckbdg0001""#)))
        XCTAssertEqual(badge.subtitle, "Chasseur de 5G", "the name in the text stands in for a missing badgeName")

        let discovery = try XCTUnwrap(FeedActivity(item: item(kind: "badge",
            #""activityType":"new_site_visited","firstDiscovery":true,"siteId":"ANFR-0381234","marketCode":"FR""#)))
        XCTAssertEqual(discovery.family, .siteDiscovered)
        XCTAssertEqual(discovery.link, .site(id: "ANFR-0381234", market: "FR"))
        XCTAssertEqual(try FeedActivity(item: item(kind: "badge",
            #""activityType":"new_site_visited","firstDiscovery":false"#))?.family, .siteVisited)

        let official = try XCTUnwrap(FeedActivity(item: item(kind: "post", text: "3 nouvelles antennes au Luxembourg",
            #""source":"netmonster_sync","created":3,"points":10"#)))
        XCTAssertEqual(official.family, .officialRecap)
        XCTAssertNil(official.points)
        XCTAssertEqual(try FeedActivity(item: item(kind: "telecom", text: "a ajouté une activité telecom", #""platform":"ios""#))?.subtitle, nil)
    }

    func testAnOrdinaryPostKeepsItsPostCard() throws {
        XCTAssertNil(FeedActivity(item: try item(kind: "post", text: "Bonjour", #""source":"composer""#)))
        XCTAssertNil(FeedActivity(item: try item(kind: "speedtest", #""activityType":"speedtest""#)))
    }

    func testProgressionLinksOnlyFromOnesOwnPosts() throws {
        let metadata = #""activityType":"level_up","newLevel":3"#
        XCTAssertEqual(FeedActivity(item: try item(kind: "badge", mine: true, metadata))?.link, .progression)
        XCTAssertNil(FeedActivity(item: try item(kind: "badge", mine: false, metadata))?.link,
                     "a friend's level must not open my own progression")
        let bug = #""activityType":"bug_report_resolved","bugId":"ckbug0001""#
        XCTAssertEqual(FeedActivity(item: try item(kind: "badge", text: "Signalement de bug validé : La carte se fige", mine: true, bug))?.link,
                       .bug(id: "ckbug0001"))
        XCTAssertEqual(FeedActivity(item: try item(kind: "badge", text: "Signalement de bug validé : La carte se fige", bug))?.subtitle,
                       "La carte se fige")
    }
}

/// Lot F (F3) : la carte ne répète pas en phrase ce que ses tuiles montrent déjà.
final class FeedCardTextTests: XCTestCase {

    private func item(kind: String, text: String, generated: Bool) throws -> UnifiedSocialFeedItem {
        try JSONDecoder().decode(UnifiedSocialFeedItem.self, from: Data("""
        {"id":"t1","kind":"\(kind)","author":{"id":"u1"},"text":\(String(reflecting: text)),
         "commentsCount":0,"repostsCount":0,"favoritesCount":0,
         "likedByMe":false,"favoritedByMe":false,"repostedByMe":false,"generated":\(generated)}
        """.utf8))
    }

    func testAutomaticSentencesAreDropped() throws {
        XCTAssertNil(try item(kind: "speedtest", text: "Speedtest 4G : 120 Mb/s", generated: true).cardText)
        XCTAssertNil(try item(kind: "coverage", text: "Session de 12 km", generated: true).cardText)
        XCTAssertNil(try item(kind: "photo", text: "Photo terrain du site Grenoble", generated: true).cardText)
        XCTAssertNil(try item(kind: "rating", text: "A évalué ce signal · ★★★★", generated: true).cardText)
        XCTAssertNil(try item(kind: "post", text: "   ", generated: false).cardText)
    }

    func testWhatTheAuthorWroteIsKept() throws {
        XCTAssertEqual(try item(kind: "photo", text: "Nouveau mât sur le toit", generated: true).cardText, "Nouveau mât sur le toit")
        XCTAssertEqual(try item(kind: "speedtest", text: "Enfin la fibre 5G !", generated: false).cardText, "Enfin la fibre 5G !")
        XCTAssertEqual(try item(kind: "rating", text: "Très stable en gare", generated: true).cardText, "Très stable en gare")
    }
}

/// Lot F (F-46) : les lieux d'Explorer restent proches et cèdent la place aux membres.
final class ExplorePlacesTests: XCTestCase {
    private let grenoble = CLLocationCoordinate2D(latitude: 45.188, longitude: 5.724)
    private let lyon = PlaceResult(id: "lyon", name: "Lyon", subtitle: nil, latitude: 45.764, longitude: 4.836)
    private let sydney = PlaceResult(id: "syd", name: "Lyon Street", subtitle: nil, latitude: -33.87, longitude: 151.21)
    private let member = SocialUserSearchResult(id: "u1", name: "Élodie Martin", handle: "elodie", avatarUrl: nil, isFriend: nil)

    func testWithoutAReferencePointNoPlaceIsShown() {
        XCTAssertTrue(ExploreViewModel.placesToShow([lyon], query: "Lyon", members: [], center: nil).isEmpty)
    }

    func testFarAwayPlacesAreDropped() {
        let shown = ExploreViewModel.placesToShow([lyon, sydney], query: "Lyon", members: [], center: grenoble)
        XCTAssertEqual(shown.map(\.id), ["lyon"])
    }

    func testTypingAMemberNameShowsNoPlace() {
        for query in ["elodie martin", "Elodie Martin", "@elodie", "ELODIE"] {
            XCTAssertTrue(ExploreViewModel.placesToShow([lyon], query: query, members: [member], center: grenoble).isEmpty, query)
        }
        XCTAssertEqual(ExploreViewModel.placesToShow([lyon], query: "Élo", members: [member], center: grenoble).count, 1)
    }
}

final class FeedRoamingSpeedtestTests: XCTestCase {
    func testVisitedNetworkAndSimAreDecodedSeparately() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(UnifiedSocialFeedItem.self, from: Data("""
        {"id":"speed-post","kind":"speedtest","author":{"id":"u1"},"text":"",
         "commentsCount":0,"repostsCount":0,"favoritesCount":0,
         "likedByMe":false,"favoritedByMe":false,"repostedByMe":false,
         "signal":{"type":"speedtest","operator":"Vodafone Germany",
           "servingOperator":"Vodafone Germany","simOperator":"Orange F",
           "isRoaming":true,"observedPlmn":"26202","simPlmn":"20801",
           "detectedTechs":[]}}
        """.utf8))

        XCTAssertEqual(item.signal?.operator, "Vodafone Germany")
        XCTAssertEqual(item.signal?.servingOperator, "Vodafone Germany")
        XCTAssertEqual(item.signal?.simOperator, "Orange F")
        XCTAssertEqual(item.signal?.isRoaming, true)
        XCTAssertEqual(item.signal?.observedPlmn, "26202")
        XCTAssertEqual(item.signal?.simPlmn, "20801")
    }
}

/// Le sondage du fil a une forme DIFFÉRENTE de celui de la messagerie
/// (`label`/`votesCount`/`votedByMe` contre `text`/`count`/`votesByMe`).
/// Confondre les deux donnerait un décodage silencieusement vide.
final class FeedPollTests: XCTestCase {

    private func poll(totalVotes: Int, expired: Bool = false, votedIndex: Int? = nil) -> FeedPoll {
        FeedPoll(
            id: "poll1", question: "Ton opérateur ?", expiresAt: nil,
            allowMultiple: false, totalVotes: totalVotes, hasExpired: expired,
            options: (0..<3).map { i in
                FeedPoll.Option(
                    id: "o\(i)", label: "Choix \(i)", position: 2 - i,
                    votesCount: i, votedByMe: votedIndex == i
                )
            }
        )
    }

    func testDecodesTheFeedShapeNotTheMessagingOne() throws {
        let json = """
        {"id":"poll1","question":"Ton opérateur ?","expiresAt":null,"allowMultiple":false,
         "totalVotes":5,"hasExpired":false,
         "options":[{"id":"o1","label":"Orange","position":0,"votesCount":3,"votedByMe":true}]}
        """
        let decoded = try JSONDecoder().decode(FeedPoll.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.options.first?.label, "Orange")
        XCTAssertEqual(decoded.options.first?.votesCount, 3)
        XCTAssertTrue(decoded.hasVoted)
    }

    /// Le piège classique : diviser par zéro quand personne n'a voté. Le
    /// résultat remonterait jusqu'à un `frame` SwiftUI et planterait le rendu.
    func testShareIsZeroRatherThanNaNWithoutVotes() {
        let empty = poll(totalVotes: 0)
        for option in empty.options {
            let share = empty.share(of: option)
            XCTAssertFalse(share.isNaN, "NaN sur un sondage sans vote")
            XCTAssertEqual(share, 0)
        }
    }

    func testShareIsAProportionOfTheTotal() {
        let p = poll(totalVotes: 3)   // votes 0, 1, 2
        XCTAssertEqual(p.share(of: p.options[2]), 2.0 / 3.0, accuracy: 0.0001)
    }

    /// Le backend renvoie `position`, mais s'y fier sans trier laisserait
    /// l'ordre à la merci de la sérialisation JSON.
    func testOptionsAreOrderedByPosition() {
        let ordered = poll(totalVotes: 3).orderedOptions
        XCTAssertEqual(ordered.map(\.position), [0, 1, 2])
    }

    /// Un sondage clos n'accepte plus de vote : proposer l'action donnerait une
    /// erreur serveur à l'utilisateur.
    func testAnExpiredPollIsClosedToVoting() {
        XCTAssertFalse(poll(totalVotes: 3, expired: true).isOpen)
        XCTAssertTrue(poll(totalVotes: 3).isOpen)
    }
}

/// Le bilan hebdo est le seul écran dont la sortie quitte l'app (image
/// partagée). Ses défauts se voient donc par des inconnus, et pas dans l'app.
final class WeeklyRecapTests: XCTestCase {

    private func stats(
        speedtests: Int = 0, topMbps: Double? = nil, points: Int = 0,
        validations: Int = 0, photos: Int = 0, badges: Int = 0, moments: Int = 0
    ) -> WeeklyRecapStats {
        WeeklyRecapStats(
            weekStart: Date(timeIntervalSince1970: 1_753_000_000),
            weekEnd: Date(timeIntervalSince1970: 1_753_604_800),
            speedtestCount: speedtests, topDownloadMbps: topMbps,
            topDownloadTech: nil, topDownloadOperator: nil,
            sessionPoints: points, sessionDistanceKm: nil,
            validationCount: validations, photoCount: photos,
            badgeCount: badges, signalMomentsShared: moments, topCity: nil
        )
    }

    /// Une semaine vide ne doit rien proposer à partager : une carte creuse est
    /// pire que pas de carte.
    func testAnEmptyWeekHasNothingToShow() {
        XCTAssertFalse(stats().hasSomethingToShow)
        XCTAssertEqual(stats().headline, .none)
    }

    func testAnyContributionMakesTheWeekWorthSharing() {
        XCTAssertTrue(stats(speedtests: 1).hasSomethingToShow)
        XCTAssertTrue(stats(validations: 1).hasSomethingToShow)
        XCTAssertTrue(stats(photos: 1).hasSomethingToShow)
        XCTAssertTrue(stats(badges: 1).hasSomethingToShow)
        XCTAssertTrue(stats(moments: 1).hasSomethingToShow)
    }

    /// Le débit domine le récit quand il existe ; sinon on met en avant ce qui a
    /// réellement occupé la semaine, plutôt qu'un zéro.
    func testHeadlinePrefersSpeedThenFallsBackInOrder() {
        XCTAssertEqual(stats(speedtests: 3, topMbps: 240, points: 10).headline, .topSpeed(240))
        XCTAssertEqual(stats(points: 10, validations: 2).headline, .coverage(10))
        XCTAssertEqual(stats(validations: 2, photos: 5).headline, .validations(2))
        XCTAssertEqual(stats(photos: 5).headline, .photos(5))
    }

    /// Un débit à zéro n'est pas un débit : il ne doit pas devenir le titre.
    func testAZeroSpeedIsNotAHeadline() {
        XCTAssertEqual(stats(speedtests: 2, topMbps: 0, points: 7).headline, .coverage(7))
    }

    func testStatsDecodeFromTheServerShape() throws {
        let json = """
        {"weekStart":"2026-07-20T00:00:00Z","weekEnd":"2026-07-27T00:00:00Z",
         "speedtestCount":12,"topDownloadMbps":243.5,"topDownloadTech":"5G",
         "topDownloadOperator":"Orange","sessionPoints":840,"sessionDistanceKm":31.2,
         "validationCount":4,"photoCount":2,"badgeCount":1,"signalMomentsShared":3,
         "topCity":"Lyon"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WeeklyRecapStats.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.speedtestCount, 12)
        XCTAssertEqual(decoded.headline, .topSpeed(243.5))
        XCTAssertTrue(decoded.hasSomethingToShow)
    }
}

/// `GET /api/social/explore` renvoie trois listes en un appel. iOS n'appelait
/// que la recherche d'utilisateurs : chercher un mot-clé ne trouvait JAMAIS la
/// publication qui le contenait.
final class SocialExploreTests: XCTestCase {

    func testDecodesTheThreeLists() throws {
        let json = """
        {"posts":[{"id":"p1","kind":"post","author":{"id":"u1"},"text":"5G à Lyon",
          "commentsCount":0,"repostsCount":0,"favoritesCount":0,
          "likedByMe":false,"favoritedByMe":false,"repostedByMe":false}],
         "people":[{"id":"u2","name":"Camille","handle":"cam"}],
         "hashtags":[{"tag":"5g","postCount":12}]}
        """
        let result = try JSONDecoder().decode(SocialExploreResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.posts.count, 1)
        XCTAssertEqual(result.people.count, 1)
        // `postCount`, pas `count` : le premier fixture utilisait le mauvais nom
        // et la liste se vidait SANS erreur, exactement le mode d'échec que le
        // repli sur liste vide peut masquer. Vérifié contre la sélection Prisma
        // du backend (`select: { tag: true, postCount: true }`).
        XCTAssertEqual(result.hashtags.count, 1)
        XCTAssertEqual(result.hashtags.first?.postCount, 12)
        XCTAssertFalse(result.isEmpty)
    }

    /// Le serveur omet les listes vides selon la requête : un champ absent doit
    /// valoir liste vide, pas un échec de décodage qui viderait tout l'écran.
    func testMissingListsDecodeAsEmptyRatherThanFailing() throws {
        let result = try JSONDecoder().decode(
            SocialExploreResult.self,
            from: Data(#"{"people":[{"id":"u2","name":"Camille"}]}"#.utf8)
        )
        XCTAssertTrue(result.posts.isEmpty)
        XCTAssertTrue(result.hashtags.isEmpty)
        XCTAssertEqual(result.people.count, 1)
    }

    /// La conversion vers le type de l'écran de recherche doit préserver
    /// l'identité — sinon le tap ouvre le mauvais profil.
    func testPeopleConversionKeepsIdentity() throws {
        let result = try JSONDecoder().decode(
            SocialExploreResult.self,
            from: Data(#"{"people":[{"id":"u9","name":"Nora","handle":"nora"}]}"#.utf8)
        )
        let converted = result.peopleAsSearchResults
        XCTAssertEqual(converted.first?.id, "u9")
        XCTAssertEqual(converted.first?.handle, "nora")
    }
}

/// Réactions dessinées en symboles SF à partir des emojis stockés (lot F, F-27).
final class FeedReactionTests: XCTestCase {
    func testStoredEmojiMatchesWithOrWithoutVariationSelector() {
        XCTAssertEqual(FeedReaction(emoji: "⚡"), .bolt)
        XCTAssertEqual(FeedReaction(emoji: "\u{26A1}\u{FE0F}"), .bolt)
        XCTAssertEqual(FeedReaction(emoji: "\u{2764}"), .like)
        XCTAssertEqual(FeedReaction(emoji: "❤️"), .like)
    }

    func testUnknownEmojiStaysCountedUnderANeutralSymbol() {
        XCTAssertNil(FeedReaction(emoji: "😂"))
        XCTAssertEqual(FeedReaction.symbol(for: "😂"), "face.smiling")
        XCTAssertFalse(FeedReaction.name(for: "😂").isEmpty)
    }

    func testPickerKeepsSendingTheStoredEmojisLikeFirst() {
        XCTAssertEqual(FeedReaction.allCases.map(\.rawValue), ["❤️", "🔥", "👏", "🚀", "⚡", "📡"])
        XCTAssertEqual(Set(FeedReaction.allCases.map(\.symbol)).count, FeedReaction.allCases.count)
    }
}

/// Lot F, F6 : les autres écrans du fil (pouls réseau, récap, composeur).
final class FeedOtherScreensTests: XCTestCase {

    /// Forme servie par `/api/social/network-pulse` : `periodDays` au lieu de
    /// `windowDays`, et des opérateurs réduits à `measurementsCount`. Exiger
    /// `sampleCount` vidait toute la liste en production (F-33).
    func testNetworkPulseDecodesTheServedShape() throws {
        let json = """
        {"avgRsrpDbm":-94.4,"medianDownloadMbps":187,"measurementsCount":342,
         "bestOperator":"Orange","radiusMeters":3000,"periodDays":365,"contributorsCount":12,
         "operators":[{"operatorKey":"ORANGE","label":"Orange","measurementsCount":140},
                      {"operatorKey":"FREE","measurementsCount":70}],
         "belowPrivacyThreshold":false}
        """
        let pulse = try JSONDecoder().decode(NetworkPulse.self, from: Data(json.utf8))
        XCTAssertEqual(pulse.avgRsrpDbm, -94)
        XCTAssertEqual(pulse.windowDays, 365)
        XCTAssertEqual(pulse.operators.map(\.sampleCount), [140, 70])
        XCTAssertEqual(pulse.operators.map(\.label), ["Orange", "FREE"])
        XCTAssertNil(pulse.operators.first?.avgRsrpDbm)
        XCTAssertFalse(pulse.isLive(at: Date()))
    }

    func testPulseWindowLabelFollowsTheServedPeriod() {
        func label(_ days: Int) -> String {
            NetworkPulse(avgRsrpDbm: nil, medianDownloadMbps: nil, measurementsCount: 1,
                         bestOperator: nil, radiusMeters: nil, windowDays: days).windowLabel
        }
        XCTAssertEqual(label(7), String(localized: "7 derniers jours"))
        XCTAssertEqual(label(30), String(localized: "30 derniers jours"))
        XCTAssertEqual(label(90), String(localized: "3 derniers mois"))
        XCTAssertEqual(label(365), String(localized: "12 derniers mois"))
    }

    private func recap(
        topMbps: Double? = nil, speedtests: Int = 0, points: Int = 0, km: Double? = nil,
        validations: Int = 0, photos: Int = 0, badges: Int = 0, moments: Int = 0
    ) -> WeeklyRecapStats {
        WeeklyRecapStats(
            weekStart: Date(timeIntervalSince1970: 1_753_000_000),
            weekEnd: Date(timeIntervalSince1970: 1_753_604_800),
            speedtestCount: speedtests, topDownloadMbps: topMbps,
            topDownloadTech: nil, topDownloadOperator: nil,
            sessionPoints: points, sessionDistanceKm: km,
            validationCount: validations, photoCount: photos,
            badgeCount: badges, signalMomentsShared: moments, topCity: nil
        )
    }

    /// Sessions et moments partagés s'affichent enfin ; les zéros se taisent (F-34).
    func testRecapShowsEveryNonZeroFigureInOrder() {
        let metrics = recap(topMbps: 412, speedtests: 6, points: 640, km: 12.4,
                            validations: 3, photos: 2, badges: 1, moments: 4).secondaryMetrics
        XCTAssertEqual(metrics.map(\.label), [
            String(localized: "speedtests"), String(localized: "points de couverture"),
            String(localized: "km parcourus"), String(localized: "validations"),
            String(localized: "photos"), String(localized: "badge"),
            String(localized: "moments partagés"),
        ])
        XCTAssertTrue(recap(topMbps: 100, speedtests: 1).secondaryMetrics.map(\.label)
            == [String(localized: "speedtest")])
    }

    /// Le chiffre déjà en titre ne se répète pas dans la grille.
    func testRecapDoesNotRepeatTheHeadline() {
        let labels = recap(points: 640, validations: 3).secondaryMetrics.map(\.label)
        XCTAssertFalse(labels.contains(String(localized: "points de couverture")))
        XCTAssertEqual(labels, [String(localized: "validations")])
        XCTAssertTrue(recap(km: 0.05, photos: 2).secondaryMetrics.isEmpty)
    }

    /// Jamais une tuile seule : 7 → 3, 2, 2 ; 4 → 2, 2 ; 3 → 3.
    func testRecapRowsAreBalanced() {
        func sizes(_ count: Int, _ max: Int) -> [Int] {
            WeeklyRecapSheet.metricRows(count: count, maxPerRow: max).map(\.count)
        }
        XCTAssertEqual(sizes(7, 3), [3, 2, 2])
        XCTAssertEqual(sizes(4, 3), [2, 2])
        XCTAssertEqual(sizes(3, 3), [3])
        XCTAssertEqual(sizes(5, 2), [2, 2, 1])
        XCTAssertEqual(sizes(0, 3), [])
        XCTAssertEqual(WeeklyRecapSheet.metricRows(count: 7, maxPerRow: 3).flatMap { Array($0) }, Array(0..<7))
    }

    /// Tendances d'abord, puis le repli, sans doublon de casse ni tag à espaces.
    func testComposerHashtagsPreferTrendsThenFallback() {
        XCTAssertEqual(ComposerSheet.quickHashtags(trending: []), ComposerSheet.fallbackHashtags)
        XCTAssertEqual(
            ComposerSheet.quickHashtags(trending: ["grenoble", "#5g", "deux mots"]),
            ["#grenoble", "#5g", "#speedtest", "#4G", "#couverture", "#antenne"]
        )
        XCTAssertEqual(ComposerSheet.quickHashtags(trending: (1...9).map { "t\($0)" }).count, 6)
    }
}

/// Lot F (F7) : un élément illisible ne doit jamais emporter ses voisins.
final class FeedDecodingRobustnessTests: XCTestCase {

    private let post = #"""
    {"id":"%@","kind":"post","author":{"id":"u1"},"text":"bonjour",
     "commentsCount":0,"repostsCount":0,"favoritesCount":0,
     "likedByMe":false,"favoritedByMe":false,"repostedByMe":false%@}
    """#

    private func postJSON(_ id: String, extra: String = "") -> String {
        String(format: post, id, extra)
    }

    /// F-31 : un sondage ou un résumé de mesure mal formé faisait tomber tout le post.
    func testMalformedPollOrSignalKeepsThePost() throws {
        let withPoll = try JSONDecoder().decode(UnifiedSocialFeedItem.self,
                                                from: Data(postJSON("p1", extra: #","poll":"oops""#).utf8))
        XCTAssertEqual(withPoll.id, "p1")
        XCTAssertNil(withPoll.poll)
        let withSignal = try JSONDecoder().decode(UnifiedSocialFeedItem.self,
                                                  from: Data(postJSON("p2", extra: #","signal":42"#).utf8))
        XCTAssertEqual(withSignal.id, "p2")
        XCTAssertNil(withSignal.signal)
    }

    /// F-41 : Explorer décode chaque liste élément par élément.
    func testExploreDropsOnlyTheUnreadableEntries() throws {
        let json = """
        {"posts":[\(postJSON("p1")),{"id":"broken"},\(postJSON("p2"))],
         "people":[{"id":"u1"},"pas un objet",{"id":"u2"}],
         "hashtags":[{"tag":"5g","postCount":3},{"tag":"x"},{"tag":"fibre","postCount":1}]}
        """
        let result = try JSONDecoder().decode(SocialExploreResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.posts.map(\.id), ["p1", "p2"])
        XCTAssertEqual(result.people.map(\.id), ["u1", "u2"])
        XCTAssertEqual(result.hashtags.map(\.tag), ["5g", "fibre"])
    }

    /// Une session se montre par son tracé (`signal.mapPoints`), jamais par un point isolé :
    /// ce serait son départ, souvent le domicile.
    func testSessionShowsItsTraceAndNeverASinglePoint() throws {
        func signal(_ json: String) throws -> SocialSignalSummary {
            try JSONDecoder().decode(SocialSignalSummary.self, from: Data(json.utf8))
        }
        let traced = try signal(#"{"latitude":45.1,"longitude":5.7,"mapPoints":[{"latitude":45.1,"longitude":5.7},{"latitude":45.2,"longitude":5.8},{"latitude":"x"}]}"#)
        XCTAssertEqual(traced.mapPoints.count, 2)
        XCTAssertEqual(SignalDetailSheet.trace(kind: "session", signal: traced)?.count, 2)
        XCTAssertEqual(SignalDetailSheet.trace(kind: "DRIVE_TEST", signal: traced)?.count, 2)
        // Un seul point, ou une position sans tracé : aucune carte.
        let single = try signal(#"{"latitude":45.1,"longitude":5.7,"mapPoints":[{"latitude":45.1,"longitude":5.7}]}"#)
        XCTAssertEqual(SignalDetailSheet.trace(kind: "session", signal: single)?.isEmpty, true)
        XCTAssertEqual(SignalDetailSheet.trace(kind: "session", signal: try signal(#"{"latitude":45.1,"longitude":5.7}"#))?.isEmpty, true)
        XCTAssertNil(SignalDetailSheet.trace(kind: "speedtest", signal: traced))
    }

    /// Miniature du fil : emprise d'au moins 250 m de demi-côté, au format 16:9, et tout le
    /// tracé projeté à l'intérieur (contrat social-session-preview, « Rendu dans les apps »).
    func testRouteThumbnailFramesTheWholeRoute() {
        let short = [CLLocationCoordinate2D(latitude: 45, longitude: 5), CLLocationCoordinate2D(latitude: 45.0001, longitude: 5.0001)]
        let small = RouteSnapshotCache.frame(for: short, aspect: 16 / 9)
        XCTAssertGreaterThanOrEqual(small.height / MKMapPointsPerMeterAtLatitude(45), 499.9)
        XCTAssertEqual(small.width / small.height, 16 / 9, accuracy: 0.0001)

        let long = (0..<40).map { CLLocationCoordinate2D(latitude: 45.17 + 0.03 * Double($0) / 39, longitude: 5.70 + 0.2 * Double($0) / 39) }
        let rect = RouteSnapshotCache.frame(for: long, aspect: 16 / 9)
        XCTAssertEqual(rect.width / rect.height, 16 / 9, accuracy: 0.0001)
        for point in RouteSnapshotCache.project(long, in: rect) {
            XCTAssertTrue((0...1).contains(point.x) && (0...1).contains(point.y), "\(point)")
        }
    }

    /// Un plan qui ne revient jamais (MapKit muet, même après annulation) est abandonné au
    /// délai, et le tour est rendu : le rendu suivant passe au lieu de geler tout le fil.
    @MainActor
    func testSilentMapIsAbandonedAndReleasesTheQueue() async {
        let cache = RouteSnapshotCache.shared
        let started = Date()
        let silent = await cache.inTurn(key: "test-silent-\(UUID())") {
            await RouteSnapshotCache.render(timeout: 0.3, start: { _ in }, cancel: {})
        }
        XCTAssertNil(silent)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let next = await cache.inTurn(key: "test-next-\(UUID())") {
            await RouteSnapshotCache.render(timeout: 5, start: { done in done(UIImage(systemName: "map")) }, cancel: {})
        }
        XCTAssertNotNil(next)
    }
}

/// Post photo du fil (contrat social-photo-post v1, #827) : le lien vers la fiche
/// d'antenne n'existe qu'avec la clé complète, jamais devinée depuis le libellé.
final class FeedPhotoSiteLinkTests: XCTestCase {
    private func photo(_ metadata: String, kind: String = "photo") throws -> UnifiedSocialFeedItem {
        try JSONDecoder().decode(UnifiedSocialFeedItem.self, from: Data("""
        {"id":"photo-p1","kind":"\(kind)","sourceType":"photo","sourceId":"p1","author":{"id":"u1"},
         "text":"Pylône","commentsCount":0,"repostsCount":0,"favoritesCount":0,
         "likedByMe":false,"favoritedByMe":false,"repostedByMe":false,"metadata":{\(metadata)}}
        """.utf8))
    }

    func testACompleteKeyOpensTheSite() throws {
        let item = try photo(#""photoId":"p1","siteId":"S1","operator":"Orange","marketCode":"FR","operatorKey":"ORANGE""#)
        let key = try XCTUnwrap(SignalDetailSheet.photoSiteKey(of: item))
        XCTAssertEqual(key.siteId, "S1")
        XCTAssertEqual(key.market, "FR")
        XCTAssertEqual(key.operatorKey, "ORANGE")
    }

    func testAnIncompleteKeyShowsNoLink() throws {
        XCTAssertNil(SignalDetailSheet.photoSiteKey(of: try photo(#""siteId":"S1","operator":"Orange","marketCode":null,"operatorKey":"ORANGE""#)))
        XCTAssertNil(SignalDetailSheet.photoSiteKey(of: try photo(#""siteId":"S1","operator":"Orange","marketCode":"FR","operatorKey":null"#)))
        XCTAssertNil(SignalDetailSheet.photoSiteKey(of: try photo(#""siteId":"S1","operator":"Orange""#)), "never guessed from the label")
        XCTAssertNil(SignalDetailSheet.photoSiteKey(of: try photo(#""siteId":"S1","marketCode":"FR","operatorKey":"ORANGE""#, kind: "post")))
    }
}

/// Carte de session de couverture : règles communes aux trois apps (relayées le 02/11).
final class CoverageCardRulesTests: XCTestCase {
    /// Q4 (14/11) : sans techno par point, le tracé est gris « pas de mesure », jamais la
    /// couleur de la génération la plus haute ; un point sans techno l'est déjà.
    func testTraceWithoutTechnologyStaysNeutral() {
        XCTAssertEqual(CoverageCardView.traceFallbackState, .unknown)
        XCTAssertEqual(SessionSignalTrace.states([.init(technology: nil, signalStrength: -85)]), [.unknown])
        XCTAssertEqual(CoverageCardView.traceFallbackState.hex, SQQualityScale.unknownHex)
    }

    func testDistanceHasThreeStates() {
        let measured = CoverageCardView.distanceMetric(meters: 1250, hasTrace: true)
        XCTAssertEqual(measured?.highlight, true)
        XCTAssertNotEqual(measured?.value, "—")
        XCTAssertEqual(CoverageCardView.distanceMetric(meters: 0, hasTrace: true), .init(label: "Distance", value: "—"))
        XCTAssertEqual(CoverageCardView.distanceMetric(meters: 800, hasTrace: false), .init(label: "Distance", value: "—"))
        XCTAssertNil(CoverageCardView.distanceMetric(meters: nil, hasTrace: true), "not served: no tile at all")
    }

    func testThePillIsRedundantOnlyWhenTheSubtitleNamesItsTechnology() {
        XCTAssertTrue(CoverageCardView.subtitle("Bouygues Telecom · 4G", names: "4G"))
        XCTAssertTrue(CoverageCardView.subtitle("Orange · 4G / 5G NSA", names: "4G"))
        XCTAssertTrue(CoverageCardView.subtitle("4G", names: "4G"), "no operator, technology alone")
        XCTAssertFalse(CoverageCardView.subtitle("Orange · 4G", names: "5G"), "a different technology stays visible")
        XCTAssertFalse(CoverageCardView.subtitle("Orange · 5G NSA", names: "5G"), "compared technology by technology, not as text")
        XCTAssertFalse(CoverageCardView.subtitle(nil, names: "4G"))
    }
}

/// Revue q34, lot A : un post est lu d'après ce qu'il est, pas d'après le `kind`
/// servi, et la ligne réseau d'un speedtest nomme le Wi-Fi et l'opérateur sans jargon.
final class FeedAutomaticPostKindTests: XCTestCase {
    private func item(kind: String, targetType: String?, signalType: String? = nil, metadata: String = "{}") throws -> UnifiedSocialFeedItem {
        let target = targetType.map { "\"\($0)\"" } ?? "null"
        let signal = signalType.map { "{\"type\":\"\($0)\"}" } ?? "null"
        return try JSONDecoder().decode(UnifiedSocialFeedItem.self, from: Data("""
        {"id":"p1","kind":"\(kind)","author":{"id":"u1"},"text":"t","targetType":\(target),"signal":\(signal),
         "metadata":\(metadata),"commentsCount":0,"repostsCount":0,"favoritesCount":0,
         "likedByMe":false,"favoritedByMe":false,"repostedByMe":false}
        """.utf8))
    }

    /// Post « telecom » : servi en `validation`, rattaché à un speedtest (constat 3).
    func testMemberPostOnASpeedtestIsShownAsASpeedtest() throws {
        XCTAssertEqual(try item(kind: "validation", targetType: "speedtest").cardKind, "speedtest")
        XCTAssertEqual(try item(kind: "validation", targetType: nil, signalType: "speedtest").cardKind, "speedtest")
        XCTAssertEqual(try item(kind: "validation", targetType: "validation", signalType: "validation").cardKind, "validation")
        XCTAssertEqual(try item(kind: "PHOTO", targetType: nil).cardKind, "photo")
    }

    /// Site communautaire sans activityType : targetType suffit (constat 5).
    func testCustomSiteIsRecognisedByItsTarget() throws {
        let site = try item(kind: "validation", targetType: "custom_site", metadata: #"{"customSiteName":"Pylône"}"#)
        XCTAssertEqual(FeedActivity(item: site)?.family, .customSite)
        XCTAssertEqual(FeedActivity(item: site)?.subtitle, "Pylône")
        XCTAssertNil(FeedActivity(item: try item(kind: "validation", targetType: "validation")))
    }

    /// La commune d'une photo vient de sa metadata quand le résumé n'en a pas (constat 7).
    func testCardPlaceFallsBackToTheSiteCommune() throws {
        XCTAssertEqual(try item(kind: "photo", targetType: "photo", metadata: #"{"siteCommune":" Grenoble "}"#).cardPlace, "Grenoble")
        XCTAssertNil(try item(kind: "photo", targetType: "photo").cardPlace)
    }

    /// La description d'un badge n'existe qu'en français : rien en anglais (constat 6).
    func testBadgeDescriptionIsShownOnlyInFrench() throws {
        let badge = try item(kind: "badge", targetType: "badge",
                             metadata: #"{"activityType":"badge_earned","badgeName":"Explorateur","badgeDescription":"Visiter 10 sites"}"#)
        XCTAssertEqual(FeedActivity(item: badge, appIsFrench: true)?.badgeDescription, "Visiter 10 sites")
        XCTAssertNil(FeedActivity(item: badge, appIsFrench: false)?.badgeDescription)
    }

    /// « Orange WIFI » devient « Wi-Fi (Orange) » ; en mobile, le nom complet (constat 1).
    func testNetworkLabelNamesWiFiAndTheFullOperator() {
        XCTAssertEqual(FeedMeasureBlock.networkLabel(operator: "Orange", technology: "WIFI"), "Wi-Fi (Orange)")
        XCTAssertEqual(FeedMeasureBlock.networkLabel(operator: nil, technology: "wifi"), "Wi-Fi")
        XCTAssertEqual(FeedMeasureBlock.networkLabel(operator: "BOUYGUES", technology: "5G NSA"),
                       "\(SQBrand.operatorName("BOUYGUES") ?? "BOUYGUES") 5G NSA")
        XCTAssertEqual(FeedMeasureBlock.networkLabel(operator: "  ", technology: nil), nil)
    }
}

/// Planche de revue des posts automatiques (q34) : rend chaque élément d'un fichier
/// d'échantillons (`SQ_FEED_SAMPLES`, tableau d'éléments tels que servis) dans le fil,
/// en clair, en sombre et en grande taille de texte, vers `SQ_FEED_OUT`. Sans ces
/// variables, le test ne fait rien.
@MainActor
final class FeedSampleRenderingHarness: XCTestCase {
    func testRenderSamples() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["SQ_FEED_SAMPLES"], let output = env["SQ_FEED_OUT"] else {
            throw XCTSkip("SQ_FEED_SAMPLES / SQ_FEED_OUT absents")
        }
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as? [[String: Any]])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text) ?? Date()
        }
        let language = Locale.preferredLanguages.first?.prefix(2) ?? "fr"
        for (index, object) in raw.enumerated() {
            let name = (object["_name"] as? String) ?? "item\(index)"
            var clean = object
            clean.removeValue(forKey: "_name")
            let item = try decoder.decode(UnifiedSocialFeedItem.self, from: JSONSerialization.data(withJSONObject: clean))
            let variants: [(String, ColorScheme, DynamicTypeSize)] = [
                ("clair", .light, .large), ("sombre", .dark, .large), ("ax", .light, .accessibility3),
            ]
            for (suffix, scheme, size) in variants {
                let view = FeedItemCard(item: item)
                    .padding(16)
                    .frame(width: 393)
                    .background(scheme == .dark ? Color.black : Color(red: 0.95, green: 0.94, blue: 0.91))
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, size)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage, name)
                let path = "\(output)/\(name)-\(language)-\(suffix).png"
                try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

/// Harnais visuel des plans (non lancé sans `SQ_LIVE_MAPS_OUT`) : ImageRenderer ne
/// dessine ni MKMapSnapshotter ni MKMapView ; on monte donc les vues dans une
/// vraie fenêtre de l'app hôte et on laisse MapKit charger ses tuiles.
@MainActor
final class FeedLiveMapsHarness: XCTestCase {
    func testRenderLiveMaps() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["SQ_FEED_SAMPLES"], let output = env["SQ_LIVE_MAPS_OUT"] else {
            throw XCTSkip("SQ_FEED_SAMPLES / SQ_LIVE_MAPS_OUT absents")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()

        func capture<V: View>(_ view: V, name: String, scheme: ColorScheme, wait: UInt64 = 7) async throws {
            let host = UIHostingController(rootView: view.environment(\.colorScheme, scheme))
            host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = host
            try await Task.sleep(nanoseconds: wait * 1_000_000_000)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
        }

        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as? [[String: Any]])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { _ in Date().addingTimeInterval(-3_600) }
        let services = AppServices(config: .test)
        for object in raw {
            let name = (object["_name"] as? String) ?? ""
            guard ["08", "09", "10"].contains(where: { name.hasPrefix($0) }) else { continue }
            var clean = object
            clean.removeValue(forKey: "_name")
            let item = try decoder.decode(UnifiedSocialFeedItem.self, from: JSONSerialization.data(withJSONObject: clean))
            for scheme in [ColorScheme.light, .dark] {
                let card = ScrollView {
                    FeedItemCard(item: item).padding(16)
                }
                .background(scheme == .dark ? Color.black : Color(red: 0.95, green: 0.94, blue: 0.91))
                .environmentObject(services)
                try await capture(card, name: "\(name)-\(scheme == .dark ? "sombre" : "clair")", scheme: scheme)
            }
        }

        // Carte d'une session : tous les états du contrat, un trou de mesure, sans coupure.
        let states: [(String, Double?)] = [
            ("4G", -75), ("4G", -78), ("4G", -88), ("5G", -92), ("5G", -98), ("4G", -104),
            ("Aucun", 0), ("Aucun", -125), ("4G", -112), ("4G", -116), ("Inconnu", -90), ("3G", -82), ("4G", -70)
        ]
        let points = states.enumerated().map { index, state -> String in
            // Un saut de 3 km au milieu : le contrat v1 ne coupe pas le tracé.
            let lat = 45.17 + Double(index) * 0.004 + (index >= 9 ? 0.027 : 0)
            let lng = 5.70 + sin(Double(index) / 2) * 0.006
            let dbm = state.1.map { "\"signalStrength\":\($0)," } ?? ""
            return "{\"id\":\"p\(index)\",\"latitude\":\(lat),\"longitude\":\(lng),\(dbm)\"technology\":\"\(state.0)\"}"
        }
        let json = "{\"session\":{\"id\":\"s1\",\"name\":\"Trajet exemple\",\"source\":\"android\",\"points\":[\(points.joined(separator: ","))]}}"
        let detail = try JSONDecoder().decode(CoverageSessionDetail.self, from: Data(json.utf8))
        // La carte principale sur cette session seule, puis les réglages de la feuille Carte.
        let cases: [(SessionTraceStyle, SessionPointColoring, ColorScheme, String)] = [
            (.trace, .rsrp, .light, "trace-signal-clair"), (.trace, .rsrp, .dark, "trace-signal-sombre"),
            (.points, .rsrp, .light, "points-signal-clair"), (.trace, .generation, .light, "trace-generation-clair")
        ]
        for (style, coloring, scheme, name) in cases {
            let center = CLLocationCoordinate2D(latitude: 45.2, longitude: 5.7)
            let map = MapKitMapView(
                annotations: [], coverageHeatFeatures: [], speedtestFeatures: [],
                renderVersion: 1, viewportRefreshID: 0, colorScheme: scheme, ornamentBottomInset: 0,
                center: .constant(center), zoom: .constant(12),
                onMoveEnd: { _, _ in }, onSelect: { _ in },
                sessionTrace: MapSessionTrace(points: detail.points, revision: 1, style: style, coloring: coloring,
                                              fitToken: 1, bottomInset: 300)
            )
            let view = VStack(spacing: 0) {
                map.frame(height: 560)
                MapSessionTraceSection(style: .constant(style), coloring: .constant(coloring), points: detail.points)
                    .padding(16)
                Spacer()
            }
            .background(scheme == .dark ? Color.black : Color(red: 0.95, green: 0.94, blue: 0.91))
            try await capture(view, name: "session-main-map-\(name)", scheme: scheme, wait: 8)
        }
    }
}
