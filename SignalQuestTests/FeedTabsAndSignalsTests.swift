import XCTest
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
