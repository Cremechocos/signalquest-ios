import CryptoKit
import XCTest
@testable import SignalQuest

/// IOS-A1 (plan 3, jalon A) : annuaire des appareils certifiés des membres,
/// épinglé d'une lecture à l'autre, et règle des « appels vérifiés » (§10.0).
final class E2EEV2TrustDirectoryTests: XCTestCase {
    private let now: Int64 = 1_790_000_000_000
    private let namespace = "ns-alice"

    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [String: Data] = [:]
        func serve(_ data: Data, for userId: String) { lock.lock(); responses[userId] = data; lock.unlock() }
        func response(for userId: String) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            guard let data = responses[userId] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    /// Réponses selon `sinceVersion` (E.1).
    private final class SincePages: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [String: Data] = [:]
        func serve(_ data: Data, since: Int?) { lock.lock(); responses[since.map(String.init) ?? "-"] = data; lock.unlock() }
        func response(since: Int?) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            guard let data = responses[since.map(String.init) ?? "-"] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    private struct Account {
        let userId: String
        let uik = P256.Signing.PrivateKey()
        let deviceId: String
        let identity = P256.KeyAgreement.PrivateKey()
        let signing = P256.Signing.PrivateKey()

        init(_ name: String) {
            userId = "user_\(name)_01J7ABCD2345"
            deviceId = "device_\(name)_ios_01J7ABCD"
        }

        init(userId: String, deviceId: String) {
            self.userId = userId
            self.deviceId = deviceId
        }
    }

    func testMembersAreCertifiedAndPinnedAcrossReads() async throws {
        let bruno = Account("bruno"), carla = Account("carla")
        let server = Server()
        server.serve(try bundle(bruno, version: 1, features: ["calls"]), for: bruno.userId)
        server.serve(try bundle(carla, version: 1, features: ["calls"]), for: carla.userId)
        let pins = E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: pins) { userId, _ in try server.response(for: userId) }

        let set = try await directory.certifiedDevices(for: [carla.userId, bruno.userId, bruno.userId])
        XCTAssertEqual(set.refusals, [:])
        XCTAssertEqual(set.signingKey(userId: bruno.userId, deviceId: bruno.deviceId)?.x963Representation,
                       bruno.signing.publicKey.x963Representation)
        XCTAssertEqual(set.device(deviceId: carla.deviceId)?.userId, carla.userId)
        XCTAssertTrue(set.supportsVerifiedCalls(nowMs: now))
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.listVersion, 1)
        XCTAssertNil(try pins.pin(userId: bruno.userId, ownerNamespace: "ns-other"), "Épinglage propre au compte")

        // Le serveur ressert une liste plus ancienne que celle épinglée.
        server.serve(try bundle(bruno, version: 2, features: ["calls"]), for: bruno.userId)
        _ = try await directory.certifiedDevices(for: [bruno.userId])
        server.serve(try bundle(bruno, version: 1, features: ["calls"]), for: bruno.userId)
        let rolledBack = try await directory.certifiedDevices(for: [bruno.userId, carla.userId])
        XCTAssertEqual(rolledBack.refusals, [bruno.userId: .deviceListRollback])
        XCTAssertNil(rolledBack.device(deviceId: bruno.deviceId), "Rien n'est cru d'un paquet refusé")
        XCTAssertNotNil(rolledBack.device(deviceId: carla.deviceId), "Les autres membres restent certifiés")
    }

    func testAChangedAccountKeyRemovesOnlyThatMember() async throws {
        let bruno = Account("bruno"), impostor = Account("bruno")
        let server = Server()
        server.serve(try bundle(bruno, version: 1, features: ["calls"]), for: bruno.userId)
        let directory = E2EEV2TrustDirectory(
            ownerNamespace: namespace, pins: E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        ) { userId, _ in try server.response(for: userId) }
        _ = try await directory.certifiedDevices(for: [bruno.userId])

        server.serve(try bundle(impostor, version: 1, features: ["calls"]), for: bruno.userId)
        let set = try await directory.certifiedDevices(for: [bruno.userId])
        XCTAssertEqual(set.refusals, [bruno.userId: .uikChanged])
        XCTAssertFalse(set.supportsVerifiedCalls(nowMs: now), "Aucun appareil certifié : pas d'appel vérifié")
    }

    func testADeviceIdCertifiedByTwoAccountsIsBelievedForNeither() async throws {
        let bruno = Account("bruno")
        var carla = Account("carla")
        carla = Account(userId: carla.userId, deviceId: bruno.deviceId)
        let server = Server()
        server.serve(try bundle(bruno, version: 1, features: ["calls"]), for: bruno.userId)
        server.serve(try bundle(carla, version: 1, features: ["calls"]), for: carla.userId)
        let directory = E2EEV2TrustDirectory(
            ownerNamespace: namespace, pins: E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        ) { userId, _ in try server.response(for: userId) }
        let set = try await directory.certifiedDevices(for: [bruno.userId, carla.userId])
        XCTAssertNil(set.device(deviceId: bruno.deviceId), "Identifiant ambigu : aucun des deux n'est cru")
        XCTAssertFalse(set.supportsVerifiedCalls(nowMs: now))
    }

    func testOwnAccountMustCarryTheKeyHeldHere() async throws {
        let alice = Account("alice"), impostor = Account("alice")
        let server = Server()
        server.serve(try bundle(impostor, version: 1, features: ["calls"]), for: alice.userId)
        let held = alice.uik.publicKey
        let directory = E2EEV2TrustDirectory(
            ownerNamespace: namespace, pins: E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore()),
            ownUserId: alice.userId, ownAccountKey: { held }
        ) { userId, _ in try server.response(for: userId) }
        let set = try await directory.certifiedDevices(for: [alice.userId])
        XCTAssertEqual(set.refusals, [alice.userId: .uikChanged])
    }

    func testTheDeviceListChainIsReadLinkByLinkFromThePin() async throws {
        let bruno = Account("bruno")
        let pins = E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        let pages = SincePages()
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: pins) { _, since in try pages.response(since: since) }
        pages.serve(try bundle(bruno, version: 1, features: ["calls"]), since: nil)
        _ = try await directory.certifiedDevices(for: [bruno.userId])

        // De la version 1 épinglée à la 4 : maillons 2 et 3 relus.
        pages.serve(try bundle(bruno, version: 4, features: ["calls"], chainFrom: 1), since: 1)
        let caughtUp = try await directory.certifiedDevices(for: [bruno.userId])
        XCTAssertEqual(caughtUp.refusals, [:])
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.listVersion, 4)

        // Un saut sans ses maillons, ou un maillon signé par une autre clé : refusés.
        pages.serve(try bundle(bruno, version: 6, features: ["calls"]), since: 4)
        let gap = try await directory.certifiedDevices(for: [bruno.userId])
        XCTAssertEqual(gap.refusals, [bruno.userId: .deviceListGap])
        pages.serve(try bundle(bruno, version: 6, features: ["calls"], chainFrom: 4, linkSigner: P256.Signing.PrivateKey()), since: 4)
        let forged = try await directory.certifiedDevices(for: [bruno.userId])
        XCTAssertEqual(forged.refusals, [bruno.userId: .invalidDeviceList])
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.listVersion, 4, "Rien n'est épinglé d'un paquet refusé")

        // De la 4 à la 7, en deux pages : le maillon 5, puis le 6.
        pages.serve(try bundle(bruno, version: 7, features: ["calls"], chainFrom: 4, chainUpTo: 5, next: 5), since: 4)
        pages.serve(try bundle(bruno, version: 7, features: ["calls"], chainFrom: 5), since: 5)
        let paged = try await directory.certifiedDevices(for: [bruno.userId])
        XCTAssertEqual(paged.refusals, [:])
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.listVersion, 7)
    }

    func testARefusedMemberMakesVerifiedCallsUnavailable() {
        let set = E2EEV2CertifiedDeviceSet(devicesByUser: [:], refusals: ["user_bruno_01J7ABCD2345": .uikChanged])
        XCTAssertFalse(set.supportsVerifiedCalls(nowMs: now))
    }

    func testVerifiedCallsNeedEveryActiveDeviceToSupportThem() {
        func device(_ id: String, features: [String]?, issuedAtMs: Int64) -> E2EEV2CertifiedDevice {
            E2EEV2CertifiedDevice(
                userId: "user_bruno_01J7ABCD2345", deviceId: id, keyVersion: 1, platform: "ios",
                identityKeyB64: "", signingKeyB64: "", fingerprint: "",
                capabilities: features.map {
                    E2EEV2CapabilitiesDocument(
                        userId: "user_bruno_01J7ABCD2345", deviceId: id, sequence: 1, issuedAtMs: issuedAtMs,
                        envelopeVersions: ["2"], payloadVersions: ["2"], kinds: ["TEXT"], features: $0
                    )
                }
            )
        }
        let fresh = now - 1_000
        let stale = now - E2EEV2IdentityVerification.capabilityFreshnessMs - 1
        func set(_ devices: [E2EEV2CertifiedDevice]) -> E2EEV2CertifiedDeviceSet {
            E2EEV2CertifiedDeviceSet(devicesByUser: ["user_bruno_01J7ABCD2345": devices], refusals: [:])
        }
        XCTAssertTrue(set([device("device_a_01J7ABCD2345", features: ["calls"], issuedAtMs: fresh)]).supportsVerifiedCalls(nowMs: now))
        XCTAssertFalse(set([
            device("device_a_01J7ABCD2345", features: ["calls"], issuedAtMs: fresh),
            device("device_b_01J7ABCD2345", features: ["voice"], issuedAtMs: fresh),
        ]).supportsVerifiedCalls(nowMs: now), "Un appareil actif sans « appels vérifiés » rend l'appel indisponible")
        XCTAssertTrue(set([
            device("device_a_01J7ABCD2345", features: ["calls"], issuedAtMs: fresh),
            device("device_b_01J7ABCD2345", features: ["voice"], issuedAtMs: stale),
            device("device_c_01J7ABCD2345", features: nil, issuedAtMs: fresh),
        ]).supportsVerifiedCalls(nowMs: now), "Les appareils mis à l'écart ne comptent pas")
        XCTAssertFalse(set([]).supportsVerifiedCalls(nowMs: now))
    }

    // MARK: - Outils

    /// Réponse E.1 d'un compte à un seul appareil. `chainFrom` : les maillons
    /// servis après cette version, jusqu'à `chainUpTo` (par défaut la liste
    /// précédant la courante) ; `next` : la page suivante annoncée.
    private func bundle(
        _ account: Account,
        version: Int,
        features: [String],
        chainFrom: Int? = nil,
        chainUpTo: Int? = nil,
        linkSigner: P256.Signing.PrivateKey? = nil,
        next: Int? = nil
    ) throws -> Data {
        let fingerprint = E2EEV2Canonical.deviceFingerprint(
            identityKeyX963: account.identity.publicKey.x963Representation,
            signingKeyX963: account.signing.publicKey.x963Representation
        )
        let entry = E2EEV2DeviceList.entry(deviceId: account.deviceId, keyVersion: 1, platform: "ios", fingerprint: fingerprint)
        // Chaîne de listes jusqu'à `version` : la dernière est la courante.
        var previous: String?
        var list = E2EEV2DeviceList.make(userId: account.userId, version: 1, previousCanonical: nil, entries: [entry], issuedAtMs: now)
        var canonicals = [list.canonical]
        if version > 1 {
            for v in 2...version {
                previous = list.canonical
                list = E2EEV2DeviceList.make(userId: account.userId, version: v, previousCanonical: previous, entries: [entry], issuedAtMs: now + Int64(v))
                canonicals.append(list.canonical)
            }
        }
        var links: [[String: String]] = []
        if let chainFrom, chainFrom + 1 <= min(chainUpTo ?? version - 1, version - 1) {
            for v in (chainFrom + 1)...min(chainUpTo ?? version - 1, version - 1) {
                let link = try E2EEV2SignedString.sign(canonicals[v - 1], with: linkSigner ?? account.uik)
                links.append(["list": link.canonical, "signatureB64": link.signatureB64])
            }
        }
        let signedList = try E2EEV2SignedString.sign(list.canonical, with: account.uik)
        let certificate = E2EEV2DeviceCertificate(
            userId: account.userId, deviceId: account.deviceId, keyVersion: 1,
            identityKeyB64: account.identity.publicKey.x963Representation.base64EncodedString(),
            signingKeyB64: account.signing.publicKey.x963Representation.base64EncodedString(),
            platform: "ios", createdAtMs: now
        )
        let signedCertificate = try E2EEV2SignedString.sign(certificate.canonical, with: account.uik)
        let document = E2EEV2CapabilitiesDocument(
            userId: account.userId, deviceId: account.deviceId, sequence: 1, issuedAtMs: now - 1_000,
            envelopeVersions: ["2"], payloadVersions: ["2"], kinds: ["TEXT"], features: features.sorted()
        ).document
        let signedDocument = try E2EEV2SignedString.sign(
            E2EEV2CapabilitiesDocument.signatureCanonical(document: document), with: account.signing
        )
        var object: [String: Any] = [
            "accountIdentityKeyB64": account.uik.publicKey.x963Representation.base64EncodedString(),
            "deviceList": ["list": signedList.canonical, "signatureB64": signedList.signatureB64, "devices": [entry]],
            "certificates": [["certificate": signedCertificate.canonical, "signatureB64": signedCertificate.signatureB64]],
            "capabilities": [["document": document, "signatureB64": signedDocument.signatureB64]],
            "pendingIdentityReset": NSNull(),
        ]
        if chainFrom != nil { object["deviceListChain"] = links }
        if let next { object["nextSinceVersion"] = String(next) }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
