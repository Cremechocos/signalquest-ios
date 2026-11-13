import CryptoKit
import XCTest
@testable import SignalQuest

/// E2EE-AUTO §8 : l'importeur des messages v1 (sources, lots de 5, issues du
/// serveur) et l'import contesté.
final class E2EEAutoHistoryImporterTests: XCTestCase {
    private let conversationId = "conversation_1234567890"
    private let alice = MessageUser(id: "user_123456789012345", name: "Alice", email: "alice@example.test", avatarUrl: nil)

    private func v1(
        _ id: String, at iso: String = "2026-08-23T00:00:00.000Z", encrypted: Bool = true, metadata: String? = nil,
        expiresAt: Date? = nil, deleted: Bool = false, attachments: [MessageAttachment] = [], kind: String = "TEXT"
    ) -> MessageItem {
        MessageItem(
            id: id, conversationId: conversationId, senderId: alice.id, kind: kind, content: nil,
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

    /// Révision 16 : une pièce jointe s'importe (ses blobs partent avant), et un
    /// message sans texte chiffré se lit par son `content`, comme chez Android ;
    /// ni système, ni éphémère passé, ni supprimé, ni plus de 20 pièces, ni pièce
    /// à identifiant non opaque, ni source trop grande.
    func testOnlyEligibleMessagesAreImported() {
        func attachment(_ id: String) -> MessageAttachment {
            MessageAttachment(id: id, kind: "image", url: URL(string: "https://example.test/\(id).jpg"), fileName: nil,
                              contentType: "image/jpeg", size: 10, width: nil, height: nil)
        }
        XCTAssertNotNil(E2EEAutoHistoryImporter.source(
            v1("message_123456789013", attachments: [attachment("attachment_0000000000001")]), text: "a", conversationId: conversationId
        ))
        XCTAssertNotNil(E2EEAutoHistoryImporter.source(v1("message_123456789016", encrypted: false), text: "", conversationId: conversationId))
        XCTAssertNil(E2EEAutoHistoryImporter.source(v1("message_123456789019", kind: "SYSTEM"), text: "a", conversationId: conversationId))
        XCTAssertNil(E2EEAutoHistoryImporter.source(
            v1("message_123456789020", attachments: (0..<21).map { attachment(String(format: "attachment_%016d", $0)) }),
            text: "a", conversationId: conversationId
        ))
        XCTAssertNil(E2EEAutoHistoryImporter.source(
            v1("message_123456789021", attachments: [attachment("a b")]), text: "a", conversationId: conversationId
        ))
        XCTAssertNil(E2EEAutoHistoryImporter.source(v1("message_123456789014", expiresAt: Date()), text: "a", conversationId: conversationId))
        XCTAssertNil(E2EEAutoHistoryImporter.source(v1("message_123456789015", deleted: true), text: "a", conversationId: conversationId))
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
            if candidate.source.messageId == "message_000000000002" { return .waiting }
            return E2EEAutoHistoryImporter.outcome(candidate.source.messageId == "message_000000000006"
                ? .failure(.init(kind: .retryable, message: "offline")) : .alreadyAccepted(messageRef: "ref"))
        }
        let peak = await probe.peak
        XCTAssertLessThanOrEqual(peak, 5)
        XCTAssertTrue(report.stopped)
        XCTAssertEqual(report.outcomes.count, 10, "le lot de l'attente finit, le troisième ne part pas")
        XCTAssertEqual(report.outcomes["message_000000000006"], .retry)
        XCTAssertEqual(report.outcomes["message_000000000002"], .waiting, "une pièce en attente n'arrête pas la tournée")
        XCTAssertNil(report.outcomes["message_000000000010"])
    }

    /// N1-6 (13/11) : les écritures d'un import passent par le client API au plus une fois
    /// par intervalle du cadenceur, même à 5 en parallèle ; une lecture n'attend pas, et
    /// hors d'un lot cadencé rien ne ralentit.
    func testImportWritesArePacedThroughTheAPIClient() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-import-writer")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        // La première requête d'une session neuve peut tarder (plusieurs secondes au simulateur) :
        // les écritures déjà cadencées s'y empileraient et arriveraient ensemble au faux serveur.
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        try? await api.request(APIEndpoint(path: "/api/e2ee/v2/conversations/c/epochs"))
        let sent = PacedRequestLog()
        MockURLProtocol.requestHandler = { request in
            sent.record(request.httpMethod ?? "GET")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, Data("{}".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }
        let candidates = try (0..<6).map { index in
            let source = try XCTUnwrap(E2EEAutoHistoryImporter.source(
                v1(String(format: "message_%012d", index)), text: "m\(index)", conversationId: conversationId
            ))
            return try XCTUnwrap(E2EEAutoHistoryImporter.candidate(source))
        }
        // 1 200 écritures par minute : une toutes les 50 ms, pour un test court.
        _ = await E2EEAutoHistoryImporter.run(candidates, pacer: APIWritePacer(writesPerMinute: 1_200)) { _ in
            try? await api.request(APIEndpoint(path: "/api/e2ee/v2/conversations/c/messages", method: .post))
            try? await api.request(APIEndpoint(path: "/api/e2ee/v2/conversations/c/epochs"))
            return .imported
        }
        let writes = sent.times(of: "POST")
        XCTAssertEqual(writes.count, 6)
        let gaps = zip(writes.dropFirst(), writes).map { $0 - $1 }
        XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, 0.045, "deux écritures du lot ne partent jamais à moins de 50 ms")
        let reads = sent.times(of: "GET")
        XCTAssertEqual(reads.count, 6)
        XCTAssertLessThan(reads.first! - writes.first!, 0.045, "une lecture n'attend pas sa place")

        let before = sent.times(of: "POST").count
        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { try? await api.request(APIEndpoint(path: "/api/feed/posts", method: .post)) }
            }
        }
        XCTAssertEqual(sent.times(of: "POST").count, before + 6)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25, "hors d'un lot cadencé, aucune attente")
    }

    // MARK: Pièces jointes v1 (§8, révision 16)

    /// Vecteur `importEligibility` de `blob-transport-v1` : une pièce en attente
    /// retient le message ; sinon les importables partent dans l'ordre.
    func testImportEligibilityVector() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/blob-transport-v1.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["importEligibility"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 7)
        for item in cases {
            let name = item["name"] as? String ?? "?"
            let states: [E2EEAutoHistoryImporter.PieceState] = try (item["attachments"] as? [String] ?? []).map {
                switch $0 {
                case "importable": .importable
                case "lost": .lost
                case "pending": .pending
                default: throw XCTSkip("état inconnu \($0)")
                }
            }
            let expected = try XCTUnwrap(item["expected"] as? [String: Any])
            let decision = E2EEAutoHistoryImporter.decide(sourceKind: item["sourceKind"] as? String ?? "", states: states)
            if expected["decision"] as? String == "WAIT" {
                XCTAssertEqual(decision, .wait, name)
            } else {
                let indexes = (expected["importedIndexes"] as? [String] ?? []).compactMap(Int.init)
                XCTAssertEqual(decision, .importing(indexes: indexes, attachmentMissing: expected["attachmentMissing"] as? Bool ?? false), name)
            }
        }
    }

    /// Classement au mot près : 404/410 de la source et échec de déchiffrement
    /// perdent la pièce ; tout autre échec la met en attente ; 100 Mio au plus.
    func testPieceStatesFollowTheContract() {
        typealias I = E2EEAutoHistoryImporter
        XCTAssertEqual(I.state(.status(404)), .lost)
        XCTAssertEqual(I.state(.status(410)), .lost)
        XCTAssertEqual(I.state(.status(500)), .pending)
        XCTAssertEqual(I.state(.status(429)), .pending)
        XCTAssertEqual(I.state(.decryptionFailed), .lost)
        XCTAssertEqual(I.state(.otherFailure), .pending)
        XCTAssertEqual(I.state(.bytes(plaintextSize: 104_857_600)), .importable)
        XCTAssertEqual(I.state(.bytes(plaintextSize: 104_857_601)), .lost)
    }

    /// Les pièces servies, dans leur ordre ; l'entrée du site se retrouve par son
    /// `url` (une entrée à `url` vide ne désigne rien) ; `v` ≠ 1 ou `ivB64` vide :
    /// en attente ; sans entrée : en clair ; adresse non `https` : inexploitable.
    func testPiecesFollowTheServedOrderAndTheSiteEntries() {
        func attachment(_ id: String, _ url: String, name: String? = nil, type: String? = nil) -> MessageAttachment {
            MessageAttachment(id: id, kind: "FILE", url: URL(string: url), fileName: name, contentType: type, size: 1, width: nil, height: nil)
        }
        let metadata = #"""
        {"e2eeAttachments":[
          {"url":"","v":1,"ivB64":"AAAAAAAAAAAAAAAA"},
          {"url":"https://cdn.test/a.enc","v":1,"ivB64":"AAECAwQFBgcICQoL","originalFileName":"antenne.jpg","originalContentType":"image/jpeg"},
          {"url":"https://cdn.test/c.enc","v":2,"ivB64":"AAECAwQFBgcICQoL"},
          {"url":"https://cdn.test/d.enc","ivB64":""}
        ]}
        """#
        let item = v1("message_123456789030", metadata: metadata, attachments: [
            attachment("attachment_a_000000000001", "https://cdn.test/a.enc", name: "antenne.jpg.enc", type: "application/octet-stream"),
            attachment("attachment_b_000000000002", "https://cdn.test/b.png", name: "b.png", type: "image/png"),
            attachment("attachment_c_000000000003", "https://cdn.test/c.enc"),
            attachment("attachment_d_000000000004", "https://cdn.test/d.enc"),
            attachment("attachment_e_000000000005", "http://cdn.test/e.png"),
        ])
        let pieces = E2EEAutoHistoryImporter.pieces(of: item)
        XCTAssertEqual(pieces.count, 5)
        XCTAssertEqual(pieces[0], .init(url: URL(string: "https://cdn.test/a.enc"), ivB64: "AAECAwQFBgcICQoL", unknownFormat: false,
                                        fileName: "antenne.jpg", mimeType: "image/jpeg"))
        XCTAssertEqual(pieces[1], .init(url: URL(string: "https://cdn.test/b.png"), ivB64: nil, unknownFormat: false,
                                        fileName: "b.png", mimeType: "image/png"))
        XCTAssertTrue(pieces[2].unknownFormat)
        XCTAssertTrue(pieces[3].unknownFormat)
        XCTAssertNil(pieces[4].url)
        XCTAssertFalse(pieces[4].unknownFormat)
    }

    /// Une pièce seule chiffrée par le site n'a pas de texte chiffré, mais demande
    /// la clé v1 comme un texte chiffré (vu sur la pile QA le 12/11) ; une pièce
    /// en clair, non.
    func testSiteEncryptedPieceAloneRequiresTheV1Key() {
        func attachment(_ url: String) -> MessageAttachment {
            MessageAttachment(id: "attachment_a_000000000001", kind: "FILE", url: URL(string: url), fileName: "a.png.enc",
                              contentType: "application/octet-stream", size: 1, width: nil, height: nil)
        }
        let sealed = v1("message_123456789031", encrypted: false,
                        metadata: #"{"e2eeAttachments":[{"url":"https://cdn.test/a.enc","v":1,"ivB64":"AAECAwQFBgcICQoL"}]}"#,
                        attachments: [attachment("https://cdn.test/a.enc")])
        let odd = v1("message_123456789032", encrypted: false,
                     metadata: #"{"e2eeAttachments":[{"url":"https://cdn.test/a.enc","v":2,"ivB64":"AAECAwQFBgcICQoL"}]}"#,
                     attachments: [attachment("https://cdn.test/a.enc")])
        let clear = v1("message_123456789033", encrypted: false, metadata: nil, attachments: [attachment("https://cdn.test/a.png")])
        XCTAssertFalse(sealed.isEncrypted)
        XCTAssertTrue(E2EEAutoHistoryImporter.requiresV1Key(sealed))
        XCTAssertTrue(E2EEAutoHistoryImporter.requiresV1Key(odd))
        XCTAssertFalse(E2EEAutoHistoryImporter.requiresV1Key(clear))
    }

    /// Lecture à la source : déchiffrée avec la clé v1, sans AAD ; 404 perdue,
    /// 503 en attente ; IV qui n'a pas 12 octets ou étiquette fausse : perdue ;
    /// clé absente : en attente ; pièce en clair gardée telle quelle.
    func testReadDownloadsDecryptsAndClassifies() async throws {
        let key = SymmetricKey(size: .bits256)
        let iv = Data((0..<12).map { UInt8($0) })
        let plain = Data("photo d'antenne".utf8)
        let sealed = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: iv))
        LegacyPieceStub.responses = [
            "/ok.enc": (200, sealed.ciphertext + sealed.tag),
            "/gone.enc": (404, Data()),
            "/busy.enc": (503, Data()),
            "/clear.png": (200, Data("clair".utf8)),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LegacyPieceStub.self]
        let session = URLSession(configuration: configuration)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("import-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        func piece(_ path: String, iv: String? = "AAECAwQFBgcICQoL") -> E2EEAutoHistoryImporter.V1Piece {
            .init(url: URL(string: "https://cdn.test\(path)"), ivB64: iv, unknownFormat: false, fileName: nil, mimeType: nil)
        }
        let open: (Data, Data) async throws -> Data = { iv, ciphertext in
            do {
                return try AES.GCM.open(.init(nonce: .init(data: iv), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16)), using: key)
            } catch { throw E2EEError.decryptFailed }
        }
        let ok = await E2EEAutoHistoryImporter.read(piece("/ok.enc"), in: work, session: session, decrypt: open)
        XCTAssertEqual(ok.read, .bytes(plaintextSize: Int64(plain.count)))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(ok.file)), plain)
        let gone = await E2EEAutoHistoryImporter.read(piece("/gone.enc"), in: work, session: session, decrypt: open)
        XCTAssertEqual(gone.read, .status(404))
        let busy = await E2EEAutoHistoryImporter.read(piece("/busy.enc"), in: work, session: session, decrypt: open)
        XCTAssertEqual(busy.read, .status(503))
        let shortIV = await E2EEAutoHistoryImporter.read(piece("/ok.enc", iv: "AAECAwQFBgc="), in: work, session: session, decrypt: open)
        XCTAssertEqual(shortIV.read, .decryptionFailed)
        let wrongKey = await E2EEAutoHistoryImporter.read(piece("/ok.enc"), in: work, session: session) { _, _ in
            throw E2EEError.decryptFailed
        }
        XCTAssertEqual(wrongKey.read, .decryptionFailed)
        let locked = await E2EEAutoHistoryImporter.read(piece("/ok.enc"), in: work, session: session) { _, _ in throw E2EEError.locked }
        XCTAssertEqual(locked.read, .otherFailure)
        let clear = await E2EEAutoHistoryImporter.read(piece("/clear.png", iv: nil), in: work, session: session, decrypt: open)
        XCTAssertEqual(clear.read, .bytes(plaintextSize: 5))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(clear.file)), Data("clair".utf8))
    }

    /// Ordre du contrat : toutes les pièces lues d'abord ; une en attente retient
    /// le message sans rien envoyer ; les perdues sont omises ; un envoi de blob
    /// raté retient le message ; les pièces citées gardent l'ordre de la source.
    func testPrepareAttachmentsKeepsOrderOmitsLostAndWaits() async throws {
        let source = try XCTUnwrap(E2EEAutoHistoryImporter.source(
            v1("message_123456789040", kind: "ATTACHMENT"), text: "", conversationId: conversationId
        ))
        var candidate = try XCTUnwrap(E2EEAutoHistoryImporter.candidate(source))
        func piece(_ name: String) -> E2EEAutoHistoryImporter.V1Piece {
            .init(url: URL(string: "https://cdn.test/\(name)"), ivB64: nil, unknownFormat: false, fileName: name, mimeType: "image/jpeg")
        }
        candidate.pieces = [piece("a"), piece("lost"), piece("b")]
        let work = FileManager.default.temporaryDirectory
        func manifest(_ id: String) -> E2EEV2BlobEncryptionManifest {
            .init(blobId: id, algorithm: E2EEV2BlobCrypto.algorithm, mediaKeyB64: Data(repeating: 1, count: 32).base64EncodedString(),
                  noncePrefixB64: Data(repeating: 2, count: 8).base64EncodedString(), cryptoChunkSize: E2EEV2BlobCrypto.cryptoChunkBytes,
                  plaintextSize: 5, ciphertextSize: 37, plaintextSha256: String(repeating: "a", count: 64),
                  ciphertextSha256: String(repeating: "b", count: 64))
        }
        func readStub(_ piece: E2EEAutoHistoryImporter.V1Piece) -> (read: E2EEAutoHistoryImporter.PieceRead, file: URL?) {
            piece.fileName == "lost" ? (.status(410), nil) : (.bytes(plaintextSize: 5), URL(fileURLWithPath: "/dev/null/\(piece.fileName!)"))
        }
        var uploaded: [String] = []
        let body = await E2EEAutoHistoryImporter.prepareAttachments(candidate, workDirectory: work, read: readStub) { file in
            uploaded.append(file.lastPathComponent)
            return manifest("blob_\(file.lastPathComponent)_0000000000")
        }
        XCTAssertEqual(uploaded, ["a", "b"])
        XCTAssertEqual(body?.attachments.map(\.blobId), ["blob_a_0000000000", "blob_b_0000000000"])
        XCTAssertEqual(body?.attachments.map(\.fileName), ["a", "b"])
        XCTAssertEqual(body?.sourceHash, candidate.body.sourceHash)
        // Le corps se relit comme le lirait un autre appareil, blobs de l'enveloppe compris.
        let relu = try XCTUnwrap(body.flatMap { E2EEV2HistoryImportBody.parse(dictionary($0.json)) })
        XCTAssertNotNil(E2EEAutoHistoryImport.verify(relu, conversationId: conversationId, importedFromMessageId: source.messageId,
                                                     encryptedBlobIds: ["blob_a_0000000000", "blob_b_0000000000"]))

        candidate.pieces = [piece("a"), .init(url: nil, ivB64: nil, unknownFormat: false, fileName: "x", mimeType: nil)]
        uploaded = []
        let waiting = await E2EEAutoHistoryImporter.prepareAttachments(candidate, workDirectory: work, read: { piece in
            piece.url == nil ? (.otherFailure, nil) : readStub(piece)
        }) { file in uploaded.append(file.lastPathComponent); return manifest("blob_x_0000000000") }
        XCTAssertNil(waiting)
        XCTAssertEqual(uploaded, [], "une pièce en attente : aucun blob ne part")

        candidate.pieces = [piece("a")]
        let failed = await E2EEAutoHistoryImporter.prepareAttachments(candidate, workDirectory: work, read: readStub) { _ in nil }
        XCTAssertNil(failed, "envoi de blob raté : le message attend")

        candidate.pieces = [piece("lost")]
        let missing = await E2EEAutoHistoryImporter.prepareAttachments(candidate, workDirectory: work, read: readStub) { _ in nil }
        XCTAssertEqual(missing?.attachments, [], "toutes perdues : le message part sans pièce")
    }

    private func dictionary(_ json: E2EEV2JSON) -> [String: E2EEV2JSON] {
        if case .object(let object) = json { return object }
        return [:]
    }

    func testAnImportDifferingFromTheLocalReadingIsContested() {
        XCTAssertEqual(
            E2EEAutoHistoryImporter.contested(local: ["a": "1", "b": "2"], imported: ["a": "1", "b": "3", "c": "4"]),
            ["b"]
        )
    }
}

/// Source v1 simulée : un statut et des octets par chemin, sans réseau.
private final class LegacyPieceStub: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.responses[request.url?.path ?? ""] ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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

/// Heure d'arrivée de chaque requête au faux serveur, par méthode.
private final class PacedRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, TimeInterval)] = []

    func record(_ method: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append((method, Date().timeIntervalSinceReferenceDate))
    }

    func times(of method: String) -> [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.0 == method }.map(\.1).sorted()
    }
}
