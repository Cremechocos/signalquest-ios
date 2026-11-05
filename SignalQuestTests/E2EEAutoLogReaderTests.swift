import CryptoKit
import XCTest
@testable import SignalQuest

/// Lecteur du journal auto (E2EE-AUTO §3.4, §3.5) contre un faux serveur qui
/// sert la chaîne de référence de `log-chain-v2` (16 maillons, une rotation de
/// la clé du journal au maillon 13, tête signée) et la tête vide de `log-head-v2`.
final class E2EEAutoLogReaderTests: XCTestCase {
    private static let owner = "user:user_alice_00000000001"

    private struct Reference {
        let pinnedLogKeyB64: String
        let nextLogKeysB64: [String]
        let links: [String]
        let logKeyEntries: [Int64: String]
        let headText: String
        let headSignatureB64: String
        let headNowMs: Int64
        let accounts: [String: (salt: String, entries: [String])]
        let emptyHeadText: String
        let emptyHeadSignatureB64: String
        let emptyHeadNowMs: Int64
    }

    private func load(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/\(name).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func reference() throws -> Reference {
        let chain = try load("log-chain-v2"), heads = try load("log-head-v2")
        let reference = try XCTUnwrap(chain["reference"] as? [String: Any])
        let head = try XCTUnwrap(reference["head"] as? [String: String])
        let emptyHead = try XCTUnwrap(heads["emptyHead"] as? [String: Any])
        var accounts: [String: (salt: String, entries: [String])] = [:]
        for account in try XCTUnwrap(reference["accounts"] as? [[String: Any]]) {
            accounts[try XCTUnwrap(account["userId"] as? String)] = (
                try XCTUnwrap(account["accountSaltB64"] as? String), try XCTUnwrap(account["entries"] as? [String])
            )
        }
        return Reference(
            pinnedLogKeyB64: try XCTUnwrap(chain["pinnedLogKeyB64"] as? String),
            nextLogKeysB64: try XCTUnwrap(chain["pinnedNextLogKeysB64"] as? [String]),
            links: try XCTUnwrap(reference["links"] as? [String]),
            logKeyEntries: try XCTUnwrap(reference["logKeyEntries"] as? [String: String])
                .reduce(into: [:]) { $0[Int64($1.key)!] = $1.value },
            headText: try XCTUnwrap(head["text"]), headSignatureB64: try XCTUnwrap(head["signatureB64"]),
            headNowMs: try XCTUnwrap((reference["headNowMs"] as? NSNumber)?.int64Value),
            accounts: accounts,
            emptyHeadText: try XCTUnwrap(emptyHead["text"] as? String),
            emptyHeadSignatureB64: try XCTUnwrap(emptyHead["signatureB64"] as? String),
            emptyHeadNowMs: try XCTUnwrap((emptyHead["nowMs"] as? NSNumber)?.int64Value)
        )
    }

    /// Faux serveur : sert `links` (pages de `pageSize`) et la tête donnée, et note les `after` demandés.
    private final class Server: @unchecked Sendable {
        var links: [String]
        var logKeyEntries: [Int64: String]
        var headText: String
        var headSignatureB64: String
        var pageSize = 1_000
        var accounts: [String: (salt: String?, entries: [String])] = [:]
        var serverDate: Date?
        /// Tête servie à chaque appel de log/links, dans l'ordre ; à défaut, `headText`.
        var headsByCall: [(text: String, signatureB64: String)] = []
        /// Un serveur qui ignore `upTo` et rend toutes les entrées après `after`.
        var ignoresUpTo = false
        /// Une fois, pour ce `after` : premier maillon dont le `prevLinkHash` ne suit pas.
        var tamperedAfter: Int64?
        var accountPageSize = 1_000
        /// Sel servi à partir de la deuxième page d'un compte.
        var saltAfterFirstPage: String?
        var reversesEntries = false
        private(set) var linkAfters: [Int64] = []
        private(set) var accountAfters: [Int64] = []

        init(_ reference: Reference) {
            links = reference.links
            logKeyEntries = reference.logKeyEntries
            headText = reference.headText
            headSignatureB64 = reference.headSignatureB64
            accounts = reference.accounts.mapValues { ($0.salt, $0.entries) }
        }

        func linksPage(after: Int64) -> Data {
            let head = linkAfters.count < headsByCall.count ? headsByCall[linkAfters.count] : (text: headText, signatureB64: headSignatureB64)
            linkAfters.append(after)
            var page = Array(links.dropFirst(Int(after)).prefix(pageSize))
            if after == tamperedAfter, var lines = page.first?.components(separatedBy: "\n") {
                tamperedAfter = nil
                lines[3] = E2EEAutoLog.digest("autre histoire")
                page[0] = lines.joined(separator: "\n")
            }
            let last = Int(after) + page.count
            var entries: [String: String] = [:]
            for seq in (Int(after) + 1)..<(last + 1) where logKeyEntries[Int64(seq)] != nil {
                entries[String(seq)] = logKeyEntries[Int64(seq)]
            }
            let object: [String: Any] = [
                "links": page, "logKeyEntries": entries,
                "head": ["text": head.text, "signatureB64": head.signatureB64], "hasMore": last < links.count,
            ]
            return try! JSONSerialization.data(withJSONObject: object)
        }

        func accountPage(userId: String, after: Int64, upTo: Int64) -> Data? {
            accountAfters.append(after)
            guard let account = accounts[userId] else { return nil }
            let remaining = account.entries.filter {
                let seq = E2EEAutoLog.parseEntry($0)?.entry.seq ?? 0
                return seq > after && (ignoresUpTo || seq <= upTo)
            }
            let entries = Array(remaining.prefix(accountPageSize))
            let salt = after > 0 ? saltAfterFirstPage ?? account.salt : account.salt
            let object: [String: Any] = [
                "userId": userId, "accountSaltB64": salt.map { $0 as Any } ?? NSNull(),
                "entries": reversesEntries ? entries.reversed() : entries, "hasMore": remaining.count > entries.count,
            ]
            return try! JSONSerialization.data(withJSONObject: object)
        }
    }

    private func makeStore() -> E2EEAutoLogStore {
        E2EEAutoLogStore(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("e2ee-auto-log-\(UUID().uuidString)"),
            keyStore: InMemoryTokenStore(), anchorStore: InMemoryTokenStore()
        )
    }

    private func makeReader(_ reference: Reference, server: Server, store: E2EEAutoLogStore, nowMs: Int64) -> E2EEAutoLogReader {
        E2EEAutoLogReader(
            ownerScopeId: Self.owner, pinnedLogKeyB64: reference.pinnedLogKeyB64, nextLogKeysB64: reference.nextLogKeysB64,
            store: store,
            fetchLinks: { after in (server.linksPage(after: after), server.serverDate) },
            fetchAccount: { userId, after, upTo in server.accountPage(userId: userId, after: after, upTo: upTo) },
            now: { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1_000) }
        )
    }

    private func status(_ reader: E2EEAutoLogReader) async -> Result<E2EEAutoLogReader.Status, Error> {
        do { return .success(try await reader.refreshLinks()) } catch { return .failure(error) }
    }

    // MARK: Maillons et tête

    func testReadsReferenceChainAndAccounts() async throws {
        let reference = try reference(), server = Server(reference), store = makeStore()
        server.pageSize = 5
        let reader = makeReader(reference, server: server, store: store, nowMs: reference.headNowMs)
        let head = try XCTUnwrap(E2EEAutoLog.parseHead(reference.headText))
        let status = try await reader.refreshLinks()
        XCTAssertEqual(status, .current(head))
        XCTAssertEqual(server.linkAfters, [0, 5, 10, 15], "pages de 5 jusqu'à la tête")
        let anchor = try XCTUnwrap(try store.anchor(ownerScopeId: Self.owner))
        XCTAssertEqual(anchor.seq, 16)
        XCTAssertEqual(anchor.linkHash, head.linkHash)
        XCTAssertNil(anchor.alert)

        // Les états de compte sont ceux de la vérification directe.
        let chain = try E2EEAutoLog.extendChain(
            .initial(pinnedLogKeyB64: reference.pinnedLogKeyB64, nextLogKeysB64: reference.nextLogKeysB64),
            links: reference.links, logKeyEntries: reference.logKeyEntries
        ).get()
        let bySeq = Dictionary(uniqueKeysWithValues: reference.links.enumerated().map { (Int64($0.offset + 1), $0.element) })
        for (userId, account) in reference.accounts {
            let expected = E2EEAutoLog.verifyAccount(
                userId: userId, accountSaltB64: account.salt, entries: account.entries, links: bySeq, chain: chain
            )
            let read = try await reader.account(userId)
            XCTAssertEqual(read, expected, userId)
        }
    }

    func testSecondReadStartsFromKeptHead() async throws {
        let reference = try reference(), server = Server(reference), store = makeStore()
        _ = try await makeReader(reference, server: server, store: store, nowMs: reference.headNowMs).refreshLinks()
        let alice = "user_alice_00000000001"
        _ = try await makeReader(reference, server: server, store: store, nowMs: reference.headNowMs).refreshLinks()
        XCTAssertEqual(server.linkAfters, [0, 16], "un nouveau lecteur repart du fichier validé par le trousseau")

        let reader = makeReader(reference, server: server, store: store, nowMs: reference.headNowMs)
        _ = try await reader.refreshLinks()
        _ = try await reader.account(alice)
        _ = try await reader.account(alice)
        let lastAliceSeq = try XCTUnwrap(reference.accounts[alice]?.entries.last.flatMap { E2EEAutoLog.parseEntry($0)?.entry.seq })
        XCTAssertEqual(server.accountAfters, [0, lastAliceSeq], "les entrées gardées ne sont pas relues")
    }

    func testEmptyJournal() async throws {
        let reference = try reference(), server = Server(reference)
        server.links = []
        server.logKeyEntries = [:]
        server.headText = reference.emptyHeadText
        server.headSignatureB64 = reference.emptyHeadSignatureB64
        let reader = makeReader(reference, server: server, store: makeStore(), nowMs: reference.emptyHeadNowMs)
        let status = try await reader.refreshLinks()
        XCTAssertEqual(status, .current(try XCTUnwrap(E2EEAutoLog.parseHead(reference.emptyHeadText))))
    }

    func testOldHeadIsNotCurrentWithoutAlert() async throws {
        let reference = try reference(), store = makeStore()
        let limit = reference.headNowMs - 60_000 + E2EEAutoLog.headMaxAgeMs + E2EEAutoLog.clockToleranceMs
        let atLimit = try await makeReader(reference, server: Server(reference), store: store, nowMs: limit).refreshLinks()
        guard case .current = atLimit else { return XCTFail("24 h 10 min pile : à jour, \(atLimit)") }
        let beyond = try await makeReader(reference, server: Server(reference), store: store, nowMs: limit + 1).refreshLinks()
        guard case .notCurrent = beyond else { return XCTFail("une milliseconde au-delà : pas à jour, \(beyond)") }
        XCTAssertNil(try store.anchor(ownerScopeId: Self.owner)?.alert)
    }

    func testInvalidHeadAdoptsNothing() async throws {
        let reference = try reference(), server = Server(reference), store = makeStore()
        server.headSignatureB64 = reference.emptyHeadSignatureB64
        let reader = makeReader(reference, server: server, store: store, nowMs: reference.headNowMs)
        let result = await status(reader)
        guard case .failure(let error) = result, case .invalidHead(.signature) = error as? E2EEAutoLogReader.Failure else {
            return XCTFail("signature fausse : \(result)")
        }
        XCTAssertNil(try store.anchor(ownerScopeId: Self.owner))
    }

    func testMissingLogKeyEntryIsRefused() async throws {
        let reference = try reference(), server = Server(reference)
        server.logKeyEntries = [:]
        let result = await status(makeReader(reference, server: server, store: makeStore(), nowMs: reference.headNowMs))
        guard case .failure(let error) = result,
              case .invalidChain(let failure) = error as? E2EEAutoLogReader.Failure else { return XCTFail("\(result)") }
        XCTAssertEqual(failure, .init(error: .logKeyEntryMissing, seq: 13))
    }

    /// Le fichier perdu est relu depuis 1, mais la tête du trousseau fait foi.
    func testKeptHeadDetectsForkAndRollbackAndKeepsTheAlert() async throws {
        let reference = try reference()
        let head = try XCTUnwrap(E2EEAutoLog.parseHead(reference.headText))

        let forkStore = makeStore()
        try forkStore.saveAnchor(.init(seq: 9, linkHash: head.linkHash, headCreatedAtMs: 0), ownerScopeId: Self.owner)
        let forkServer = Server(reference)
        let fork = try await makeReader(reference, server: forkServer, store: forkStore, nowMs: reference.headNowMs).refreshLinks()
        XCTAssertEqual(fork, .alert(.init(error: "FORK", seq: 9)))
        let again = try await makeReader(reference, server: forkServer, store: forkStore, nowMs: reference.headNowMs).refreshLinks()
        XCTAssertEqual(again, fork, "l'alerte ne se lève pas seule")
        XCTAssertEqual(forkServer.linkAfters, [0], "plus rien n'est relu après l'alerte")

        let rollbackStore = makeStore()
        try rollbackStore.saveAnchor(.init(seq: 20, linkHash: head.linkHash, headCreatedAtMs: 0), ownerScopeId: Self.owner)
        let rollback = try await makeReader(reference, server: Server(reference), store: rollbackStore, nowMs: reference.headNowMs)
            .refreshLinks()
        XCTAssertEqual(rollback, .alert(.init(error: "ROLLBACK", seq: 16)))
    }

    /// Seule une réinitialisation volontaire (lot 6d) oublie l'alerte : la relecture repart de 1.
    func testVoluntaryResetForgetsTheAlertAndRereadsFromTheStart() async throws {
        let reference = try reference()
        let head = try XCTUnwrap(E2EEAutoLog.parseHead(reference.headText))
        let store = makeStore(), server = Server(reference)
        let defaults = UserDefaults(suiteName: "e2ee-auto-log-alert-\(UUID().uuidString)")!
        let alerts = E2EEAutoLogAlerts(store: store, defaults: defaults)
        try store.saveAnchor(.init(seq: 9, linkHash: head.linkHash, headCreatedAtMs: 0), ownerScopeId: Self.owner)

        let raised = expectation(forNotification: E2EEAutoLogAlerts.didChange, object: nil)
        let fork = try await makeReader(reference, server: server, store: store, nowMs: reference.headNowMs).refreshLinks()
        await fulfillment(of: [raised], timeout: 1)
        let alert = E2EEAutoLogStore.Alert(error: "FORK", seq: 9)
        XCTAssertEqual(fork, .alert(alert))
        XCTAssertEqual(alerts.current(ownerScopeId: Self.owner), alert)

        alerts.setReported("bug_1", for: alert, ownerScopeId: Self.owner)
        XCTAssertEqual(alerts.reportId(for: alert, ownerScopeId: Self.owner), "bug_1")
        XCTAssertNil(alerts.reportId(for: .init(error: "FORK", seq: 10), ownerScopeId: Self.owner), "un signalement par alerte")

        let cleared = expectation(forNotification: E2EEAutoLogAlerts.didChange, object: nil)
        try alerts.reset(ownerScopeId: Self.owner)
        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertNil(alerts.current(ownerScopeId: Self.owner))
        XCTAssertNil(alerts.reportId(for: alert, ownerScopeId: Self.owner))
        let reread = try await makeReader(reference, server: server, store: store, nowMs: reference.headNowMs).refreshLinks()
        XCTAssertEqual(reread, .current(head))
        XCTAssertEqual(server.linkAfters.last, 0, "relu depuis le premier maillon")
    }

    func testRecedingHeadBetweenPagesInvalidatesTheRead() async throws {
        let reference = try reference(), server = Server(reference), store = makeStore()
        let boundary = try boundaryHead(seq: 12)
        server.pageSize = 5
        server.headsByCall = [(reference.headText, reference.headSignatureB64), boundary]
        let result = await status(makeReader(reference, server: server, store: store, nowMs: reference.headNowMs))
        guard case .failure(let error) = result, case .malformed = error as? E2EEAutoLogReader.Failure else {
            return XCTFail("tête 16 puis 12 : \(result)")
        }
        XCTAssertNil(try store.anchor(ownerScopeId: Self.owner))
    }

    /// Les entrées au-delà de la tête vérifiée sont écartées avant le vérificateur, même si le serveur ignore `upTo`.
    func testEntriesBeyondVerifiedHeadAreSetAside() async throws {
        let reference = try reference(), server = Server(reference)
        let boundary = try boundaryHead(seq: 12)
        server.links = Array(reference.links.prefix(12))
        (server.headText, server.headSignatureB64) = boundary
        server.ignoresUpTo = true
        let nowMs = try XCTUnwrap(E2EEAutoLog.parseHead(boundary.text)).createdAtMs
        let reader = makeReader(reference, server: server, store: makeStore(), nowMs: nowMs)
        let status = try await reader.refreshLinks()
        guard case .current(let head) = status else { return XCTFail("tête 12 : \(status)") }
        XCTAssertEqual(head.seq, 12)

        let chain = try E2EEAutoLog.extendChain(
            .initial(pinnedLogKeyB64: reference.pinnedLogKeyB64, nextLogKeysB64: reference.nextLogKeysB64),
            links: server.links, logKeyEntries: [:]
        ).get()
        let bySeq = Dictionary(uniqueKeysWithValues: server.links.enumerated().map { (Int64($0.offset + 1), $0.element) })
        for (userId, account) in reference.accounts {
            XCTAssertTrue(account.entries.contains { (E2EEAutoLog.parseEntry($0)?.entry.seq ?? 0) > 12 }, userId)
            let kept = account.entries.filter { (E2EEAutoLog.parseEntry($0)?.entry.seq ?? 0) <= 12 }
            let expected = E2EEAutoLog.verifyAccount(userId: userId, accountSaltB64: account.salt, entries: kept, links: bySeq, chain: chain)
            XCTAssertNotNil(try? expected.get(), userId)
            let read = try await reader.account(userId)
            XCTAssertEqual(read, expected, userId)
        }
    }

    /// Lecteur qui garde la tête 12 (avant la LOG_KEY du maillon 13), sur le même magasin.
    private func keepHead12(_ reference: Reference, store: E2EEAutoLogStore) async throws {
        let server = Server(reference), boundary = try boundaryHead(seq: 12)
        server.links = Array(reference.links.prefix(12))
        (server.headText, server.headSignatureB64) = boundary
        let nowMs = try XCTUnwrap(E2EEAutoLog.parseHead(boundary.text)).createdAtMs
        let status = try await makeReader(reference, server: server, store: store, nowMs: nowMs).refreshLinks()
        guard case .current = status else { return XCTFail("tête 12 : \(status)") }
    }

    /// Fourche seulement si une tête vérifiée la prouve (révision 6) : relecture depuis 1 d'abord.
    func testFirstLinkNotExtendingKeptHeadIsRereadBeforeAnyAlert() async throws {
        let reference = try reference(), store = makeStore()
        try await keepHead12(reference, store: store)
        let server = Server(reference)
        server.tamperedAfter = 12
        let status = try await makeReader(reference, server: server, store: store, nowMs: reference.headNowMs).refreshLinks()
        XCTAssertEqual(status, .current(try XCTUnwrap(E2EEAutoLog.parseHead(reference.headText))))
        XCTAssertEqual(server.linkAfters, [12, 0])
        XCTAssertNil(try store.anchor(ownerScopeId: Self.owner)?.alert)
    }

    func testIncoherentPagesAreInconclusive() async throws {
        let reference = try reference(), boundary = try boundaryHead(seq: 12)
        func expectInconclusive(_ server: Server, store: E2EEAutoLogStore, keptSeq: Int64?, _ message: String) async throws {
            let result = await status(makeReader(reference, server: server, store: store, nowMs: reference.headNowMs))
            guard case .failure(let error) = result, case .malformed = error as? E2EEAutoLogReader.Failure else {
                return XCTFail("\(message) : \(result)")
            }
            let anchor = try store.anchor(ownerScopeId: Self.owner)
            XCTAssertEqual(anchor?.seq, keptSeq, message)
            XCTAssertNil(anchor?.alert, message)
        }

        // Révision 13 : une entrée `LOG_KEY` en trop sous une tête vérifiée qui termine des
        // maillons intacts n'est plus non concluante, c'est l'alerte « chaîne invalide ».
        let extraEntry = Server(reference)
        extraEntry.logKeyEntries[5] = reference.logKeyEntries[13]
        let extra = try await makeReader(reference, server: extraEntry, store: makeStore(), nowMs: reference.headNowMs).refreshLinks()
        XCTAssertEqual(extra, .alert(.init(error: "CHAIN_INVALID", seq: 5)), "entrée LOG_KEY en trop")

        let shortHead = Server(reference)
        (shortHead.headText, shortHead.headSignatureB64) = boundary
        try await expectInconclusive(shortHead, store: makeStore(), keptSeq: nil, "dernier maillon 16, tête 12")

        let store = makeStore()
        try await keepHead12(reference, store: store)
        let emptyAhead = Server(reference)
        emptyAhead.links = Array(reference.links.prefix(12))
        try await expectInconclusive(emptyAhead, store: store, keptSeq: 12, "page vide, tête 16 après 12")
    }

    /// Page vide sous une tête plus ancienne : vérifiée avec la clé de son `seq`, c'est un retour en arrière.
    func testEmptyPageWithOlderVerifiedHeadIsRollback() async throws {
        let reference = try reference(), store = makeStore()
        _ = try await makeReader(reference, server: Server(reference), store: store, nowMs: reference.headNowMs).refreshLinks()
        let server = Server(reference), boundary = try boundaryHead(seq: 12)
        server.links = Array(reference.links.prefix(12))
        (server.headText, server.headSignatureB64) = boundary
        let status = try await makeReader(reference, server: server, store: store, nowMs: reference.headNowMs).refreshLinks()
        XCTAssertEqual(status, .alert(.init(error: "ROLLBACK", seq: 12)))
    }

    /// Têtes plus courtes que la gardée (révision 7) : signée par la clé en vigueur à son `seq`,
    /// retour en arrière quel que soit son âge ; sinon non concluant.
    func testEarlierHeadVectors() async throws {
        let reference = try reference()
        let cases = try XCTUnwrap(try load("log-head-v2")["earlierHeads"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for testCase in cases {
            let name = try XCTUnwrap(testCase["name"] as? String)
            XCTAssertEqual((testCase["after"] as? NSNumber)?.int64Value, 16, name)
            let head = try XCTUnwrap(testCase["head"] as? [String: String], name)
            let store = makeStore()
            _ = try await makeReader(reference, server: Server(reference), store: store, nowMs: reference.headNowMs).refreshLinks()
            let server = Server(reference)
            (server.headText, server.headSignatureB64) = (try XCTUnwrap(head["text"]), try XCTUnwrap(head["signatureB64"]))
            let result = await status(makeReader(reference, server: server, store: store, nowMs: reference.headNowMs))
            switch (try XCTUnwrap(testCase["expect"] as? String), result) {
            case ("ROLLBACK", .success(.alert(let alert))): XCTAssertEqual(alert.error, "ROLLBACK", name)
            case ("INCONCLUSIVE", .failure): XCTAssertNil(try store.anchor(ownerScopeId: Self.owner)?.alert, name)
            default: XCTFail("\(name) : \(result)")
            }
        }
    }

    /// Page vide, même tête : la plus fraîche des deux est gardée et borne les 24 h (révision 7).
    func testFresherHeadIsKept() async throws {
        let reference = try reference(), vectors = try XCTUnwrap(try load("log-head-v2")["fresherHead"] as? [String: Any])
        let kept = try XCTUnwrap(vectors["kept"] as? [String: String]), received = try XCTUnwrap(vectors["received"] as? [String: String])
        let nowMs = try XCTUnwrap((vectors["nowMs"] as? NSNumber)?.int64Value)
        let store = makeStore()
        func read(_ head: [String: String]) async throws -> E2EEAutoLogReader.Status {
            let server = Server(reference)
            (server.headText, server.headSignatureB64) = (try XCTUnwrap(head["text"]), try XCTUnwrap(head["signatureB64"]))
            return try await makeReader(reference, server: server, store: store, nowMs: nowMs).refreshLinks()
        }
        let receivedHead = try XCTUnwrap(E2EEAutoLog.parseHead(try XCTUnwrap(received["text"])))
        guard case .notCurrent = try await read(kept) else { return XCTFail("tête gardée : \(String(describing: vectors["keptExpect"]))") }
        let fresher = try await read(received)
        XCTAssertEqual(fresher, .current(receivedHead))
        let older = try await read(kept)
        XCTAssertEqual(older, .current(receivedHead), "la tête plus ancienne ne remplace pas la plus fraîche")
        XCTAssertEqual(try store.anchor(ownerScopeId: Self.owner)?.headCreatedAtMs, receivedHead.createdAtMs)
    }

    /// Même tête reçue plus ancienne que la tête gardée (révision 9) : la gardée reste et borne les 24 h.
    func testOlderReceivedHeadDoesNotReplaceTheKeptOne() async throws {
        let reference = try reference(), vectors = try XCTUnwrap(try load("log-head-v2")["olderReceivedHead"] as? [String: Any])
        let kept = try XCTUnwrap(vectors["kept"] as? [String: String]), received = try XCTUnwrap(vectors["received"] as? [String: String])
        let nowMs = try XCTUnwrap((vectors["nowMs"] as? NSNumber)?.int64Value)
        XCTAssertEqual(vectors["keptExpect"] as? String, "ok")
        XCTAssertEqual(vectors["receivedExpect"] as? String, "stale")
        XCTAssertEqual(vectors["fresher"] as? String, "kept")
        let store = makeStore()
        func read(_ head: [String: String]) async throws -> E2EEAutoLogReader.Status {
            let server = Server(reference)
            (server.headText, server.headSignatureB64) = (try XCTUnwrap(head["text"]), try XCTUnwrap(head["signatureB64"]))
            return try await makeReader(reference, server: server, store: store, nowMs: nowMs).refreshLinks()
        }
        let keptHead = try XCTUnwrap(E2EEAutoLog.parseHead(try XCTUnwrap(kept["text"])))
        guard case .notCurrent = try await read(received) else { return XCTFail("tête reçue seule : stale") }
        let first = try await read(kept)
        XCTAssertEqual(first, .current(keptHead))
        let older = try await read(received)
        XCTAssertEqual(older, .current(keptHead), "la tête reçue plus ancienne ne remplace pas la gardée")
        XCTAssertEqual(try store.anchor(ownerScopeId: Self.owner)?.headCreatedAtMs, keptHead.createdAtMs)
        XCTAssertNil(try store.anchor(ownerScopeId: Self.owner)?.alert)
    }

    /// Tête au seq 12 de `log-head-v2`, signée par la clé épinglée (avant la LOG_KEY du maillon 13).
    private func boundaryHead(seq: Int64) throws -> (text: String, signatureB64: String) {
        let boundaries = try XCTUnwrap(try load("log-head-v2")["boundaryHeads"] as? [[String: Any]])
        let match = try XCTUnwrap(boundaries.first {
            ($0["expect"] as? String) == "ok" && ($0["keptSeq"] as? NSNumber)?.int64Value == seq
        })
        let head = try XCTUnwrap(match["head"] as? [String: String])
        return (try XCTUnwrap(head["text"]), try XCTUnwrap(head["signatureB64"]))
    }

    func testClockOffsetFromDateHeader() async throws {
        let reference = try reference(), server = Server(reference)
        server.serverDate = Date(timeIntervalSince1970: TimeInterval(reference.headNowMs + 90_000) / 1_000)
        let reader = makeReader(reference, server: server, store: makeStore(), nowMs: reference.headNowMs)
        let status = try await reader.refreshLinks()
        guard case .current = status else { return XCTFail("l'âge de la tête se juge à l'horloge locale : \(status)") }
        let offset = await reader.clockOffsetMs
        XCTAssertEqual(offset, 90_000)
        let corrected = await reader.correctedNowMs()
        XCTAssertEqual(corrected, reference.headNowMs + 90_000)
        XCTAssertNotNil(E2EEV2APITransport.httpDate("Sun, 25 Oct 2026 20:00:00 GMT"))
        XCTAssertNil(E2EEV2APITransport.httpDate("2026-10-25T20:00:00Z"))
    }

    func testProbeComparison() async throws {
        let reference = try reference()
        let reader = makeReader(reference, server: Server(reference), store: makeStore(), nowMs: reference.headNowMs)
        _ = try await reader.refreshLinks()
        let head = try XCTUnwrap(E2EEAutoLog.parseHead(reference.headText))
        let seq9 = E2EEAutoLog.digest(reference.links[8])
        let agreeAtHead = await reader.compareProbe(seq: 16, linkHash: head.linkHash)
        let agreeEarlier = await reader.compareProbe(seq: 9, linkHash: seq9)
        let fork = await reader.compareProbe(seq: 9, linkHash: head.linkHash)
        let behind = await reader.compareProbe(seq: 17, linkHash: head.linkHash)
        XCTAssertEqual(agreeAtHead, .agree)
        XCTAssertEqual(agreeEarlier, .agree)
        XCTAssertEqual(fork, .fork)
        XCTAssertEqual(behind, .behind)
    }

    // MARK: Comptes

    func testAccountsNotServedOrNotYetAuto() async throws {
        let reference = try reference(), server = Server(reference)
        let alice = "user_alice_00000000001", carol = "user_carol_00000000003"
        let reader = makeReader(reference, server: server, store: makeStore(), nowMs: reference.headNowMs)
        _ = try await reader.refreshLinks()
        let notServed = try await reader.account("user_dave_000000000004")
        XCTAssertNil(notServed)

        server.accounts[carol] = (nil, [])
        let notYetAuto = try await reader.account(carol)
        guard case .success(let empty)? = notYetAuto else { return XCTFail("compte pas encore auto : \(String(describing: notYetAuto))") }
        XCTAssertTrue(empty.devices.isEmpty)
        XCTAssertEqual(empty.lastSeq, 0)

        // Le maillon ACCOUNT existe : le serveur ne peut pas taire le compte.
        server.accounts[alice] = (nil, [])
        let withheld = try await reader.account(alice)
        guard case .failure(let failure)? = withheld else { return XCTFail("compte tu : \(String(describing: withheld))") }
        XCTAssertEqual(failure.error, .accountWithheld)
    }

    func testAccountPagesAreStrict() async throws {
        let reference = try reference(), alice = "user_alice_00000000001", bob = "user_bob_0000000000002"
        for (label, configure) in [
            ("sel changé d'une page à l'autre", { (server: Server) in
                server.accountPageSize = 1
                server.saltAfterFirstPage = reference.accounts[bob]?.salt
            }),
            ("seq décroissants", { (server: Server) in server.reversesEntries = true }),
        ] {
            let server = Server(reference)
            configure(server)
            let reader = makeReader(reference, server: server, store: makeStore(), nowMs: reference.headNowMs)
            _ = try await reader.refreshLinks()
            do {
                let read = try await reader.account(alice)
                XCTFail("\(label) : \(String(describing: read))")
            } catch E2EEAutoLogReader.Failure.malformed {
            }
        }
    }

    /// Sel sans maillon `ACCOUNT` : toléré sans entrée, sinon échec à la première entrée (révision 6).
    func testSaltWithoutAccountLink() throws {
        let reference = try reference(), alice = "user_alice_00000000001"
        let account = try XCTUnwrap(reference.accounts[alice])
        let initial = E2EEAutoLog.ChainState.initial(pinnedLogKeyB64: reference.pinnedLogKeyB64, nextLogKeysB64: reference.nextLogKeysB64)
        let empty = E2EEAutoLog.verifyAccount(userId: alice, accountSaltB64: account.salt, entries: [], links: [:], chain: initial)
        XCTAssertNotNil(try? empty.get())
        let refused = E2EEAutoLog.verifyAccount(userId: alice, accountSaltB64: account.salt, entries: account.entries, links: [:], chain: initial)
        let firstSeq = try XCTUnwrap(account.entries.first.flatMap { E2EEAutoLog.parseEntry($0)?.entry.seq })
        XCTAssertEqual(refused, .failure(.init(error: .accountLinkMissing, seq: firstSeq)))
    }

    func testDeviceSetFromLog() async throws {
        let reference = try reference(), server = Server(reference)
        let alice = "user_alice_00000000001", bob = "user_bob_0000000000002", dave = "user_dave_000000000004"
        let reader = makeReader(reference, server: server, store: makeStore(), nowMs: reference.headNowMs)
        _ = try await reader.refreshLinks()
        var accounts: [String: Result<E2EEAutoLog.AccountState, E2EEAutoLog.AccountFailure>?] = [:]
        for userId in [alice, bob, dave] { accounts[userId] = try await reader.account(userId) }
        let set = E2EEAutoDeviceDirectory.deviceSet(accounts: accounts)

        XCTAssertEqual(set.refusals, [dave: .notFound])
        for userId in [alice, bob] {
            guard case .success(let account)?? = accounts[userId] else { return XCTFail(userId) }
            XCTAssertEqual(set.logSeqs[userId], account.lastSeq, userId)
            let devices = try XCTUnwrap(set.devicesByUser[userId], userId)
            XCTAssertEqual(devices.map(\.deviceId), account.activeDevices.map(\.deviceId), userId)
            for device in devices {
                let state = try XCTUnwrap(account.devices[device.deviceId])
                XCTAssertTrue(device.verifiedByLog)
                XCTAssertFalse(device.isSidelined(nowMs: .max))
                XCTAssertEqual(device.identityKeyB64, state.identityKeyB64, "clé d'accord du dernier ROTATE")
                XCTAssertEqual(device.keyVersion, state.keyVersion)
                XCTAssertEqual(device.fingerprint, E2EEAutoEpoch.recipientFingerprint(state))
                XCTAssertNotNil(device.signingKey)
            }
        }
        let withoutDave = E2EEV2CertifiedDeviceSet(devicesByUser: set.devicesByUser, refusals: [:])
        XCTAssertNotNil(withoutDave.capabilityIntersection(nowMs: reference.headNowMs, excludesWeb: false))
    }

    // MARK: Maillon sans entrée (§3.5 point 5, révision 13)

    /// Chez un contact : une alerte pour lui seul, gardée sans relecture, que la
    /// lecture suivante des maillons ne perd pas et que seul l'oubli du journal lève.
    func testAContactLinkWithoutItsEntryAlertsForThatContactAndIsKept() async throws {
        let reference = try reference(), server = Server(reference), store = makeStore()
        let bob = "user_bob_0000000000002"
        let full = try XCTUnwrap(reference.accounts[bob])
        let lastSeq = try XCTUnwrap(full.entries.last.flatMap { E2EEAutoLog.parseEntry($0)?.entry.seq })
        server.accounts[bob] = (full.salt, Array(full.entries.dropLast()))
        let reader = makeReader(reference, server: server, store: store, nowMs: reference.headNowMs)
        _ = try await reader.refreshLinks()

        let read = try await reader.account(bob)
        XCTAssertEqual(read, .failure(.init(error: .entryMissing, seq: lastSeq)))
        let expected = E2EEAutoLogStore.Alert(error: "ENTRY_MISSING", seq: lastSeq)
        XCTAssertEqual(try store.anchor(ownerScopeId: Self.owner)?.accountAlerts, [bob: expected])
        XCTAssertNil(try store.anchor(ownerScopeId: Self.owner)?.alert, "les autres conversations continuent")
        XCTAssertEqual(E2EEAutoDeviceDirectory.deviceSet(accounts: [bob: read]).refusals, [bob: .logEntryMissing])

        server.accounts[bob] = (full.salt, full.entries)
        let asked = server.accountAfters.count
        guard case .current = try await reader.refreshLinks() else { return XCTFail("maillons courants") }
        let reread = try await reader.account(bob)
        XCTAssertEqual(reread, read, "jamais réparé seul")
        XCTAssertEqual(server.accountAfters.count, asked, "ni relu")
        XCTAssertEqual(try store.anchor(ownerScopeId: Self.owner)?.accountAlerts, [bob: expected])

        let alerts = E2EEAutoLogAlerts(store: store, defaults: UserDefaults(suiteName: "account-alert-\(UUID().uuidString)")!)
        XCTAssertEqual(alerts.accountAlert(userId: bob, ownerScopeId: Self.owner), expected)
        alerts.setAccountReported("bug_7", for: expected, userId: bob, ownerScopeId: Self.owner)
        XCTAssertEqual(alerts.accountReportId(for: expected, userId: bob, ownerScopeId: Self.owner), "bug_7")
        XCTAssertNil(alerts.accountReportId(for: expected, userId: "user_carol_00000000003", ownerScopeId: Self.owner))
        try alerts.reset(ownerScopeId: Self.owner)
        XCTAssertNil(alerts.accountAlert(userId: bob, ownerScopeId: Self.owner))
        XCTAssertNil(alerts.accountReportId(for: expected, userId: bob, ownerScopeId: Self.owner))
    }

    /// Sur son propre compte : l'alerte globale, comme une fourche.
    func testOwnAccountWithheldRaisesTheGlobalAlert() async throws {
        let reference = try reference(), server = Server(reference), store = makeStore()
        server.accounts["user_alice_00000000001"] = (nil, [])
        let reader = makeReader(reference, server: server, store: store, nowMs: reference.headNowMs)
        _ = try await reader.refreshLinks()
        guard case .failure(let failure)? = try await reader.account("user_alice_00000000001") else { return XCTFail("compte tu") }
        XCTAssertEqual(failure.error, .accountWithheld)
        let alert = try XCTUnwrap(try store.anchor(ownerScopeId: Self.owner)?.alert)
        XCTAssertEqual(alert, .init(error: "ACCOUNT_WITHHELD", seq: try XCTUnwrap(failure.seq)))
        let status = try await reader.refreshLinks()
        XCTAssertEqual(status, .alert(alert))
    }

    /// Les autres échecs d'un compte le rendent illisible, sans alerte (révision 13).
    func testOtherAccountFailuresRaiseNoAlert() async throws {
        let reference = try reference(), server = Server(reference), store = makeStore()
        let alice = "user_alice_00000000001", bob = "user_bob_0000000000002"
        let full = try XCTUnwrap(reference.accounts[bob])
        server.accounts[bob] = (reference.accounts[alice]?.salt, full.entries)
        let reader = makeReader(reference, server: server, store: store, nowMs: reference.headNowMs)
        _ = try await reader.refreshLinks()
        guard case .failure(let failure)? = try await reader.account(bob) else { return XCTFail("sel d'un autre compte") }
        XCTAssertFalse(failure.isMissingLink)
        XCTAssertNil(try store.anchor(ownerScopeId: Self.owner)?.accountAlerts)
        XCTAssertNil(try store.anchor(ownerScopeId: Self.owner)?.alert)
        XCTAssertEqual(E2EEAutoDeviceDirectory.deviceSet(accounts: [bob: .failure(failure)]).refusals, [bob: .invalidDeviceList])
    }

    // MARK: Clés de production

    /// Les clés épinglées sont celles annoncées le 26/10 (§3.4) : points P-256
    /// valides, `logKeyId` attendus, et jamais les clés publiques des vecteurs.
    func testProductionLogKeysArePinnedAndAreNotVectorKeys() throws {
        let keys = try XCTUnwrap(E2EEAutoLogReader.productionLogKeys)
        XCTAssertEqual(keys.next.count, 1)
        for key in [keys.current] + keys.next {
            XCTAssertNoThrow(try P256.Signing.PublicKey(x963Representation: try XCTUnwrap(Data(base64Encoded: key))))
        }
        XCTAssertEqual(E2EEAutoLog.logKeyId(keys.current), "pMHQt1dVtqYasYPPTsFLVZmAE5g9csUaJ-_-EJK5toU")
        XCTAssertEqual(E2EEAutoLog.logKeyId(keys.next[0]), "hL8oRK4XxGnJk8GFNc-Ys6tMf0tHB4Doxshv116AmLU")
        let vectors = try reference()
        let vectorKeys = Set([vectors.pinnedLogKeyB64] + vectors.nextLogKeysB64)
        XCTAssertTrue(vectorKeys.isDisjoint(with: [keys.current] + keys.next))
        // Lot 9 (05/11) : ouvert dans la build, sans effet tant que le serveur ne bascule pas.
        XCTAssertTrue(SQFeatures.e2eeAutoLogEnabled, "le journal est ouvert pour la build de la bascule")
    }

    // MARK: Pages

    func testPageParsingIsStrict() throws {
        func links(_ object: [String: Any]) -> E2EEAutoLogPages.Links? {
            E2EEAutoLogPages.parseLinks(try! JSONSerialization.data(withJSONObject: object))
        }
        let head: [String: Any] = ["text": "t", "signatureB64": "s"]
        XCTAssertNotNil(links(["links": [], "logKeyEntries": [:], "head": head, "hasMore": false]))
        XCTAssertNil(links(["links": [], "logKeyEntries": [:], "head": head, "hasMore": 0]), "hasMore booléen")
        XCTAssertNil(links(["links": [], "logKeyEntries": ["013": "e"], "head": head, "hasMore": false]), "seq décimal canonique")
        XCTAssertNil(links(["links": [], "logKeyEntries": [:], "hasMore": false]), "tête absente")
        XCTAssertNil(links(["links": Array(repeating: "l", count: 1_001), "logKeyEntries": [:], "head": head, "hasMore": true]))

        func account(_ object: [String: Any]) -> E2EEAutoLogPages.Account? {
            E2EEAutoLogPages.parseAccount(try! JSONSerialization.data(withJSONObject: object), userId: "user_a")
        }
        XCTAssertNotNil(account(["userId": "user_a", "accountSaltB64": NSNull(), "entries": [], "hasMore": false]))
        XCTAssertNil(account(["userId": "user_b", "accountSaltB64": "s", "entries": [], "hasMore": false]), "autre compte")
        XCTAssertNil(account(["userId": "user_a", "accountSaltB64": NSNull(), "entries": ["e"], "hasMore": false]),
                     "sans sel, aucune entrée")
        XCTAssertNil(account(["userId": "user_a", "entries": [], "hasMore": false]), "sel absent, pas null")
    }

    // MARK: Révision 13

    /// Petit journal signé par une clé tirée ici : maillons, entrées `LOG_KEY` et tête au choix.
    private struct Signed {
        let key = P256.Signing.PrivateKey()
        var pinnedB64: String { key.publicKey.x963Representation.base64EncodedString() }

        static func link(seq: Int64, prev: String, kind: String = "ENTRY", tag: String, genesis: Bool = false) -> String {
            ["SQ-E2EE-AUTO-LOG-LINK", "1", String(seq), prev, kind, tag, E2EEAutoLog.digest("entrée \(seq)"), genesis ? "1" : "0"]
                .joined(separator: "\n")
        }

        /// Maillons enchaînés sur le texte entier, quel qu'en soit le format.
        static func chained(_ make: [(String) -> String]) -> [String] {
            var prev = E2EEAutoLog.genesisHash
            return make.map { build in
                let text = build(prev)
                prev = E2EEAutoLog.digest(text)
                return text
            }
        }

        func head(over links: [String], createdAtMs: Int64) throws -> (text: String, signatureB64: String) {
            let text = [
                "SQ-E2EE-AUTO-LOG-HEAD", "2", String(links.count), links.last.map(E2EEAutoLog.digest) ?? E2EEAutoLog.genesisHash,
                E2EEAutoLog.logKeyId(pinnedB64), String(createdAtMs),
            ].joined(separator: "\n")
            return (text, try E2EEV2LowS.sign(Data(text.utf8), with: key).base64EncodedString())
        }
    }

    private static let nowMs: Int64 = 1_790_036_000_000
    private static let accountTag = E2EEAutoLog.digest("compte")

    private func signedServer(_ signed: Signed, links: [String], headCreatedAtMs: Int64 = nowMs) throws -> Server {
        let server = Server(try reference())
        server.links = links
        server.logKeyEntries = [:]
        server.accounts = [:]
        (server.headText, server.headSignatureB64) = try signed.head(over: links, createdAtMs: headCreatedAtMs)
        return server
    }

    private func signedReader(_ signed: Signed, server: Server, store: E2EEAutoLogStore, nowMs: Int64 = nowMs) -> E2EEAutoLogReader {
        E2EEAutoLogReader(
            ownerScopeId: Self.owner, pinnedLogKeyB64: signed.pinnedB64, nextLogKeysB64: [], store: store,
            fetchLinks: { after in (server.linksPage(after: after), nil) },
            fetchAccount: { userId, after, upTo in server.accountPage(userId: userId, after: after, upTo: upTo) },
            now: { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1_000) },
            defaults: UserDefaults(suiteName: "e2ee-auto-log-\(UUID().uuidString)")!
        )
    }

    /// Maillons enchaînés jusqu'à une tête vérifiée mais contraires au §3.3 :
    /// alerte « chaîne invalide », gardée comme une fourche, même sur plusieurs pages.
    func testChainedButInvalidLinksUnderAVerifiedHeadRaiseTheAlert() async throws {
        let signed = Signed(), tag = Self.accountTag
        let cases: [(String, [(String) -> String], Int64)] = [
            ("deuxième ACCOUNT", [
                { Signed.link(seq: 1, prev: $0, kind: "ACCOUNT", tag: tag) },
                { Signed.link(seq: 2, prev: $0, tag: tag) },
                { Signed.link(seq: 3, prev: $0, kind: "ACCOUNT", tag: tag) },
            ], 3),
            ("genesis après un 0", [
                { Signed.link(seq: 1, prev: $0, kind: "ACCOUNT", tag: tag) },
                { Signed.link(seq: 2, prev: $0, tag: tag, genesis: true) },
            ], 2),
            ("maillon hors format", [
                { Signed.link(seq: 1, prev: $0, kind: "ACCOUNT", tag: tag) },
                { Signed.link(seq: 2, prev: $0, tag: tag).replacingOccurrences(of: "SQ-E2EE-AUTO-LOG-LINK", with: "SQ-E2EE-AUTO-LOG-LINX") },
            ], 2),
            ("maillon hors suite", [
                { Signed.link(seq: 1, prev: $0, kind: "ACCOUNT", tag: tag) },
                { Signed.link(seq: 7, prev: $0, tag: tag) },
            ], 7),
            ("LOG_KEY sans entrée", [
                { Signed.link(seq: 1, prev: $0, kind: "ACCOUNT", tag: tag) },
                { Signed.link(seq: 2, prev: $0, tag: E2EEAutoLog.none) },
            ], 2),
        ]
        for (name, make, seq) in cases {
            let server = try signedServer(signed, links: Signed.chained(make)), store = makeStore()
            server.pageSize = 1
            let status = try await signedReader(signed, server: server, store: store).refreshLinks()
            XCTAssertEqual(status, .alert(.init(error: "CHAIN_INVALID", seq: seq)), name)
            let again = try await signedReader(signed, server: server, store: store).refreshLinks()
            XCTAssertEqual(again, status, "\(name) : l'alerte ne se lève pas seule")
        }

        // Une entrée `LOG_KEY` en trop, sur une chaîne par ailleurs valide.
        let links = Signed.chained([
            { Signed.link(seq: 1, prev: $0, kind: "ACCOUNT", tag: tag) },
            { Signed.link(seq: 2, prev: $0, tag: tag) },
        ])
        let server = try signedServer(signed, links: links)
        server.logKeyEntries = [2: "entrée en trop"]
        let status = try await signedReader(signed, server: server, store: makeStore()).refreshLinks()
        XCTAssertEqual(status, .alert(.init(error: "CHAIN_INVALID", seq: 2)))
    }

    /// Le chaînage se lit avant le format : rompu, la tête ne prouve rien, non
    /// concluant et sans alerte. Une tête pas à jour n'engage rien non plus.
    func testBrokenLinkageOrStaleHeadIsInconclusive() async throws {
        let signed = Signed(), tag = Self.accountTag
        let valid: (String) -> String = { Signed.link(seq: 1, prev: $0, kind: "ACCOUNT", tag: tag) }
        let broken: [(String, [String])] = [
            ("moins de 4 lignes", Signed.chained([valid, { _ in "SQ-E2EE-AUTO-LOG-LINK\n1\n2" }])),
            ("4ᵉ ligne qui n'est pas un condensat", Signed.chained([valid, { _ in
                Signed.link(seq: 2, prev: "pas-un-condensat", tag: tag)
            }])),
            ("autre condensat", Signed.chained([valid, { _ in Signed.link(seq: 2, prev: E2EEAutoLog.digest("ailleurs"), tag: tag) }])),
        ]
        for (name, links) in broken {
            let store = makeStore()
            let reader = signedReader(signed, server: try signedServer(signed, links: links), store: store)
            let result = await status(reader)
            guard case .failure(let error) = result, case .invalidChain(let failure) = error as? E2EEAutoLogReader.Failure, failure == .init(error: .linkPrevHash, seq: 2) else {
                XCTFail("\(name) : \(result)"); continue
            }
            XCTAssertNil(try store.anchor(ownerScopeId: Self.owner), name)
        }

        let invalid = Signed.chained([valid, { Signed.link(seq: 2, prev: $0, kind: "ACCOUNT", tag: tag) }])
        let store = makeStore()
        let stale = try signedServer(signed, links: invalid, headCreatedAtMs: Self.nowMs - 2 * E2EEAutoLog.headMaxAgeMs)
        let result = await status(signedReader(signed, server: stale, store: store))
        guard case .failure(let error) = result, case .invalidChain(let failure) = error as? E2EEAutoLogReader.Failure, failure == .init(error: .duplicateAccount, seq: 2) else {
            return XCTFail("tête pas à jour : \(result)")
        }
        XCTAssertNil(try store.anchor(ownerScopeId: Self.owner))

        // Et une chaîne valide sous la même clé passe.
        let ok = try await signedReader(signed, server: try signedServer(signed, links: Signed.chained([valid])), store: makeStore()).refreshLinks()
        guard case .current = ok else { return XCTFail("\(ok)") }
    }

    /// `429` : non concluant, plus aucun appel avant `Retry-After` (ou une heure),
    /// le quota de comptes ne retient que `log/accounts` ; persistant d'un lecteur à l'autre.
    func testRateLimitsHoldFurtherReads() async throws {
        let signed = Signed()
        let links = Signed.chained([{ Signed.link(seq: 1, prev: $0, kind: "ACCOUNT", tag: Self.accountTag) }])
        let server = try signedServer(signed, links: links)
        let suite = "e2ee-auto-log-\(UUID().uuidString)"
        final class Calls: @unchecked Sendable { var links = 0, accounts = 0, linksFailure: Error?, accountFailure: Error? }
        let calls = Calls()
        func reader(at nowMs: Int64) -> E2EEAutoLogReader {
            E2EEAutoLogReader(
                ownerScopeId: Self.owner, pinnedLogKeyB64: signed.pinnedB64, nextLogKeysB64: [], store: makeStore(),
                fetchLinks: { after in
                    calls.links += 1
                    if let failure = calls.linksFailure { calls.linksFailure = nil; throw failure }
                    return (server.linksPage(after: after), nil)
                },
                fetchAccount: { userId, after, upTo in
                    calls.accounts += 1
                    if let failure = calls.accountFailure { calls.accountFailure = nil; throw failure }
                    return server.accountPage(userId: userId, after: after, upTo: upTo)
                },
                now: { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1_000) },
                defaults: UserDefaults(suiteName: suite)!
            )
        }
        func isRateLimited(_ call: () async throws -> Void) async -> Bool {
            do { try await call(); return false } catch { return error as? E2EEAutoLogReader.Failure == .rateLimited }
        }

        calls.linksFailure = E2EEV2TransportFailure(kind: .retryable, statusCode: 429, message: "e2ee-http-429", retryAfterSeconds: 120)
        let first = reader(at: Self.nowMs)
        let firstLimited = await isRateLimited { _ = try await first.refreshLinks() }
        XCTAssertTrue(firstLimited)
        let retryAt = await first.retryAtMs(.reads)
        XCTAssertEqual(retryAt, Self.nowMs + 120_000)
        let during = reader(at: Self.nowMs + 119_000)
        let duringLimited = await isRateLimited { _ = try await during.refreshLinks() }
        XCTAssertTrue(duringLimited)
        XCTAssertEqual(calls.links, 1, "aucun appel avant Retry-After")
        let after = reader(at: Self.nowMs + 120_001)
        let status = try await after.refreshLinks()
        guard case .current = status else { return XCTFail("\(status)") }

        // Quota de comptes, sans Retry-After : une heure, et seulement log/accounts.
        calls.accountFailure = E2EEV2TransportFailure(kind: .retryable, statusCode: 429, code: "E2EE_AUTO_ACCOUNT_QUOTA", message: "quota")
        let accountLimited = await isRateLimited { _ = try await after.account("user_alice_00000000001") }
        XCTAssertTrue(accountLimited)
        let accountsRetry = await after.retryAtMs(.accounts)
        XCTAssertEqual(accountsRetry, Self.nowMs + 120_001 + 3_600_000)
        let readsRetry = await after.retryAtMs(.reads)
        XCTAssertNil(readsRetry)
        let later = reader(at: Self.nowMs + 600_000)
        _ = try await later.refreshLinks()
        let laterLimited = await isRateLimited { _ = try await later.account("user_alice_00000000001") }
        XCTAssertTrue(laterLimited)
        XCTAssertEqual(calls.accounts, 1)

        // Les autres erreurs passent telles quelles, sans attente.
        calls.linksFailure = E2EEV2TransportFailure(kind: .retryable, statusCode: 503, message: "e2ee-http-503")
        let other = reader(at: Self.nowMs + 700_000)
        let otherLimited = await isRateLimited { _ = try await other.refreshLinks() }
        XCTAssertFalse(otherLimited)
        let otherRetry = await other.retryAtMs(.reads)
        XCTAssertNil(otherRetry)
    }

    func testOnlyTheCodedNotFoundIsDecisive() {
        XCTAssertTrue(E2EEAutoLogReader.isAccountNotFound(.init(kind: .permanent, statusCode: 404, code: "E2EE_AUTO_ACCOUNT_NOT_FOUND", message: "x")))
        XCTAssertFalse(E2EEAutoLogReader.isAccountNotFound(.init(kind: .permanent, statusCode: 404, message: "x")))
        XCTAssertFalse(E2EEAutoLogReader.isAccountNotFound(.init(kind: .permanent, statusCode: 404, code: "NOT_FOUND", message: "x")))
        XCTAssertFalse(E2EEAutoLogReader.isAccountNotFound(.init(kind: .permanent, statusCode: 410, code: "E2EE_AUTO_ACCOUNT_NOT_FOUND", message: "x")))
    }
}

// MARK: - Sonde (§3.7, révision 21 §7.8 E) : vecteur `probe-head-v1`

extension E2EEAutoLogReaderTests {
    private struct Probe {
        let vector: [String: Any]
        let probeKeys: [String: String]
        let logKeyB64: String
        let links: [String]
        let forkedLinks: [String]

        func data(_ file: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: file, options: [.fragmentsAllowed])
        }

        func cases(_ name: String) -> [[String: Any]] { vector[name] as? [[String: Any]] ?? [] }

        func validFile(_ name: String) throws -> Data {
            try data(XCTUnwrap(cases("valid").first { $0["name"] as? String == name }?["file"]))
        }

        /// Tête du journal signée, tirée des cas `compare` et `afterReread`.
        func head(seq: Int64, linkHash: String? = nil) throws -> (text: String, signatureB64: String) {
            let heads = (cases("compare").flatMap { [$0["appHead"], $0["probeHead"]] } + cases("afterReread").map { $0["probeHead"] })
                .compactMap { $0 as? [String: String] }
            let found = heads.first {
                guard let parsed = $0["text"].flatMap(E2EEAutoLog.parseHead) else { return false }
                return parsed.seq == seq && (linkHash == nil || parsed.linkHash == linkHash)
            }
            let head = try XCTUnwrap(found)
            return (try XCTUnwrap(head["text"]), try XCTUnwrap(head["signatureB64"]))
        }
    }

    private func probeVector() throws -> Probe {
        let vector = try load("probe-head-v1")
        let probeKey = try XCTUnwrap(vector["probeKey"] as? [String: String])
        let logKey = try XCTUnwrap(vector["logKey"] as? [String: String])
        let chain = try XCTUnwrap(vector["chain"] as? [String: [String]])
        return Probe(
            vector: vector,
            probeKeys: [try XCTUnwrap(probeKey["keyId"]): try XCTUnwrap(probeKey["publicKeyB64"])],
            logKeyB64: try XCTUnwrap(logKey["publicKeyB64"]),
            links: try XCTUnwrap(chain["links"]), forkedLinks: try XCTUnwrap(chain["forkedLinks"])
        )
    }

    func testProbeHeadVectors() throws {
        let probe = try probeVector()
        let vector = probe.vector
        XCTAssertEqual(vector["maxAgeMs"] as? String, String(E2EEAutoProbeHead.maxAgeMs))
        XCTAssertEqual(vector["clockToleranceMs"] as? String, String(E2EEAutoLog.clockToleranceMs))
        for key in ["probeKey", "otherProbeKey"] {
            let pair = try XCTUnwrap(vector[key] as? [String: String])
            XCTAssertEqual(E2EEAutoProbeHead.keyId(try XCTUnwrap(pair["publicKeyB64"])), pair["keyId"], key)
        }
        let payload = try XCTUnwrap(vector["payload"] as? [String: String])
        XCTAssertEqual(
            E2EEAutoProbeHead.payload(
                keyId: try XCTUnwrap(payload["keyId"]), headText: try XCTUnwrap(payload["headText"]), seenAtMs: try XCTUnwrap(payload["seenAtMs"])
            ),
            payload["text"]
        )
        let pinned = try XCTUnwrap(E2EEAutoProbeHead.pinnedKeys.first)
        XCTAssertEqual(E2EEAutoProbeHead.keyId(pinned.value), pinned.key)

        for valid in probe.cases("valid") {
            let name = try XCTUnwrap(valid["name"] as? String)
            let expected = try XCTUnwrap(valid["expected"] as? [String: Any])
            let nowMs = try XCTUnwrap((valid["nowMs"] as? NSNumber)?.int64Value)
            let check = E2EEAutoProbeHead.verify(try probe.data(try XCTUnwrap(valid["file"])), probeKeys: probe.probeKeys, logKeyB64: probe.logKeyB64, nowMs: nowMs)
            let head: E2EEAutoLog.Head
            switch (check, expected["status"] as? String) {
            case (.ok(let verified), "ok"), (.stale(let verified), "stale"): head = verified
            default: XCTFail("\(name) : \(check)"); continue
            }
            XCTAssertEqual(head.seq, (expected["seq"] as? NSNumber)?.int64Value, name)
            XCTAssertEqual(head.linkHash, expected["linkHash"] as? String, name)
            XCTAssertEqual(valid["appBehavior"] as? String, check == .ok(head) ? "COMPARE" : "IGNORE", name)
        }

        XCTAssertFalse(probe.cases("negative").isEmpty)
        for negative in probe.cases("negative") {
            let name = try XCTUnwrap(negative["name"] as? String)
            let nowMs = try XCTUnwrap((negative["nowMs"] as? NSNumber)?.int64Value)
            let check = E2EEAutoProbeHead.verify(try probe.data(try XCTUnwrap(negative["file"])), probeKeys: probe.probeKeys, logKeyB64: probe.logKeyB64, nowMs: nowMs)
            XCTAssertEqual(check, .invalid(try XCTUnwrap(E2EEAutoProbeHead.Invalid(rawValue: try XCTUnwrap(negative["expected"] as? String)))), name)
            XCTAssertEqual(negative["appBehavior"] as? String, "IGNORE", name)
        }

        // `v` booléen, décimal ou nul : jamais le nombre 1.
        let basic = try XCTUnwrap(try JSONSerialization.jsonObject(with: probe.validFile("basic")) as? [String: Any])
        for v: Any in [true, 1.5, NSNull()] {
            var file = basic
            file["v"] = v
            XCTAssertEqual(E2EEAutoProbeHead.verify(try probe.data(file), probeKeys: probe.probeKeys, logKeyB64: probe.logKeyB64, nowMs: 1_790_010_840_000), .invalid(.format))
        }
        // La clé épinglée de production ne connaît pas la clé de test.
        XCTAssertEqual(
            E2EEAutoProbeHead.verify(try probe.validFile("basic"), logKeyB64: probe.logKeyB64, nowMs: 1_790_010_840_000),
            .invalid(.keyUnknown)
        )
    }

    /// Fichier de la sonde signé par une clé de test : pour les têtes que le vecteur ne publie pas.
    private func signedProbeFile(head: (text: String, signatureB64: String), seenAtMs: Int64, key: P256.Signing.PrivateKey) throws -> Data {
        let keyB64 = key.publicKey.x963Representation.base64EncodedString()
        let keyId = E2EEAutoProbeHead.keyId(keyB64)
        let payload = E2EEAutoProbeHead.payload(keyId: keyId, headText: head.text, seenAtMs: String(seenAtMs))
        let signature = try E2EEV2LowS.sign(Data(payload.utf8), with: key)
        return try JSONSerialization.data(withJSONObject: [
            "v": 1, "keyId": keyId, "head": ["text": head.text, "signatureB64": head.signatureB64],
            "seenAtMs": String(seenAtMs), "signatureB64": signature.base64EncodedString(),
        ] as [String: Any])
    }

    private final class ProbeBox: @unchecked Sendable {
        var data: Data?
        private(set) var fetches = 0
        init(_ data: Data?) { self.data = data }
        func fetch() -> Data? { fetches += 1; return data }
    }

    private final class Clock: @unchecked Sendable {
        var nowMs: Int64
        init(_ nowMs: Int64) { self.nowMs = nowMs }
    }

    /// Lecteur sur la chaîne du vecteur (5 maillons, sans entrée `LOG_KEY`), dont le serveur sert les `served` premiers.
    private func probeReader(
        _ probe: Probe, served: Int, links: [String]? = nil, file: ProbeBox, clock: Clock, probeKeys: [String: String]? = nil,
        store: E2EEAutoLogStore
    ) throws -> (E2EEAutoLogReader, Server) {
        let all = links ?? probe.links
        let head = try probe.head(seq: Int64(served), linkHash: served == 0 ? nil : E2EEAutoLog.digest(all[served - 1]))
        let reference = Reference(
            pinnedLogKeyB64: probe.logKeyB64, nextLogKeysB64: [], links: Array(all.prefix(served)), logKeyEntries: [:],
            headText: head.text, headSignatureB64: head.signatureB64, headNowMs: clock.nowMs, accounts: [:],
            emptyHeadText: "", emptyHeadSignatureB64: "", emptyHeadNowMs: 0
        )
        let server = Server(reference)
        let reader = E2EEAutoLogReader(
            ownerScopeId: Self.owner, pinnedLogKeyB64: probe.logKeyB64, nextLogKeysB64: [], store: store,
            fetchLinks: { after in (server.linksPage(after: after), nil) },
            fetchAccount: { _, _, _ in nil },
            fetchProbe: { file.fetch() },
            probeKeys: probeKeys ?? probe.probeKeys,
            now: { Date(timeIntervalSince1970: TimeInterval(clock.nowMs) / 1_000) }
        )
        return (reader, server)
    }

    func testProbeAgreesOncePerDayAndIgnoresWhatItCannotTrust() async throws {
        let probe = try probeVector()
        let clock = Clock(1_790_010_840_000)
        let file = ProbeBox(try probe.validFile("basic"))
        let store = makeStore()
        let (reader, _) = try probeReader(probe, served: 5, file: file, clock: clock, store: store)

        let unread = await reader.checkProbeIfDue()
        XCTAssertEqual(unread, .skipped, "Rien avant la lecture des maillons")
        XCTAssertEqual(file.fetches, 0)
        _ = try await reader.refreshLinks()
        let first = await reader.checkProbeIfDue()
        let sameDay = await reader.checkProbeIfDue()
        XCTAssertEqual(first, .agree)
        XCTAssertEqual(sameDay, .skipped)
        XCTAssertEqual(file.fetches, 1)

        // La sonde n'a vu que la genèse : un préfixe de la chaîne d'ici.
        clock.nowMs += E2EEAutoProbeHead.checkIntervalMs
        file.data = try probe.validFile("emptyLog")
        _ = try await reader.refreshLinks()
        let empty = await reader.checkProbeIfDue()
        XCTAssertEqual(empty, .agree)

        // Absent, clé inconnue, signature fausse ou trop vieux : ignoré jusqu'au lendemain, sans alerte.
        let unknown = try XCTUnwrap(probe.cases("negative").first { $0["name"] as? String == "unknownKey" }?["file"])
        let wrong = try XCTUnwrap(probe.cases("negative").first { $0["name"] as? String == "wrongSignature" }?["file"])
        let invalidFiles: [Data?] = [nil, Data("<html>".utf8), try probe.data(unknown), try probe.data(wrong)]
        for data in invalidFiles {
            clock.nowMs += E2EEAutoProbeHead.checkIntervalMs
            file.data = data
            _ = try await reader.refreshLinks()
            let ignored = await reader.checkProbeIfDue()
            let again = await reader.checkProbeIfDue()
            XCTAssertEqual(ignored, .ignored)
            XCTAssertEqual(again, .skipped)
        }
        // Vue il y a plus de 7 jours : ignorée, même juste.
        clock.nowMs = 1_790_007_240_000 + E2EEAutoProbeHead.maxAgeMs + 1
        file.data = try probe.validFile("basic")
        _ = try await reader.refreshLinks()
        let stale = await reader.checkProbeIfDue()
        XCTAssertEqual(stale, .ignored)
        let status = try await reader.refreshLinks()
        XCTAssertNil(try store.anchor(ownerScopeId: Self.owner)?.alert)
        if case .alert = status { XCTFail("Aucune alerte attendue") }
    }

    func testProbeAheadIsRereadThenJudged() async throws {
        let probe = try probeVector()
        // La sonde a vu le maillon 5 ; ici, la chaîne s'arrête à 4 puis le serveur le sert.
        let clock = Clock(1_790_010_840_000)
        let file = ProbeBox(try probe.validFile("basic"))
        let (reader, server) = try probeReader(probe, served: 4, file: file, clock: clock, store: makeStore())
        _ = try await reader.refreshLinks()
        let fifth = try probe.head(seq: 5, linkHash: E2EEAutoLog.digest(probe.links[4]))
        server.links = probe.links
        server.headText = fifth.text
        server.headSignatureB64 = fifth.signatureB64
        let agree = await reader.checkProbeIfDue()
        XCTAssertEqual(agree, .agree)
        XCTAssertEqual(server.linkAfters, [0, 4])

        // Relecture non concluante : jamais une fourche.
        let store = makeStore()
        let (stuck, stuckServer) = try probeReader(probe, served: 4, file: file, clock: clock, store: store)
        _ = try await stuck.refreshLinks()
        stuckServer.headText = "illisible"
        let inconclusive = await stuck.checkProbeIfDue()
        XCTAssertEqual(inconclusive, .ignored)
        XCTAssertNil(try store.anchor(ownerScopeId: Self.owner)?.alert)

        // Relecture concluante qui reste sous la sonde : le journal ne raccourcit pas.
        let below = makeStore()
        let (behind, _) = try probeReader(probe, served: 4, file: file, clock: clock, store: below)
        _ = try await behind.refreshLinks()
        let fork = await behind.checkProbeIfDue()
        XCTAssertEqual(fork, .fork)
        XCTAssertEqual(try below.anchor(ownerScopeId: Self.owner)?.alert, .init(error: "FORK", seq: 5))
        let kept = try await behind.refreshLinks()
        XCTAssertEqual(kept, .alert(.init(error: "FORK", seq: 5)))
    }

    func testProbeOnAnotherBranchRaisesTheForkAlert() async throws {
        let probe = try probeVector()
        let clock = Clock(1_790_010_840_000)
        let key = P256.Signing.PrivateKey()
        let keyB64 = key.publicKey.x963Representation.base64EncodedString()
        let forked = try probe.head(seq: 5, linkHash: E2EEAutoLog.digest(probe.forkedLinks[4]))
        XCTAssertNotEqual(probe.links[4], probe.forkedLinks[4])
        let file = ProbeBox(try signedProbeFile(head: forked, seenAtMs: clock.nowMs - 60_000, key: key))
        let store = makeStore()
        let (reader, _) = try probeReader(
            probe, served: 5, file: file, clock: clock, probeKeys: [E2EEAutoProbeHead.keyId(keyB64): keyB64], store: store
        )
        _ = try await reader.refreshLinks()
        let fork = await reader.checkProbeIfDue()
        XCTAssertEqual(fork, .fork)
        let kept = try await reader.refreshLinks()
        XCTAssertEqual(kept, .alert(.init(error: "FORK", seq: 5)))

        // Même tête signée par une autre clé de sonde : inconnue, donc ignorée.
        let other = makeStore()
        let (unknown, _) = try probeReader(probe, served: 5, file: file, clock: clock, store: other)
        _ = try await unknown.refreshLinks()
        let ignored = await unknown.checkProbeIfDue()
        XCTAssertEqual(ignored, .ignored)
        XCTAssertNil(try other.anchor(ownerScopeId: Self.owner)?.alert)
    }
}
