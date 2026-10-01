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
