import CryptoKit
import XCTest
@testable import SignalQuest

/// IOS-A1 (plan 3, jalon A) : clé de compte (UIK) créée au premier appareil,
/// et objets signés du bootstrap étendu (spec §2.1, §2.2, §12 et E.1).
final class E2EEV2AccountIdentityTests: XCTestCase {
    private let now: Int64 = 1_790_000_000_000
    private let userId = "user_alice_01J7ABCD2345"
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

    // MARK: - Outils

    private func descriptor(
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
