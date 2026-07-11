import XCTest
@testable import SignalQuest

final class CallReliabilityTests: XCTestCase {
    private let decoder = JSONDecoder.signalQuest

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

    func testScreenSharingRemainsDisabledByDefault() {
        XCTAssertFalse(SQFeatures.callScreenSharingEnabled)
    }
}
