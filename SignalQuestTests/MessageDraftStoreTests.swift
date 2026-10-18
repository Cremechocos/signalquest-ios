import Foundation
import XCTest
@testable import SignalQuest

/// Brouillons de messagerie chiffrés sur l'appareil (plan 3, vague 1).
final class MessageDraftStoreTests: XCTestCase {
    private let alice = "user:" + String(repeating: "a", count: 64)
    private let bruno = "user:" + String(repeating: "b", count: 64)

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageDraftStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func draftFiles(in root: URL) -> [URL] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "drafts.json.enc" }
    }

    func testDraftIsEncryptedAtRestSurvivesRelaunchAndIsolatesAccounts() async throws {
        let root = temporaryRoot()
        let keys = InMemoryTokenStore()
        let store = MessageDraftStore(rootURL: root, keyStore: keys)
        try await store.save("Rendez-vous à 18 h devant l’antenne", conversationId: "c1", ownerScopeId: alice)

        let file = try XCTUnwrap(draftFiles(in: root).first)
        let bytes = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertFalse(bytes.contains("Rendez-vous"))
        XCTAssertFalse(bytes.contains("c1"))

        // Nouvelle instance = relance de l'app : même fichier, même trousseau.
        let relaunched = MessageDraftStore(rootURL: root, keyStore: keys)
        let restored = await relaunched.text(conversationId: "c1", ownerScopeId: alice)
        XCTAssertEqual(restored, "Rendez-vous à 18 h devant l’antenne")
        let other = await relaunched.text(conversationId: "c1", ownerScopeId: bruno)
        XCTAssertNil(other)
    }

    private func pendingV2(_ id: String, conversation: String = "c1", createdAtMs: Int64 = 1_790_000_000_000) -> MessageDraftStore.PendingV2Send {
        .init(clientRequestId: id, conversationId: conversation, isGroup: false, participantIds: ["a", "b"],
              text: "Texte secret \(id)", replyToRef: nil, ttlSeconds: 0, createdAtMs: createdAtMs)
    }

    /// B02 : un texte chiffré v2 refusé reste gardé, scellé, par compte, et se retire à l'accusé.
    func testPendingV2SendsAreSealedIsolatedAndRemovedOnceAccepted() async throws {
        let root = temporaryRoot()
        let keys = InMemoryTokenStore()
        let store = MessageDraftStore(rootURL: root, keyStore: keys)
        try await store.stageV2Send(pendingV2("req-1"), ownerScopeId: alice)
        try await store.stageV2Send(pendingV2("req-2", conversation: "c2"), ownerScopeId: alice)
        try await store.stageV2Send(pendingV2("req-1"), ownerScopeId: alice)

        let file = try XCTUnwrap(draftFiles(in: root).first)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("Texte secret"))

        let relaunched = MessageDraftStore(rootURL: root, keyStore: keys)
        let all = await relaunched.pendingV2Sends(ownerScopeId: alice)
        XCTAssertEqual(all.map(\.clientRequestId).sorted(), ["req-1", "req-2"], "Le même identifiant ne se range qu'une fois")
        let inC2 = await relaunched.pendingV2Sends(ownerScopeId: alice, conversationId: "c2")
        XCTAssertEqual(inC2.map(\.clientRequestId), ["req-2"])
        let others = await relaunched.pendingV2Sends(ownerScopeId: bruno)
        XCTAssertTrue(others.isEmpty)

        await relaunched.removeV2Send(clientRequestId: "req-1", ownerScopeId: alice)
        await relaunched.removeV2Send(clientRequestId: "req-2", ownerScopeId: alice)
        let left = await relaunched.pendingV2Sends(ownerScopeId: alice)
        XCTAssertTrue(left.isEmpty)
        XCTAssertTrue(draftFiles(in: root).isEmpty, "Plus rien à garder : le fichier disparaît")
    }

    func testPendingV2SendsKeepTheMostRecentOnesAndDieWithTheAccountPurge() async throws {
        let store = MessageDraftStore(rootURL: temporaryRoot(), keyStore: InMemoryTokenStore())
        for index in 0..<(MessageDraftStore.maxPendingV2Sends + 3) {
            try await store.stageV2Send(pendingV2("req-\(index)", createdAtMs: 1_790_000_000_000 + Int64(index)), ownerScopeId: alice)
        }
        let kept = await store.pendingV2Sends(ownerScopeId: alice)
        XCTAssertEqual(kept.count, MessageDraftStore.maxPendingV2Sends)
        XCTAssertFalse(kept.contains { $0.clientRequestId == "req-0" })
        XCTAssertTrue(kept.contains { $0.clientRequestId == "req-\(MessageDraftStore.maxPendingV2Sends + 2)" })

        await store.purge(ownerScopeId: alice)
        let afterPurge = await store.pendingV2Sends(ownerScopeId: alice)
        XCTAssertTrue(afterPurge.isEmpty)
    }

    func testBlankTextRemovesTheDraftAndTheFile() async throws {
        let root = temporaryRoot()
        let store = MessageDraftStore(rootURL: root, keyStore: InMemoryTokenStore())
        try await store.save("Salut", conversationId: "c1", ownerScopeId: alice)
        try await store.save("  \n ", conversationId: "c1", ownerScopeId: alice)
        let text = await store.text(conversationId: "c1", ownerScopeId: alice)
        XCTAssertNil(text)
        XCTAssertTrue(draftFiles(in: root).isEmpty)
    }

    func testKeepsTheMostRecentDrafts() async throws {
        let store = MessageDraftStore(rootURL: temporaryRoot(), keyStore: InMemoryTokenStore())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(MessageDraftStore.maxDrafts + 5) {
            try await store.save("Brouillon \(index)", conversationId: "c\(index)", ownerScopeId: alice,
                                 now: start.addingTimeInterval(TimeInterval(index)))
        }
        let all = await store.all(ownerScopeId: alice)
        XCTAssertEqual(all.count, MessageDraftStore.maxDrafts)
        XCTAssertNil(all["c0"], "Le plus ancien tombe en premier")
        XCTAssertEqual(all["c\(MessageDraftStore.maxDrafts + 4)"], "Brouillon \(MessageDraftStore.maxDrafts + 4)")
    }

    func testUnreadableFileIsReplacedInsteadOfBlocking() async throws {
        let keys = InMemoryTokenStore()
        let store = MessageDraftStore(rootURL: temporaryRoot(), keyStore: keys)
        try await store.save("Ancien", conversationId: "c1", ownerScopeId: alice)
        // Clé perdue (restauration sur un autre appareil) : le fichier ne se lit plus.
        try keys.removeAll()
        let lost = await store.text(conversationId: "c1", ownerScopeId: alice)
        XCTAssertNil(lost)
        try await store.save("Nouveau", conversationId: "c2", ownerScopeId: alice)
        let all = await store.all(ownerScopeId: alice)
        XCTAssertEqual(all, ["c2": "Nouveau"])
    }

    func testPurgeRemovesTheFileAndItsKey() async throws {
        let root = temporaryRoot()
        let keys = InMemoryTokenStore()
        let store = MessageDraftStore(rootURL: root, keyStore: keys)
        try await store.save("Salut", conversationId: "c1", ownerScopeId: alice)
        try await store.save("Coucou", conversationId: "c1", ownerScopeId: bruno)
        await store.purge(ownerScopeId: alice)
        let purged = await store.all(ownerScopeId: alice)
        XCTAssertTrue(purged.isEmpty)
        XCTAssertEqual(try keys.keys(withPrefix: "key:").count, 1, "Seule la clé de l'autre compte reste")
        let kept = await store.text(conversationId: "c1", ownerScopeId: bruno)
        XCTAssertEqual(kept, "Coucou")
    }

    func testDraftsStayOutOfDeviceBackups() async throws {
        let root = temporaryRoot()
        let store = MessageDraftStore(rootURL: root, keyStore: InMemoryTokenStore())
        try await store.save("Salut", conversationId: "c1", ownerScopeId: alice)
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    @MainActor
    func testAutosaverSavesAfterAPauseAndDiscardsOnSend() async throws {
        let store = MessageDraftStore(rootURL: temporaryRoot(), keyStore: InMemoryTokenStore())
        let scope = LocalAccountScope.currentOwnerScopeId
        let autosaver = MessageDraftAutosaver(conversationId: "c1", ownerScopeId: scope, store: store)
        autosaver.textChanged("Sal")
        autosaver.textChanged("Salut")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let saved = await store.text(conversationId: "c1", ownerScopeId: scope)
        XCTAssertEqual(saved, "Salut")

        autosaver.discard()
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterSend = await store.text(conversationId: "c1", ownerScopeId: scope)
        XCTAssertNil(afterSend)
    }

    @MainActor
    func testAutosaverNeverOverwritesWhatIsBeingTyped() async throws {
        let store = MessageDraftStore(rootURL: temporaryRoot(), keyStore: InMemoryTokenStore())
        let scope = LocalAccountScope.currentOwnerScopeId
        try await store.save("Ancien", conversationId: "c1", ownerScopeId: scope)

        let typing = MessageDraftAutosaver(conversationId: "c1", ownerScopeId: scope, store: store)
        typing.textChanged("Nouveau")
        let seeded = await typing.load()
        XCTAssertNil(seeded)
        XCTAssertEqual(typing.text, "Nouveau")

        let reopened = MessageDraftAutosaver(conversationId: "c1", ownerScopeId: scope, store: store)
        let restored = await reopened.load()
        XCTAssertEqual(restored, "Ancien")
    }

    @MainActor
    func testAutosaverWritesNothingForAnotherAccount() async throws {
        let store = MessageDraftStore(rootURL: temporaryRoot(), keyStore: InMemoryTokenStore())
        let stale = "user:" + String(repeating: "c", count: 64)
        XCTAssertNotEqual(LocalAccountScope.currentOwnerScopeId, stale)
        let autosaver = MessageDraftAutosaver(conversationId: "c1", ownerScopeId: stale, store: store)
        autosaver.textChanged("Salut")
        await autosaver.flush()
        let written = await store.text(conversationId: "c1", ownerScopeId: stale)
        XCTAssertNil(written)
    }
}
