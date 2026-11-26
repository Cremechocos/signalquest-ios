import XCTest
import Combine
import CoreLocation
@testable import SignalQuest

@MainActor
final class FeedContextTests: XCTestCase {
    func testNetworkPulseSendsRoundedCoordinates() {
        XCTAssertEqual(SocialFeedService.pulseCoordinate(48.8566142), "48.857")
        XCTAssertEqual(SocialFeedService.pulseCoordinate(-1.5536217), "-1.554")
        XCTAssertEqual(SocialFeedService.pulseCoordinate(2), "2.000")
    }

    func testDetailReceiptSurvivesOlderInFlightReload() async throws {
        let gate = FeedFixtureGate<SocialFeedPage>(), calls = FeedCallCount()
        let started = expectation(description: "old GET started")
        let original = Self.item("post-1")
        var stale = original
        stale.commentsCount = 9
        let model = FeedViewModel(service: FeedContextFixture { _, _, _ in
            if await calls.next() == 1 { return Self.page("initial", items: [original]) }
            started.fulfill()
            return try await gate.wait()
        })
        await model.load()

        let reload = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        let data = Data(#"{"reactions":[{"emoji":"❤️","count":4,"reactedByMe":true}],"reposted":true,"repostsCount":2}"#.utf8)
        let receipt = try JSONDecoder().decode(ReactionResponse.self, from: data)
        model.acceptDetailItem(original.applying(receipt))
        XCTAssertEqual(model.page?.items.first?.reactions.first?.count, 4)

        await gate.finish(.success(Self.page("old-get", items: [stale])))
        await reload.value
        XCTAssertEqual(model.page?.requestId, "old-get")
        XCTAssertEqual(model.page?.items.first?.commentsCount, 9)
        XCTAssertEqual(model.page?.items.first?.reactions.first?.count, 4)
        XCTAssertTrue(model.page?.items.first?.likedByMe == true)
        XCTAssertEqual(model.page?.items.first?.repostsCount, 2)
        XCTAssertFalse(model.isLoading)
    }

    func testLatePageCannotReplaceTheSelectedTab() async {
        let gate = FeedFixtureGate<SocialFeedPage>()
        let entered = expectation(description: "Old tab is pending")
        let service = FeedContextFixture { _, _, tab in
            if tab == .forYou { entered.fulfill(); return try await gate.wait() }
            return Self.page("new")
        }
        let model = FeedViewModel(service: service)
        let old = Task { await model.load() }
        await fulfillment(of: [entered], timeout: 2)
        await model.select(.following)
        await gate.finish(.success(Self.page("old")))
        await old.value
        XCTAssertEqual(model.page?.requestId, "new")
        XCTAssertFalse(model.isLoading)
    }

    /// « Autour » sans position : aucune requête au serveur, l'onglet dit ce qui manque.
    func testNearbyWithoutPositionSendsNothing() async {
        let calls = FeedCallCount()
        let model = FeedViewModel(service: FeedContextFixture { _, _, tab in
            if tab == .nearby { _ = await calls.next() }
            return Self.page("page")
        })
        await model.select(.nearby)
        let nearbyCalls = await calls.next() - 1
        XCTAssertEqual(nearbyCalls, 0)
        XCTAssertEqual(model.nearbyPosition, .unavailable)
        // Une page vide : l'onglet quitte le squelette de chargement pour dire ce qui manque.
        XCTAssertEqual(model.page?.items.isEmpty, true)
        XCTAssertNil(model.page?.nextCursor)
        XCTAssertFalse(model.isLoading)
    }

    func testOldFailureCannotStopTheNewLoadingIndicator() async {
        let oldGate = FeedFixtureGate<SocialFeedPage>(), newGate = FeedFixtureGate<SocialFeedPage>()
        let oldStarted = expectation(description: "old"), newStarted = expectation(description: "new")
        let model = FeedViewModel(service: FeedContextFixture { _, _, tab in
            if tab == .forYou { oldStarted.fulfill(); return try await oldGate.wait() }
            newStarted.fulfill(); return try await newGate.wait()
        })
        let first = Task { await model.load() }
        await fulfillment(of: [oldStarted], timeout: 2)
        let second = Task { await model.select(.following) }
        await fulfillment(of: [newStarted], timeout: 2)
        await oldGate.finish(.failure(FeedFixtureError.unused)); await first.value
        XCTAssertTrue(model.isLoading); XCTAssertNil(model.errorMessage)
        await newGate.finish(.success(Self.page("current"))); await second.value
        XCTAssertFalse(model.isLoading); XCTAssertEqual(model.page?.requestId, "current")
    }

    func testHashtagRoundTripRejectsTheFirstResponseEvenWhenTheTextMatchesAgain() async {
        let gate = FeedFixtureGate<SocialFeedPage>(), calls = FeedCallCount()
        let started = expectation(description: "first hashtag request")
        let model = FeedViewModel(service: FeedContextFixture { _, tag, _ in
            if await calls.next() == 1 { started.fulfill(); return try await gate.wait() }
            return Self.page("new-" + (tag ?? "none"))
        })
        model.selectedHashtag = "alpha"
        let old = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        model.selectedHashtag = "beta"; model.selectedHashtag = "alpha"
        await model.load()
        await gate.finish(.success(Self.page("old-alpha"))); await old.value
        XCTAssertEqual(model.page?.requestId, "new-alpha")
    }

    func testOldPaginationCannotAppendToAnotherTab() async {
        let gate = FeedFixtureGate<SocialFeedPage>()
        let started = expectation(description: "pagination")
        let model = FeedViewModel(service: FeedContextFixture { cursor, _, tab in
            if cursor != nil { started.fulfill(); return try await gate.wait() }
            return tab == .forYou ? Self.page("first", cursor: "next", items: [Self.item("a")]) : Self.page("current")
        })
        await model.load()
        let old = Task { await model.loadMore() }
        await fulfillment(of: [started], timeout: 2)
        await model.select(.following)
        await gate.finish(.success(Self.page("old-page"))); await old.value
        XCTAssertEqual(model.page?.requestId, "current"); XCTAssertNil(model.page?.nextCursor)
        XCTAssertFalse(model.isLoadingMore)
    }

    func testAnEmptyPageWithACursorChainsToTheNextOne() async {
        // Le serveur découpe la page dans ce qu'il a lu : une page entièrement cachée
        // revient vide avec une suite, et rien à l'écran ne demanderait la suivante.
        let model = FeedViewModel(service: FeedContextFixture { cursor, _, _ in
            switch cursor {
            case nil: Self.page("first", cursor: "c1", items: [Self.item("a")])
            case "c1": Self.page("hidden", cursor: "c2")
            default: Self.page("last", items: [Self.item("b")])
            }
        })
        await model.load()
        await model.loadMore()
        XCTAssertEqual(model.page?.items.map(\.id), ["a", "b"])
        XCTAssertNil(model.page?.nextCursor)
        XCTAssertFalse(model.isLoadingMore)
    }

    func testAnEmptyFirstPageWithACursorIsNotAnEmptyFeed() async {
        let model = FeedViewModel(service: FeedContextFixture { cursor, _, _ in
            cursor == nil ? Self.page("hidden", cursor: "c1") : Self.page("next", items: [Self.item("a")])
        })
        await model.load()
        XCTAssertEqual(model.page?.items.map(\.id), ["a"])
        XCTAssertFalse(model.isLoading)
    }

    func testEmptyPagesStopAfterAFewHopsAndKeepTheirCursor() async {
        let calls = FeedCallCount()
        let model = FeedViewModel(service: FeedContextFixture { cursor, _, _ in
            let call = await calls.next()
            return cursor == nil ? Self.page("first", cursor: "c0", items: [Self.item("a")]) : Self.page("hidden", cursor: "c\(call)")
        })
        await model.load()
        await model.loadMore()
        let next = await calls.next()
        XCTAssertEqual(next, 2 + FeedViewModel.emptyPageHops, "1 page puis 5 pages vides, pas davantage")
        XCTAssertNotNil(model.page?.nextCursor, "faire défiler relance la suite")
        XCTAssertEqual(model.page?.items.map(\.id), ["a"])
    }

    func testReturnAfterStopIgnoresThePreviousLoad() async {
        let gate = FeedFixtureGate<SocialFeedPage>(), calls = FeedCallCount()
        let started = expectation(description: "before leaving")
        let model = FeedViewModel(service: FeedContextFixture { _, _, _ in
            if await calls.next() == 1 { started.fulfill(); return try await gate.wait() }
            return Self.page("after-return")
        })
        let old = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        model.stopStream()
        await model.load()
        await gate.finish(.success(Self.page("before-return"))); await old.value
        XCTAssertEqual(model.page?.requestId, "after-return")
    }

    func testStreamRechecksTheSelectedFilterAndDoesNotInsertOrDuplicatePosts() async throws {
        let streams = FeedFixtureStreams(), calls = FeedCallCount()
        let current = Self.item("current"), fresh = Self.item("fresh")
        let model = FeedViewModel(service: FeedContextFixture { _, tag, tab in
            XCTAssertEqual(tag, "beta"); XCTAssertEqual(tab, .following)
            let count = await calls.next()
            return Self.page("filtered", items: count == 1 ? [current] : [current, fresh])
        })
        model.selectedHashtag = "beta"
        await model.select(.following)
        model.startStream { streams.make() }
        defer { model.stopStream() }
        // Two unrelated global posts must not produce a count of two.
        let raw = String(decoding: try JSONEncoder.signalQuest.encode(Self.page("global", items: [Self.item("x"), Self.item("y")])), as: UTF8.self)
        streams.emit(0, raw)
        await eventually { model.pendingCount == 1 }
        XCTAssertEqual(model.page?.items.map(\.id), ["current"])
        model.stopStream(); model.startStream { streams.make() }
        let replayChecked = expectation(description: "Reconnected stream rechecked the filter")
        let subscription = model.$pendingCount.dropFirst().sink { count in
            if count == 1 { replayChecked.fulfill() }
        }
        defer { subscription.cancel() }
        streams.emit(0, raw); streams.emit(1, raw)
        await fulfillment(of: [replayChecked], timeout: 2)
        XCTAssertEqual(model.pendingCount, 1)
        // Règle commune du 24/11 (Fil Communauté, C2/C8) : toucher la pastille insère les
        // nouveautés en tête, sans relire le tri affiché.
        await model.applyPending()
        XCTAssertEqual(model.page?.items.map(\.id), ["fresh", "current"])
        XCTAssertEqual(model.pendingCount, 0)
    }

    /// COM-04 : la suite du fil qui échoue, ou qui ne ramène que des pages vides, laisse un bouton
    /// pour réessayer ; avant, rien ne la relançait si les dernières cartes étaient déjà à l'écran.
    func testFailedOrEmptyContinuationOffersARetry() async throws {
        let failing = FeedViewModel(service: FeedContextFixture { cursor, _, _ in
            if cursor == nil { return Self.page("first", cursor: "next", items: [Self.item("a")]) }
            throw URLError(.notConnectedToInternet)
        })
        await failing.load()
        XCTAssertFalse(failing.loadMoreStalled)
        await failing.loadMore()
        XCTAssertTrue(failing.loadMoreStalled, "échec : « Charger plus de publications »")
        XCTAssertEqual(failing.page?.items.map(\.id), ["a"], "la page lue reste")

        let empty = FeedViewModel(service: FeedContextFixture { cursor, _, _ in
            if cursor == nil { return Self.page("first", cursor: "next", items: [Self.item("a")]) }
            return Self.page("empty", cursor: "next", items: [])
        })
        await empty.load()
        await empty.loadMore()
        XCTAssertTrue(empty.loadMoreStalled, "pages vides à la file : on le dit")
        await empty.load()
        XCTAssertFalse(empty.loadMoreStalled, "un rechargement efface l'état")
    }

    /// COM-02 : bloquer un membre, ou supprimer une publication, vide aussi ce qui attend derrière
    /// la pastille « N nouvelles » ; la toucher réinsérait le post du membre bloqué.
    func testPendingPostsLeaveWithABlockedAuthorOrADeletedPost() async throws {
        for removal in ["author", "post"] {
            let streams = FeedFixtureStreams(), calls = FeedCallCount()
            let current = Self.item("current"), fresh = Self.item("fresh")
            let model = FeedViewModel(service: FeedContextFixture { _, _, _ in
                let count = await calls.next()
                return Self.page("page", items: count == 1 ? [current] : [current, fresh])
            })
            // Onglet chronologique : la page lue sert de référence, sans relecture qui
            // absorberait déjà la nouveauté (même montage que le test du flux ci-dessus).
            await model.select(.following)
            model.startStream { streams.make() }
            let raw = String(decoding: try JSONEncoder.signalQuest.encode(Self.page("global", items: [Self.item("x")])), as: UTF8.self)
            streams.emit(0, raw)
            await eventually { model.pendingCount == 1 }
            if removal == "author" { model.removeAuthor("qa-author") } else { model.removeItem("fresh") }
            XCTAssertEqual(model.pendingCount, 0, "pastille vidée (\(removal))")
            model.stopStream()
        }
    }

    /// Audit perf, E2 : deux instantanés reçus dans l'intervalle ne font qu'une relecture,
    /// à l'échéance ; aucun n'est perdu. Chaque relecture rend un post de plus.
    func testStreamRechecksAtMostOncePerIntervalWithoutLosingALateSnapshot() async throws {
        let streams = FeedFixtureStreams(), calls = FeedCallCount()
        let model = FeedViewModel(service: FeedContextFixture { _, _, _ in
            let count = await calls.next()
            return Self.page("read-\(count)", items: (1...count).map { Self.item("post-\($0)") })
        }, liveCheckInterval: 1.5)
        await model.load()
        model.startStream { streams.make() }
        defer { model.stopStream() }
        let raw = String(decoding: try JSONEncoder.signalQuest.encode(Self.page("global", items: [Self.item("x")])), as: UTF8.self)
        streams.emit(0, raw)
        await eventually { model.pendingCount == 1 }

        streams.emit(0, raw); streams.emit(0, raw)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.pendingCount, 1, "Pas de relecture avant l'échéance")
        await eventually { model.pendingCount == 2 }
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(model.pendingCount, 2, "Une seule relecture pour les deux instantanés")
    }

    /// Audit perf, E2 : seule la première page demande stories, tendances et suggestions ;
    /// la page suivante et le fil d'un hashtag demandent les posts seuls.
    func testNextPagesAskForPostsOnly() async throws {
        var includes: [String] = []
        // Le gestionnaire tourne sur une file de CFNetwork : rien d'isolé au MainActor dedans.
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/social/feed" {
                includes.append(Self.queryValue("include", of: request) ?? "")
            }
            let json = Self.queryValue("cursor", of: request) != nil
                ? #"{"items":[],"nextCursor":null}"#
                : #"{"items":[{"id":"a","kind":"post","author":{"id":"qa-author","name":"Recette"},"text":"a"}],"nextCursor":"next"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (response, Data(json.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("feed-include-access-token")
        let service = SocialFeedService(api: APIClient(config: .test, credentials: credentials,
                                                       session: URLSession(configuration: configuration)))
        let model = FeedViewModel(service: service)

        await model.load()
        await model.loadMore()
        _ = try await service.loadFeedItems(cursor: nil, hashtag: "beta", tab: nil)
        XCTAssertEqual(includes, ["items,stories,trends,suggestions", "items", "items"])
        XCTAssertEqual(model.page?.items.map(\.id), ["a"])
    }

    /// Fil Communauté C8 et contrat B3 v1.1 : le tri choisi donne le `ranking`, et seule la
    /// Pertinence du fil demande `rankWindow=1` ; la pastille relit toujours en `latest`.
    func testSortSetsRankingAndRankWindowOnEveryPage() async throws {
        var queries: [String] = []
        MockURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/social/feed" {
                // Pas de closure ici : sous le MainActor du test, elle serait isolée et ferait
                // planter le gestionnaire, qui tourne sur une file de CFNetwork.
                let filter = Self.queryValue("filter", of: request) ?? "?"
                let ranking = Self.queryValue("ranking", of: request) ?? "?"
                let window = Self.queryValue("rankWindow", of: request) ?? "-"
                queries.append("\(filter)|\(ranking)|\(window)")
            }
            let json = Self.queryValue("cursor", of: request) != nil
                ? #"{"items":[],"nextCursor":null}"#
                : #"{"items":[{"id":"a","kind":"post","author":{"id":"qa-author","name":"Recette"},"text":"a"}],"nextCursor":"rank:opaque"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (response, Data(json.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("feed-sort-access-token")
        let service = SocialFeedService(api: APIClient(config: .test, credentials: credentials,
                                                       session: URLSession(configuration: configuration)))
        _ = try await service.loadFeed(cursor: nil, hashtag: nil, tab: .forYou, near: nil, sort: .relevance)
        _ = try await service.loadFeedItems(cursor: "rank:opaque", hashtag: nil, tab: .forYou, near: nil, sort: .relevance)
        _ = try await service.loadFeedItems(cursor: nil, hashtag: nil, tab: .forYou, near: nil, sort: .latest)
        _ = try await service.loadFeedItems(cursor: nil, hashtag: nil, tab: .photos, near: nil, sort: .relevance)
        _ = try await service.loadFeedItems(cursor: nil, hashtag: nil, tab: .following, near: nil, sort: nil)
        // L'accueil et les appelants sans tri ne demandent jamais la fenêtre.
        _ = try await service.loadFeedItems(cursor: nil, hashtag: nil, tab: .forYou)
        XCTAssertEqual(queries, ["all|foryou|1", "all|foryou|1", "all|latest|-", "media|smart|1",
                                 "following|latest|-", "all|foryou|-"])
    }

    /// C2/C8 : une nouveauté est plus récente que la plus récente affichée. Une publication
    /// ancienne qui remonte, ou en cours de suppression, n'en est pas une (recette du 24/11).
    func testOnlyNewerPostsAreAnnouncedAndTheirTapInsertsThem() async throws {
        func dated(_ id: String, _ iso: String) -> UnifiedSocialFeedItem {
            let raw = #"{"id":"\#(id)","kind":"post","author":{"id":"qa-author","name":"Recette"},"text":"\#(id)","createdAt":"\#(iso)"}"#
            return try! JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: Data(raw.utf8))
        }
        let shown = [dated("b", "2026-11-24T10:00:00Z"), dated("a", "2026-11-24T09:00:00Z")]
        let candidates = [dated("new", "2026-11-24T11:00:00Z"), dated("deleting", "2026-11-24T10:30:00Z"),
                          dated("b", "2026-11-24T10:00:00Z"), dated("old", "2026-11-23T08:00:00Z")]
        XCTAssertEqual(FeedViewModel.newerItems(in: candidates, than: shown, excluding: ["deleting"]).map(\.id), ["new"])
        // Rien d'affiché ni de daté : tout ce qui n'est pas connu compte.
        XCTAssertEqual(FeedViewModel.newerItems(in: candidates, than: [], excluding: []).count, 4)

        let model = FeedViewModel(service: FeedContextFixture { _, _, _ in Self.page("page", items: shown) })
        await model.load()
        await model.applyPending()
        XCTAssertEqual(model.page?.items.map(\.id), ["b", "a"], "sans nouveauté gardée, un simple rechargement")
    }

    /// Règle commune du 25/11 : un profil illisible donne « Rien de neuf… », jamais « personne ».
    func testUnreadableFollowingCountIsNotReadAsNobody() async {
        let model = FeedViewModel(service: FeedContextFixture { _, _, _ in Self.page("page") })
        XCTAssertNil(model.followingCount)
        XCTAssertFalse(model.followingCountFailed)
        await model.loadFollowingCount(userId: "qa-viewer")
        XCTAssertNil(model.followingCount)
        XCTAssertTrue(model.followingCountFailed)
    }

    /// Règle commune du 25/11 (défaut vu en prod sur le Web) : en Pertinence, la page classée ne
    /// contient pas les plus récentes ; la lecture `latest` d'ouverture fixe la référence, et seul
    /// ce qui arrive ensuite est annoncé.
    func testRelevancePillDoesNotAnnounceRecentPostsAtOpening() async throws {
        func dated(_ id: String, _ iso: String) -> UnifiedSocialFeedItem {
            let raw = #"{"id":"\#(id)","kind":"post","author":{"id":"qa-author","name":"Recette"},"text":"\#(id)","createdAt":"\#(iso)"}"#
            return try! JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: Data(raw.utf8))
        }
        let ranked = dated("ranked", "2026-11-22T08:00:00Z"), recent = dated("recent", "2026-11-25T01:00:00Z")
        let brandNew = dated("new", "2026-11-25T02:00:00Z")
        let streams = FeedFixtureStreams(), calls = FeedCallCount()
        let model = FeedViewModel(service: FeedContextFixture { _, _, _ in
            switch await calls.next() {
            case 1: return Self.page("relevance", items: [ranked])          // page classée
            case 2, 3: return Self.page("latest", items: [recent, ranked])   // ouverture, puis relecture
            default: return Self.page("latest", items: [brandNew, recent, ranked])
            }
        }, liveCheckInterval: 0)
        await model.load()
        XCTAssertFalse(model.isChronological)
        model.startStream { streams.make() }
        defer { model.stopStream() }
        let raw = String(decoding: try JSONEncoder.signalQuest.encode(Self.page("global", items: [Self.item("x")])), as: UTF8.self)
        streams.emit(0, raw)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.pendingCount, 0, "« recent » était déjà en ligne à l'ouverture")
        streams.emit(0, raw)
        await eventually { model.pendingCount == 1 }
        await model.applyPending()
        XCTAssertEqual(model.page?.items.map(\.id), ["new", "ranked"])
    }

    /// C8 : changer de tri garde la page affichée jusqu'à l'arrivée de la nouvelle.
    func testChangingTheSortKeepsThePageUntilTheNewOneArrives() async throws {
        let key = FeedViewModel.feedSortKey(ownerScopeId: LocalAccountScope.currentOwnerScopeId)
        let previous = UserDefaults.standard.dictionary(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let gate = FeedFixtureGate<SocialFeedPage>(), calls = FeedCallCount()
        let started = expectation(description: "second load")
        let model = FeedViewModel(service: FeedContextFixture { _, _, _ in
            if await calls.next() == 1 { return Self.page("relevance", items: [Self.item("a")]) }
            started.fulfill()
            return try await gate.wait()
        })
        await model.load()
        XCTAssertEqual(model.sort(for: .forYou), .relevance)
        XCTAssertEqual(model.sort(for: .nearby), .latest)
        XCTAssertNil(model.sort(for: .following))
        XCTAssertFalse(model.isChronological)
        let change = Task { await model.selectSort(.latest) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.page?.requestId, "relevance", "la page affichée reste à l'écran")
        XCTAssertTrue(model.isChronological)
        await gate.finish(.success(Self.page("latest", items: [Self.item("b")])))
        await change.value
        XCTAssertEqual(model.page?.requestId, "latest")
        XCTAssertEqual(model.sort(for: .forYou), .latest)
    }

    /// C8 : séparateurs « Aujourd'hui », « Hier », puis la date ; heure exacte au-delà de 24 h.
    func testDaySeparatorsAndExactTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = ISO8601DateFormatter().date(from: "2026-11-24T20:00:00Z")!
        func dated(_ id: String, _ iso: String) -> UnifiedSocialFeedItem {
            let raw = #"{"id":"\#(id)","kind":"post","author":{"id":"qa-author","name":"Recette"},"text":"\#(id)","createdAt":"\#(iso)"}"#
            return try! JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: Data(raw.utf8))
        }
        let today = dated("t", "2026-11-24T18:00:00Z"), today2 = dated("t2", "2026-11-24T08:00:00Z")
        let yesterday = dated("y", "2026-11-23T21:40:00Z"), older = dated("o", "2026-11-20T10:00:00Z")
        XCTAssertEqual(FeedDaySeparator.title(for: today, after: nil, now: now, calendar: calendar), String(localized: "Aujourd’hui"))
        XCTAssertNil(FeedDaySeparator.title(for: today2, after: today, now: now, calendar: calendar))
        XCTAssertEqual(FeedDaySeparator.title(for: yesterday, after: today2, now: now, calendar: calendar), String(localized: "Hier"))
        XCTAssertNotNil(FeedDaySeparator.title(for: older, after: yesterday, now: now, calendar: calendar))
        XCTAssertNil(FeedDaySeparator.title(for: Self.item("sans-date"), after: nil, now: now, calendar: calendar))

        let recent = now.addingTimeInterval(-3_600), dayOld = now.addingTimeInterval(-90_000)
        XCTAssertEqual(CardHeader.timeLabel(exact: true, now: now)(recent), recent.formatted(.sqRelative))
        XCTAssertEqual(CardHeader.timeLabel(exact: true, now: now)(dayOld), dayOld.formatted(.dateTime.hour().minute()))
        XCTAssertEqual(CardHeader.timeLabel(exact: false, now: now)(dayOld), dayOld.formatted(.sqRelative))
    }

    /// Jusqu'à 5 s : une seconde ne suffisait pas sous la charge des portes
    /// (simulateur partagé), le test passant pourtant seul.
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    /// E5 (audit du 21/11) : la page suivante se demande dès l'une des quatre dernières cartes,
    /// et la photo des trois cartes suivantes se précharge à l'adresse et à la taille de sa carte.
    func testNextPageStartsFourCardsBeforeTheEndAndUpcomingPhotosArePrefetched() throws {
        let items = (0..<10).map { Self.item("p\($0)") }
        XCTAssertFalse(FeedViewModel.shouldLoadMore(appearing: "p5", in: items))
        XCTAssertTrue(FeedViewModel.shouldLoadMore(appearing: "p6", in: items))
        XCTAssertTrue(FeedViewModel.shouldLoadMore(appearing: "p9", in: items))
        XCTAssertFalse(FeedViewModel.shouldLoadMore(appearing: "absent", in: items))
        XCTAssertTrue(FeedViewModel.shouldLoadMore(appearing: "p0", in: Array(items.prefix(3))))
        XCTAssertEqual(FeedViewModel.upcoming(after: "p2", in: items).map(\.id), ["p3", "p4", "p5"])
        XCTAssertEqual(FeedViewModel.upcoming(after: "p8", in: items).map(\.id), ["p9"])
        XCTAssertTrue(FeedViewModel.upcoming(after: "p9", in: items).isEmpty)
        XCTAssertTrue(FeedViewModel.upcoming(after: "absent", in: items).isEmpty)

        let full = "https://cdn.example.invalid/full.webp", thumb = "https://cdn.example.invalid/thumb.webp"
        func card(_ kind: String, attachment: String = "image") throws -> UnifiedSocialFeedItem {
            let raw = #"{"id":"\#(kind)","kind":"\#(kind)","author":{"id":"qa-author","name":"Recette"},"text":"x","#
                + #""attachments":[{"id":"a1","kind":"\#(attachment)","url":"\#(full)","thumbnailUrl":"\#(thumb)"}]}"#
            return try JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: Data(raw.utf8))
        }
        // Même aiguillage que les cartes : la carte photo montre l'image pleine, la publication sa vignette.
        let photo = FeedItemCard.prefetchImage(for: try card("photo"))
        XCTAssertEqual(photo?.url.absoluteString, full)
        XCTAssertEqual(photo?.maxDimension, PhotoCardView.heroMaxDimension)
        XCTAssertEqual(PhotoCardView.heroMaxDimension, 460)
        let post = FeedItemCard.prefetchImage(for: try card("post"))
        XCTAssertEqual(post?.url.absoluteString, thumb)
        XCTAssertEqual(post?.maxDimension, PostCardView.imageMaxDimension)
        XCTAssertEqual(PostCardView.imageMaxDimension, 440)
        XCTAssertNil(FeedItemCard.prefetchImage(for: try card("post", attachment: "video")))
        XCTAssertNil(FeedItemCard.prefetchImage(for: try card("speedtest")))
        XCTAssertNil(FeedItemCard.prefetchImage(for: Self.item("sans-photo")))
    }

    /// Plan Fil Communauté, C5 : la publication quitte le fil aussitôt, rien ne part avant
    /// la fin du délai « Annuler », et un rechargement pendant ce délai ne la rend pas.
    func testDeletionWaitsForTheUndoDelayAndUndoKeepsThePost() async throws {
        let deletions = FeedDeletions()
        let items = ["a", "b", "c"].map(Self.item)
        let service = FeedContextFixture { _, _, _ in Self.page("page", items: items) }
        service.onDelete = { await deletions.record($0) }
        let model = FeedViewModel(service: service)
        model.deletions = Self.isolatedDeletions()
        await model.load()

        model.deletePost(items[1], after: .milliseconds(150))
        XCTAssertEqual(model.page?.items.map(\.id), ["a", "c"])
        model.undoDeletion("b")
        XCTAssertEqual(model.page?.items.map(\.id), ["a", "b", "c"], "« Annuler » remet la publication à sa place")
        try await Task.sleep(for: .milliseconds(400))
        let afterUndo = await deletions.ids
        XCTAssertEqual(afterUndo, [], "rien ne part après « Annuler »")

        model.deletePost(items[2], after: .milliseconds(250))
        await model.load()
        XCTAssertEqual(model.page?.items.map(\.id), ["a", "b"], "un rechargement ne rend pas une publication en cours de suppression")
        let beforeDelay = await deletions.ids
        XCTAssertEqual(beforeDelay, [])
        try await Task.sleep(for: .milliseconds(600))
        let sent = await deletions.ids
        XCTAssertEqual(sent, ["c"])
        model.undoDeletion("c")
        XCTAssertEqual(model.page?.items.map(\.id), ["a", "b"], "trop tard une fois la suppression partie")
    }

    /// Un refus du serveur, après le délai, remet la publication à sa place avec le message.
    func testRefusedDeletionPutsThePostBack() async throws {
        let items = ["a", "b", "c"].map(Self.item)
        let service = FeedContextFixture { _, _, _ in Self.page("page", items: items) }
        service.onDelete = { _ in throw APIError.http(status: 500, code: nil, message: "", requestId: nil, retryAfter: nil) }
        let model = FeedViewModel(service: service)
        model.deletions = Self.isolatedDeletions()
        await model.load()
        model.deletePost(items[0], after: .milliseconds(50))
        XCTAssertEqual(model.page?.items.map(\.id), ["b", "c"])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.page?.items.map(\.id), ["a", "b", "c"])
        XCTAssertNotNil(model.actionError)
    }

    /// COM-01 : app tuée pendant le délai « Annuler ». Avant, la suppression ne vivait que
    /// dans une tâche du fil et ne partait jamais, alors que l'écran l'avait annoncée. Elle est
    /// inscrite sur l'appareil, et le passage suivant (lancement, retour du réseau) l'envoie.
    func testDeletionAnnouncedBeforeTheAppIsKilledStillReachesTheServer() async throws {
        let suite = "PendingPostDeletionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let deletions = FeedDeletions()
        let service = FeedContextFixture { _, _, _ in Self.page("page") }
        service.onDelete = { await deletions.record($0) }

        let beforeKill = PendingPostDeletions(defaults: defaults)
        beforeKill.schedule(postId: "c", after: .seconds(60), service: service) { _ in }
        // Relance : une autre instance relit l'inscription, sans la tâche du délai.
        let relaunched = PendingPostDeletions(defaults: defaults)
        XCTAssertTrue(relaunched.isPending("c"), "un rechargement ne rend pas la publication")
        await relaunched.flush(using: service)
        let tooEarly = await deletions.ids
        XCTAssertEqual(tooEarly, [], "rien ne part avant la fin du délai : il reprend à l'échéance restante")
        // Relance après l'échéance : la suppression part au premier passage.
        let late = PendingPostDeletions(defaults: defaults)
        await late.flush(using: service, now: Date().addingTimeInterval(120))
        let sent = await deletions.ids
        XCTAssertEqual(sent, ["c"])
        XCTAssertFalse(late.isPending("c"))
        relaunched.cancel("c")
        beforeKill.cancel("c")
    }

    /// Au passage suivant, une panne passagère garde la suppression ; un refus définitif
    /// (publication déjà supprimée, 404) l'abandonne.
    func testFlushKeepsTransientFailuresAndDropsRefusals() async throws {
        let suite = "PendingPostDeletionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FeedContextFixture { _, _, _ in Self.page("page") }
        service.onDelete = { id in
            if id == "offline" { throw URLError(.notConnectedToInternet) }
            throw APIError.http(status: 404, code: nil, message: "", requestId: nil, retryAfter: nil)
        }
        let beforeKill = PendingPostDeletions(defaults: defaults)
        beforeKill.schedule(postId: "offline", after: .seconds(60), service: service) { _ in }
        beforeKill.schedule(postId: "gone", after: .seconds(60), service: service) { _ in }
        let relaunched = PendingPostDeletions(defaults: defaults)
        await relaunched.flush(using: service, now: Date().addingTimeInterval(120))
        XCTAssertTrue(relaunched.isPending("offline"), "réessayée au prochain passage")
        XCTAssertFalse(relaunched.isPending("gone"))
        beforeKill.cancel("offline")
        beforeKill.cancel("gone")
    }

    /// File de suppressions propre à un test, hors des préférences de l'app.
    private static func isolatedDeletions() -> PendingPostDeletions {
        PendingPostDeletions(defaults: UserDefaults(suiteName: "PendingPostDeletionsTests.\(UUID().uuidString)")!)
    }

    /// Plan Fil Communauté, C1 : le dernier onglet ouvert revient au lancement suivant,
    /// relu une seule fois ; « Enregistrés », ouvert depuis le menu ⋯, n'est jamais retenu.
    func testLastTabIsRememberedOnTheDevice() async {
        let key = FeedViewModel.lastTabKey(ownerScopeId: LocalAccountScope.currentOwnerScopeId)
        let previous = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        let first = FeedViewModel(service: FeedContextFixture { _, _, _ in Self.page("page") })
        XCTAssertFalse(first.restoreLastTab(), "rien de retenu : l'onglet par défaut")
        await first.select(.photos)
        await first.select(.saved)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "photos")

        let next = FeedViewModel(service: FeedContextFixture { _, _, _ in Self.page("page") })
        XCTAssertTrue(next.restoreLastTab())
        XCTAssertEqual(next.tab, .photos)
        await next.select(.forYou)
        XCTAssertFalse(next.restoreLastTab(), "relu une seule fois, au premier affichage")
        XCTAssertEqual(next.tab, .forYou)
    }

    /// Plan Fil Communauté, C4 : une zone choisie à la main remplace la position de l'appareil,
    /// même sans service de localisation ; « Ma position » la retire.
    func testNearbyZoneChosenByHandReplacesThePosition() async {
        let calls = FeedCallCount()
        let model = FeedViewModel(service: FeedContextFixture { _, _, tab in
            if tab == .nearby { _ = await calls.next() }
            return Self.page("page")
        })
        await model.select(.nearby)
        XCTAssertEqual(model.nearbyPosition, .unavailable)
        await model.chooseNearbyZone(name: "Annecy", coordinate: CLLocationCoordinate2D(latitude: 45.899_247, longitude: 6.129_384))
        XCTAssertEqual(model.nearbyPosition, .ready)
        XCTAssertEqual(model.nearbyZone?.name, "Annecy")
        XCTAssertEqual(model.nearPoint, FeedNearPoint(CLLocationCoordinate2D(latitude: 45.90, longitude: 6.13)))
        let afterZone = await calls.next() - 1
        XCTAssertEqual(afterZone, 1, "la zone choisie charge l'onglet")
        await model.clearNearbyZone()
        XCTAssertNil(model.nearbyZone)
        XCTAssertNil(model.nearPoint)
        XCTAssertEqual(model.nearbyPosition, .unavailable)
    }

    /// Règle commune du 25/11 : Autour vide propose déjà « Publier », le crayon flottant se retire ;
    /// partout ailleurs, et dès qu'une publication arrive, il revient.
    func testEmptyNearbyOffersPublishInsteadOfThePencil() async throws {
        let empty = try JSONDecoder.signalQuest.decode(SocialFeedPage.self, from: Data(#"{"items":[]}"#.utf8))
        let model = FeedViewModel(service: FeedContextFixture { _, _, _ in empty })
        await model.load()
        XCTAssertFalse(model.emptyStateOffersPublish, "Pour toi vide n'a pas de « Publier »")
        await model.select(.nearby)
        XCTAssertFalse(model.emptyStateOffersPublish, "sans position, l'état vide n'est pas affiché")
        await model.chooseNearbyZone(name: "Lyon", coordinate: CLLocationCoordinate2D(latitude: 45.76, longitude: 4.84))
        XCTAssertTrue(model.emptyStateOffersPublish, "Autour vide : le crayon se retire")
        model.selectedHashtag = "alpha"
        XCTAssertFalse(model.emptyStateOffersPublish, "un hashtag a son propre état vide, sans « Publier »")

        let full = FeedViewModel(service: FeedContextFixture { _, _, _ in Self.page("page", items: [Self.item("a")]) })
        await full.chooseNearbyZone(name: "Lyon", coordinate: CLLocationCoordinate2D(latitude: 45.76, longitude: 4.84))
        await full.select(.nearby)
        XCTAssertFalse(full.emptyStateOffersPublish, "des publications : le crayon reste")
    }

    /// Plan Fil Communauté, B4 : le rayon de « Autour » vient de la réponse, jamais d'une constante.
    func testNearbyRadiusIsReadFromTheResponse() async throws {
        let raw = #"{"items":[],"nextCursor":null,"nearRadiusKm":25}"#
        let decoded = try JSONDecoder.signalQuest.decode(SocialFeedPage.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.nearRadiusKm, 25)
        let model = FeedViewModel(service: FeedContextFixture { _, _, _ in decoded })
        XCTAssertNil(model.nearRadiusKm)
        await model.load()
        XCTAssertEqual(model.nearRadiusKm, 25)
        let older = try JSONDecoder.signalQuest.decode(SocialFeedPage.self, from: Data(#"{"items":[]}"#.utf8))
        XCTAssertNil(older.nearRadiusKm)
    }

    nonisolated private static func queryValue(_ name: String, of request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    nonisolated private static func item(_ id: String) -> UnifiedSocialFeedItem {
        let raw = #"{"id":"\#(id)","kind":"post","author":{"id":"qa-author","name":"Recette"},"text":"\#(id)"}"#
        return try! JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: Data(raw.utf8))
    }

    nonisolated private static func page(_ id: String, cursor: String? = nil, items: [UnifiedSocialFeedItem] = []) -> SocialFeedPage {
        SocialFeedPage(items: items, nextCursor: cursor, stories: [], trendingHashtags: [], suggestedUsers: [], requestId: id)
    }
}

private enum FeedFixtureError: Error { case unused }
private final class FeedContextFixture: SocialFeedServicing, @unchecked Sendable {
    let handler: @Sendable (String?, String?, FeedTab?) async throws -> SocialFeedPage
    init(_ handler: @escaping @Sendable (String?, String?, FeedTab?) async throws -> SocialFeedPage) { self.handler = handler }
    func loadFeed(cursor: String?, hashtag: String?, tab: FeedTab?) async throws -> SocialFeedPage { try await handler(cursor, hashtag, tab) }
    func post(id: String) async throws -> UnifiedSocialFeedItem? { throw FeedFixtureError.unused }
    func createPost(
        text: String,
        visibility: String,
        attachments: [CreatePostAttachment],
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?,
        poll: CreatePostPoll?
    ) async throws -> UnifiedSocialFeedItem? { throw FeedFixtureError.unused }
    func uploadImage(data: Data, mimeType: String) async throws -> CreatePostAttachment { throw FeedFixtureError.unused }
    func publishPost(
        text: String,
        visibility: String,
        imageData: Data?,
        imageMimeType: String,
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?,
        poll: CreatePostPoll?
    ) async throws -> UnifiedSocialFeedItem? { throw FeedFixtureError.unused }
    func retryPendingPosts() async {  }
    func react(postId: String, emoji: String) async throws -> ReactionResponse { throw FeedFixtureError.unused }
    func favorite(postId: String) async throws -> ReactionResponse { throw FeedFixtureError.unused }
    func repost(postId: String) async throws -> ReactionResponse { throw FeedFixtureError.unused }
    func muteNotifications(postId: String) async throws -> SuccessResponse { throw FeedFixtureError.unused }
    func editPost(postId: String, text: String, visibility: String?) async throws -> UnifiedSocialFeedItem? { throw FeedFixtureError.unused }
    func setVisibility(postId: String, visibility: String) async throws -> UnifiedSocialFeedItem? { throw FeedFixtureError.unused }
    var onDelete: (@Sendable (String) async throws -> Void)?
    func deletePost(postId: String) async throws {
        guard let onDelete else { throw FeedFixtureError.unused }
        try await onDelete(postId)
    }
    func setPinned(postId: String, pinned: Bool) async throws { throw FeedFixtureError.unused }
    func votePoll(postId: String, optionId: String?, removing: Bool) async throws -> FeedPoll? { throw FeedFixtureError.unused }
    func followedHashtags() async throws -> [FollowedHashtag] { throw FeedFixtureError.unused }
    func setHashtagFollowed(_ tag: String, following: Bool) async throws { throw FeedFixtureError.unused }
    func mutes() async throws -> SocialMutes { throw FeedFixtureError.unused }
    func setHashtagMuted(_ tag: String, muted: Bool) async throws { throw FeedFixtureError.unused }
    func setWordMuted(_ pattern: String, muted: Bool) async throws { throw FeedFixtureError.unused }
    func explore(query: String?) async throws -> SocialExploreResult { throw FeedFixtureError.unused }
    func weeklyRecap() async throws -> WeeklyRecapStats? { throw FeedFixtureError.unused }
    func publishWeeklyRecap() async throws -> WeeklyRecapPublishResponse { throw FeedFixtureError.unused }
    func share(postId: String, conversationId: String) async throws -> String? { throw FeedFixtureError.unused }
    func userProfile(userId: String) async throws -> SocialUserProfile { throw FeedFixtureError.unused }
    func toggleFollow(userId: String) async throws -> SocialFollowResult { throw FeedFixtureError.unused }
    func setPostNotifications(userId: String, level: PostNotificationLevel) async throws -> PostNotificationLevel { throw FeedFixtureError.unused }
    func followList(_ kind: SocialFollowListKind, userId: String, cursor: String?, limit: Int) async throws -> SocialFollowPage { throw FeedFixtureError.unused }
    func userPosts(userId: String, cursor: String?, mine: Bool) async throws -> SocialFeedPage { throw FeedFixtureError.unused }
    func trendingHashtags() async throws -> [TrendingHashtag] { throw FeedFixtureError.unused }
    func suggestedUsers() async throws -> [SocialFeedAuthor] { throw FeedFixtureError.unused }
    func searchUsers(query: String, limit: Int) async throws -> [SocialUserSearchResult] { throw FeedFixtureError.unused }
    func myLatestSpeedtest() async throws -> SocialShareableSpeedtest? { throw FeedFixtureError.unused }
    func mySpeedtests(limit: Int) async throws -> [SocialShareableSpeedtest] { throw FeedFixtureError.unused }
    func mySpeedtests(page: Int, limit: Int) async throws -> (tests: [SocialShareableSpeedtest], hasMore: Bool) { throw FeedFixtureError.unused }
    func networkPulse(latitude: Double, longitude: Double, radiusMeters: Int?) async throws -> NetworkPulse { throw FeedFixtureError.unused }
    func nearbyRecentSpeedtests(latitude: Double, longitude: Double, radiusMeters: Int, limit: Int) async throws -> [AndroidSpeedtestMarker] { throw FeedFixtureError.unused }
}

private actor FeedFixtureGate<Value: Sendable> {
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    func wait() async throws -> Value {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ value: Result<Value, Error>) {
        result = value; continuation?.resume(with: value); continuation = nil
    }
}

private actor FeedDeletions {
    private(set) var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}

private actor FeedCallCount {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

@MainActor
private final class FeedFixtureStreams {
    private var outputs: [AsyncStream<(event: String, data: String)>.Continuation] = []
    func make() -> AsyncStream<(event: String, data: String)> {
        AsyncStream { outputs.append($0) }
    }
    func emit(_ index: Int, _ data: String) { outputs[index].yield((event: "snapshot", data: data)) }
}

/// IOS-064 : les pastilles d'une photo (commune, prise de vue) restent sur leur ligne quand la
/// largeur de placement est arrondie au pixel ; la seconde passait à la ligne, sous l'image.
final class FlowRowLayoutTests: XCTestCase {
    func testPixelRoundingDoesNotWrapTheLastChip() {
        // « Paris 1er » et « à 2 097,0 km, vers l’ouest » : 246 pt annoncés, 245,67 pt au placement.
        XCTAssertEqual(FlowRow.rows(widths: [70, 170], available: 245.67, spacing: 6), [[0, 1]])
    }

    func testARealLackOfRoomStillWraps() {
        XCTAssertEqual(FlowRow.rows(widths: [70, 170], available: 200, spacing: 6), [[0], [1]])
        XCTAssertEqual(FlowRow.rows(widths: [], available: 200, spacing: 6), [])
        XCTAssertEqual(FlowRow.rows(widths: [300, 20], available: 200, spacing: 6), [[0], [1]],
                       "un élément trop large garde sa propre ligne")
    }
}

/// Profil d'un autre membre, refonte « carte d'identité » du 25/11 : carte d'accueil d'un
/// nouveau membre, ligne d'abonnés, réseau le plus mesuré et anneau de niveau.
extension FeedContextTests {
    private func memberProfile(points: Int? = 0, tests: Int? = 0, followers: Int = 0, following: Int = 0,
                               isSelf: Bool = false, statsHidden: Bool = false,
                               photos: [SocialProfilePhoto] = []) -> SocialUserProfile {
        SocialUserProfile(
            id: "m1", name: "Francois Costes", handle: "costesf", bio: nil, avatarUrl: nil, createdAt: nil,
            isSelf: isSelf, isFriend: false, isFollowing: false, followersCount: followers, followingCount: following,
            canMessage: true,
            stats: SocialUserProfileStats(points: points, gamificationPoints: points, level: 1, validations: 0,
                                          photos: 0, speedtests: tests),
            statsHidden: statsHidden, recentPhotos: photos
        )
    }

    func testNewcomerCardReplacesZerosOnlyForAnotherMemberWithNothingYet() {
        XCTAssertTrue(UserProfileView.isNewcomer(memberProfile(), postCount: 0, isLoadingPosts: false))
        XCTAssertFalse(UserProfileView.isNewcomer(memberProfile(), postCount: 0, isLoadingPosts: true), "pas pendant le chargement")
        XCTAssertFalse(UserProfileView.isNewcomer(memberProfile(), postCount: 1, isLoadingPosts: false), "une publication suffit")
        XCTAssertFalse(UserProfileView.isNewcomer(memberProfile(tests: 3), postCount: 0, isLoadingPosts: false))
        XCTAssertFalse(UserProfileView.isNewcomer(memberProfile(followers: 1), postCount: 0, isLoadingPosts: false))
        XCTAssertFalse(UserProfileView.isNewcomer(memberProfile(isSelf: true), postCount: 0, isLoadingPosts: false), "jamais sur son propre profil")
        XCTAssertFalse(UserProfileView.isNewcomer(memberProfile(statsHidden: true), postCount: 0, isLoadingPosts: false),
                       "chiffres masqués : on ne sait pas, on ne présume rien")
        let photo = SocialProfilePhoto(id: "p1", thumbnailUrl: nil, siteId: nil)
        XCTAssertFalse(UserProfileView.isNewcomer(memberProfile(photos: [photo]), postCount: 0, isLoadingPosts: false))

        XCTAssertFalse(UserProfileView.showsFollowCounters(memberProfile()), "« 0 abonné · 0 abonnement » disparaît")
        XCTAssertTrue(UserProfileView.showsFollowCounters(memberProfile(following: 2)))
        XCTAssertTrue(UserProfileView.showsFollowCounters(memberProfile(isSelf: true)))
    }

    func testMainNetworkLineAndLevelRingReadServedData() throws {
        let networks = SocialProfileNetworks(countryCode: "FR", countryIsDeclared: false, operators: [
            SocialProfileOperatorShare(key: "SFR", count: 48, share: 0.48),
            SocialProfileOperatorShare(key: "ORANGE", count: 52, share: 0.52)
        ], sampleSize: 100)
        let line = try XCTUnwrap(UserProfileView.mainNetworkLine(networks))
        XCTAssertTrue(line.contains("Orange"), line)
        XCTAssertFalse(line.contains("SFR"), line)
        XCTAssertNil(UserProfileView.mainNetworkLine(SocialProfileNetworks(countryCode: nil, countryIsDeclared: false, operators: [], sampleSize: 0)))

        // `levelProgress` est un pourcentage, comme partout côté serveur ; l'anneau le ramène à 0…1.
        let raw = #"{"points":10,"level":2,"missionsLevel":3,"levelProgress":38.7}"#
        let stats = try JSONDecoder.signalQuest.decode(SocialUserProfileStats.self, from: Data(raw.utf8))
        XCTAssertEqual(try XCTUnwrap(stats.levelFraction), 0.387, accuracy: 0.0001)
        let hidden = try JSONDecoder.signalQuest.decode(SocialUserProfileStats.self, from: Data(#"{"levelProgress":null}"#.utf8))
        XCTAssertNil(hidden.levelFraction)
        let over = try JSONDecoder.signalQuest.decode(SocialUserProfileStats.self, from: Data(#"{"levelProgress":140}"#.utf8))
        XCTAssertEqual(over.levelFraction, 1)
    }
}
