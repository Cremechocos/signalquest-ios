import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 5 (plan 3) : réception des messages texte v2 (§3.4, §4.2, §4.3, D.7).
final class E2EEV2MessageReceiverV2Tests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD23456789"
    private let carol = "user_carol_01J7ABCD23456789"
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    func testReceivesAMessageFromACertifiedMember() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let receiver = try makeReceiver(fixture)
        let message = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, text: "Salut !")
        let results = receiver.receive([message], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId)
        guard case .received(let received)? = results.first else { return XCTFail("Message refusé : \(results)") }
        XCTAssertEqual(received.payload.body, .text("Salut !"))
        XCTAssertEqual(received.senderUserId, bruno)
        XCTAssertEqual(received.messageRef, E2EEV2MessageRef.make(
            conversationId: seeded.conversationId, senderDeviceId: phone.device.deviceId, clientRequestId: "message_bruno_0000000001"
        ))
        XCTAssertEqual(received.fk.count, 32, "Gardée pour le signalement")
        XCTAssertEqual(E2EEV2Franking.frankTag(
            fk: received.fk, conversationId: seeded.conversationId, senderDeviceId: phone.device.deviceId,
            clientRequestId: received.clientRequestId, payload: received.payloadBytes
        ).base64EncodedString(), received.frankTagB64)
        XCTAssertEqual(received.serverTagB64, message.serverTagB64)
        XCTAssertNil(received.expiresAtMs)
    }

    func testDuplicatesAreIgnoredAndEquivocationsHidden() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let receiver = try makeReceiver(fixture)
        let owner = fixture.session.ownerScopeId
        let first = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, text: "Rendez-vous à 8 h")
        let ref = E2EEV2MessageRef.make(conversationId: seeded.conversationId, senderDeviceId: phone.device.deviceId, clientRequestId: "message_bruno_0000000001")
        let page = receiver.receive([first, first], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner)
        XCTAssertEqual(page.count, 2)
        guard case .received = page[0] else { return XCTFail("Premier vu : \(page[0])") }
        XCTAssertEqual(page[1], .duplicate, "La même enveloppe, une seule fois")

        // Même identité, autre charge signée : équivoque, plus rien d'affiché.
        let twin = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, text: "Rendez-vous à 10 h", sequence: 2)
        XCTAssertEqual(receiver.receive([twin], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner), [.equivocation([ref])])
        XCTAssertEqual(receiver.receive([first], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner), [.equivocation([ref])],
                       "L'original reste masqué")

        // Même compteur sous une autre identité : les deux sont masqués.
        let second = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000002", counter: 2, text: "Ça marche", sequence: 3)
        guard case .received = receiver.receive([second], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner).first
        else { return XCTFail("Deuxième message") }
        let reused = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000003", counter: 2, text: "Autre chose", sequence: 4)
        let secondRef = E2EEV2MessageRef.make(conversationId: seeded.conversationId, senderDeviceId: phone.device.deviceId, clientRequestId: "message_bruno_0000000002")
        let reusedRef = E2EEV2MessageRef.make(conversationId: seeded.conversationId, senderDeviceId: phone.device.deviceId, clientRequestId: "message_bruno_0000000003")
        XCTAssertEqual(receiver.receive([reused], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner),
                       [.equivocation([secondRef, reusedRef])])
    }

    func testGapsAreCountedBetweenSeenCounters() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let ledgers = try ledgerStore()
        let receiver = try makeReceiver(fixture, ledgers: ledgers)
        let owner = fixture.session.ownerScopeId
        let messages = try [5, 7, 8].map {
            try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_000000000\($0)", counter: Int64($0), sequence: Int64($0))
        }
        _ = receiver.receive(messages, conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner)
        func missing() throws -> Int {
            try ledgers.update(conversationId: seeded.conversationId, ownerScopeId: owner) { $0.missingCount(deviceId: phone.device.deviceId) }
        }
        XCTAssertEqual(try missing(), 1, "Le 6 manque ; avant le 5, rien : Bruno a pu écrire avant notre arrivée")
        let late = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000006", counter: 6, sequence: 9)
        guard case .received = receiver.receive([late], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner).first
        else { return XCTFail("Le retardataire comble le trou") }
        XCTAssertEqual(try missing(), 0)
    }

    func testRejectsWhatCannotBeTrusted() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let carolPhone = E2EEV2TestRemote(user: carol, device: "device_carol_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device, carolPhone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: fixture.deviceSet(adding: [phone.device]))
        let receiver = try makeReceiver(fixture)
        let owner = fixture.session.ownerScopeId
        func receive(_ message: E2EEV2DeliveredMessageV2, devices set: E2EEV2CertifiedDeviceSet? = nil) -> E2EEV2MessageReceptionV2? {
            receiver.receive([message], conversationId: seeded.conversationId, devices: set ?? devices, expectedOwnerScopeId: owner).first
        }
        let message = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1)
        XCTAssertEqual(receive(message, devices: fixture.deviceSet(adding: [])), .rejected("e2ee-sender-not-certified"), "Appareil révoqué ou inconnu")
        XCTAssertEqual(receive(try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, senderUserId: fixture.user)),
                       .rejected("e2ee-sender-not-certified"), "Appareil de Bruno annoncé comme le mien")
        XCTAssertEqual(receive(try delivered(from: carolPhone, seeded: seeded, clientRequestId: "message_carol_0000000001", counter: 1)),
                       .rejected("e2ee-sender-not-member"), "Carol n'est pas membre")
        let forger = P256.Signing.PrivateKey()
        XCTAssertEqual(receive(try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, signer: forger)),
                       .rejected("invalid-e2ee-message-signature"), "Signature d'une autre clé")
        XCTAssertEqual(receive(try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, epochKey: Data(repeating: 1, count: 32))),
                       .rejected("invalid-e2ee-message"), "Chiffré sous une autre clé que celle de l'époque")
        guard case .received = receive(message) else { return XCTFail("Aucun refus n'entre au registre") }
    }

    func testEpochWindowAndUnknownEpochs() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let owner = fixture.session.ownerScopeId
        let epochTwo = Data((0..<32).map { UInt8(0x40 + $0) })
        let ahead = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000002", counter: 2, epochNumber: 2, epochKey: epochTwo)
        XCTAssertEqual(try makeReceiver(fixture).receive([ahead], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner),
                       [.needsEpoch], "Époque pas encore connue")

        try fixture.advance(seeded, to: 2, epochKey: epochTwo)
        let replacedAt = seeded.current.acceptedAtMs + 1_000
        let inFlight = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1)
        let soon = try makeReceiver(fixture, nowMs: replacedAt + 60 * 60 * 1_000)
        guard case .received = soon.receive([inFlight], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner).first
        else { return XCTFail("Message en vol sous l'époque remplacée depuis une heure") }
        let late = try makeReceiver(fixture, nowMs: replacedAt + 25 * 60 * 60 * 1_000)
        let stale = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000003", counter: 3)
        XCTAssertEqual(late.receive([stale], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner),
                       [.rejected("e2ee-epoch-replaced")], "Plus de 24 heures après son remplacement")
        guard case .received = late.receive([ahead], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner).first
        else { return XCTFail("Époque courante") }
    }

    func testEphemeralMessagesExpireFromTheEarlierClock() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let receiver = try makeReceiver(fixture, nowMs: nowMs)
        let owner = fixture.session.ownerScopeId
        let fresh = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, ttl: 60, sentAtMs: nowMs - 10_000)
        guard case .received(let message)? = receiver.receive([fresh], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner).first
        else { return XCTFail("Encore dans sa minute") }
        XCTAssertEqual(message.expiresAtMs, nowMs - 10_000 + 60_000)
        // Le serveur annonce une heure plus tardive : l'heure de l'émetteur l'emporte.
        let old = try delivered(
            from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000002", counter: 2, ttl: 60,
            sentAtMs: nowMs - 120_000, serverTimeMs: nowMs
        )
        XCTAssertEqual(receiver.receive([old], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner), [.expired])
    }

    func testTheLedgerIsErasedWithTheAccount() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let ledgers = try ledgerStore()
        let receiver = try makeReceiver(fixture, ledgers: ledgers)
        let owner = fixture.session.ownerScopeId
        let message = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1)
        _ = receiver.receive([message], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner)
        XCTAssertEqual(receiver.receive([message], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner), [.duplicate])
        try ledgers.purge(ownerScopeId: owner)
        guard case .received = receiver.receive([message], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: owner).first
        else { return XCTFail("Registre effacé avec le compte") }
    }

    func testOnlyTheAuthorMayEditOrDelete() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let receiver = try makeReceiver(fixture)
        let target = E2EEV2MessageRef.make(conversationId: seeded.conversationId, senderDeviceId: phone.device.deviceId, clientRequestId: "message_bruno_0000000001")
        let edit = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000002", counter: 2, body: .edit(targetRef: target, text: "Corrigé"))
        guard case .received(let received)? = receiver.receive([edit], conversationId: seeded.conversationId, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId).first
        else { return XCTFail("Édition reçue") }
        XCTAssertTrue(E2EEV2MessageAuthorization.allows(received, targetAuthorUserId: bruno), "Son propre message, depuis n'importe lequel de ses appareils")
        XCTAssertFalse(E2EEV2MessageAuthorization.allows(received, targetAuthorUserId: fixture.user), "Le message d'un autre")
        XCTAssertFalse(E2EEV2MessageAuthorization.allows(received, targetAuthorUserId: nil), "Cible inconnue")
    }

    // MARK: Aides

    private func ledgerStore() throws -> E2EEV2MessageLedgerStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-" + UUID().uuidString, isDirectory: true)
        directories.append(directory)
        return try E2EEV2MessageLedgerStore(baseDirectory: directory)
    }

    private func makeReceiver(
        _ fixture: E2EEV2AccountFixture,
        ledgers: E2EEV2MessageLedgerStore? = nil,
        nowMs: Int64? = nil
    ) throws -> E2EEV2MessageReceiverV2 {
        let clock = nowMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
        return E2EEV2MessageReceiverV2(
            keyStore: fixture.keys, stateStore: fixture.states, ledgerStore: try ledgers ?? ledgerStore(),
            expectedSession: fixture.session, now: { clock ?? Date() }
        )
    }

    /// Un message de l'appareil distant, tel que le serveur le remet.
    private func delivered(
        from remote: E2EEV2TestRemote,
        seeded: E2EEV2SeededConversation,
        clientRequestId: String,
        counter: Int64,
        text: String = "Salut",
        body: E2EEV2ContentPayloadV2.Body? = nil,
        epochNumber: Int = 1,
        epochKey: Data? = nil,
        ttl: Int = 0,
        sequence: Int64 = 1,
        sentAtMs: Int64? = nil,
        serverTimeMs: Int64? = nil,
        signer: P256.Signing.PrivateKey? = nil,
        senderUserId: String? = nil
    ) throws -> E2EEV2DeliveredMessageV2 {
        let key = epochKey ?? seeded.epochKey
        let signing = signer ?? remote.signing
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let payload = try E2EEV2ContentPayloadV2(
            sentAtMs: sentAtMs ?? nowMs, counter: counter, replyToRef: nil, mentions: [], body: body ?? .text(text)
        ).encoded()
        let device = E2EEV2DeviceDescriptor(
            deviceId: remote.device.deviceId, platform: remote.device.platform, label: nil,
            publicIdentityKeyB64: remote.device.identityKeyB64,
            publicSigningKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            identityKeyAlgorithm: "P256_ECDH", signingKeyAlgorithm: "P256_ECDSA_SHA256", keyVersion: 1
        )
        let signed = try E2EEV2MessageComposerV2.compose(
            payload: payload, conversationId: seeded.conversationId, clientRequestId: clientRequestId, ttlSeconds: ttl,
            epoch: E2EEV2StoredEpochKey(
                conversationId: seeded.conversationId, epochId: "epoch_test_0000000000\(epochNumber)", epochNumber: epochNumber,
                keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(key), epochKey: key
            ),
            device: device, fk: E2EEV2MessageComposerV2.randomBytes(32), nonce: E2EEV2MessageComposerV2.randomBytes(12),
            sign: { try E2EEV2LowS.sign($0, with: signing) }
        )
        return E2EEV2DeliveredMessageV2(
            envelopeId: "envelope_\(clientRequestId)", sequence: sequence, senderUserId: senderUserId ?? remote.device.userId,
            senderDeviceId: remote.device.deviceId, signed: signed,
            serverTagB64: Data(repeating: 9, count: 32).base64EncodedString(), serverTimeMs: serverTimeMs ?? nowMs,
            keyId: "server_tag_key_01J7ABCD"
        )
    }
}
