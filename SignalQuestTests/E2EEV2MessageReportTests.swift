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

    func testAnEditedMessageIsReportedAsTheReporterSawIt() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let original = try message(1, text: "Salut")
        let edit = try message(2, body: .edit(targetRef: original.messageRef, text: "Insulte"), sentAtMs: nowMs + 10)
        let store = try storeWith([original, edit], owner: fixture.session.ownerScopeId)
        let moderation = P256.KeyAgreement.PrivateKey()
        let bodies = LockedData()
        MockURLProtocol.requestHandler = { request in
            let raw = E2EEV2AccountFixture.rawBody(request)
            bodies.append(raw)
            let root = try XCTUnwrap(try E2EEV2CanonicalJSON.parseStrict(raw).objectValue)
            let clear = try E2EEV2Report.parseClear(try XCTUnwrap(root["clear"]?.stringValue))
            return E2EEV2AccountFixture.response(request, E2EEV2CanonicalJSON.encode(.object(["reportId": .string(clear.reportId)])))
        }
        // Le même message choisi deux fois ne part qu'une fois.
        try await E2EEV2MessageReport.send(
            refs: [original.messageRef, original.messageRef], reason: .harassment, conversationId: conversationId,
            ownerScopeId: fixture.session.ownerScopeId, store: store, sender: sender(fixture, key: moderation.publicKey)
        )
        let root = try XCTUnwrap(try E2EEV2CanonicalJSON.parseStrict(try XCTUnwrap(bodies.all.first)).objectValue)
        let clear = try XCTUnwrap(root["clear"]?.stringValue)
        let parsed = try E2EEV2Report.parseClear(clear)
        XCTAssertEqual(parsed.reason, "HARASSMENT")
        XCTAssertEqual(parsed.items.map(\.envelopeId), [original.envelopeId, edit.envelopeId], "Le message, puis son édition")
        let opened = try E2EEV2Report.open(
            clearJSON: clear,
            enc: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(root["encB64"]?.stringValue))),
            sealed: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(root["sealedB64"]?.stringValue))),
            moderationKey: moderation
        )
        XCTAssertEqual(opened.map(\.payload), [original.payloadBytes, edit.payloadBytes], "La modération lit aussi le texte modifié")
        for (item, clearItem) in zip(opened, parsed.items) {
            let source = try XCTUnwrap([original, edit].first { $0.envelopeId == item.envelopeId })
            XCTAssertTrue(E2EEV2Report.verifyFrankTag(
                item: item, clearItem: clearItem, conversationId: conversationId, senderDeviceId: brunoDevice,
                clientRequestId: source.clientRequestId
            ))
        }
    }

    func testTooManyMessagesOrATooLargeReportAskForASmallerSelection() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let key = P256.KeyAgreement.PrivateKey().publicKey
        MockURLProtocol.requestHandler = { request in
            XCTFail("Aucune requête")
            return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 500)
        }
        let refs = (0..<51).map { "ref_many_\(String(format: "%033d", $0))" }
        await XCTAssertThrowsAsync(
            try await E2EEV2MessageReport.send(
                refs: refs, reason: .spam, conversationId: conversationId, ownerScopeId: fixture.session.ownerScopeId,
                store: E2EEV2MessageStoreV2(rootURL: root, keyStore: InMemoryTokenStore()), sender: sender(fixture, key: key)
            ),
            E2EEV2MessageReport.Failure.tooLarge
        )
        // Six longs messages dépassent 512 Kio une fois la charge encodée deux fois.
        let long = try (1...6).map { try message($0, text: String(repeating: "x", count: 60_000)) }
        let store = try storeWith(long, owner: fixture.session.ownerScopeId)
        await XCTAssertThrowsAsync(
            try await E2EEV2MessageReport.send(
                refs: long.map(\.messageRef), reason: .spam, conversationId: conversationId,
                ownerScopeId: fixture.session.ownerScopeId, store: store, sender: sender(fixture, key: key)
            ),
            E2EEV2MessageReport.Failure.tooLarge
        )
    }

    func testTheDailyLimitIsSaidPlainlyAndOnlyForItsCode() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let kept = try message(1, text: "Gardé")
        let store = try storeWith([kept], owner: fixture.session.ownerScopeId)
        let code = LockedData()
        code.append(Data("E2EE_REPORT_QUOTA".utf8))
        MockURLProtocol.requestHandler = { request in
            let value = String(decoding: code.all.last ?? Data(), as: UTF8.self)
            return E2EEV2AccountFixture.response(request, Data(#"{"error":"Trop de signalements","code":"\#(value)"}"#.utf8), status: 429)
        }
        let key = P256.KeyAgreement.PrivateKey().publicKey
        await XCTAssertThrowsAsync(
            try await E2EEV2MessageReport.send(
                refs: [kept.messageRef], reason: .spam, conversationId: conversationId,
                ownerScopeId: fixture.session.ownerScopeId, store: store, sender: sender(fixture, key: key)
            ),
            E2EEV2MessageReport.Failure.dailyLimit
        )
        // Un autre 429 n'est qu'un ralentissement passager.
        code.append(Data("RATE_LIMITED".utf8))
        await XCTAssertThrowsAsync(
            try await E2EEV2MessageReport.send(
                refs: [kept.messageRef], reason: .spam, conversationId: conversationId,
                ownerScopeId: fixture.session.ownerScopeId, store: store, sender: sender(fixture, key: key)
            ),
            E2EEV2MessageReport.Failure.failed
        )
    }

    func testAHeavilyEditedMessageStaysReportable() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let original = try message(1, text: "Salut")
        let long = try (2...7).map {
            try message($0, body: .edit(targetRef: original.messageRef, text: String(repeating: "x", count: 60_000)), sentAtMs: nowMs + Int64($0))
        }
        let last = try message(8, body: .edit(targetRef: original.messageRef, text: "Insulte"), sentAtMs: nowMs + 100)
        let store = try storeWith([original] + long + [last], owner: fixture.session.ownerScopeId)
        let moderation = P256.KeyAgreement.PrivateKey()
        let bodies = LockedData()
        MockURLProtocol.requestHandler = { request in
            let raw = E2EEV2AccountFixture.rawBody(request)
            bodies.append(raw)
            let root = try XCTUnwrap(try E2EEV2CanonicalJSON.parseStrict(raw).objectValue)
            let clear = try E2EEV2Report.parseClear(try XCTUnwrap(root["clear"]?.stringValue))
            return E2EEV2AccountFixture.response(request, E2EEV2CanonicalJSON.encode(.object(["reportId": .string(clear.reportId)])))
        }
        try await E2EEV2MessageReport.send(
            refs: [original.messageRef], reason: .harassment, conversationId: conversationId,
            ownerScopeId: fixture.session.ownerScopeId, store: store, sender: sender(fixture, key: moderation.publicKey)
        )
        XCTAssertEqual(bodies.all.count, 1, "Un seul envoi, une fois le rapport ajusté")
        let root = try XCTUnwrap(try E2EEV2CanonicalJSON.parseStrict(try XCTUnwrap(bodies.all.first)).objectValue)
        let ids = try E2EEV2Report.parseClear(try XCTUnwrap(root["clear"]?.stringValue)).items.map(\.envelopeId)
        XCTAssertTrue(ids.contains(last.envelopeId), "La version affichée part toujours")
        XCTAssertTrue(ids.contains(original.envelopeId), "L'original suit")
        XCTAssertLessThan(ids.count, 8, "Les plus anciennes éditions intermédiaires restent de côté")
    }

    func testNothingLeavesForAMessageThatIsNotFullyKept() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let kept = try message(1, text: "Gardé")
        let store = try storeWith([kept], owner: fixture.session.ownerScopeId)
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
        let store = try storeWith([kept], owner: fixture.session.ownerScopeId)
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

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Data] = []
        func append(_ value: Data) { lock.withLock { values.append(value) } }
        var all: [Data] { lock.withLock { values } }
    }

    private func sender(_ fixture: E2EEV2AccountFixture, key: P256.KeyAgreement.PublicKey) -> E2EEV2ReportSenderV2 {
        E2EEV2ReportSenderV2(
            api: fixture.api, identityStore: fixture.identity,
            moderationKey: .init(keyId: "moderation_key_01J7ABCD", publicKeyX963B64: key.x963Representation.base64EncodedString()),
            expectedSession: fixture.session
        )
    }

    private func storeWith(_ messages: [E2EEV2ReceivedMessageV2], owner: String) throws -> E2EEV2MessageStoreV2 {
        let store = E2EEV2MessageStoreV2(rootURL: root, keyStore: InMemoryTokenStore())
        try store.apply(messages, equivocal: [], cursor: messages.map(\.sequence).max() ?? 0,
                        conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        return store
    }

    private func message(_ sequence: Int, text: String) throws -> E2EEV2ReceivedMessageV2 {
        try message(sequence, body: .text(text))
    }

    private func message(
        _ sequence: Int, body: E2EEV2ContentPayloadV2.Body, sentAtMs: Int64? = nil
    ) throws -> E2EEV2ReceivedMessageV2 {
        let clientRequestId = "message_report_000000000\(sequence)"
        let payload = E2EEV2ContentPayloadV2(
            sentAtMs: sentAtMs ?? nowMs, counter: Int64(sequence), replyToRef: nil, mentions: [], body: body
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
