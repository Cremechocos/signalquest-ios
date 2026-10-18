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

    /// Rouvrir le composer avec un brouillon n'écrit rien dans `UserDefaults` :
    /// chaque écriture notifiait SwiftUI, et la vue parente, qui recrée le
    /// composer à chaque rendu, tournait en boucle (l'éditeur ne s'ouvrait plus).
    func testReopeningWithADraftWritesNothing() {
        let draft = ComposerViewModel(service: ComposerFeedFixture())
        draft.text = "Brouillon en cours"
        final class Count: @unchecked Sendable { var value = 0 }
        let writes = Count()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: nil
        ) { _ in writes.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<3 {
            XCTAssertEqual(ComposerViewModel(service: ComposerFeedFixture()).text, "Brouillon en cours")
        }
        XCTAssertEqual(writes.value, 0, "Relire le brouillon ne doit pas le réécrire")
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

    /// Le relevé joint à une story se lit sous `signal` (forme du serveur), sous
    /// `radioSnapshot` ou à plat ; sans opérateur, techno ni RSRP, pas de pastille.
    func testStorySignalPillsReadTheServerShapes() {
        let nested = StorySignalSummary(metadata: [
            "signal": .object(["operator": .string("SFR"), "technology": .string("5g"), "rsrp": .number(-88)])
        ])
        XCTAssertEqual(nested?.pills.first, "SFR · 5G")
        XCTAssertEqual(nested?.pills.count, 2, "La qualité du signal manque")

        let snapshot = StorySignalSummary(metadata: ["radioSnapshot": .object(["networkType": .string("4G")])])
        XCTAssertEqual(snapshot?.pills, ["4G"])

        let flat = StorySignalSummary(metadata: ["operator": .string("Orange")])
        XCTAssertEqual(flat?.pills, ["Orange"])

        XCTAssertNil(StorySignalSummary(metadata: nil))
        XCTAssertNil(StorySignalSummary(metadata: ["signal": .object(["city": .string("Lyon")])]))
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

    // MARK: Listes Abonnés / Abonnements

    /// Champs null et fin de liste : la ligne reste affichable (repli « Membre »).
    func testFollowPageDecodesNullFieldsAndNullCursor() throws {
        let json = #"{"people":[{"id":"u1","name":null,"handle":null,"avatarUrl":null,"following":true,"followsMe":true,"friend":false}],"nextCursor":null,"requestId":"r"}"#
        let page = try JSONDecoder.signalQuest.decode(SocialFollowPage.self, from: Data(json.utf8))
        XCTAssertNil(page.nextCursor)
        let person = try XCTUnwrap(page.people.first)
        XCTAssertNil(person.name)
        XCTAssertNil(person.handle)
        XCTAssertNil(person.avatarUrl)
        XCTAssertTrue(person.following)
        XCTAssertTrue(person.followsMe)
        XCTAssertFalse(person.friend)
        XCTAssertEqual(person.displayName, String(localized: "Membre"))
    }

    /// Une clé absente prend sa valeur par défaut, un élément sans id est écarté :
    /// jamais d'échec de toute la page pour un champ.
    func testFollowPageToleratesMissingKeysAndUnreadableItems() throws {
        let json = #"{"people":[{"id":"u1","handle":"zed"},{"name":"Sans id"},{"id":"u2","following":"oui","friend":true}],"nextCursor":"abc"}"#
        let page = try JSONDecoder.signalQuest.decode(SocialFollowPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.nextCursor, "abc")
        XCTAssertEqual(page.people.map(\.id), ["u1", "u2"])
        XCTAssertEqual(page.people[0].displayName, "@zed")
        XCTAssertFalse(page.people[0].following)
        XCTAssertFalse(page.people[0].followsMe)
        XCTAssertFalse(page.people[0].friend)
        // Un drapeau mal typé retombe sur « faux » sans toucher les autres.
        XCTAssertFalse(page.people[1].following)
        XCTAssertTrue(page.people[1].friend)

        let empty = try JSONDecoder.signalQuest.decode(SocialFollowPage.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.people.isEmpty)
        XCTAssertNil(empty.nextCursor)
    }

    /// `profile.privacy.hideFollowLists` : absent (serveur plus ancien) = listes visibles.
    func testProfileDecodesHideFollowListsAbsentAndPresent() throws {
        func profile(_ extra: String) throws -> SocialUserProfile {
            let json = #"{"id":"u1","name":"Léa","isSelf":false\#(extra)}"#
            return try JSONDecoder.signalQuest.decode(SocialUserProfile.self, from: Data(json.utf8))
        }
        let absent = try profile("")
        XCTAssertNil(absent.privacy)
        XCTAssertFalse(absent.followListsHidden)

        let emptyPrivacy = try profile(#","privacy":{}"#)
        XCTAssertFalse(emptyPrivacy.followListsHidden)

        let hidden = try profile(#","privacy":{"hideFollowLists":true}"#)
        XCTAssertEqual(hidden.privacy?.hideFollowLists, true)
        XCTAssertTrue(hidden.followListsHidden)

        let visible = try profile(#","privacy":{"hideFollowLists":false}"#)
        XCTAssertFalse(visible.followListsHidden)
    }

    func testFollowListShowsHiddenAndPrivateStatesInsteadOfAnError() async {
        let fixture = ComposerFeedFixture()
        let model = FollowListViewModel(
            route: FollowListRoute(userId: "u1", displayName: "Léa", kind: .followers, isSelf: false),
            service: fixture
        )
        fixture.followListError = APIError.http(status: 403, code: "FOLLOW_LISTS_HIDDEN",
                                                message: "Ce membre masque ses listes", requestId: nil, retryAfter: nil)
        await model.load()
        XCTAssertEqual(model.current.restriction, .listsHidden)
        XCTAssertNil(model.current.errorMessage)

        fixture.followListError = APIError.http(status: 403, code: "PROFILE_PRIVATE",
                                                message: "Profil privé", requestId: nil, retryAfter: nil)
        await model.load()
        XCTAssertEqual(model.current.restriction, .profilePrivate)

        // 404 sans code (route pas encore en production) : erreur propre, avec « Réessayer ».
        fixture.followListError = APIError.http(status: 404, code: nil, message: "", requestId: nil, retryAfter: nil)
        await model.load()
        XCTAssertNil(model.current.restriction)
        XCTAssertNotNil(model.current.errorMessage)
        XCTAssertFalse(model.current.hasLoaded)
    }

    func testFollowListPaginatesWithOpaqueCursorAndSkipsDuplicates() async {
        let fixture = ComposerFeedFixture()
        fixture.followPages = [
            SocialFollowPage(people: [
                SocialFollowPerson(id: "a", name: "A", handle: nil, avatarUrl: nil),
                SocialFollowPerson(id: "b", name: "B", handle: nil, avatarUrl: nil)
            ], nextCursor: "page-2"),
            SocialFollowPage(people: [
                SocialFollowPerson(id: "b", name: "B", handle: nil, avatarUrl: nil),
                SocialFollowPerson(id: "c", name: "C", handle: nil, avatarUrl: nil)
            ], nextCursor: nil)
        ]
        let model = FollowListViewModel(
            route: FollowListRoute(userId: "u1", displayName: "Léa", kind: .following, isSelf: true),
            service: fixture
        )
        await model.load()
        XCTAssertEqual(model.current.people.map(\.id), ["a", "b"])
        XCTAssertEqual(model.current.nextCursor, "page-2")

        await model.loadMore()
        XCTAssertEqual(model.current.people.map(\.id), ["a", "b", "c"])
        XCTAssertNil(model.current.nextCursor)
        XCTAssertEqual(fixture.followListCursors, [nil, "page-2"])

        // Fin de liste : plus aucun appel.
        await model.loadMore()
        XCTAssertEqual(fixture.followListCursors.count, 2)
    }

    func testFollowListKeepsLoadedRowsWhenNextPageFails() async {
        let fixture = ComposerFeedFixture()
        fixture.followPages = [
            SocialFollowPage(people: [SocialFollowPerson(id: "a", name: "A", handle: nil, avatarUrl: nil)], nextCursor: "page-2")
        ]
        let model = FollowListViewModel(
            route: FollowListRoute(userId: "u1", displayName: "Léa", kind: .followers, isSelf: false),
            service: fixture
        )
        await model.load()
        fixture.followListError = APIError.transport("offline")
        await model.loadMore()
        XCTAssertEqual(model.current.people.map(\.id), ["a"])
        XCTAssertTrue(model.current.loadMoreFailed)
        XCTAssertEqual(model.current.nextCursor, "page-2")
        XCTAssertNil(model.current.errorMessage)
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
    /// Pages servies dans l'ordre ; une erreur prend le pas quand elle est posée.
    var followPages: [SocialFollowPage] = []
    var followListError: Error?
    var followListCursors: [String?] = []
    func followList(_ kind: SocialFollowListKind, userId: String, cursor: String?, limit: Int) async throws -> SocialFollowPage {
        followListCursors.append(cursor)
        if let followListError { throw followListError }
        guard !followPages.isEmpty else { throw ComposerFixtureError.unused }
        return followPages.removeFirst()
    }
    func userPosts(userId: String, cursor: String?, mine: Bool) async throws -> SocialFeedPage { throw ComposerFixtureError.unused }
    func trendingHashtags() async throws -> [TrendingHashtag] { throw ComposerFixtureError.unused }
    func suggestedUsers() async throws -> [SocialFeedAuthor] { throw ComposerFixtureError.unused }
    func searchUsers(query: String, limit: Int) async throws -> [SocialUserSearchResult] { throw ComposerFixtureError.unused }
    func myLatestSpeedtest() async throws -> SocialShareableSpeedtest? { throw ComposerFixtureError.unused }
    func mySpeedtests(limit: Int) async throws -> [SocialShareableSpeedtest] { throw ComposerFixtureError.unused }
    func networkPulse(latitude: Double, longitude: Double, radiusMeters: Int?) async throws -> NetworkPulse { throw ComposerFixtureError.unused }
    func nearbyRecentSpeedtests(latitude: Double, longitude: Double, radiusMeters: Int, limit: Int) async throws -> [AndroidSpeedtestMarker] { throw ComposerFixtureError.unused }
}
