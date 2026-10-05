import CryptoKit
import Security
import XCTest
@testable import SignalQuest

/// Lot A1 « confiance » du serveur (PR #259, formes figées le 02/10) : détails
/// d'erreur, versions de clé, dépôt de confiance d'une approbation, cible signée.
final class E2EEV2A1ContractTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func device(_ descriptor: E2EEV2DeviceDescriptor, keyVersion: Any = 1, platform: String? = nil) -> [String: Any] {
        [
            "deviceId": descriptor.deviceId, "platform": platform ?? descriptor.platform, "label": NSNull(),
            "publicIdentityKeyB64": descriptor.publicIdentityKeyB64, "publicSigningKeyB64": descriptor.publicSigningKeyB64,
            "identityKeyAlgorithm": descriptor.identityKeyAlgorithm, "signingKeyAlgorithm": descriptor.signingKeyAlgorithm,
            "keyVersion": keyVersion, "status": "pending", "approvedAt": NSNull(), "revokedAt": NSNull(),
            "lastSeenAt": NSNull(), "createdAt": "2026-10-02T00:00:00.000Z",
        ]
    }

    private func descriptor() throws -> E2EEV2DeviceDescriptor {
        try E2EEV2DeviceIdentityStore(tokenStore: InMemoryTokenStore(), allowsOwner: { _ in true })
            .loadOrCreate(ownerNamespace: "account-a1")
    }

    func testARecertifiedDeviceIsReadWithItsKeyVersion() throws {
        let pending = try descriptor()
        let two = try JSONSerialization.data(withJSONObject: ["devices": [device(pending, keyVersion: 2)]])
        XCTAssertEqual(E2EEV2DeviceApprovalContract.parseDevices(two)?.first?.descriptor.keyVersion, 2)
        for invalid: Any in [0, true, 1.5, "2"] {
            let data = try JSONSerialization.data(withJSONObject: ["devices": [device(pending, keyVersion: invalid)]])
            XCTAssertNil(E2EEV2DeviceApprovalContract.parseDevices(data), "keyVersion \(invalid)")
        }
    }

    private func approval(_ pending: E2EEV2DeviceDescriptor, status: String, challenge: Any) -> [String: Any] {
        [
            "id": "approval_0000000000000001", "pendingDeviceId": pending.deviceId, "method": "QR",
            "challengeB64Url": challenge, "proximityCode": NSNull(), "status": status,
            "expiresAt": "2026-10-02T00:10:00.000Z", "createdAt": "2026-10-02T00:00:00.000Z",
        ]
    }

    private let wrap: [String: Any] = [
        "userId": "user_a1", "approverDeviceId": "ios_approver_000000000001", "newDeviceId": "",
        "uikPublicKeyB64": "BAAA", "ephemeralPublicKeyB64": "BBBB", "nonceB64": "CCCC", "aadB64": "DDDD",
        "wrappedUikB64": "EEEE", "signatureB64": "FFFF",
    ]

    func testTheApprovalTrustDepositFollowsTheServerStates() throws {
        let pending = try descriptor()
        let challenge = String(repeating: "A", count: 43)
        func parse(_ root: [String: Any]) throws -> E2EEV2ApprovalDetail? {
            E2EEV2DeviceApprovalContract.parseApprovalDetail(try JSONSerialization.data(withJSONObject: root))
        }
        var uikWrap = wrap
        uikWrap["newDeviceId"] = pending.deviceId
        let certificate: [String: Any] = ["certificate": "SQ-E2EE-V2-DEVICE-CERT\n1", "signatureB64": "MEUC"]
        let list: [String: Any] = ["list": "SQ-E2EE-V2-DEVICE-LIST\n1", "signatureB64": "MEUC", "devices": ["entry"]]

        // En attente : le dépôt est nul.
        let waiting = try XCTUnwrap(parse([
            "approval": approval(pending, status: "pending", challenge: challenge), "pendingDevice": device(pending),
            "certificate": NSNull(), "deviceList": NSNull(), "uikWrap": NSNull(),
        ]))
        XCTAssertNil(waiting.trust)
        // Approuvée : le défi est effacé, le dépôt rempli.
        let approved = try XCTUnwrap(parse([
            "approval": approval(pending, status: "approved", challenge: NSNull()), "pendingDevice": device(pending),
            "certificate": certificate, "deviceList": list, "uikWrap": uikWrap,
        ]))
        XCTAssertEqual(approved.trust?.uikWrap?.newDeviceId, pending.deviceId)
        XCTAssertEqual(approved.trust?.deviceEntries, ["entry"])
        // Navigateur : jamais d'UIK.
        let browser = try XCTUnwrap(parse([
            "approval": approval(pending, status: "approved", challenge: NSNull()), "pendingDevice": device(pending, platform: "web"),
            "certificate": certificate, "deviceList": list, "uikWrap": NSNull(),
        ]))
        XCTAssertNotNil(browser.trust)
        XCTAssertNil(browser.trust?.uikWrap)
        XCTAssertNil(try parse([
            "approval": approval(pending, status: "approved", challenge: NSNull()), "pendingDevice": device(pending, platform: "web"),
            "certificate": certificate, "deviceList": list, "uikWrap": uikWrap,
        ]), "Une UIK pour un navigateur est refusée")
        XCTAssertNil(try parse([
            "approval": approval(pending, status: "approved", challenge: NSNull()), "pendingDevice": device(pending),
            "certificate": certificate, "deviceList": list, "uikWrap": wrap.merging(["newDeviceId": "ios_other_000000000001"]) { $1 },
        ]), "Une UIK destinée à un autre appareil est refusée")
        // Dépôt consommé ou expiré : de nouveau nul, l'approbation reste lisible.
        XCTAssertNil(try XCTUnwrap(parse([
            "approval": approval(pending, status: "approved", challenge: NSNull()), "pendingDevice": device(pending),
            "certificate": NSNull(), "deviceList": NSNull(), "uikWrap": NSNull(),
        ])).trust)
        // Un dépôt partiel, une clé de trop ou une UIK à dix clés : refusés.
        XCTAssertNil(try parse([
            "approval": approval(pending, status: "approved", challenge: NSNull()), "pendingDevice": device(pending),
            "certificate": certificate, "deviceList": NSNull(), "uikWrap": uikWrap,
        ]))
        var tooMany = uikWrap
        tooMany["extra"] = "x"
        XCTAssertNil(try parse([
            "approval": approval(pending, status: "approved", challenge: NSNull()), "pendingDevice": device(pending),
            "certificate": certificate, "deviceList": list, "uikWrap": tooMany,
        ]))
        XCTAssertNil(try parse([
            "approval": approval(pending, status: "pending", challenge: NSNull()), "pendingDevice": device(pending),
            "certificate": NSNull(), "deviceList": NSNull(), "uikWrap": NSNull(),
        ]), "En attente, le défi reste obligatoire")
    }

    func testTheSignedTargetEncodesEverythingButUnreservedCharacters() {
        XCTAssertEqual(
            E2EEV2SignedTarget.encodedQuery([URLQueryItem(name: "q", value: "a+b c@d'é"), URLQueryItem(name: "sinceVersion", value: "3")]),
            "q=a%2Bb%20c%40d%27%C3%A9&sinceVersion=3"
        )
        XCTAssertNil(E2EEV2SignedTarget.encodedQuery([]))
        XCTAssertTrue(E2EEV2SignedTarget.isEncodedPath("/api/e2ee/v2/users/user_0123456789abcdef/identity"))
        XCTAssertFalse(E2EEV2SignedTarget.isEncodedPath("/api/e2ee/v2/users/a b/identity"))
        XCTAssertFalse(E2EEV2SignedTarget.isEncodedPath("/api//identity"))
    }

    /// §2.8 : après une approbation ou une révocation, seul un bundle actif
    /// déjà signé par l'UIK d'ici est re-signé. Un bundle servi avec la clé
    /// publique de notre UIK mais une autre signature, ou sans signature, ne
    /// l'est jamais : le serveur ferait sinon certifier sa propre clé.
    func testOnlyABundleAlreadySignedByOurAccountKeyIsResigned() throws {
        let owner = "user:a1-resign"
        let uik = P256.Signing.PrivateKey()
        let material = try E2EEV2RecoveryV2Crypto.generateMaterial(ownerBinding: owner, accountKey: uik)
        func served(signedBy key: P256.Signing.PrivateKey?, version: Int = 3) throws -> Data {
            let signature = try key.map {
                try E2EEV2LowS.sign(E2EEV2RecoveryV2Crypto.bundleSignatureCanonical(
                    userId: "a1-resign", bundle: material.bundle, deviceListVersion: version
                ), with: $0).base64EncodedString()
            } ?? ""
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: E2EEV2RecoveryV2Contract.uploadData(
                material.bundle, signatureB64: signature, deviceListVersion: version
            )) as? [String: Any])
            object["createdAt"] = "2026-10-05T20:00:00.000Z"
            object["rotatedAt"] = NSNull()
            object["revokedAt"] = NSNull()
            return try JSONSerialization.data(withJSONObject: ["bundle": object, "state": "AVAILABLE"])
        }
        let ours = try XCTUnwrap(E2EEV2RecoveryV2Contract.activeBundleSignedBy(
            try served(signedBy: uik), uik: uik.publicKey, ownerScopeId: owner
        ))
        XCTAssertEqual(ours.listVersion, 3)
        XCTAssertNil(E2EEV2RecoveryV2Contract.activeBundleSignedBy(
            try served(signedBy: P256.Signing.PrivateKey()), uik: uik.publicKey, ownerScopeId: owner
        ), "Signé par une autre clé : jamais re-signé")
        XCTAssertNil(E2EEV2RecoveryV2Contract.activeBundleSignedBy(
            try served(signedBy: nil), uik: uik.publicKey, ownerScopeId: owner
        ), "Sans signature : jamais re-signé")
    }

    /// Une requête signée automatique (rotation, lecture) ne crée jamais
    /// l'identité d'appareil : seul l'enregistrement demandé la crée.
    func testASignedRequestNeverCreatesTheDeviceIdentity() throws {
        let store = E2EEV2DeviceIdentityStore(
            tokenStore: InMemoryTokenStore(), allowsOwner: { _ in true },
            identityChanged: { _ in XCTFail("Aucune identité ne doit naître d'une signature") }
        )
        XCTAssertThrowsError(try store.signWithDeviceId(canonicalRequest: Data("GET\n/".utf8), ownerNamespace: "user:a1-sign"))
        XCTAssertNil(try store.load(ownerNamespace: "user:a1-sign"))
        // Le chemin du transport, qui signe chaque requête v2, non plus.
        XCTAssertThrowsError(try E2EEV2SignedRequest.signBodyHash(
            method: "GET", path: "/api/e2ee/v2/epoch-rotation-requirements",
            bodySHA256Base64URL: "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU",
            ownerNamespace: "user:a1-sign", identityStore: store
        ))
        XCTAssertNil(try store.load(ownerNamespace: "user:a1-sign"))
    }

    /// E.1 : lecture par session, sans signature ; lire un membre ne crée
    /// jamais d'identité d'appareil, et un 404 devient le refus de ce membre.
    func testAnIdentityIsReadBySessionWithoutCreatingADevice() async throws {
        let previousUserId = LocalAccountScope.currentUserId
        LocalAccountScope.activate(userId: "a1-identity")
        defer { if let previousUserId { LocalAccountScope.activate(userId: previousUserId) } else { LocalAccountScope.deactivate() } }
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let store = E2EEV2DeviceIdentityStore(tokenStore: InMemoryTokenStore(), allowsOwner: { _ in true })
        let seen = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            seen.append(request, body: [:])
            let notFound = request.url?.path.contains("user_hidden") == true
            let body = try JSONSerialization.data(withJSONObject: notFound
                ? ["error": "x", "code": "E2EE_IDENTITY_NOT_FOUND", "requestId": "r"]
                : ["accountIdentityKeyB64": "x"])
            return (HTTPURLResponse(url: request.url!, statusCode: notFound ? 404 : 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("a1-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let fetch = E2EEV2TrustDirectory.identityFetch(
            transport: E2EEV2APITransport(api: api, identityStore: store), ownerScopeId: session.ownerScopeId
        )

        _ = try await fetch("user_member_00000000001", 3)
        let request = try XCTUnwrap(seen.first?.0)
        XCTAssertEqual(request.url?.path, "/api/e2ee/v2/users/user_member_00000000001/identity")
        XCTAssertEqual(request.url?.query, "sinceVersion=3")
        XCTAssertNil(request.value(forHTTPHeaderField: E2EEV2SignedRequest.headerSignature), "Lecture par session")
        XCTAssertNotNil(request.value(forHTTPHeaderField: ClientProtocolContract.capabilitiesHeaderName))
        XCTAssertNil(try store.load(ownerNamespace: session.ownerNamespace), "Aucune identité créée par une lecture")

        do {
            _ = try await fetch("user_hidden_00000000001", nil)
            XCTFail("404 attendu")
        } catch {
            XCTAssertEqual(error as? E2EEV2TrustDirectory.IdentityNotFound, E2EEV2TrustDirectory.IdentityNotFound())
        }
        XCTAssertNil(seen.all.last?.0.url?.query, "Sans pin, pas de sinceVersion")
    }

    /// La requête part telle qu'elle est signée, et `E2EE_DEVICE_LIST_STALE`
    /// garde les membres dont relire l'identité.
    func testTheWireTargetMatchesTheSignatureAndStaleDetailsSurvive() async throws {
        let previousUserId = LocalAccountScope.currentUserId
        LocalAccountScope.activate(userId: "a1-target")
        defer { if let previousUserId { LocalAccountScope.activate(userId: previousUserId) } else { LocalAccountScope.deactivate() } }
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let store = E2EEV2DeviceIdentityStore(tokenStore: InMemoryTokenStore(), allowsOwner: { _ in true })
        _ = try store.loadOrCreate(ownerNamespace: session.ownerNamespace)
        let seen = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            seen.append(request, body: [:])
            let body = try JSONSerialization.data(withJSONObject: [
                "error": "stale", "code": "E2EE_DEVICE_LIST_STALE", "requestId": "r",
                "details": ["userId": "user_member_00000000001", "userIds": ["user_member_00000000001", "user_member_00000000002"]],
            ])
            return (HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("a1-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let result = await E2EEV2APITransport(api: api, identityStore: store).getJSON(
            path: "/api/e2ee/v2/devices", query: [URLQueryItem(name: "q", value: "a+b c")],
            expectedOwnerScopeId: session.ownerScopeId, capabilitySet: .deviceLifecycle
        )
        let request = try XCTUnwrap(seen.first?.0)
        XCTAssertEqual(request.url?.query, "q=a%2Bb%20c")
        guard case .failure(let failure) = result else { return XCTFail("409 attendu") }
        XCTAssertEqual(failure.code, "E2EE_DEVICE_LIST_STALE")
        XCTAssertEqual(failure.staleUserIds, ["user_member_00000000001", "user_member_00000000002"])
    }
}
