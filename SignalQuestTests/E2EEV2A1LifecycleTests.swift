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

    /// §12 : le document de capacités part dès que l'appareil détient la clé
    /// du compte, signé par lui ; il ne repart qu'avec un nouveau build ; une
    /// séquence dépassée repart au-dessus de celle du serveur.
    func testTheCapabilitiesDocumentIsPublishedOnceAndOnANewBuild() async throws {
        let fixture = try E2EEV2AccountFixture()
        defer { fixture.close() }
        let first = try device(fixture, primary: true)
        let server = TrustServer()
        install(server, pending: first.descriptor)
        _ = try first.accounts.create(ownerNamespace: fixture.session.ownerNamespace)
        guard case .success(true) = await first.lifecycle.publishCapabilitiesIfNeeded() else { return XCTFail("Premier document") }
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
