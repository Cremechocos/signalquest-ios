import CallKit
import XCTest
@testable import SignalQuest

/// IOS-CALL-5 (plan 3, jalon A) : un appel chiffré sonne avec le nom retrouvé
/// sur l'appareil et reste hors de l'historique d'appels d'iOS (spec §10.5).
final class CallDiscretionTests: XCTestCase {
    private let alice = "user:" + String(repeating: "a", count: 24)
    private let bruno = "user:" + String(repeating: "b", count: 24)

    func testDirectoryKeepsTheNameShownInTheAppSealedAndPerAccount() throws {
        let root = temporaryRoot()
        let keys = InMemoryTokenStore()
        let directory = CallConversationDirectory(rootURL: root, keyStore: keys)
        directory.record(
            [conversation("c1", title: nil, encrypted: true, members: [("u-alice", "Alice"), ("u-lea", "Léa")])],
            currentUserId: "u-alice",
            ownerScopeId: alice
        )

        XCTAssertEqual(directory.entry(conversationId: "c1", ownerScopeId: alice)?.title, "Léa", "Jamais son propre nom")
        XCTAssertEqual(directory.entry(conversationId: "c1", ownerScopeId: alice)?.isEncrypted, true)
        XCTAssertNil(directory.entry(conversationId: "c1", ownerScopeId: bruno))

        let file = try XCTUnwrap(files(in: root).first)
        let bytes = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(bytes.contains("Léa"), "Scellé sur le disque")
        XCTAssertFalse(bytes.contains("c1"))

        // Nouvelle instance = réveil par PushKit : même fichier, même trousseau.
        let relaunched = CallConversationDirectory(rootURL: root, keyStore: keys)
        XCTAssertEqual(relaunched.entry(conversationId: "c1", ownerScopeId: alice)?.title, "Léa")

        relaunched.purge(ownerScopeId: alice)
        XCTAssertNil(relaunched.entry(conversationId: "c1", ownerScopeId: alice))
        XCTAssertTrue(files(in: root).isEmpty, "Effacé avec le compte")
    }

    func testDirectoryFollowsRenamesAndDropsTheLeastRecentlySeen() {
        let directory = CallConversationDirectory(rootURL: temporaryRoot(), keyStore: InMemoryTokenStore())
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let many = (0..<CallConversationDirectory.maxEntries).map {
            conversation("c\($0)", title: "Groupe \($0)", encrypted: false, members: [])
        }
        directory.record(many, currentUserId: nil, ownerScopeId: alice, now: start)
        directory.record(
            [conversation("c0", title: "Équipe terrain", encrypted: true, members: []),
             conversation("new", title: "Nouveau", encrypted: false, members: [])],
            currentUserId: nil,
            ownerScopeId: alice,
            now: start.addingTimeInterval(60)
        )

        XCTAssertEqual(directory.entry(conversationId: "c0", ownerScopeId: alice)?.title, "Équipe terrain")
        XCTAssertEqual(directory.entry(conversationId: "c0", ownerScopeId: alice)?.isEncrypted, true)
        XCTAssertEqual(directory.entry(conversationId: "new", ownerScopeId: alice)?.title, "Nouveau")
        let kept = (0..<CallConversationDirectory.maxEntries).filter {
            directory.entry(conversationId: "c\($0)", ownerScopeId: alice) != nil
        }
        XCTAssertEqual(kept.count, CallConversationDirectory.maxEntries - 1, "Plafonné : une conversation ancienne tombe")
    }

    func testEncryptedCallNameComesFromTheDeviceOnly() {
        let known = CallConversationDirectory.Entry(title: "Léa", isEncrypted: true, seenAtMs: 0)
        XCTAssertEqual(
            CallDiscretionPolicy.displayName(payloadName: "Ta banque", requiresE2EE: true, conversation: known),
            "Léa", "Le serveur ne choisit pas le nom d'un appel chiffré"
        )
        XCTAssertEqual(
            CallDiscretionPolicy.displayName(payloadName: "Ta banque", requiresE2EE: true, conversation: nil),
            CallDiscretionPolicy.fallbackName
        )
        XCTAssertEqual(
            CallDiscretionPolicy.displayName(payloadName: "Camille", requiresE2EE: false, conversation: known),
            "Camille", "Appel d'une conversation v1 : le nom de la notification reste"
        )
        XCTAssertEqual(
            CallDiscretionPolicy.displayName(payloadName: "  ", requiresE2EE: nil, conversation: known),
            "Léa"
        )
        XCTAssertEqual(IncomingCallE2EEExpectation.invalid.requiresE2EE, true, "Une notification invalide ne donne pas de nom")
        XCTAssertNil(IncomingCallE2EEExpectation.unresolved.requiresE2EE)
    }

    func testEncryptedConversationCallsAlsoGoToTheSystemRecents() {
        let encrypted = CallConversationDirectory.Entry(title: "Léa", isEncrypted: true, seenAtMs: 0)
        let plain = CallConversationDirectory.Entry(title: "Camille", isEncrypted: false, seenAtMs: 0)
        XCTAssertTrue(CallDiscretionPolicy.isDiscreet(requiresE2EE: true, conversation: nil))
        XCTAssertTrue(CallDiscretionPolicy.isDiscreet(requiresE2EE: false, conversation: encrypted), "Conversation v1 chiffrée")
        XCTAssertFalse(CallDiscretionPolicy.isDiscreet(requiresE2EE: nil, conversation: plain))
        XCTAssertFalse(CallDiscretionPolicy.isDiscreet(requiresE2EE: nil, conversation: nil))

        // Décision du 06/10 (v0.4.36) : Récents pour tous les appels.
        let configuration = CXProviderConfiguration()
        XCTAssertTrue(CallDiscretionPolicy.configuration(configuration, discreet: true).includesCallsInRecents)
        XCTAssertTrue(CallDiscretionPolicy.configuration(configuration, discreet: false).includesCallsInRecents)
    }

    func testRecentsHandleCarriesTheConversationAndCallsBackThroughIt() {
        XCTAssertEqual(CallRecentsHandle.value(conversationId: "conv_01J7"), "sq-conversation:conv_01J7")
        XCTAssertNil(CallRecentsHandle.value(conversationId: nil))
        XCTAssertNil(CallRecentsHandle.value(conversationId: ""))
        XCTAssertEqual(CallRecentsHandle.conversationId(fromHandleValue: "sq-conversation:conv_01J7"), "conv_01J7")
        XCTAssertNil(CallRecentsHandle.conversationId(fromHandleValue: "Camille"), "Ancien appel nommé : rien à rappeler")
        XCTAssertNil(CallRecentsHandle.conversationId(fromHandleValue: "sq-conversation:../x"))
        XCTAssertNil(CallRecentsHandle.conversationId(fromHandleValue: "sq-conversation:"))

        // `NSUserActivity.interaction` ne se pose pas en test : sans elle, rien.
        XCTAssertNil(CallRecentsHandle.callBack(from: NSUserActivity(activityType: "INStartCallIntent")))
    }

    func testOnlyTheRingNotificationOfThatCallIsCleared() {
        XCTAssertTrue(CallManager.isRingNotification(["type": "call_incoming", "callId": "call_1"], callId: "call_1"))
        XCTAssertFalse(CallManager.isRingNotification(["type": "call_incoming", "callId": "call_2"], callId: "call_1"))
        XCTAssertFalse(CallManager.isRingNotification(["type": "call_missed", "callId": "call_1"], callId: "call_1"))
        XCTAssertFalse(CallManager.isRingNotification(["type": "message", "conversationId": "c"], callId: "call_1"))
    }

    // MARK: - Outils

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallDiscretionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func files(in root: URL) -> [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "conversations.json.enc" }
    }

    private func conversation(
        _ id: String,
        title: String?,
        encrypted: Bool,
        members: [(id: String, name: String)]
    ) -> MessageConversation {
        MessageConversation(
            id: id,
            title: title,
            isGroup: members.count > 2,
            e2eeEnabled: encrypted,
            groupPhotoUrl: nil,
            createdAt: nil,
            updatedAt: nil,
            lastMessageAt: nil,
            lastReadAt: nil,
            pinnedAt: nil,
            participants: members.map { member in
                ConversationParticipant(
                    userId: member.id,
                    role: "member",
                    joinedAt: nil,
                    lastReadAt: nil,
                    user: MessageUser(id: member.id, name: member.name, email: "\(member.id)@example.org", avatarUrl: nil),
                    presence: nil
                )
            },
            lastMessage: nil
        )
    }

    private final class LockedTokenStore: TokenStore, @unchecked Sendable {
        func string(for key: String) throws -> String? { throw CocoaError(.fileReadNoPermission) }
        func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws {}
        func remove(_ key: String) throws {}
        func keys(withPrefix prefix: String) throws -> [String] { [] }
        func removeAll() throws {}
    }

    /// §10.0 : un appel d'une conversation que l'appareil sait v2 n'est accepté
    /// que chiffré, même si sa notification ne le dit pas ; illisible, l'état
    /// compte comme v2.
    func testAV2ConversationOnlyTakesEncryptedCalls() throws {
        XCTAssertEqual(IncomingCallE2EEExpectation.requiresEncryption(announced: false, knownV2: true), true)
        XCTAssertEqual(IncomingCallE2EEExpectation.requiresEncryption(announced: nil, knownV2: true), true)
        XCTAssertEqual(IncomingCallE2EEExpectation.requiresEncryption(announced: true, knownV2: false), true)
        XCTAssertEqual(IncomingCallE2EEExpectation.requiresEncryption(announced: false, knownV2: false), false)
        XCTAssertNil(IncomingCallE2EEExpectation.requiresEncryption(announced: nil, knownV2: false))

        let namespace = "ns-calls"
        let store = E2EEV2ConversationStateStore(tokenStore: InMemoryTokenStore()) { _ in true }
        try store.record(
            .init(conversationId: "conv-v2-0000000001", creatorUserId: "user-alice-000001", creatorDeviceId: "device-alice-0001",
                  manifestDigest: "digest", membershipChangeNumber: 2, membershipDigest: "membership", recordedAtMs: 0),
            ownerNamespace: namespace
        )
        XCTAssertTrue(IncomingCallE2EEExpectation.knownV2(conversationId: "conv-v2-0000000001", ownerNamespace: namespace, stateStore: store))
        XCTAssertFalse(IncomingCallE2EEExpectation.knownV2(conversationId: "conv-v1-0000000001", ownerNamespace: namespace, stateStore: store))
        XCTAssertFalse(IncomingCallE2EEExpectation.knownV2(conversationId: nil, ownerNamespace: namespace, stateStore: store))
        let locked = E2EEV2ConversationStateStore(tokenStore: LockedTokenStore()) { _ in true }
        XCTAssertTrue(
            IncomingCallE2EEExpectation.knownV2(conversationId: "conv-v1-0000000001", ownerNamespace: namespace, stateStore: locked),
            "Illisible : compte comme v2"
        )
    }

    /// Relecture indépendante : le serveur peut rendre le chiffrement
    /// obligatoire, jamais le retirer à un appel annoncé chiffré.
    func testServerCannotDowngradeACallAnnouncedEncrypted() {
        XCTAssertTrue(IncomingCallE2EEExpectation.merged(known: true, server: false))
        XCTAssertTrue(IncomingCallE2EEExpectation.merged(known: nil, server: true))
        XCTAssertTrue(IncomingCallE2EEExpectation.merged(known: false, server: true))
        XCTAssertFalse(IncomingCallE2EEExpectation.merged(known: nil, server: false))
        XCTAssertFalse(IncomingCallE2EEExpectation.merged(known: false, server: false))
    }
}
