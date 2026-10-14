import Foundation
import XCTest
@testable import SignalQuest

@MainActor
final class PostDetailActionsTests: XCTestCase {
    private func item() throws -> UnifiedSocialFeedItem {
        let data = Data(#"{"id":"post-1","kind":"post","author":{"id":"author","name":"Camille"},"text":"Signal"}"#.utf8)
        return try JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: data)
    }

    /// La feuille de détail montre chaque image jointe, en pleine résolution
    /// d'abord, avec son texte alternatif ; une vidéo n'y entre pas.
    func testDetailSheetShowsEveryImageAttachment() throws {
        let json = #"""
        {"id":"post-2","kind":"post","author":{"id":"author","name":"Camille"},"text":"Pylône",
         "attachments":[
           {"id":"a1","kind":"image","url":"https://cdn.example/full.jpg","thumbnailUrl":"https://cdn.example/thumb.jpg","altText":"Pylône au coucher du soleil"},
           {"id":"a2","kind":"image","thumbnailUrl":"https://cdn.example/only-thumb.jpg"},
           {"id":"a3","kind":"video","url":"https://cdn.example/clip.mp4"}
         ]}
        """#
        let post = try JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: Data(json.utf8))
        let images = SignalDetailSheet.images(of: post)
        XCTAssertEqual(images.map { $0.id }, ["a1", "a2"])
        XCTAssertEqual(images.first?.url.absoluteString, "https://cdn.example/full.jpg")
        XCTAssertEqual(images.first?.label, "Pylône au coucher du soleil")
        XCTAssertEqual(images.last?.url.absoluteString, "https://cdn.example/only-thumb.jpg")
        XCTAssertTrue(SignalDetailSheet.images(of: try item()).isEmpty)
    }

    func testServerReactionReceiptUpdatesAllVisibleCounters() throws {
        let json = #"{"reactions":[{"emoji":"❤️","count":2,"reactedByMe":true}],"favorited":true,"favoritesCount":3,"reposted":true,"repostsCount":4}"#
        let response = try JSONDecoder().decode(ReactionResponse.self, from: Data(json.utf8))

        let updated = try item().applying(response)
        XCTAssertTrue(updated.likedByMe)
        XCTAssertEqual(updated.reactions.first?.count, 2)
        XCTAssertTrue(updated.favoritedByMe)
        XCTAssertEqual(updated.favoritesCount, 3)
        XCTAssertTrue(updated.repostedByMe)
        XCTAssertEqual(updated.repostsCount, 4)
    }

    func testPartialReceiptPreservesUnrelatedState() throws {
        let original = try item()
        let response = try JSONDecoder().decode(ReactionResponse.self, from: Data(#"{"favorited":true,"favoritesCount":1}"#.utf8))

        let updated = original.applying(response)
        XCTAssertEqual(updated.reactions, original.reactions)
        XCTAssertEqual(updated.likedByMe, original.likedByMe)
        XCTAssertEqual(updated.repostedByMe, original.repostedByMe)
        XCTAssertTrue(updated.favoritedByMe)
        XCTAssertEqual(updated.favoritesCount, 1)
    }

    func testReturningToFeedPreservesNewerCommentsWhileCopyingConfirmedInteractions() throws {
        var feedItem = try item()
        feedItem.commentsCount = 9
        let detailItem = try item().applying(response(
            #"{"reactions":[{"emoji":"❤️","count":5,"reactedByMe":true}],"reposted":true,"repostsCount":2}"#
        ))

        let merged = feedItem.adoptingInteractions(from: detailItem)
        XCTAssertEqual(merged.commentsCount, 9)
        XCTAssertEqual(merged.reactions.first?.count, 5)
        XCTAssertTrue(merged.likedByMe)
        XCTAssertEqual(merged.repostsCount, 2)
    }

    func testEachMutationUsesServerReceiptAndFailureKeepsPreviousCounters() async throws {
        let original = try item()
        let reactions = try response(#"{"reactions":[{"emoji":"❤️","count":7,"reactedByMe":true}]}"#)
        let repost = try response(#"{"reposted":true,"repostsCount":4}"#)
        let favorite = try response(#"{"favorited":true,"favoritesCount":3}"#)
        let sequence = ReactionSequence(success: reactions)
        var delivered: [UnifiedSocialFeedItem] = []
        let actions = PostDetailActions(
            item: original,
            react: { _ in try sequence.next() },
            repost: { _ in repost },
            favorite: { _ in favorite },
            share: { _, _ in nil },
            onItemChanged: { delivered.append($0) }
        )

        await actions.mutate(.react)
        XCTAssertEqual(actions.item, original)
        XCTAssertNotNil(actions.errorMessage)
        XCTAssertFalse(actions.isMutating)
        XCTAssertTrue(delivered.isEmpty)

        await actions.mutate(.react)
        XCTAssertNil(actions.errorMessage)
        XCTAssertTrue(actions.item.likedByMe)
        XCTAssertEqual(actions.item.reactions.first?.count, 7)
        await actions.mutate(.repost)
        XCTAssertTrue(actions.item.repostedByMe)
        XCTAssertEqual(actions.item.repostsCount, 4)
        await actions.mutate(.favorite)
        XCTAssertTrue(actions.item.favoritedByMe)
        XCTAssertEqual(actions.item.favoritesCount, 3)
        XCTAssertEqual(sequence.callCount, 2)
        XCTAssertEqual(delivered.map(\.id), [original.id, original.id, original.id])
        XCTAssertEqual(delivered.last?.favoritesCount, 3)
    }

    func testShareReturnsOnlyConfirmedMessageID() async throws {
        let original = try item()
        let actions = PostDetailActions(
            item: original,
            react: { _ in throw TestError.failed },
            repost: { _ in throw TestError.failed },
            favorite: { _ in throw TestError.failed },
            share: { postID, conversationID in
                XCTAssertEqual(postID, original.id)
                switch conversationID {
                case "success": return "message-42"
                case "empty": return ""
                default: throw TestError.failed
                }
            }
        )
        let sent = await actions.share(to: "success")
        let empty = await actions.share(to: "empty")
        let failed = await actions.share(to: "failure")
        XCTAssertEqual(sent, "message-42")
        XCTAssertNil(empty)
        XCTAssertNil(failed)
    }

    private func response(_ json: String) throws -> ReactionResponse {
        try JSONDecoder().decode(ReactionResponse.self, from: Data(json.utf8))
    }
}

private enum TestError: Error { case failed }

@MainActor
private final class ReactionSequence {
    private(set) var callCount = 0
    let success: ReactionResponse
    init(success: ReactionResponse) { self.success = success }
    func next() throws -> ReactionResponse {
        callCount += 1
        if callCount == 1 { throw TestError.failed }
        return success
    }
}

@MainActor
final class PostDeepLinkTests: XCTestCase {
    func testPostLinksAndUntrustedOrigins() {
        let origin = URL(string: "https://signalquest.fr")!
        func parse(_ raw: String, scheme: String = "signalquest") -> String? {
            PostDeepLink.postID(from: URL(string: raw)!, appOrigin: origin, appScheme: scheme)
        }
        XCTAssertEqual(parse("https://signalquest.fr/posts/post-42"), "post-42")
        XCTAssertEqual(parse("signalquest://post/post-42"), "post-42")
        XCTAssertEqual(parse("signalquest-beta://post/post_42", scheme: "signalquest-beta"), "post_42")
        XCTAssertNil(parse("https://other.example/posts/post-42"))
        XCTAssertNil(parse("https://signalquest.fr/posts/post-42/extra"))
        XCTAssertNil(parse("https://signalquest.fr/posts/%2E%2E"))
        XCTAssertNil(parse("signalquest://messages/post-42"))
    }

    func testNotificationPostIntentSurvivesUntilFeedConsumesIt() {
        let router = AppRouter()
        router.handle(type: "reaction", conversationId: nil, postId: "post-42")
        XCTAssertEqual(router.selectedTab, .community)
        XCTAssertEqual(router.openPostId, "post-42")
        XCTAssertTrue(router.hasPendingContentRoute)
    }
}

extension PostDetailActionsTests {
    /// Une réaction 🔥 ne dit rien du ❤️ : l'état se lit emoji par emoji.
    func testReactionStateIsReadPerEmoji() throws {
        let data = Data(#"{"id":"post-1","kind":"post","author":{"id":"author","name":"Camille"},"text":"Signal","reactions":[{"emoji":"🔥","count":2,"reactedByMe":true},{"emoji":"❤️","count":1,"reactedByMe":false}]}"#.utf8)
        let reacted = try JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: data)
        XCTAssertTrue(reacted.hasReacted(with: "🔥"))
        XCTAssertFalse(reacted.hasReacted(with: "❤️"))
        XCTAssertFalse(reacted.hasReacted(with: "👏"))
    }

    /// Sans ligne ❤️ dans les réactions, `likedByMe` fait foi pour le ❤️ seulement.
    func testHeartFallsBackOnLikedByMe() throws {
        var liked = try item()
        liked.likedByMe = true
        XCTAssertTrue(liked.hasReacted(with: "❤️"))
        XCTAssertFalse(liked.hasReacted(with: "🔥"))
    }
}
