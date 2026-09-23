import Foundation
import XCTest
@testable import SignalQuest

final class PostDetailActionsTests: XCTestCase {
    private func item() throws -> UnifiedSocialFeedItem {
        let data = Data(#"{"id":"post-1","kind":"post","author":{"id":"author","name":"Camille"},"text":"Signal"}"#.utf8)
        return try JSONDecoder.signalQuest.decode(UnifiedSocialFeedItem.self, from: data)
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
}
