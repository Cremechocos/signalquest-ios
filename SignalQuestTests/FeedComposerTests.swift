import UIKit
import XCTest
@testable import SignalQuest

/// Composer du fil (Lot 4f, SOC-18).
@MainActor
final class FeedComposerTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ComposerSheet.draftText.\(LocalAccountScope.storageNamespace)")
        UserDefaults.standard.removeObject(forKey: "ComposerSheet.draftVisibility.\(LocalAccountScope.storageNamespace)")
        super.tearDown()
    }

    /// Un sondage seul se publie : le bouton restait désactivé.
    func testPollAloneCanBePublished() {
        let model = ComposerViewModel(service: ComposerFeedFixture())
        model.text = ""
        XCTAssertFalse(model.canPublish)
        model.pollEnabled = true
        model.pollQuestion = "Meilleur réseau à Lyon ?"
        model.pollOptions[0].text = "Orange"
        model.pollOptions[1].text = "SFR"
        XCTAssertTrue(model.canPublish)
        XCTAssertEqual(model.fallbackBody, "Meilleur réseau à Lyon ?")
    }

    /// Une photo retirée ne part plus avec la publication ; une photo floutée
    /// remplace l'originale (plan 3, vague 1).
    func testRemovedPhotoIsNotPublishedAndBlurredPhotoReplacesIt() throws {
        let model = ComposerViewModel(service: ComposerFeedFixture())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        model.applyBlurredImage(photo)
        XCTAssertEqual(model.imageDataForUpload, photo.jpegData(compressionQuality: 0.92))
        XCTAssertTrue(model.previewImage === photo)
        model.removeImage()
        XCTAssertNil(model.imageDataForUpload, "La photo retirée partait encore avec la publication")
        XCTAssertNil(model.previewImage)
    }

    /// Modifier un post ne remplace pas le brouillon en cours de rédaction.
    func testEditingAPostKeepsTheDraft() throws {
        let draft = ComposerViewModel(service: ComposerFeedFixture())
        draft.text = "Brouillon en cours"
        let editor = ComposerViewModel(service: ComposerFeedFixture())
        let post = try XCTUnwrap(Self.post(text: "Texte publié"))
        editor.beginEditing(post)
        editor.text = "Texte publié, corrigé"
        let reopened = ComposerViewModel(service: ComposerFeedFixture())
        XCTAssertEqual(reopened.text, "Brouillon en cours")
    }

    /// Légende de story : coupée au plafond du serveur, compté en unités UTF-16
    /// comme en JavaScript, sans casser un emoji (SOC-34).
    func testStoryCaptionIsCappedLikeTheServerCountsIt() {
        let limit = StoryComposerViewModel.maxTextLength
        XCTAssertEqual(StoryComposerViewModel.clampedCaption("Salut"), "Salut")
        let long = String(repeating: "a", count: limit + 10)
        XCTAssertEqual(StoryComposerViewModel.clampedCaption(long).utf16.count, limit)
        // « 👍🏽 » : un caractère, quatre unités UTF-16.
        let emojis = String(repeating: "👍🏽", count: 400)
        let clamped = StoryComposerViewModel.clampedCaption(emojis)
        XCTAssertEqual(clamped.count, limit / 4)
        XCTAssertEqual(clamped.utf16.count, limit)
    }

    /// Les codes d'erreur des stories ont des mots, et un refus Premium venu
    /// d'une autre fonction ne parle plus du journal radio.
    func testStoryErrorCodesGetPlainWords() {
        for code in ["EMPTY_STORY", "INVALID_STORY_EXPIRATION", "INVALID_STORY"] {
            let shown = APIError.userFacingMessage(status: 400, code: code, serverMessage: code)
            XCTAssertFalse(shown.contains("_"), "\(code) s'affiche brut : « \(shown) »")
            XCTAssertNotEqual(shown, APIError.statusFallback(400), "\(code) retombe sur le repli générique")
        }
        let premium = APIError.userFacingMessage(status: 403, code: "PREMIUM_REQUIRED", serverMessage: "")
        XCTAssertFalse(premium.contains("journal radio"))
    }

    /// Profil réglé sur « personne » : état « Profil privé », sans erreur ni
    /// « Réessayer » (403 PROFILE_PRIVATE, en prod depuis le 30/09).
    func testPrivateProfileShowsACalmStateInsteadOfAnError() async {
        let fixture = ComposerFeedFixture()
        fixture.userProfileError = APIError.http(status: 403, code: "PROFILE_PRIVATE",
                                                 message: "Profil privé", requestId: nil, retryAfter: nil)
        let model = UserProfileViewModel(userId: "u-private", prefill: nil, service: fixture)
        await model.load()
        XCTAssertTrue(model.isPrivate)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.items.isEmpty)
    }

    private static func post(text: String) -> UnifiedSocialFeedItem? {
        let json = #"{"id":"post-1","kind":"post","author":{"id":"me","name":"Moi"},"text":"\#(text)"}"#
        return try? JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: Data(json.utf8))
    }
}

private enum ComposerFixtureError: Error { case unused }
private final class ComposerFeedFixture: SocialFeedServicing, @unchecked Sendable {
    let handler: @Sendable (String?, String?, FeedTab?) async throws -> SocialFeedPage
    init() { self.handler = { _, _, _ in throw ComposerFixtureError.unused } }
    func loadFeed(cursor: String?, hashtag: String?, tab: FeedTab?) async throws -> SocialFeedPage { try await handler(cursor, hashtag, tab) }
    func post(id: String) async throws -> UnifiedSocialFeedItem? { throw ComposerFixtureError.unused }
    func createPost(
        text: String,
        visibility: String,
        attachments: [CreatePostAttachment],
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?,
        poll: CreatePostPoll?
    ) async throws -> UnifiedSocialFeedItem? { throw ComposerFixtureError.unused }
    func uploadImage(data: Data, mimeType: String) async throws -> CreatePostAttachment { throw ComposerFixtureError.unused }
    func publishPost(
        text: String,
        visibility: String,
        imageData: Data?,
        imageMimeType: String,
        targetType: String?,
        targetId: String?,
        extraMetadata: [String: JSONValue]?,
        poll: CreatePostPoll?
    ) async throws -> UnifiedSocialFeedItem? { throw ComposerFixtureError.unused }
    func retryPendingPosts() async {  }
    func react(postId: String, emoji: String) async throws -> ReactionResponse { throw ComposerFixtureError.unused }
    func favorite(postId: String) async throws -> ReactionResponse { throw ComposerFixtureError.unused }
    func repost(postId: String) async throws -> ReactionResponse { throw ComposerFixtureError.unused }
    func muteNotifications(postId: String) async throws -> SuccessResponse { throw ComposerFixtureError.unused }
    func editPost(postId: String, text: String, visibility: String?) async throws -> UnifiedSocialFeedItem? { throw ComposerFixtureError.unused }
    func deletePost(postId: String) async throws { throw ComposerFixtureError.unused }
    func setPinned(postId: String, pinned: Bool) async throws { throw ComposerFixtureError.unused }
    func votePoll(postId: String, optionId: String?, removing: Bool) async throws -> FeedPoll? { throw ComposerFixtureError.unused }
    func followedHashtags() async throws -> [FollowedHashtag] { throw ComposerFixtureError.unused }
    func setHashtagFollowed(_ tag: String, following: Bool) async throws { throw ComposerFixtureError.unused }
    func mutes() async throws -> SocialMutes { throw ComposerFixtureError.unused }
    func setHashtagMuted(_ tag: String, muted: Bool) async throws { throw ComposerFixtureError.unused }
    func setWordMuted(_ pattern: String, muted: Bool) async throws { throw ComposerFixtureError.unused }
    func explore(query: String?) async throws -> SocialExploreResult { throw ComposerFixtureError.unused }
    func weeklyRecap() async throws -> WeeklyRecapStats? { throw ComposerFixtureError.unused }
    func publishWeeklyRecap() async throws -> WeeklyRecapPublishResponse { throw ComposerFixtureError.unused }
    func share(postId: String, conversationId: String) async throws -> String? { throw ComposerFixtureError.unused }
    var userProfileError: Error = ComposerFixtureError.unused
    func userProfile(userId: String) async throws -> SocialUserProfile { throw userProfileError }
    func toggleFollow(userId: String) async throws -> SocialFollowResult { throw ComposerFixtureError.unused }
    func userPosts(userId: String, cursor: String?, mine: Bool) async throws -> SocialFeedPage { throw ComposerFixtureError.unused }
    func trendingHashtags() async throws -> [TrendingHashtag] { throw ComposerFixtureError.unused }
    func suggestedUsers() async throws -> [SocialFeedAuthor] { throw ComposerFixtureError.unused }
    func searchUsers(query: String, limit: Int) async throws -> [SocialUserSearchResult] { throw ComposerFixtureError.unused }
    func myLatestSpeedtest() async throws -> SocialShareableSpeedtest? { throw ComposerFixtureError.unused }
    func mySpeedtests(limit: Int) async throws -> [SocialShareableSpeedtest] { throw ComposerFixtureError.unused }
    func networkPulse(latitude: Double, longitude: Double, radiusMeters: Int?) async throws -> NetworkPulse { throw ComposerFixtureError.unused }
    func nearbyRecentSpeedtests(latitude: Double, longitude: Double, radiusMeters: Int, limit: Int) async throws -> [AndroidSpeedtestMarker] { throw ComposerFixtureError.unused }
}
