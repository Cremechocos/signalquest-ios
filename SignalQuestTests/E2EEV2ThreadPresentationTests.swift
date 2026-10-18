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

    /// P03 : seuls les derniers messages deviennent des bulles ; les plus anciens se présentent à la demande.
    func testOnlyTheLatestMessagesArePresentedWhenAWindowIsGiven() {
        let all = (1...5).map { index in
            stored("ref_window_\(index)_000000000000000000000000000", sequence: Int64(index), sender: bruno.id,
                   text: "Message \(index)", serverTimeMs: 1_790_000_000_000 + Int64(index) * 1_000)
        }
        let result = E2EEV2MessagesV2(snapshot: .init(cursor: 5, messages: all, equivocalRefs: []),
                                      unsupported: [], missingByDevice: [:], waitingForEpoch: false)
        let windowed = E2EEV2ThreadPresenter.present(
            result, conversationId: conversationId, members: [bruno.id: bruno], deviceOwners: [:], limit: 2
        )
        XCTAssertEqual(windowed.messages.map(\.content), ["Message 4", "Message 5"])
        XCTAssertTrue(windowed.hasOlder)
        XCTAssertEqual(windowed.clientRequestIds.count, 5, "Les envois déjà acceptés se reconnaissent même hors fenêtre")

        let full = E2EEV2ThreadPresenter.present(
            result, conversationId: conversationId, members: [bruno.id: bruno], deviceOwners: [:], limit: 10
        )
        XCTAssertEqual(full.messages.count, 5)
        XCTAssertFalse(full.hasOlder)
    }

    /// U05 : l'enveloppe du dernier message reçu sert à accuser « distribué » depuis le fil.
    func testTheLastIncomingEnvelopeIgnoresOwnAndDeletedMessages() {
        let incoming = stored("ref_in_00000000000000000000000000000001", sequence: 1, sender: bruno.id, text: "Salut", serverTimeMs: 1_790_000_000_000)
        let mine = stored("ref_me_00000000000000000000000000000002", sequence: 2, sender: carla.id, text: "Coucou", serverTimeMs: 1_790_000_010_000)
        let deleted = stored("ref_gone_0000000000000000000000000000003", sequence: 3, sender: bruno.id, text: nil,
                             serverTimeMs: 1_790_000_020_000, editedAtMs: 1_790_000_030_000, deleted: true)
        let result = E2EEV2MessagesV2(snapshot: .init(cursor: 3, messages: [incoming, mine, deleted], equivocalRefs: []),
                                      unsupported: [], missingByDevice: [:], waitingForEpoch: false)

        let thread = E2EEV2ThreadPresenter.present(
            result, conversationId: conversationId, members: [:], deviceOwners: [:], ownUserId: carla.id
        )
        XCTAssertEqual(thread.lastIncomingEnvelopeId, incoming.envelopeId)
        XCTAssertNil(E2EEV2ThreadPresenter.present(result, conversationId: conversationId, members: [:], deviceOwners: [:]).lastIncomingEnvelopeId)
    }

    /// AF-MSG-01 : le fil v2 présenté se lit et s'écrit à l'écran. Le
    /// présentateur marque ses bulles `e2eeVersion: 2` avec le texte en clair ;
    /// l'écran les traitait comme du v1 encore chiffré (« Message chiffré »,
    /// envoi bloqué derrière le mot de passe v1).
    func testThePresentedV2ThreadIsShownAndWritable() {
        let first = stored("ref_first_00000000000000000000000000000001", sequence: 1, sender: bruno.id, text: "Salut", serverTimeMs: 1_790_000_000_000)
        let deleted = stored("ref_deleted_000000000000000000000000000003", sequence: 2, sender: bruno.id, text: nil,
                             serverTimeMs: 1_790_000_120_000, editedAtMs: 1_790_000_150_000, deleted: true)
        let thread = E2EEV2ThreadPresenter.present(
            E2EEV2MessagesV2(snapshot: .init(cursor: 2, messages: [first, deleted], equivocalRefs: []),
                             unsupported: [], missingByDevice: [:], waitingForEpoch: false),
            conversationId: conversationId, members: [bruno.id: bruno], deviceOwners: [:]
        )
        XCTAssertEqual(EncryptedConversationSurfaces.displayedText(for: thread.messages[0], usesV2: true, decrypted: [:]), "Salut")
        XCTAssertEqual(EncryptedConversationSurfaces.displayedText(for: thread.messages[1], usesV2: true, decrypted: [:]), "")
        // Hors du chemin v2 (verrous fermés), rien ne s'affiche en clair.
        XCTAssertEqual(EncryptedConversationSurfaces.displayedText(for: thread.messages[0], usesV2: false, decrypted: [:]),
                       String(localized: "🔒 Message chiffré"))
        XCTAssertTrue(EncryptedConversationSurfaces.canSend(isEncrypted: true, usesV2: true, legacyUnlocked: false))
        XCTAssertFalse(EncryptedConversationSurfaces.canSend(isEncrypted: true, usesV2: false, legacyUnlocked: false))
        XCTAssertFalse(EncryptedConversationSurfaces.showsLegacyUnlockBanner(isEncrypted: true, v2Resolved: true, isV2: true, legacyUnlocked: false))
        XCTAssertFalse(EncryptedConversationSurfaces.showsLegacyUnlockBanner(isEncrypted: true, v2Resolved: false, isV2: false, legacyUnlocked: false),
                       "Pas de bandeau v1 tant que la nature de la conversation n'est pas établie")
        XCTAssertTrue(EncryptedConversationSurfaces.showsLegacyUnlockBanner(isEncrypted: true, v2Resolved: true, isV2: false, legacyUnlocked: false))
        // Les routes v1 (fil, rappel, enregistrés, épingles) ne connaissent pas un `messageRef`.
        XCTAssertFalse(EncryptedConversationSurfaces.allowsServerActions(messageId: thread.messages[0].id, isV2: true))
        XCTAssertFalse(EncryptedConversationSurfaces.allowsServerActions(messageId: "local-1234", isV2: false))
        XCTAssertTrue(EncryptedConversationSurfaces.allowsServerActions(messageId: "msg_server_01J7ABCD", isV2: false))
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
