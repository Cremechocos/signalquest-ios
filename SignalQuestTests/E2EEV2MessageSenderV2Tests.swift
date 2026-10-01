import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 5 (plan 3) : envoi d'un message texte v2 (§4, D.7, E.3) et format de
/// transport de l'enveloppe.
final class E2EEV2MessageSenderV2Tests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD23456789"
    private let tagKeyId = "server_tag_key_01J7ABCD"

    // MARK: Envoi

    func testSendsASignedV2EnvelopeThatTheMembersCanOpen() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let requests = LockedRequests()
        let bodies = Bodies()
        MockURLProtocol.requestHandler = { [tagKeyId] request in
            let raw = E2EEV2AccountFixture.rawBody(request)
            _ = bodies.append(raw)
            requests.append(request, body: [:])
            let signed = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(raw))
            return E2EEV2AccountFixture.response(request, Self.receipt(signed.envelope.clientRequestId, keyId: tagKeyId))
        }
        let sender = E2EEV2MessageSenderV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let first = await sender.send(
            draft("Salut Bruno"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
            membership: seeded.membership, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        let ref = E2EEV2MessageRef.make(
            conversationId: seeded.conversationId, senderDeviceId: fixture.descriptor.deviceId, clientRequestId: "message_01J7ABCD00000001"
        )
        guard case .sent(let receipt, let messageRef) = first else { return XCTFail("Envoi refusé : \(first)") }
        XCTAssertEqual(messageRef, ref)
        XCTAssertEqual(receipt.keyId, tagKeyId)
        XCTAssertEqual(requests.first?.0.url?.path, "/api/e2ee/v2/conversations/\(seeded.conversationId)/messages")
        XCTAssertEqual(requests.first?.0.httpMethod, "POST")

        // Ce que Bruno reçoit s'ouvre : signature, déchiffrement, franking, compteur.
        let signed = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(try XCTUnwrap(bodies.all.first)))
        XCTAssertEqual(signed.encoded, bodies.all.first, "JSON canonique, à l'octet")
        let context = signed.context(conversationId: seeded.conversationId, senderDeviceId: fixture.descriptor.deviceId)
        let ownKey = try P256.Signing.PublicKey(x963Representation: XCTUnwrap(Data(base64Encoded: fixture.descriptor.publicSigningKeyB64)))
        try E2EEV2MessageCryptoV2.verifySignature(context: context, envelope: signed.envelope, signatureDerB64: signed.senderSignatureB64, senderSigningKey: ownKey)
        let opened = try E2EEV2MessageCryptoV2.decrypt(envelope: signed.envelope, epochKey: seeded.epochKey, context: context)
        XCTAssertEqual(opened.payload.body, .text("Salut Bruno"))
        XCTAssertEqual(opened.payload.counter, 1)
        XCTAssertEqual(signed.envelope.epochNumber, 1)
        XCTAssertNil(try fixture.states.pendingSend(
            conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001", ownerNamespace: fixture.session.ownerNamespace
        ), "Rien n'est gardé après l'accusé")

        // Le message suivant prend le compteur suivant.
        _ = await sender.send(
            draft("Tu es là ?"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000002",
            membership: seeded.membership, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        let second = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(try XCTUnwrap(bodies.all.last)))
        XCTAssertEqual(second.envelope.counter, 2)
    }

    func testARetryResendsTheSameBytesAndKeepsItsCounter() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let bodies = Bodies()
        MockURLProtocol.requestHandler = { request in
            if bodies.append(E2EEV2AccountFixture.rawBody(request)) == 1 { throw URLError(.networkConnectionLost) }
            return E2EEV2AccountFixture.response(request, Self.receipt("message_01J7ABCD00000001"))
        }
        let sender = E2EEV2MessageSenderV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let failed = await sender.send(
            draft("Premier essai"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
            membership: seeded.membership, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        guard case .failure = failed else { return XCTFail("La coupure réseau doit échouer : \(failed)") }
        XCTAssertNotNil(try fixture.states.pendingSend(
            conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001", ownerNamespace: fixture.session.ownerNamespace
        ), "L'envoi reste en attente")
        let retried = await sender.send(
            draft("Texte changé entre-temps"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
            membership: seeded.membership, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        guard case .sent = retried else { return XCTFail("Le nouvel essai doit passer : \(retried)") }
        let sent = bodies.all
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1], "Même enveloppe à l'octet : jamais deux charges pour une identité")
        let signed = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(sent[1]))
        let opened = try E2EEV2MessageCryptoV2.decrypt(
            envelope: signed.envelope, epochKey: seeded.epochKey,
            context: signed.context(conversationId: seeded.conversationId, senderDeviceId: fixture.descriptor.deviceId)
        )
        XCTAssertEqual(opened.payload.body, .text("Premier essai"))
        XCTAssertEqual(opened.payload.counter, 1)
    }

    func testAPendingMessageIsReencryptedLocallyWhenItsEpochWasReplaced() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let bodies = Bodies()
        MockURLProtocol.requestHandler = { request in
            if bodies.append(E2EEV2AccountFixture.rawBody(request)) == 1 { throw URLError(.networkConnectionLost) }
            return E2EEV2AccountFixture.response(request, Self.receipt("message_01J7ABCD00000001"))
        }
        let sender = E2EEV2MessageSenderV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        _ = await sender.send(
            draft("Avant la rotation"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
            membership: seeded.membership, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        let epochTwo = Data((0..<32).map { UInt8(0x40 + $0) })
        try fixture.advance(seeded, to: 2, epochKey: epochTwo)
        let result = await sender.send(
            draft("Avant la rotation"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
            membership: seeded.membership, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        guard case .sent = result else { return XCTFail("Rechiffré puis accepté : \(result)") }
        let sent = bodies.all
        XCTAssertEqual(sent.count, 2, "Jamais renvoyé sous une époque que l'appareil sait remplacée")
        let first = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(sent[0]))
        let last = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(sent[1]))
        XCTAssertEqual(first.envelope.epochNumber, 1)
        XCTAssertEqual(last.envelope.epochNumber, 2)
        XCTAssertEqual(last.envelope.clientRequestId, first.envelope.clientRequestId)
        XCTAssertEqual(last.envelope.counter, first.envelope.counter)
        XCTAssertEqual(last.envelope.frankTagB64, first.envelope.frankTagB64, "Même fk et même charge : un doublon chez les destinataires")
        let deviceId = fixture.descriptor.deviceId
        let context = { (signed: E2EEV2SignedMessageEnvelopeV2) in
            signed.context(conversationId: seeded.conversationId, senderDeviceId: deviceId)
        }
        let before = try E2EEV2MessageCryptoV2.decrypt(envelope: first.envelope, epochKey: seeded.epochKey, context: context(first))
        let after = try E2EEV2MessageCryptoV2.decrypt(envelope: last.envelope, epochKey: epochTwo, context: context(last))
        XCTAssertEqual(after.payloadBytes, before.payloadBytes, "Même charge, même compteur, même date")
    }

    func testAConflictMeansAnEarlierVersionWasDelivered() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        MockURLProtocol.requestHandler = { request in
            E2EEV2AccountFixture.response(request, Self.error("E2EE_MESSAGE_CONFLICT"), status: 409)
        }
        let sender = E2EEV2MessageSenderV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let result = await sender.send(
            draft("Bonjour"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
            membership: seeded.membership, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(result, .alreadyAccepted(messageRef: E2EEV2MessageRef.make(
            conversationId: seeded.conversationId, senderDeviceId: fixture.descriptor.deviceId, clientRequestId: "message_01J7ABCD00000001"
        )))
        XCTAssertNil(try fixture.states.pendingSend(
            conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001", ownerNamespace: fixture.session.ownerNamespace
        ), "Plus rien à renvoyer, ni charge en clair gardée")
    }

    func testADeliveredMessageIsNeverSentTwiceEvenConcurrently() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let bodies = Bodies()
        MockURLProtocol.requestHandler = { request in
            _ = bodies.append(E2EEV2AccountFixture.rawBody(request))
            return E2EEV2AccountFixture.response(request, Self.receipt("message_01J7ABCD00000001"))
        }
        let sender = E2EEV2MessageSenderV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let owner = fixture.session.ownerScopeId
        let message = draft("Double tape"), conversationId = seeded.conversationId, membership = seeded.membership
        async let one = sender.send(message, conversationId: conversationId, clientRequestId: "message_01J7ABCD00000001",
                                    membership: membership, devices: devices, expectedOwnerScopeId: owner)
        async let two = sender.send(message, conversationId: conversationId, clientRequestId: "message_01J7ABCD00000001",
                                    membership: membership, devices: devices, expectedOwnerScopeId: owner)
        let results = await [one, two]
        XCTAssertEqual(Set(bodies.all).count, 1, "Une seule enveloppe signée pour une identité")
        for result in results { guard case .sent = result else { return XCTFail("Remis : \(result)") } }
        let count = bodies.all.count
        guard case .sent = await sender.send(draft("Double tape"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
                                             membership: seeded.membership, devices: devices, expectedOwnerScopeId: owner)
        else { return XCTFail("Déjà remis : le même accusé") }
        XCTAssertEqual(bodies.all.count, count, "Aucun nouvel envoi après l'accusé")
        XCTAssertEqual(try fixture.states.reserveSendCounter(conversationId: seeded.conversationId, deviceId: fixture.descriptor.deviceId,
                                                             ownerNamespace: fixture.session.ownerNamespace), 2, "Un seul compteur réservé")
    }

    func testOversizedOrAbandonedMessagesKeepNothing() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let namespace = fixture.session.ownerNamespace
        MockURLProtocol.requestHandler = { request in
            E2EEV2AccountFixture.response(request, Data(#"{"error":"bad","code":"E2EE_INVALID_ENVELOPE"}"#.utf8), status: 422)
        }
        let sender = E2EEV2MessageSenderV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let owner = fixture.session.ownerScopeId
        // 65 536 octets de texte, mais des caractères de contrôle échappés en six : la charge canonique dépasse sa borne.
        let controls = String(repeating: "\u{1}", count: 65_536)
        let tooLong = await sender.send(draft(controls), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
                                        membership: seeded.membership, devices: devices, expectedOwnerScopeId: owner)
        XCTAssertEqual(tooLong, .failure(.init(kind: .localState, message: "e2ee-message-too-long")))
        let refused = await sender.send(draft("Bonjour"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000002",
                                        membership: seeded.membership, devices: devices, expectedOwnerScopeId: owner)
        guard case .failure(let failure) = refused, failure.kind == .permanent else { return XCTFail("Refus définitif : \(refused)") }
        XCTAssertNil(try fixture.states.pendingSend(conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000002", ownerNamespace: namespace),
                     "Refus définitif : la charge en clair est effacée")
        XCTAssertEqual(try fixture.states.reserveSendCounter(conversationId: seeded.conversationId, deviceId: fixture.descriptor.deviceId, ownerNamespace: namespace), 2,
                       "Le message trop long n'a réservé aucun compteur")
    }

    func testTenThousandMessagesCallForANewEpoch() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let nowMs = seeded.current.acceptedAtMs + 1_000
        XCTAssertEqual(E2EEV2RotationPolicy.reasons(current: seeded.current, membership: seeded.membership, devices: devices, nowMs: nowMs, messageCount: 9_999), [])
        XCTAssertEqual(E2EEV2RotationPolicy.reasons(current: seeded.current, membership: seeded.membership, devices: devices, nowMs: nowMs, messageCount: 10_000), [.volume])
    }

    func testAStaleEpochTheDeviceDoesNotKnowAsksForASync() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        MockURLProtocol.requestHandler = { request in
            E2EEV2AccountFixture.response(request, Self.error("E2EE_EPOCH_STALE"), status: 409)
        }
        let sender = E2EEV2MessageSenderV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let result = await sender.send(
            draft("Bonjour"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
            membership: seeded.membership, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(result, .needsEpoch)
        XCTAssertNotNil(try fixture.states.pendingSend(
            conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001", ownerNamespace: fixture.session.ownerNamespace
        ), "Gardé pour l'essai suivant")
    }

    func testRotationComesBeforeAnySend() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let seeded = try fixture.seedConversation(with: bruno, devices: fixture.deviceSet(adding: [phone.device]))
        MockURLProtocol.requestHandler = { request in
            XCTFail("Aucune requête avant la rotation")
            return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 500)
        }
        let sender = E2EEV2MessageSenderV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let tablet = E2EEV2TestRemote(user: bruno, device: "device_bruno_tablet_01J7ABCD")
        let result = await sender.send(
            draft("Bonjour"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
            membership: seeded.membership, devices: fixture.deviceSet(adding: [phone.device, tablet.device]),
            expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(result, .needsRotation, "Un appareil ajouté impose une nouvelle époque")
        XCTAssertNil(try fixture.states.pendingSend(
            conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001", ownerNamespace: fixture.session.ownerNamespace
        ), "Rien n'est composé sous une époque à remplacer")
    }

    func testRefusesOutsideAV2ConversationOrWhenNotAMember() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        MockURLProtocol.requestHandler = { request in
            XCTFail("Aucune requête")
            return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 500)
        }
        let sender = E2EEV2MessageSenderV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let unknown = await sender.send(
            draft("Bonjour"), conversationId: "conversation_unknown_01J7ABCD", clientRequestId: "message_01J7ABCD00000001",
            membership: seeded.membership, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(unknown, .failure(.init(kind: .localState, message: "e2ee-send-state-unavailable")))
        var removed = seeded.membership
        removed.members.remove(fixture.user)
        let notMember = await sender.send(
            draft("Bonjour"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
            membership: removed, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(notMember, .failure(.init(kind: .localState, message: "e2ee-sender-not-member")))
        let otherAccount = await sender.send(
            draft("Bonjour"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
            membership: seeded.membership, devices: devices, expectedOwnerScopeId: "user:someone_else_01J7ABCD"
        )
        XCTAssertEqual(otherAccount, .failure(.init(kind: .localState, message: "invalid-e2ee-send-scope")))
    }

    func testAnInvalidReceiptKeepsTheMessagePending() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        MockURLProtocol.requestHandler = { request in
            // Autre identité, et l'heure en nombre JSON.
            let body = #"{"clientRequestId":"message_01J7ABCD99999999","envelopeId":"envelope_01J7ABCD23456789","keyId":"server_tag_key_01J7ABCD","serverTagB64":"CQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQk=","serverTimeMs":1790000000250}"#
            return E2EEV2AccountFixture.response(request, Data(body.utf8))
        }
        let sender = E2EEV2MessageSenderV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let result = await sender.send(
            draft("Bonjour"), conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001",
            membership: seeded.membership, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(result, .failure(.init(kind: .localState, message: "invalid-e2ee-message-receipt")))
        XCTAssertNotNil(try fixture.states.pendingSend(
            conversationId: seeded.conversationId, clientRequestId: "message_01J7ABCD00000001", ownerNamespace: fixture.session.ownerNamespace
        ))
    }

    // MARK: Compteur

    func testCountersOnlyMoveForwardAndRestartForANewIdentity() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let namespace = fixture.session.ownerNamespace
        let conversation = "conversation_counter_01J7ABCD"
        XCTAssertEqual(try fixture.states.reserveSendCounter(conversationId: conversation, deviceId: "device_ios_01J7ABCD2345", ownerNamespace: namespace), 1)
        XCTAssertEqual(try fixture.states.reserveSendCounter(conversationId: conversation, deviceId: "device_ios_01J7ABCD2345", ownerNamespace: namespace), 2)
        XCTAssertEqual(try fixture.states.reserveSendCounter(conversationId: "conversation_other_01J7ABCD", deviceId: "device_ios_01J7ABCD2345", ownerNamespace: namespace), 1,
                       "Un compteur par conversation")
        XCTAssertEqual(try fixture.states.reserveSendCounter(conversationId: conversation, deviceId: "device_ios_new_01J7ABCD", ownerNamespace: namespace), 1,
                       "Une nouvelle identité d'appareil repart de 1")
        XCTAssertEqual(try fixture.states.reserveSendCounter(conversationId: conversation, deviceId: "device_ios_new_01J7ABCD", ownerNamespace: namespace), 2)
        try fixture.states.removeCurrentEpochs(ownerNamespace: namespace)
        XCTAssertEqual(try fixture.states.reserveSendCounter(conversationId: conversation, deviceId: "device_ios_new_01J7ABCD", ownerNamespace: namespace), 1,
                       "Réinitialisation d'identité : compteurs et envois en attente effacés")
    }

    // MARK: Transport

    func testTheWireIsStrict() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let epoch = E2EEV2StoredEpochKey(
            conversationId: "conversation_01J7ABCD23456789", epochId: "epoch_01J7ABCD23456789", epochNumber: 3,
            keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(Data(repeating: 4, count: 32)), epochKey: Data(repeating: 4, count: 32)
        )
        let payload = try E2EEV2ContentPayloadV2(
            sentAtMs: 1_790_000_000_000, counter: 7, replyToRef: nil, mentions: [], body: .text("Bonjour")
        ).encoded()
        let signed = try E2EEV2MessageComposerV2.compose(
            payload: payload, conversationId: epoch.conversationId, clientRequestId: "message_01J7ABCD23456789", ttlSeconds: 86_400,
            epoch: epoch, device: fixture.descriptor, fk: Data(repeating: 5, count: 32), nonce: Data(repeating: 6, count: 12),
            sign: fixture.signer()
        )
        let wire = String(decoding: signed.encoded, as: UTF8.self)
        XCTAssertEqual(E2EEV2SignedMessageEnvelopeV2.parse(signed.encoded), signed)
        XCTAssertTrue(wire.contains(#""counter":"7""#) && wire.contains(#""epochNumber":"3""#) && wire.contains(#""ttlSeconds":"86400""#),
                      "Entiers en chaînes décimales")
        let commitment = signed.envelope.keyCommitmentB64
        let negatives: [(String, String)] = [
            ("compteur en nombre", wire.replacingOccurrences(of: #""counter":"7""#, with: #""counter":7"#)),
            ("époque en nombre", wire.replacingOccurrences(of: #""epochNumber":"3""#, with: #""epochNumber":3"#)),
            ("version 1", wire.replacingOccurrences(of: #""envelopeVersion":"2""#, with: #""envelopeVersion":"1""#)),
            ("compteur nul", wire.replacingOccurrences(of: #""counter":"7""#, with: #""counter":"0""#)),
            ("compteur à zéro initial", wire.replacingOccurrences(of: #""counter":"7""#, with: #""counter":"07""#)),
            ("compteur au-delà de 2³¹ − 2", wire.replacingOccurrences(of: #""counter":"7""#, with: #""counter":"2147483647""#)),
            ("TTL au-delà de 30 jours", wire.replacingOccurrences(of: #""ttlSeconds":"86400""#, with: #""ttlSeconds":"2592001""#)),
            ("appareil lu dans l'enveloppe", wire.replacingOccurrences(of: #"{"aadB64""#, with: #"{"senderDeviceId":"device_ios_01J7ABCD2345","aadB64""#)),
            ("clé dupliquée", wire.replacingOccurrences(of: #"{"aadB64""#, with: #"{"counter":"8","aadB64""#)),
            ("blob dupliqué", wire.replacingOccurrences(of: #""encryptedBlobIds":[]"#, with: #""encryptedBlobIds":["blob_01J7ABCD23456789","blob_01J7ABCD23456789"]"#)),
            ("engagement sans remplissage", wire.replacingOccurrences(of: commitment, with: String(commitment.dropLast()))),
        ]
        for (name, candidate) in negatives {
            XCTAssertNotEqual(candidate, wire, name)
            XCTAssertNil(E2EEV2SignedMessageEnvelopeV2.parse(Data(candidate.utf8)), name)
        }
        // Chiffré hors palier de bourrage.
        var ciphertext = try XCTUnwrap(Data(base64Encoded: signed.envelope.ciphertextB64))
        ciphertext.append(0)
        XCTAssertNil(E2EEV2SignedMessageEnvelopeV2.parse(Data(
            wire.replacingOccurrences(of: signed.envelope.ciphertextB64, with: ciphertext.base64EncodedString()).utf8
        )))
    }

    func testDeliveredPagesFollowTheCursor() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let epoch = E2EEV2StoredEpochKey(
            conversationId: "conversation_01J7ABCD23456789", epochId: "epoch_01J7ABCD23456789", epochNumber: 1,
            keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(Data(repeating: 4, count: 32)), epochKey: Data(repeating: 4, count: 32)
        )
        func item(_ sequence: Int, counter: Int64) throws -> E2EEV2JSON {
            let payload = try E2EEV2ContentPayloadV2(
                sentAtMs: 1_790_000_000_000, counter: counter, replyToRef: nil, mentions: [], body: .text("Message \(sequence)")
            ).encoded()
            let signed = try E2EEV2MessageComposerV2.compose(
                payload: payload, conversationId: epoch.conversationId, clientRequestId: "message_01J7ABCD0000000\(sequence)",
                ttlSeconds: 0, epoch: epoch, device: fixture.descriptor, fk: Data(repeating: 5, count: 32),
                nonce: Data(repeating: 6, count: 12), sign: fixture.signer()
            )
            return .object([
                "envelopeId": .string("envelope_01J7ABCD0000000\(sequence)"), "sequence": .string(String(sequence)),
                "senderUserId": .string(fixture.user), "senderDeviceId": .string(fixture.descriptor.deviceId),
                "envelope": signed.json, "serverTagB64": .string(Data(repeating: 9, count: 32).base64EncodedString()),
                "serverTimeMs": .string("1790000000250"), "keyId": .string(tagKeyId),
            ])
        }
        func page(_ items: [E2EEV2JSON], hasMore: Bool) -> Data {
            E2EEV2CanonicalJSON.encode(.object(["messages": .array(items), "hasMore": .bool(hasMore)]))
        }
        let parsed = try XCTUnwrap(E2EEV2DeliveredMessageV2.parsePage(page([try item(4, counter: 1), try item(5, counter: 2)], hasMore: true), after: 3))
        XCTAssertEqual(parsed.messages.map(\.sequence), [4, 5])
        XCTAssertTrue(parsed.hasMore)
        XCTAssertNil(E2EEV2DeliveredMessageV2.parsePage(page([try item(4, counter: 1)], hasMore: false), after: 4), "Au plus le curseur")
        XCTAssertNil(E2EEV2DeliveredMessageV2.parsePage(page([try item(5, counter: 1), try item(4, counter: 2)], hasMore: false), after: 0), "Ordre croissant")
        XCTAssertNil(E2EEV2DeliveredMessageV2.parsePage(page([], hasMore: true), after: 0), "Page vide qui en annonce d'autres")
        let fetched = E2EEV2CanonicalJSON.encode(.object(["message": try item(4, counter: 1)]))
        XCTAssertNotNil(E2EEV2DeliveredMessageV2.parseFetch(fetched, envelopeId: "envelope_01J7ABCD00000004"))
        XCTAssertNil(E2EEV2DeliveredMessageV2.parseFetch(fetched, envelopeId: "envelope_01J7ABCD00000005"), "Autre enveloppe")
    }

    // MARK: Aides

    private func draft(_ text: String) -> E2EEV2MessageSenderV2.Draft {
        .init(body: .text(text), replyToRef: nil, mentions: [], ttlSeconds: 0)
    }

    private static func receipt(_ clientRequestId: String, keyId: String = "server_tag_key_01J7ABCD") -> Data {
        E2EEV2CanonicalJSON.encode(.object([
            "envelopeId": .string("envelope_01J7ABCD23456789"), "clientRequestId": .string(clientRequestId),
            "serverTagB64": .string(Data(repeating: 9, count: 32).base64EncodedString()),
            "serverTimeMs": .string("1790000000250"), "keyId": .string(keyId),
        ]))
    }

    private static func error(_ code: String) -> Data {
        Data(#"{"error":"stale","code":"\#(code)"}"#.utf8)
    }
}

/// Corps reçus par le faux serveur, dans l'ordre.
private final class Bodies: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []

    /// Rend le nombre de corps reçus, celui-ci compris.
    func append(_ body: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        items.append(body)
        return items.count
    }

    var all: [Data] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
