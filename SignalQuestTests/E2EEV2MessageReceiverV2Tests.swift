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
        let results = receiver.receive([message], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId)
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
        let page = receiver.receive([first, first], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner)
        XCTAssertEqual(page.count, 2)
        guard case .received = page[0] else { return XCTFail("Premier vu : \(page[0])") }
        XCTAssertEqual(page[1], .duplicate, "La même enveloppe, une seule fois")

        // Même identité, autre charge signée : équivoque, plus rien d'affiché.
        let twin = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, text: "Rendez-vous à 10 h", sequence: 2)
        XCTAssertEqual(receiver.receive([twin], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner), [.equivocation([ref])])
        XCTAssertEqual(receiver.receive([first], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner), [.equivocation([ref])],
                       "L'original reste masqué")

        // Même compteur sous une autre identité : les deux sont masqués.
        let second = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000002", counter: 2, text: "Ça marche", sequence: 3)
        guard case .received = receiver.receive([second], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner).first
        else { return XCTFail("Deuxième message") }
        let reused = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000003", counter: 2, text: "Autre chose", sequence: 4)
        let secondRef = E2EEV2MessageRef.make(conversationId: seeded.conversationId, senderDeviceId: phone.device.deviceId, clientRequestId: "message_bruno_0000000002")
        let reusedRef = E2EEV2MessageRef.make(conversationId: seeded.conversationId, senderDeviceId: phone.device.deviceId, clientRequestId: "message_bruno_0000000003")
        XCTAssertEqual(receiver.receive([reused], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner),
                       [.equivocation([secondRef, reusedRef])])
    }

    func testAReencryptedCopyIsADuplicateNotAnEquivocation() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let epochTwo = Data((0..<32).map { UInt8(0x40 + $0) })
        try fixture.advance(seeded, to: 2, epochKey: epochTwo)
        let receiver = try makeReceiver(fixture)
        let owner = fixture.session.ownerScopeId
        // Même charge et même fk : la version refusée et sa version rechiffrée.
        let fk = Data(repeating: 0x5A, count: 32), sentAt = Int64(Date().timeIntervalSince1970 * 1_000)
        let stale = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, sentAtMs: sentAt, fk: fk)
        let fresh = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, epochNumber: 2, epochKey: epochTwo, sequence: 2, sentAtMs: sentAt, fk: fk)
        let results = receiver.receive([stale, fresh], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner)
        guard case .received = results.first else { return XCTFail("Première version : \(results)") }
        XCTAssertEqual(results.last, .duplicate, "Même frankTag, donc même charge : un doublon")
    }

    func testNothingIsKeptWhenTheMessagesCannotBeStored() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let receiver = try makeReceiver(fixture)
        let owner = fixture.session.ownerScopeId
        let message = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1)
        let failed = receiver.receive([message], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner) { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }
        XCTAssertEqual(failed, [.retryLater("e2ee-ledger-unavailable")])
        var kept: [E2EEV2ReceivedMessageV2] = []
        let again = receiver.receive([message], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner) { received, _ in
            kept = received
        }
        guard case .received = again.first else { return XCTFail("Le registre n'a rien retenu : la page se relit") }
        XCTAssertEqual(kept.count, 1)
    }

    func testOwnCountersSeenInTheListRaiseTheSendCounter() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let receiver = try makeReceiver(fixture)
        let namespace = fixture.session.ownerNamespace
        // Un message de cet appareil, compteur 7 : une sauvegarde restaurée avait fait reculer le compteur local.
        let own = try ownMessage(fixture, seeded: seeded, counter: 7)
        guard case .received = receiver.receive([own], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId).first
        else { return XCTFail("Son propre message se relit") }
        XCTAssertEqual(try fixture.states.reserveSendCounter(conversationId: seeded.conversationId, deviceId: fixture.descriptor.deviceId, ownerNamespace: namespace), 8)
    }

    func testAnAuthenticUnknownKindCountsWithoutBeingInterpreted() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let ledgers = try ledgerStore()
        let receiver = try makeReceiver(fixture, ledgers: ledgers)
        let owner = fixture.session.ownerScopeId
        let poll = Data(#"{"body":{},"counter":"2","kind":"POLL","mentions":[],"replyToRef":null,"schema":"signalquest.e2ee-content","sentAtMs":"1790000000000","version":"2"}"#.utf8)
        let first = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1)
        let unknown = try raw(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000002", counter: 2, payload: poll, sequence: 2)
        let third = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000003", counter: 3, sequence: 3)
        let results = receiver.receive([first, unknown, third], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner)
        XCTAssertEqual(results[1], .unsupported(
            messageRef: E2EEV2MessageRef.make(conversationId: seeded.conversationId, senderDeviceId: phone.device.deviceId, clientRequestId: "message_bruno_0000000002"),
            senderUserId: bruno
        ), "« Contenu non pris en charge »")
        let missing = try ledgers.update(conversationId: seeded.conversationId, ownerScopeId: owner) { $0.missingCount(deviceId: phone.device.deviceId) }
        XCTAssertEqual(missing, 0, "Son compteur est compté : aucun faux trou")
    }

    func testAnUnsignedMessageWithAFarEpochObligesNothing() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let receiver = try makeReceiver(fixture)
        let junk = try delivered(
            from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, epochNumber: 99,
            epochKey: Data(repeating: 9, count: 32), signer: P256.Signing.PrivateKey()
        )
        XCTAssertEqual(receiver.receive([junk], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId),
                       [.rejected("invalid-e2ee-message-signature")], "Pas de synchronisation pour un message non signé")
    }

    func testAMemberWhoLeftIsAcceptedOnlyWhileInFlight() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let namespace = fixture.session.ownerNamespace
        let owner = fixture.session.ownerScopeId
        // Bruno part ; l'époque courante n'a pas encore tourné.
        let chain = try fixture.states.membershipChain(conversationId: seeded.conversationId, ownerNamespace: namespace)
        let leave = E2EEV2MembershipChange(
            conversationId: seeded.conversationId, changeNumber: chain.count + 1, action: "LEAVE", targetUserId: bruno,
            actorUserId: bruno, actorDeviceId: phone.device.deviceId,
            previousChangeDigest: E2EEV2MembershipChange.digest(of: try XCTUnwrap(chain.last?.canonical)), createdAtMs: 1_790_000_000_000
        )
        let leftAt = Int64(Date().timeIntervalSince1970 * 1_000)
        try fixture.states.appendMembership(
            [try E2EEV2SignedString.sign(leave.canonical, with: phone.signing)], conversationId: seeded.conversationId,
            ownerNamespace: namespace, nowMs: leftAt
        )
        let inFlight = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1)
        guard case .received = try makeReceiver(fixture, nowMs: leftAt + 60_000)
            .receive([inFlight], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner).first
        else { return XCTFail("En vol depuis une minute") }
        let later = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000002", counter: 2, sequence: 2)
        XCTAssertEqual(try makeReceiver(fixture, nowMs: leftAt + 25 * 60 * 60 * 1_000)
            .receive([later], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner),
                       [.rejected("e2ee-sender-departed")], "Plus de 24 heures après son départ, même sous l'époque courante")
    }

    func testTheServerClockNeitherShortensNorExtendsAnEphemeralMessage() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let receiver = try makeReceiver(fixture, nowMs: nowMs)
        let message = try delivered(
            from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, ttl: 60,
            sentAtMs: nowMs - 1_000, serverTimeMs: 0
        )
        guard case .received(let received)? = receiver.receive([message], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId).first
        else { return XCTFail("Une heure du serveur à zéro n'efface rien") }
        XCTAssertEqual(received.expiresAtMs, nowMs - 1_000 + 60_000, "Heure signée de l'émetteur seule")
        XCTAssertThrowsError(try E2EEV2ContentPayloadV2.parse(try E2EEV2ContentPayloadV2(
            sentAtMs: E2EEV2Canonical.maxSafeInteger + 1, counter: 1, replyToRef: nil, mentions: [], body: .text("Futur")
        ).encoded()), "Instant au-delà de 2⁵³ − 1 refusé : aucune addition ne déborde")
    }

    func testIdentitiesAreKeptForLifeAndACorruptedLedgerStartsOver() throws {
        var ledger = E2EEV2MessageLedgerV2()
        let refs = (0...E2EEV2MessageLedgerV2.recentLimit).map {
            E2EEV2MessageRef.make(conversationId: "conversation_01J7ABCD23456789", senderDeviceId: "device_bruno_android_01J7ABCD", clientRequestId: "message_life_\($0)_0000")
        }
        for (index, ref) in refs.enumerated() {
            XCTAssertEqual(ledger.record(messageRef: ref, deviceId: "device_bruno_android_01J7ABCD", counter: index + 1, frankTagB64: "tag\(index)", epochNumber: 1), .accepted)
        }
        XCTAssertEqual(ledger.record(messageRef: refs[0], deviceId: "device_bruno_android_01J7ABCD", counter: 9_999, frankTagB64: "autre", epochNumber: 1), .replayed,
                       "Une identité oubliée des récentes n'est jamais réaffichée, même sous un compteur neuf")
        XCTAssertEqual(ledger.acceptedCount(epochNumber: 1), refs.count)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-" + UUID().uuidString, isDirectory: true)
        directories.append(directory)
        let store = try E2EEV2MessageLedgerStore(baseDirectory: directory)
        let owner = "user:" + String(repeating: "b", count: 64)
        _ = try store.update(conversationId: "conversation_01J7ABCD23456789", ownerScopeId: owner) {
            $0.record(messageRef: refs[0], deviceId: "device_bruno_android_01J7ABCD", counter: 1, frankTagB64: "tag0", epochNumber: 1)
        }
        let file = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: directory.path).first { $0.hasSuffix(".json") })
        try Data(#"{"counters":{"device_bruno_android_01J7ABCD":[[5]]},"recent":{},"order":[],"equivocal":[],"acceptedPerEpoch":{},"seenRefs":[]}"#.utf8)
            .write(to: directory.appendingPathComponent(file))
        let outcome = try store.update(conversationId: "conversation_01J7ABCD23456789", ownerScopeId: owner) {
            $0.record(messageRef: refs[1], deviceId: "device_bruno_android_01J7ABCD", counter: 2, frankTagB64: "tag1", epochNumber: 1)
        }
        XCTAssertEqual(outcome, .accepted, "Un registre incohérent repart de zéro, sans planter ni bloquer")
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
        _ = receiver.receive(messages, conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner)
        func missing() throws -> Int {
            try ledgers.update(conversationId: seeded.conversationId, ownerScopeId: owner) { $0.missingCount(deviceId: phone.device.deviceId) }
        }
        XCTAssertEqual(try missing(), 1, "Le 6 manque ; avant le 5, rien : Bruno a pu écrire avant notre arrivée")
        let late = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000006", counter: 6, sequence: 9)
        guard case .received = receiver.receive([late], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner).first
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
            receiver.receive([message], conversationId: seeded.conversationId, isGroup: false, devices: set ?? devices, expectedOwnerScopeId: owner).first
        }
        let message = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1)
        XCTAssertEqual(receive(message, devices: fixture.deviceSet(adding: [])), .retryLater("e2ee-sender-not-certified"), "Appareil révoqué ou inconnu")
        XCTAssertEqual(receive(try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1, senderUserId: fixture.user)),
                       .retryLater("e2ee-sender-not-certified"), "Appareil de Bruno annoncé comme le mien")
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
        XCTAssertEqual(try makeReceiver(fixture).receive([ahead], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner),
                       [.needsEpoch], "Époque pas encore connue")

        try fixture.advance(seeded, to: 2, epochKey: epochTwo)
        let replacedAt = seeded.current.acceptedAtMs + 1_000
        let inFlight = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000001", counter: 1)
        let soon = try makeReceiver(fixture, nowMs: replacedAt + 60 * 60 * 1_000)
        guard case .received = soon.receive([inFlight], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner).first
        else { return XCTFail("Message en vol sous l'époque remplacée depuis une heure") }
        let late = try makeReceiver(fixture, nowMs: replacedAt + 25 * 60 * 60 * 1_000)
        let stale = try delivered(from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000003", counter: 3)
        XCTAssertEqual(late.receive([stale], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner),
                       [.rejected("e2ee-epoch-replaced")], "Plus de 24 heures après son remplacement")
        guard case .received = late.receive([ahead], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner).first
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
        guard case .received(let message)? = receiver.receive([fresh], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner).first
        else { return XCTFail("Encore dans sa minute") }
        XCTAssertEqual(message.expiresAtMs, nowMs - 10_000 + 60_000)
        // Le serveur annonce une heure plus tardive : l'heure de l'émetteur l'emporte.
        let old = try delivered(
            from: phone, seeded: seeded, clientRequestId: "message_bruno_0000000002", counter: 2, ttl: 60,
            sentAtMs: nowMs - 120_000, serverTimeMs: nowMs
        )
        XCTAssertEqual(receiver.receive([old], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner), [.expired])
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
        _ = receiver.receive([message], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner)
        XCTAssertEqual(receiver.receive([message], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner), [.duplicate])
        try ledgers.purge(ownerScopeId: owner)
        guard case .received = receiver.receive([message], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: owner).first
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
        guard case .received(let received)? = receiver.receive([edit], conversationId: seeded.conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId).first
        else { return XCTFail("Édition reçue") }
        XCTAssertTrue(E2EEV2MessageAuthorization.allows(received, targetAuthorUserId: bruno), "Son propre message, depuis n'importe lequel de ses appareils")
        XCTAssertFalse(E2EEV2MessageAuthorization.allows(received, targetAuthorUserId: fixture.user), "Le message d'un autre")
        XCTAssertFalse(E2EEV2MessageAuthorization.allows(received, targetAuthorUserId: nil), "Cible inconnue")
    }

    // MARK: Aides

    /// Un message de cet appareil, signé par son coffre, tel que la liste le rend.
    private func ownMessage(_ fixture: E2EEV2AccountFixture, seeded: E2EEV2SeededConversation, counter: Int64) throws -> E2EEV2DeliveredMessageV2 {
        let clientRequestId = "message_own_00000000\(counter)"
        let payload = try E2EEV2ContentPayloadV2(
            sentAtMs: Int64(Date().timeIntervalSince1970 * 1_000), counter: counter, replyToRef: nil, mentions: [], body: .text("Moi")
        ).encoded()
        let signed = try E2EEV2MessageComposerV2.compose(
            payload: payload, conversationId: seeded.conversationId, clientRequestId: clientRequestId, ttlSeconds: 0,
            epoch: E2EEV2StoredEpochKey(
                conversationId: seeded.conversationId, epochId: "epoch_test_00000000001", epochNumber: 1,
                keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(seeded.epochKey), epochKey: seeded.epochKey
            ),
            device: fixture.descriptor, fk: Data(repeating: 1, count: 32), nonce: Data(repeating: 2, count: 12), sign: fixture.signer()
        )
        return E2EEV2DeliveredMessageV2(
            envelopeId: "envelope_own_000000000\(counter)", sequence: counter, senderUserId: fixture.user,
            senderDeviceId: fixture.descriptor.deviceId, signed: signed,
            serverTagB64: Data(repeating: 9, count: 32).base64EncodedString(), serverTimeMs: Int64(Date().timeIntervalSince1970 * 1_000),
            keyId: "server_tag_key_01J7ABCD"
        )
    }

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
            identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states, ledgerStore: try ledgers ?? ledgerStore(),
            expectedSession: fixture.session, now: { clock ?? Date() }
        )
    }

    /// Une charge quelconque, chiffrée et signée par l'appareil distant : `compose` refuserait un `kind` inconnu.
    private func raw(
        from remote: E2EEV2TestRemote,
        seeded: E2EEV2SeededConversation,
        clientRequestId: String,
        counter: Int64,
        payload: Data,
        sequence: Int64
    ) throws -> E2EEV2DeliveredMessageV2 {
        let context = E2EEV2MessageContextV2(
            conversationId: seeded.conversationId, epochNumber: 1, senderDeviceId: remote.device.deviceId,
            clientRequestId: clientRequestId, counter: counter, ttlSeconds: 0, encryptedBlobIds: []
        )
        let envelope = try E2EEV2MessageCryptoV2.encrypt(
            payload: payload, fk: Data(repeating: 3, count: 32), epochKey: seeded.epochKey, nonce: Data(repeating: 4, count: 12), context: context
        )
        let signature = try E2EEV2LowS.sign(try E2EEV2MessageCryptoV2.signatureCanonical(context: context, envelope: envelope), with: remote.signing)
        return E2EEV2DeliveredMessageV2(
            envelopeId: "envelope_\(clientRequestId)", sequence: sequence, senderUserId: remote.device.userId,
            senderDeviceId: remote.device.deviceId,
            signed: E2EEV2SignedMessageEnvelopeV2(envelope: envelope, senderSignatureB64: signature.base64EncodedString()),
            serverTagB64: Data(repeating: 9, count: 32).base64EncodedString(), serverTimeMs: Int64(Date().timeIntervalSince1970 * 1_000),
            keyId: "server_tag_key_01J7ABCD"
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
        senderUserId: String? = nil,
        fk: Data? = nil
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
            device: device, fk: try fk ?? E2EEV2MessageComposerV2.randomBytes(32), nonce: E2EEV2MessageComposerV2.randomBytes(12),
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
