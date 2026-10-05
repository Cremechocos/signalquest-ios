import CryptoKit
import XCTest
@testable import SignalQuest
#if canImport(LiveKit)
import LiveKit
#endif

final class CallReliabilityTests: XCTestCase {
    private let decoder = JSONDecoder.signalQuest

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testPendingSingletonContractDecodesCanonicalBackendShape() throws {
        let data = Data(#"""
        {
          "pending": true,
          "callId": "call-123",
          "conversationId": "conversation-9",
          "callerName": "Alice",
          "type": "sync",
          "callType": "VIDEO",
          "status": "RINGING",
          "startedAt": "2026-07-10T10:00:00.000Z",
          "isGroup": true
        }
        """#.utf8)

        let response = try decoder.decode(PendingCallsResponse.self, from: data)

        XCTAssertEqual(response.calls.count, 1)
        XCTAssertEqual(response.calls[0].id, "call-123")
        XCTAssertEqual(response.calls[0].mode, "video")
        XCTAssertEqual(response.calls[0].status, "ringing")
        XCTAssertEqual(response.calls[0].isPending, true)
        XCTAssertEqual(response.calls[0].displayName, "Alice")
        XCTAssertTrue(response.calls[0].isGroup)
    }

    func testPendingFalseIsAnEmptyListRatherThanSyntheticCall() throws {
        let response = try decoder.decode(
            PendingCallsResponse.self,
            from: Data(#"{"pending":false}"#.utf8)
        )

        XCTAssertTrue(response.calls.isEmpty)
    }

    func testTransferredActiveCallRemainsPendingForThisParticipant() throws {
        let response = try decoder.decode(
            PendingCallsResponse.self,
            from: Data(
                #"{"pending":true,"callId":"transfer-1","callType":"AUDIO","status":"ACTIVE"}"#.utf8
            )
        )
        let call = try XCTUnwrap(response.calls.first)

        XCTAssertTrue(CallLifecyclePolicy.isRinging(call.status, pending: call.isPending))
        XCTAssertEqual(
            CallLifecyclePolicy.terminationAction(
                isOutgoing: false,
                isAnswered: false,
                serverStatus: call.status
            ),
            .leave
        )
    }

    func testPendingLegacyArrayRemainsCompatible() throws {
        let data = Data(#"{"calls":[{"id":"legacy","type":"AUDIO","status":"pending"}]}"#.utf8)
        let response = try decoder.decode(PendingCallsResponse.self, from: data)

        XCTAssertEqual(response.calls.map(\.id), ["legacy"])
        XCTAssertEqual(response.calls.first?.mode, "audio")
    }

    func testMalformedCallDoesNotReceiveRandomIdentity() {
        XCTAssertThrowsError(
            try decoder.decode(CallSession.self, from: Data(#"{"status":"RINGING"}"#.utf8))
        )
    }

    func testHistoryParticipantNamesAndConversationTitleDecode() throws {
        let data = Data(#"""
        {
          "id":"history-1",
          "type":"VIDEO",
          "status":"ENDED",
          "startedAt":"2026-07-10T10:00:00.000Z",
          "otherParticipants":[{"id":"u2","name":"Bob"}],
          "conversation":{"title":"Équipe terrain","isGroup":true}
        }
        """#.utf8)
        let call = try decoder.decode(CallSession.self, from: data)

        XCTAssertEqual(call.participants, ["Bob"])
        XCTAssertEqual(call.displayName, "Équipe terrain")
        XCTAssertEqual(call.mode, "video")
        XCTAssertEqual(call.status, "ended")
        XCTAssertTrue(call.isGroup)
    }

    func testLifecyclePolicyIsCaseInsensitiveAndChoosesCorrectTermination() {
        XCTAssertTrue(CallLifecyclePolicy.isRinging("RINGING"))
        XCTAssertTrue(CallLifecyclePolicy.isRinging("pending"))
        XCTAssertTrue(CallLifecyclePolicy.isRinging("ACTIVE", pending: true))
        XCTAssertFalse(CallLifecyclePolicy.isRinging("ENDED"))
        XCTAssertEqual(
            CallLifecyclePolicy.terminationAction(isOutgoing: false, isAnswered: false),
            .reject
        )
        XCTAssertEqual(
            CallLifecyclePolicy.terminationAction(isOutgoing: false, isAnswered: true),
            .leave
        )
        XCTAssertEqual(
            CallLifecyclePolicy.terminationAction(isOutgoing: true, isAnswered: false),
            .leave
        )
        XCTAssertEqual(
            CallLifecyclePolicy.terminationAction(
                isOutgoing: false,
                isAnswered: false,
                serverStatus: "ACTIVE"
            ),
            .leave
        )
    }

    func testCallKitIdentityIsStablePerBackendCall() {
        let first = CallLifecyclePolicy.callKitUUID(callId: "call-123")
        XCTAssertEqual(first, CallLifecyclePolicy.callKitUUID(callId: "call-123"))
        XCTAssertNotEqual(first, CallLifecyclePolicy.callKitUUID(callId: "call-456"))
    }

    func testCallsAreLimitedToTwoThroughEightParticipants() {
        XCTAssertFalse(CallLifecyclePolicy.canStartCall(participantCount: 1))
        XCTAssertTrue(CallLifecyclePolicy.canStartCall(participantCount: 2))
        XCTAssertTrue(CallLifecyclePolicy.canStartCall(participantCount: 8))
        XCTAssertFalse(CallLifecyclePolicy.canStartCall(participantCount: 9))
    }

    func testAudioRouteDefaultsYieldToBluetoothAndPreserveExplicitChoice() {
        XCTAssertTrue(CallAudioRoutePolicy.wantsSpeaker(
            video: true, userOverride: nil, hasExternalRoute: false
        ))
        XCTAssertFalse(CallAudioRoutePolicy.wantsSpeaker(
            video: true, userOverride: nil, hasExternalRoute: true
        ))
        XCTAssertFalse(CallAudioRoutePolicy.wantsSpeaker(
            video: false, userOverride: nil, hasExternalRoute: false
        ))
        XCTAssertTrue(CallAudioRoutePolicy.wantsSpeaker(
            video: true, userOverride: true, hasExternalRoute: true
        ))
        XCTAssertFalse(CallAudioRoutePolicy.wantsSpeaker(
            video: true, userOverride: false, hasExternalRoute: false
        ))
        XCTAssertTrue(CallBackgroundMediaPolicy.suspendLocalVideoTracks)
    }

    func testOfflineTerminationOutboxPersistsDeduplicatesAndIsolatesAccounts() throws {
        let suiteName = "CallTerminationRetryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "test-outbox"
        let now = Date(timeIntervalSince1970: 10_000)
        let first = CallTerminationRetryStore(defaults: defaults, key: key)

        first.enqueue(
            ownerScopeId: "user:alice",
            callId: "expired",
            action: .leave,
            now: now.addingTimeInterval(-CallTerminationRetryStore.maximumAge - 1)
        )
        first.enqueue(ownerScopeId: "user:alice", callId: "call-a", action: .reject, now: now)
        first.enqueue(ownerScopeId: "user:alice", callId: "call-a", action: .leave, now: now.addingTimeInterval(1))
        first.enqueue(ownerScopeId: "user:bob", callId: "call-b", action: .reject, now: now)

        let reloaded = CallTerminationRetryStore(defaults: defaults, key: key)
        XCTAssertEqual(
            reloaded.pending(ownerScopeId: "user:alice", now: now),
            [.init(ownerScopeId: "user:alice", callId: "call-a", action: .leave, createdAt: now)]
        )
        XCTAssertEqual(reloaded.pending(ownerScopeId: "user:bob", now: now).map(\.callId), ["call-b"])
        XCTAssertTrue(reloaded.pending(ownerScopeId: "guest", now: now).isEmpty)

        reloaded.remove(ownerScopeId: "user:alice", callId: "call-a", now: now)
        XCTAssertTrue(reloaded.pending(ownerScopeId: "user:alice", now: now).isEmpty)
        XCTAssertEqual(reloaded.pending(ownerScopeId: "user:bob", now: now).map(\.callId), ["call-b"])
    }

    /// Dans une conversation chiffrée, un appel sans v2 n'est jamais silencieux :
    /// il demande une confirmation (décision du 30/09, E2E-02).
    func testEncryptedConversationAsksBeforeTransportOnlyCall() {
        XCTAssertEqual(CallLifecyclePolicy.outgoingCallMode(conversationE2EE: false, conversationV2: false, verifiedV2: false), .standard)
        XCTAssertEqual(CallLifecyclePolicy.outgoingCallMode(conversationE2EE: true, conversationV2: false, verifiedV2: false), .confirmTransportOnly)
        XCTAssertEqual(CallLifecyclePolicy.outgoingCallMode(conversationE2EE: true, conversationV2: false, verifiedV2: true), .endToEnd)
        // §10.0 : une conversation v2 n'a jamais d'appel en transport seul.
        XCTAssertEqual(CallLifecyclePolicy.outgoingCallMode(conversationE2EE: true, conversationV2: true, verifiedV2: false), .unavailable)
        XCTAssertEqual(CallLifecyclePolicy.outgoingCallMode(conversationE2EE: true, conversationV2: true, verifiedV2: true), .endToEnd)
    }

    #if DEBUG
    /// Les verrous de Release s'ouvrent avec les capacités que le serveur
    /// publie dans `/api/app/version-policy`, et seulement avec elles.
    func testServerPublishedCapabilitiesOpenTheReleaseGates() throws {
        defer { E2EEV2ServerGate.overrideForTesting = nil }
        let production = AppConfig(
            environment: .production,
            appBaseURL: try XCTUnwrap(URL(string: "https://signalquest.fr")),
            apiBaseURL: try XCTUnwrap(URL(string: "https://api.signalquest.fr")),
            debugLogsEnabled: false
        )
        let secureMedia = try XCTUnwrap(URL(string: "wss://livekit.signalquest.fr"))
        let clearMedia = try XCTUnwrap(URL(string: "ws://livekit.signalquest.fr"))

        E2EEV2ServerGate.overrideForTesting = ["e2ee_v2_contract_preview"]
        XCTAssertFalse(E2EEV2RuntimeWriteGate.enabled)
        XCTAssertFalse(E2EEV2RuntimeReadGate.enabled)
        XCTAssertFalse(E2EEV2CallRuntimeGate.allowsControlPlane(config: production, qaArgumentEnabled: false))
        XCTAssertFalse(E2EEV2CallRuntimeGate.allowsMedia(liveKitURL: secureMedia, config: production, qaArgumentEnabled: false))

        E2EEV2ServerGate.overrideForTesting = ["e2ee_v2_contract_preview", "e2ee_device_identity_v2", "e2ee_message_envelope_v2"]
        XCTAssertTrue(E2EEV2RuntimeWriteGate.enabled)
        XCTAssertTrue(E2EEV2RuntimeReadGate.enabled)
        XCTAssertFalse(E2EEV2CallRuntimeGate.allowsControlPlane(config: production, qaArgumentEnabled: false))

        E2EEV2ServerGate.overrideForTesting = [
            "e2ee_device_identity_v2", "e2ee_message_envelope_v2", "e2ee_verified_calls_v2",
        ]
        XCTAssertTrue(E2EEV2CallRuntimeGate.allowsControlPlane(config: production, qaArgumentEnabled: false))
        XCTAssertTrue(E2EEV2CallRuntimeGate.allowsMedia(liveKitURL: secureMedia, config: production, qaArgumentEnabled: false))
        XCTAssertFalse(E2EEV2CallRuntimeGate.allowsMedia(liveKitURL: clearMedia, config: production, qaArgumentEnabled: false))
        // La recette locale ne vise jamais la production, porte ouverte ou non.
        XCTAssertFalse(E2EEV2CallRuntimeGate.allowsControlPlane(config: production, qaArgumentEnabled: true))
    }
    #endif

    func testE2EECallQAGateRequiresExplicitDebugFlagAndStrictLoopbackEndpoints() throws {
        let local = AppConfig(
            environment: .test,
            appBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:4173")),
            apiBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:4182")),
            debugLogsEnabled: false
        )
        let production = AppConfig(
            environment: .production,
            appBaseURL: try XCTUnwrap(URL(string: "https://signalquest.fr")),
            apiBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:4182")),
            debugLogsEnabled: false
        )

        XCTAssertFalse(E2EEV2RuntimeWriteGate.enabled)
        XCTAssertFalse(E2EEV2CallRuntimeGate.allowsControlPlane(
            config: local,
            qaArgumentEnabled: false
        ))
        XCTAssertFalse(E2EEV2CallRuntimeGate.allowsControlPlane(
            config: production,
            qaArgumentEnabled: true
        ))

        #if DEBUG
        XCTAssertTrue(E2EEV2CallRuntimeGate.allowsControlPlane(
            config: local,
            qaArgumentEnabled: true
        ))
        XCTAssertTrue(E2EEV2CallRuntimeGate.allowsMedia(
            liveKitURL: try XCTUnwrap(URL(string: "ws://localhost:7880")),
            config: local,
            qaArgumentEnabled: true
        ))
        for unsafeURL in [
            "wss://livekit.signalquest.fr",
            "ws://127.0.0.2:7880",
            "ws://localhost.evil:7880",
            "ws://user@localhost:7880",
            "ws://localhost:7880/room",
            "ws://localhost:7880?token=leak",
            "ws://localhost",
        ] {
            XCTAssertFalse(E2EEV2CallRuntimeGate.allowsMedia(
                liveKitURL: try XCTUnwrap(URL(string: unsafeURL)),
                config: local,
                qaArgumentEnabled: true
            ), unsafeURL)
        }
        let publicAPI = AppConfig(
            environment: .test,
            appBaseURL: local.appBaseURL,
            apiBaseURL: try XCTUnwrap(URL(string: "https://api.signalquest.fr")),
            debugLogsEnabled: false
        )
        XCTAssertFalse(E2EEV2CallRuntimeGate.allowsControlPlane(
            config: publicAPI,
            qaArgumentEnabled: true
        ))
        #else
        XCTAssertFalse(E2EEV2CallRuntimeGate.allowsControlPlane(
            config: local,
            qaArgumentEnabled: true
        ))
        XCTAssertFalse(E2EEV2CallRuntimeGate.allowsMedia(
            liveKitURL: try XCTUnwrap(URL(string: "ws://localhost:7880")),
            config: local,
            qaArgumentEnabled: true
        ))
        #endif
    }

    func testE2EECallDataChannelIsFailClosed() {
        #if canImport(LiveKit)
        XCTAssertTrue(E2EEV2CallDataPolicy.canPublish(
            requiresE2EE: false,
            cryptorsVerified: false
        ))
        XCTAssertFalse(E2EEV2CallDataPolicy.canPublish(
            requiresE2EE: true,
            cryptorsVerified: false
        ))
        XCTAssertTrue(E2EEV2CallDataPolicy.canPublish(
            requiresE2EE: true,
            cryptorsVerified: true
        ))
        XCTAssertEqual(E2EEV2CallDataPolicy.verdict(
            requiresE2EE: true,
            senderIdentity: "remote",
            encryptionType: .none
        ), .endCall)
        XCTAssertEqual(E2EEV2CallDataPolicy.verdict(
            requiresE2EE: true,
            senderIdentity: nil,
            encryptionType: .none
        ), .endCall, "En clair, même d'un émetteur inconnu")
        XCTAssertEqual(E2EEV2CallDataPolicy.verdict(
            requiresE2EE: true,
            senderIdentity: nil,
            encryptionType: .gcm
        ), .ignore, "Émetteur pas encore annoncé par le serveur : ni accepté, ni motif de coupure")
        XCTAssertEqual(E2EEV2CallDataPolicy.verdict(
            requiresE2EE: true,
            senderIdentity: "remote",
            encryptionType: .gcm
        ), .accept)
        XCTAssertEqual(E2EEV2CallDataPolicy.verdict(
            requiresE2EE: false,
            senderIdentity: nil,
            encryptionType: .none
        ), .accept, "Appel en clair : inchangé")
        #endif
    }

    func testE2EECryptorRejectsRatchetRevokedOrMissingKeys() {
        #if canImport(LiveKit)
        let verification = E2EEV2LiveKitVerification()
        verification.expectParticipant("local")
        verification.expectParticipant("remote")
        verification.expect(participantID: "local", trackID: "local-audio")
        verification.expect(participantID: "remote", trackID: "remote-audio")
        verification.update("local-audio", state: .ok)
        verification.update("remote-audio", state: .ok)
        XCTAssertTrue(verification.isVerified)
        XCTAssertTrue(verification.isTrackVerified("remote-audio"))

        verification.expect(participantID: "remote", trackID: "remote-video")
        XCTAssertFalse(verification.isVerified)
        XCTAssertFalse(verification.isTrackVerified("remote-video"), "Rien n'est montré avant « OK »")
        // Spec §10.3 : pas de ratchet, une clé par appel. Une clé qui bouge
        // est un échec, pas une rotation acceptable.
        verification.update("local-audio", state: .key_ratcheted)
        verification.update("remote-audio", state: .key_ratcheted)
        XCTAssertFalse(verification.isVerified)
        XCTAssertTrue(E2EEV2CallCryptorPolicy.isTerminalFailure(.key_ratcheted))

        verification.update("remote-audio", state: .missing_key)
        XCTAssertFalse(verification.isVerified)
        XCTAssertTrue(E2EEV2CallCryptorPolicy.isTerminalFailure(.missing_key))
        XCTAssertTrue(E2EEV2CallCryptorPolicy.isTerminalFailure(.decryption_failed))
        XCTAssertFalse(E2EEV2CallCryptorPolicy.isTerminalFailure(.new))
        XCTAssertFalse(E2EEV2CallCryptorPolicy.isTerminalFailure(.ok))

        verification.update("local-audio", state: .ok)
        verification.failGlobally()
        XCTAssertFalse(verification.isTrackVerified("local-audio"), "Un échec global cache tout")
        #endif
    }

    func testEncryptedCallAcceptsOnlyGCMTracks() {
        #if canImport(LiveKit)
        XCTAssertTrue(E2EEV2CallMediaPolicy.accepts(requiresE2EE: true, encryptionType: .gcm))
        XCTAssertFalse(E2EEV2CallMediaPolicy.accepts(requiresE2EE: true, encryptionType: .none),
                       "Une piste en clair met fin à un appel chiffré")
        XCTAssertFalse(E2EEV2CallMediaPolicy.accepts(requiresE2EE: true, encryptionType: .custom))
        XCTAssertTrue(E2EEV2CallMediaPolicy.accepts(requiresE2EE: false, encryptionType: .none),
                      "Un appel non chiffré garde ses pistes")
        #endif
    }

    func testEncryptedLocalTrackStaysMutedUntilItsCryptorIsOK() {
        #if canImport(LiveKit)
        XCTAssertFalse(E2EEV2CallLocalTrackPolicy.mayUnmute(encryptionType: .gcm, cryptorState: nil),
                       "Chiffreur pas encore attaché : la piste reste muette")
        XCTAssertFalse(E2EEV2CallLocalTrackPolicy.mayUnmute(encryptionType: .gcm, cryptorState: .new))
        XCTAssertFalse(E2EEV2CallLocalTrackPolicy.mayUnmute(encryptionType: .gcm, cryptorState: .key_ratcheted))
        XCTAssertFalse(E2EEV2CallLocalTrackPolicy.mayUnmute(encryptionType: .gcm, cryptorState: .encryption_failed))
        XCTAssertFalse(E2EEV2CallLocalTrackPolicy.mayUnmute(encryptionType: .none, cryptorState: .ok),
                       "Publiée en clair : jamais réactivée")
        XCTAssertTrue(E2EEV2CallLocalTrackPolicy.mayUnmute(encryptionType: .gcm, cryptorState: .ok))

        let verification = E2EEV2LiveKitVerification(requiresJoinProof: true)
        verification.expect(participantID: "local", trackID: "local-audio")
        XCTAssertEqual(verification.state(of: "local-audio"), .new)
        verification.update("local-audio", state: .ok)
        XCTAssertEqual(verification.state(of: "local-audio"), .ok, "Notre piste chiffre, preuve de jonction ou non")
        XCTAssertNil(verification.state(of: "absente"))
        verification.failGlobally()
        XCTAssertNil(verification.state(of: "local-audio"), "Après un échec global, plus rien n'est réactivé")
        #endif
    }

    // MARK: Appels chiffrés v2 (D.11, E.4)

    private static let callerKey = P256.Signing.PrivateKey()

    /// Descripteur signé par un appareil appelant de test.
    private func signedDescriptor(
        callId: String = "call_1234567890123456",
        epochNumber: Int = 4
    ) throws -> E2EEV2SignedCallDescriptor {
        try E2EEV2CallDescriptorFactory.make(
            conversationId: "conversation_1234567890123456",
            callId: callId,
            callerDeviceId: "device_caller_1234567890",
            epochId: "epoch_1234567890123456",
            epochNumber: epochNumber,
            keyCommitmentB64: Data(repeating: 3, count: 32).base64EncodedString(),
            callNonceB64: Data(repeating: 7, count: 32).base64EncodedString(),
            createdAtMs: 1_760_000_000_000,
            sign: { try E2EEV2LowS.sign($0, with: Self.callerKey) }
        )
    }

    private func json(_ descriptor: E2EEV2SignedCallDescriptor) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "descriptor": descriptor.signed.canonical,
            "signatureB64": descriptor.signed.signatureB64,
            "callerDeviceId": descriptor.callerDeviceId,
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testPendingE2EECallRequiresAnExactDescriptor() throws {
        let descriptor = try signedDescriptor()
        let data = Data("""
        {
          "pending": true,
          "callId": "call_1234567890123456",
          "conversationId": "conversation_1234567890123456",
          "callType": "AUDIO",
          "status": "RINGING",
          "callerName": null,
          "e2eeV2": \(try json(descriptor))
        }
        """.utf8)

        let call = try XCTUnwrap(decoder.decode(PendingCallsResponse.self, from: data).calls.first)
        XCTAssertTrue(call.e2eeRequired)
        XCTAssertEqual(call.e2eeV2, descriptor)

        // Une clé de trop dans `e2eeV2` : rien n'est lu.
        let extra = Data("""
        {"pending": true, "callId": "call_1234567890123456", "status": "RINGING",
         "e2eeV2": {"descriptor": "x", "signatureB64": "AA==", "callerDeviceId": "device_caller_1234567890", "epochKey": "AA=="}}
        """.utf8)
        XCTAssertThrowsError(try decoder.decode(PendingCallsResponse.self, from: extra))
    }

    func testPendingE2EERequiredMarkerWithoutDescriptorFailsClosed() {
        let data = Data(#"""
        {
          "pending": true,
          "callId": "call_1234567890123456",
          "conversationId": "conversation_1234567890123456",
          "callType": "AUDIO",
          "status": "RINGING",
          "e2eeRequired": true
        }
        """#.utf8)

        XCTAssertThrowsError(try decoder.decode(PendingCallsResponse.self, from: data))
    }

    func testIncomingVoipE2EEPayloadIsFailClosedAndLegacyPushesStayReconcilable() throws {
        XCTAssertEqual(IncomingCallE2EEContract.parse(["callId": "legacy"]), .unresolved)
        XCTAssertEqual(IncomingCallE2EEContract.parse(["e2eeRequired": false]), .legacy)
        XCTAssertEqual(IncomingCallE2EEContract.parse(["e2eeRequired": true]), .invalid)

        let descriptor = try signedDescriptor(epochNumber: 9)
        let object: [String: Any] = [
            "descriptor": descriptor.signed.canonical,
            "signatureB64": descriptor.signed.signatureB64,
            "callerDeviceId": descriptor.callerDeviceId,
        ]
        guard case .required(let value) = IncomingCallE2EEContract.parse(["callId": "call_1234567890123456", "e2eeV2": object]) else {
            return XCTFail("Le descripteur VoIP exact doit être accepté")
        }
        XCTAssertEqual(value, descriptor)
        XCTAssertEqual(value.descriptor.epochNumber, 9)

        var malformed = object
        malformed["epochKey"] = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertEqual(IncomingCallE2EEContract.parse(["e2eeV2": malformed]), .invalid)
        var otherCaller = object
        otherCaller["callerDeviceId"] = "device_other_123456789012"
        XCTAssertEqual(IncomingCallE2EEContract.parse(["e2eeV2": otherCaller]), .invalid,
                       "L'appareil annoncé doit être celui que le descripteur signe")
        XCTAssertEqual(IncomingCallE2EEContract.parse(["e2eeRequired": false, "e2eeV2": object]), .invalid)
    }

    func testE2EECallWireSendsTheSignedDescriptorAndRejectsADowngradedResponse() throws {
        let descriptor = try signedDescriptor(epochNumber: 5)
        let body = CallE2EEV2Wire.initiateBody(conversationId: "conversation_1234567890123456", type: "VIDEO", descriptor: descriptor)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["conversationId", "type", "callId", "e2eeV2"])
        XCTAssertEqual(object["callId"] as? String, descriptor.descriptor.callId)
        XCTAssertEqual(Set((object["e2eeV2"] as? [String: Any])?.keys ?? [:].keys), ["descriptor", "signatureB64", "callerDeviceId"])
        XCTAssertEqual(
            try XCTUnwrap(JSONSerialization.jsonObject(with: CallE2EEV2Wire.answerBody(callId: "call_1234567890123456")) as? [String: String]),
            ["callId": "call_1234567890123456"]
        )

        func response(_ e2eeV2: String?, callId: String = "call_1234567890123456") -> Data {
            Data("""
            {"callId": "\(callId)", "roomName": "call-room", "token": "livekit-token-value",
             "wsUrl": "wss://livekit.example.test", "type": "VIDEO", "livekitIdentity": "user_a.device_a"\(e2eeV2.map { ", \"e2eeV2\": \($0)" } ?? "")}
            """.utf8)
        }
        let valid = try CallE2EEV2Wire.decodeInitiated(response(try json(descriptor)), sent: descriptor)
        XCTAssertEqual(valid.id, "call_1234567890123456")
        XCTAssertEqual(valid.livekitIdentity, "user_a.device_a")
        XCTAssertThrowsError(try CallE2EEV2Wire.decodeInitiated(response(nil), sent: descriptor), "Réponse sans descripteur")
        let other = try signedDescriptor(epochNumber: 6)
        XCTAssertThrowsError(try CallE2EEV2Wire.decodeInitiated(response(try json(other)), sent: descriptor), "Autre descripteur")
        XCTAssertEqual(try CallE2EEV2Wire.decodeAnswered(response(try json(descriptor)), callId: "call_1234567890123456").e2eeV2, descriptor)
        XCTAssertThrowsError(try CallE2EEV2Wire.decodeAnswered(response(nil), callId: "call_1234567890123456"))
    }

    func testCallsServiceSendsTheSignedV2BodyOnceAndBindsTheResponse() async throws {
        let previousUserId = LocalAccountScope.currentUserId
        LocalAccountScope.activate(userId: "call-wire-test-user")
        defer {
            if let previousUserId {
                LocalAccountScope.activate(userId: previousUserId)
            } else {
                LocalAccountScope.deactivate()
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("call-wire-access-token")
        let api = APIClient(
            config: .test,
            credentials: credentials,
            session: URLSession(configuration: configuration)
        )
        let identityStore = E2EEV2DeviceIdentityStore(tokenStore: InMemoryTokenStore(), allowsOwner: { _ in true })
        _ = try identityStore.loadOrCreate(label: "Call wire test")
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore)
        let service = CallsService(api: api, e2eeTransport: transport)
        let descriptor = try signedDescriptor(epochNumber: 12)
        let served = try json(descriptor)
        var requestCount = 0

        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/calls/initiate")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: ClientProtocolContract.protocolVersionHeader),
                "2"
            )
            XCTAssertTrue(
                request.value(forHTTPHeaderField: ClientProtocolContract.capabilitiesHeaderName)?
                    .contains(E2EEV2ActivationPolicy.verifiedCallsCapability) == true
            )
            XCTAssertNotNil(request.value(forHTTPHeaderField: E2EEV2SignedRequest.headerSignature))
            let body = request.httpBody ?? request.httpBodyStream.flatMap { stream in
                stream.open()
                defer { stream.close() }
                var result = Data()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    result.append(buffer, count: count)
                }
                return result
            }
            let object = try XCTUnwrap(
                body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            )
            XCTAssertNil(object["epochKey"])
            XCTAssertEqual(object["callId"] as? String, descriptor.descriptor.callId)
            XCTAssertEqual((object["e2eeV2"] as? [String: Any])?["descriptor"] as? String, descriptor.signed.canonical)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("""
            {"callId": "call_1234567890123456", "roomName": "call-room", "token": "livekit-token-value",
             "wsUrl": "wss://livekit.example.test", "type": "AUDIO", "e2eeV2": \(served)}
            """.utf8))
        }

        let session = try await service.initiate(
            conversationId: "conversation_1234567890123456",
            mode: "audio",
            e2ee: descriptor
        )

        XCTAssertEqual(requestCount, 1, "Une preuve signée ne doit jamais être rejouée automatiquement")
        XCTAssertTrue(session.e2eeRequired)
        XCTAssertEqual(session.e2eeV2, descriptor)

        // Refus du serveur : son code remonte, sans nouvel essai automatique.
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"error":"stale","code":"E2EE_EPOCH_STALE"}"#.utf8))
        }
        do {
            _ = try await service.initiate(conversationId: "conversation_1234567890123456", mode: "audio", e2ee: descriptor)
            XCTFail("Refus attendu")
        } catch {
            XCTAssertEqual(error as? CallsServiceError, .refused(code: "E2EE_EPOCH_STALE"))
        }
        XCTAssertEqual(requestCount, 2)
    }

    func testScreenSharingRemainsDisabledByDefault() {
        XCTAssertFalse(SQFeatures.callScreenSharingEnabled)
    }

    @MainActor
    func testLiveKitE2EEMediaInteropLocalQA() async throws {
        #if DEBUG
        #if canImport(LiveKit)
        let fixture = try LiveKitMediaQAFixture.loadFromRunner()
        var epochKey = fixture.epochKey
        defer { epochKey.resetBytes(in: 0..<epochKey.count) }
        let context = E2EEV2CallFrameKeyContext(
            conversationId: fixture.call.conversationId,
            epochNumber: fixture.e2ee.descriptor.epochNumber,
            callId: fixture.call.callId
        )
        let e2eeSession = try E2EEV2LiveKitSession.make(epochKey: epochKey, context: context)
        let client = LiveKitClient()
        let renderer = LiveKitMediaQACountingRenderer()
        var receivedSequences = Set<Int>()
        var acknowledgedSequences = Set<Int>()
        var unexpectedBadKeyPacket = false
        var publishFailure: String?
        var correctCryptorsVerified = false
        var remoteAudioTrackDecrypted = false

        client.onDataReceived = { [weak client] senderIdentity, data, topic in
            guard senderIdentity == fixture.web.identity,
                  topic == LiveKitMediaQAFixture.topic,
                  let packet = try? JSONDecoder().decode(LiveKitMediaQAPacket.self, from: data),
                  packet.v == 1,
                  packet.runId == fixture.runId,
                  packet.kind == "ping",
                  packet.sender == "web",
                  ["initial", "reconnect", "bad-key"].contains(packet.phase) else { return }
            if packet.phase == "bad-key" {
                unexpectedBadKeyPacket = true
                return
            }
            receivedSequences.insert(packet.sequence)
            let pong = LiveKitMediaQAPacket(
                v: 1,
                runId: fixture.runId,
                kind: "pong",
                phase: packet.phase,
                sender: "ios",
                sequence: packet.sequence
            )
            Task { @MainActor [weak client] in
                do {
                    let encoded = try JSONEncoder().encode(pong)
                    try await client?.publishData(encoded, topic: LiveKitMediaQAFixture.topic)
                    acknowledgedSequences.insert(packet.sequence)
                } catch {
                    publishFailure = error.localizedDescription
                }
            }
        }

        await client.connect(
            url: fixture.liveKitURL,
            token: fixture.ios.token,
            room: fixture.livekit.roomName,
            video: false,
            e2eeSession: e2eeSession,
            mediaSetupMode: .localQADataOnly
        )
        do {
            try await waitForLiveKitMediaQA("room-connected") { client.state == .connected }
            guard client.state == .connected else {
                throw LiveKitMediaQAError.failed("ios-room-not-connected")
            }
            let bootstrap = LiveKitMediaQAPacket(
                v: 1,
                runId: fixture.runId,
                kind: "pong",
                phase: "bootstrap",
                sender: "ios",
                sequence: 0
            )
            try await client.publishData(
                JSONEncoder().encode(bootstrap),
                topic: LiveKitMediaQAFixture.topic
            )
            try await waitForLiveKitMediaQA("remote-web-video") {
                client.remoteVideos.contains { $0.participantID == fixture.web.identity }
            }
            try await waitForLiveKitMediaQA("remote-web-audio") {
                client.remoteAudios.contains { $0.participantID == fixture.web.identity }
            }
            guard let remoteVideo = client.remoteVideos.first(where: {
                $0.participantID == fixture.web.identity && !$0.isScreenShare
            }) else {
                throw LiveKitMediaQAError.failed("remote-web-video-unavailable")
            }
            remoteVideo.track.add(videoRenderer: renderer)
            defer { remoteVideo.track.remove(videoRenderer: renderer) }
            try await waitForLiveKitMediaQA("remote-web-video-frames") { renderer.frameCount > 0 }
            try await waitForLiveKitMediaQA("initial-data") {
                receivedSequences.contains(1) && acknowledgedSequences.contains(1)
            }
            try await waitForLiveKitMediaQA("cryptors-verified") { client.isE2EEVerified }
            correctCryptorsVerified = client.isE2EEVerified
            remoteAudioTrackDecrypted = client.remoteAudios.contains {
                $0.participantID == fixture.web.identity
            }
            try await waitForLiveKitMediaQA("reconnected-data") {
                receivedSequences.contains(2) && acknowledgedSequences.contains(2)
            }
            try await waitForLiveKitMediaQA("wrong-key-decryption-failure") {
                client.e2eeDataDecryptionFailureCount > 0 && !client.isE2EEVerified
            }
            let wrongKeyProbe = LiveKitMediaQAPacket(
                v: 1,
                runId: fixture.runId,
                kind: "pong",
                phase: "bad-key",
                sender: "ios",
                sequence: 3
            )
            try await client.publishData(
                JSONEncoder().encode(wrongKeyProbe),
                topic: LiveKitMediaQAFixture.topic
            )
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertNil(publishFailure)
            XCTAssertFalse(unexpectedBadKeyPacket)

            let publicResult: [String: Any] = [
                "version": 1,
                "runId": fixture.runId,
                "client": "ios",
                "connected": true,
                "correctCryptorsVerified": correctCryptorsVerified,
                "remoteWebVideoFrames": renderer.frameCount,
                "remoteWebAudioTrackDecrypted": remoteAudioTrackDecrypted,
                "bidirectionalDataBeforeReconnect": acknowledgedSequences.contains(1),
                "bidirectionalDataAfterReconnect": acknowledgedSequences.contains(2),
                "wrongKeyDataRejected": !unexpectedBadKeyPacket,
                "wrongKeyDecryptionFailures": client.e2eeDataDecryptionFailureCount,
                "wrongKeyVerificationFailed": !client.isE2EEVerified,
            ]
            let output = try JSONSerialization.data(withJSONObject: publicResult, options: [.sortedKeys])
            print("SQ_LIVEKIT_MEDIA_QA_RESULT_B64=\(output.base64EncodedString())")
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
        #else
        throw XCTSkip("LiveKit SDK unavailable in this test build")
        #endif
        #else
        throw XCTSkip("Le bootstrap média LiveKit local est volontairement limité aux builds Debug")
        #endif
    }
}

#if canImport(LiveKit)
private struct LiveKitMediaQAPacket: Codable {
    let v: Int
    let runId: String
    let kind: String
    let phase: String
    let sender: String
    let sequence: Int
}

private enum LiveKitMediaQAError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let reason): reason
        }
    }
}

private struct LiveKitMediaQAFixture: Decodable {
    static let topic = "sq_e2ee_call_qa"

    struct Participant: Decodable {
        let identity: String
        let platform: String
        let token: String
    }
    struct LiveKitBlock: Decodable {
        let wsUrl: String
        let roomName: String
        let participants: [Participant]
    }
    struct Descriptor: Decodable {
        let version: Int
        let provider: String
        let epochNumber: Int
        let required: Bool
    }
    struct E2EEBlock: Decodable {
        let descriptor: Descriptor
        let epochKeyB64: String
    }
    struct CallBlock: Decodable {
        let conversationId: String
        let callId: String
    }

    let version: Int
    let runId: String
    let livekit: LiveKitBlock
    let e2ee: E2EEBlock
    let call: CallBlock

    var liveKitURL: URL { URL(string: livekit.wsUrl)! }
    var epochKey: Data { Data(base64Encoded: e2ee.epochKeyB64)! }
    var ios: Participant { participant("ios")! }
    var web: Participant { participant("web")! }

    static func loadFromRunner() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        let inline = environment["SQ_LIVEKIT_MEDIA_QA_FIXTURE_B64"]
            ?? environment["TEST_RUNNER_SQ_LIVEKIT_MEDIA_QA_FIXTURE_B64"]
        let path = environment["SQ_LIVEKIT_MEDIA_QA_FIXTURE_PATH"]
            ?? environment["TEST_RUNNER_SQ_LIVEKIT_MEDIA_QA_FIXTURE_PATH"]
        guard inline != nil || path != nil else {
            throw XCTSkip("LiveKit media QA fixture not provided")
        }
        guard !(inline != nil && path != nil) else {
            throw LiveKitMediaQAError.failed("ambiguous-media-qa-fixture")
        }
        let data: Data
        if let inline {
            guard inline.utf8.count <= 96 * 1_024, let decoded = Data(base64Encoded: inline) else {
                throw LiveKitMediaQAError.failed("invalid-media-qa-fixture-base64")
            }
            data = decoded
        } else {
            guard let path else { throw LiveKitMediaQAError.failed("missing-media-qa-fixture") }
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        }
        guard data.count <= 64 * 1_024 else {
            throw LiveKitMediaQAError.failed("media-qa-fixture-too-large")
        }
        let fixture = try JSONDecoder().decode(Self.self, from: data)
        guard fixture.version == 1,
              !fixture.runId.isEmpty, fixture.runId.count <= 96,
              fixture.e2ee.descriptor.version == 1,
              fixture.e2ee.descriptor.provider == "LIVEKIT_FRAME_CRYPTOR_V1",
              fixture.e2ee.descriptor.required,
              fixture.e2ee.descriptor.epochNumber > 0,
              fixture.epochKey.count == 32,
              validOpaqueID(fixture.call.conversationId),
              validOpaqueID(fixture.call.callId),
              strictLoopbackLiveKitURL(fixture.liveKitURL),
              let ios = fixture.participant("ios"),
              let web = fixture.participant("web"),
              ios.identity != web.identity,
              ios.token != web.token else {
            throw LiveKitMediaQAError.failed("invalid-media-qa-fixture")
        }
        return fixture
    }

    private func participant(_ platform: String) -> Participant? {
        let matches = livekit.participants.filter { $0.platform.lowercased() == platform }
        guard matches.count == 1, let value = matches.first,
              !value.identity.isEmpty, value.identity.count <= 160,
              value.token.count >= 16, value.token.count <= 32_768,
              value.token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return value
    }

    private static func validOpaqueID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{15,127}$"#, options: .regularExpression) != nil
    }

    private static func strictLoopbackLiveKitURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["ws", "wss"].contains(components.scheme?.lowercased() ?? ""),
              ["localhost", "127.0.0.1", "::1"].contains(components.host?.lowercased() ?? ""),
              components.port != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return false }
        return true
    }
}

private final class LiveKitMediaQACountingRenderer: NSObject, VideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0

    @MainActor var isAdaptiveStreamEnabled: Bool { true }
    @MainActor var adaptiveStreamSize: CGSize { CGSize(width: 320, height: 240) }

    nonisolated func render(frame: VideoFrame) {
        lock.lock()
        frames += 1
        lock.unlock()
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}

@MainActor
private func waitForLiveKitMediaQA(
    _ label: String,
    attempts: Int = 750,
    predicate: @escaping @MainActor () -> Bool
) async throws {
    for _ in 0..<attempts {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw LiveKitMediaQAError.failed("media-qa-timeout:\(label)")
}
#endif
