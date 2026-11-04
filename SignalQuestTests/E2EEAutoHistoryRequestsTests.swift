import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot C3 (E2EE-AUTO §5.3) : un nouvel appareil sans HK la demande, un appareil
/// actif qui la détient l'enveloppe vers lui ; tout se juge sur le journal vérifié.
final class E2EEAutoHistoryRequestsTests: XCTestCase {
    private static let userId = "user_alice_00000000001"
    private static let salt = Data(repeating: 7, count: 16).base64EncodedString()
    private static let requestId = "hreq_000000000000000001"

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

        func state(_ status: E2EEAutoLog.DeviceStatus = .active, platform: E2EEAutoLog.Platform = .ios, addedAtMs: Int64 = 5_000) -> E2EEAutoLog.DeviceState {
            let key = agreement.publicKey.x963Representation.base64EncodedString()
            return E2EEAutoLog.DeviceState(
                deviceId: id, platform: platform, identityKeyB64: key,
                signingKeyB64: signing.publicKey.x963Representation.base64EncodedString(), keyVersion: 1, status: status,
                addedAtMs: addedAtMs, activatedAtMs: status == .pending ? nil : addedAtMs,
                addEntryHash: E2EEAutoLog.digest("add-\(id)"), identityKeys: [.init(keyVersion: 1, identityKeyB64: key, sinceMs: addedAtMs)],
                revokeReason: nil, revokeSeq: status == .revoked ? 40 : nil, revokedAtMs: status == .revoked ? 9_000 : nil
            )
        }
    }

    private let approver = Device(id: "ios_device_approver_0001")
    private let requester = Device(id: "and_device_requester_001")
    private let scalar = P256.Signing.PrivateKey().rawRepresentation
    private var hkPubB64: String { E2EEAutoHistoryKey.publicKeyB64(scalar: scalar)! }

    private func account(approver approverStatus: E2EEAutoLog.DeviceStatus = .active, extra: [E2EEAutoLog.DeviceState] = []) -> E2EEAutoLog.AccountState {
        var account = E2EEAutoLog.AccountState(userId: Self.userId, accountSaltB64: Self.salt)
        account.devices[approver.id] = approver.state(approverStatus)
        account.devices[requester.id] = requester.state(platform: .android, addedAtMs: 7_000)
        for device in extra { account.devices[device.deviceId] = device }
        account.historyKeyPubB64 = hkPubB64
        account.lastEntryHash = E2EEAutoLog.digest("last")
        return account
    }

    private static func view(
        _ id: String = requestId, device: String, status: String = "open", activate: Bool = false, createdAtMs: Int64 = 900_000
    ) -> [String: Any] {
        ["requestId": id, "deviceId": device, "activate": activate, "status": status,
         "createdAtMs": String(createdAtMs), "expiresAtMs": String(createdAtMs + 86_400_000)]
    }

    private static func json(_ object: Any) -> E2EEV2TransportResult<Data> {
        .success(value: try! JSONSerialization.data(withJSONObject: object), statusCode: 200, idempotentReplay: false)
    }

    private static func failure(_ status: Int, _ code: String, details: [String: JSONValue]? = nil) -> E2EEV2TransportResult<Data> {
        .failure(.init(
            kind: E2EEV2TransportFailurePolicy.classify(statusCode: status, code: code), statusCode: status, code: code,
            message: "x", details: details
        ))
    }

    private final class Fake: @unchecked Sendable {
        var reads: [E2EEAutoEnrollment.OwnAccount]
        var readCount = 0
        /// Réponses par « MÉTHODE chemin », consommées dans l'ordre.
        var routes: [String: [E2EEV2TransportResult<Data>]] = [:]
        /// Réponse calculée sur le corps reçu (l'`ACTIVATE` écrit à partir de la signature envoyée).
        var echoes: [String: (Data) -> E2EEV2TransportResult<Data>] = [:]
        var held: [String: Data] = [:]
        var open: E2EEAutoHistoryRequests.OpenRequest?
        private(set) var calls: [String] = []
        private(set) var bodies: [String: [String: Any]] = [:]
        private(set) var kept: [Data] = []
        var nowMs: Int64 = 1_000_000

        init(reads: [E2EEAutoEnrollment.OwnAccount]) { self.reads = reads }

        private func answer(_ key: String, body: Data?) -> E2EEV2TransportResult<Data> {
            calls.append(key)
            if let body { bodies[key] = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
            if let body, let echo = echoes[key] { return echo(body) }
            guard var queue = routes[key], !queue.isEmpty else {
                return key.hasPrefix("PUT") ? .success(value: Data("{}".utf8), statusCode: 200, idempotentReplay: false)
                    : .failure(.init(kind: .retryable, statusCode: 503, message: "x"))
            }
            let first = queue.removeFirst()
            routes[key] = queue
            return first
        }

        func dependencies(_ device: Device) -> E2EEAutoHistoryRequests.Dependencies {
            .init(
                userId: E2EEAutoHistoryRequestsTests.userId,
                device: { device.descriptor },
                sign: { try E2EEV2LowS.sign($0, with: device.signing) },
                get: { [self] path in answer("GET \(path)", body: nil) },
                post: { [self] path, body, _ in answer("POST \(path)", body: body) },
                delete: { [self] path, _ in answer("DELETE \(path)", body: nil) },
                put: { [self] path, body, _ in answer("PUT \(path)", body: body) },
                readOwnAccount: { [self] in
                    defer { readCount += 1 }
                    return reads[min(readCount, reads.count - 1)]
                },
                scalar: { [self] in held[$0] },
                keep: { [self] scalar in
                    kept.append(scalar)
                    let key = E2EEAutoHistoryKey.publicKeyB64(scalar: scalar)!
                    held[key] = scalar
                    return key
                },
                heldKeyVersions: { [1] },
                openWrap: { wrap in try E2EEAutoHistory.open(wrap, userId: E2EEAutoHistoryRequestsTests.userId, agreementKey: device.agreement) },
                openRequest: { [self] in open },
                recordOpenRequest: { [self] in open = $0 },
                nowMs: { [self] in nowMs }
            )
        }
    }

    private var requestPath: String { E2EEAutoHistoryRequestContract.requestPath(Self.requestId) }
    private var fulfilPath: String { E2EEAutoHistoryRequestContract.fulfilPath(Self.requestId) }

    /// L'approbateur scelle par `approve` ; le serveur rend la même enveloppe.
    private func servedWrap(account: E2EEAutoLog.AccountState) async throws -> [String: Any] {
        let fake = Fake(reads: [.verified(account)])
        fake.held[hkPubB64] = scalar
        fake.routes["GET \(requestPath)"] = [Self.json(["request": Self.view(device: requester.id), "historyWrap": NSNull()])]
        fake.routes["POST \(fulfilPath)"] = [Self.json(["request": Self.view(device: requester.id, status: "fulfilled"), "activation": NSNull()])]
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(approver)).approve(requestId: Self.requestId)
        XCTAssertEqual(outcome, .served)
        let body = try XCTUnwrap(fake.bodies["POST \(fulfilPath)"])
        XCTAssertEqual(Set(body.keys), ["historyWrap", "activation"])
        XCTAssertTrue(body["activation"] is NSNull)
        return try XCTUnwrap(body["historyWrap"] as? [String: Any])
    }

    private func requesterFake(account: E2EEAutoLog.AccountState, wrap: [String: Any]) -> Fake {
        let fake = Fake(reads: [.verified(account)])
        fake.open = .init(requestId: Self.requestId, expiresAtMs: 900_000 + 86_400_000)
        fake.routes["GET \(requestPath)"] = [Self.json(["request": Self.view(device: requester.id, status: "fulfilled"), "historyWrap": wrap])]
        return fake
    }

    /// « C'est moi » de bout en bout : HK enveloppée vers la clé d'accord du journal,
    /// ouverte par le demandeur, rangée puis déclarée `present`.
    func testApprovedRequestIsReceivedOpenedAndDeclared() async throws {
        let wrap = try await servedWrap(account: account())
        XCTAssertEqual(wrap["recipient"] as? String, requester.id)
        XCTAssertEqual(wrap["requestId"] as? String, Self.requestId)
        XCTAssertEqual(wrap["addHash"] as? String, E2EEAutoLog.digest("add-\(requester.id)"))
        XCTAssertEqual(wrap["hkPubB64"] as? String, hkPubB64)

        let fake = requesterFake(account: account(), wrap: wrap)
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(requester)).check()
        XCTAssertEqual(outcome, .present(hkPubB64: hkPubB64))
        XCTAssertEqual(fake.kept, [scalar])
        XCTAssertNil(fake.open, "la demande servie n'est plus attendue")
        XCTAssertEqual(fake.bodies["PUT \(E2EEAutoHistoryKeyContract.historyStatusPath(deviceId: requester.id))"]?["historyKey"] as? String, "present")
    }

    /// §5.4 : l'émetteur doit être `ACTIVE` au journal vérifié ; révoqué, rien n'est rangé.
    func testWrapFromARevokedSenderIsNotKept() async throws {
        let wrap = try await servedWrap(account: account())
        let fake = requesterFake(account: account(approver: .revoked), wrap: wrap)
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(requester)).check()
        XCTAssertEqual(outcome, .failed("e2ee-auto-history-wrap-sender"))
        XCTAssertTrue(fake.kept.isEmpty)
    }

    /// Une enveloppe d'une autre demande que celle ouverte ici est refusée.
    func testWrapForAnotherRequestIsNotKept() async throws {
        var wrap = try await servedWrap(account: account())
        wrap["requestId"] = "hreq_000000000000000002"
        let fake = requesterFake(account: account(), wrap: wrap)
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(requester)).check()
        XCTAssertNotEqual(outcome, .present(hkPubB64: hkPubB64))
        XCTAssertTrue(fake.kept.isEmpty)
    }

    /// Révision 11 : « ouverte » se juge ici ; une demande expirée n'accepte plus rien, sans lecture.
    func testLocallyExpiredRequestAcceptsNothing() async throws {
        let wrap = try await servedWrap(account: account())
        let fake = requesterFake(account: account(), wrap: wrap)
        fake.nowMs = 900_000 + 86_400_000
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(requester)).check()
        XCTAssertEqual(outcome, .closed)
        XCTAssertFalse(fake.calls.contains("GET \(requestPath)"))
        XCTAssertTrue(fake.kept.isEmpty)
        XCTAssertNil(fake.open)
    }

    /// HK arrivée par la synchro pendant l'attente : la demande est annulée, `present` déclaré.
    func testHeldKeyCancelsTheOpenRequest() async {
        let fake = Fake(reads: [.verified(account())])
        fake.held[hkPubB64] = scalar
        fake.open = .init(requestId: Self.requestId, expiresAtMs: 900_000 + 86_400_000)
        fake.routes["DELETE \(requestPath)"] = [Self.json(Self.view(device: requester.id, status: "cancelled"))]
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(requester)).start()
        XCTAssertEqual(outcome, .present(hkPubB64: hkPubB64))
        XCTAssertTrue(fake.calls.contains("DELETE \(requestPath)"))
        XCTAssertNil(fake.open)
        XCTAssertFalse(fake.calls.contains("POST \(E2EEAutoHistoryRequestContract.requestsPath)"))
    }

    /// Création : corps exact `{ activate: false }`, vue stricte, demande retenue ici.
    func testStartCreatesARequestAndParsesItsViewStrictly() async {
        let create = "POST \(E2EEAutoHistoryRequestContract.requestsPath)"
        let fake = Fake(reads: [.verified(account())])
        fake.routes[create] = [Self.json(Self.view(device: requester.id))]
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(requester)).start()
        XCTAssertEqual(outcome, .waiting(.init(requestId: Self.requestId, expiresAtMs: 900_000 + 86_400_000)))
        XCTAssertEqual(fake.bodies[create]?.count, 1)
        XCTAssertEqual(fake.bodies[create]?["activate"] as? Bool, false)
        XCTAssertEqual(fake.open?.requestId, Self.requestId)

        var extra = Self.view(device: requester.id); extra["label"] = "Pixel"
        var number = Self.view(device: requester.id); number["createdAtMs"] = 900_000
        var lifetime = Self.view(device: requester.id); lifetime["expiresAtMs"] = "900001"
        var rotation = Self.view(device: requester.id); rotation["requestId"] = "rotation-12"
        var flag = Self.view(device: requester.id); flag["activate"] = 0
        for bad in [extra, number, lifetime, rotation, flag] {
            XCTAssertNil(E2EEAutoHistoryRequestContract.view(bad), "\(bad)")
        }
    }

    /// L'écran « C'est moi » : seulement les demandes d'appareils actifs du journal,
    /// décrites par lui (plateforme, heure d'ajout, empreinte), jamais la sienne.
    func testListingShowsOnlyLogDescribedRequests() async {
        let stranger = Device(id: "web_device_unknown_00001")
        let pending = Device(id: "ios_device_pending_00001")
        let fake = Fake(reads: [.verified(account(extra: [pending.state(.pending)]))])
        fake.held[hkPubB64] = scalar
        fake.routes["GET \(E2EEAutoHistoryRequestContract.requestsPath)"] = [Self.json(["requests": [
            Self.view(device: requester.id),
            Self.view("hreq_000000000000000003", device: stranger.id),
            Self.view("hreq_000000000000000004", device: pending.id, activate: true),
            Self.view("hreq_000000000000000005", device: approver.id),
        ]])]
        let listing = await E2EEAutoHistoryRequests(fake.dependencies(approver)).openRequests()
        guard case .requests(let items) = listing else { return XCTFail("\(listing)") }
        XCTAssertEqual(items.map(\.deviceId), [requester.id])
        XCTAssertEqual(items.first?.platform, .android)
        XCTAssertEqual(items.first?.addedAtMs, 7_000)
        let fingerprint = E2EEAutoSafetyCode.deviceFingerprint(
            userId: Self.userId, deviceId: requester.id, signingKeyB64: requester.state().signingKeyB64
        )
        XCTAssertEqual(items.first?.fingerprint, E2EEAutoSafetyCode.shortFingerprint(fingerprint))
        XCTAssertEqual(items.first?.fingerprint.count, 4)
    }

    /// Servie entre-temps par un autre appareil : succès pour lui, notification retirée.
    func testApproveAfterAnotherDeviceServedIt() async {
        let fake = Fake(reads: [.verified(account())])
        fake.held[hkPubB64] = scalar
        fake.routes["GET \(requestPath)"] = [Self.json(["request": Self.view(device: requester.id), "historyWrap": NSNull()])]
        fake.routes["POST \(fulfilPath)"] = [Self.failure(409, "E2EE_HISTORY_REQUEST_CLOSED", details: ["status": .string("fulfilled")])]
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(approver)).approve(requestId: Self.requestId)
        XCTAssertEqual(outcome, .alreadyServed)
    }

    /// Clé du demandeur périmée : le compte est relu et l'enveloppe refaite, une fois.
    func testStaleRecipientKeyRereadsAndReseals() async {
        let fake = Fake(reads: [.verified(account())])
        fake.held[hkPubB64] = scalar
        let open = Self.json(["request": Self.view(device: requester.id), "historyWrap": NSNull()])
        fake.routes["GET \(requestPath)"] = [open, open]
        fake.routes["POST \(fulfilPath)"] = [
            Self.failure(409, "E2EE_RECIPIENT_KEY_STALE"),
            Self.json(["request": Self.view(device: requester.id, status: "fulfilled"), "activation": NSNull()]),
        ]
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(approver)).approve(requestId: Self.requestId)
        XCTAssertEqual(outcome, .served)
        XCTAssertEqual(fake.readCount, 2)
        XCTAssertEqual(fake.calls.filter { $0 == "POST \(fulfilPath)" }.count, 2)
    }

    /// Sans la HK du journal, l'approbateur n'envoie rien.
    func testApproverWithoutTheHistoryKeySendsNothing() async {
        let fake = Fake(reads: [.verified(account())])
        fake.routes["GET \(requestPath)"] = [Self.json(["request": Self.view(device: requester.id), "historyWrap": NSNull()])]
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(approver)).approve(requestId: Self.requestId)
        XCTAssertEqual(outcome, .noHistoryKey)
        XCTAssertFalse(fake.calls.contains("POST \(fulfilPath)"))
    }

    /// Sans HK, l'appareil ne pourrait rien servir : aucune liste, aucune lecture.
    func testApproverWithoutTheHistoryKeyListsNothing() async {
        let fake = Fake(reads: [.verified(account())])
        fake.routes["GET \(E2EEAutoHistoryRequestContract.requestsPath)"] = [Self.json(["requests": [Self.view(device: requester.id)]])]
        let listing = await E2EEAutoHistoryRequests(fake.dependencies(approver)).openRequests()
        XCTAssertEqual(listing, .requests([]))
        XCTAssertFalse(fake.calls.contains("GET \(E2EEAutoHistoryRequestContract.requestsPath)"))
    }

    // MARK: - Mode renforcé (§6)

    private static let day = E2EEAutoLog.signerMinAgeMs

    /// Le demandeur est en attente (`ADD_PENDING`) ; l'approbateur, inscrit à 5 000 ms.
    private func strictAccount(activated: Bool = false) -> E2EEAutoLog.AccountState {
        var account = account()
        account.mode = .strict
        var state = requester.state(activated ? .active : .pending, platform: .android, addedAtMs: 7_000)
        if activated { state.activatedAtMs = 7_000 + Self.day + 10 }
        account.devices[requester.id] = state
        return account
    }

    /// L'`ACTIVATE` que le serveur écrirait à partir du corps reçu, signé par l'approbateur.
    private func writtenActivation(_ body: Data, signer: String? = nil) -> E2EEV2TransportResult<Data> {
        let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let activation = object["activation"] as? [String: Any] ?? [:]
        let state = requester.state(.pending, platform: .android, addedAtMs: 7_000)
        let entry = E2EEAutoLog.Entry(
            seq: 31, userId: Self.userId, prevUserEntryHash: activation["prevUserEntryHash"] as? String ?? "", op: .activate,
            deviceId: requester.id, platform: "android", identityKeyB64: state.identityKeyB64, signingKeyB64: state.signingKeyB64,
            keyVersion: "1", detail: "\(signer ?? approver.id):\(activation["signatureB64"] as? String ?? "")", createdAtMs: 9
        ).canonical
        let link = ["SQ-E2EE-AUTO-LOG-LINK", "1", "31", E2EEAutoLog.digest("prev"), "ENTRY", E2EEAutoLog.digest("tag"),
                    E2EEAutoLog.digest(entry), "0"].joined(separator: "\n")
        return Self.json([
            "request": Self.view(device: requester.id, status: "fulfilled", activate: true),
            "activation": ["entry": entry, "link": link, "head": ["text": "t", "signatureB64": "s"]],
        ])
    }

    /// En attente, la demande part aussitôt avec `activate: true`, même avec HK déjà synchronisée.
    func testPendingDeviceAsksForActivationEvenWithTheKey() async {
        let create = "POST \(E2EEAutoHistoryRequestContract.requestsPath)"
        let fake = Fake(reads: [.verified(strictAccount())])
        fake.held[hkPubB64] = scalar
        fake.routes[create] = [Self.json(Self.view(device: requester.id, activate: true))]
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(requester)).start()
        XCTAssertEqual(outcome, .waiting(.init(requestId: Self.requestId, expiresAtMs: 900_000 + 86_400_000, activate: true)))
        XCTAssertEqual(fake.bodies[create]?["activate"] as? Bool, true)
        XCTAssertFalse(fake.calls.contains { $0.hasPrefix("DELETE") || $0.hasPrefix("PUT") })
    }

    /// L'approbateur inscrit depuis 24 h voit la demande d'activation, décrite par le journal ;
    /// plus récent, il ne la voit pas.
    func testActivationRequestIsListedOnlyForAnOldEnoughApprover() async {
        let list = "GET \(E2EEAutoHistoryRequestContract.requestsPath)"
        let fake = Fake(reads: [.verified(strictAccount())])
        fake.nowMs = 5_000 + Self.day
        fake.routes[list] = [Self.json(["requests": [Self.view(device: requester.id, activate: true)]])]
        let listing = await E2EEAutoHistoryRequests(fake.dependencies(approver)).openRequests()
        guard case .requests(let items) = listing else { return XCTFail("\(listing)") }
        XCTAssertEqual(items.map(\.deviceId), [requester.id])
        XCTAssertEqual(items.first?.activate, true)

        let recent = Fake(reads: [.verified(strictAccount())])
        recent.nowMs = 5_000 + Self.day - 1
        recent.routes[list] = [Self.json(["requests": [Self.view(device: requester.id, activate: true)]])]
        let none = await E2EEAutoHistoryRequests(recent.dependencies(approver)).openRequests()
        XCTAssertEqual(none, .requests([]))
        XCTAssertFalse(recent.calls.contains(list))
    }

    /// « C'est moi » sur une demande d'activation : l'`ACTIVATE` signé par l'approbateur
    /// sur la dernière entrée, recopiant la cible du journal, et HK dans la même opération.
    func testApproverSignsTheActivationAndSendsTheKey() async throws {
        let account = strictAccount()
        let fake = Fake(reads: [.verified(account)])
        fake.nowMs = 5_000 + Self.day
        fake.held[hkPubB64] = scalar
        fake.routes["GET \(requestPath)"] = [Self.json(["request": Self.view(device: requester.id, activate: true), "historyWrap": NSNull()])]
        fake.echoes["POST \(fulfilPath)"] = { self.writtenActivation($0) }
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(approver)).approve(requestId: Self.requestId)
        XCTAssertEqual(outcome, .served)

        let body = try XCTUnwrap(fake.bodies["POST \(fulfilPath)"])
        let activation = try XCTUnwrap(body["activation"] as? [String: Any])
        XCTAssertEqual(Set(activation.keys), ["prevUserEntryHash", "signatureB64"])
        XCTAssertEqual(activation["prevUserEntryHash"] as? String, account.lastEntryHash)
        let target = account.devices[requester.id]!
        let payload = E2EEAutoLog.Payload.activate(
            userId: Self.userId, prevUserEntryHash: account.lastEntryHash!, approverDeviceId: approver.id, deviceId: requester.id,
            identityKeyB64: target.identityKeyB64, signingKeyB64: target.signingKeyB64, keyVersion: 1
        )
        XCTAssertTrue(E2EEAutoLog.verify(
            publicKeyB64: approver.descriptor.publicSigningKeyB64, payload: payload,
            signatureB64: try XCTUnwrap(activation["signatureB64"] as? String)
        ))
        let wrap = try XCTUnwrap(E2EEAutoHistory.parseWrap(try XCTUnwrap(body["historyWrap"] as? [String: Any])))
        XCTAssertEqual(wrap.addHash, target.addEntryHash, "addHash = entryHash de l'ADD_PENDING")
    }

    /// Sans HK, l'approbateur active quand même, `historyWrap` nul ; une réponse dont
    /// l'`ACTIVATE` n'est pas celui signé ici est refusée.
    func testActivationWithoutTheKeyAndForgedResponse() async throws {
        let fake = Fake(reads: [.verified(strictAccount())])
        fake.nowMs = 5_000 + Self.day
        let open = Self.json(["request": Self.view(device: requester.id, activate: true), "historyWrap": NSNull()])
        fake.routes["GET \(requestPath)"] = [open, open]
        fake.echoes["POST \(fulfilPath)"] = { self.writtenActivation($0) }
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(approver)).approve(requestId: Self.requestId)
        XCTAssertEqual(outcome, .served)
        XCTAssertTrue(fake.bodies["POST \(fulfilPath)"]?["historyWrap"] is NSNull)

        fake.echoes["POST \(fulfilPath)"] = { self.writtenActivation($0, signer: self.requester.id) }
        let forged = await E2EEAutoHistoryRequests(fake.dependencies(approver)).approve(requestId: Self.requestId)
        XCTAssertEqual(forged, .failed("invalid-e2ee-auto-history-fulfil-response"))
    }

    /// Activé sans HK : la demande se ferme et la suite habituelle reprend ; tant que
    /// le journal ne montre pas l'`ACTIVATE`, la demande reste retenue.
    func testActivatedRequesterContinuesOnlyOnceTheLogShowsIt() async {
        let read = Self.json(["request": Self.view(device: requester.id, status: "fulfilled", activate: true), "historyWrap": NSNull()])
        let stale = Fake(reads: [.verified(strictAccount())])
        stale.open = .init(requestId: Self.requestId, expiresAtMs: 900_000 + 86_400_000, activate: true)
        stale.routes["GET \(requestPath)"] = [read]
        let waiting = await E2EEAutoHistoryRequests(stale.dependencies(requester)).check()
        XCTAssertEqual(waiting, .retryLater(afterSeconds: nil))
        XCTAssertNotNil(stale.open)

        let fake = Fake(reads: [.verified(strictAccount()), .verified(strictAccount(activated: true))])
        fake.open = .init(requestId: Self.requestId, expiresAtMs: 900_000 + 86_400_000, activate: true)
        fake.routes["GET \(requestPath)"] = [read]
        let outcome = await E2EEAutoHistoryRequests(fake.dependencies(requester)).check()
        XCTAssertEqual(outcome, .activated)
        XCTAssertNil(fake.open)
    }
}
