import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 4 (plan 3) : chaîne d'appartenance signée (D.4) et état « v2 » collant
/// d'une conversation (§12, v0.4.7).
final class E2EEV2ConversationStateTests: XCTestCase {
    private let conversationId = "conversation_01J7ABCD23456789"
    private let alice = "user_alice_01J7ABCD23456789"
    private let bruno = "user_bruno_01J7ABCD23456789"
    private let carla = "user_carla_01J7ABCD23456789"
    private let aliceDevice = "device_alice_ios_01J7ABCD2345"
    private let brunoDevice = "device_bruno_android_01J7ABCD"
    private let carlaDevice = "device_carla_ios_01J7ABCD2345"
    private let createdAtMs: Int64 = 1_790_000_000_000

    private var keys: [String: P256.Signing.PrivateKey] = [:]

    override func setUp() {
        super.setUp()
        keys = [aliceDevice: P256.Signing.PrivateKey(), brunoDevice: P256.Signing.PrivateKey(), carlaDevice: P256.Signing.PrivateKey()]
    }

    // MARK: Chaîne d'appartenance

    func testGenesisReproducesTheMembershipVector() throws {
        let vector = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL("membership-change-v1"))) as? [String: Any])
        let chain = try XCTUnwrap(vector["chain"] as? [[String: Any]]).compactMap { $0["changeUtf8"] as? String }
        let genesis = try E2EEV2MembershipChain.genesis(
            conversationId: conversationId, memberIds: [bruno, alice], adminIds: [alice], isGroup: true,
            actor: .init(userId: alice, deviceId: aliceDevice), createdAtMs: createdAtMs
        )
        XCTAssertEqual(genesis.map(\.canonical), Array(chain.prefix(3)), "ADD triés par userId, puis ROLE_ADMIN")

        let excluding = try E2EEV2MembershipChain.genesis(
            conversationId: conversationId, memberIds: [bruno, alice], adminIds: [alice], isGroup: true, excludesWeb: true,
            actor: .init(userId: alice, deviceId: aliceDevice), createdAtMs: createdAtMs
        )
        XCTAssertEqual(excluding.map(\.canonical), chain, "Navigateurs exclus dès l'époque 1 : EXCLUDE_WEB_ON en dernier")
    }

    func testGenesisBuilderRefusesInvalidShapes() {
        let actor = E2EEV2MembershipChain.Actor(userId: alice, deviceId: aliceDevice)
        func build(_ members: [String], _ admins: [String], group: Bool) -> Bool {
            (try? E2EEV2MembershipChain.genesis(
                conversationId: conversationId, memberIds: members, adminIds: admins, isGroup: group,
                actor: actor, createdAtMs: createdAtMs
            )) != nil
        }
        XCTAssertTrue(build([alice, bruno], [], group: false))
        XCTAssertFalse(build([alice, bruno], [alice], group: false), "Pas d'administrateur en tête-à-tête")
        XCTAssertFalse(build([alice, bruno, carla], [], group: false), "Un tête-à-tête a deux membres")
        XCTAssertFalse(build([alice, bruno], [], group: true), "Un groupe a au moins un administrateur")
        XCTAssertFalse(build([bruno, carla], [bruno], group: true), "L'auteur fait partie des membres")
        XCTAssertFalse(build([alice, bruno], [carla], group: true), "Un administrateur est membre")
        XCTAssertFalse(build([alice, alice, bruno], [alice], group: true), "Pas de doublon")
    }

    func testGroupChainFollowsTheAdminRules() throws {
        let genesis = try signedGenesis(members: [alice, bruno, carla], admins: [alice], group: true, by: aliceDevice, user: alice)
        var state = try apply(genesis, group: true, genesisLength: 3 + 1)
        XCTAssertEqual(state.members, [alice, bruno, carla])
        XCTAssertEqual(state.admins, [alice])

        XCTAssertThrowsError(try apply([next(state, "REMOVE", carla, by: bruno, brunoDevice)], to: state, group: true, genesisLength: 4),
                             "Un membre non administrateur ne retire personne")
        XCTAssertThrowsError(try apply([next(state, "REMOVE", alice, by: alice, aliceDevice)], to: state, group: true, genesisLength: 4),
                             "On part par LEAVE, pas en se retirant")
        state = try apply([next(state, "ROLE_ADMIN", bruno, by: alice, aliceDevice)], to: state, group: true, genesisLength: 4)
        state = try apply([next(state, "REMOVE", carla, by: bruno, brunoDevice)], to: state, group: true, genesisLength: 4)
        XCTAssertEqual(state.members, [alice, bruno])
        XCTAssertThrowsError(try apply([next(state, "LEAVE", carla, by: carla, carlaDevice)], to: state, group: true, genesisLength: 4),
                             "Un ancien membre n'agit plus")
        state = try apply([next(state, "LEAVE", bruno, by: bruno, brunoDevice)], to: state, group: true, genesisLength: 4)
        XCTAssertEqual(state.admins, [alice])

        let forged = next(state, "ADD", carla, by: alice, aliceDevice)
        let tampered = E2EEV2SignedString(canonical: forged.canonical, signatureB64: next(state, "ADD", bruno, by: alice, aliceDevice).signatureB64)
        XCTAssertThrowsError(try apply([tampered], to: state, group: true, genesisLength: 4), "Signature d'un autre changement")
        XCTAssertThrowsError(
            try E2EEV2MembershipChain.apply([forged], to: state, conversationId: conversationId, isGroup: true, genesisLength: 4) { _, _ in nil },
            "Appareil inconnu"
        )
    }

    /// 410 `E2EE_ACCOUNT_DELETED` : un membre sans appareil, ni refusé ni à relire.
    func testADeletedAccountIsAMemberWithoutDevices() async throws {
        let directory = E2EEV2TrustDirectory(
            ownerNamespace: "ns-deleted-account", pins: E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore()),
            fetch: { _, _ in throw E2EEV2TrustDirectory.AccountDeleted() }
        )
        let set = try await directory.certifiedDevices(for: [bruno])
        XCTAssertEqual(set.devicesByUser[bruno], [])
        XCTAssertEqual(set.deleted, [bruno])
        XCTAssertTrue(set.refusals.isEmpty)
        XCTAssertEqual(set.untrustedMembers([bruno]), [])
        XCTAssertEqual(set.unread([bruno]), [])
        XCTAssertNil(set.listVersions[bruno])
    }

    /// Un membre non administrateur qui a migré un groupe ne peut pas, plus
    /// tard, se nommer administrateur : la genèse s'arrête au n° de l'époque 1.
    func testMigrationAuthorCannotLaterGrantHimselfAdmin() throws {
        let genesis = try signedGenesis(members: [alice, bruno], admins: [alice], group: true, by: brunoDevice, user: bruno)
        let state = try apply(genesis, group: true, genesisLength: 3)
        XCTAssertEqual(state.admins, [alice])
        let grant = next(state, "ROLE_ADMIN", bruno, by: bruno, brunoDevice)
        XCTAssertThrowsError(try apply([grant], to: state, group: true, genesisLength: 3))
    }

    func testDirectConversationRules() throws {
        let genesis = try signedGenesis(members: [alice, bruno], admins: [], group: false, by: aliceDevice, user: alice)
        var state = try apply(genesis, group: false, genesisLength: 2)
        state = try apply([next(state, "EXCLUDE_WEB_ON", "-", by: bruno, brunoDevice)], to: state, group: false, genesisLength: 2)
        XCTAssertTrue(state.excludesWeb, "En tête-à-tête, les deux membres règlent les navigateurs")
        XCTAssertThrowsError(try apply([next(state, "ADD", carla, by: alice, aliceDevice)], to: state, group: false, genesisLength: 2),
                             "On n'ajoute personne à un tête-à-tête")
    }

    /// Relecture indépendante du lot 4 : l'époque 1 repose sur toute la
    /// genèse, et aucune époque sur une genèse partielle (ici, avant son
    /// EXCLUDE_WEB_ON final, quand un navigateur était encore permis).
    func testAnEpochCannotRestOnAPartialGenesis() throws {
        let changes = try E2EEV2MembershipChain.genesis(
            conversationId: conversationId, memberIds: [alice, bruno], adminIds: [alice], isGroup: true, excludesWeb: true,
            actor: .init(userId: alice, deviceId: aliceDevice), createdAtMs: createdAtMs
        ).map { try E2EEV2SignedString.sign($0.canonical, with: XCTUnwrap(keys[aliceDevice])) }
        XCTAssertEqual(changes.count, 4)
        let partial = try apply(Array(changes.prefix(3)), group: true, genesisLength: 4)
        let web = E2EEV2EpochManifest.recipient(
            userId: bruno, deviceId: "device_bruno_web_01J7ABCD2345", platform: "web",
            fingerprint: E2EEV2Canonical.sha256B64URL(Data("navigateur".utf8))
        )
        func manifest(epoch: Int, on state: E2EEV2MembershipState) throws -> E2EEV2EpochManifest {
            E2EEV2EpochManifest.make(
                conversationId: conversationId, epochNumber: epoch, creatorUserId: alice, creatorDeviceId: aliceDevice,
                keyCommitmentB64: Data(repeating: 1, count: 32).base64EncodedString(), recipients: [web],
                excludesWeb: false, membershipChangeNumber: state.changeNumber,
                membershipDigest: E2EEV2MembershipChange.digest(of: try XCTUnwrap(state.lastCanonical)), createdAtMs: createdAtMs
            )
        }
        for epoch in [1, 2] {
            XCTAssertThrowsError(try E2EEV2EpochBinding.check(
                try manifest(epoch: epoch, on: partial), recipients: [web], state: partial, genesisLength: 4,
                previousMembershipChangeNumber: nil
            )) { XCTAssertEqual($0 as? E2EEV2EpochBinding.Failure, .membershipMismatch, "Époque \(epoch) sur une genèse partielle") }
        }
    }

    func testSequenceNumbersAndEncodingsAreBounded() throws {
        XCTAssertEqual(E2EEV2Canonical.sequenceNumber("2147483646"), 2_147_483_646)
        XCTAssertNil(E2EEV2Canonical.sequenceNumber("2147483647"), "n + 1 ne doit jamais déborder")
        XCTAssertNil(E2EEV2Canonical.sequenceNumber("0"))
        XCTAssertNil(E2EEV2Canonical.sequenceNumber("01"))
        let huge = [E2EEV2MembershipChange.tag, "1", conversationId, "2147483647", "ADD", bruno, alice, aliceDevice, "x", String(createdAtMs)]
            .joined(separator: "\n")
        XCTAssertThrowsError(try E2EEV2MembershipChange.parse(huge, previousCanonical: "précédent"))

        // Une même signature en base64 non canonique (bits de bourrage) est refusée.
        let signed = try E2EEV2SignedString.sign("SQ-TEST\n1", with: XCTUnwrap(keys[aliceDevice]))
        let key = try XCTUnwrap(keys[aliceDevice]).publicKey
        XCTAssertTrue(signed.verify(with: key))
        if signed.signatureB64.hasSuffix("=") {
            var characters = Array(signed.signatureB64)
            let index = characters.lastIndex { $0 != "=" }!
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
            characters[index] = alphabet[alphabet.firstIndex(of: characters[index])! ^ 1]
            let variant = E2EEV2SignedString(canonical: signed.canonical, signatureB64: String(characters))
            XCTAssertEqual(Data(base64Encoded: variant.signatureB64), Data(base64Encoded: signed.signatureB64))
            XCTAssertFalse(variant.verify(with: key), "Base64 non canonique")
        }
    }

    // MARK: État collant

    func testStickyStateNeverRegressesAndRefusesASecondGenesis() throws {
        let tokens = InMemoryTokenStore()
        let namespace = LocalAccountScope.storageNamespace(for: "user:\(alice)")
        let store = E2EEV2ConversationStateStore(tokenStore: tokens, allowsOwner: { $0 == namespace })
        XCTAssertFalse(try store.isV2(conversationId: conversationId, ownerNamespace: namespace))

        let genesis = E2EEV2ConversationStateStore.Genesis(
            conversationId: conversationId, creatorUserId: alice, creatorDeviceId: aliceDevice,
            manifestDigest: E2EEV2Canonical.sha256B64URL(Data("manifeste 1".utf8)),
            membershipChangeNumber: 3, membershipDigest: E2EEV2Canonical.sha256B64URL(Data("changement 3".utf8)),
            recordedAtMs: createdAtMs
        )
        try store.record(genesis, ownerNamespace: namespace)
        XCTAssertTrue(try store.isV2(conversationId: conversationId, ownerNamespace: namespace))
        XCTAssertEqual(try store.record(genesis, ownerNamespace: namespace), genesis, "Le même manifeste : sans effet")

        let other = E2EEV2ConversationStateStore.Genesis(
            conversationId: conversationId, creatorUserId: bruno, creatorDeviceId: brunoDevice,
            manifestDigest: E2EEV2Canonical.sha256B64URL(Data("manifeste 2".utf8)),
            membershipChangeNumber: 4, membershipDigest: E2EEV2Canonical.sha256B64URL(Data("changement 4".utf8)),
            recordedAtMs: createdAtMs + 1
        )
        XCTAssertThrowsError(try store.record(other, ownerNamespace: namespace)) {
            XCTAssertEqual($0 as? E2EEV2ConversationStateStore.Failure, .genesisConflict)
        }
        XCTAssertThrowsError(try store.record(genesis, ownerNamespace: "autre-compte")) {
            XCTAssertEqual($0 as? E2EEV2ConversationStateStore.Failure, .otherAccount)
        }

        let key = try XCTUnwrap(try tokens.keys(withPrefix: E2EEV2ConversationStateStore.prefix(ownerNamespace: namespace)).first)
        try tokens.set("illisible", for: key, accessibility: .afterFirstUnlock)
        XCTAssertTrue(try store.isV2(conversationId: conversationId, ownerNamespace: namespace), "Illisible : toujours v2")
        XCTAssertThrowsError(try store.genesis(conversationId: conversationId, ownerNamespace: namespace))

        try E2EEV2VaultBoundary.purge(store: tokens, ownerScopeId: "user:\(alice)")
        XCTAssertFalse(try store.isV2(conversationId: conversationId, ownerNamespace: namespace), "Effacé avec le compte")
    }

    /// Réinitialisation d'identité : sans ses clés, une époque courante n'est
    /// plus à jour ; la genèse, elle, reste.
    func testIdentityResetDropsCurrentEpochsButKeepsTheGenesis() throws {
        let tokens = InMemoryTokenStore()
        let namespace = LocalAccountScope.storageNamespace(for: "user:\(alice)")
        let store = E2EEV2ConversationStateStore(tokenStore: tokens, allowsOwner: { $0 == namespace })
        try store.record(
            .init(
                conversationId: conversationId, creatorUserId: alice, creatorDeviceId: aliceDevice,
                manifestDigest: E2EEV2Canonical.sha256B64URL(Data("m".utf8)), membershipChangeNumber: 2,
                membershipDigest: E2EEV2Canonical.sha256B64URL(Data("c".utf8)), recordedAtMs: createdAtMs
            ),
            ownerNamespace: namespace
        )
        try store.recordCurrentEpoch(
            .init(
                conversationId: conversationId, epochNumber: 3, membershipChangeNumber: 2, memberIds: [alice, bruno],
                recipientsDigest: "d", excludesWeb: false, createdAtMs: createdAtMs, acceptedAtMs: createdAtMs
            ),
            ownerNamespace: namespace
        )
        try store.removeCurrentEpochs(ownerNamespace: namespace)
        XCTAssertNil(try store.currentEpoch(conversationId: conversationId, ownerNamespace: namespace))
        XCTAssertTrue(try store.isV2(conversationId: conversationId, ownerNamespace: namespace))
    }

    /// Relecture indépendante du lot 4 (constat critique) : pour une
    /// conversation v2, l'envoi et les appels prennent l'époque vérifiée, lue
    /// par son numéro, même si un ancien chemin a déplacé le pointeur du coffre.
    func testAV2ConversationAlwaysUsesItsVerifiedEpoch() throws {
        let tokens = InMemoryTokenStore()
        let owner = "user:\(alice)"
        let namespace = LocalAccountScope.storageNamespace(for: owner)
        let states = E2EEV2ConversationStateStore(tokenStore: tokens, allowsOwner: { $0 == namespace })
        let keys = E2EEV2EpochKeyStore(tokenStore: tokens, allowsOwner: { $0 == namespace })
        func put(_ number: Int, _ byte: UInt8, conversation: String) throws {
            let key = Data(repeating: byte, count: 32)
            XCTAssertTrue(try keys.put(
                recordInput: .init(
                    conversationId: conversation, epochId: "epoch_review_\(number)_0123456789",
                    epochNumber: number, keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(key)
                ),
                epochKey: key, ownerNamespace: namespace
            ))
        }
        try put(1, 0x11, conversation: conversationId)
        try states.record(
            .init(
                conversationId: conversationId, creatorUserId: alice, creatorDeviceId: aliceDevice,
                manifestDigest: E2EEV2Canonical.sha256B64URL(Data("m".utf8)), membershipChangeNumber: 2,
                membershipDigest: E2EEV2Canonical.sha256B64URL(Data("c".utf8)), recordedAtMs: createdAtMs
            ),
            ownerNamespace: namespace
        )
        try states.recordCurrentEpoch(
            .init(
                conversationId: conversationId, epochNumber: 1, membershipChangeNumber: 2, memberIds: [alice, bruno],
                recipientsDigest: "d", excludesWeb: false, createdAtMs: createdAtMs, acceptedAtMs: createdAtMs
            ),
            ownerNamespace: namespace
        )
        // Un ancien chemin piloté par le serveur avance le pointeur à l'époque 5.
        try put(5, 0x55, conversation: conversationId)
        XCTAssertEqual(try keys.load(conversationId: conversationId, ownerNamespace: namespace)?.epochNumber, 5)

        let used = try XCTUnwrap(try E2EEV2VerifiedEpochKeys.current(
            conversationId: conversationId, ownerNamespace: namespace, keyStore: keys, stateStore: states
        ))
        XCTAssertEqual(used.epochNumber, 1)
        XCTAssertEqual(used.epochKey, Data(repeating: 0x11, count: 32))
        XCTAssertNil(try E2EEV2VerifiedEpochKeys.exact(
            conversationId: conversationId, epochNumber: 5, ownerNamespace: namespace, keyStore: keys, stateStore: states
        ), "Aucun appel sur une époque non vérifiée")
        XCTAssertFalse(E2EEV2VerifiedEpochKeys.allowsLegacyEpochPath(
            conversationId: conversationId, ownerNamespace: namespace, stateStore: states
        ))

        // Une conversation non v2 garde le comportement d'avant.
        let legacy = "conversation_legacy_0123456789"
        try put(2, 0x22, conversation: legacy)
        XCTAssertEqual(try E2EEV2VerifiedEpochKeys.current(
            conversationId: legacy, ownerNamespace: namespace, keyStore: keys, stateStore: states
        )?.epochNumber, 2)
        XCTAssertTrue(E2EEV2VerifiedEpochKeys.allowsLegacyEpochPath(conversationId: legacy, ownerNamespace: namespace, stateStore: states))

        // État illisible : aucune clé, aucun ancien chemin.
        let unreadable = E2EEV2ConversationStateStore(tokenStore: ThrowingTokenStore(), allowsOwner: { _ in true })
        XCTAssertThrowsError(try E2EEV2VerifiedEpochKeys.current(
            conversationId: conversationId, ownerNamespace: namespace, keyStore: keys, stateStore: unreadable
        ))
        XCTAssertFalse(E2EEV2VerifiedEpochKeys.allowsLegacyEpochPath(
            conversationId: conversationId, ownerNamespace: namespace, stateStore: unreadable
        ))
    }

    // MARK: Outils

    private func signedGenesis(members: [String], admins: [String], group: Bool, by device: String, user: String) throws -> [E2EEV2SignedString] {
        try E2EEV2MembershipChain.genesis(
            conversationId: conversationId, memberIds: members, adminIds: admins, isGroup: group,
            actor: .init(userId: user, deviceId: device), createdAtMs: createdAtMs
        ).map { try E2EEV2SignedString.sign($0.canonical, with: XCTUnwrap(keys[device])) }
    }

    private func next(_ state: E2EEV2MembershipState, _ action: String, _ target: String, by user: String, _ device: String) -> E2EEV2SignedString {
        let change = E2EEV2MembershipChange(
            conversationId: conversationId, changeNumber: state.changeNumber + 1, action: action, targetUserId: target,
            actorUserId: user, actorDeviceId: device,
            previousChangeDigest: state.lastCanonical.map(E2EEV2MembershipChange.digest(of:)) ?? "-",
            createdAtMs: createdAtMs + Int64(state.changeNumber)
        )
        // Une clé absente échoue au test, pas au chaînage.
        return (try? E2EEV2SignedString.sign(change.canonical, with: keys[device] ?? P256.Signing.PrivateKey()))
            ?? E2EEV2SignedString(canonical: change.canonical, signatureB64: "")
    }

    private func apply(
        _ changes: [E2EEV2SignedString],
        to state: E2EEV2MembershipState = E2EEV2MembershipState(),
        group: Bool,
        genesisLength: Int
    ) throws -> E2EEV2MembershipState {
        let devices: [String: String] = [aliceDevice: alice, brunoDevice: bruno, carlaDevice: carla]
        return try E2EEV2MembershipChain.apply(
            changes, to: state, conversationId: conversationId, isGroup: group, genesisLength: genesisLength
        ) { userId, deviceId in
            devices[deviceId] == userId ? self.keys[deviceId]?.publicKey : nil
        }
    }

    private func vectorURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-v2/\(name).json")
    }
}

/// Coffre dont toute lecture échoue (trousseau verrouillé, enregistrement abîmé).
private final class ThrowingTokenStore: TokenStore, @unchecked Sendable {
    struct Locked: Error {}
    func string(for key: String) throws -> String? { throw Locked() }
    func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws { throw Locked() }
    func remove(_ key: String) throws { throw Locked() }
    func keys(withPrefix prefix: String) throws -> [String] { throw Locked() }
    func removeAll() throws { throw Locked() }
}
