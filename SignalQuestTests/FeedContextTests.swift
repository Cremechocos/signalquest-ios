import XCTest
import Combine
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
        await model.applyPending()
        XCTAssertEqual(model.page?.items.map(\.id), ["current", "fresh"])
        XCTAssertEqual(model.pendingCount, 0)
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
    func deletePost(postId: String) async throws { throw FeedFixtureError.unused }
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
