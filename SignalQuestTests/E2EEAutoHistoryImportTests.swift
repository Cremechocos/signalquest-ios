import XCTest
@testable import SignalQuest

/// E2EE-AUTO §8 : lecture d'un message v1 importé (`HISTORY_IMPORT`), vecteur
/// `history-import-v1` ; place et mentions dans le fil.
final class E2EEAutoHistoryImportTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/history-import-v1.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func str(_ dictionary: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(dictionary[key] as? String, "clé \(key)")
    }

    private func importBody(_ payload: E2EEV2ContentPayloadV2) -> E2EEV2HistoryImportBody? {
        if case .historyImport(let body) = payload.body { return body }
        return nil
    }

    func testValidImportsAreReadToTheByteAndVerified() throws {
        let v = try vector()
        let cases = try XCTUnwrap(v["valid"] as? [[String: Any]])
        XCTAssertEqual(cases.map { $0["case"] as? String }, ["text", "attachment"])
        for item in cases {
            let name = try str(item, "case")
            let bytes = Data(try str(item, "payloadUtf8").utf8)
            let payload = try E2EEV2ContentPayloadV2.parse(bytes)
            XCTAssertEqual(try payload.encoded(), bytes, "réencodé à l'octet : \(name)")
            XCTAssertEqual(payload.body.kind, "HISTORY_IMPORT")
            let body = try XCTUnwrap(importBody(payload), name)
            XCTAssertEqual(body.sourceHash, try str(item, "sourceHash"), name)
            let sourceData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(item["source"]))
            let expected = try JSONDecoder().decode(E2EEV2LegacyMessageSource.self, from: sourceData)
            let source = E2EEAutoHistoryImport.verify(
                body, conversationId: try str(item, "conversationId"),
                importedFromMessageId: try str(item, "importedFromMessageId"),
                encryptedBlobIds: body.attachments.map(\.blobId)
            )
            XCTAssertEqual(source, expected, name)
            XCTAssertEqual(
                try E2EEV2HistoryMigrationContract.clientRequestId(messageId: expected.messageId, sourceHash: body.sourceHash),
                try str(item, "clientRequestId"), name
            )
        }
    }

    func testRefusalsAreMalformedOrUnreadableAsTheVectorSays() throws {
        let v = try vector()
        let cases = try XCTUnwrap(v["negative"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 13)
        for item in cases {
            let name = try str(item, "case")
            let bytes = Data(try str(item, "payloadUtf8").utf8)
            switch try str(item, "expected") {
            case "MALFORMED":
                XCTAssertThrowsError(try E2EEV2ContentPayloadV2.parse(bytes), name)
                XCTAssertFalse(E2EEV2ContentPayloadV2.isUnsupported(bytes), "nature connue, forme refusée : \(name)")
            case "UNREADABLE_IMPORT":
                let body = try XCTUnwrap(importBody(try E2EEV2ContentPayloadV2.parse(bytes)), name)
                XCTAssertNil(E2EEAutoHistoryImport.verify(
                    body, conversationId: try str(item, "conversationId"),
                    importedFromMessageId: try str(item, "importedFromMessageId"),
                    encryptedBlobIds: body.attachments.map(\.blobId)
                ), name)
            default:
                XCTFail("issue inconnue : \(name)")
            }
        }
    }

    /// Révision 16 : les blobs de l'enveloppe sont exactement les pièces citées.
    func testEnvelopeBlobsMustMatchTheAttachments() throws {
        let item = try XCTUnwrap((try vector()["valid"] as? [[String: Any]])?.last)
        let body = try XCTUnwrap(importBody(try E2EEV2ContentPayloadV2.parse(Data(try str(item, "payloadUtf8").utf8))))
        let verify = { (blobs: [String]) in
            E2EEAutoHistoryImport.verify(
                body, conversationId: try self.str(item, "conversationId"),
                importedFromMessageId: try self.str(item, "importedFromMessageId"), encryptedBlobIds: blobs
            )
        }
        XCTAssertNotNil(try verify(["opaque_blob_fixture_0123456789"]))
        XCTAssertNil(try verify([]))
        XCTAssertNil(try verify(["opaque_blob_fixture_0123456789", "opaque_blob_fixture_9876543210"]))
        XCTAssertNil(E2EEAutoHistoryImport.verify(
            body, conversationId: try str(item, "conversationId"), importedFromMessageId: nil,
            encryptedBlobIds: ["opaque_blob_fixture_0123456789"]
        ), "sans importedFromMessageId servi : illisible")
    }

    /// Un message ordinaire servi avec `importedFromMessageId` est illisible de même.
    func testAnOrdinaryMessageServedAsAnImportIsUnreadable() throws {
        let text = E2EEV2ContentPayloadV2(sentAtMs: 1, counter: 1, replyToRef: nil, mentions: [], body: .text("Salut"))
        XCTAssertNil(E2EEAutoHistoryImport.record(
            payload: text, conversationId: "conversation_1234567890", importedFromMessageId: nil,
            encryptedBlobIds: [], importerPlatform: "ios"
        ))
        let served = try XCTUnwrap(E2EEAutoHistoryImport.record(
            payload: text, conversationId: "conversation_1234567890", importedFromMessageId: "message_123456789012",
            encryptedBlobIds: [], importerPlatform: "ios"
        ))
        XCTAssertNil(served.source)
    }

    // MARK: Fil

    private let conversationId = "conversation_1234567890"
    private let alice = MessageUser(id: "user_alice_01J7ABCD23456789", name: "Alice", email: "alice@example.test", avatarUrl: nil)
    private let bruno = MessageUser(id: "user_bruno_01J7ABCD23456789", name: "Bruno", email: "bruno@example.test", avatarUrl: nil)

    private func source(_ messageId: String, sender: String, createdAt: String, content: String, kind: String = "TEXT",
                        replyTo: String? = nil) -> E2EEV2LegacyMessageSource {
        E2EEV2LegacyMessageSource(
            version: 1, conversationId: conversationId, messageId: messageId, senderId: sender, kind: kind,
            content: content, metadata: nil, createdAt: createdAt, editedAt: nil, replyToId: replyTo, expiresAt: nil
        )
    }

    private func stored(
        _ ref: String, sequence: Int64, sender: String, text: String?, serverTimeMs: Int64,
        historyImport: E2EEAutoHistoryImport.Record? = nil
    ) -> E2EEV2MessageStoreV2.Stored {
        E2EEV2MessageStoreV2.Stored(
            messageRef: ref, envelopeId: "envelope_\(sequence)_0000000000", sequence: sequence, senderUserId: sender,
            senderDeviceId: "device_\(sender)", clientRequestId: "message_\(sequence)_0000000000", epochNumber: 1,
            serverTimeMs: serverTimeMs, serverTagB64: "", keyId: "server_tag_key_01J7ABCD",
            frankTagB64: "", kind: historyImport == nil ? "TEXT" : "HISTORY_IMPORT", targetRef: nil, replyToRef: nil,
            sentAtMs: serverTimeMs, expiresAtMs: nil, payloadB64: nil, fkB64: nil, text: text, editedAtMs: nil,
            deleted: false, historyImport: historyImport
        )
    }

    func testImportsFormABlockBeforeEveryOtherMessage() {
        let genesis: Int64 = 1_790_000_000_000
        let recent = stored("ref_recent_000000000000000000000000000001", sequence: 1, sender: alice.id, text: "Après la bascule",
                            serverTimeMs: genesis)
        // Arrivés après le message récent, dans le désordre de leurs dates d'origine.
        let later = stored("ref_import_b_0000000000000000000000000002", sequence: 2, sender: bruno.id, text: nil,
                           serverTimeMs: genesis + 5_000, historyImport: .init(
                               source: source("message_v1_bbbbbbbbbbbb", sender: alice.id, createdAt: "2026-08-23T00:05:00.000Z",
                                              content: "Réponse", replyTo: "message_v1_aaaaaaaaaaaa"),
                               missingAttachments: 0, importerPlatform: "android"))
        let earlier = stored("ref_import_a_0000000000000000000000000003", sequence: 3, sender: bruno.id, text: nil,
                             serverTimeMs: genesis + 6_000, historyImport: .init(
                                 source: source("message_v1_aaaaaaaaaaaa", sender: "user_gone_01J7ABCD234567890",
                                                createdAt: "2026-08-23T00:00:00.000Z", content: "Bonjour"),
                                 missingAttachments: 0, importerPlatform: "android"))
        let unreadable = stored("ref_import_x_0000000000000000000000000004", sequence: 4, sender: bruno.id, text: nil,
                                serverTimeMs: genesis + 7_000, historyImport: .init(
                                    source: nil, missingAttachments: 0, importerPlatform: nil))
        let attachment = stored("ref_import_c_0000000000000000000000000005", sequence: 5, sender: bruno.id, text: nil,
                                serverTimeMs: genesis + 8_000, historyImport: .init(
                                    source: source("message_v1_cccccccccccc", sender: bruno.id,
                                                   createdAt: "2026-08-23T00:10:00.000Z", content: "", kind: "ATTACHMENT"),
                                    missingAttachments: 1, importerPlatform: "ios"))
        let result = E2EEV2MessagesV2(
            snapshot: .init(cursor: 5, messages: [recent, later, earlier, unreadable, attachment], equivocalRefs: []),
            unsupported: [], missingByDevice: [:], waitingForEpoch: false
        )
        let thread = E2EEV2ThreadPresenter.present(
            result, conversationId: conversationId, members: [alice.id: alice, bruno.id: bruno], deviceOwners: [:]
        )
        XCTAssertEqual(thread.messages.map(\.id), [earlier, later, attachment, unreadable, recent].map(\.messageRef))
        XCTAssertEqual(thread.messages[0].content, "Bonjour")
        XCTAssertEqual(thread.messages[0].sender?.displayName, "ancien membre", "jamais l'identifiant brut")
        XCTAssertEqual(thread.messages[1].senderId, alice.id, "sous le nom du compte de la source")
        XCTAssertEqual(thread.messages[1].replyToId, earlier.messageRef, "la réponse v1 vise l'import de sa cible")
        XCTAssertEqual(thread.messages[2].content, "pièce jointe non importée")
        XCTAssertEqual(thread.messages[3].content, "message importé illisible")
        XCTAssertEqual(thread.messages[3].senderId, bruno.id)
        // Le fil se trie par date : tout le bloc reste avant le premier message non importé.
        let dates = thread.messages.compactMap(\.createdAt)
        XCTAssertEqual(dates.count, 5)
        XCTAssertTrue(dates.dropLast().allSatisfy { $0 < dates.last! })
        XCTAssertEqual(thread.messages[0].createdAt, ISO8601DateFormatter().date(from: "2026-08-23T00:00:00Z"))

        XCTAssertEqual(thread.imports.count, 4)
        XCTAssertEqual(thread.imports[earlier.messageRef]?.importedBy, "importé par Bruno (Android)")
        XCTAssertEqual(thread.imports[earlier.messageRef]?.startsBlock, true)
        XCTAssertEqual(thread.imports[later.messageRef]?.startsBlock, false)
        XCTAssertEqual(thread.imports[unreadable.messageRef]?.importedBy, "importé par Bruno (plateforme inconnue)")
        XCTAssertEqual(thread.imports[attachment.messageRef]?.missingAttachments, false, "déjà dit dans la bulle")
        XCTAssertNil(thread.imports[recent.messageRef])
    }

    private func legacy(_ id: String, sender: MessageUser, at iso: String, content: String?, encrypted: Bool,
                        replyTo: String? = nil) -> MessageItem {
        MessageItem(
            id: id, conversationId: conversationId, senderId: sender.id, kind: "TEXT", content: content,
            e2eeVersion: encrypted ? 1 : nil, e2eeIvB64: encrypted ? "AAAA" : nil, e2eeCiphertextB64: encrypted ? "AAAA" : nil,
            e2eeAadB64: nil, metadata: nil, createdAt: ISO8601DateFormatter().date(from: iso), editedAt: nil, deletedAt: nil,
            expiresAt: nil, replyToId: replyTo, threadReplyCount: nil, sender: sender, attachments: [], reactions: []
        )
    }

    /// Anciens messages d'une conversation passée en auto (E2EE-AUTO §8) : après
    /// le bloc, avant les messages v2 ; l'import vérifié cache sa source v1.
    /// Pièces importées (révision 16) : l'import « pièce seule » du vecteur
    /// s'affiche comme un média, téléchargé par l'enveloppe de l'import, et non
    /// plus « pièce jointe non importée ».
    func testImportedAttachmentsShowAsMedia() throws {
        let valid = try XCTUnwrap(vector()["valid"] as? [[String: Any]])
        let item = try XCTUnwrap(valid.first { $0["case"] as? String == "attachment" })
        let payload = try XCTUnwrap((item["payloadUtf8"] as? String)?.data(using: .utf8))
        let sourceObject = try XCTUnwrap(item["source"])
        let source = try JSONDecoder().decode(
            E2EEV2LegacyMessageSource.self, from: JSONSerialization.data(withJSONObject: sourceObject)
        )
        var imported = stored("ref_import_d_0000000000000000000000000006", sequence: 6, sender: bruno.id, text: nil,
                              serverTimeMs: 1_790_000_009_000, historyImport: .init(
                                  source: source, missingAttachments: 0, importerPlatform: "android"))
        imported.payloadB64 = payload.base64EncodedString()
        let result = E2EEV2MessagesV2(
            snapshot: .init(cursor: 6, messages: [imported], equivocalRefs: []),
            unsupported: [], missingByDevice: [:], waitingForEpoch: false
        )
        let thread = E2EEV2ThreadPresenter.present(
            result, conversationId: source.conversationId, members: [alice.id: alice, bruno.id: bruno], deviceOwners: [:]
        )
        let message = try XCTUnwrap(thread.messages.first)
        XCTAssertEqual(message.kind, "MEDIA")
        XCTAssertEqual(message.content, "")
        XCTAssertEqual(message.attachments.map(\.kind), ["IMAGE"])
        XCTAssertEqual(message.attachments.first?.fileName, "antenne.jpg")
        XCTAssertEqual(message.attachments.first?.url, E2EEAutoMediaRef.url(blobId: "opaque_blob_fixture_0123456789"))
        XCTAssertEqual(thread.blobEnvelopes[imported.messageRef], imported.envelopeId)
        XCTAssertEqual(thread.media["opaque_blob_fixture_0123456789"]?.file.width, 640)
    }

    func testOlderMessagesFollowTheBlockWithTheirMention() {
        let genesis: Int64 = 1_790_000_000_000
        let recent = stored("ref_recent_000000000000000000000000000001", sequence: 1, sender: alice.id, text: "Après la bascule",
                            serverTimeMs: genesis)
        let imported = stored("ref_import_a_0000000000000000000000000002", sequence: 2, sender: bruno.id, text: nil,
                              serverTimeMs: genesis + 5_000, historyImport: .init(
                                  source: source("message_v1_aaaaaaaaaaaa", sender: alice.id,
                                                 createdAt: "2026-08-23T00:00:00.000Z", content: "Bonjour"),
                                  missingAttachments: 0, importerPlatform: "ios"))
        let result = E2EEV2MessagesV2(
            snapshot: .init(cursor: 2, messages: [recent, imported], equivocalRefs: []),
            unsupported: [], missingByDevice: [:], waitingForEpoch: false
        )
        let older = [
            // Plus ancien que l'import : il reste pourtant après le bloc.
            legacy("message_v1_plain_00000001", sender: bruno, at: "2026-08-22T00:00:00Z", content: "En clair", encrypted: false),
            legacy("message_v1_aaaaaaaaaaaa", sender: alice, at: "2026-08-23T00:00:00Z", content: nil, encrypted: true),
            legacy("message_v1_dddddddddddd", sender: bruno, at: "2026-08-24T00:00:00Z", content: nil, encrypted: true,
                   replyTo: "message_v1_aaaaaaaaaaaa"),
        ]
        let thread = E2EEV2ThreadPresenter.present(
            result, conversationId: conversationId, members: [alice.id: alice, bruno.id: bruno], deviceOwners: [:],
            legacy: older
        )
        let plainId = E2EEAutoLegacyHistory.idPrefix + "message_v1_plain_00000001"
        let v1Id = E2EEAutoLegacyHistory.idPrefix + "message_v1_dddddddddddd"
        let sorted = thread.messages.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        XCTAssertEqual(sorted.map(\.id), [imported.messageRef, plainId, v1Id, recent.messageRef])
        XCTAssertEqual(sorted[1].content, "En clair")
        XCTAssertEqual(sorted[2].content, "ancien message non importé")
        XCTAssertFalse(sorted[2].isEncrypted)
        XCTAssertEqual(sorted[2].replyToId, imported.messageRef, "la réponse vise l'import de sa cible")
        XCTAssertEqual(thread.legacyCaptions, [plainId: "ancien message non chiffré"])

        // Fenêtre arrêtée dans le bloc : les anciens messages suivent les récents, l'import attend qu'on remonte.
        let window = E2EEV2ThreadPresenter.present(
            result, conversationId: conversationId, members: [alice.id: alice, bruno.id: bruno], deviceOwners: [:],
            limit: 1, legacy: older
        )
        XCTAssertEqual(Set(window.messages.map(\.id)), [plainId, v1Id, recent.messageRef])
        XCTAssertTrue(window.hasOlder)
        // Fenêtre arrêtée dans les messages v2 : les anciens messages attendent aussi.
        let second = stored("ref_recent_000000000000000000000000000003", sequence: 3, sender: bruno.id, text: "Ensuite",
                            serverTimeMs: genesis + 9_000)
        let longer = E2EEV2MessagesV2(
            snapshot: .init(cursor: 3, messages: [recent, imported, second], equivocalRefs: []),
            unsupported: [], missingByDevice: [:], waitingForEpoch: false
        )
        let recentOnly = E2EEV2ThreadPresenter.present(
            longer, conversationId: conversationId, members: [alice.id: alice, bruno.id: bruno], deviceOwners: [:],
            limit: 1, legacy: older
        )
        XCTAssertEqual(recentOnly.messages.map(\.id), [second.messageRef])
        XCTAssertTrue(recentOnly.legacyCaptions.isEmpty)
    }

    /// Une pièce seule chiffrée par le site (sans texte chiffré) n'est ni « non
    /// chiffrée » ni montrée comme fichier `.enc` brut : la mention « non
    /// importé » reste tant qu'aucun import ne la remplace (pile QA, 12/11).
    func testASiteEncryptedPieceAloneIsNotShownAsPlain() {
        let url = "https://cdn.test/photo.png.enc"
        let item = MessageItem(
            id: "message_v1_piece_0000001", conversationId: conversationId, senderId: bruno.id, kind: "ATTACHMENT", content: "",
            e2eeVersion: nil, e2eeIvB64: nil, e2eeCiphertextB64: nil, e2eeAadB64: nil,
            metadata: #"{"e2eeAttachments":[{"url":"\#(url)","v":1,"ivB64":"AAECAwQFBgcICQoL"}]}"#,
            createdAt: ISO8601DateFormatter().date(from: "2026-08-24T00:00:00Z"), editedAt: nil, deletedAt: nil,
            expiresAt: nil, replyToId: nil, threadReplyCount: nil, sender: bruno,
            attachments: [MessageAttachment(id: "attachment_a_000000000001", kind: "FILE", url: URL(string: url),
                                            fileName: "photo.png.enc", contentType: "application/octet-stream",
                                            size: 1, width: nil, height: nil)],
            reactions: []
        )
        let shown = E2EEAutoLegacyHistory.present([item], importRefs: [:], readings: [item.id: ""])
        XCTAssertTrue(shown.captions.isEmpty)
        XCTAssertEqual(shown.messages.map(\.content), ["ancien message non importé"])
        XCTAssertEqual(shown.messages.first?.attachments.count, 0)
    }

    /// La lecture v1 de cet appareil s'affiche tant qu'aucun import ne la
    /// remplace ; un import dont la source en diffère est contesté, et la
    /// lecture v1 reste affichée (E2EE-AUTO §8).
    func testTheLocalV1ReadingStaysShownAgainstAContestedImport() {
        let genesis: Int64 = 1_790_000_000_000
        let recent = stored("ref_recent_000000000000000000000000000001", sequence: 1, sender: alice.id, text: "Après la bascule",
                            serverTimeMs: genesis)
        let forged = stored("ref_import_a_0000000000000000000000000002", sequence: 2, sender: bruno.id, text: nil,
                            serverTimeMs: genesis + 5_000, historyImport: .init(
                                source: source("message_v1_aaaaaaaaaaaa", sender: alice.id,
                                               createdAt: "2026-08-23T00:00:00.000Z", content: "Texte forgé"),
                                missingAttachments: 0, importerPlatform: "web"))
        let result = E2EEV2MessagesV2(
            snapshot: .init(cursor: 2, messages: [recent, forged], equivocalRefs: []),
            unsupported: [], missingByDevice: [:], waitingForEpoch: false
        )
        let older = [
            legacy("message_v1_aaaaaaaaaaaa", sender: alice, at: "2026-08-23T00:00:00Z", content: nil, encrypted: true),
            legacy("message_v1_bbbbbbbbbbbb", sender: alice, at: "2026-08-23T00:01:00Z", content: nil, encrypted: true),
        ]
        let thread = E2EEV2ThreadPresenter.present(
            result, conversationId: conversationId, members: [alice.id: alice, bruno.id: bruno], deviceOwners: [:],
            legacy: older, legacyReadings: ["message_v1_aaaaaaaaaaaa": "Bonjour", "message_v1_bbbbbbbbbbbb": "Ça va ?"]
        )
        let contents = Dictionary(uniqueKeysWithValues: thread.messages.map { ($0.id, $0.content) })
        XCTAssertEqual(contents[E2EEAutoLegacyHistory.idPrefix + "message_v1_aaaaaaaaaaaa"], "Bonjour")
        XCTAssertEqual(contents[E2EEAutoLegacyHistory.idPrefix + "message_v1_bbbbbbbbbbbb"], "Ça va ?")
        XCTAssertEqual(contents[forged.messageRef], "Texte forgé")
        XCTAssertEqual(thread.imports[forged.messageRef]?.contested, true)
        XCTAssertEqual(thread.importedV1Ids, ["message_v1_aaaaaaaaaaaa"])

        // Même source qu'ici : l'import remplace la lecture v1.
        let agreed = E2EEV2ThreadPresenter.present(
            result, conversationId: conversationId, members: [alice.id: alice, bruno.id: bruno], deviceOwners: [:],
            legacy: older, legacyReadings: ["message_v1_aaaaaaaaaaaa": "Texte forgé"]
        )
        XCTAssertFalse(agreed.messages.contains { $0.id == E2EEAutoLegacyHistory.idPrefix + "message_v1_aaaaaaaaaaaa" })
        XCTAssertEqual(agreed.imports[forged.messageRef]?.contested, false)
    }

    /// Un import n'est jamais le dernier message de la liste (E2EE-AUTO §8).
    func testTheStoreKeepsImportsWithoutText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = E2EEV2MessageStoreV2(rootURL: root, keyStore: InMemoryTokenStore())
        let item = try XCTUnwrap((try vector()["valid"] as? [[String: Any]])?.first)
        let bytes = Data(try str(item, "payloadUtf8").utf8)
        let payload = try E2EEV2ContentPayloadV2.parse(bytes)
        let record = E2EEAutoHistoryImport.record(
            payload: payload, conversationId: conversationId, importedFromMessageId: try str(item, "importedFromMessageId"),
            encryptedBlobIds: [], importerPlatform: "web"
        )
        XCTAssertNotNil(record?.source)
        let received = E2EEV2ReceivedMessageV2(
            envelopeId: "envelope_import_0000000001", sequence: 1, messageRef: "ref_import_00000000000000000000000000001",
            senderUserId: bruno.id, senderDeviceId: "device_bruno_0000000001", clientRequestId: try str(item, "clientRequestId"),
            epochNumber: 1, frankTagB64: "", serverTagB64: "", serverTimeMs: 1_790_000_000_000, keyId: "server_tag_key_01J7ABCD",
            payload: payload, payloadBytes: bytes, fk: Data(repeating: 1, count: 32), expiresAtMs: nil, historyImport: record
        )
        try store.apply([received], equivocal: [], cursor: 1, conversationId: conversationId, ownerScopeId: "user:me", nowMs: 1)
        let snapshot = try store.snapshot(conversationId: conversationId, ownerScopeId: "user:me", nowMs: 1)
        XCTAssertEqual(snapshot.messages.map(\.kind), ["HISTORY_IMPORT"])
        XCTAssertNil(snapshot.messages.first?.text)
        XCTAssertEqual(snapshot.messages.first?.historyImport, record)
    }
}
