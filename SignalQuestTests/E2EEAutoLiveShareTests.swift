import CryptoKit
import XCTest
@testable import SignalQuest

/// Révision 18 (E2EE-AUTO §7.6) : sous une époque marquée, une position de
/// partage en direct part en enveloppe v3 `live_share` (vecteur
/// `live-share-envelope-v3`, mêmes clés, `fk` et nonce que `message-envelope-v3`).
final class E2EEAutoLiveShareTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/live-share-envelope-v3.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func str(_ dictionary: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(dictionary[key] as? String, "clé \(key)")
    }

    private func b64(_ dictionary: [String: Any], _ key: String) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: str(dictionary, key)), "clé \(key)")
    }

    /// Lu à l'octet, ouvert, puis recomposé par l'app : même AAD, même chiffré,
    /// même `frankTag` ; la signature du vecteur et celle tirée ici se vérifient.
    func testLiveShareUpdateIsReadAndRecomposedAtTheByte() throws {
        let v = try vector()
        let item = try XCTUnwrap((v["cases"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["case"] as? String, "liveShareUpdate")
        let conversationId = try str(v, "conversationId"), senderDeviceId = try str(v, "senderDeviceId")
        let epochKey = try b64(v, "epochKeyB64")
        let signing = try P256.Signing.PrivateKey(rawRepresentation: b64(v, "senderSigningPrivateRawB64"))
        let sender = try P256.Signing.PublicKey(x963Representation: b64(v, "senderSigningPublicX963B64"))
        XCTAssertEqual(signing.publicKey.x963Representation, sender.x963Representation)

        let wire = Data(try str(item, "wireJsonUtf8").utf8)
        XCTAssertNil(E2EEV2SignedMessageEnvelopeV2.parse(wire), "la route des messages la refuse")
        let parsed = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(wire, allowLiveShare: true))
        XCTAssertEqual(parsed.encoded, wire, "JSON canonique, à l'octet")
        XCTAssertEqual(parsed.envelope.envelopeVersion, 3)
        XCTAssertEqual(parsed.envelope.delivery, .liveShare)
        XCTAssertEqual(parsed.envelope.notifyUserId, "")
        XCTAssertEqual(parsed.envelope.counter, 1)
        XCTAssertEqual(parsed.envelope.ttlSeconds, 900)
        XCTAssertEqual(parsed.envelope.aadB64, try str(item, "aadB64"))
        XCTAssertEqual(Data(base64Encoded: parsed.envelope.aadB64), Data(try str(item, "aadUtf8").utf8))

        let context = parsed.context(conversationId: conversationId, senderDeviceId: senderDeviceId)
        XCTAssertEqual(
            try E2EEV2MessageCryptoV2.signatureCanonical(context: context, envelope: parsed.envelope),
            Data(try str(item, "signatureCanonicalUtf8").utf8)
        )
        let payload = Data(try str(item, "payloadUtf8").utf8)
        XCTAssertEqual(
            try E2EEV2MessageCryptoV2.openFranked(envelope: parsed.envelope, epochKey: epochKey, context: context).payloadBytes,
            payload
        )
        let content = try E2EEV2LiveShareEnvelopeV3.open(
            parsed, conversationId: conversationId, senderDeviceId: senderDeviceId,
            senderSigningKey: sender, epochKey: epochKey
        )
        XCTAssertEqual(content["kind"] as? String, "LIVE_LOCATION")
        let body = try XCTUnwrap(content["body"] as? [String: Any])
        XCTAssertEqual(body["sessionId"] as? String, try str(v, "sessionId"))
        XCTAssertEqual((body["sequence"] as? NSNumber)?.intValue, 4, "la séquence du clair n'est pas le compteur")
        // Un message v3 ordinaire ne s'ouvre pas avec ce contexte : le contenu v1 n'en est pas un.
        XCTAssertThrowsError(try E2EEV2MessageCryptoV2.decrypt(envelope: parsed.envelope, epochKey: epochKey, context: context))

        let epoch = E2EEV2StoredEpochKey(
            conversationId: conversationId, epochId: "epoch_vector_000000000001",
            epochNumber: try XCTUnwrap(Int(str(v, "epochNumber"))),
            keyCommitmentB64: try str(v, "keyCommitmentB64"), epochKey: epochKey
        )
        let device = E2EEV2DeviceDescriptor(
            deviceId: senderDeviceId, platform: "ios", label: nil,
            publicIdentityKeyB64: try str(v, "senderSigningPublicX963B64"),
            publicSigningKeyB64: try str(v, "senderSigningPublicX963B64"),
            identityKeyAlgorithm: "P-256", signingKeyAlgorithm: "P-256", keyVersion: 1
        )
        let composed = try E2EEV2LiveShareEnvelopeV3.compose(
            payload: payload, conversationId: conversationId, clientRequestId: try str(item, "clientRequestId"),
            counter: 1, ttlSeconds: 900, epoch: epoch, device: device,
            fk: b64(v, "fkB64"), nonce: b64(v, "nonceB64")
        ) { try E2EEV2LowS.sign($0, with: signing) }
        XCTAssertEqual(composed.envelope, parsed.envelope, "recomposé à l'octet")
        try E2EEV2MessageCryptoV2.verifySignature(
            context: context, envelope: composed.envelope, signatureDerB64: composed.senderSignatureB64, senderSigningKey: sender
        )
        XCTAssertNotNil(try E2EEV2LiveShareEnvelopeV3.open(
            composed, conversationId: conversationId, senderDeviceId: senderDeviceId,
            senderSigningKey: sender, epochKey: epochKey
        ))
        // Une signature d'un autre appareil ne passe pas.
        XCTAssertThrowsError(try E2EEV2LiveShareEnvelopeV3.open(
            parsed, conversationId: conversationId, senderDeviceId: senderDeviceId,
            senderSigningKey: P256.Signing.PrivateKey().publicKey, epochKey: epochKey
        ))
    }

    /// Une position ne se rejoue pas en message, ni l'inverse (§7.6, refus croisé).
    func testCrossDeliveryIsRefusedBothWays() throws {
        let v = try vector()
        let cases = try XCTUnwrap(v["crossDelivery"] as? [[String: Any]])
        let onLiveShareRoute = try XCTUnwrap(cases.first { $0["case"] as? String == "messageOnLiveShareRoute" })
        let messageWire = Data(try str(onLiveShareRoute, "wireJsonUtf8").utf8)
        XCTAssertNil(E2EEV2SignedMessageEnvelopeV2.parse(messageWire, allowLiveShare: true))
        let onMessageRoute = try XCTUnwrap(cases.first { $0["case"] as? String == "liveShareOnMessageRoute" })
        let liveShareWire = Data(try str(onMessageRoute, "wireJsonUtf8").utf8)
        XCTAssertNil(E2EEV2SignedMessageEnvelopeV2.parse(liveShareWire))
        XCTAssertNotNil(E2EEV2SignedMessageEnvelopeV2.parse(liveShareWire, allowLiveShare: true))
    }

    /// `updates/latest` d'une époque déjà accusée : 22 clés, entiers v3 en chaînes,
    /// `recipientEnvelope` nul ; la clé gardée déchiffre.
    func testAcknowledgedLatestDeliveryOpensWithTheStoredKey() throws {
        let v = try vector()
        let latest = try XCTUnwrap(v["latestAcknowledged"] as? [String: Any])
        let response = Data(try str(latest, "responseJsonUtf8").utf8)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let envelope = try XCTUnwrap(root["envelope"] as? [String: Any])
        XCTAssertEqual(envelope.count, 22)
        let conversationId = try str(v, "conversationId")
        let readerDeviceId = try str(latest, "readerDeviceId")
        func parse(_ allowsLiveShareV3: Bool) -> E2EEV2VerifiedMessageDelivery? {
            E2EEV2MessageDeliveryContract.parseAndVerify(
                response, ownerScopeId: "user:user_bruno_01J7ABCD2345678",
                expectedEnvelopeId: envelope["id"] as? String ?? "",
                expectedConversationId: conversationId, expectedRecipientDeviceId: readerDeviceId,
                allowServerBoundedExpiry: true, allowsLiveShareV3: allowsLiveShareV3
            )
        }
        XCTAssertNil(parse(false), "seul le partage en direct lit la v3")
        let delivery = try XCTUnwrap(parse(true))
        XCTAssertNil(delivery.epochDelivery)
        XCTAssertEqual(delivery.epoch.epochNumber, 1)
        XCTAssertEqual(delivery.expiresAt, envelope["expiresAt"] as? String)
        let signed = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(delivery.incoming.envelopeData, allowLiveShare: true))
        XCTAssertEqual(signed.encoded, Data(try str(try XCTUnwrap((v["cases"] as? [[String: Any]])?.first), "wireJsonUtf8").utf8))
        let content = try E2EEV2LiveShareEnvelopeV3.open(
            signed, conversationId: conversationId, senderDeviceId: delivery.incoming.senderDeviceId,
            senderSigningKey: P256.Signing.PublicKey(x963Representation: b64(v, "senderSigningPublicX963B64")),
            epochKey: b64(v, "epochKeyB64")
        )
        let publicExpiry = try XCTUnwrap(E2EEV2PortableInventoryContract.parseInstant(delivery.expiresAt ?? ""))
        let update = try XCTUnwrap(E2EEV2LiveShareTransportClient.validateDecryptedContent(
            updateId: envelope["id"] as? String ?? "", expectedSessionId: try str(v, "sessionId"), content: content,
            ttlSeconds: signed.envelope.ttlSeconds, encryptedBlobIds: signed.envelope.encryptedBlobIds,
            publicExpiresAt: publicExpiry,
            now: try XCTUnwrap(E2EEV2PortableInventoryContract.parseInstant("2026-08-26T12:05:00.000Z"))
        ))
        XCTAssertEqual(update.sequence, 4)

        // Une autre clé que les quatre de la v3 : refusée.
        var extra = envelope
        extra["counterB64"] = "AA=="
        let tampered = try JSONSerialization.data(withJSONObject: ["envelope": extra])
        XCTAssertNil(E2EEV2MessageDeliveryContract.parseAndVerify(
            tampered, ownerScopeId: "user:user_bruno_01J7ABCD2345678", expectedEnvelopeId: envelope["id"] as? String ?? "",
            expectedConversationId: conversationId, expectedRecipientDeviceId: readerDeviceId,
            allowServerBoundedExpiry: true, allowsLiveShareV3: true
        ))
    }

    /// Compteur propre à la session sur cet appareil : 1, 2…, relevé après
    /// `lastCounter`, jamais redescendu ; l'enveloppe v3 en attente survit.
    func testCounterIsClaimedRaisedAndPendingV3Survives() throws {
        let tokenStore = InMemoryTokenStore()
        let owner = "user:owner_01J7ABCD23456789", conversation = "conversation_0123456789abcdef"
        let session = "live_0123456789abcdef"
        let store = E2EEV2LiveShareStateStore(tokenStore: tokenStore)
        XCTAssertThrowsError(try store.claimCounter(
            ownerScopeId: owner, conversationId: conversation, sessionId: session, nowMs: 1
        ), "l'état naît de la séquence")
        XCTAssertEqual(try store.claimSequence(ownerScopeId: owner, conversationId: conversation, sessionId: session, nowMs: 1), 0)
        XCTAssertEqual(try store.claimCounter(ownerScopeId: owner, conversationId: conversation, sessionId: session, nowMs: 1), 1)
        XCTAssertEqual(try store.claimCounter(ownerScopeId: owner, conversationId: conversation, sessionId: session, nowMs: 2), 2)
        try store.raiseCounter(ownerScopeId: owner, sessionId: session, above: 41, nowMs: 3)
        try store.raiseCounter(ownerScopeId: owner, sessionId: session, above: 5, nowMs: 4)
        XCTAssertEqual(try store.claimCounter(ownerScopeId: owner, conversationId: conversation, sessionId: session, nowMs: 5), 42)

        let v = try vector()
        let item = try XCTUnwrap((v["cases"] as? [[String: Any]])?.first)
        let signed = try XCTUnwrap(E2EEV2SignedMessageEnvelopeV2.parse(Data(try str(item, "wireJsonUtf8").utf8), allowLiveShare: true))
        let pending = E2EEV2LiveSharePendingEnvelope(
            clientRequestId: signed.envelope.clientRequestId, sendDeadlineAtMs: 61_000, prepared: .v3(signed)
        )
        try store.storePending(ownerScopeId: owner, conversationId: conversation, sessionId: session, pending: pending, nowMs: 1_000)
        let restored = E2EEV2LiveShareStateStore(tokenStore: tokenStore)
        let kept = try XCTUnwrap(try restored.pending(ownerScopeId: owner, conversationId: conversation, sessionId: session))
        XCTAssertEqual(kept.prepared, .v3(signed))
        XCTAssertEqual(try restored.claimCounter(ownerScopeId: owner, conversationId: conversation, sessionId: session, nowMs: 6), 43)
    }

    /// Un refus n'est pas retenu par le serveur : l'enveloppe en attente est
    /// abandonnée ; réseau, cadence et erreurs serveur la gardent.
    func testRefusedPendingIsDroppedAndEpochRefusalsAreNotTerminal() {
        func failure(_ status: Int?, _ code: String? = nil) -> E2EEV2TransportFailure {
            .init(kind: .permanent, statusCode: status, code: code, message: "test")
        }
        XCTAssertTrue(E2EEV2LiveShareRuntimeCoordinator.dropsPending(failure(409, "E2EE_EPOCH_STALE")))
        XCTAssertTrue(E2EEV2LiveShareRuntimeCoordinator.dropsPending(failure(404, "E2EE_EPOCH_ENVELOPE_NOT_FOUND")))
        XCTAssertFalse(E2EEV2LiveShareRuntimeCoordinator.dropsPending(failure(429, "RATE_LIMITED")))
        XCTAssertFalse(E2EEV2LiveShareRuntimeCoordinator.dropsPending(failure(503)))
        XCTAssertFalse(E2EEV2LiveShareRuntimeCoordinator.dropsPending(failure(nil)))

        func terminal(_ status: Int, _ code: String) -> Bool {
            ConversationLiveShareCoordinator.isTerminalPublishFailure(
                E2EEV2LiveShareRuntimeError.transport(failure(status, code))
            )
        }
        XCTAssertFalse(terminal(409, "E2EE_EPOCH_STALE"))
        XCTAssertFalse(terminal(409, "E2EE_AUTO_REQUIRED"))
        XCTAssertFalse(terminal(404, "E2EE_EPOCH_ENVELOPE_NOT_FOUND"))
        XCTAssertTrue(terminal(409, "E2EE_LIVE_SHARE_COUNTER_STALE"), "au second refus, fin du partage")
        XCTAssertTrue(terminal(403, "LIVE_SHARE_ENDED"))
    }
}
