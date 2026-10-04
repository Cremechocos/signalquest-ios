import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot A1 (plan 3) de bout en bout contre un faux serveur qui garde l'état de
/// confiance du compte : bootstrap du premier appareil avec l'UIK, approbation
/// d'un second par QR, réception de l'UIK, révocation.
final class E2EEV2A1LifecycleTests: XCTestCase {
    private let now: Int64 = 1_790_000_000_000

    /// Ce que le serveur garde du compte (E.1) et sert à `GET …/identity`.
    private final class TrustServer: @unchecked Sendable {
        private let lock = NSLock()
        var uik: String?
        var lists: [[String: Any]] = []
        var certificates: [[String: Any]] = []
        var deposit: [String: Any]?
        var approvalStatus = "pending"
        var staleOnce = false
        var bodies: [String: [[String: Any]]] = [:]
        var bootstrapFailures = 0
        /// La rotation est enregistrée, mais la réponse se perd.
        var recertificationLost = false
        /// Séquence de capacités enregistrée par appareil ; une réponse STALE forcée.
        var capabilitySequences: [String: Int] = [:]
        var staleCapabilitiesOnce: Int?
        var invalidCapabilitiesOnce = false

        func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

        func record(_ path: String, _ body: [String: Any]) { locked { bodies[path, default: []].append(body) } }

        func identity(since: Int?) throws -> Data {
            try locked {
                let current = try XCTUnwrap(lists.last)
                let start = since ?? lists.count
                let chain = lists.indices.filter { $0 + 1 > start && $0 + 1 < lists.count }
                    .map { ["list": lists[$0]["list"]!, "signatureB64": lists[$0]["signatureB64"]!] }
                return try JSONSerialization.data(withJSONObject: [
                    "accountIdentityKeyB64": try XCTUnwrap(uik), "deviceList": current, "deviceListChain": chain,
                    "certificates": certificates, "capabilities": [], "pendingIdentityReset": NSNull(),
                ])
            }
        }
    }

    private struct Device {
        let identity: E2EEV2DeviceIdentityStore
        let accounts: E2EEV2AccountIdentityStore
        let vault: InMemoryTokenStore
        let descriptor: E2EEV2DeviceDescriptor
        let lifecycle: E2EEV2DeviceLifecycleCoordinator
    }

    private func device(_ fixture: E2EEV2AccountFixture, primary: Bool, nowMs: Int64? = nil, appBuild: String = "161") throws -> Device {
        let vault = primary ? fixture.vault : InMemoryTokenStore()
        let identity = primary ? fixture.identity : E2EEV2DeviceIdentityStore(tokenStore: vault, allowsOwner: { _ in true })
        let descriptor = primary ? fixture.descriptor : try identity.loadOrCreate(ownerNamespace: fixture.session.ownerNamespace)
        let accounts = E2EEV2AccountIdentityStore(tokenStore: vault, allowsOwner: { _ in true })
        let now = nowMs ?? self.now
        return Device(
            identity: identity, accounts: accounts, vault: vault, descriptor: descriptor,
            lifecycle: E2EEV2DeviceLifecycleCoordinator(
                api: fixture.api, identityStore: identity, epochKeyStore: fixture.keys,
                conversationStateStore: fixture.states, accountIdentityStore: accounts,
                trustPins: E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore()),
                capabilities: E2EEV2CapabilitiesPublicationStore(tokenStore: vault, allowsOwner: { _ in true }),
                appBuild: appBuild, nowMs: { now },
                rotationCommitted: { _, _, _ in }
            )
        )
    }

    private func remote(_ descriptor: E2EEV2DeviceDescriptor, status: String) -> [String: Any] {
        [
            "deviceId": descriptor.deviceId, "platform": descriptor.platform, "label": NSNull(),
            "publicIdentityKeyB64": descriptor.publicIdentityKeyB64, "publicSigningKeyB64": descriptor.publicSigningKeyB64,
            "identityKeyAlgorithm": descriptor.identityKeyAlgorithm, "signingKeyAlgorithm": descriptor.signingKeyAlgorithm,
            "keyVersion": 1, "status": status, "approvedAt": NSNull(), "revokedAt": NSNull(),
            "lastSeenAt": NSNull(), "createdAt": "2026-10-02T00:00:00.000Z",
        ]
    }

    private static let approvalId = "approval_a1_000000000001"
    private static let challenge = String(repeating: "Q", count: 43)
    private static let expiresAt = "2026-10-02T23:59:00.000Z"

    private static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private func approvalDetail(_ pending: E2EEV2DeviceDescriptor, server: TrustServer) throws -> Data {
        try server.locked {
            let approved = server.approvalStatus == "approved"
            var root: [String: Any] = [
                "approval": [
                    "id": Self.approvalId, "pendingDeviceId": pending.deviceId, "method": "QR",
                    "challengeB64Url": approved ? NSNull() : Self.challenge as Any, "proximityCode": NSNull(),
                    "status": server.approvalStatus, "expiresAt": Self.expiresAt, "createdAt": "2026-10-02T00:00:00.000Z",
                ],
                "pendingDevice": remote(pending, status: approved ? "approved" : "pending"),
                "certificate": NSNull(), "deviceList": NSNull(), "uikWrap": NSNull(),
            ]
            if approved, let deposit = server.deposit { root.merge(deposit) { $1 } }
            return try JSONSerialization.data(withJSONObject: root)
        }
    }

    private func install(_ server: TrustServer, pending: E2EEV2DeviceDescriptor) {
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let respond = { (object: Any, status: Int) throws -> (HTTPURLResponse, Data) in
                E2EEV2AccountFixture.response(request, try JSONSerialization.data(withJSONObject: object), status: status)
            }
            switch (request.httpMethod, path) {
            case ("GET", let path) where path.hasSuffix("/identity"):
                let since = request.url?.query.flatMap { Int($0.replacingOccurrences(of: "sinceVersion=", with: "")) }
                return E2EEV2AccountFixture.response(request, try server.identity(since: since))
            case ("POST", "/api/e2ee/v2/bootstrap"):
                let body = try E2EEV2AccountFixture.body(request)
                server.record(path, body)
                if server.locked({ server.bootstrapFailures > 0 }) {
                    server.locked { server.bootstrapFailures -= 1 }
                    return try respond(["error": "x", "code": "INTERNAL_ERROR", "requestId": "r"], 503)
                }
                server.locked {
                    server.uik = body["accountIdentityKeyB64"] as? String
                    server.lists = [body["deviceList"] as! [String: Any]]
                    server.certificates = [body["certificate"] as! [String: Any]]
                }
                return try respond([
                    "device": ["deviceId": body["deviceId"]!, "status": "approved", "approvedByDeviceId": NSNull()],
                    "identity": ["generation": 1, "establishmentMethod": "account_reauth", "establishedAt": "2026-10-02T00:00:00.000Z"],
                    "alreadyBootstrapped": false, "epochRotationRequired": false,
                ], 200)
            case ("GET", "/api/e2ee/v2/device-approvals/\(Self.approvalId)"):
                return E2EEV2AccountFixture.response(request, try self.approvalDetail(pending, server: server))
            case ("POST", "/api/e2ee/v2/device-approvals/\(Self.approvalId)/approve"):
                let body = try E2EEV2AccountFixture.body(request)
                server.record(path, body)
                if server.locked({ let stale = server.staleOnce; server.staleOnce = false; return stale }) {
                    return try respond(["error": "x", "code": "E2EE_DEVICE_LIST_STALE", "requestId": "r",
                                        "details": ["userId": "u", "userIds": []]], 409)
                }
                server.locked {
                    server.lists.append(body["deviceList"] as! [String: Any])
                    server.certificates.append(body["certificate"] as! [String: Any])
                    server.deposit = ["certificate": body["certificate"]!, "deviceList": body["deviceList"]!, "uikWrap": body["uikWrap"]!]
                    server.approvalStatus = "approved"
                }
                return try respond([
                    "device": ["deviceId": pending.deviceId, "status": "approved", "approvedAt": "2026-10-02T00:01:00.000Z",
                               "approvedByDeviceId": "x_approver_0000000001"],
                    "epochRotationRequired": false, "affectedConversationIds": [],
                ], 200)
            case ("PUT", let path) where path.hasSuffix("/certificate"):
                let body = try E2EEV2AccountFixture.body(request)
                server.record("certificate", body)
                let list = body["deviceList"] as! [String: Any]
                let accepted = try server.locked { () throws -> Bool in
                    server.lists.append(list)
                    server.certificates = [body["certificate"] as! [String: Any]]
                    defer { server.recertificationLost = false }
                    return !server.recertificationLost
                }
                guard accepted else { return try respond(["error": "x", "code": "INTERNAL_ERROR", "requestId": "r"], 503) }
                let version = try XCTUnwrap((list["list"] as? String)?.components(separatedBy: "\n")[3])
                return try respond(["deviceId": path.components(separatedBy: "/")[5], "keyVersion": "2", "deviceListVersion": version], 200)
            case ("PUT", let path) where path.hasSuffix("/capabilities"):
                let body = try E2EEV2AccountFixture.body(request)
                server.record("capabilities", body)
                XCTAssertEqual(Set(body.keys), ["document", "signatureB64"])
                let document = try E2EEV2CapabilitiesDocument.parse(document: try XCTUnwrap(body["document"] as? String))
                let deviceId = path.components(separatedBy: "/")[5]
                XCTAssertEqual(document.deviceId, deviceId)
                if server.locked({ () -> Bool in defer { server.invalidCapabilitiesOnce = false }; return server.invalidCapabilitiesOnce }) {
                    return try respond(["error": "x", "code": "E2EE_CAPABILITIES_INVALID", "requestId": "r"], 422)
                }
                if let stale = server.locked({ () -> Int? in defer { server.staleCapabilitiesOnce = nil }; return server.staleCapabilitiesOnce }) {
                    return try respond(["error": "x", "code": "E2EE_CAPABILITIES_STALE", "requestId": "r",
                                        "details": ["currentSequence": String(stale)]], 409)
                }
                server.locked { server.capabilitySequences[deviceId] = document.sequence }
                return try respond(["deviceId": deviceId, "sequence": String(document.sequence)], 200)
            case ("POST", let path) where path.hasSuffix("/revoke"):
                let body = try E2EEV2AccountFixture.body(request)
                server.record("revoke", body)
                let deviceId = path.components(separatedBy: "/")[5]
                return try respond([
                    "revoked": true, "alreadyRevoked": false, "deviceId": deviceId, "selfRevocation": false,
                    "revokedSessionCount": 0, "cleanupScheduled": true, "rotationRequired": false, "affectedConversationIds": [],
                ], 200)
            default:
                return try respond(["error": "x", "code": "NOT_FOUND", "requestId": "r"], 404)
            }
        }
    }

    func testTheAccountKeyTravelsFromTheFirstDeviceToTheNextOne() async throws {
        let fixture = try E2EEV2AccountFixture()
        defer { fixture.close() }
        let first = try device(fixture, primary: true)
        let second = try device(fixture, primary: false)
        let namespace = fixture.session.ownerNamespace
        let server = TrustServer()
        install(server, pending: second.descriptor)

        // 1. Bootstrap : une première tentative perdue, la reprise renvoie les mêmes textes.
        server.locked { server.bootstrapFailures = 1 }
        let reauth = E2EEV2BootstrapReauthentication.email(challengeId: "challenge_000000000001", code: "123456")
        guard case .failed = await first.lifecycle.bootstrapInitialDevice(reauth) else { return XCTFail("503 attendu") }
        guard case .success = await first.lifecycle.bootstrapInitialDevice(reauth) else { return XCTFail("bootstrap") }
        let bootstraps = try XCTUnwrap(server.locked { server.bodies["/api/e2ee/v2/bootstrap"] })
        XCTAssertEqual(bootstraps.count, 2)
        for key in ["accountIdentityKeyB64"] {
            XCTAssertEqual(bootstraps[0][key] as? String, bootstraps[1][key] as? String)
        }
        XCTAssertEqual((bootstraps[0]["certificate"] as? [String: Any])?["certificate"] as? String,
                       (bootstraps[1]["certificate"] as? [String: Any])?["certificate"] as? String, "Même certificat au rejeu")
        XCTAssertEqual((bootstraps[0]["deviceList"] as? [String: Any])?["list"] as? String,
                       (bootstraps[1]["deviceList"] as? [String: Any])?["list"] as? String, "Même liste v1 au rejeu")
        let certificate = try E2EEV2DeviceCertificate.parse(
            try XCTUnwrap((bootstraps[1]["certificate"] as? [String: Any])?["certificate"] as? String)
        )
        XCTAssertEqual(certificate.platform, "ios")
        XCTAssertEqual(certificate.deviceId, first.descriptor.deviceId)
        let uik = try XCTUnwrap(try first.accounts.load(ownerNamespace: namespace))
        XCTAssertEqual(uik.publicKey.x963Representation.base64EncodedString(), bootstraps[1]["accountIdentityKeyB64"] as? String)
        XCTAssertTrue(try first.accounts.isVerified(ownerNamespace: namespace))
        XCTAssertNil(try first.vault.string(for: E2EEV2AccountIdentityStore.pendingBootstrapKey(ownerNamespace: namespace)),
                     "Confirmé : plus de bootstrap en cours")

        // 2. Le second appareil affiche son QR ; le premier le scanne et approuve.
        let detail = try XCTUnwrap(E2EEV2DeviceApprovalContract.parseApprovalDetail(try approvalDetail(second.descriptor, server: server)))
        let identityKey = try XCTUnwrap(Data(base64Encoded: second.descriptor.publicIdentityKeyB64))
        let signingKey = try XCTUnwrap(Data(base64Encoded: second.descriptor.publicSigningKeyB64))
        let qr = E2EEV2QRApprovalPayload(
            approvalId: Self.approvalId, pendingDeviceId: second.descriptor.deviceId, platform: "ios",
            fingerprint: E2EEV2Canonical.deviceFingerprint(identityKeyX963: identityKey, signingKeyX963: signingKey),
            challengeB64URL: Self.challenge,
            expiresAtMs: Int64((try XCTUnwrap(Self.isoDate(Self.expiresAt)).timeIntervalSince1970 * 1_000).rounded())
        )
        guard case .success(.pending) = await second.lifecycle.receiveApprovedTrust(approvalId: Self.approvalId) else {
            return XCTFail("Encore en attente")
        }
        server.locked { server.staleOnce = true }
        guard case .success = await first.lifecycle.approve(detail, comparedQR: qr) else { return XCTFail("approbation") }
        let approvals = try XCTUnwrap(server.locked { server.bodies["/api/e2ee/v2/device-approvals/\(Self.approvalId)/approve"] })
        XCTAssertEqual(approvals.count, 2, "Liste périmée : relue puis renvoyée une fois")
        XCTAssertEqual(Set(approvals[1].keys), ["pendingDeviceId", "challengeB64Url", "certificate", "deviceList", "uikWrap"])
        XCTAssertEqual(((approvals[1]["deviceList"] as? [String: Any])?["devices"] as? [String])?.count, 2)

        // Un QR d'un autre appareil n'est jamais approuvé.
        let forged = E2EEV2QRApprovalPayload(
            approvalId: qr.approvalId, pendingDeviceId: qr.pendingDeviceId, platform: qr.platform,
            fingerprint: String(repeating: "A", count: 43), challengeB64URL: qr.challengeB64URL, expiresAtMs: qr.expiresAtMs
        )
        guard case .failed(let refused) = await first.lifecycle.approve(detail, comparedQR: forged) else { return XCTFail() }
        XCTAssertEqual(refused.message, "e2ee-approval-method-unsupported")

        // 3. Le second appareil reçoit l'UIK du compte, non vérifiée, même
        // après la fermeture de l'écran : la demande en cours est gardée.
        try second.accounts.setPendingApprovalId(Self.approvalId, ownerNamespace: namespace)
        guard case .success(.approved)? = await second.lifecycle.resumePendingApproval() else {
            return XCTFail("UIK reçue")
        }
        XCTAssertNil(try second.accounts.pendingApprovalId(ownerNamespace: namespace), "Demande close une fois l'UIK reçue")
        let none = await second.lifecycle.resumePendingApproval()
        XCTAssertNil(none.map { _ in true })
        let received = try XCTUnwrap(try second.accounts.load(ownerNamespace: namespace))
        XCTAssertEqual(received.rawRepresentation, uik.rawRepresentation)
        XCTAssertFalse(try second.accounts.isVerified(ownerNamespace: namespace), "Reçue, jamais vérifiée d'avance")

        // 4. Révocation : la liste suivante ne nomme plus le second appareil.
        guard case .success = await first.lifecycle.revoke(deviceId: second.descriptor.deviceId, reason: "USER_REQUEST") else {
            return XCTFail("révocation")
        }
        let revoke = try XCTUnwrap(server.locked { server.bodies["revoke"]?.last })
        let entries = try XCTUnwrap((revoke["deviceList"] as? [String: Any])?["devices"] as? [String])
        XCTAssertEqual(entries.map { $0.components(separatedBy: "\n")[0] }, [first.descriptor.deviceId])
        // Un appareil en attente n'est pas dans la liste : pas de liste suivante.
        guard case .success = await first.lifecycle.revoke(deviceId: "ios_pending_000000000001", reason: "USER_REQUEST") else {
            return XCTFail("révocation d'un appareil en attente")
        }
        XCTAssertNil(try XCTUnwrap(server.locked { server.bodies["revoke"]?.last })["deviceList"])
    }

    /// §2.6 : après 30 jours, la clé d'accord tourne. Le certificat de la
    /// nouvelle (version 2) et la liste suivante partent signés par l'UIK ; une
    /// réponse perdue se rattrape en relisant la liste ; une enveloppe adressée
    /// à l'ancienne clé s'ouvre encore.
    func testTheAgreementKeyRotatesAfterThirtyDays() async throws {
        let fixture = try E2EEV2AccountFixture()
        defer { fixture.close() }
        let first = try device(fixture, primary: true)
        let namespace = fixture.session.ownerNamespace
        let server = TrustServer()
        install(server, pending: first.descriptor)
        guard case .success = await first.lifecycle.bootstrapInitialDevice(
            .email(challengeId: "challenge_000000000001", code: "123456")
        ) else { return XCTFail("bootstrap") }
        guard case .success(false) = await first.lifecycle.recertifyIfDue() else { return XCTFail("Pas encore due") }

        let epochKey = Data(repeating: 5, count: 32)
        let context = E2EEV2EpochContext(
            conversationId: "conversation_a1_0000000001", epochNumber: 1,
            senderDeviceId: first.descriptor.deviceId, recipientDeviceId: first.descriptor.deviceId
        )
        let envelope = try first.identity.createSignedEpochEnvelope(
            context: context, epochKey: epochKey, recipientPublicIdentityKeyB64: first.descriptor.publicIdentityKeyB64,
            ownerNamespace: namespace
        )
        let delivery = E2EEV2EpochDelivery(
            conversationId: context.conversationId, epochId: "epoch_a1_00000000000001", epochNumber: 1,
            keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(epochKey), reason: "INITIAL", status: "active",
            createdAt: "2026-10-02T00:00:00.000Z", senderDeviceId: first.descriptor.deviceId,
            senderPublicSigningKeyB64: first.descriptor.publicSigningKeyB64, envelope: envelope
        )

        // L'identité date de l'heure réelle : 30 jours après elle.
        let later = try device(
            fixture, primary: true,
            nowMs: Int64(Date().timeIntervalSince1970 * 1_000) + E2EEV2DeviceIdentityStore.agreementKeyLifetimeMs + 60_000
        )
        server.locked { server.recertificationLost = true }
        guard case .failed = await later.lifecycle.recertifyIfDue() else { return XCTFail("Réponse perdue") }
        XCTAssertEqual(try first.identity.load(ownerNamespace: namespace)?.keyVersion, 1, "Rien n'est activé sans réponse")
        guard case .success(true) = await later.lifecycle.recertifyIfDue() else { return XCTFail("Rattrapage") }
        XCTAssertEqual(server.locked { server.bodies["certificate"]?.count }, 1, "La liste porte déjà la clé : pas de second envoi")

        let rotated = try XCTUnwrap(try first.identity.load(ownerNamespace: namespace))
        XCTAssertEqual(rotated.keyVersion, 2)
        XCTAssertNotEqual(rotated.publicIdentityKeyB64, first.descriptor.publicIdentityKeyB64)
        XCTAssertEqual(rotated.publicSigningKeyB64, first.descriptor.publicSigningKeyB64, "La clé de signature ne change pas")
        let body = try XCTUnwrap(server.locked { server.bodies["certificate"]?.first })
        XCTAssertEqual(Set(body.keys), ["certificate", "deviceList"])
        let certificate = try E2EEV2DeviceCertificate.parse(try XCTUnwrap((body["certificate"] as? [String: Any])?["certificate"] as? String))
        XCTAssertEqual(certificate.keyVersion, 2)
        XCTAssertEqual(certificate.identityKeyB64, rotated.publicIdentityKeyB64)
        XCTAssertEqual(try first.identity.unwrapEpochKey(delivery: delivery, ownerNamespace: namespace), epochKey,
                       "Une enveloppe adressée à l'ancienne clé s'ouvre encore")
        guard case .success(false) = await later.lifecycle.recertifyIfDue() else { return XCTFail("Nouvelle clé : plus due") }
    }

    /// §12 : le document de capacités part après le bootstrap, signé par
    /// l'appareil ; il ne repart qu'avec un nouveau build ; une séquence
    /// dépassée repart au-dessus de celle du serveur.
    func testTheCapabilitiesDocumentIsPublishedAtBootstrapAndOnANewBuild() async throws {
        let fixture = try E2EEV2AccountFixture()
        defer { fixture.close() }
        let first = try device(fixture, primary: true)
        let server = TrustServer()
        install(server, pending: first.descriptor)
        guard case .success = await first.lifecycle.bootstrapInitialDevice(
            .email(challengeId: "challenge_000000000001", code: "123456")
        ) else { return XCTFail("bootstrap") }
        let published = try XCTUnwrap(server.locked { server.bodies["capabilities"]?.first })
        let document = try E2EEV2CapabilitiesDocument.parse(document: try XCTUnwrap(published["document"] as? String))
        XCTAssertEqual(document.sequence, 1)
        XCTAssertEqual(document.kinds, ["DELETE", "EDIT", "TEXT"])
        XCTAssertEqual(document.features, [], "Ni médias ni appels annoncés avant qu'ils marchent")
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(published["signatureB64"] as? String)))
        let signingKey = try P256.Signing.PublicKey(x963Representation: try XCTUnwrap(Data(base64Encoded: first.descriptor.publicSigningKeyB64)))
        XCTAssertTrue(E2EEV2LowS.verify(
            derSignature: signature,
            message: Data(E2EEV2CapabilitiesDocument.signatureCanonical(document: document.document).utf8),
            publicKey: signingKey
        ), "Signé par la clé de l'appareil, en low-S")

        guard case .success(false) = await first.lifecycle.publishCapabilitiesIfNeeded() else { return XCTFail("À jour") }
        XCTAssertEqual(server.locked { server.bodies["capabilities"]?.count }, 1)

        let upgraded = try device(fixture, primary: true, appBuild: "162")
        server.locked { server.staleCapabilitiesOnce = 5 }
        guard case .success(true) = await upgraded.lifecycle.publishCapabilitiesIfNeeded() else { return XCTFail("Nouveau build") }
        XCTAssertEqual(server.locked { server.capabilitySequences[first.descriptor.deviceId] }, 6,
                       "Au-dessus de la séquence du serveur")

        // Relecture du 04/10 : une séquence très en avance ne se croit pas.
        let next = try device(fixture, primary: true, appBuild: "163")
        server.locked { server.staleCapabilitiesOnce = 6 + 5_000 }
        guard case .failed(let implausible) = await next.lifecycle.publishCapabilitiesIfNeeded() else { return XCTFail("Refus attendu") }
        XCTAssertEqual(implausible.message, "e2ee-capabilities-sequence-implausible")
        XCTAssertEqual(server.locked { server.capabilitySequences[first.descriptor.deviceId] }, 6)
        // Un refus définitif ne fait pas repartir le même document.
        let refused = try device(fixture, primary: true, appBuild: "164")
        server.locked { server.invalidCapabilitiesOnce = true }
        guard case .failed = await refused.lifecycle.publishCapabilitiesIfNeeded() else { return XCTFail("422 attendu") }
        let namespace = fixture.session.ownerNamespace
        XCTAssertNil(try E2EEV2CapabilitiesPublicationStore(tokenStore: first.vault, allowsOwner: { _ in true }).load(ownerNamespace: namespace),
                     "Document refusé oublié")
        guard case .success(true) = await refused.lifecycle.publishCapabilitiesIfNeeded() else { return XCTFail("Document neuf") }
    }

    /// Un autre appareil a établi le compte pendant ce bootstrap : l'UIK créée
    /// ici est retirée, celle du compte pourra être installée à l'approbation.
    func testALostBootstrapRaceDiscardsTheLocalAccountKey() async throws {
        let fixture = try E2EEV2AccountFixture()
        defer { fixture.close() }
        let first = try device(fixture, primary: true)
        let namespace = fixture.session.ownerNamespace
        let served = LockedBoxA1<String?>(nil)
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/identity") == true {
                return E2EEV2AccountFixture.response(request, try JSONSerialization.data(withJSONObject: [
                    "accountIdentityKeyB64": served.value ?? "",
                ]))
            }
            return E2EEV2AccountFixture.response(request, try JSONSerialization.data(withJSONObject: [
                "error": "x", "code": "E2EE_IDENTITY_ALREADY_ESTABLISHED", "requestId": "r",
            ]), status: 409)
        }
        let reauth = E2EEV2BootstrapReauthentication.email(challengeId: "challenge_000000000001", code: "123456")
        // Le compte porte déjà notre UIK (textes différents) : elle est gardée et confirmée.
        let local = try first.accounts.pendingBootstrap(ownerNamespace: namespace, nowMs: now).uik
        served.value = local.publicKey.x963Representation.base64EncodedString()
        guard case .failed = await first.lifecycle.bootstrapInitialDevice(reauth) else { return XCTFail("409 attendu") }
        XCTAssertEqual(try first.accounts.load(ownerNamespace: namespace)?.rawRepresentation, local.rawRepresentation)
        XCTAssertFalse(try first.accounts.hasPendingBootstrap(ownerNamespace: namespace))
        // Le compte porte une autre UIK : celle d'un bootstrap perdu est retirée.
        try first.vault.remove(E2EEV2AccountIdentityStore.key(ownerNamespace: namespace))
        served.value = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        guard case .failed = await first.lifecycle.bootstrapInitialDevice(reauth) else { return XCTFail("409 attendu") }
        XCTAssertNil(try first.accounts.load(ownerNamespace: namespace))
        let other = P256.Signing.PrivateKey()
        XCTAssertNoThrow(try first.accounts.install(other, ownerNamespace: namespace))
        // Une UIK reçue n'est jamais retirée par un bootstrap.
        try first.accounts.discardPendingBootstrap(ownerNamespace: namespace)
        XCTAssertEqual(try first.accounts.load(ownerNamespace: namespace)?.rawRepresentation, other.rawRepresentation)
    }
}

private final class LockedBoxA1<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
