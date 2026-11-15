import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot C4 (E2EE-AUTO §5.6) : après un `REVOKE`, preuve de possession, HK′ servie aux
/// seules preuves valides, maillon de chaîne, réception d'un transfert et remontée
/// de la chaîne ; tout se juge sur le journal vérifié, avec une vraie crypto.
final class E2EEAutoHistoryRotationTests: XCTestCase {
    private static let userId = "user_alice_00000000001"
    private static let salt = Data(repeating: 7, count: 16).base64EncodedString()
    private static let revokeSeq: Int64 = 40
    private static let rotationSeq: Int64 = 41
    private static let day = E2EEAutoLog.signerMinAgeMs

    private struct Device {
        let id: String
        let signing = P256.Signing.PrivateKey()
        let agreement = P256.KeyAgreement.PrivateKey()

        var descriptor: E2EEV2DeviceDescriptor {
            E2EEV2DeviceDescriptor(
                deviceId: id, platform: "ios", label: nil, publicIdentityKeyB64: agreement.publicKey.x963Representation.base64EncodedString(),
                publicSigningKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
                identityKeyAlgorithm: E2EEV2DeviceAlgorithms.identityKeyAlgorithm,
                signingKeyAlgorithm: E2EEV2DeviceAlgorithms.signingKeyAlgorithm, keyVersion: 1
            )
        }

        func state(_ status: E2EEAutoLog.DeviceStatus = .active, addedAtMs: Int64 = 5_000) -> E2EEAutoLog.DeviceState {
            let key = agreement.publicKey.x963Representation.base64EncodedString()
            return E2EEAutoLog.DeviceState(
                deviceId: id, platform: .ios, identityKeyB64: key,
                signingKeyB64: signing.publicKey.x963Representation.base64EncodedString(), keyVersion: 1, status: status,
                addedAtMs: addedAtMs, activatedAtMs: addedAtMs,
                addEntryHash: E2EEAutoLog.digest("add-\(id)"), identityKeys: [.init(keyVersion: 1, identityKeyB64: key, sinceMs: addedAtMs)],
                revokeReason: status == .revoked ? .user : nil, revokeSeq: status == .revoked ? revokeSeq : nil,
                revokedAtMs: status == .revoked ? 9_000 : nil
            )
        }
    }

    private let rotator = Device(id: "ios_device_rotator_00001")
    private let member = Device(id: "and_device_member_000001")
    private let other = Device(id: "web_device_other_0000001")
    private let lost = Device(id: "ios_device_lost_00000001")
    private let oldScalar = P256.Signing.PrivateKey().rawRepresentation
    private let newScalar = P256.Signing.PrivateKey().rawRepresentation
    private var oldHk: String { E2EEAutoHistoryKey.publicKeyB64(scalar: oldScalar)! }
    private var newHk: String { E2EEAutoHistoryKey.publicKeyB64(scalar: newScalar)! }
    private var rotationCreatedAtMs: Int64 { 5_000 + Self.day + 1 }

    private var firstRecord: E2EEAutoLog.HistoryKeyRecord {
        .init(seq: 10, entryHash: E2EEAutoLog.digest("hk-1"), hkPubB64: oldHk, previousHkPubB64: nil, signerDeviceId: rotator.id,
              signerAddedAtMs: 5_000, createdAtMs: 6_000, afterRevokeSeq: nil)
    }

    private var rotationRecord: E2EEAutoLog.HistoryKeyRecord {
        .init(seq: Self.rotationSeq, entryHash: E2EEAutoLog.digest("hk-2"), hkPubB64: newHk, previousHkPubB64: oldHk,
              signerDeviceId: rotator.id, signerAddedAtMs: 5_000, createdAtMs: rotationCreatedAtMs, afterRevokeSeq: Self.revokeSeq)
    }

    /// `rotated` : HK′ déjà au journal ; sinon le `REVOKE` attend sa rotation.
    private func account(rotated: Bool, rotatorAddedAtMs: Int64 = 5_000) -> E2EEAutoLog.AccountState {
        var account = E2EEAutoLog.AccountState(userId: Self.userId, accountSaltB64: Self.salt)
        account.devices[rotator.id] = rotator.state(addedAtMs: rotatorAddedAtMs)
        account.devices[member.id] = member.state()
        account.devices[other.id] = other.state()
        account.devices[lost.id] = lost.state(.revoked)
        if rotated {
            account.historyKeys = [firstRecord, rotationRecord]
            account.historyKeyPubB64 = newHk
            account.historyKeyEntryHash = rotationRecord.entryHash
        } else {
            account.historyKeys = [firstRecord]
            account.historyKeyPubB64 = oldHk
            account.historyKeyEntryHash = firstRecord.entryHash
            account.rotationDueRevokeSeq = Self.revokeSeq
        }
        account.lastEntryHash = E2EEAutoLog.digest("last")
        return account
    }

    private static func json(_ object: Any, status: Int = 201) -> E2EEV2TransportResult<Data> {
        .success(value: try! JSONSerialization.data(withJSONObject: object), statusCode: status, idempotentReplay: false)
    }

    private static func failure(_ status: Int, _ code: String) -> E2EEV2TransportResult<Data> {
        .failure(.init(
            kind: E2EEV2TransportFailurePolicy.classify(statusCode: status, code: code), statusCode: status, code: code, message: "x"
        ))
    }

    private final class Fake: @unchecked Sendable {
        var reads: [E2EEAutoEnrollment.OwnAccount]
        var readCount = 0
        /// Réponses par « MÉTHODE chemin », consommées dans l'ordre.
        var routes: [String: [E2EEV2TransportResult<Data>]] = [:]
        var held: [String: Data] = [:]
        var rotation: E2EEAutoHistoryKeyPublication.Outcome = .tooRecent
        var done: Set<String> = []
        private(set) var calls: [String] = []
        private(set) var bodies: [String: [[String: Any]]] = [:]
        private(set) var rotations = 0
        private(set) var declared = 0

        init(reads: [E2EEAutoEnrollment.OwnAccount]) { self.reads = reads }

        private func answer(_ key: String, body: Data?) -> E2EEV2TransportResult<Data> {
            calls.append(key)
            if let body { bodies[key, default: []].append((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]) }
            guard var queue = routes[key], !queue.isEmpty else { return .failure(.init(kind: .retryable, statusCode: 503, message: "x")) }
            let first = queue.removeFirst()
            routes[key] = queue
            return first
        }

        func dependencies(_ device: Device) -> E2EEAutoHistoryRotation.Dependencies {
            .init(
                userId: E2EEAutoHistoryRotationTests.userId,
                device: { device.descriptor },
                sign: { try E2EEV2LowS.sign($0, with: device.signing) },
                get: { [self] path in answer("GET \(path)", body: nil) },
                post: { [self] path, body, _ in answer("POST \(path)", body: body) },
                put: { [self] path, body, _ in answer("PUT \(path)", body: body) },
                readOwnAccount: { [self] in
                    defer { readCount += 1 }
                    return reads[min(readCount, reads.count - 1)]
                },
                scalar: { [self] in held[$0] },
                keep: { [self] scalar in
                    let key = E2EEAutoHistoryKey.publicKeyB64(scalar: scalar)!
                    held[key] = scalar
                    return key
                },
                heldKeyVersions: { [1] },
                openWrap: { wrap in try E2EEAutoHistory.open(wrap, userId: E2EEAutoHistoryRotationTests.userId, agreementKey: device.agreement) },
                rotate: { [self] in rotations += 1; return rotation },
                declarePresent: { [self] in declared += 1 },
                isDone: { [self] in done.contains($0) },
                recordDone: { [self] in done.insert($0) }
            )
        }
    }

    private var proofsPath: String {
        E2EEAutoHistoryRotationContract.proofsQueryPath(hkPubB64: oldHk, revokeSeq: Self.revokeSeq)!
    }

    private func proofRow(_ device: String, signedAs signer: String? = nil) -> [String: Any] {
        let signature = E2EEAutoHistoryKey.signProof(
            userId: Self.userId, deviceId: signer ?? device, hkPubB64: oldHk, revokeSeq: Self.revokeSeq, scalar: oldScalar
        )!
        return ["deviceId": device, "hkPubB64": oldHk, "revokeSeq": String(Self.revokeSeq), "signatureB64": signature, "createdAtMs": "9100"]
    }

    /// Maillon `chain/{oldHk}` vers HK′, signé par `sender`.
    private func chainLink(from sender: Device) throws -> E2EEAutoHistory.Wrap {
        try E2EEAutoHistory.seal(
            scalar: oldScalar, userId: Self.userId, senderDeviceId: sender.id, recipient: E2EEAutoHistory.historyRecipientPrefix + newHk,
            keyVersion: 1, requestId: E2EEAutoHistory.chainRequest, addHash: rotationRecord.entryHash,
            recipientAgreementKey: P256.KeyAgreement.PrivateKey(rawRepresentation: newScalar).publicKey,
            sign: { try E2EEV2LowS.sign($0, with: sender.signing) }
        )
    }

    private func proofs(_ rows: [[String: Any]]) throws -> [E2EEAutoHistoryRotationContract.Proof] {
        try XCTUnwrap(E2EEAutoHistoryRotationContract.parseProofs(
            JSONSerialization.data(withJSONObject: ["proofs": rows]), hkPubB64: oldHk, revokeSeq: Self.revokeSeq
        ))
    }

    // MARK: Preuve et publication

    /// À la vue du REVOKE : une preuve signée par l'ancienne HK, puis la publication de HK′.
    func testRevokeDepositsAProofOnceAndRotates() async throws {
        let fake = Fake(reads: [.verified(account(rotated: false))])
        fake.held[oldHk] = oldScalar
        fake.routes["POST \(E2EEAutoHistoryRotationContract.proofsPath)"] = [Self.json([
            "deviceId": member.id, "hkPubB64": oldHk, "revokeSeq": "40", "createdAtMs": "9100",
        ])]
        let rotation = E2EEAutoHistoryRotation(fake.dependencies(member))
        let report = await rotation.run()
        XCTAssertTrue(report.proofDeposited)
        XCTAssertEqual(fake.rotations, 1)
        let body = try XCTUnwrap(fake.bodies["POST \(E2EEAutoHistoryRotationContract.proofsPath)"]?.first)
        XCTAssertEqual(Set(body.keys), ["hkPubB64", "revokeSeq", "signatureB64"])
        XCTAssertEqual(body["revokeSeq"] as? String, "40")
        XCTAssertTrue(E2EEAutoHistoryKey.verifyProof(
            userId: Self.userId, deviceId: member.id, hkPubB64: oldHk, revokeSeq: Self.revokeSeq,
            signatureB64: try XCTUnwrap(body["signatureB64"] as? String)
        ))

        let again = await rotation.run()
        XCTAssertFalse(again.proofDeposited)
        XCTAssertEqual(fake.bodies["POST \(E2EEAutoHistoryRotationContract.proofsPath)"]?.count, 1)
    }

    /// Sans l'ancienne HK, rien ne se prouve et rien ne se publie.
    func testWithoutTheOldKeyNothingIsProvenOrRotated() async {
        let fake = Fake(reads: [.verified(account(rotated: false))])
        let report = await E2EEAutoHistoryRotation(fake.dependencies(member)).run()
        XCTAssertFalse(report.proofDeposited)
        XCTAssertEqual(fake.rotations, 0)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    // MARK: Service des preuves

    /// HK′ part seulement aux appareils actifs dont la preuve se vérifie ; le
    /// destinataire l'accepte et l'ouvre.
    func testRotatorServesOnlyValidProofs() async throws {
        let account = account(rotated: true)
        let fake = Fake(reads: [.verified(account)])
        fake.held[oldHk] = oldScalar
        fake.held[newHk] = newScalar
        fake.routes["GET \(proofsPath)"] = [Self.json(["proofs": [
            proofRow(member.id), proofRow(other.id, signedAs: member.id), proofRow(lost.id), proofRow(rotator.id),
        ]], status: 200)]
        fake.routes["POST \(E2EEAutoHistoryRotationContract.transfersPath)"] = [Self.json([
            "recipientDeviceId": member.id, "requestId": "rotation-41",
        ])]
        let report = await E2EEAutoHistoryRotation(fake.dependencies(rotator)).run()
        XCTAssertEqual(report.served, [member.id])

        let sent = try XCTUnwrap(fake.bodies["POST \(E2EEAutoHistoryRotationContract.transfersPath)"])
        XCTAssertEqual(sent.count, 1)
        let wrap = try XCTUnwrap(E2EEAutoHistory.parseWrap(sent[0]))
        XCTAssertEqual(wrap.recipient, member.id)
        XCTAssertEqual(wrap.requestId, "rotation-41")
        let reader = E2EEAutoHistory.Reader.device(deviceId: member.id, keyVersions: [1], openRequestIds: [], heldHkPubB64: oldHk)
        XCTAssertNil(E2EEAutoHistory.check(userId: Self.userId, wrap: wrap, account: account, reader: reader))
        XCTAssertEqual(try E2EEAutoHistory.open(wrap, userId: Self.userId, agreementKey: member.agreement), newScalar)
    }

    /// `409 E2EE_HISTORY_TRANSFER_EXISTS` vaut un transfert fait : pas de nouvel essai.
    func testExistingTransferCountsAsServed() async {
        let fake = Fake(reads: [.verified(account(rotated: true))])
        fake.held[newHk] = newScalar
        fake.routes["GET \(proofsPath)"] = [Self.json(["proofs": [proofRow(member.id)]], status: 200)]
        fake.routes["POST \(E2EEAutoHistoryRotationContract.transfersPath)"] = [Self.failure(409, "E2EE_HISTORY_TRANSFER_EXISTS")]
        let rotation = E2EEAutoHistoryRotation(fake.dependencies(rotator))
        let first = await rotation.run()
        XCTAssertEqual(first.served, [member.id])
        fake.routes["GET \(proofsPath)"] = [Self.json(["proofs": [proofRow(member.id)]], status: 200)]
        let second = await rotation.run()
        XCTAssertEqual(second.served, [])
        XCTAssertEqual(fake.bodies["POST \(E2EEAutoHistoryRotationContract.transfersPath)"]?.count, 1)
    }

    // MARK: Chaîne

    /// Détenteur des deux HK et éligible : l'ancienne part vers HK′ ; un lecteur qui
    /// n'a que HK′ l'accepte et l'ouvre.
    func testEligibleHolderDepositsTheChainLink() async throws {
        let account = account(rotated: true)
        let fake = Fake(reads: [.verified(account)])
        fake.held[oldHk] = oldScalar
        fake.held[newHk] = newScalar
        let chainPath = try XCTUnwrap(E2EEAutoHistoryRotationContract.chainPath(oldHk))
        fake.routes["PUT \(chainPath)"] = [Self.json(["hkPubB64": oldHk, "nextHkPubB64": newHk])]
        let report = await E2EEAutoHistoryRotation(fake.dependencies(rotator)).run()
        XCTAssertTrue(report.chainDeposited)
        // La preuve de l'émetteur suit `afterRevokeSeq` de HK′, déposée avant le maillon (r23).
        let proof = try XCTUnwrap(fake.bodies["POST \(E2EEAutoHistoryRotationContract.proofsPath)"]?.first)
        XCTAssertEqual(proof["hkPubB64"] as? String, oldHk)
        XCTAssertEqual(proof["revokeSeq"] as? String, "40")
        XCTAssertLessThan(
            try XCTUnwrap(fake.calls.firstIndex(of: "POST \(E2EEAutoHistoryRotationContract.proofsPath)")),
            try XCTUnwrap(fake.calls.firstIndex(of: "PUT \(chainPath)"))
        )

        let link = try XCTUnwrap(E2EEAutoHistory.parseWrap(try XCTUnwrap(fake.bodies["PUT \(chainPath)"]?.first)))
        XCTAssertEqual(link.recipient, E2EEAutoHistory.historyRecipientPrefix + newHk)
        XCTAssertEqual(link.requestId, E2EEAutoHistory.chainRequest)
        XCTAssertEqual(link.keyVersion, 1)
        XCTAssertNil(E2EEAutoHistory.check(userId: Self.userId, wrap: link, account: account, reader: .history(hkPubB64: newHk)))
        let agreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: newScalar)
        XCTAssertEqual(try E2EEAutoHistory.open(link, userId: Self.userId, agreementKey: agreement), oldScalar)
    }

    /// Inscrit depuis moins de 24 h à l'entrée de HK′ : aucun maillon déposé.
    func testRecentDeviceDepositsNoChainLink() async throws {
        let fake = Fake(reads: [.verified(account(rotated: true, rotatorAddedAtMs: rotationCreatedAtMs - 1_000))])
        fake.held[oldHk] = oldScalar
        fake.held[newHk] = newScalar
        let report = await E2EEAutoHistoryRotation(fake.dependencies(rotator)).run()
        XCTAssertFalse(report.chainDeposited)
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("PUT") })
    }

    /// Un appareil qui n'a que HK′ remonte la chaîne vers l'ancienne HK.
    func testHolderOfTheNewKeyFollowsTheChain() async throws {
        let account = account(rotated: true)
        let chainPath = try XCTUnwrap(E2EEAutoHistoryRotationContract.chainPath(oldHk))
        let link = try E2EEAutoHistory.seal(
            scalar: oldScalar, userId: Self.userId, senderDeviceId: rotator.id, recipient: E2EEAutoHistory.historyRecipientPrefix + newHk,
            keyVersion: 1, requestId: E2EEAutoHistory.chainRequest, addHash: rotationRecord.entryHash,
            recipientAgreementKey: P256.KeyAgreement.PrivateKey(rawRepresentation: newScalar).publicKey,
            sign: { try E2EEV2LowS.sign($0, with: self.rotator.signing) }
        )
        let forged = try E2EEAutoHistory.seal(
            scalar: P256.Signing.PrivateKey().rawRepresentation, userId: Self.userId, senderDeviceId: lost.id,
            recipient: E2EEAutoHistory.historyRecipientPrefix + newHk, keyVersion: 1, requestId: E2EEAutoHistory.chainRequest,
            addHash: rotationRecord.entryHash, recipientAgreementKey: P256.KeyAgreement.PrivateKey(rawRepresentation: newScalar).publicKey,
            sign: { try E2EEV2LowS.sign($0, with: self.lost.signing) }
        )
        let fake = Fake(reads: [.verified(account)])
        fake.held[newHk] = newScalar
        fake.routes["GET \(chainPath)"] = [Self.json(["links": [forged.jsonObject, link.jsonObject]], status: 200)]
        fake.routes["GET \(proofsPath)"] = [Self.json(["proofs": []], status: 200)]
        let report = await E2EEAutoHistoryRotation(fake.dependencies(member)).run()
        XCTAssertEqual(report.chained, 1)
        XCTAssertEqual(fake.held[oldHk], oldScalar)
    }

    // MARK: Réception

    /// Le destinataire garde HK′ d'un transfert valide, ignore un transfert d'un appareil
    /// révoqué, puis déclare `present`.
    func testMemberReceivesTheTransferAndIgnoresAForgedOne() async throws {
        let account = account(rotated: true)
        let forged = try E2EEAutoHistory.seal(
            scalar: newScalar, userId: Self.userId, senderDeviceId: lost.id, recipient: member.id, keyVersion: 1,
            requestId: "rotation-41", addHash: account.devices[member.id]!.addEntryHash,
            recipientAgreementKey: member.agreement.publicKey, sign: { try E2EEV2LowS.sign($0, with: self.lost.signing) }
        )
        let valid = try E2EEAutoHistory.seal(
            scalar: newScalar, userId: Self.userId, senderDeviceId: rotator.id, recipient: member.id, keyVersion: 1,
            requestId: "rotation-41", addHash: account.devices[member.id]!.addEntryHash,
            recipientAgreementKey: member.agreement.publicKey, sign: { try E2EEV2LowS.sign($0, with: self.rotator.signing) }
        )
        let fake = Fake(reads: [.verified(account)])
        fake.held[oldHk] = oldScalar
        fake.routes["GET \(E2EEAutoHistoryRotationContract.transfersPath)"] = [
            Self.json(["transfers": [forged.jsonObject, valid.jsonObject]], status: 200),
        ]
        let chainPath = try XCTUnwrap(E2EEAutoHistoryRotationContract.chainPath(oldHk))
        fake.routes["GET \(chainPath)"] = [Self.json(["links": [try chainLink(from: rotator).jsonObject]], status: 200)]
        fake.routes["GET \(proofsPath)"] = [
            Self.json(["proofs": [proofRow(rotator.id)]], status: 200), Self.json(["proofs": []], status: 200),
        ]
        let report = await E2EEAutoHistoryRotation(fake.dependencies(member)).run()
        XCTAssertTrue(report.received)
        XCTAssertEqual(fake.declared, 1)
        XCTAssertEqual(fake.held[newHk], newScalar)
    }

    /// Un transfert valide n'est pas rangé sans maillon à preuve : son émetteur peut ne
    /// jamais avoir détenu l'ancienne HK (révision 23, T1).
    func testTransferWithoutAProvenLinkIsNotKept() async throws {
        let account = account(rotated: true)
        let valid = try E2EEAutoHistory.seal(
            scalar: newScalar, userId: Self.userId, senderDeviceId: rotator.id, recipient: member.id, keyVersion: 1,
            requestId: "rotation-41", addHash: account.devices[member.id]!.addEntryHash,
            recipientAgreementKey: member.agreement.publicKey, sign: { try E2EEV2LowS.sign($0, with: self.rotator.signing) }
        )
        let chainPath = try XCTUnwrap(E2EEAutoHistoryRotationContract.chainPath(oldHk))
        let fake = Fake(reads: [.verified(account)])
        fake.held[oldHk] = oldScalar
        fake.routes["GET \(E2EEAutoHistoryRotationContract.transfersPath)"] = [Self.json(["transfers": [valid.jsonObject]], status: 200)]
        // Le maillon de l'émetteur existe, mais il n'a déposé aucune preuve de l'ancienne HK.
        fake.routes["GET \(chainPath)"] = [Self.json(["links": [try chainLink(from: rotator).jsonObject]], status: 200)]
        fake.routes["GET \(proofsPath)"] = [Self.json(["proofs": [proofRow(member.id)]], status: 200)]
        let report = await E2EEAutoHistoryRotation(fake.dependencies(member)).run()
        XCTAssertFalse(report.received)
        XCTAssertNil(fake.held[newHk])
        XCTAssertEqual(fake.declared, 0)
        XCTAssertFalse(fake.done.contains(E2EEAutoHistoryRotation.vouchedMarker(newHk)))
    }

    /// Une HK′ d'un autre détenue ici sans maillon à preuve (reçue par une build sans la
    /// porte) ne reçoit ni notre preuve ni notre maillon : il la rendrait vérifiée.
    func testUnprovenKeyHeldHereGetsNoChainLinkFromHere() async {
        let fake = Fake(reads: [.verified(account(rotated: true))])
        fake.held[oldHk] = oldScalar
        fake.held[newHk] = newScalar
        let report = await E2EEAutoHistoryRotation(fake.dependencies(member)).run()
        XCTAssertFalse(report.chainDeposited)
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("PUT") || $0.hasPrefix("POST") })
    }

    /// Une HK′ d'un autre détenue ici : le maillon prouvé d'un appareil qui n'en est pas
    /// l'auteur ne la vérifie pas, et n'appelle donc ni notre preuve ni notre maillon ; celui
    /// de l'auteur, oui (« Auteur d'abord », décision 16).
    func testHolderLinksOnlyAfterTheAuthorsProvenLink() async throws {
        let chainPath = try XCTUnwrap(E2EEAutoHistoryRotationContract.chainPath(oldHk))
        let proofsPost = "POST \(E2EEAutoHistoryRotationContract.proofsPath)"

        let refused = Fake(reads: [.verified(account(rotated: true))])
        refused.held[oldHk] = oldScalar
        refused.held[newHk] = newScalar
        refused.routes["GET \(chainPath)"] = [Self.json(["links": [try chainLink(from: other).jsonObject]], status: 200)]
        refused.routes["GET \(proofsPath)"] = [Self.json(["proofs": [proofRow(other.id)]], status: 200)]
        let refusedReport = await E2EEAutoHistoryRotation(refused.dependencies(member)).run()
        XCTAssertFalse(refusedReport.chainDeposited)
        XCTAssertFalse(refused.calls.contains("PUT \(chainPath)"))
        XCTAssertFalse(refused.calls.contains(proofsPost))
        XCTAssertFalse(refused.done.contains(E2EEAutoHistoryRotation.vouchedMarker(newHk)))

        let accepted = Fake(reads: [.verified(account(rotated: true))])
        accepted.held[oldHk] = oldScalar
        accepted.held[newHk] = newScalar
        accepted.routes["GET \(chainPath)"] = [
            Self.json(["links": [try chainLink(from: other).jsonObject, try chainLink(from: rotator).jsonObject]], status: 200),
        ]
        accepted.routes["GET \(proofsPath)"] = [Self.json(["proofs": [proofRow(other.id), proofRow(rotator.id)]], status: 200)]
        accepted.routes["PUT \(chainPath)"] = [Self.json(["hkPubB64": oldHk, "nextHkPubB64": newHk])]
        let acceptedReport = await E2EEAutoHistoryRotation(accepted.dependencies(member)).run()
        XCTAssertTrue(acceptedReport.chainDeposited)
        XCTAssertTrue(accepted.calls.contains(proofsPost))
        XCTAssertTrue(accepted.done.contains(E2EEAutoHistoryRotation.vouchedMarker(newHk)))
    }

    /// Le maillon compte seulement si son propre émetteur a prouvé détenir l'ancienne HK
    /// pour `afterRevokeSeq` de HK′, s'il passe les contrôles publics du §5.6, et si cet
    /// émetteur est l'auteur de HK′ (« Auteur d'abord », décision 16, §5.6 bis).
    func testProvenLinkNeedsItsOwnSendersProof() throws {
        let account = account(rotated: true)
        func vouched(_ links: [E2EEAutoHistory.Wrap], _ rows: [[String: Any]]) throws -> Bool {
            E2EEAutoHistoryRotationContract.isVouched(
                userId: Self.userId, account: account, rotation: rotationRecord, links: links, proofs: try proofs(rows)
            )
        }
        let link = try chainLink(from: rotator)
        XCTAssertTrue(try vouched([link], [proofRow(rotator.id)]))
        XCTAssertFalse(try vouched([link], [proofRow(member.id)]), "preuve d'un autre appareil que l'émetteur")
        XCTAssertFalse(try vouched([link], [proofRow(rotator.id, signedAs: member.id)]), "preuve rejouée sous l'émetteur")
        XCTAssertFalse(try vouched([try chainLink(from: lost)], [proofRow(lost.id)]), "émetteur révoqué avant HK′")
        XCTAssertFalse(try vouched([], [proofRow(rotator.id)]))
        let otherLink = try chainLink(from: member)
        XCTAssertFalse(try vouched([otherLink], [proofRow(member.id)]), "maillon prouvé d'un appareil qui n'est pas l'auteur")
        XCTAssertFalse(try vouched([otherLink, link], [proofRow(member.id)]), "maillon de l'auteur sans sa propre preuve")
        XCTAssertFalse(try vouched([otherLink], [proofRow(member.id), proofRow(rotator.id)]), "preuve de l'auteur sans son maillon")
        XCTAssertTrue(try vouched([otherLink, link], [proofRow(member.id), proofRow(rotator.id)]))
    }

    /// Un transfert seul d'un appareil révoqué ne donne rien.
    func testForgedTransferAloneIsRefused() async throws {
        let account = account(rotated: true)
        let forged = try E2EEAutoHistory.seal(
            scalar: newScalar, userId: Self.userId, senderDeviceId: lost.id, recipient: member.id, keyVersion: 1,
            requestId: "rotation-41", addHash: account.devices[member.id]!.addEntryHash,
            recipientAgreementKey: member.agreement.publicKey, sign: { try E2EEV2LowS.sign($0, with: self.lost.signing) }
        )
        let fake = Fake(reads: [.verified(account)])
        fake.held[oldHk] = oldScalar
        fake.routes["GET \(E2EEAutoHistoryRotationContract.transfersPath)"] = [Self.json(["transfers": [forged.jsonObject]], status: 200)]
        let report = await E2EEAutoHistoryRotation(fake.dependencies(member)).run()
        XCTAssertFalse(report.received)
        XCTAssertNil(fake.held[newHk])
        XCTAssertEqual(fake.declared, 0)
    }

    // MARK: HK annulée, rotation depuis la base (révision 23, §5.6 bis)

    private let intruder = Device(id: "web_device_intruder_0001")
    private let cancelledScalar = P256.Signing.PrivateKey().rawRepresentation
    private var cancelledHk: String { E2EEAutoHistoryKey.publicKeyB64(scalar: cancelledScalar)! }

    /// HK_r publiée par `intruder` par-dessus HK0, hors rotation.
    private var cancelledRecord: E2EEAutoLog.HistoryKeyRecord {
        .init(seq: 30, entryHash: E2EEAutoLog.digest("hk-r"), hkPubB64: cancelledHk, previousHkPubB64: oldHk,
              signerDeviceId: intruder.id, signerAddedAtMs: 5_000, createdAtMs: 7_000, afterRevokeSeq: nil)
    }

    /// HK″ tournée depuis la base : `previousHkPubB64` reste HK_r, la littérale (même entrée que `rotationRecord`).
    private var baseRotationRecord: E2EEAutoLog.HistoryKeyRecord {
        .init(seq: Self.rotationSeq, entryHash: rotationRecord.entryHash, hkPubB64: newHk, previousHkPubB64: cancelledHk,
              signerDeviceId: rotator.id, signerAddedAtMs: 5_000, createdAtMs: rotationCreatedAtMs, afterRevokeSeq: Self.revokeSeq)
    }

    /// HK0, HK_r, puis le REVOKE `NOT_ME` de son signataire (seq 40) : HK_r est annulée, la
    /// base est HK0. `rotated` : HK″ est au journal ; sinon la rotation est due.
    private func cancelledAccount(rotated: Bool) -> E2EEAutoLog.AccountState {
        var account = account(rotated: false)
        account.devices[lost.id] = nil
        var revoked = intruder.state()
        revoked.status = .revoked
        revoked.revokeReason = .notMe
        revoked.revokeSeq = Self.revokeSeq
        revoked.revokedAtMs = 9_000
        account.devices[intruder.id] = revoked
        if rotated {
            account.historyKeys = [firstRecord, cancelledRecord, baseRotationRecord]
            account.historyKeyPubB64 = newHk
            account.historyKeyEntryHash = baseRotationRecord.entryHash
            account.rotationDueRevokeSeq = nil
        } else {
            account.historyKeys = [firstRecord, cancelledRecord]
            account.historyKeyPubB64 = cancelledHk
            account.historyKeyEntryHash = cancelledRecord.entryHash
        }
        return account
    }

    func testCancelledKeyAndItsBaseAreDerivedFromTheLog() {
        let bases = cancelledAccount(rotated: true).historyKeyBases
        XCTAssertEqual(bases.map(\.cancelSeq), [nil, Self.revokeSeq, nil])
        XCTAssertEqual(bases.map(\.admissibleHkPubB64), [nil, oldHk, oldHk])
        XCTAssertEqual(bases[2].previousHkPubB64, cancelledHk, "la littérale reste HK_r")
        XCTAssertEqual(cancelledAccount(rotated: false).rotationBaseHkPubB64, oldHk)
        // Révoqué en USER, le signataire n'annule rien : la base est HK_r elle-même.
        var user = cancelledAccount(rotated: false)
        user.devices[intruder.id]?.revokeReason = .user
        XCTAssertEqual(user.rotationBaseHkPubB64, cancelledHk)
        XCTAssertEqual(user.historyKeyBases.map(\.cancelled), [false, false])
    }

    /// La dernière HK est annulée : le détenteur de la base prouve la base et publie HK″ ;
    /// celui qui ne détient que HK_r ne prouve rien et ne publie rien.
    func testCancelledLastKeyRotatesFromTheBase() async throws {
        let fake = Fake(reads: [.verified(cancelledAccount(rotated: false))])
        fake.held[oldHk] = oldScalar
        fake.held[cancelledHk] = cancelledScalar
        fake.routes["POST \(E2EEAutoHistoryRotationContract.proofsPath)"] = [Self.json([
            "deviceId": member.id, "hkPubB64": oldHk, "revokeSeq": "40", "createdAtMs": "9100",
        ])]
        let report = await E2EEAutoHistoryRotation(fake.dependencies(member)).run()
        XCTAssertTrue(report.proofDeposited)
        XCTAssertEqual(fake.rotations, 1)
        let body = try XCTUnwrap(fake.bodies["POST \(E2EEAutoHistoryRotationContract.proofsPath)"]?.first)
        XCTAssertEqual(body["hkPubB64"] as? String, oldHk, "jamais la HK annulée")
        XCTAssertTrue(E2EEAutoHistoryKey.verifyProof(
            userId: Self.userId, deviceId: member.id, hkPubB64: oldHk, revokeSeq: Self.revokeSeq,
            signatureB64: try XCTUnwrap(body["signatureB64"] as? String)
        ))

        let cancelledOnly = Fake(reads: [.verified(cancelledAccount(rotated: false))])
        cancelledOnly.held[cancelledHk] = cancelledScalar
        let idle = await E2EEAutoHistoryRotation(cancelledOnly.dependencies(member)).run()
        XCTAssertFalse(idle.proofDeposited)
        XCTAssertEqual(cancelledOnly.rotations, 0)
        XCTAssertTrue(cancelledOnly.calls.isEmpty)
    }

    /// HK″ tournée depuis la base : preuve et maillon sur la base, jamais `chain/{HK_r}` ;
    /// HK″ servie aux preuves de la base, qu'un détenteur de la base seule accepte.
    func testRotationFromTheBaseLinksAndServesOnTheBase() async throws {
        let account = cancelledAccount(rotated: true)
        let fake = Fake(reads: [.verified(account)])
        fake.held[oldHk] = oldScalar
        fake.held[cancelledHk] = cancelledScalar
        fake.held[newHk] = newScalar
        let chainPath = try XCTUnwrap(E2EEAutoHistoryRotationContract.chainPath(oldHk))
        fake.routes["PUT \(chainPath)"] = [Self.json(["hkPubB64": oldHk, "nextHkPubB64": newHk])]
        fake.routes["GET \(proofsPath)"] = [Self.json(["proofs": [proofRow(member.id)]], status: 200)]
        fake.routes["POST \(E2EEAutoHistoryRotationContract.transfersPath)"] = [Self.json([
            "recipientDeviceId": member.id, "requestId": "rotation-41",
        ])]
        let report = await E2EEAutoHistoryRotation(fake.dependencies(rotator)).run()
        XCTAssertTrue(report.chainDeposited)
        XCTAssertEqual(report.served, [member.id])
        XCTAssertFalse(fake.calls.contains("PUT \(try XCTUnwrap(E2EEAutoHistoryRotationContract.chainPath(cancelledHk)))"))
        let proof = try XCTUnwrap(fake.bodies["POST \(E2EEAutoHistoryRotationContract.proofsPath)"]?.first)
        XCTAssertEqual(proof["hkPubB64"] as? String, oldHk)
        let link = try XCTUnwrap(E2EEAutoHistory.parseWrap(try XCTUnwrap(fake.bodies["PUT \(chainPath)"]?.first)))
        XCTAssertEqual(link.hkPubB64, oldHk)
        XCTAssertNil(E2EEAutoHistory.check(userId: Self.userId, wrap: link, account: account, reader: .history(hkPubB64: newHk)))

        let transfer = try XCTUnwrap(E2EEAutoHistory.parseWrap(try XCTUnwrap(fake.bodies["POST \(E2EEAutoHistoryRotationContract.transfersPath)"]?.first)))
        func claim(_ held: String) -> E2EEAutoHistory.CheckError? {
            E2EEAutoHistory.check(userId: Self.userId, wrap: transfer, account: account, reader: .device(
                deviceId: member.id, keyVersions: [1], openRequestIds: [], heldHkPubB64: held
            ))
        }
        XCTAssertNil(claim(oldHk), "le claim porte sur la base")
        XCTAssertEqual(claim(cancelledHk), .rotation, "détenir HK_r ne suffit pas")
    }

    /// Le détenteur de la base seule reçoit HK″ sur le maillon à preuve de l'auteur, posé sur la base.
    func testHolderOfTheBaseReceivesTheRotationFromTheBase() async throws {
        let account = cancelledAccount(rotated: true)
        let valid = try E2EEAutoHistory.seal(
            scalar: newScalar, userId: Self.userId, senderDeviceId: rotator.id, recipient: member.id, keyVersion: 1,
            requestId: "rotation-41", addHash: account.devices[member.id]!.addEntryHash,
            recipientAgreementKey: member.agreement.publicKey, sign: { try E2EEV2LowS.sign($0, with: self.rotator.signing) }
        )
        let fake = Fake(reads: [.verified(account)])
        fake.held[oldHk] = oldScalar
        fake.routes["GET \(E2EEAutoHistoryRotationContract.transfersPath)"] = [Self.json(["transfers": [valid.jsonObject]], status: 200)]
        let chainPath = try XCTUnwrap(E2EEAutoHistoryRotationContract.chainPath(oldHk))
        fake.routes["GET \(chainPath)"] = [Self.json(["links": [try chainLink(from: rotator).jsonObject]], status: 200)]
        fake.routes["GET \(proofsPath)"] = [Self.json(["proofs": [proofRow(rotator.id)]], status: 200)]
        let report = await E2EEAutoHistoryRotation(fake.dependencies(member)).run()
        XCTAssertTrue(report.received)
        XCTAssertEqual(fake.held[newHk], newScalar)
        XCTAssertFalse(fake.calls.contains { $0.contains(E2EEAutoHistoryRotationContract.pathParam(cancelledHk)!) })
    }

    /// R1 : un maillon vers une HK annulée ne compte jamais, ni un maillon posé sur elle ;
    /// une HK annulée en forme de rotation n'a jamais de maillon à preuve, même de son auteur.
    func testLinksToOrFromACancelledKeyNeverCount() throws {
        var account = cancelledAccount(rotated: true)
        let cancelledAgreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: cancelledScalar).publicKey
        let toCancelled = try E2EEAutoHistory.seal(
            scalar: oldScalar, userId: Self.userId, senderDeviceId: rotator.id, recipient: E2EEAutoHistory.historyRecipientPrefix + cancelledHk,
            keyVersion: 1, requestId: E2EEAutoHistory.chainRequest, addHash: cancelledRecord.entryHash,
            recipientAgreementKey: cancelledAgreement, sign: { try E2EEV2LowS.sign($0, with: self.rotator.signing) }
        )
        XCTAssertEqual(E2EEAutoHistory.check(userId: Self.userId, wrap: toCancelled, account: account, reader: .history(hkPubB64: cancelledHk)), .chain)
        let fromCancelled = try E2EEAutoHistory.seal(
            scalar: cancelledScalar, userId: Self.userId, senderDeviceId: rotator.id, recipient: E2EEAutoHistory.historyRecipientPrefix + newHk,
            keyVersion: 1, requestId: E2EEAutoHistory.chainRequest, addHash: baseRotationRecord.entryHash,
            recipientAgreementKey: P256.KeyAgreement.PrivateKey(rawRepresentation: newScalar).publicKey,
            sign: { try E2EEV2LowS.sign($0, with: self.rotator.signing) }
        )
        XCTAssertEqual(E2EEAutoHistory.check(userId: Self.userId, wrap: fromCancelled, account: account, reader: .history(hkPubB64: newHk)), .chain)

        // HK_r en forme de rotation, son auteur avec maillon et preuve sur HK0 : annulée, elle ne compte pas.
        let shaped = E2EEAutoLog.HistoryKeyRecord(
            seq: 30, entryHash: cancelledRecord.entryHash, hkPubB64: cancelledHk, previousHkPubB64: oldHk, signerDeviceId: rotator.id,
            signerAddedAtMs: 5_000, createdAtMs: rotationCreatedAtMs, afterRevokeSeq: 20
        )
        account.historyKeys = [firstRecord, shaped]
        account.devices[rotator.id]?.status = .revoked
        account.devices[rotator.id]?.revokeReason = .notMe
        account.devices[rotator.id]?.revokeSeq = Self.revokeSeq
        let proof = E2EEAutoHistoryKey.signProof(userId: Self.userId, deviceId: rotator.id, hkPubB64: oldHk, revokeSeq: 20, scalar: oldScalar)!
        XCTAssertEqual(E2EEAutoHistoryRotationContract.provenSenders(
            userId: Self.userId, account: account, rotation: shaped, links: [toCancelled],
            proofs: [.init(deviceId: rotator.id, signatureB64: proof)]
        ), [])
    }

    /// Une HK′ annulée ne se chaîne ni ne se sert, même détenue avec la base.
    func testCancelledLastKeyIsNeitherLinkedNorServed() async {
        var account = cancelledAccount(rotated: false)
        account.historyKeys[1] = .init(
            seq: 30, entryHash: cancelledRecord.entryHash, hkPubB64: cancelledHk, previousHkPubB64: oldHk, signerDeviceId: intruder.id,
            signerAddedAtMs: 5_000, createdAtMs: 7_000, afterRevokeSeq: 20
        )
        let fake = Fake(reads: [.verified(account)])
        fake.held[oldHk] = oldScalar
        fake.held[cancelledHk] = cancelledScalar
        fake.routes["POST \(E2EEAutoHistoryRotationContract.proofsPath)"] = [Self.json([
            "deviceId": member.id, "hkPubB64": oldHk, "revokeSeq": "40", "createdAtMs": "9100",
        ])]
        let report = await E2EEAutoHistoryRotation(fake.dependencies(member)).run()
        XCTAssertFalse(report.chainDeposited)
        XCTAssertEqual(report.served, [])
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("PUT") || $0.hasPrefix("GET") })
    }

    // MARK: Contrat

    func testStrictParsers() throws {
        let other = E2EEAutoHistoryKey.publicKeyB64(scalar: P256.Signing.PrivateKey().rawRepresentation)!
        let good = try JSONSerialization.data(withJSONObject: ["proofs": [proofRow(member.id)]])
        XCTAssertEqual(E2EEAutoHistoryRotationContract.parseProofs(good, hkPubB64: oldHk, revokeSeq: Self.revokeSeq)?.count, 1)
        var foreign = proofRow(member.id)
        foreign["hkPubB64"] = other
        let mixed = try JSONSerialization.data(withJSONObject: ["proofs": [proofRow(member.id), foreign]])
        XCTAssertNil(E2EEAutoHistoryRotationContract.parseProofs(mixed, hkPubB64: oldHk, revokeSeq: Self.revokeSeq))
        var numeric = proofRow(member.id)
        numeric["revokeSeq"] = 40
        let typed = try JSONSerialization.data(withJSONObject: ["proofs": [numeric]])
        XCTAssertNil(E2EEAutoHistoryRotationContract.parseProofs(typed, hkPubB64: oldHk, revokeSeq: Self.revokeSeq))
        let extra = try JSONSerialization.data(withJSONObject: ["links": [], "next": NSNull()])
        XCTAssertNil(E2EEAutoHistoryRotationContract.parseWraps(extra, key: "links"))
        XCTAssertNil(E2EEAutoHistoryRotationContract.proofsQueryPath(hkPubB64: oldHk, revokeSeq: 0))
        let param = try XCTUnwrap(E2EEAutoHistoryRotationContract.pathParam(oldHk))
        XCTAssertEqual(param.count, 87)
        XCTAssertFalse(param.contains("=") || param.contains("+") || param.contains("/"))
    }
}
