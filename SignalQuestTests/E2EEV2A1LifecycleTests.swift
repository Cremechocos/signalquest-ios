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

    private func device(_ fixture: E2EEV2AccountFixture, primary: Bool) throws -> Device {
        let vault = primary ? fixture.vault : InMemoryTokenStore()
        let identity = primary ? fixture.identity : E2EEV2DeviceIdentityStore(tokenStore: vault, allowsOwner: { _ in true })
        let descriptor = primary ? fixture.descriptor : try identity.loadOrCreate(ownerNamespace: fixture.session.ownerNamespace)
        let accounts = E2EEV2AccountIdentityStore(tokenStore: vault, allowsOwner: { _ in true })
        let now = self.now
        return Device(
            identity: identity, accounts: accounts, vault: vault, descriptor: descriptor,
            lifecycle: E2EEV2DeviceLifecycleCoordinator(
                api: fixture.api, identityStore: identity, epochKeyStore: fixture.keys,
                conversationStateStore: fixture.states, accountIdentityStore: accounts,
                trustPins: E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore()), nowMs: { now },
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

        // 3. Le second appareil reçoit l'UIK du compte, non vérifiée.
        guard case .success(.approved) = await second.lifecycle.receiveApprovedTrust(approvalId: Self.approvalId) else {
            return XCTFail("UIK reçue")
        }
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

    /// Un autre appareil a établi le compte pendant ce bootstrap : l'UIK créée
    /// ici est retirée, celle du compte pourra être installée à l'approbation.
    func testALostBootstrapRaceDiscardsTheLocalAccountKey() async throws {
        let fixture = try E2EEV2AccountFixture()
        defer { fixture.close() }
        let first = try device(fixture, primary: true)
        let namespace = fixture.session.ownerNamespace
        MockURLProtocol.requestHandler = { request in
            E2EEV2AccountFixture.response(request, try JSONSerialization.data(withJSONObject: [
                "error": "x", "code": "E2EE_IDENTITY_ALREADY_ESTABLISHED", "requestId": "r",
            ]), status: 409)
        }
        guard case .failed = await first.lifecycle.bootstrapInitialDevice(
            .email(challengeId: "challenge_000000000001", code: "123456")
        ) else { return XCTFail("409 attendu") }
        XCTAssertNil(try first.accounts.load(ownerNamespace: namespace))
        let other = P256.Signing.PrivateKey()
        XCTAssertNoThrow(try first.accounts.install(other, ownerNamespace: namespace))
        // Une UIK reçue n'est jamais retirée par un bootstrap.
        try first.accounts.discardPendingBootstrap(ownerNamespace: namespace)
        XCTAssertEqual(try first.accounts.load(ownerNamespace: namespace)?.rawRepresentation, other.rawRepresentation)
    }
}
