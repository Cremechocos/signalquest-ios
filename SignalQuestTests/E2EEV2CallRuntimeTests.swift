import CryptoKit
import XCTest
@testable import SignalQuest

/// Appels chiffrés v2 (§10.1, §10.2, IOS-CALL) : le descripteur que cet
/// appareil signe, et ce que l'appelé vérifie avant de sonner ou de répondre.
final class E2EEV2CallRuntimeTests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD2345"

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private func runtime(
        _ fixture: E2EEV2AccountFixture,
        devices: E2EEV2CertifiedDeviceSet,
        open: Bool = true,
        syncs: Box<Int> = Box(0),
        now: Date = Date()
    ) -> E2EEV2CallRuntime {
        let members = E2EEV2MessagingRuntime.CallMembers(
            devices: devices, members: [fixture.user, bruno], excludesWeb: false,
            ownUserId: fixture.user, ownerNamespace: fixture.session.ownerNamespace
        )
        return E2EEV2CallRuntime(
            members: { _, synchronizing in
                if synchronizing { syncs.value += 1 }
                return members
            },
            identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            nonces: E2EEV2CallNonceLedger(fileURL: nil), contextStore: { nil }, now: { now },
            controlPlaneOpen: { open }, mediaOpen: { _ in open }
        )
    }

    /// Descripteur signé par l'appareil de Bruno sur l'époque gardée.
    private func incoming(
        _ seeded: E2EEV2SeededConversation,
        from phone: E2EEV2TestRemote,
        callId: String = "call_incoming_000000000001",
        nonce: UInt8 = 9,
        epochNumber: Int? = nil,
        createdAt: Date = Date()
    ) throws -> E2EEV2SignedCallDescriptor {
        try E2EEV2CallDescriptorFactory.make(
            conversationId: seeded.conversationId, callId: callId, callerDeviceId: phone.device.deviceId,
            epochId: try XCTUnwrap(seeded.current.epochId), epochNumber: epochNumber ?? seeded.current.epochNumber,
            keyCommitmentB64: try XCTUnwrap(seeded.current.keyCommitmentB64),
            callNonceB64: Data(repeating: nonce, count: 32).base64EncodedString(),
            createdAtMs: Int64(createdAt.timeIntervalSince1970 * 1_000),
            sign: { try E2EEV2LowS.sign($0, with: phone.signing) }
        )
    }

    func testTheCallerSignsADescriptorOnTheCurrentVerifiedEpoch() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)

        XCTAssertEqual(runtime(fixture, devices: devices, open: false).prepareOutgoing(conversationId: seeded.conversationId), .runtimeClosed)
        XCTAssertFalse(runtime(fixture, devices: devices, open: false).canStart(conversationId: seeded.conversationId))
        XCTAssertEqual(runtime(fixture, devices: devices).prepareOutgoing(conversationId: "conversation_v1_only_000001"),
                       .localEpochUnavailable)

        let open = runtime(fixture, devices: devices)
        XCTAssertTrue(open.canStart(conversationId: seeded.conversationId))
        guard case .prepared(let signed) = open.prepareOutgoing(conversationId: seeded.conversationId) else {
            return XCTFail("Descripteur attendu")
        }
        XCTAssertEqual(signed.callerDeviceId, fixture.descriptor.deviceId)
        XCTAssertEqual(signed.descriptor.epochNumber, seeded.current.epochNumber)
        XCTAssertEqual(signed.descriptor.epochId, seeded.current.epochId)
        let ownKey = try XCTUnwrap(devices.signingKey(userId: fixture.user, deviceId: fixture.descriptor.deviceId))
        XCTAssertNoThrow(try E2EEV2CallDescriptor.verify(signed.signed, callerSigningKey: ownKey, nowMs: Int64(Date().timeIntervalSince1970 * 1_000), ringing: true))
        guard case .prepared(let second) = open.prepareOutgoing(conversationId: seeded.conversationId) else {
            return XCTFail("Descripteur attendu")
        }
        XCTAssertNotEqual(second.descriptor.callId, signed.descriptor.callId, "Un identifiant d'appel neuf à chaque appel")
        XCTAssertNotEqual(second.descriptor.callNonceB64, signed.descriptor.callNonceB64)
    }

    func testTheCalleeVerifiesTheCallerDeviceEpochAndNonce() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let syncs = Box(0)
        let callee = runtime(fixture, devices: devices, syncs: syncs)

        let call = try incoming(seeded, from: phone)
        let verified = await callee.verify(call, conversationId: seeded.conversationId, callId: call.descriptor.callId, ringing: true)
        XCTAssertEqual(verified, .verified(call.descriptor))
        let again = await callee.verify(call, conversationId: seeded.conversationId, callId: call.descriptor.callId, ringing: false)
        XCTAssertEqual(again, .verified(call.descriptor), "Revérifié à la réponse, même nonce, même appel")

        // Le même nonce pour un autre appel : rejeu.
        let replay = try incoming(seeded, from: phone, callId: "call_incoming_000000000002")
        let replayed = await callee.verify(replay, conversationId: seeded.conversationId, callId: replay.descriptor.callId, ringing: true)
        XCTAssertEqual(replayed, .refused(.replayedNonce))

        // Sonnerie de plus de 60 secondes.
        let late = try incoming(seeded, from: phone, callId: "call_incoming_000000000003", nonce: 10, createdAt: Date().addingTimeInterval(-120))
        let expired = await callee.verify(late, conversationId: seeded.conversationId, callId: late.descriptor.callId, ringing: true)
        XCTAssertEqual(expired, .refused(.expired))

        // Une autre conversation que celle annoncée.
        let other = await callee.verify(call, conversationId: "conversation_other_0000000001", callId: call.descriptor.callId, ringing: true)
        XCTAssertEqual(other, .refused(.otherCall))
        XCTAssertEqual(syncs.value, 0, "Rien à relire pour ces refus")
    }

    func testAnUnknownCallerOrANewerEpochRereadsTheConversationOnce() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let stranger = E2EEV2TestRemote(user: bruno, device: "device_bruno_unknown_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let syncs = Box(0)
        let callee = runtime(fixture, devices: devices, syncs: syncs)

        let unknown = try incoming(seeded, from: stranger, nonce: 11)
        let refused = await callee.verify(unknown, conversationId: seeded.conversationId, callId: unknown.descriptor.callId, ringing: true)
        XCTAssertEqual(refused, .refused(.untrustedCaller))
        XCTAssertEqual(syncs.value, 1, "Un appareil inconnu fait relire la conversation une fois")

        let ahead = try incoming(seeded, from: phone, callId: "call_incoming_000000000004", nonce: 12, epochNumber: seeded.current.epochNumber + 1)
        let stale = await callee.verify(ahead, conversationId: seeded.conversationId, callId: ahead.descriptor.callId, ringing: true)
        XCTAssertEqual(stale, .refused(.notLatestEpoch))
        XCTAssertEqual(syncs.value, 2, "Une époque plus récente aussi")
    }

    /// §10.0 : un appareil sans « appels vérifiés » n'appelle pas.
    func testACallerWithoutTheCallsCapabilityIsRefused() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let base = phone.device
        let withoutCalls = E2EEV2CertifiedDevice(
            userId: base.userId, deviceId: base.deviceId, keyVersion: base.keyVersion, platform: base.platform,
            identityKeyB64: base.identityKeyB64, signingKeyB64: base.signingKeyB64, fingerprint: base.fingerprint,
            capabilities: E2EEV2CapabilitiesDocument(
                userId: base.userId, deviceId: base.deviceId, sequence: 1, issuedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
                envelopeVersions: ["2"], payloadVersions: ["2"], kinds: ["DELETE", "EDIT", "TEXT"], features: []
            )
        )
        let devices = fixture.deviceSet(adding: [withoutCalls])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let call = try incoming(seeded, from: phone, nonce: 13)
        let result = await runtime(fixture, devices: devices).verify(call, conversationId: seeded.conversationId, callId: call.descriptor.callId, ringing: true)
        XCTAssertEqual(result, .refused(.untrustedCaller))
        let closed = await runtime(fixture, devices: devices, open: false).verify(call, conversationId: seeded.conversationId, callId: call.descriptor.callId, ringing: true)
        XCTAssertEqual(closed, .unavailable)
    }

    /// E.1 (v0.4.19) : jetons APNs seulement, l'environnement du build, et
    /// rien à envoyer sans jeton valide (le corps remplace tout l'ensemble).
    func testPushTokensCarryOnlyValidAPNsTokensAndTheEnvironment() throws {
        let voip = String(repeating: "ab", count: 32), apns = String(repeating: "0f", count: 32)
        let body = try XCTUnwrap(E2EEV2CallPushTokens.body(voipToken: voip, apnsToken: apns, environment: "sandbox"))
        XCTAssertEqual(
            try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String]),
            ["apnsVoipToken": voip, "apnsToken": apns, "environment": "sandbox"]
        )
        let voipOnly = try XCTUnwrap(E2EEV2CallPushTokens.body(voipToken: voip, apnsToken: "not-hex", environment: "production"))
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: voipOnly) as? [String: String]).keys),
                       ["apnsVoipToken", "environment"])
        XCTAssertNil(E2EEV2CallPushTokens.body(voipToken: nil, apnsToken: nil))
        XCTAssertNil(E2EEV2CallPushTokens.body(voipToken: String(repeating: "AB", count: 32), apnsToken: "abc"),
                     "Hexadécimal minuscule, 32 caractères au moins")
        XCTAssertEqual(E2EEV2CallPushTokens.hex(Data([0x0f, 0xa0])), "0fa0")
        XCTAssertFalse(E2EEV2CapabilitiesPublicationStore.features.contains("calls"),
                       "« Appels vérifiés » n'est annoncé que verrou d'appels ouvert")
    }
}
