import CryptoKit
import XCTest
@testable import SignalQuest

/// IOS-A1 (plan 3, jalon A) : du paquet de confiance servi par le serveur
/// (E.1) aux appareils certifiés d'un compte (§2.2, §12).
final class E2EEV2IdentityVerificationTests: XCTestCase {
    private let userId = "user_bruno_01J7ABCD23456789"
    private let now: Int64 = 1_790_000_000_000

    private struct Device {
        let id: String
        let platform: String
        let keyVersion: Int
        let identity = P256.KeyAgreement.PrivateKey()
        let signing = P256.Signing.PrivateKey()

        var identityB64: String { identity.publicKey.x963Representation.base64EncodedString() }
        var signingB64: String { signing.publicKey.x963Representation.base64EncodedString() }
        var fingerprint: String {
            E2EEV2Canonical.deviceFingerprint(
                identityKeyX963: identity.publicKey.x963Representation,
                signingKeyX963: signing.publicKey.x963Representation
            )
        }
        var entry: String {
            E2EEV2DeviceList.entry(deviceId: id, keyVersion: keyVersion, platform: platform, fingerprint: fingerprint)
        }
    }

    private let phone = Device(id: "device_bruno_ios_01J7ABCD", platform: "ios", keyVersion: 1)
    private let tablet = Device(id: "device_bruno_ipad_01J7ABCD", platform: "ios", keyVersion: 2)

    func testFirstContactPinsTheAccountAndCertifiesItsListedDevices() throws {
        let uik = P256.Signing.PrivateKey()
        let (bundle, _) = try makeBundle(uik: uik, devices: [phone, tablet], version: 1, previous: nil,
                                         capabilities: [(phone, 1, now - 1_000, ["calls"])])
        let outcome = try XCTUnwrap(try? E2EEV2IdentityVerification.verify(bundle, pinned: nil).get())

        XCTAssertEqual(outcome.devices.map(\.deviceId), [tablet.id, phone.id].sorted())
        let certifiedPhone = try XCTUnwrap(outcome.devices.first { $0.deviceId == phone.id })
        XCTAssertEqual(certifiedPhone.signingKey?.x963Representation, phone.signing.publicKey.x963Representation)
        XCTAssertTrue(certifiedPhone.supports("calls", nowMs: now))
        let certifiedTablet = try XCTUnwrap(outcome.devices.first { $0.deviceId == tablet.id })
        XCTAssertTrue(certifiedTablet.isSidelined(nowMs: now), "Sans document de capacités, mis à l'écart")
        XCTAssertEqual(outcome.pin.uikX963B64, uik.publicKey.x963Representation.base64EncodedString())
        XCTAssertEqual(outcome.pin.listVersion, 1)
        XCTAssertEqual(outcome.pin.capabilitySequences, [phone.id: 1])
        XCTAssertFalse(outcome.pin.verified, "Confiance à la première utilisation")
    }

    func testAChangedAccountKeyIsNeverBelieved() throws {
        let (first, _) = try makeBundle(uik: P256.Signing.PrivateKey(), devices: [phone], version: 1, previous: nil)
        let pin = try XCTUnwrap(try? E2EEV2IdentityVerification.verify(first, pinned: nil).get()).pin
        let (swapped, _) = try makeBundle(uik: P256.Signing.PrivateKey(), devices: [phone], version: 2, previous: nil)
        XCTAssertEqual(failure(E2EEV2IdentityVerification.verify(swapped, pinned: pin)), .uikChanged)
    }

    func testTheDeviceListNeverGoesBackOrForks() throws {
        let uik = P256.Signing.PrivateKey()
        let (v1, v1Canonical) = try makeBundle(uik: uik, devices: [phone], version: 1, previous: nil)
        let (v2, v2Canonical) = try makeBundle(uik: uik, devices: [phone, tablet], version: 2, previous: v1Canonical)
        let pin1 = try XCTUnwrap(try? E2EEV2IdentityVerification.verify(v1, pinned: nil).get()).pin

        let pin2 = try XCTUnwrap(try? E2EEV2IdentityVerification.verify(v2, pinned: pin1).get()).pin
        XCTAssertEqual(pin2.listVersion, 2)
        XCTAssertEqual(failure(E2EEV2IdentityVerification.verify(v1, pinned: pin2)), .deviceListRollback)

        let (fork, _) = try makeBundle(uik: uik, devices: [tablet], version: 2, previous: v1Canonical)
        XCTAssertEqual(failure(E2EEV2IdentityVerification.verify(fork, pinned: pin2)), .deviceListRollback,
                       "Une autre liste à la même version")

        let (unchained, _) = try makeBundle(uik: uik, devices: [phone, tablet], version: 3, previous: v1Canonical)
        XCTAssertEqual(failure(E2EEV2IdentityVerification.verify(unchained, pinned: pin2)), .invalidDeviceList,
                       "La version suivante doit chaîner la dernière vue")

        let (v3, v3Canonical) = try makeBundle(uik: uik, devices: [tablet], version: 3, previous: v2Canonical)
        var (v4, _) = try makeBundle(uik: uik, devices: [tablet], version: 4, previous: v3Canonical)
        XCTAssertNoThrow(try E2EEV2IdentityVerification.verify(v3, pinned: pin2).get())
        XCTAssertEqual(failure(E2EEV2IdentityVerification.verify(v4, pinned: pin2)), .deviceListGap,
                       "Une version manquée sans son maillon : rien n'est cru (D.3, E.1)")
        v4.deviceListChain = [v3.deviceList]
        let skipped = try XCTUnwrap(try? E2EEV2IdentityVerification.verify(v4, pinned: pin2).get())
        XCTAssertEqual(skipped.pin.listVersion, 4, "Versions manquées : chaque maillon vérifié depuis la version épinglée")
        XCTAssertEqual(skipped.devices.map(\.deviceId), [tablet.id], "Le téléphone, retiré de la liste, n'est plus certifié")
    }

    func testOnlyListedDevicesWithMatchingCertificatesAreCertified() throws {
        let uik = P256.Signing.PrivateKey()
        let stranger = Device(id: "device_bruno_web_01J7ABCD", platform: "web", keyVersion: 1)
        var (bundle, _) = try makeBundle(uik: uik, devices: [phone, tablet], version: 1, previous: nil)
        // Certificat du téléphone signé par une autre clé, certificat d'un appareil
        // hors liste, certificat de la tablette annonçant une autre plateforme.
        bundle = E2EEV2IdentityBundle(
            userId: userId,
            uikX963B64: bundle.uikX963B64,
            deviceList: bundle.deviceList,
            deviceEntries: bundle.deviceEntries,
            certificates: [
                try certificate(phone, signedBy: P256.Signing.PrivateKey()),
                try certificate(stranger, signedBy: uik),
                try certificate(Device(id: tablet.id, platform: "android", keyVersion: tablet.keyVersion), signedBy: uik),
            ],
            capabilities: [],
            hasPendingIdentityReset: false
        )
        let outcome = try XCTUnwrap(try? E2EEV2IdentityVerification.verify(bundle, pinned: nil).get())
        XCTAssertTrue(outcome.devices.isEmpty, "Rien n'est certifié sans certificat conforme à la liste")

        let tampered = E2EEV2IdentityBundle(
            userId: userId, uikX963B64: bundle.uikX963B64, deviceList: bundle.deviceList,
            deviceEntries: bundle.deviceEntries + [stranger.entry], certificates: [], capabilities: [],
            hasPendingIdentityReset: false
        )
        XCTAssertEqual(failure(E2EEV2IdentityVerification.verify(tampered, pinned: nil)), .invalidDeviceList,
                       "Une entrée ajoutée hors de la liste signée")
    }

    func testCapabilitiesMustBeSignedByTheDeviceAndNeverGoBack() throws {
        let uik = P256.Signing.PrivateKey()
        let (first, firstCanonical) = try makeBundle(uik: uik, devices: [phone], version: 1, previous: nil,
                                                     capabilities: [(phone, 5, now - 1_000, ["calls"])])
        let pin = try XCTUnwrap(try? E2EEV2IdentityVerification.verify(first, pinned: nil).get()).pin

        let (older, _) = try makeBundle(uik: uik, devices: [phone], version: 2, previous: firstCanonical,
                                        capabilities: [(phone, 4, now, ["calls"])])
        let outcome = try XCTUnwrap(try? E2EEV2IdentityVerification.verify(older, pinned: pin).get())
        XCTAssertNil(outcome.devices.first?.capabilities, "Une séquence en recul est ignorée")
        XCTAssertEqual(outcome.pin.capabilitySequences[phone.id], 5, "La dernière séquence vue est gardée")

        var forged = first
        let document = capabilitiesDocument(phone, sequence: 6, issuedAtMs: now, features: ["calls"])
        forged = E2EEV2IdentityBundle(
            userId: userId, uikX963B64: forged.uikX963B64, deviceList: forged.deviceList,
            deviceEntries: forged.deviceEntries, certificates: forged.certificates,
            capabilities: [try signedCapabilities(document, with: tablet.signing)],
            hasPendingIdentityReset: false
        )
        let forgedOutcome = try XCTUnwrap(try? E2EEV2IdentityVerification.verify(forged, pinned: nil).get())
        XCTAssertNil(forgedOutcome.devices.first?.capabilities, "Signé par un autre appareil : ignoré")

        let (stale, _) = try makeBundle(uik: uik, devices: [phone], version: 1, previous: nil,
                                        capabilities: [(phone, 1, now - E2EEV2IdentityVerification.capabilityFreshnessMs - 1, ["calls"])])
        let staleDevice = try XCTUnwrap(try? E2EEV2IdentityVerification.verify(stale, pinned: nil).get()).devices.first
        XCTAssertEqual(staleDevice?.isSidelined(nowMs: now), true, "Document de plus de 90 jours : mis à l'écart")
        XCTAssertEqual(staleDevice?.supports("calls", nowMs: now), false)
    }

    func testServerResponseIsReadStrictly() throws {
        let uik = P256.Signing.PrivateKey()
        let (bundle, _) = try makeBundle(uik: uik, devices: [phone], version: 1, previous: nil,
                                         capabilities: [(phone, 1, now, ["calls"])])
        var object: [String: Any] = [
            "accountIdentityKeyB64": bundle.uikX963B64,
            "deviceList": [
                "list": bundle.deviceList.canonical,
                "signatureB64": bundle.deviceList.signatureB64,
                "devices": bundle.deviceEntries,
            ],
            "certificates": bundle.certificates.map { ["certificate": $0.canonical, "signatureB64": $0.signatureB64] },
            "capabilities": bundle.capabilities.map { ["document": $0.document, "signatureB64": $0.signatureB64] },
            "pendingIdentityReset": NSNull(),
            "futureKey": "ajout compatible",
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(E2EEV2IdentityBundle.parse(decoded, userId: userId), bundle, "Clé inconnue de premier niveau ignorée")

        object["deviceList"] = ["list": bundle.deviceList.canonical, "signatureB64": bundle.deviceList.signatureB64,
                                "devices": bundle.deviceEntries, "extra": true]
        XCTAssertNil(E2EEV2IdentityBundle.parse(object, userId: userId), "Objet signé : clés exactes")
        object.removeValue(forKey: "deviceList")
        XCTAssertNil(E2EEV2IdentityBundle.parse(object, userId: userId), "Clé attendue absente")
    }

    // MARK: - Outils

    // MARK: - Relecture indépendante du 01/10 (X-2)

    func testOwnAccountKeyIsComparedToTheKeyHeldHereEvenAtFirstContact() throws {
        let uik = P256.Signing.PrivateKey()
        let (bundle, _) = try makeBundle(uik: P256.Signing.PrivateKey(), devices: [phone], version: 1, previous: nil)
        XCTAssertEqual(failure(E2EEV2IdentityVerification.verify(bundle, pinned: nil, expectedUIK: uik.publicKey)),
                       .uikChanged, "Le serveur ne glisse pas une autre clé dans son propre compte")
        let (own, _) = try makeBundle(uik: uik, devices: [phone], version: 1, previous: nil)
        XCTAssertNotNil(try? E2EEV2IdentityVerification.verify(own, pinned: nil, expectedUIK: uik.publicKey).get())
    }

    func testNonCanonicalKeysAndGroupedEntriesAreRefused() throws {
        let uik = P256.Signing.PrivateKey()
        let (bundle, _) = try makeBundle(uik: uik, devices: [phone], version: 1, previous: nil)
        // Même clé, base64 non canonique : refusée plutôt que prise pour une autre.
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var b64 = Array(bundle.uikX963B64)
        let last = b64.count - 2 // avant le « = » : 2 bits de bourrage
        b64[last] = alphabet[try XCTUnwrap(alphabet.firstIndex(of: b64[last])) ^ 1]
        let variant = String(b64)
        XCTAssertEqual(Data(base64Encoded: variant), Data(base64Encoded: bundle.uikX963B64), "Même octets")
        let renamed = E2EEV2IdentityBundle(
            userId: bundle.userId, uikX963B64: variant, deviceList: bundle.deviceList,
            deviceEntries: bundle.deviceEntries, certificates: bundle.certificates,
            capabilities: bundle.capabilities, hasPendingIdentityReset: false
        )
        XCTAssertEqual(failure(E2EEV2IdentityVerification.verify(renamed, pinned: nil)), .malformed)

        // Entrées regroupées : même condensat, découpage différent.
        let grouped = ["a1234567890123456\n1\nios", "fa\n\(phone.entry)"]
        let list = E2EEV2DeviceList.make(userId: userId, version: 1, previousCanonical: nil, entries: grouped, issuedAtMs: now)
        XCTAssertThrowsError(try E2EEV2DeviceList.verifyWithoutChain(
            E2EEV2SignedString.sign(list.canonical, with: uik), entries: grouped, uik: uik.publicKey
        ), "Une liste signée aux entrées mal formées est refusée")
    }

    func testCanonicalFieldsRefuseTrailingLineTerminators() {
        for terminator in ["\n", "\r", "\u{2028}", "\u{0085}"] {
            XCTAssertFalse(E2EEV2Canonical.isOpaque("device_bruno_ios_01J7ABCD" + terminator), terminator.debugDescription)
            XCTAssertFalse(E2EEV2Canonical.isDecimal("42" + terminator), terminator.debugDescription)
        }
        XCTAssertTrue(E2EEV2Canonical.isOpaque("device_bruno_ios_01J7ABCD"))
        XCTAssertTrue(E2EEV2Canonical.isDecimal("42"))
    }

    func testAHugeListVersionIsRefusedInsteadOfOverflowing() throws {
        let uik = P256.Signing.PrivateKey()
        let (first, canonical) = try makeBundle(uik: uik, devices: [phone], version: 1, previous: nil)
        let pin = try XCTUnwrap(try? E2EEV2IdentityVerification.verify(first, pinned: nil).get()).pin
        let (huge, _) = try makeBundle(uik: uik, devices: [phone], version: Int.max, previous: canonical)
        XCTAssertEqual(failure(E2EEV2IdentityVerification.verify(huge, pinned: pin)), .invalidDeviceList)
        XCTAssertEqual(failure(E2EEV2IdentityVerification.verify(huge, pinned: nil)), .invalidDeviceList)
    }

    private func makeBundle(
        uik: P256.Signing.PrivateKey,
        devices: [Device],
        version: Int,
        previous: String?,
        capabilities: [(Device, Int, Int64, [String])] = []
    ) throws -> (E2EEV2IdentityBundle, String) {
        let list = E2EEV2DeviceList.make(
            userId: userId, version: version, previousCanonical: previous,
            entries: devices.map(\.entry), issuedAtMs: now
        )
        let signedList = try E2EEV2SignedString.sign(list.canonical, with: uik)
        let bundle = E2EEV2IdentityBundle(
            userId: userId,
            uikX963B64: uik.publicKey.x963Representation.base64EncodedString(),
            deviceList: signedList,
            deviceEntries: devices.map(\.entry),
            certificates: try devices.map { try certificate($0, signedBy: uik) },
            capabilities: try capabilities.map { device, sequence, issuedAt, features in
                try signedCapabilities(
                    capabilitiesDocument(device, sequence: sequence, issuedAtMs: issuedAt, features: features),
                    with: device.signing
                )
            },
            hasPendingIdentityReset: false
        )
        return (bundle, list.canonical)
    }

    private func certificate(_ device: Device, signedBy uik: P256.Signing.PrivateKey) throws -> E2EEV2SignedString {
        let certificate = E2EEV2DeviceCertificate(
            userId: userId, deviceId: device.id, keyVersion: device.keyVersion,
            identityKeyB64: device.identityB64, signingKeyB64: device.signingB64,
            platform: device.platform, createdAtMs: now
        )
        return try E2EEV2SignedString.sign(certificate.canonical, with: uik)
    }

    private func capabilitiesDocument(_ device: Device, sequence: Int, issuedAtMs: Int64, features: [String]) -> String {
        E2EEV2CapabilitiesDocument(
            userId: userId, deviceId: device.id, sequence: sequence, issuedAtMs: issuedAtMs,
            envelopeVersions: ["2"], payloadVersions: ["2"], kinds: ["TEXT"], features: features.sorted()
        ).document
    }

    private func signedCapabilities(_ document: String, with key: P256.Signing.PrivateKey) throws -> E2EEV2SignedCapabilities {
        let signed = try E2EEV2SignedString.sign(E2EEV2CapabilitiesDocument.signatureCanonical(document: document), with: key)
        return E2EEV2SignedCapabilities(document: document, signatureB64: signed.signatureB64)
    }

    private func failure(
        _ result: Result<E2EEV2IdentityVerification.Outcome, E2EEV2IdentityVerification.Failure>
    ) -> E2EEV2IdentityVerification.Failure? {
        if case .failure(let error) = result { return error }
        return nil
    }
}
