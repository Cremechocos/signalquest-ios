import XCTest
@testable import SignalQuest

/// Lot 5 (plan 3) : ce que le fil montre d'une conversation v2 (§4.2, §4.3, §5).
final class E2EEV2ThreadPresentationTests: XCTestCase {
    private let conversationId = "conv_presentation_01J7ABCD"
    private let bruno = MessageUser(id: "user_bruno_01J7ABCD23456789", name: "Bruno", email: "bruno@example.test", avatarUrl: nil)
    private let carla = MessageUser(id: "user_carla_01J7ABCD23456789", name: "Carla", email: "carla@example.test", avatarUrl: nil)

    private func stored(
        _ ref: String, sequence: Int64, sender: String, text: String?, serverTimeMs: Int64,
        editedAtMs: Int64? = nil, deleted: Bool = false, replyTo: String? = nil, expiresAtMs: Int64? = nil
    ) -> E2EEV2MessageStoreV2.Stored {
        E2EEV2MessageStoreV2.Stored(
            messageRef: ref, envelopeId: "envelope_\(sequence)_0000000000", sequence: sequence, senderUserId: sender,
            senderDeviceId: "device_\(sender)", clientRequestId: "message_\(sequence)_0000000000", epochNumber: 1,
            serverTimeMs: serverTimeMs, serverTagB64: "", keyId: "server_tag_key_01J7ABCD",
            frankTagB64: "", kind: "TEXT", targetRef: nil, replyToRef: replyTo, sentAtMs: serverTimeMs - 500,
            expiresAtMs: expiresAtMs, payloadB64: nil, fkB64: nil, text: text, editedAtMs: editedAtMs, deleted: deleted
        )
    }

    func testStoredMessagesBecomeThreadItems() {
        let first = stored("ref_first_00000000000000000000000000000001", sequence: 1, sender: bruno.id, text: "Salut", serverTimeMs: 1_790_000_000_000)
        let edited = stored("ref_edited_0000000000000000000000000000002", sequence: 2, sender: carla.id, text: "Texte corrigé",
                            serverTimeMs: 1_790_000_060_000, editedAtMs: 1_790_000_090_000, replyTo: first.messageRef)
        let deleted = stored("ref_deleted_000000000000000000000000000003", sequence: 3, sender: bruno.id, text: nil,
                             serverTimeMs: 1_790_000_120_000, editedAtMs: 1_790_000_150_000, deleted: true)
        let ephemeral = stored("ref_ephemeral_0000000000000000000000000004", sequence: 4, sender: carla.id, text: "Bientôt parti",
                               serverTimeMs: 1_790_000_180_000, expiresAtMs: 1_790_086_580_000)
        let result = E2EEV2MessagesV2(
            snapshot: .init(cursor: 4, messages: [first, edited, deleted, ephemeral], equivocalRefs: []),
            unsupported: [], missingByDevice: [:], waitingForEpoch: false
        )
        let thread = E2EEV2ThreadPresenter.present(
            result, conversationId: conversationId, members: [bruno.id: bruno, carla.id: carla], deviceOwners: [:]
        )
        XCTAssertEqual(thread.messages.map(\.id), [first.messageRef, edited.messageRef, deleted.messageRef, ephemeral.messageRef])
        XCTAssertEqual(thread.messages[0].content, "Salut")
        XCTAssertEqual(thread.messages[0].sender?.displayName, "Bruno")
        XCTAssertTrue(thread.messages[0].isEncrypted)
        XCTAssertEqual(thread.messages[0].createdAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(thread.messages[1].content, "Texte corrigé")
        XCTAssertEqual(thread.messages[1].editedAt, Date(timeIntervalSince1970: 1_790_000_090))
        XCTAssertEqual(thread.messages[1].replyToId, first.messageRef, "Une réponse vise l'identité du message (§4.2)")
        XCTAssertNil(thread.messages[2].content, "Supprimé : plus de texte")
        XCTAssertNotNil(thread.messages[2].deletedAt)
        XCTAssertNil(thread.messages[2].editedAt)
        XCTAssertEqual(thread.messages[3].expiresAt, Date(timeIntervalSince1970: 1_790_086_580))
        XCTAssertTrue(thread.notices.isEmpty)
    }

    func testNoticesSayWhatIsMissingWithoutShowingIt() {
        let result = E2EEV2MessagesV2(
            snapshot: .init(cursor: 9, messages: [], equivocalRefs: ["ref_a", "ref_b"]),
            unsupported: ["ref_c"],
            missingByDevice: ["device_bruno_phone": 2, "device_bruno_tablet": 1, "device_unknown": 4],
            waitingForEpoch: true
        )
        let thread = E2EEV2ThreadPresenter.present(
            result, conversationId: conversationId, members: [bruno.id: bruno],
            deviceOwners: ["device_bruno_phone": bruno.id, "device_bruno_tablet": bruno.id]
        )
        XCTAssertEqual(thread.notices, [
            .waitingForEpoch,
            .equivocation(count: 2),
            .missing(senderName: nil, count: 4),
            .missing(senderName: "Bruno", count: 3),
            .unsupported(count: 1),
        ])
        XCTAssertTrue(thread.notices[3].text.contains("Bruno"))
    }

    func testAMemberWhoseIdentityIsNotTrustedComesFirst() {
        let result = E2EEV2MessagesV2(
            snapshot: .init(cursor: 1, messages: [], equivocalRefs: []), unsupported: [], missingByDevice: [:], waitingForEpoch: true
        )
        let thread = E2EEV2ThreadPresenter.present(
            result, conversationId: conversationId, members: [bruno.id: bruno], deviceOwners: [:],
            refusals: [carla.id: .deviceListRollback, bruno.id: .uikChanged]
        )
        XCTAssertEqual(thread.notices, [
            .identityChanged(userId: bruno.id, name: "Bruno"),
            .identityUnverified(userId: carla.id, name: nil),
            .waitingForEpoch,
        ], "L'envoi les attend : ils passent en tête")
        XCTAssertTrue(thread.notices[0].text.contains("Bruno"))
    }
}
