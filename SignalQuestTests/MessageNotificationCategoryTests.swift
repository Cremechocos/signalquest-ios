import UserNotifications
import XCTest
@testable import SignalQuest

/// Plan 3, vague 2 : répondre à un message et le marquer comme lu depuis sa
/// notification, jamais de réponse en clair dans une conversation chiffrée.
final class MessageNotificationCategoryTests: XCTestCase {
    func testMessagesGetTheirCategoryAndOtherNotificationsDoNot() {
        XCTAssertEqual(
            MessageNotificationCategory.category(for: ["type": "message_new", "conversationId": "c1"]),
            MessageNotificationCategory.plain
        )
        XCTAssertEqual(
            MessageNotificationCategory.category(for: ["type": "message_new", "isE2EE": "1"]),
            MessageNotificationCategory.encrypted
        )
        XCTAssertEqual(
            MessageNotificationCategory.category(for: ["type": "message_new", "isE2EE": true]),
            MessageNotificationCategory.encrypted
        )
        XCTAssertEqual(
            MessageNotificationCategory.category(for: ["type": "message_mention", "conversationId": "c1", "messageId": "m1"]),
            MessageNotificationCategory.plain
        )
        XCTAssertNil(MessageNotificationCategory.category(for: ["type": "community_outage"]))
    }

    func testCategorizedContentKeepsTheRest() {
        let content = UNMutableNotificationContent()
        content.title = "Équipe terrain"
        content.body = "Léa : on se retrouve samedi ?"
        content.userInfo = ["type": "message_new", "conversationId": "c1"]
        let categorized = MessageNotificationCategory.categorized(content)
        XCTAssertEqual(categorized.categoryIdentifier, MessageNotificationCategory.plain)
        XCTAssertEqual(categorized.body, content.body)
        XCTAssertEqual(categorized.userInfo["conversationId"] as? String, "c1")

        let other = UNMutableNotificationContent()
        other.userInfo = ["type": "social_like"]
        XCTAssertEqual(MessageNotificationCategory.categorized(other).categoryIdentifier, "")
    }

    func testReplyIsOfferedOnlyOutsideEncryptedConversationsAndNeedsUnlocking() throws {
        let categories = MessageNotificationCategory.declared()
        let plain = try XCTUnwrap(categories.first { $0.identifier == MessageNotificationCategory.plain })
        let encrypted = try XCTUnwrap(categories.first { $0.identifier == MessageNotificationCategory.encrypted })

        let reply = try XCTUnwrap(plain.actions.first { $0.identifier == MessageNotificationCategory.replyAction })
        XCTAssertTrue(reply is UNTextInputNotificationAction)
        XCTAssertTrue(reply.options.contains(.authenticationRequired))
        XCTAssertTrue(plain.actions.contains { $0.identifier == MessageNotificationCategory.markReadAction })

        XCTAssertEqual(encrypted.actions.map(\.identifier), [MessageNotificationCategory.markReadAction])
    }

    func testOfflineReplyTargetIsAPlainConversation() {
        let target = MessageConversation.replyTarget(id: "c1")
        XCTAssertEqual(target.id, "c1")
        XCTAssertEqual(target.e2eeEnabled, false)
    }
}
