import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot C1 (E2EE-AUTO §5.1) : publication de HK signée ici, comparaison-échange
/// sur la dernière HK du journal, déclaration `present` une seule fois.
final class E2EEAutoHistoryKeyPublicationTests: XCTestCase {
    private static let userId = "user_alice_00000000001"
    private static let salt = Data(repeating: 7, count: 16).base64EncodedString()
    private let signing = P256.Signing.PrivateKey()
    private let ownId = "ios_device_own_000000000"

    private static func newKey() -> String {
        P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
    }

    private var ownDevice: E2EEV2DeviceDescriptor {
        E2EEV2DeviceDescriptor(
            deviceId: ownId, platform: "ios", label: nil, publicIdentityKeyB64: Self.newKey(),
            publicSigningKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            identityKeyAlgorithm: E2EEV2DeviceAlgorithms.identityKeyAlgorithm,
            signingKeyAlgorithm: E2EEV2DeviceAlgorithms.signingKeyAlgorithm, keyVersion: 1
        )
    }

    private func account(
        hk: String? = nil, status: E2EEAutoLog.DeviceStatus = .active, addedAtMs: Int64 = 1,
        last: String = E2EEAutoLog.digest("last")
    ) -> E2EEAutoLog.AccountState {
        let key = Self.newKey()
        var account = E2EEAutoLog.AccountState(userId: Self.userId, accountSaltB64: Self.salt)
        account.devices[ownId] = E2EEAutoLog.DeviceState(
            deviceId: ownId, platform: .ios, identityKeyB64: key, signingKeyB64: ownDevice.publicSigningKeyB64,
            keyVersion: 1, status: status, addedAtMs: addedAtMs, activatedAtMs: status == .pending ? nil : addedAtMs,
            addEntryHash: E2EEAutoLog.digest("add"), identityKeys: [.init(keyVersion: 1, identityKeyB64: key, sinceMs: addedAtMs)],
            revokeReason: nil, revokeSeq: nil, revokedAtMs: nil
        )
        account.historyKeyPubB64 = hk
        account.lastEntryHash = last
        return account
    }

    /// La `HISTORY_KEY` que le serveur écrirait, signée par `key`.
    private func written(hk: String, previous: String?, prev: String, key: P256.Signing.PrivateKey? = nil) throws -> Data {
        let payload = E2EEAutoHistoryKeyContract.payload(
            userId: Self.userId, prevUserEntryHash: prev, signerDeviceId: ownId, previousHkPubB64: previous, hkPubB64: hk
        )
        let signature = try E2EEV2LowS.sign(Data(payload.utf8), with: key ?? signing).base64EncodedString()
        let entry = E2EEAutoLog.Entry(
            seq: 30, userId: Self.userId, prevUserEntryHash: prev, op: .historyKey, deviceId: E2EEAutoLog.none,
            platform: E2EEAutoLog.none, identityKeyB64: E2EEAutoLog.none, signingKeyB64: E2EEAutoLog.none,
            keyVersion: E2EEAutoLog.none, detail: "\(ownId):\(hk):\(signature)", createdAtMs: 9
        ).canonical
        let link = ["SQ-E2EE-AUTO-LOG-LINK", "1", "30", E2EEAutoLog.digest("prev"), "ENTRY", E2EEAutoLog.digest("tag"),
                    E2EEAutoLog.digest(entry), "0"].joined(separator: "\n")
        return try JSONSerialization.data(withJSONObject: ["entry": entry, "link": link, "head": ["text": "t", "signatureB64": "s"]])
    }

    private static func failure(_ status: Int, _ code: String, retryAfter: Int? = nil) -> E2EEV2TransportResult<Data> {
        .failure(.init(
            kind: E2EEV2TransportFailurePolicy.classify(statusCode: status, code: code), statusCode: status, code: code, message: "x",
            retryAfterSeconds: retryAfter
        ))
    }

    private final class Fake: @unchecked Sendable {
        var reads: [E2EEAutoEnrollment.OwnAccount]
        var readCount = 0
        var responses: [(E2EEAutoHistoryKeyPublicationTests.Fake) -> E2EEV2TransportResult<Data>] = []
        var putResult: E2EEV2TransportResult<Data> = .success(value: Data("{}".utf8), statusCode: 200, idempotentReplay: false)
        var held: Set<String> = []
        var pending: String?
        var reported: String?
        private(set) var created: [String] = []
        private(set) var discarded: [String] = []
        private(set) var posts: [[String: Any]] = []
        private(set) var puts: [(path: String, body: [String: Any])] = []
        var nowMs: Int64 = 1_000_000

        init(reads: [E2EEAutoEnrollment.OwnAccount]) { self.reads = reads }

        func dependencies(device: E2EEV2DeviceDescriptor, signing: P256.Signing.PrivateKey) -> E2EEAutoHistoryKeyPublication.Dependencies {
            .init(
                userId: E2EEAutoHistoryKeyPublicationTests.userId,
                device: { device },
                sign: { try E2EEV2LowS.sign($0, with: signing) },
                post: { [self] _, body, _ in
                    posts.append((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
                    return responses.isEmpty ? .failure(.init(kind: .retryable, statusCode: 503, message: "x")) : responses.removeFirst()(self)
                },
                put: { [self] path, body, _ in
                    puts.append((path, (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]))
                    return putResult
                },
                readOwnAccount: { [self] in
                    defer { readCount += 1 }
                    return reads[min(readCount, reads.count - 1)]
                },
                holds: { [self] in held.contains($0) },
                create: { [self] in
                    let key = E2EEAutoHistoryKeyPublicationTests.newKey()
                    created.append(key)
                    held.insert(key)
                    return key
                },
                discard: { [self] in
                    discarded.append($0)
                    held.remove($0)
                },
                pendingKey: { [self] in pending },
                recordPendingKey: { [self] in pending = $0 },
                reportedStatus: { [self] in reported },
                recordReportedStatus: { [self] in reported = $0 },
                nowMs: { [self] in nowMs }
            )
        }
    }

    private func publication(_ fake: Fake) -> E2EEAutoHistoryKeyPublication {
        E2EEAutoHistoryKeyPublication(fake.dependencies(device: ownDevice, signing: signing))
    }

    /// Réponse au corps reçu : l'entrée écrite sur la clé et l'état envoyés.
    private func echo(key: P256.Signing.PrivateKey? = nil) -> (Fake) -> E2EEV2TransportResult<Data> {
        { [self] fake in
            let body = fake.posts.last ?? [:]
            let previous = body["previousHkPubB64"] as? String
            let data = try! written(
                hk: body["hkPubB64"] as! String, previous: previous == "-" ? nil : previous,
                prev: body["prevUserEntryHash"] as! String, key: key
            )
            return .success(value: data, statusCode: 201, idempotentReplay: false)
        }
    }

    // MARK: Contrat

    func testBodyHasTheFourFieldsAndADashWithoutPreviousKey() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: E2EEAutoHistoryKeyContract.body(
            prevUserEntryHash: "h", previousHkPubB64: nil, hkPubB64: "k", signatureB64: "s"
        )) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["prevUserEntryHash", "previousHkPubB64", "hkPubB64", "signatureB64"])
        XCTAssertEqual(body["previousHkPubB64"] as? String, "-")
        XCTAssertEqual(
            E2EEAutoHistoryKeyContract.payload(userId: "u", prevUserEntryHash: "p", signerDeviceId: "d", previousHkPubB64: nil, hkPubB64: "k"),
            "SQ-E2EE-AUTO-HISTORY-KEY\n1\nu\np\nd\n-\nk"
        )
        XCTAssertEqual(E2EEAutoHistoryKeyContract.historyStatusPath(deviceId: ownId), "/api/e2ee/auto/devices/\(ownId)/history-status")
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: E2EEAutoHistoryKeyContract.statusBody(present: true)) as? [String: String])
        XCTAssertEqual(status, ["historyKey": "present"])
    }

    func testResponseMustBeThisKeySignedHere() throws {
        let hk = Self.newKey(), prev = E2EEAutoLog.digest("last")
        func parse(_ data: Data, hk expected: String? = nil) -> Bool {
            E2EEAutoHistoryKeyContract.parse(
                data, userId: Self.userId, signerDeviceId: ownId, previousHkPubB64: nil, hkPubB64: expected ?? hk,
                signingKeyB64: ownDevice.publicSigningKeyB64
            )
        }
        XCTAssertTrue(parse(try written(hk: hk, previous: nil, prev: prev)))
        XCTAssertTrue(parse(try written(hk: hk, previous: nil, prev: E2EEAutoLog.digest("replay"))), "rejeu : entrée déjà écrite")
        XCTAssertFalse(parse(try written(hk: hk, previous: nil, prev: prev), hk: Self.newKey()), "autre clé publiée")
        XCTAssertFalse(parse(try written(hk: hk, previous: Self.newKey(), prev: prev)), "autre HK précédente")
        XCTAssertFalse(parse(try written(hk: hk, previous: nil, prev: prev, key: P256.Signing.PrivateKey())), "autre signataire")
    }

    // MARK: Publication

    func testFirstDevicePublishesThenReportsPresentOnce() async {
        let fake = Fake(reads: [.verified(account())])
        fake.responses = [echo()]
        let outcome = await publication(fake).run()
        let key = fake.created.first
        XCTAssertEqual(outcome, key.map { .present(hkPubB64: $0) })
        XCTAssertEqual(fake.posts.first?["previousHkPubB64"] as? String, "-")
        XCTAssertEqual(fake.posts.first?["prevUserEntryHash"] as? String, E2EEAutoLog.digest("last"))
        XCTAssertEqual(fake.puts.map(\.path), [E2EEAutoHistoryKeyContract.historyStatusPath(deviceId: ownId)])
        XCTAssertEqual(fake.puts.first?.body["historyKey"] as? String, "present")

        // Une fois au journal, le marqueur tombe et la déclaration n'est pas refaite.
        let again = Fake(reads: [.verified(account(hk: key))])
        again.held = fake.held
        again.pending = fake.pending
        again.reported = fake.reported
        let second = await publication(again).run()
        XCTAssertEqual(second, key.map { .present(hkPubB64: $0) })
        XCTAssertNil(again.pending)
        XCTAssertTrue(again.posts.isEmpty)
        XCTAssertTrue(again.puts.isEmpty, "present déjà déclaré pour cette HK")
    }

    func testDeviceWithoutTheAccountKeyIsMissingAndPublishesNothing() async {
        let hk = Self.newKey()
        let fake = Fake(reads: [.verified(account(hk: hk))])
        let outcome = await publication(fake).run()
        XCTAssertEqual(outcome, .missing(hkPubB64: hk))
        XCTAssertTrue(fake.created.isEmpty)
        XCTAssertTrue(fake.posts.isEmpty)
        XCTAssertTrue(fake.puts.isEmpty, "absent n'est pas déclaré à ce stade")
    }

    func testLostCompareAndSwapDiscardsItsKeyAndRereads() async {
        let winner = Self.newKey()
        let fake = Fake(reads: [.verified(account()), .verified(account(hk: winner))])
        fake.responses = [{ _ in Self.failure(409, "E2EE_HISTORY_KEY_STALE") }]
        let outcome = await publication(fake).run()
        XCTAssertEqual(outcome, .missing(hkPubB64: winner))
        XCTAssertEqual(fake.discarded, fake.created, "la HK perdante quitte le trousseau")
        XCTAssertNil(fake.pending)
        XCTAssertEqual(fake.readCount, 2)
    }

    func testLostResponseRepublishesTheSamePendingKey() async {
        let fake = Fake(reads: [.verified(account())])
        let first = await publication(fake).run()
        XCTAssertEqual(first, .retryLater(afterSeconds: nil))
        let pending = fake.pending
        XCTAssertNotNil(pending)
        fake.responses = [echo()]
        let second = await publication(fake).run()
        XCTAssertEqual(fake.created.count, 1, "pas de nouvelle HK tant que la première peut être écrite")
        XCTAssertEqual(fake.posts.last?["hkPubB64"] as? String, pending)
        XCTAssertEqual(second, pending.map { .present(hkPubB64: $0) })
    }

    func testReplacingALostKeyWaitsForTheSignerAge() async {
        let lost = Self.newKey()
        let fake = Fake(reads: [.verified(account(hk: lost, addedAtMs: 1_000_000))])
        fake.nowMs = 1_000_000 + E2EEAutoLog.signerMinAgeMs - 1
        let early = await publication(fake).replaceLostKey()
        XCTAssertEqual(early, .tooRecent)
        XCTAssertTrue(fake.posts.isEmpty)

        fake.nowMs = 1_000_000 + E2EEAutoLog.signerMinAgeMs
        fake.responses = [echo()]
        let outcome = await publication(fake).replaceLostKey()
        XCTAssertEqual(fake.posts.first?["previousHkPubB64"] as? String, lost, "comparaison-échange sur la HK perdue")
        XCTAssertEqual(outcome, fake.created.first.map { .present(hkPubB64: $0) })
    }

    /// Rotation après un REVOKE (§5.6) : HK′ par-dessus la HK détenue, seulement si la
    /// rotation est encore due ; sinon la HK courante reste simplement déclarée.
    func testRotationPublishesOverTheHeldKeyOnlyWhileDue() async {
        let current = Self.newKey()
        var due = account(hk: current)
        due.rotationDueRevokeSeq = 40
        let fake = Fake(reads: [.verified(account(hk: current))])
        fake.held = [current]
        fake.nowMs = 1 + E2EEAutoLog.signerMinAgeMs
        let settled = await publication(fake).rotate()
        XCTAssertEqual(settled, .present(hkPubB64: current))
        XCTAssertTrue(fake.posts.isEmpty, "rotation plus due : rien de publié")

        let rotating = Fake(reads: [.verified(due)])
        rotating.held = [current]
        rotating.nowMs = 1 + E2EEAutoLog.signerMinAgeMs
        rotating.responses = [echo()]
        let outcome = await publication(rotating).rotate()
        XCTAssertEqual(rotating.posts.first?["previousHkPubB64"] as? String, current, "comparaison-échange sur la HK détenue")
        XCTAssertEqual(outcome, rotating.created.first.map { .present(hkPubB64: $0) })
    }

    func testPendingDeviceAndRefusalsPublishNothingFurther() async {
        let pendingDevice = Fake(reads: [.verified(account(status: .pending))])
        let notActive = await publication(pendingDevice).run()
        XCTAssertEqual(notActive, .notActive)
        XCTAssertTrue(pendingDevice.posts.isEmpty)

        let limited = Fake(reads: [.verified(account())])
        limited.responses = [{ _ in Self.failure(429, "E2EE_HISTORY_KEY_RATE_LIMITED", retryAfter: 60) }]
        let rateLimited = await publication(limited).run()
        XCTAssertEqual(rateLimited, .retryLater(afterSeconds: 60))
        XCTAssertNotNil(limited.pending, "la HK tirée reste pour le prochain passage")

        let invalid = Fake(reads: [.verified(account())])
        invalid.responses = [{ _ in Self.failure(400, "E2EE_HISTORY_KEY_REQUEST_INVALID") }]
        let refused = await publication(invalid).run()
        XCTAssertEqual(refused, .failed("e2ee-auto-history-key-refused"))
        XCTAssertEqual(invalid.posts.count, 1, "un 400 n'est pas réessayé")

        let forged = Fake(reads: [.verified(account())])
        forged.responses = [echo(key: P256.Signing.PrivateKey())]
        let unsigned = await publication(forged).run()
        XCTAssertEqual(unsigned, .failed("invalid-e2ee-auto-history-key-response"))
        XCTAssertTrue(forged.puts.isEmpty)

        let refusedLog = Fake(reads: [.refused])
        let logRefused = await publication(refusedLog).run()
        XCTAssertEqual(logRefused, .logRefused)
    }

    func testFailedStatusReportIsRetriedNextTime() async {
        let hk = Self.newKey()
        let fake = Fake(reads: [.verified(account(hk: hk))])
        fake.held = [hk]
        fake.putResult = .failure(.init(kind: .retryable, statusCode: 503, message: "x"))
        _ = await publication(fake).run()
        XCTAssertNil(fake.reported)
        fake.putResult = .success(value: Data("{}".utf8), statusCode: 200, idempotentReplay: false)
        _ = await publication(fake).run()
        XCTAssertEqual(fake.puts.count, 2)
        XCTAssertEqual(fake.reported, "\(ownId):\(hk)")
    }
}
