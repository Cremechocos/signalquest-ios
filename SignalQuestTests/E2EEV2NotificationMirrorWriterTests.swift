import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 5 (plan 3) : entrées du miroir de notification (§2.6), écrites par l'app.
final class E2EEV2NotificationMirrorWriterTests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD23456789"
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    /// Écritures du trousseau qui échouent à la demande.
    private final class SwitchableTokenStore: TokenStore, @unchecked Sendable {
        private let memory = InMemoryTokenStore()
        var failWrites = false
        func string(for key: String) throws -> String? { try memory.string(for: key) }
        func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws {
            if failWrites { throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
            try memory.set(value, for: key, accessibility: accessibility)
        }
        func remove(_ key: String) throws { try memory.remove(key) }
        func keys(withPrefix prefix: String) throws -> [String] { try memory.keys(withPrefix: prefix) }
        func removeAll() throws { try memory.removeAll() }
    }

    func testTheEntryHoldsVerifiedEpochKeysAndCertifiedPublicKeysOnly() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let epochTwo = Data(repeating: 0x42, count: 32)
        try fixture.advance(seeded, to: 2, epochKey: epochTwo)
        let ledger = try ledgerStore()
        try ledger.update(conversationId: seeded.conversationId, ownerScopeId: fixture.session.ownerScopeId) { ledger in
            _ = ledger.record(
                messageRef: E2EEV2MessageRef.make(
                    conversationId: seeded.conversationId, senderDeviceId: phone.device.deviceId, clientRequestId: "message_mirror_000001"
                ),
                deviceId: phone.device.deviceId, counter: 4, frankTagB64: Data(repeating: 1, count: 32).base64EncodedString(),
                epochNumber: 1
            )
        }
        let replacedAt = seeded.current.acceptedAtMs + 1_000
        let writer = E2EEV2NotificationMirrorWriter(
            keyStore: fixture.keys, stateStore: fixture.states, ledgerStore: ledger,
            contextStore: E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore()),
            now: { Date(timeIntervalSince1970: Double(replacedAt + 60_000) / 1_000) }
        )
        let context = notificationContext(fixture)
        let entry = try XCTUnwrap(writer.entry(
            conversationId: seeded.conversationId, devices: devices, latestMemberIds: [fixture.user, bruno],
            context: context, session: fixture.session
        ))
        XCTAssertTrue(entry.isStructurallyValid)
        XCTAssertEqual(entry.ownerScopeId, context.ownerScopeId)
        XCTAssertEqual(entry.sessionId, fixture.session.sessionId)
        XCTAssertEqual(entry.epochs.map(\.epochNumber), [2, 1], "La courante, puis celle remplacée depuis une minute")
        XCTAssertEqual(entry.epochs.first?.keyB64, epochTwo.base64EncodedString())
        XCTAssertNil(entry.epochs.first?.replacedAtMs)
        XCTAssertEqual(entry.epochs.last?.keyB64, seeded.epochKey.base64EncodedString())
        XCTAssertEqual(Set(entry.epochs.last?.memberIds ?? []), [fixture.user, bruno])
        XCTAssertEqual(entry.latestMemberIds, [fixture.user, bruno].sorted())
        XCTAssertEqual(entry.counters, [phone.device.deviceId: 4], "Ce que l'app a reçu ne s'affichera plus")
        XCTAssertEqual(entry.signingKeys[E2EEV2NotificationConversation.signingKeyName(userId: bruno, deviceId: phone.device.deviceId)],
                       phone.device.signingKeyB64)
        XCTAssertEqual(entry.signingKeys[E2EEV2NotificationConversation.signingKeyName(userId: fixture.user, deviceId: fixture.descriptor.deviceId)],
                       fixture.descriptor.publicSigningKeyB64, "Ses propres autres appareils aussi")

        let senderOnly = try XCTUnwrap(writer.entry(
            conversationId: seeded.conversationId, devices: devices, latestMemberIds: [fixture.user, bruno],
            context: notificationContext(fixture, privacy: .senderOnly), session: fixture.session
        ))
        XCTAssertTrue(senderOnly.isStructurallyValid)
        XCTAssertTrue(senderOnly.epochs.allSatisfy { $0.keyB64 == nil }, "Expéditeur seulement : aucune clé d'époque")

        let later = E2EEV2NotificationMirrorWriter(
            keyStore: fixture.keys, stateStore: fixture.states, ledgerStore: ledger,
            contextStore: E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore()),
            now: { Date(timeIntervalSince1970: Double(replacedAt + 25 * 3_600_000) / 1_000) }
        )
        let next = try XCTUnwrap(later.entry(
            conversationId: seeded.conversationId, devices: devices, latestMemberIds: [fixture.user, bruno],
            context: context, session: fixture.session
        ))
        XCTAssertEqual(next.epochs.map(\.epochNumber), [2], "Remplacée depuis plus de 24 heures : sa clé quitte le miroir")
    }

    func testTheMirrorIsWrittenOnlyForThisSessionAndLeavesOnFailure() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let tokens = SwitchableTokenStore()
        let contextStore = E2EEV2NotificationContextStore(tokenStore: tokens)
        var writer = E2EEV2NotificationMirrorWriter(
            keyStore: fixture.keys, stateStore: fixture.states, ledgerStore: try ledgerStore(), contextStore: contextStore
        )
        let members: Set<String> = [fixture.user, bruno]
        let update = { (writer: E2EEV2NotificationMirrorWriter) in
            writer.update(
                conversationId: seeded.conversationId, devices: devices, latestMemberIds: members, session: fixture.session,
                generation: writer.invalidate(seeded.conversationId)
            )
        }
        XCTAssertFalse(update(writer), "Verrou fermé : rien")
        writer.contractPreview = true
        XCTAssertFalse(update(writer), "Aucun contexte actif : rien")
        XCTAssertTrue(try tokens.keys(withPrefix: "").isEmpty, "Aucune clé d'époque dans le groupe partagé")

        let other = notificationContext(fixture, sessionId: UUID().uuidString.lowercased())
        try contextStore.saveContractPreview(other, now: Date())
        XCTAssertFalse(update(writer), "Contexte d'une autre session : rien")
        XCTAssertTrue(try tokens.keys(withPrefix: "notification-conversation-v1:").isEmpty)

        try contextStore.saveContractPreview(notificationContext(fixture), now: Date())
        XCTAssertTrue(update(writer))
        XCTAssertEqual(try contextStore.conversation(seeded.conversationId)?.sessionId, fixture.session.sessionId)

        tokens.failWrites = true
        XCTAssertFalse(update(writer))
        tokens.failWrites = false
        XCTAssertNil(try contextStore.conversation(seeded.conversationId), "Plutôt aucune entrée qu'une entrée périmée")
    }

    func testAnOlderOperationNeverRewritesOverANewerOne() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let contextStore = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        try contextStore.saveContractPreview(notificationContext(fixture), now: Date())
        let writer = E2EEV2NotificationMirrorWriter(
            keyStore: fixture.keys, stateStore: fixture.states, ledgerStore: try ledgerStore(), contextStore: contextStore,
            contractPreview: true
        )
        let older = writer.invalidate(seeded.conversationId)
        let newer = writer.invalidate(seeded.conversationId)
        let write = { (generation: UInt64) in
            writer.update(
                conversationId: seeded.conversationId, devices: devices, latestMemberIds: [fixture.user, self.bruno],
                session: fixture.session, generation: generation
            )
        }
        XCTAssertFalse(write(older), "Commencée avant la plus récente : rien")
        XCTAssertNil(try contextStore.conversation(seeded.conversationId))
        XCTAssertTrue(write(newer))
        XCTAssertNotNil(try contextStore.conversation(seeded.conversationId))
    }

    func testNoEntryWithoutAReadableLedger() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let contextStore = E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore())
        try contextStore.saveContractPreview(notificationContext(fixture), now: Date())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-" + UUID().uuidString, isDirectory: true)
        directories.append(directory)
        let hex = { (value: String) in SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
        let folder = directory.appendingPathComponent(hex(fixture.session.ownerScopeId), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("illisible".utf8).write(to: folder.appendingPathComponent(hex(seeded.conversationId) + ".json"))
        let writer = E2EEV2NotificationMirrorWriter(
            keyStore: fixture.keys, stateStore: fixture.states,
            ledgerStore: try E2EEV2MessageLedgerStore(baseDirectory: directory), contextStore: contextStore, contractPreview: true
        )
        XCTAssertFalse(writer.update(
            conversationId: seeded.conversationId, devices: devices, latestMemberIds: [fixture.user, bruno],
            session: fixture.session, generation: writer.invalidate(seeded.conversationId)
        ), "Registre illisible : pas de plancher, pas d'entrée")
        XCTAssertNil(try contextStore.conversation(seeded.conversationId))
    }

    private func notificationContext(
        _ fixture: E2EEV2AccountFixture,
        privacy: E2EEV2NotificationPrivacy = .full,
        sessionId: String? = nil
    ) -> E2EEV2NotificationContext {
        .init(
            version: E2EEV2NotificationContext.currentVersion, revisionId: UUID().uuidString.lowercased(),
            ownerScopeId: PushOwnerScope.id(for: fixture.user), sessionId: sessionId ?? fixture.session.sessionId,
            authToken: "fixture.jwt.signature", expiresAtMs: Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000),
            deviceId: fixture.descriptor.deviceId, privacy: privacy, senderNames: [:]
        )
    }

    private func ledgerStore() throws -> E2EEV2MessageLedgerStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-" + UUID().uuidString, isDirectory: true)
        directories.append(directory)
        return try E2EEV2MessageLedgerStore(baseDirectory: directory)
    }
}
