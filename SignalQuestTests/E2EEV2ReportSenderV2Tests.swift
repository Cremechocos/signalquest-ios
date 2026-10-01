import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 5 (plan 3) : signalement en deux parties (§11, D.10, E.3).
final class E2EEV2ReportSenderV2Tests: XCTestCase {
    private let conversationId = "conversation_01J7ABCD23456789"
    private let brunoDevice = "device_bruno_android_01J7ABCD"

    func testUnavailableWithoutAPinnedModerationKey() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        MockURLProtocol.requestHandler = { request in
            XCTFail("Aucune requête sans clé de modération")
            return E2EEV2AccountFixture.response(request, Data("{}".utf8), status: 500)
        }
        let sender = E2EEV2ReportSenderV2(api: fixture.api, identityStore: fixture.identity, moderationKey: nil, expectedSession: fixture.session)
        let result = await sender.report([try message(1)], reason: "SPAM", conversationId: conversationId, expectedOwnerScopeId: fixture.session.ownerScopeId)
        XCTAssertEqual(result, .unavailable)
        XCTAssertNil(E2EEV2ModerationKey.pinned, "Aucune clé épinglée avant l'outil hors ligne (SRV-A6)")
    }

    func testOnlyTheModerationKeyOpensTheSealedPart() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let moderation = P256.KeyAgreement.PrivateKey()
        let pinned = E2EEV2ModerationKey.Pinned(
            keyId: "moderation_key_01J7ABCD", publicKeyX963B64: moderation.publicKey.x963Representation.base64EncodedString()
        )
        let captured = LockedRequests()
        let rawBodies = RawBodies()
        MockURLProtocol.requestHandler = { request in
            let raw = E2EEV2AccountFixture.rawBody(request)
            rawBodies.append(raw)
            captured.append(request, body: [:])
            let root = try XCTUnwrap(try E2EEV2CanonicalJSON.parseStrict(raw).objectValue)
            let clear = try XCTUnwrap(root["clear"]?.stringValue)
            let reportId = try E2EEV2Report.parseClear(clear).reportId
            return E2EEV2AccountFixture.response(request, E2EEV2CanonicalJSON.encode(.object(["reportId": .string(reportId)])))
        }
        let sender = E2EEV2ReportSenderV2(api: fixture.api, identityStore: fixture.identity, moderationKey: pinned, expectedSession: fixture.session)
        let messages = [try message(2, text: "Deuxième"), try message(1, text: "Premier")]
        let result = await sender.report(messages, reason: "HARASSMENT", conversationId: conversationId, expectedOwnerScopeId: fixture.session.ownerScopeId)
        guard case .sent(let reportId) = result else { return XCTFail("Signalement refusé : \(result)") }
        XCTAssertEqual(captured.first?.0.url?.path, "/api/e2ee/v2/reports")

        let root = try XCTUnwrap(try E2EEV2CanonicalJSON.parseStrict(try XCTUnwrap(rawBodies.all.first)).objectValue)
        XCTAssertEqual(Set(root.keys), ["clear", "encB64", "sealedB64", "moderationKeyId"])
        XCTAssertEqual(root["moderationKeyId"]?.stringValue, pinned.keyId)
        let clear = try XCTUnwrap(root["clear"]?.stringValue)
        let parsed = try E2EEV2Report.parseClear(clear)
        XCTAssertEqual(parsed.reportId, reportId)
        XCTAssertEqual(parsed.reason, "HARASSMENT")
        XCTAssertEqual(parsed.items.map(\.envelopeId), ["envelope_report_0000000001", "envelope_report_0000000002"], "Dans l'ordre des messages")
        XCTAssertFalse(clear.contains("Premier"), "La partie en clair ne porte aucun contenu")

        let enc = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(root["encB64"]?.stringValue)))
        let sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(root["sealedB64"]?.stringValue)))
        let opened = try E2EEV2Report.open(clearJSON: clear, enc: enc, sealed: sealed, moderationKey: moderation)
        XCTAssertEqual(opened.count, 2)
        for (item, clearItem) in zip(opened, parsed.items) {
            let source = try XCTUnwrap(messages.first { $0.envelopeId == item.envelopeId })
            XCTAssertEqual(item.payload, source.payloadBytes)
            XCTAssertTrue(E2EEV2Report.verifyFrankTag(
                item: item, clearItem: clearItem, conversationId: conversationId, senderDeviceId: brunoDevice,
                clientRequestId: source.clientRequestId
            ), "L'outil de modération recalcule le frankTag")
        }
        XCTAssertThrowsError(try E2EEV2Report.open(clearJSON: clear, enc: enc, sealed: sealed, moderationKey: P256.KeyAgreement.PrivateKey()),
                             "Aucune autre clé n'ouvre la partie scellée")
        let otherClear = clear.replacingOccurrences(of: "HARASSMENT", with: "SPAM")
        XCTAssertThrowsError(try E2EEV2Report.open(clearJSON: otherClear, enc: enc, sealed: sealed, moderationKey: moderation),
                             "La partie scellée est liée à sa partie en clair")
    }

    func testRefusesAnInvalidReport() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let pinned = E2EEV2ModerationKey.Pinned(
            keyId: "moderation_key_01J7ABCD",
            publicKeyX963B64: P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
        )
        MockURLProtocol.requestHandler = { request in
            E2EEV2AccountFixture.response(request, E2EEV2CanonicalJSON.encode(.object(["reportId": .string("report_someone_else_0001")])))
        }
        let sender = E2EEV2ReportSenderV2(api: fixture.api, identityStore: fixture.identity, moderationKey: pinned, expectedSession: fixture.session)
        let owner = fixture.session.ownerScopeId
        let invalid = E2EEV2ReportResultV2.failure(.init(kind: .localState, message: "invalid-e2ee-report"))
        let empty = await sender.report([], reason: "SPAM", conversationId: conversationId, expectedOwnerScopeId: owner)
        XCTAssertEqual(empty, invalid)
        let tooMany = await sender.report(try (1...51).map { try message($0) }, reason: "SPAM", conversationId: conversationId, expectedOwnerScopeId: owner)
        XCTAssertEqual(tooMany, invalid, "50 messages au plus")
        let twice = await sender.report([try message(1), try message(1)], reason: "SPAM", conversationId: conversationId, expectedOwnerScopeId: owner)
        XCTAssertEqual(twice, invalid, "Un message une seule fois")
        let unknownReason = await sender.report([try message(1)], reason: "BORING", conversationId: conversationId, expectedOwnerScopeId: owner)
        XCTAssertEqual(unknownReason, invalid)
        let wrongEcho = await sender.report([try message(1)], reason: "SPAM", conversationId: conversationId, expectedOwnerScopeId: owner)
        XCTAssertEqual(wrongEcho, .failure(.init(kind: .localState, message: "invalid-e2ee-report-response")),
                       "Le serveur rend l'identifiant du rapport envoyé")
    }

    // MARK: Aides

    /// Un message reçu de Bruno, franké.
    private func message(_ sequence: Int, text: String = "Message") throws -> E2EEV2ReceivedMessageV2 {
        let clientRequestId = "message_report_000000000\(sequence)"
        let payload = try E2EEV2ContentPayloadV2(
            sentAtMs: 1_790_000_000_000, counter: Int64(sequence), replyToRef: nil, mentions: [], body: .text(text)
        )
        let bytes = try payload.encoded()
        let fk = Data((0..<32).map { UInt8($0 + sequence) })
        return E2EEV2ReceivedMessageV2(
            envelopeId: String(format: "envelope_report_%010d", sequence), sequence: Int64(sequence),
            messageRef: E2EEV2MessageRef.make(conversationId: conversationId, senderDeviceId: brunoDevice, clientRequestId: clientRequestId),
            senderUserId: "user_bruno_01J7ABCD23456789", senderDeviceId: brunoDevice, clientRequestId: clientRequestId,
            epochNumber: 1,
            frankTagB64: E2EEV2Franking.frankTag(
                fk: fk, conversationId: conversationId, senderDeviceId: brunoDevice, clientRequestId: clientRequestId, payload: bytes
            ).base64EncodedString(),
            serverTagB64: Data(repeating: UInt8(sequence), count: 32).base64EncodedString(), serverTimeMs: 1_790_000_000_250,
            keyId: "server_tag_key_01J7ABCD", payload: payload, payloadBytes: bytes, fk: fk, expiresAtMs: nil
        )
    }
}

private final class RawBodies: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []

    func append(_ body: Data) {
        lock.lock(); defer { lock.unlock() }
        items.append(body)
    }

    var all: [Data] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
