import XCTest
@testable import SignalQuest

/// E2EE-AUTO §8 : l'importeur des messages v1 (sources, lots de 5, issues du
/// serveur) et l'import contesté.
final class E2EEAutoHistoryImporterTests: XCTestCase {
    private let conversationId = "conversation_1234567890"
    private let alice = MessageUser(id: "user_123456789012345", name: "Alice", email: "alice@example.test", avatarUrl: nil)

    private func v1(
        _ id: String, at iso: String = "2026-08-23T00:00:00.000Z", encrypted: Bool = true, metadata: String? = nil,
        expiresAt: Date? = nil, deleted: Bool = false, attachments: [MessageAttachment] = []
    ) -> MessageItem {
        MessageItem(
            id: id, conversationId: conversationId, senderId: alice.id, kind: "TEXT", content: nil,
            e2eeVersion: encrypted ? 2 : nil, e2eeIvB64: encrypted ? "AAAA" : nil, e2eeCiphertextB64: encrypted ? "AAAA" : nil,
            e2eeAadB64: nil, metadata: metadata, createdAt: ISO8601DateFormatter.withFractions.date(from: iso), editedAt: nil,
            deletedAt: deleted ? Date() : nil, expiresAt: expiresAt, replyToId: nil, threadReplyCount: nil, sender: alice,
            attachments: attachments, reactions: []
        )
    }

    private func vector() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-v2/history-migration-v1.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Le message v1 du vecteur `history-migration-v1`, déchiffré ici, donne ses
    /// octets canoniques, son condensat et son `clientRequestId`, à l'octet.
    func testADecryptedV1MessageBecomesTheVectorImport() throws {
        let vector = try vector()
        let item = v1("message_123456789012", metadata: #"{"formatted":true}"#)
        let source = try XCTUnwrap(E2EEAutoHistoryImporter.source(item, text: "Bonjour, monde 🌍", conversationId: conversationId))
        let candidate = try XCTUnwrap(E2EEAutoHistoryImporter.candidate(source))
        XCTAssertEqual(candidate.body.sourceB64, vector["canonicalSourceB64"] as? String)
        XCTAssertEqual(candidate.body.sourceHash, vector["sourceHash"] as? String)
        XCTAssertEqual(candidate.clientRequestId, vector["clientRequestId"] as? String)
        XCTAssertTrue(candidate.body.attachments.isEmpty)
        // Relu comme le lirait un autre appareil : vérifié.
        XCTAssertEqual(E2EEAutoHistoryImport.verify(
            candidate.body, conversationId: conversationId, importedFromMessageId: "message_123456789012", encryptedBlobIds: []
        ), source)
    }

    /// Pas de blob côté serveur : une pièce jointe attend ; ni éphémère, ni
    /// supprimé, ni message en clair, ni source trop grande.
    func testOnlyEligibleMessagesAreImported() {
        let attachment = MessageAttachment(
            id: "attachment_0000000000001", kind: "image", url: URL(string: "https://example.test/a.jpg"), fileName: nil,
            contentType: "image/jpeg", size: 10, width: nil, height: nil
        )
        XCTAssertNil(E2EEAutoHistoryImporter.source(v1("message_123456789013", attachments: [attachment]), text: "a", conversationId: conversationId))
        XCTAssertNil(E2EEAutoHistoryImporter.source(v1("message_123456789014", expiresAt: Date()), text: "a", conversationId: conversationId))
        XCTAssertNil(E2EEAutoHistoryImporter.source(v1("message_123456789015", deleted: true), text: "a", conversationId: conversationId))
        XCTAssertNil(E2EEAutoHistoryImporter.source(v1("message_123456789016", encrypted: false), text: "a", conversationId: conversationId))
        XCTAssertNil(E2EEAutoHistoryImporter.source(
            v1("message_123456789017"), text: String(repeating: "a", count: 81 * 1_024), conversationId: conversationId
        ))
        XCTAssertNotNil(E2EEAutoHistoryImporter.source(v1("message_123456789018"), text: "a", conversationId: conversationId))
    }

    /// Révision 16 : la route v1 sert `expiresAt`. Un éphémère encore valable
    /// s'importe avec son échéance dans la source et un TTL jusqu'à elle, arrondi
    /// au supérieur ; un éphémère passé ne s'importe pas.
    func testEphemeralSourcesCarryTheirExpiry() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter.withFractions.date(from: "2026-10-27T20:00:00.000Z"))
        let expiry = now.addingTimeInterval(90.2)
        let source = try XCTUnwrap(E2EEAutoHistoryImporter.source(
            v1("message_123456789019", expiresAt: expiry), text: "a", conversationId: conversationId, now: now
        ))
        XCTAssertEqual(source.expiresAt, "2026-10-27T20:01:30.200Z")
        let candidate = try XCTUnwrap(E2EEAutoHistoryImporter.candidate(source, now: now))
        XCTAssertEqual(candidate.ttlSeconds, 91)
        XCTAssertEqual(E2EEAutoHistoryImport.verify(
            candidate.body, conversationId: conversationId, importedFromMessageId: "message_123456789019", encryptedBlobIds: []
        ), source)

        XCTAssertNil(E2EEAutoHistoryImporter.source(
            v1("message_123456789020", expiresAt: now), text: "a", conversationId: conversationId, now: now
        ))
        XCTAssertNil(E2EEAutoHistoryImporter.candidate(source, now: expiry))
        let far = try XCTUnwrap(E2EEAutoHistoryImporter.source(
            v1("message_123456789021", expiresAt: now.addingTimeInterval(40 * 86_400)), text: "a",
            conversationId: conversationId, now: now
        ))
        XCTAssertEqual(E2EEAutoHistoryImporter.candidate(far, now: now)?.ttlSeconds, 2_592_000)
        let permanent = try XCTUnwrap(E2EEAutoHistoryImporter.source(v1("message_123456789022"), text: "a", conversationId: conversationId))
        XCTAssertEqual(E2EEAutoHistoryImporter.candidate(permanent)?.ttlSeconds, 0)
    }

    /// Le lecteur masque un import à la plus proche des deux échéances.
    func testAnImportExpiresAtTheNearestDeadline() {
        let source = E2EEV2LegacyMessageSource(
            version: 1, conversationId: conversationId, messageId: "message_123456789019", senderId: alice.id,
            kind: "TEXT", content: "a", metadata: nil, createdAt: "2026-10-27T19:00:00.000Z", editedAt: nil,
            replyToId: nil, expiresAt: "2026-10-27T20:01:30.200Z"
        )
        let sourceMs: Int64 = 1_793_131_290_200
        XCTAssertEqual(E2EEAutoHistoryImporter.expiresAtMs(signedMs: sourceMs + 800, source: source), sourceMs)
        XCTAssertEqual(E2EEAutoHistoryImporter.expiresAtMs(signedMs: sourceMs - 1, source: source), sourceMs - 1)
        XCTAssertEqual(E2EEAutoHistoryImporter.expiresAtMs(signedMs: nil, source: source), sourceMs)
        XCTAssertEqual(E2EEAutoHistoryImporter.expiresAtMs(signedMs: 5, source: nil), 5)
        XCTAssertNil(E2EEAutoHistoryImporter.expiresAtMs(signedMs: nil, source: nil))
    }

    func testServerAnswersBecomeOutcomes() {
        func failure(_ status: Int, _ code: String, _ kind: E2EEV2TransportFailureKind = .permanent) -> E2EEV2MessageSendResultV2 {
            .failure(.init(kind: kind, statusCode: status, code: code, message: ""))
        }
        XCTAssertEqual(E2EEAutoHistoryImporter.outcome(.alreadyAccepted(messageRef: "ref")), .imported)
        XCTAssertEqual(E2EEAutoHistoryImporter.outcome(failure(409, "E2EE_IMPORT_EXISTS")), .exists)
        XCTAssertEqual(E2EEAutoHistoryImporter.outcome(failure(409, "E2EE_MESSAGE_CONFLICT")), .exists)
        XCTAssertEqual(E2EEAutoHistoryImporter.outcome(failure(400, "E2EE_IMPORT_SOURCE_INVALID")), .refused)
        XCTAssertEqual(E2EEAutoHistoryImporter.outcome(failure(503, "UNAVAILABLE", .retryable)), .retry)
        XCTAssertEqual(E2EEAutoHistoryImporter.outcome(.needsEpoch), .retry)
        XCTAssertEqual(E2EEAutoHistoryImporter.outcome(.capabilityMissing(["x"])), .retry)
    }

    /// Lots de 5 envois en vol au plus ; une attente arrête la tournée après son lot.
    func testImportsGoInBatchesOfFiveAndStopOnAWait() async throws {
        let candidates = try (0..<12).map { index in
            let source = try XCTUnwrap(E2EEAutoHistoryImporter.source(
                v1(String(format: "message_%012d", index)), text: "m\(index)", conversationId: conversationId
            ))
            return try XCTUnwrap(E2EEAutoHistoryImporter.candidate(source))
        }
        let probe = InFlightProbe()
        let report = await E2EEAutoHistoryImporter.run(candidates) { candidate in
            await probe.enter()
            try? await Task.sleep(nanoseconds: 5_000_000)
            await probe.leave()
            return candidate.source.messageId == "message_000000000006"
                ? .failure(.init(kind: .retryable, message: "offline")) : .alreadyAccepted(messageRef: "ref")
        }
        let peak = await probe.peak
        XCTAssertLessThanOrEqual(peak, 5)
        XCTAssertTrue(report.stopped)
        XCTAssertEqual(report.outcomes.count, 10, "le lot de l'attente finit, le troisième ne part pas")
        XCTAssertEqual(report.outcomes["message_000000000006"], .retry)
        XCTAssertNil(report.outcomes["message_000000000010"])
    }

    func testAnImportDifferingFromTheLocalReadingIsContested() {
        XCTAssertEqual(
            E2EEAutoHistoryImporter.contested(local: ["a": "1", "b": "2"], imported: ["a": "1", "b": "3", "c": "4"]),
            ["b"]
        )
    }
}

private actor InFlightProbe {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

private extension ISO8601DateFormatter {
    static var withFractions: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
