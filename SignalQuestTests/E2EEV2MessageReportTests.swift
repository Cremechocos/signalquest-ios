import CryptoKit
import XCTest
@testable import SignalQuest

/// Plan 3, lot 5 : signaler un message d'une conversation v2 depuis ce que
/// l'appareil a gardé (§11, D.10).
final class E2EEV2MessageReportTests: XCTestCase {
    private let conversationId = "conversation_report_01J7ABCD2345"
    private let bruno = "user_bruno_01J7ABCD23456789"
    private let brunoDevice = "device_bruno_android_01J7ABCD"
    private let nowMs: Int64 = 1_790_000_000_000
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-report-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testMessageReasonsMapToReasonsOfTheClearPart() {
        for reason in E2EEV2MessageReport.reasons {
            XCTAssertTrue(E2EEV2Report.reasons.contains(E2EEV2MessageReport.wireReason(reason)), "\(reason)")
        }
        XCTAssertEqual(E2EEV2MessageReport.wireReason(.harassment), "HARASSMENT")
        XCTAssertEqual(E2EEV2MessageReport.wireReason(.misleading), "OTHER")
    }

    func testAKeptMessageIsReportedSealedForModeration() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let store = try storeWith(message(1, text: "Message signalé"), owner: fixture.session.ownerScopeId)
        let moderation = P256.KeyAgreement.PrivateKey()
        let reasons = LockedStrings()
        MockURLProtocol.requestHandler = { request in
            let root = try XCTUnwrap(try E2EEV2CanonicalJSON.parseStrict(E2EEV2AccountFixture.rawBody(request)).objectValue)
            let clear = try E2EEV2Report.parseClear(try XCTUnwrap(root["clear"]?.stringValue))
            reasons.append(clear.reason)
            return E2EEV2AccountFixture.response(request, E2EEV2CanonicalJSON.encode(.object(["reportId": .string(clear.reportId)])))
        }
        let ref = try message(1, text: "Message signalé").messageRef
        try await E2EEV2MessageReport.send(
            refs: [ref], reason: .harassment, conversationId: conversationId, ownerScopeId: fixture.session.ownerScopeId,
            store: store, sender: sender(fixture, key: moderation.publicKey)
        )
        XCTAssertEqual(reasons.all, ["HARASSMENT"])
    }

    func testNothingLeavesForAMessageThatIsNotFullyKept() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let kept = try message(1, text: "Gardé")
        let store = try storeWith(kept, owner: fixture.session.ownerScopeId)
        MockURLProtocol.requestHandler = { request in
            XCTFail("Aucune requête")
            return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 500)
        }
        let key = P256.KeyAgreement.PrivateKey().publicKey
        await XCTAssertThrowsAsync(
            try await E2EEV2MessageReport.send(
                refs: ["ref_unknown_00000000000000000000000000000"], reason: .spam, conversationId: conversationId,
                ownerScopeId: fixture.session.ownerScopeId, store: store, sender: sender(fixture, key: key)
            ),
            E2EEV2MessageReport.Failure.notReportable
        )
        await XCTAssertThrowsAsync(
            try await E2EEV2MessageReport.send(
                refs: [kept.messageRef, "ref_unknown_00000000000000000000000000000"], reason: .spam,
                conversationId: conversationId, ownerScopeId: fixture.session.ownerScopeId, store: store,
                sender: sender(fixture, key: key)
            ),
            E2EEV2MessageReport.Failure.notReportable, "Jamais une partie seulement de ce que l'utilisateur a choisi"
        )
        await XCTAssertThrowsAsync(
            try await E2EEV2MessageReport.send(
                refs: [], reason: .spam, conversationId: conversationId, ownerScopeId: fixture.session.ownerScopeId,
                store: store, sender: sender(fixture, key: key)
            ),
            E2EEV2MessageReport.Failure.notReportable
        )
    }

    func testWithoutAModerationKeyReportingIsUnavailable() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let kept = try message(1, text: "Gardé")
        let store = try storeWith(kept, owner: fixture.session.ownerScopeId)
        MockURLProtocol.requestHandler = { request in
            XCTFail("Aucune requête sans clé de modération")
            return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 500)
        }
        await XCTAssertThrowsAsync(
            try await E2EEV2MessageReport.send(
                refs: [kept.messageRef], reason: .spam, conversationId: conversationId,
                ownerScopeId: fixture.session.ownerScopeId, store: store,
                sender: E2EEV2ReportSenderV2(api: fixture.api, identityStore: fixture.identity, moderationKey: nil, expectedSession: fixture.session)
            ),
            E2EEV2MessageReport.Failure.unavailable
        )
        XCTAssertNotNil(E2EEV2MessageReport.Failure.unavailable.errorDescription)
    }

    // MARK: Outils

    private final class LockedStrings: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
    }

    private func sender(_ fixture: E2EEV2AccountFixture, key: P256.KeyAgreement.PublicKey) -> E2EEV2ReportSenderV2 {
        E2EEV2ReportSenderV2(
            api: fixture.api, identityStore: fixture.identity,
            moderationKey: .init(keyId: "moderation_key_01J7ABCD", publicKeyX963B64: key.x963Representation.base64EncodedString()),
            expectedSession: fixture.session
        )
    }

    private func storeWith(_ message: E2EEV2ReceivedMessageV2, owner: String) throws -> E2EEV2MessageStoreV2 {
        let store = E2EEV2MessageStoreV2(rootURL: root, keyStore: InMemoryTokenStore())
        try store.apply([message], equivocal: [], cursor: message.sequence, conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        return store
    }

    private func message(_ sequence: Int, text: String) throws -> E2EEV2ReceivedMessageV2 {
        let clientRequestId = "message_report_000000000\(sequence)"
        let payload = E2EEV2ContentPayloadV2(
            sentAtMs: nowMs, counter: Int64(sequence), replyToRef: nil, mentions: [], body: .text(text)
        )
        let bytes = try payload.encoded()
        let fk = Data(repeating: UInt8(sequence), count: 32)
        return E2EEV2ReceivedMessageV2(
            envelopeId: "envelope_report_000000000\(sequence)", sequence: Int64(sequence),
            messageRef: E2EEV2MessageRef.make(conversationId: conversationId, senderDeviceId: brunoDevice, clientRequestId: clientRequestId),
            senderUserId: bruno, senderDeviceId: brunoDevice, clientRequestId: clientRequestId, epochNumber: 1,
            frankTagB64: E2EEV2Franking.frankTag(
                fk: fk, conversationId: conversationId, senderDeviceId: brunoDevice, clientRequestId: clientRequestId, payload: bytes
            ).base64EncodedString(),
            serverTagB64: Data(repeating: 9, count: 32).base64EncodedString(), serverTimeMs: nowMs + 250,
            keyId: "server_tag_key_01J7ABCD", payload: payload, payloadBytes: bytes, fk: fk, expiresAtMs: nil
        )
    }
}
