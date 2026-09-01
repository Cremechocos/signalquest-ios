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

    func testE2EEConversationCannotFallBackToTransportOnlyCall() {
        XCTAssertTrue(CallLifecyclePolicy.canUseE2EECall(conversationE2EE: false, verifiedV2: false))
        XCTAssertFalse(CallLifecyclePolicy.canUseE2EECall(conversationE2EE: true, verifiedV2: false))
        XCTAssertTrue(CallLifecyclePolicy.canUseE2EECall(conversationE2EE: true, verifiedV2: true))
    }

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
        XCTAssertFalse(E2EEV2CallDataPolicy.accepts(
            requiresE2EE: true,
            senderIdentity: "remote",
            encryptionType: .none
        ))
        XCTAssertFalse(E2EEV2CallDataPolicy.accepts(
            requiresE2EE: true,
            senderIdentity: nil,
            encryptionType: .gcm
        ))
        XCTAssertTrue(E2EEV2CallDataPolicy.accepts(
            requiresE2EE: true,
            senderIdentity: "remote",
            encryptionType: .gcm
        ))
        #endif
    }

    func testE2EECryptorAcceptsRatchetAndRejectsRevokedOrMissingKeys() {
        #if canImport(LiveKit)
        let verification = E2EEV2LiveKitVerification()
        verification.expectParticipant("local")
        verification.expectParticipant("remote")
        verification.expect(participantID: "local", trackID: "local-audio")
        verification.expect(participantID: "remote", trackID: "remote-audio")
        verification.update("local-audio", state: .ok)
        verification.update("remote-audio", state: .ok)
        XCTAssertTrue(verification.isVerified)

        verification.markAllPending()
        XCTAssertFalse(verification.isVerified)
        verification.update("local-audio", state: .key_ratcheted)
        verification.update("remote-audio", state: .key_ratcheted)
        XCTAssertTrue(verification.isVerified, "Une rotation LiveKit ratchetée reste une preuve valide")

        verification.update("remote-audio", state: .missing_key)
        XCTAssertFalse(verification.isVerified)
        XCTAssertTrue(E2EEV2CallCryptorPolicy.isTerminalFailure(.missing_key))
        XCTAssertTrue(E2EEV2CallCryptorPolicy.isTerminalFailure(.decryption_failed))
        XCTAssertFalse(E2EEV2CallCryptorPolicy.isTerminalFailure(.key_ratcheted))
        #endif
    }

    func testPendingE2EECallRequiresAnExactDescriptor() throws {
        let commitment = Data(repeating: 7, count: 32).base64EncodedString()
        let data = Data(#"""
        {
          "pending": true,
          "callId": "call_1234567890123456",
          "conversationId": "conversation_1234567890123456",
          "callType": "AUDIO",
          "status": "RINGING",
          "e2eeRequired": true,
          "e2ee": {
            "version": 1,
            "provider": "LIVEKIT_FRAME_CRYPTOR_V1",
            "epochId": "epoch_1234567890123456",
            "epochNumber": 4,
            "keyCommitmentB64": "\#(commitment)",
            "required": true,
            "keyId": "epoch_1234567890123456"
          }
        }
        """#.utf8)

        let call = try XCTUnwrap(decoder.decode(PendingCallsResponse.self, from: data).calls.first)

        XCTAssertTrue(call.e2eeRequired)
        XCTAssertEqual(call.e2ee?.epochNumber, 4)
        XCTAssertEqual(call.e2ee?.keyId, "epoch_1234567890123456")
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
        XCTAssertEqual(
            IncomingCallE2EEContract.parse(["e2eeRequired": true]),
            .invalid
        )

        let commitment = Data(repeating: 3, count: 32).base64EncodedString()
        let descriptor: [String: Any] = [
            "version": 1,
            "provider": "LIVEKIT_FRAME_CRYPTOR_V1",
            "epochId": "epoch_1234567890123456",
            "epochNumber": 9,
            "keyCommitmentB64": commitment,
            "required": true,
            "keyId": "epoch_1234567890123456",
        ]
        let parsed = IncomingCallE2EEContract.parse([
            "e2eeRequired": true,
            "e2ee": descriptor,
        ])
        guard case .required(let value) = parsed else {
            return XCTFail("Le descripteur PushKit exact doit être accepté")
        }
        XCTAssertEqual(value.epochNumber, 9)

        var malformed = descriptor
        malformed["epochKey"] = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertEqual(
            IncomingCallE2EEContract.parse([
                "e2eeRequired": true,
                "e2ee": malformed,
            ]),
            .invalid
        )
    }

    func testE2EECallWireSignsContextOnlyAndRejectsDowngradedResponse() throws {
        let commitment = Data(repeating: 9, count: 32).base64EncodedString()
        let context = E2EEV2CallEpochContext(
            version: 1,
            provider: "LIVEKIT_FRAME_CRYPTOR_V1",
            epochId: "epoch_1234567890123456",
            epochNumber: 5,
            keyCommitmentB64: commitment
        )
        let body = try CallE2EEV2Wire.initiateBody(
            conversationId: "conversation_1234567890123456",
            type: "VIDEO",
            context: context
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let e2ee = try XCTUnwrap(object["e2ee"] as? [String: Any])

        XCTAssertEqual(Set(object.keys), Set(["conversationId", "type", "e2ee"]))
        XCTAssertEqual(
            Set(e2ee.keys),
            Set(["version", "provider", "epochId", "epochNumber", "keyCommitmentB64"])
        )
        XCTAssertNil(e2ee["epochKey"])

        let validResponse = Data(#"""
        {
          "callId": "call_1234567890123456",
          "roomName": "call-room",
          "token": "livekit-token-value",
          "wsUrl": "wss://livekit.example.test",
          "type": "VIDEO",
          "e2ee": {
            "version": 1,
            "provider": "LIVEKIT_FRAME_CRYPTOR_V1",
            "epochId": "epoch_1234567890123456",
            "epochNumber": 5,
            "keyCommitmentB64": "\#(commitment)",
            "required": true,
            "keyId": "epoch_1234567890123456"
          }
        }
        """#.utf8)
        XCTAssertEqual(
            try CallE2EEV2Wire.decodeBoundSession(validResponse, expectedContext: context).id,
            "call_1234567890123456"
        )

        let downgraded = Data(#"""
        {
          "callId": "call_1234567890123456",
          "roomName": "call-room",
          "token": "livekit-token-value",
          "wsUrl": "wss://livekit.example.test",
          "type": "VIDEO"
        }
        """#.utf8)
        XCTAssertThrowsError(try CallE2EEV2Wire.decodeBoundSession(downgraded, expectedContext: context))
    }

    func testIncomingE2EEAnswerUsesTheDescriptorHistoricalEpoch() throws {
        let key = Data((0..<32).map(UInt8.init))
        let commitment = try E2EEV2EpochCrypto.keyCommitment(key)
        let stored = E2EEV2StoredEpochKey(
            conversationId: "conversation_1234567890123456",
            epochId: "epoch_1234567890123456",
            epochNumber: 8,
            keyCommitmentB64: commitment,
            epochKey: key
        )
        let descriptor = E2EEV2CallSessionDescriptor(
            version: 1,
            provider: "LIVEKIT_FRAME_CRYPTOR_V1",
            epochId: stored.epochId,
            epochNumber: stored.epochNumber,
            keyCommitmentB64: stored.keyCommitmentB64,
            required: true,
            keyId: stored.epochId
        )

        XCTAssertEqual(
            E2EEV2CallBridge.prepareAnswerContractPreview(
                conversationId: stored.conversationId,
                descriptor: descriptor,
                epochLoader: { stored }
            ),
            .prepared(.init(
                version: 1,
                provider: "LIVEKIT_FRAME_CRYPTOR_V1",
                epochId: stored.epochId,
                epochNumber: stored.epochNumber,
                keyCommitmentB64: stored.keyCommitmentB64
            ))
        )

        let wrongDescriptor = E2EEV2CallSessionDescriptor(
            version: descriptor.version,
            provider: descriptor.provider,
            epochId: descriptor.epochId,
            epochNumber: descriptor.epochNumber + 1,
            keyCommitmentB64: descriptor.keyCommitmentB64,
            required: true,
            keyId: descriptor.keyId
        )
        XCTAssertEqual(
            E2EEV2CallBridge.prepareAnswerContractPreview(
                conversationId: stored.conversationId,
                descriptor: wrongDescriptor,
                epochLoader: { stored }
            ),
            .localEpochUnavailable
        )
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
        let commitment = Data(repeating: 11, count: 32).base64EncodedString()
        let context = E2EEV2CallEpochContext(
            version: 1,
            provider: "LIVEKIT_FRAME_CRYPTOR_V1",
            epochId: "epoch_1234567890123456",
            epochNumber: 12,
            keyCommitmentB64: commitment
        )
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
            XCTAssertEqual((object["e2ee"] as? [String: Any])?["epochNumber"] as? Int, 12)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"""
            {
              "callId": "call_1234567890123456",
              "roomName": "call-room",
              "token": "livekit-token-value",
              "wsUrl": "wss://livekit.example.test",
              "type": "AUDIO",
              "e2ee": {
                "version": 1,
                "provider": "LIVEKIT_FRAME_CRYPTOR_V1",
                "epochId": "epoch_1234567890123456",
                "epochNumber": 12,
                "keyCommitmentB64": "\#(commitment)",
                "required": true,
                "keyId": "epoch_1234567890123456"
              }
            }
            """#.utf8))
        }

        let session = try await service.initiate(
            conversationId: "conversation_1234567890123456",
            mode: "audio",
            e2ee: context
        )

        XCTAssertEqual(requestCount, 1, "Une preuve signée ne doit jamais être rejouée automatiquement")
        XCTAssertTrue(session.e2eeRequired)
        XCTAssertEqual(session.e2ee?.epochNumber, context.epochNumber)
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
              fixture.e2ee.descriptor.provider == E2EEV2CallBridge.provider,
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
