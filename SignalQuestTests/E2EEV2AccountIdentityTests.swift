import CryptoKit
import XCTest
@testable import SignalQuest

/// IOS-A1 (plan 3, jalon A) : clé de compte (UIK) créée au premier appareil,
/// et objets signés du bootstrap étendu (spec §2.1, §2.2, §12 et E.1).
final class E2EEV2AccountIdentityTests: XCTestCase {
    fileprivate let now: Int64 = 1_790_000_000_000
    fileprivate let userId = "user_alice_01J7ABCD2345"
    private let namespace = "ns-alice"

    func testTheAccountKeyIsCreatedOnceAndStaysInItsAccount() throws {
        let tokens = InMemoryTokenStore()
        let store = E2EEV2AccountIdentityStore(tokenStore: tokens) { $0 == "ns-alice" }
        XCTAssertNil(try store.load(ownerNamespace: namespace))

        let created = try store.create(ownerNamespace: namespace)
        XCTAssertEqual(try store.load(ownerNamespace: namespace)?.rawRepresentation, created.rawRepresentation)
        XCTAssertThrowsError(try store.create(ownerNamespace: namespace)) {
            XCTAssertEqual($0 as? E2EEV2AccountIdentityStore.Failure, .alreadyExists, "Jamais une UIK par-dessus une autre")
        }
        XCTAssertThrowsError(try store.load(ownerNamespace: "ns-other")) {
            XCTAssertEqual($0 as? E2EEV2AccountIdentityStore.Failure, .otherAccount)
        }
        XCTAssertThrowsError(try store.install(P256.Signing.PrivateKey(), ownerNamespace: "ns-other"))
        XCTAssertThrowsError(try store.install(P256.Signing.PrivateKey(), ownerNamespace: namespace)) {
            XCTAssertEqual($0 as? E2EEV2AccountIdentityStore.Failure, .alreadyExists, "Une UIK reçue n'écrase jamais l'autre")
        }
        XCTAssertNoThrow(try store.install(created, ownerNamespace: namespace), "La même clé, idempotente")

        try tokens.set("pas une clé", for: E2EEV2AccountIdentityStore.key(ownerNamespace: namespace), accessibility: .whenUnlocked)
        XCTAssertThrowsError(try store.load(ownerNamespace: namespace)) {
            XCTAssertEqual($0 as? E2EEV2AccountIdentityStore.Failure, .invalidRecord)
        }
    }

    func testTheAccountErasurePurgesTheAccountKey() throws {
        let tokens = InMemoryTokenStore()
        let store = E2EEV2AccountIdentityStore(tokenStore: tokens) { _ in true }
        let ownerScopeId = "user:\(userId)"
        let ownNamespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        _ = try store.create(ownerNamespace: ownNamespace)
        _ = try store.create(ownerNamespace: "ns-other")

        try E2EEV2VaultBoundary.purge(store: tokens, ownerScopeId: ownerScopeId)
        XCTAssertNil(try store.load(ownerNamespace: ownNamespace))
        XCTAssertNotNil(try store.load(ownerNamespace: "ns-other"), "Les autres comptes gardent leur clé")
    }

    /// §2.3 : le premier appareil a créé la clé du compte ; un appareil approuvé
    /// la reçoit « non vérifiée » jusqu'à la comparaison des 30 chiffres du compte.
    func testAnApprovedDeviceHoldsAnUnverifiedAccountKeyUntilCompared() throws {
        let tokens = InMemoryTokenStore()
        let store = E2EEV2AccountIdentityStore(tokenStore: tokens) { _ in true }
        let created = try store.create(ownerNamespace: namespace)
        XCTAssertTrue(try store.isVerified(ownerNamespace: namespace), "Créée ici : rien à comparer")

        try store.install(created, ownerNamespace: "ns-approved")
        XCTAssertFalse(try store.isVerified(ownerNamespace: "ns-approved"), "Reçue à l'approbation : non vérifiée")
        try store.install(created, ownerNamespace: "ns-approved")
        XCTAssertFalse(try store.isVerified(ownerNamespace: "ns-approved"), "Réinstaller ne la vérifie pas")
        try store.markVerified(ownerNamespace: "ns-approved")
        XCTAssertTrue(try store.isVerified(ownerNamespace: "ns-approved"))
        XCTAssertThrowsError(try store.markVerified(ownerNamespace: "ns-empty"), "Pas de clé, rien à vérifier")

        try tokens.set("1", for: E2EEV2AccountIdentityStore.verifiedKey(ownerNamespace: "ns-stale"), accessibility: .whenUnlocked)
        try store.install(created, ownerNamespace: "ns-stale")
        XCTAssertFalse(try store.isVerified(ownerNamespace: "ns-stale"), "Un drapeau orphelin ne vérifie pas une clé reçue")

        let ownerScopeId = "user:\(userId)"
        let ownNamespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        _ = try store.create(ownerNamespace: ownNamespace)
        try E2EEV2VaultBoundary.purge(store: tokens, ownerScopeId: ownerScopeId)
        XCTAssertFalse(try store.isVerified(ownerNamespace: ownNamespace), "Effacée avec le compte")
        XCTAssertTrue(try store.isVerified(ownerNamespace: "ns-approved"), "Les autres comptes gardent la leur")
    }

    /// Ce que publie le premier appareil se vérifie comme le paquet de
    /// n'importe quel contact, jusqu'à l'UIK.
    func testTheFirstDeviceTrustVerifiesLikeAnyContactBundle() throws {
        let uik = P256.Signing.PrivateKey()
        let signing = P256.Signing.PrivateKey()
        let device = descriptor(signing: signing)
        let trust = try E2EEV2InitialTrust.make(
            userId: userId, device: device, uik: uik,
            signWithDevice: { try E2EEV2LowS.sign($0, with: signing) },
            kinds: ["TEXT", "EDIT", "TEXT"], features: ["voice", "calls"], nowMs: now
        )
        XCTAssertEqual(trust.accountIdentityKeyB64, uik.publicKey.x963Representation.base64EncodedString())

        var object = trust.bootstrapFields
        object["certificates"] = [try XCTUnwrap(object.removeValue(forKey: "certificate"))]
        object["capabilities"] = [trust.capabilitiesBody]
        object["pendingIdentityReset"] = NSNull()
        let bundle = try XCTUnwrap(E2EEV2IdentityBundle.parse(
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: object)) as? [String: Any]),
            userId: userId
        ))
        let outcome = try E2EEV2IdentityVerification.verify(bundle, pinned: nil).get()
        let certified = try XCTUnwrap(outcome.devices.first)
        XCTAssertEqual(outcome.devices.count, 1)
        XCTAssertEqual(outcome.pin.listVersion, 1)
        XCTAssertEqual(certified.deviceId, device.deviceId)
        XCTAssertEqual(certified.platform, "ios")
        XCTAssertEqual(certified.signingKey?.x963Representation, signing.publicKey.x963Representation)
        XCTAssertEqual(certified.capabilities?.kinds, ["EDIT", "TEXT"], "Triées et sans doublon")
        XCTAssertTrue(certified.supports("calls", nowMs: now))
    }

    func testTheFirstDeviceNeverSignsWhatOthersWouldRefuse() {
        let signing = P256.Signing.PrivateKey()
        func make(_ device: E2EEV2DeviceDescriptor, features: [String] = ["calls"]) throws -> E2EEV2InitialTrust.Artifacts {
            try E2EEV2InitialTrust.make(
                userId: userId, device: device, uik: P256.Signing.PrivateKey(),
                signWithDevice: { try E2EEV2LowS.sign($0, with: signing) },
                kinds: ["TEXT"], features: features, nowMs: now
            )
        }
        XCTAssertThrowsError(try make(descriptor(signing: signing), features: ["calls", "teleport"]),
                             "Capacité inconnue des autres plateformes")
        XCTAssertThrowsError(try make(descriptor(signing: signing, keyVersion: 0)))
        XCTAssertThrowsError(try make(descriptor(signing: signing, deviceId: "appareil ios")))
    }

    func testTheBootstrapBodyGainsTheTrustFieldsOnlyWhenGiven() throws {
        let signing = P256.Signing.PrivateKey()
        let device = descriptor(signing: signing)
        let trust = try E2EEV2InitialTrust.make(
            userId: userId, device: device, uik: P256.Signing.PrivateKey(),
            signWithDevice: { try E2EEV2LowS.sign($0, with: signing) },
            kinds: ["TEXT"], features: ["calls"], nowMs: now
        )
        func keys(_ data: Data) throws -> Set<String> {
            Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        }
        let plain = try E2EEV2DeviceApprovalContract.initialBootstrapData(
            deviceId: device.deviceId, reauthentication: .password("secret-de-test")
        )
        XCTAssertEqual(try keys(plain), ["version", "deviceId", "reauthentication"], "Corps actuel inchangé")

        let extended = try E2EEV2DeviceApprovalContract.initialBootstrapData(
            deviceId: device.deviceId, reauthentication: .password("secret-de-test"), trust: trust
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: extended) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "version", "deviceId", "reauthentication", "accountIdentityKeyB64", "certificate", "deviceList",
        ])
        XCTAssertEqual(Set(try XCTUnwrap(object["certificate"] as? [String: Any]).keys), ["certificate", "signatureB64"])
        XCTAssertEqual(Set(try XCTUnwrap(object["deviceList"] as? [String: Any]).keys), ["list", "signatureB64", "devices"])
        XCTAssertEqual(Set(trust.capabilitiesBody.keys), ["document", "signatureB64"])
    }

    // MARK: - Approbation d'un nouvel appareil (§2.3, D.1, E.1)

    /// Le nouvel appareil entre dans la liste suivante, chaînée à la
    /// précédente, et reçoit l'UIK du compte, lisible par lui seul.
    func testApprovalCertifiesTheNewDeviceAndHandsItTheAccountKey() throws {
        let first = try FirstDevice(test: self)
        let pinV1 = try E2EEV2IdentityVerification.verify(first.bundle(), pinned: nil).get().pin

        let tokens = InMemoryTokenStore()
        let newStore = E2EEV2DeviceIdentityStore(tokenStore: tokens, allowsOwner: { _ in true }, identityChanged: { _ in })
        let second = try newStore.loadOrCreate(ownerNamespace: "ns-new")
        let approval = try first.approve(second)

        let bundleV2 = try first.bundle(
            list: approval.deviceList, entries: approval.deviceEntries,
            extraCertificates: [approval.certificate]
        )
        let outcome = try E2EEV2IdentityVerification.verify(bundleV2, pinned: pinV1).get()
        XCTAssertEqual(outcome.pin.listVersion, 2, "Liste suivante, chaînée à la v1 épinglée")
        XCTAssertEqual(Set(outcome.devices.map(\.deviceId)), [first.device.deviceId, second.deviceId])

        let uik = try E2EEV2DeviceApprovalTrust.accept(
            approval.uikWrap, account: outcome, userId: userId, device: second
        ) { wrap, approverKey, expected in
            try newStore.unwrapAccountIdentityKey(
                wrap, approverSigningKey: approverKey, expectedUIKB64: expected, ownerNamespace: "ns-new"
            )
        }
        XCTAssertEqual(uik.rawRepresentation, first.uik.rawRepresentation)
    }

    func testApprovalSignsOnlyWhatTheUserCompared() throws {
        let first = try FirstDevice(test: self)
        let newcomer = descriptor(signing: P256.Signing.PrivateKey(), deviceId: "device_alice_web_01J7ABCD")
        XCTAssertThrowsError(try first.approve(newcomer, expectedFingerprint: "empreinte-affichée-ailleurs")) {
            XCTAssertEqual($0 as? E2EEV2DeviceApprovalTrust.Failure, .fingerprintMismatch)
        }
        XCTAssertThrowsError(try first.approve(newcomer, comparedPlatform: "web")) {
            XCTAssertEqual($0 as? E2EEV2DeviceApprovalTrust.Failure, .platformMismatch,
                           "Le serveur annonce un iPhone, l'utilisateur a vu un navigateur")
        }
        XCTAssertThrowsError(try first.approve(first.device)) {
            XCTAssertEqual($0 as? E2EEV2DeviceApprovalTrust.Failure, .alreadyListed)
        }
        XCTAssertThrowsError(try first.approve(newcomer, uik: P256.Signing.PrivateKey())) {
            XCTAssertEqual($0 as? E2EEV2DeviceApprovalTrust.Failure, .foreignList, "Liste d'un autre compte")
        }
        XCTAssertThrowsError(try first.approve(newcomer, approverDeviceId: "device_alice_ipad_01J7ABCD")) {
            XCTAssertEqual($0 as? E2EEV2DeviceApprovalTrust.Failure, .approverNotListed)
        }
    }

    func testTheNewDeviceTakesTheKeyOnlyFromACertifiedApprover() throws {
        let first = try FirstDevice(test: self)
        let newStore = E2EEV2DeviceIdentityStore(tokenStore: InMemoryTokenStore(), allowsOwner: { _ in true }, identityChanged: { _ in })
        let second = try newStore.loadOrCreate(ownerNamespace: "ns-new")
        let approval = try first.approve(second)
        let unwrap: (E2EEV2UIKWrap, P256.Signing.PublicKey, String) throws -> P256.Signing.PrivateKey = {
            try newStore.unwrapAccountIdentityKey($0, approverSigningKey: $1, expectedUIKB64: $2, ownerNamespace: "ns-new")
        }

        // Paquet encore à la v1 : le compte ne certifie pas (encore) ce nouvel appareil.
        let v1 = try E2EEV2IdentityVerification.verify(first.bundle(), pinned: nil).get()
        XCTAssertThrowsError(try E2EEV2DeviceApprovalTrust.accept(approval.uikWrap, account: v1, userId: userId, device: second, unwrap: unwrap)) {
            XCTAssertEqual($0 as? E2EEV2DeviceApprovalTrust.Failure, .notCertified)
        }

        // Un « approbateur » que le compte ne connaît pas.
        let outcome = try E2EEV2IdentityVerification.verify(
            first.bundle(list: approval.deviceList, entries: approval.deviceEntries, extraCertificates: [approval.certificate]),
            pinned: nil
        ).get()
        let stranger = try E2EEV2UIKWrapCrypto.wrap(
            uik: first.uik, userId: userId, approverDeviceId: "device_mallory_ios_01J7ABCD", newDeviceId: second.deviceId,
            newDeviceAgreementKey: P256.KeyAgreement.PublicKey(x963Representation: XCTUnwrap(Data(base64Encoded: second.publicIdentityKeyB64))),
            approverSigningKey: P256.Signing.PrivateKey(), nonce: Data(repeating: 7, count: 12)
        )
        XCTAssertThrowsError(try E2EEV2DeviceApprovalTrust.accept(stranger, account: outcome, userId: userId, device: second, unwrap: unwrap)) {
            XCTAssertEqual($0 as? E2EEV2DeviceApprovalTrust.Failure, .approverNotListed)
        }
    }

    func testTheApprovalBodyGainsTheTrustFieldsOnlyWhenGiven() throws {
        let first = try FirstDevice(test: self)
        let newcomer = descriptor(signing: P256.Signing.PrivateKey(), deviceId: "device_alice_web_01J7ABCD")
        let approval = try first.approve(newcomer)
        func detail(pendingDeviceId: String) -> E2EEV2ApprovalDetail {
            E2EEV2ApprovalDetail(
                approval: .init(id: "approval_alice_00001", pendingDeviceId: pendingDeviceId, method: .qr,
                    challengeB64URL: String(repeating: "A", count: 43), proximityCode: nil, status: .pending,
                    expiresAt: "2026-10-01T02:00:00.000Z", createdAt: "2026-10-01T01:55:00.000Z"),
                pendingDevice: .init(descriptor: newcomer, status: .pending, approvedAt: nil, revokedAt: nil,
                    lastSeenAt: nil, createdAt: "2026-10-01T01:55:00.000Z")
            )
        }
        func keys(_ data: Data) throws -> Set<String> {
            Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        }
        XCTAssertEqual(try keys(E2EEV2DeviceApprovalContract.approvalCompletionData(detail(pendingDeviceId: newcomer.deviceId))),
                       ["pendingDeviceId", "challengeB64Url"], "Corps actuel inchangé")
        let body = try E2EEV2DeviceApprovalContract.approvalCompletionData(detail(pendingDeviceId: newcomer.deviceId), trust: approval)
        XCTAssertEqual(try keys(body), ["pendingDeviceId", "challengeB64Url", "certificate", "deviceList", "uikWrap"])
        let wrap = try XCTUnwrap((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["uikWrap"] as? [String: Any])
        XCTAssertEqual(Set(wrap.keys), [
            "userId", "approverDeviceId", "newDeviceId", "uikPublicKeyB64", "ephemeralPublicKeyB64",
            "nonceB64", "aadB64", "wrappedUikB64", "signatureB64",
        ])
        XCTAssertThrowsError(try E2EEV2DeviceApprovalContract.approvalCompletionData(
            detail(pendingDeviceId: "device_alice_other_01J7ABCD"), trust: approval
        ), "Une approbation ne porte que les objets de son appareil")
    }

    /// Révocation : la liste suivante ne contient plus l'appareil, et reste
    /// chaînée à la précédente.
    func testRevocationListDropsOnlyTheRevokedDevice() throws {
        let first = try FirstDevice(test: self)
        let second = descriptor(signing: P256.Signing.PrivateKey(), deviceId: "device_alice_web_01J7ABCD")
        let approval = try first.approve(second)
        let pinV2 = try E2EEV2IdentityVerification.verify(
            first.bundle(list: approval.deviceList, entries: approval.deviceEntries, extraCertificates: [approval.certificate]),
            pinned: nil
        ).get().pin

        let revocation = try E2EEV2DeviceRevocationTrust.make(
            userId: userId, revokedDeviceId: second.deviceId, currentList: approval.deviceList,
            currentEntries: approval.deviceEntries, uik: first.uik, nowMs: now + 120_000
        )
        XCTAssertEqual(revocation.deviceEntries, first.trust.deviceEntries)
        let outcome = try E2EEV2IdentityVerification.verify(
            first.bundle(list: revocation.deviceList, entries: revocation.deviceEntries), pinned: pinV2
        ).get()
        XCTAssertEqual(outcome.pin.listVersion, 3)
        XCTAssertEqual(outcome.devices.map(\.deviceId), [first.device.deviceId])

        XCTAssertThrowsError(try E2EEV2DeviceRevocationTrust.make(
            userId: userId, revokedDeviceId: "device_alice_ipad_01J7ABCD", currentList: approval.deviceList,
            currentEntries: approval.deviceEntries, uik: first.uik, nowMs: now
        ), "Appareil absent de la liste")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: E2EEV2DeviceApprovalContract.revocationData(reason: "USER_REQUEST", trust: revocation)
        ) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["version", "reason", "deviceList"])
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(
            with: E2EEV2DeviceApprovalContract.revocationData(reason: "USER_REQUEST")
        ) as? [String: Any]).keys), ["version", "reason"], "Corps actuel inchangé")
    }

    /// Premier appareil d'Alice : son UIK, ses clés et ses objets signés (v1).
    private struct FirstDevice {
        let userId: String
        let now: Int64
        let uik = P256.Signing.PrivateKey()
        let signing = P256.Signing.PrivateKey()
        let device: E2EEV2DeviceDescriptor
        let trust: E2EEV2InitialTrust.Artifacts

        init(test: E2EEV2AccountIdentityTests) throws {
            userId = test.userId
            now = test.now
            device = test.descriptor(signing: signing)
            let signing = self.signing
            trust = try E2EEV2InitialTrust.make(
                userId: userId, device: device, uik: uik,
                signWithDevice: { try E2EEV2LowS.sign($0, with: signing) },
                kinds: ["TEXT"], features: ["calls"], nowMs: now
            )
        }

        func approve(
            _ newcomer: E2EEV2DeviceDescriptor,
            expectedFingerprint: String? = nil,
            comparedPlatform: String? = nil,
            uik: P256.Signing.PrivateKey? = nil,
            approverDeviceId: String? = nil
        ) throws -> E2EEV2DeviceApprovalTrust.Artifacts {
            let fingerprint = E2EEV2Canonical.deviceFingerprint(
                identityKeyX963: Data(base64Encoded: newcomer.publicIdentityKeyB64) ?? Data(),
                signingKeyX963: Data(base64Encoded: newcomer.publicSigningKeyB64) ?? Data()
            )
            let signing = self.signing
            return try E2EEV2DeviceApprovalTrust.make(
                userId: userId, currentList: trust.deviceList, currentEntries: trust.deviceEntries,
                newDevice: newcomer, expectedFingerprint: expectedFingerprint ?? fingerprint,
                comparedPlatform: comparedPlatform ?? newcomer.platform,
                uik: uik ?? self.uik, approverDeviceId: approverDeviceId ?? device.deviceId,
                signWithApprover: { try E2EEV2LowS.sign($0, with: signing) },
                nonce: Data(repeating: 9, count: 12), nowMs: now + 60_000
            )
        }

        /// Paquet E.1 du compte, tel que le serveur le servirait.
        func bundle(
            list: E2EEV2SignedString? = nil,
            entries: [String]? = nil,
            extraCertificates: [E2EEV2SignedString] = []
        ) throws -> E2EEV2IdentityBundle {
            let list = list ?? trust.deviceList
            let object: [String: Any] = [
                "accountIdentityKeyB64": trust.accountIdentityKeyB64,
                "deviceList": ["list": list.canonical, "signatureB64": list.signatureB64, "devices": entries ?? trust.deviceEntries],
                "certificates": ([trust.certificate] + extraCertificates).map {
                    ["certificate": $0.canonical, "signatureB64": $0.signatureB64]
                },
                "capabilities": [trust.capabilitiesBody],
                "pendingIdentityReset": NSNull(),
            ]
            return try XCTUnwrap(E2EEV2IdentityBundle.parse(object, userId: userId))
        }
    }

    // MARK: - Outils

    fileprivate func descriptor(
        signing: P256.Signing.PrivateKey,
        deviceId: String = "device_alice_ios_01J7ABCD",
        keyVersion: Int = 1
    ) -> E2EEV2DeviceDescriptor {
        E2EEV2DeviceDescriptor(
            deviceId: deviceId,
            platform: "ios",
            label: "iPhone",
            publicIdentityKeyB64: P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString(),
            publicSigningKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            identityKeyAlgorithm: E2EEV2DeviceIdentityStore.identityKeyAlgorithm,
            signingKeyAlgorithm: E2EEV2DeviceIdentityStore.signingKeyAlgorithm,
            keyVersion: keyVersion
        )
    }
}
