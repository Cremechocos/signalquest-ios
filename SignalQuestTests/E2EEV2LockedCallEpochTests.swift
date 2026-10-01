import CryptoKit
import Security
import XCTest
@testable import SignalQuest

/// Spec §2.6 (v0.4.13) : écran verrouillé, un appel chiffré se rejoint avec la
/// clé de l'époque courante lue dans le miroir des aperçus, qui ne la porte
/// qu'avec l'aperçu complet. L'extension peut écrire ce miroir : la clé ne sert
/// que si elle tient l'engagement épinglé dans l'état de l'app. Sinon l'appel
/// attend le déverrouillage.
final class E2EEV2LockedCallEpochTests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD23456789"
    private let callId = "call_locked_0000000000000001"
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    /// Coffre des clés d'époque fermé tant que l'appareil est verrouillé ;
    /// l'état des conversations reste lisible après le premier déverrouillage.
    private final class LockableVault: TokenStore, @unchecked Sendable {
        private let base: TokenStore
        var locked = false
        /// Une autre erreur du trousseau que le verrouillage.
        var failure: OSStatus?
        init(_ base: TokenStore) { self.base = base }
        func string(for key: String) throws -> String? {
            if key.hasPrefix("epoch-v2") {
                if let failure { throw KeychainError.unexpectedStatus(failure) }
                if locked { throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
            }
            return try base.string(for: key)
        }
        func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws {
            try base.set(value, for: key, accessibility: accessibility)
        }
        func remove(_ key: String) throws { try base.remove(key) }
        func keys(withPrefix prefix: String) throws -> [String] { try base.keys(withPrefix: prefix) }
        func removeAll() throws { try base.removeAll() }
    }

    private struct Call {
        let fixture: E2EEV2AccountFixture
        let seeded: E2EEV2SeededConversation
        let devices: E2EEV2CertifiedDeviceSet
        let vault: LockableVault
        let keys: E2EEV2EpochKeyStore
        let contextStore: E2EEV2NotificationContextStore
        let descriptor: E2EEV2CallSessionDescriptor
    }

    /// Conversation v2 à l'époque 1 et, s'il y a un aperçu, miroir écrit pour ce
    /// compte et cette session.
    private func makeCall(privacy: E2EEV2NotificationPrivacy? = .full) throws -> Call {
        let fixture = try E2EEV2AccountFixture()
        let devices = fixture.deviceSet(adding: [E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD").device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let contextStore = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        if let privacy {
            try contextStore.saveContractPreview(notificationContext(fixture, privacy: privacy), now: Date())
            try writeMirror(fixture: fixture, seeded: seeded, devices: devices, contextStore: contextStore)
        }
        let vault = LockableVault(fixture.vault)
        return Call(
            fixture: fixture, seeded: seeded, devices: devices, vault: vault, keys: E2EEV2EpochKeyStore(tokenStore: vault),
            contextStore: contextStore, descriptor: descriptor(epochNumber: 1, epochKey: seeded.epochKey)
        )
    }

    private func writeMirror(
        fixture: E2EEV2AccountFixture,
        seeded: E2EEV2SeededConversation,
        devices: E2EEV2CertifiedDeviceSet,
        contextStore: E2EEV2NotificationContextStore
    ) throws {
        let writer = E2EEV2NotificationMirrorWriter(
            keyStore: fixture.keys, stateStore: fixture.states, ledgerStore: try ledgerStore(), contextStore: contextStore,
            contractPreview: true
        )
        XCTAssertTrue(writer.update(
            conversationId: seeded.conversationId, devices: devices, latestMemberIds: [fixture.user, bruno],
            session: fixture.session, generation: writer.invalidate(seeded.conversationId)
        ))
    }

    private func descriptor(epochNumber: Int, epochKey: Data) -> E2EEV2CallSessionDescriptor {
        let epochId = "epoch_seeded_00000000000\(epochNumber)"
        return .init(
            version: E2EEV2CallBridge.version, provider: E2EEV2CallBridge.provider, epochId: epochId,
            epochNumber: epochNumber, keyCommitmentB64: (try? E2EEV2EpochCrypto.keyCommitment(epochKey)) ?? "",
            required: true, keyId: epochId
        )
    }

    private func prepare(_ call: Call, descriptor: E2EEV2CallSessionDescriptor? = nil) -> E2EEV2CallRequestPreparation {
        E2EEV2CallBridge.prepareAnswer(
            conversationId: call.seeded.conversationId, descriptor: descriptor ?? call.descriptor,
            ownerNamespace: call.fixture.session.ownerNamespace,
            keyStore: call.keys, stateStore: call.fixture.states, contextStore: call.contextStore
        )
    }

    private func resolve(_ call: Call) -> E2EEV2CallSessionResolution {
        E2EEV2CallBridge.resolveSession(
            conversationId: call.seeded.conversationId, callId: callId, descriptor: call.descriptor,
            ownerNamespace: call.fixture.session.ownerNamespace,
            keyStore: call.keys, stateStore: call.fixture.states, contextStore: call.contextStore
        )
    }

    private func prepared(_ descriptor: E2EEV2CallSessionDescriptor) -> E2EEV2CallRequestPreparation {
        .prepared(.init(
            version: E2EEV2CallBridge.version, provider: E2EEV2CallBridge.provider, epochId: descriptor.epochId,
            epochNumber: descriptor.epochNumber, keyCommitmentB64: descriptor.keyCommitmentB64
        ))
    }

    /// Le miroir de l'époque 1 réécrit avec une autre clé, cohérent en lui-même.
    private func forgeMirror(_ call: Call, key: Data) throws {
        let mirrored = try XCTUnwrap(call.contextStore.conversation(call.seeded.conversationId))
        let current = try XCTUnwrap(mirrored.epochs.first)
        try call.contextStore.saveConversationContractPreview(.init(
            version: mirrored.version, conversationId: mirrored.conversationId, ownerScopeId: mirrored.ownerScopeId,
            sessionId: mirrored.sessionId, writtenAtMs: mirrored.writtenAtMs,
            epochs: [.init(epochNumber: 1, keyB64: key.base64EncodedString(), memberIds: current.memberIds, replacedAtMs: nil)],
            latestMemberIds: mirrored.latestMemberIds, departures: mirrored.departures, counters: mirrored.counters,
            signingKeys: mirrored.signingKeys
        ), now: Date())
    }

    func testUnlockedTheCallTakesTheKeyFromTheVault() throws {
        let call = try makeCall(privacy: nil)
        defer { call.fixture.close() }
        XCTAssertEqual(prepare(call), prepared(call.descriptor))
    }

    func testLockedWithFullPreviewsTheCallJoinsWithTheMirroredKey() throws {
        let call = try makeCall()
        defer { call.fixture.close() }
        call.vault.locked = true
        XCTAssertEqual(prepare(call), prepared(call.descriptor))
        guard case .ready(let material) = resolve(call) else { return XCTFail("Clé du miroir attendue") }
        material.consume { key, context in
            XCTAssertEqual(key, call.seeded.epochKey)
            XCTAssertEqual(context, .init(conversationId: call.seeded.conversationId, epochNumber: 1, callId: callId))
        }
    }

    func testLockedWithoutPreviewKeysTheCallWaitsForTheUnlock() throws {
        for privacy in [E2EEV2NotificationPrivacy.senderOnly, nil] {
            let call = try makeCall(privacy: privacy)
            defer { call.fixture.close() }
            call.vault.locked = true
            XCTAssertEqual(prepare(call), .deviceLocked, "Aperçu \(privacy?.rawValue ?? "absent")")
            guard case .blocked(.deviceLocked) = resolve(call) else { return XCTFail("Déverrouillage attendu") }
            call.vault.locked = false
            XCTAssertEqual(prepare(call), prepared(call.descriptor), "Au déverrouillage, l'appel se rejoint")
        }
    }

    /// L'extension peut écrire le miroir : une clé cohérente en elle-même, mais
    /// qui ne tient pas l'engagement épinglé par l'app, n'est jamais prise.
    func testAMirroredKeyThatDoesNotMatchTheAppPinIsNeverUsed() throws {
        let call = try makeCall()
        defer { call.fixture.close() }
        let forged = Data(repeating: 7, count: 32)
        try forgeMirror(call, key: forged)
        call.vault.locked = true
        XCTAssertEqual(prepare(call), .deviceLocked)
        XCTAssertEqual(prepare(call, descriptor: descriptor(epochNumber: 1, epochKey: forged)), .deviceLocked,
                       "Même avec un descripteur qui s'accorde à la clé du miroir")
    }

    /// Époque gardée avant l'épingle : rien à vérifier, on attend le déverrouillage.
    func testAnEpochKeptBeforeThePinWaitsForTheUnlock() throws {
        let call = try makeCall()
        defer { call.fixture.close() }
        let epochTwo = Data(repeating: 0x42, count: 32)
        XCTAssertTrue(try call.fixture.keys.put(
            recordInput: .init(
                conversationId: call.seeded.conversationId, epochId: "epoch_seeded_000000000002", epochNumber: 2,
                keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(epochTwo)
            ),
            epochKey: epochTwo, ownerNamespace: call.fixture.session.ownerNamespace, expectedSession: call.fixture.session
        ))
        let current = call.seeded.current
        try call.fixture.states.recordCurrentEpoch(.init(
            conversationId: current.conversationId, epochNumber: 2, membershipChangeNumber: current.membershipChangeNumber,
            memberIds: current.memberIds, recipientsDigest: current.recipientsDigest, excludesWeb: current.excludesWeb,
            createdAtMs: current.createdAtMs + 1_000, acceptedAtMs: current.acceptedAtMs + 1_000
        ), ownerNamespace: call.fixture.session.ownerNamespace)
        try writeMirror(fixture: call.fixture, seeded: call.seeded, devices: call.devices, contextStore: call.contextStore)
        call.vault.locked = true
        XCTAssertEqual(prepare(call, descriptor: descriptor(epochNumber: 2, epochKey: epochTwo)), .deviceLocked)
    }

    /// L'époque courante a avancé, le miroir pas encore : jamais l'ancienne clé.
    func testAStaleMirrorIsNeverUsed() throws {
        let call = try makeCall()
        defer { call.fixture.close() }
        let epochTwo = Data(repeating: 0x42, count: 32)
        try call.fixture.advance(call.seeded, to: 2, epochKey: epochTwo)
        call.vault.locked = true
        XCTAssertEqual(prepare(call, descriptor: descriptor(epochNumber: 2, epochKey: epochTwo)), .deviceLocked)
    }

    func testOnlyFullPreviewsChosenOnTheDeviceAllowTheMirror() throws {
        let call = try makeCall()
        defer { call.fixture.close() }
        call.vault.locked = true
        func load(_ privacy: E2EEV2NotificationPrivacy) -> E2EEV2StoredEpochKey? {
            E2EEV2VerifiedEpochKeys.exactWhileLocked(
                conversationId: call.seeded.conversationId, epochNumber: 1, session: call.fixture.session,
                stateStore: call.fixture.states, contextStore: call.contextStore, privacy: { _ in privacy }
            )
        }
        XCTAssertEqual(load(.full)?.epochKey, call.seeded.epochKey)
        XCTAssertNil(load(.senderOnly), "Le réglage de l'app prime sur celui écrit dans le miroir")
        XCTAssertNil(load(.hidden))
    }

    func testTheMirrorOfAnotherSessionOrAccountIsNeverUsed() throws {
        let call = try makeCall(privacy: nil)
        defer { call.fixture.close() }
        let writer = E2EEV2NotificationMirrorWriter(
            keyStore: call.fixture.keys, stateStore: call.fixture.states, ledgerStore: try ledgerStore(),
            contextStore: call.contextStore
        )
        let foreignContexts = [
            notificationContext(call.fixture, privacy: .full, sessionId: UUID().uuidString.lowercased()),
            notificationContext(call.fixture, privacy: .full, ownerScopeId: PushOwnerScope.id(for: "account_other_00000000000001")),
        ]
        for foreign in foreignContexts {
            try call.contextStore.saveContractPreview(foreign, now: Date())
            let entry = try XCTUnwrap(writer.entry(
                conversationId: call.seeded.conversationId, devices: call.devices,
                latestMemberIds: [call.fixture.user, bruno], context: foreign, session: call.fixture.session
            ))
            try call.contextStore.saveConversationContractPreview(entry, now: Date())
            call.vault.locked = true
            XCTAssertEqual(prepare(call), .deviceLocked)
            call.vault.locked = false
        }
    }

    /// Une autre erreur du trousseau n'est pas « verrouillé » : pas d'attente.
    func testAnotherKeychainFailureIsNotTakenForTheLock() throws {
        let call = try makeCall()
        defer { call.fixture.close() }
        call.vault.failure = errSecIO
        XCTAssertEqual(prepare(call), .localEpochUnavailable)
    }

    /// Un appel d'une autre époque que la courante : refusé, verrouillé ou non.
    func testACallOfAnotherEpochIsRefusedEvenLocked() throws {
        let older = try makeCall()
        defer { older.fixture.close() }
        try older.fixture.advance(older.seeded, to: 2, epochKey: Data(repeating: 0x42, count: 32))
        older.vault.locked = true
        XCTAssertEqual(prepare(older), .localEpochUnavailable)
    }

    /// Une époque gardée avant l'épingle se relit : les champs manquent, sans erreur.
    func testAnEpochRecordWithoutThePinStillDecodes() throws {
        let old = #"{"conversationId":"conv_v2_000000000000001","epochNumber":3,"membershipChangeNumber":2,"memberIds":["a"],"recipientsDigest":"d","excludesWeb":false,"createdAtMs":1,"acceptedAtMs":2}"#
        let epoch = try JSONDecoder().decode(E2EEV2ConversationStateStore.CurrentEpoch.self, from: Data(old.utf8))
        XCTAssertEqual(epoch.epochNumber, 3)
        XCTAssertNil(epoch.epochId)
        XCTAssertNil(epoch.keyCommitmentB64)
    }

    private func notificationContext(
        _ fixture: E2EEV2AccountFixture,
        privacy: E2EEV2NotificationPrivacy,
        sessionId: String? = nil,
        ownerScopeId: String? = nil
    ) -> E2EEV2NotificationContext {
        .init(
            version: E2EEV2NotificationContext.currentVersion, revisionId: UUID().uuidString.lowercased(),
            ownerScopeId: ownerScopeId ?? PushOwnerScope.id(for: fixture.user), sessionId: sessionId ?? fixture.session.sessionId,
            authToken: "fixture.jwt.signature", expiresAtMs: Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000),
            deviceId: fixture.descriptor.deviceId, privacy: privacy, senderNames: [:]
        )
    }

    private func ledgerStore() throws -> E2EEV2MessageLedgerStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("locked-call-" + UUID().uuidString, isDirectory: true)
        directories.append(directory)
        return try E2EEV2MessageLedgerStore(baseDirectory: directory)
    }
}
