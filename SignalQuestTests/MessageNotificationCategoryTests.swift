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

    func testEncryptedMessagesNeverShowTheServerText() {
        let content = UNMutableNotificationContent()
        content.title = "Équipe secrète 🎉"
        content.subtitle = "Léa"
        content.body = "Léa : le code de la porte est 4521 😀"
        content.threadIdentifier = "c1"
        content.userInfo = ["type": "message_new", "conversationId": "c1", "isE2EE": "1"]
        let categorized = MessageNotificationCategory.categorized(content)
        XCTAssertEqual(categorized.categoryIdentifier, MessageNotificationCategory.encrypted)
        XCTAssertEqual(categorized.title, "SignalQuest", "Ni titre de conversation ni emoji")
        XCTAssertEqual(categorized.subtitle, "", "Ni nom")
        XCTAssertEqual(categorized.body, String(localized: "Nouveau message chiffré"))
        for leaked in ["Équipe", "Léa", "4521", "🎉", "😀"] {
            XCTAssertFalse([categorized.title, categorized.subtitle, categorized.body].joined().contains(leaked), leaked)
        }
        XCTAssertEqual(categorized.userInfo["conversationId"] as? String, "c1", "Ouvre toujours la bonne conversation")
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

    /// U04 : une réponse refusée par le serveur prévient, et le toucher mène au fil.
    func testFailedReplyNoticeNamesTheConversationAndOpensIt() throws {
        let owner = PushOwnerScope.id(for: "account-a")
        let named = try XCTUnwrap(PushNotificationService.replyFailureContent(
            conversationId: "conv-1", conversationTitle: "Camille", ownerScopeId: owner
        ))
        XCTAssertEqual(named.userInfo["type"] as? String, "message_new")
        XCTAssertEqual(named.userInfo["conversationId"] as? String, "conv-1")
        XCTAssertTrue(named.body.contains("Camille"))

        let anonymous = try XCTUnwrap(PushNotificationService.replyFailureContent(
            conversationId: "conv-1", conversationTitle: "  ", ownerScopeId: owner
        ))
        XCTAssertFalse(anonymous.body.isEmpty)
        XCTAssertNotEqual(anonymous.body, named.body)
        XCTAssertEqual(anonymous.userInfo["conversationId"] as? String, "conv-1")
    }

    /// Le rappel passe par la même politique que les pushs : il porte le compte courant,
    /// sinon le délégué l'écarterait au tap. Sans compte actif, rien n'est posté.
    func testFailedReplyNoticeIsAcceptedByTheRecipientPolicyOfItsAccountOnly() throws {
        let owner = PushOwnerScope.id(for: "account-a")
        let content = try XCTUnwrap(PushNotificationService.replyFailureContent(
            conversationId: "conv-1", conversationTitle: nil, ownerScopeId: owner
        ))
        XCTAssertEqual(PushRecipientPolicy.evaluate(content.userInfo, currentOwnerScopeId: owner), .acceptTargeted)
        XCTAssertEqual(
            PushRecipientPolicy.evaluate(content.userInfo, currentOwnerScopeId: PushOwnerScope.id(for: "account-b")),
            .rejectWrongAccount
        )
        XCTAssertNil(PushNotificationService.replyFailureContent(
            conversationId: "conv-1", conversationTitle: nil, ownerScopeId: nil
        ))
    }

    func testOfflineReplyTargetIsAPlainConversation() {
        let target = MessageConversation.replyTarget(id: "c1")
        XCTAssertEqual(target.id, "c1")
        XCTAssertEqual(target.e2eeEnabled, false)
    }
}
