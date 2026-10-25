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
            linkAfters.append(after)
            let page = Array(links.dropFirst(Int(after)).prefix(pageSize))
            let last = Int(after) + page.count
            var entries: [String: String] = [:]
            for seq in (Int(after) + 1)..<(last + 1) where logKeyEntries[Int64(seq)] != nil {
                entries[String(seq)] = logKeyEntries[Int64(seq)]
            }
            let object: [String: Any] = [
                "links": page, "logKeyEntries": entries,
                "head": ["text": headText, "signatureB64": headSignatureB64], "hasMore": last < links.count,
            ]
            return try! JSONSerialization.data(withJSONObject: object)
        }

        func accountPage(userId: String, after: Int64) -> Data? {
            accountAfters.append(after)
            guard let account = accounts[userId] else { return nil }
            let entries = account.entries.filter { (E2EEAutoLog.parseEntry($0)?.entry.seq ?? 0) > after }
            let object: [String: Any] = [
                "userId": userId, "accountSaltB64": account.salt.map { $0 as Any } ?? NSNull(),
                "entries": entries, "hasMore": false,
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
            fetchAccount: { userId, after in server.accountPage(userId: userId, after: after) },
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
        XCTAssertEqual(failure.error, .accountLinkMissing)
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
}
