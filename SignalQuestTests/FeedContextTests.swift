import XCTest
import Combine
@testable import SignalQuest

@MainActor
final class FeedContextTests: XCTestCase {
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
        await model.select(.latest)
        await gate.finish(.success(Self.page("old")))
        await old.value
        XCTAssertEqual(model.page?.requestId, "new")
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
        let second = Task { await model.select(.latest) }
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
            return Self.page(tab == .forYou ? "first" : "current", cursor: tab == .forYou ? "next" : nil)
        })
        await model.load()
        let old = Task { await model.loadMore() }
        await fulfillment(of: [started], timeout: 2)
        await model.select(.latest)
        await gate.finish(.success(Self.page("old-page"))); await old.value
        XCTAssertEqual(model.page?.requestId, "current"); XCTAssertNil(model.page?.nextCursor)
        XCTAssertFalse(model.isLoadingMore)
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
            XCTAssertEqual(tag, "beta"); XCTAssertEqual(tab, .latest)
            let count = await calls.next()
            return Self.page("filtered", items: count == 1 ? [current] : [current, fresh])
        })
        model.selectedHashtag = "beta"
        await model.select(.latest)
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

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
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
    func userPosts(userId: String, cursor: String?, mine: Bool) async throws -> SocialFeedPage { throw FeedFixtureError.unused }
    func trendingHashtags() async throws -> [TrendingHashtag] { throw FeedFixtureError.unused }
    func suggestedUsers() async throws -> [SocialFeedAuthor] { throw FeedFixtureError.unused }
    func searchUsers(query: String, limit: Int) async throws -> [SocialUserSearchResult] { throw FeedFixtureError.unused }
    func myLatestSpeedtest() async throws -> SocialShareableSpeedtest? { throw FeedFixtureError.unused }
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
