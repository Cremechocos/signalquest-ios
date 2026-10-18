import XCTest
@testable import SignalQuest

/// Spec E2EE §13 : surfaces fermées par défaut d'une conversation chiffrée.
final class EncryptedConversationSurfacesTests: XCTestCase {
    private let namespace = "user_surfaces_01J7ABCD23456789"

    func testOnlyAnEncryptedConversationWithAVerifiedGenesisIsV2() throws {
        let vault = InMemoryTokenStore()
        let states = E2EEV2ConversationStateStore(tokenStore: vault, allowsOwner: { _ in true })
        let encrypted = conversation("conversation_surfaces_01J7AB", encrypted: true)
        XCTAssertFalse(EncryptedConversationSurfaces.isV2(conversation("conversation_plain_0001J7AB", encrypted: false), ownerNamespace: namespace, stateStore: states))
        XCTAssertFalse(EncryptedConversationSurfaces.isV2(encrypted, ownerNamespace: namespace, stateStore: states), "Chiffrée v1, sans genèse")
        try states.record(.init(
            conversationId: encrypted.id, creatorUserId: "user_creator_01J7ABCD2345", creatorDeviceId: "device_creator_01J7ABCD",
            manifestDigest: "digest", membershipChangeNumber: 2, membershipDigest: "membership", recordedAtMs: 1
        ), ownerNamespace: namespace)
        XCTAssertTrue(EncryptedConversationSurfaces.isV2(encrypted, ownerNamespace: namespace, stateStore: states))
        // Un trousseau illisible vaut v2 : aucune surface ne se rouvre.
        let broken = E2EEV2ConversationStateStore(tokenStore: FailingTokenStore(), allowsOwner: { _ in true })
        XCTAssertTrue(EncryptedConversationSurfaces.isV2(encrypted, ownerNamespace: namespace, stateStore: broken))
        XCTAssertFalse(EncryptedConversationSurfaces.isV2(conversation("conversation_plain_0001J7AB", encrypted: false), ownerNamespace: namespace, stateStore: broken))
    }

    func testScheduledMessagesAreClosedInAV2Conversation() {
        XCTAssertFalse(EncryptedConversationSurfaces.allowsScheduling(isV2: true))
        XCTAssertTrue(EncryptedConversationSurfaces.allowsScheduling(isV2: false))
    }

    func testTheAppSwitcherNeverShowsDecryptedContent() {
        let encrypted = conversation("conversation_secret_01J7ABCD", encrypted: true)
        let plain = conversation("conversation_plain_0001J7AB", encrypted: false)
        XCTAssertTrue(EncryptedConversationSurfaces.hidesSnapshot(of: encrypted))
        XCTAssertFalse(EncryptedConversationSurfaces.hidesSnapshot(of: plain))
        XCTAssertFalse(EncryptedConversationSurfaces.listHidesSnapshot([encrypted, plain], decryptedPreviews: [:], drafts: [plain.id: "Brouillon en clair"]),
                       "Ni aperçu déchiffré ni brouillon chiffré : la liste reste visible")
        XCTAssertTrue(EncryptedConversationSurfaces.listHidesSnapshot([encrypted, plain], decryptedPreviews: [encrypted.id: "Rendez-vous à 8 h"], drafts: [:]))
        XCTAssertTrue(EncryptedConversationSurfaces.listHidesSnapshot([encrypted, plain], decryptedPreviews: [:], drafts: [encrypted.id: "Brouillon"]))
        XCTAssertFalse(EncryptedConversationSurfaces.listHidesSnapshot([plain], decryptedPreviews: [plain.id: "texte"], drafts: [:]))
    }

    /// AF-MSG-03 : « Supprimer pour moi » d'un message v2 tient après la relève
    /// suivante, par compte et par conversation, et part avec le compte.
    func testHiddenV2MessagesStayHiddenPerAccountAndConversation() {
        let defaults = UserDefaults(suiteName: "EncryptedConversationSurfacesTests.hidden")!
        defaults.removePersistentDomain(forName: "EncryptedConversationSurfacesTests.hidden")
        let alice = "user:user_alice_01J7ABCD23456789"
        let bob = "user:user_bob_0001J7ABCD23456789"
        E2EEV2HiddenMessagesStore.hide(messageRef: "ref_one", conversationId: "conv_a", ownerScopeId: alice, defaults: defaults)
        E2EEV2HiddenMessagesStore.hide(messageRef: "ref_two", conversationId: "conv_a", ownerScopeId: alice, defaults: defaults)
        E2EEV2HiddenMessagesStore.hide(messageRef: "ref_one", conversationId: "conv_a", ownerScopeId: alice, defaults: defaults)
        XCTAssertEqual(E2EEV2HiddenMessagesStore.hiddenRefs(conversationId: "conv_a", ownerScopeId: alice, defaults: defaults), ["ref_one", "ref_two"])
        XCTAssertTrue(E2EEV2HiddenMessagesStore.hiddenRefs(conversationId: "conv_b", ownerScopeId: alice, defaults: defaults).isEmpty)
        XCTAssertTrue(E2EEV2HiddenMessagesStore.hiddenRefs(conversationId: "conv_a", ownerScopeId: bob, defaults: defaults).isEmpty,
                      "Un autre compte du même appareil ne voit pas ces choix")
        // Un invité n'a pas de compte auquel rattacher le choix.
        E2EEV2HiddenMessagesStore.hide(messageRef: "ref_guest", conversationId: "conv_a", ownerScopeId: "guest", defaults: defaults)
        XCTAssertTrue(E2EEV2HiddenMessagesStore.hiddenRefs(conversationId: "conv_a", ownerScopeId: "guest", defaults: defaults).isEmpty)
        E2EEV2HiddenMessagesStore.purge(ownerScopeId: alice, defaults: defaults)
        XCTAssertTrue(E2EEV2HiddenMessagesStore.hiddenRefs(conversationId: "conv_a", ownerScopeId: alice, defaults: defaults).isEmpty)
        defaults.removePersistentDomain(forName: "EncryptedConversationSurfacesTests.hidden")
    }

    /// U01 : une cible chiffrée est toujours sûre ; seul « chiffré vers clair » est interdit.
    func testForwardNeverTurnsAnEncryptedMessageIntoPlainText() {
        typealias Surfaces = EncryptedConversationSurfaces
        XCTAssertFalse(Surfaces.allowsForward(fromEncrypted: true, toEncrypted: false))
        XCTAssertTrue(Surfaces.allowsForward(fromEncrypted: true, toEncrypted: true))
        XCTAssertTrue(Surfaces.allowsForward(fromEncrypted: false, toEncrypted: true))
        XCTAssertTrue(Surfaces.allowsForward(fromEncrypted: false, toEncrypted: false))
    }

    /// U01 : chaque cible reçoit le texte par son propre chemin d'envoi.
    func testForwardRouteFollowsTheTarget() {
        typealias Surfaces = EncryptedConversationSurfaces
        XCTAssertEqual(Surfaces.forwardRoute(toEncrypted: false, targetIsV2: false, v2Enabled: false), .plain)
        XCTAssertEqual(Surfaces.forwardRoute(toEncrypted: false, targetIsV2: true, v2Enabled: true), .plain)
        XCTAssertEqual(Surfaces.forwardRoute(toEncrypted: true, targetIsV2: false, v2Enabled: true), .legacyEncrypted)
        XCTAssertEqual(Surfaces.forwardRoute(toEncrypted: true, targetIsV2: true, v2Enabled: true), .v2)
        XCTAssertEqual(Surfaces.forwardRoute(toEncrypted: true, targetIsV2: true, v2Enabled: false), .unavailable,
                       "Une cible v2 fermée dans cette version ne reçoit jamais le texte en clair")
    }

    func testV2SendFailureMessageDependsOnWhetherTheTextIsKept() throws {
        typealias Surfaces = EncryptedConversationSurfaces
        XCTAssertNil(Surfaces.v2SendFailureMessage(.alreadyAccepted(messageRef: "ref")))
        let kept = try XCTUnwrap(Surfaces.v2SendFailureMessage(.capabilityMissing(["u"])))
        let notKept = try XCTUnwrap(Surfaces.v2SendFailureMessage(.capabilityMissing(["u"]), keptForRetry: false))
        XCTAssertNotEqual(kept, notKept, "Le transfert ne garde rien : il ne promet pas de bouton Renvoyer")
        XCTAssertNotNil(Surfaces.v2SendFailureMessage(.needsEpoch))
        XCTAssertNotNil(Surfaces.v2SendFailureMessage(.membersNotTrusted(["u"])))
    }

    private func conversation(_ id: String, encrypted: Bool) -> MessageConversation {
        MessageConversation(
            id: id, title: "Fixture", isGroup: false, e2eeEnabled: encrypted, groupPhotoUrl: nil, createdAt: nil,
            updatedAt: nil, lastMessageAt: nil, lastReadAt: nil, pinnedAt: nil, participants: [], lastMessage: nil
        )
    }
}

/// Trousseau qui ne répond plus.
private struct FailingTokenStore: TokenStore {
    func string(for key: String) throws -> String? { throw KeychainError.unexpectedStatus(-25308) }
    func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws { throw KeychainError.unexpectedStatus(-25308) }
    func remove(_ key: String) throws { throw KeychainError.unexpectedStatus(-25308) }
    func removeAll() throws { throw KeychainError.unexpectedStatus(-25308) }
}
