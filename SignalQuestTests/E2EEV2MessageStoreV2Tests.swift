import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 5 (plan 3) : messages v2 gardés sur l'appareil (§4, §5.3, §11, §13).
final class E2EEV2MessageStoreV2Tests: XCTestCase {
    private let conversationId = "conversation_01J7ABCD23456789"
    private let owner = "user:" + String(repeating: "a", count: 64)
    private let bruno = "user_bruno_01J7ABCD23456789"
    private let carol = "user_carol_01J7ABCD23456789"
    private let nowMs: Int64 = 1_790_000_000_000
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-messages-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testKeepsTextSealedAndAdvancesTheCursor() throws {
        let store = makeStore()
        try store.apply([try message(1, from: bruno, .text("Salut"))], equivocal: [], cursor: 7, conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        let snapshot = try store.snapshot(conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        XCTAssertEqual(snapshot.cursor, 7)
        XCTAssertEqual(snapshot.messages.map(\.text), ["Salut"])
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".sealed") }
        XCTAssertEqual(files.count, 1)
        let raw = try Data(contentsOf: root.appendingPathComponent(try XCTUnwrap(files.first)))
        XCTAssertNil(raw.range(of: Data("Salut".utf8)), "Scellé sur le disque")
        try store.apply([], equivocal: [], cursor: 3, conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        let after = try store.snapshot(conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        XCTAssertEqual(after.cursor, 7, "Le curseur ne recule pas")
    }

    func testOnlyTheAuthorEditsOrDeletesInAnyArrivalOrder() throws {
        let store = makeStore()
        let original = try message(1, from: bruno, .text("Rendez-vous à 8 h"))
        let ref = original.messageRef
        // L'édition arrive avant le message ; une autre vient de Carol.
        try store.apply(
            [try message(2, from: bruno, .edit(targetRef: ref, text: "Rendez-vous à 9 h"), sentAtMs: nowMs + 10),
             try message(3, from: carol, .edit(targetRef: ref, text: "Piraté"), sentAtMs: nowMs + 20)],
            equivocal: [], cursor: 3, conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs
        )
        try store.apply([original], equivocal: [], cursor: 4, conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        var snapshot = try store.snapshot(conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        XCTAssertEqual(snapshot.messages.map(\.text), ["Rendez-vous à 9 h"], "Édition de l'auteur seulement, appliquée à l'arrivée de la cible")
        XCTAssertEqual(snapshot.messages.first?.editedAtMs, nowMs + 10)

        try store.apply([try message(4, from: carol, .delete(targetRef: ref))], equivocal: [], cursor: 5, conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        snapshot = try store.snapshot(conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        XCTAssertFalse(try XCTUnwrap(snapshot.messages.first).deleted, "Carol ne supprime pas le message de Bruno")

        try store.apply([try message(5, from: bruno, .delete(targetRef: ref))], equivocal: [], cursor: 6, conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        snapshot = try store.snapshot(conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        let deleted = try XCTUnwrap(snapshot.messages.first)
        XCTAssertTrue(deleted.deleted)
        XCTAssertNil(deleted.text)
        XCTAssertNil(deleted.payloadB64, "La charge part avec le message")
        let reportable = try store.reportable([ref], conversationId: conversationId, ownerScopeId: owner)
        XCTAssertTrue(reportable.isEmpty, "Un message supprimé ne se signale plus")
    }

    func testEquivocalAndExpiredMessagesAreNeverShown() throws {
        let store = makeStore()
        let kept = try message(1, from: bruno, .text("Gardé"))
        let twin = try message(2, from: bruno, .text("Équivoque"))
        let ephemeral = try message(3, from: bruno, .text("Éphémère"), expiresAtMs: nowMs + 60_000)
        try store.apply([kept, twin, ephemeral], equivocal: [twin.messageRef], cursor: 3, conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        let now = try store.snapshot(conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        XCTAssertEqual(now.messages.map(\.text), ["Gardé", "Éphémère"])
        XCTAssertEqual(now.equivocalRefs, [twin.messageRef])
        let later = try store.snapshot(conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs + 61_000)
        XCTAssertEqual(later.messages.map(\.text), ["Gardé"])
        try store.apply([], equivocal: [], cursor: 3, conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs + 61_000)
        let reportable = try store.reportable([ephemeral.messageRef], conversationId: conversationId, ownerScopeId: owner)
        XCTAssertTrue(reportable.isEmpty, "Un éphémère expiré quitte l'appareil")
    }

    func testReportableMessagesKeepTheirExactPayloadAndFrankingKey() throws {
        let store = makeStore()
        let received = try message(1, from: bruno, .text("À signaler"))
        try store.apply([received], equivocal: [], cursor: 1, conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        let reportable = try store.reportable([received.messageRef], conversationId: conversationId, ownerScopeId: owner)
        XCTAssertEqual(reportable, [received])
    }

    func testPurgeAndTamperingLeaveNothingReadable() throws {
        let keys = InMemoryTokenStore()
        let store = makeStore(keys: keys)
        try store.apply([try message(1, from: bruno, .text("Salut"))], equivocal: [], cursor: 1, conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        let file = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: root.path).first { $0.hasSuffix(".sealed") })
        let url = root.appendingPathComponent(file)
        var raw = try Data(contentsOf: url)
        raw[raw.count - 1] ^= 0x01
        try raw.write(to: url)
        do {
            _ = try store.snapshot(conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
            XCTFail("Un fichier altéré ne se lit pas")
        } catch {}
        try store.purge(ownerScopeId: owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try keys.keys(withPrefix: "").isEmpty, "La clé part avec le compte")
        let empty = try store.snapshot(conversationId: conversationId, ownerScopeId: owner, nowMs: nowMs)
        XCTAssertTrue(empty.messages.isEmpty)
    }

    // MARK: Aides

    private func makeStore(keys: TokenStore = InMemoryTokenStore()) -> E2EEV2MessageStoreV2 {
        E2EEV2MessageStoreV2(rootURL: root, keyStore: keys)
    }

    private func message(
        _ sequence: Int,
        from sender: String,
        _ body: E2EEV2ContentPayloadV2.Body,
        sentAtMs: Int64? = nil,
        expiresAtMs: Int64? = nil
    ) throws -> E2EEV2ReceivedMessageV2 {
        let device = sender == bruno ? "device_bruno_android_01J7ABCD" : "device_carol_android_01J7ABCD"
        let clientRequestId = "message_store_000000000\(sequence)"
        let payload = E2EEV2ContentPayloadV2(
            sentAtMs: sentAtMs ?? nowMs, counter: Int64(sequence), replyToRef: nil, mentions: [], body: body
        )
        let bytes = try payload.encoded()
        let fk = Data(repeating: UInt8(sequence), count: 32)
        return E2EEV2ReceivedMessageV2(
            envelopeId: "envelope_store_000000000\(sequence)", sequence: Int64(sequence),
            messageRef: E2EEV2MessageRef.make(conversationId: conversationId, senderDeviceId: device, clientRequestId: clientRequestId),
            senderUserId: sender, senderDeviceId: device, clientRequestId: clientRequestId, epochNumber: 1,
            frankTagB64: E2EEV2Franking.frankTag(
                fk: fk, conversationId: conversationId, senderDeviceId: device, clientRequestId: clientRequestId, payload: bytes
            ).base64EncodedString(),
            serverTagB64: Data(repeating: 9, count: 32).base64EncodedString(), serverTimeMs: nowMs + 250,
            keyId: "server_tag_key_01J7ABCD", payload: payload, payloadBytes: bytes, fk: fk, expiresAtMs: expiresAtMs
        )
    }
}
