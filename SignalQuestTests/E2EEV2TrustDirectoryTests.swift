import CryptoKit
import XCTest
@testable import SignalQuest

/// IOS-A1 (plan 3, jalon A) : annuaire des appareils certifiés des membres,
/// épinglé d'une lecture à l'autre, et règle des « appels vérifiés » (§10.0).
final class E2EEV2TrustDirectoryTests: XCTestCase {
    private let now: Int64 = 1_790_000_000_000
    private let namespace = "ns-alice"
    private let alice = "user_alice_01J7ABCD2345"

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
        XCTAssertTrue(set.supportsVerifiedCalls(nowMs: now, excludesWeb: false))
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

    /// `E2EE_IDENTITY_NOT_FOUND` (A1) : seul ce membre est refusé.
    func testAnUnreadableMemberIsRefusedAlone() async throws {
        let bruno = Account("bruno"), carla = Account("carla")
        let server = Server()
        server.serve(try bundle(bruno, version: 1, features: ["calls"]), for: bruno.userId)
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())) { userId, _ in
            if userId == carla.userId { throw E2EEV2TrustDirectory.IdentityNotFound() }
            return try server.response(for: userId)
        }
        let set = try await directory.certifiedDevices(for: [bruno.userId, carla.userId])
        XCTAssertEqual(set.refusals, [carla.userId: .notFound])
        XCTAssertNotNil(set.device(deviceId: bruno.deviceId))
        XCTAssertFalse(set.supportsVerifiedCalls(nowMs: now, excludesWeb: false), "Un membre illisible rend l'appel indisponible")
    }

    /// Cache de l'annuaire (branchement v2) : relu après 5 minutes ou sur
    /// invalidation, jamais à chaque appel ; une ambiguïté reste refusée.
    func testTheDirectoryCacheRereadsOnlyStaleOrInvalidatedAccounts() async throws {
        let bruno = Account("bruno"), carla = Account("carla")
        let server = Server()
        server.serve(try bundle(bruno, version: 1, features: ["calls"]), for: bruno.userId)
        server.serve(try bundle(carla, version: 1, features: ["calls"]), for: carla.userId)
        let reads = LockedCount()
        let clock = LockedDate(Date(timeIntervalSince1970: 1_790_000_000))
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())) { userId, _ in
            reads.add(userId)
            return try server.response(for: userId)
        }
        let session = LocalAccountSession(ownerScopeId: "user:\(alice)", sessionId: "session_cache_0000000001")
        let cache = E2EEV2DeviceDirectoryCache(session: session, directory: directory, now: { clock.value })
        let first = try await cache.devices(for: [bruno.userId, carla.userId])
        XCTAssertNotNil(first.device(deviceId: bruno.deviceId))
        _ = try await cache.devices(for: [bruno.userId])
        XCTAssertEqual(reads.count(bruno.userId), 1, "Gardé 5 minutes")
        await cache.invalidate([bruno.userId])
        _ = try await cache.devices(for: [bruno.userId, carla.userId])
        XCTAssertEqual(reads.count(bruno.userId), 2, "Relu après invalidation")
        XCTAssertEqual(reads.count(carla.userId), 1, "Les autres restent en cache")
        clock.value = clock.value.addingTimeInterval(E2EEV2DeviceDirectoryCache.lifetime)
        _ = try await cache.devices(for: [carla.userId])
        XCTAssertEqual(reads.count(carla.userId), 2, "Relu passé 5 minutes")
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
        XCTAssertFalse(set.supportsVerifiedCalls(nowMs: now, excludesWeb: false), "Aucun appareil certifié : pas d'appel vérifié")
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
        XCTAssertFalse(set.supportsVerifiedCalls(nowMs: now, excludesWeb: false))
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
        XCTAssertFalse(set.supportsVerifiedCalls(nowMs: now, excludesWeb: false))
    }

    func testVerifiedCallsNeedEveryActiveDeviceToSupportThem() {
        func device(_ id: String, features: [String]?, issuedAtMs: Int64, platform: String = "ios") -> E2EEV2CertifiedDevice {
            E2EEV2CertifiedDevice(
                userId: "user_bruno_01J7ABCD2345", deviceId: id, keyVersion: 1, platform: platform,
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
        XCTAssertTrue(set([device("device_a_01J7ABCD2345", features: ["calls"], issuedAtMs: fresh)]).supportsVerifiedCalls(nowMs: now, excludesWeb: false))
        XCTAssertFalse(set([
            device("device_a_01J7ABCD2345", features: ["calls"], issuedAtMs: fresh),
            device("device_b_01J7ABCD2345", features: ["voice"], issuedAtMs: fresh),
        ]).supportsVerifiedCalls(nowMs: now, excludesWeb: false), "Un appareil actif sans « appels vérifiés » rend l'appel indisponible")
        XCTAssertTrue(set([
            device("device_a_01J7ABCD2345", features: ["calls"], issuedAtMs: fresh),
            device("device_b_01J7ABCD2345", features: ["voice"], issuedAtMs: stale),
            device("device_c_01J7ABCD2345", features: nil, issuedAtMs: fresh),
        ]).supportsVerifiedCalls(nowMs: now, excludesWeb: false), "Les appareils mis à l'écart ne comptent pas")
        XCTAssertFalse(set([]).supportsVerifiedCalls(nowMs: now, excludesWeb: false))

        // §12 : un navigateur approuvé compte, sauf si la conversation exclut les navigateurs.
        let phone = device("device_a_01J7ABCD2345", features: ["calls"], issuedAtMs: fresh)
        let browser = device("device_w_01J7ABCD2345", features: ["voice"], issuedAtMs: fresh, platform: "web")
        XCTAssertFalse(set([phone, browser]).supportsVerifiedCalls(nowMs: now, excludesWeb: false))
        XCTAssertTrue(set([phone, browser]).supportsVerifiedCalls(nowMs: now, excludesWeb: true),
                      "Navigateurs exclus : celui-ci ne rend plus l'appel indisponible")
        XCTAssertFalse(set([browser]).supportsVerifiedCalls(nowMs: now, excludesWeb: true), "Il reste au moins un appareil")
    }

    // MARK: - Numéro de sécurité (§2.4, D.12)

    func testTheSafetyNumberStatusFollowsTheUsersChoices() async throws {
        let bruno = Account("bruno")
        let server = Server()
        server.serve(try bundle(bruno, version: 1, features: ["calls"]), for: bruno.userId)
        let pins = E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: pins, ownUserId: alice) { userId, _ in
            try server.response(for: userId)
        }
        let uik = bruno.uik.publicKey.x963Representation.base64EncodedString()

        let first = try await directory.safetyNumberIdentity(userId: bruno.userId)
        XCTAssertEqual(first, E2EEV2SafetyNumberIdentity(userId: bruno.userId, uikX963B64: uik, status: .unverified))
        XCTAssertNotNil(try pins.pin(userId: bruno.userId, ownerNamespace: namespace), "Épinglé au premier contact")

        try await directory.setVerified(true, userId: bruno.userId, uikX963B64: uik)
        let verified = try await directory.safetyNumberIdentity(userId: bruno.userId)
        XCTAssertEqual(verified.status, .verified)
        _ = try await directory.certifiedDevices(for: [bruno.userId])
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.verified, true,
                       "Une relecture garde la vérification")

        try await directory.setVerified(false, userId: bruno.userId, uikX963B64: uik)
        let cleared = try await directory.safetyNumberIdentity(userId: bruno.userId)
        XCTAssertEqual(cleared.status, .unverified)

        let other = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        await XCTAssertThrowsAsync(try await directory.setVerified(true, userId: bruno.userId, uikX963B64: other),
                                   E2EEV2TrustDirectory.SafetyNumberFailure.numberChanged)
        await XCTAssertThrowsAsync(try await directory.safetyNumberIdentity(userId: alice),
                                   E2EEV2TrustDirectory.SafetyNumberFailure.ownAccount)
    }

    func testAChangedKeyIsShownButNotBelievedUntilAccepted() async throws {
        let bruno = Account("bruno")
        let reset = Account(userId: bruno.userId, deviceId: "device_bruno_new_01J7ABCD")
        let pins = E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        let pages = SincePages()
        pages.serve(try bundle(bruno, version: 3, features: ["calls"]), since: nil)
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: pins, ownUserId: alice) { _, since in
            try pages.response(since: since)
        }
        _ = try await directory.certifiedDevices(for: [bruno.userId])

        // Nouvelle identité : sa liste repart de 1 (D.14). Le serveur ignore la
        // version épinglée, plus grande que la sienne (E.1, v0.4.9).
        let renewed = try bundle(reset, version: 1, features: ["calls"])
        pages.serve(renewed, since: 3)
        pages.serve(renewed, since: nil)
        let newUIK = reset.uik.publicKey.x963Representation.base64EncodedString()
        let changed = try await directory.safetyNumberIdentity(userId: bruno.userId)
        XCTAssertEqual(changed, E2EEV2SafetyNumberIdentity(userId: bruno.userId, uikX963B64: newUIK, status: .changed(wasVerified: false)))
        let refused = try await directory.certifiedDevices(for: [bruno.userId])
        XCTAssertEqual(refused.refusals, [bruno.userId: .uikChanged], "Montrée, mais pas crue")

        let unseen = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        await XCTAssertThrowsAsync(
            try await directory.acceptChangedIdentity(userId: bruno.userId, uikX963B64: unseen, verified: false),
            E2EEV2TrustDirectory.SafetyNumberFailure.numberChanged, "Seule l'UIK dont le numéro a été vu s'accepte"
        )
        // L'acceptation relit sans `sinceVersion` : la réponse à la version
        // épinglée ne sert plus.
        pages.serve(Data("{}".utf8), since: 3)
        try await directory.acceptChangedIdentity(userId: bruno.userId, uikX963B64: newUIK, verified: false)
        pages.serve(renewed, since: 1)
        let accepted = try await directory.certifiedDevices(for: [bruno.userId])
        XCTAssertEqual(accepted.refusals, [:])
        XCTAssertNotNil(accepted.device(userId: bruno.userId, deviceId: reset.deviceId))
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.listVersion, 1)
        let now = try await directory.safetyNumberIdentity(userId: bruno.userId)
        XCTAssertEqual(now.status, .unverified)
    }

    func testAVerifiedKeyIsReplacedOnlyByANewVerification() async throws {
        let bruno = Account("bruno")
        let reset = Account(userId: bruno.userId, deviceId: "device_bruno_new_01J7ABCD")
        let server = Server()
        server.serve(try bundle(bruno, version: 1, features: ["calls"]), for: bruno.userId)
        let directory = E2EEV2TrustDirectory(
            ownerNamespace: namespace, pins: E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore()), ownUserId: alice
        ) { userId, _ in try server.response(for: userId) }
        _ = try await directory.safetyNumberIdentity(userId: bruno.userId)
        try await directory.setVerified(true, userId: bruno.userId, uikX963B64: bruno.uik.publicKey.x963Representation.base64EncodedString())

        server.serve(try bundle(reset, version: 1, features: ["calls"]), for: bruno.userId)
        let newUIK = reset.uik.publicKey.x963Representation.base64EncodedString()
        let changed = try await directory.safetyNumberIdentity(userId: bruno.userId)
        XCTAssertEqual(changed.status, .changed(wasVerified: true))
        await XCTAssertThrowsAsync(
            try await directory.acceptChangedIdentity(userId: bruno.userId, uikX963B64: newUIK, verified: false),
            E2EEV2TrustDirectory.SafetyNumberFailure.verificationRequired
        )
        try await directory.acceptChangedIdentity(userId: bruno.userId, uikX963B64: newUIK, verified: true)
        let verified = try await directory.safetyNumberIdentity(userId: bruno.userId)
        XCTAssertEqual(verified, E2EEV2SafetyNumberIdentity(userId: bruno.userId, uikX963B64: newUIK, status: .verified))
    }

    func testAReadInFlightKeepsAVerificationMadeMeanwhile() async throws {
        let bruno = Account("bruno")
        let served = try bundle(bruno, version: 1, features: ["calls"])
        let gate = Gate()
        let pins = E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: pins, ownUserId: alice) { _, _ in
            await gate.pass()
            return served
        }
        _ = try await directory.certifiedDevices(for: [bruno.userId])

        gate.closeNext()
        let inFlight = Task { try await directory.certifiedDevices(for: [bruno.userId]) }
        await gate.waitForArrival()
        try await directory.setVerified(true, userId: bruno.userId, uikX963B64: bruno.uik.publicKey.x963Representation.base64EncodedString())
        gate.open()
        _ = try await inFlight.value
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.verified, true,
                       "La lecture partie avant la vérification ne l'efface pas")
    }

    func testAnOlderReadNeverRollsTheListBack() async throws {
        let bruno = Account("bruno")
        let gate = Gate()
        let responses = Responses([
            try bundle(bruno, version: 1, features: ["calls"]),
            try bundle(bruno, version: 2, features: ["calls"], chainFrom: 1),
            try bundle(bruno, version: 3, features: ["calls"], chainFrom: 1),
        ])
        let pins = E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: pins) { _, _ in
            let response = responses.next()
            if response.index == 1 { await gate.pass() }
            return response.data
        }
        _ = try await directory.certifiedDevices(for: [bruno.userId])

        gate.closeNext()
        let older = Task { try await directory.certifiedDevices(for: [bruno.userId]) }
        await gate.waitForArrival()
        _ = try await directory.certifiedDevices(for: [bruno.userId])
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.listVersion, 3)
        gate.open()
        let olderSet = try await older.value
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.listVersion, 3,
                       "Le résultat plus ancien n'écrase pas la liste plus récente")
        XCTAssertEqual(olderSet.refusals, [:], "Relue contre la liste la plus récente, elle est acceptée")
        XCTAssertNotNil(olderSet.device(userId: bruno.userId, deviceId: bruno.deviceId))
        XCTAssertEqual(responses.count, 4, "La lecture périmée a été refaite")
    }

    func testAFirstContactReadAgainstAStalePinBelievesNothing() async throws {
        // Deux premiers contacts concurrents, servis avec deux UIK différentes.
        let bruno = Account("bruno"), forged = Account(userId: bruno.userId, deviceId: "device_forged_ios_01J7ABCD")
        let gate = Gate()
        let responses = Responses([
            try bundle(forged, version: 1, features: ["calls"]),
            try bundle(bruno, version: 1, features: ["calls"]),
            try bundle(forged, version: 1, features: ["calls"]),
        ])
        let pins = E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: pins, ownUserId: alice) { _, _ in
            let response = responses.next()
            if response.index == 0 { await gate.pass() }
            return response.data
        }
        gate.closeNext()
        let first = Task { try await directory.certifiedDevices(for: [bruno.userId]) }
        await gate.waitForArrival()
        let shown = try await directory.safetyNumberIdentity(userId: bruno.userId)
        XCTAssertEqual(shown.uikX963B64, bruno.uik.publicKey.x963Representation.base64EncodedString())
        gate.open()
        let set = try await first.value
        XCTAssertNil(set.device(deviceId: forged.deviceId), "Rien n'est cru d'un paquet lu contre un pin périmé")
        XCTAssertEqual(set.refusals, [bruno.userId: .uikChanged], "Relu contre la clé épinglée, l'autre clé est refusée")
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.uikX963B64,
                       bruno.uik.publicKey.x963Representation.base64EncodedString(), "La clé montrée reste épinglée")
    }

    func testCapabilitySequencesNeverGoBack() async throws {
        let bruno = Account("bruno")
        let gate = Gate()
        let responses = Responses([
            try bundle(bruno, version: 1, features: ["calls"], capabilitySequence: 1),
            try bundle(bruno, version: 1, features: ["calls"], capabilitySequence: 1),
            try bundle(bruno, version: 1, features: ["calls"], capabilitySequence: 2),
            try bundle(bruno, version: 1, features: ["calls"], capabilitySequence: 2),
        ])
        let pins = E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: pins) { _, _ in
            let response = responses.next()
            if response.index == 1 { await gate.pass() }
            return response.data
        }
        _ = try await directory.certifiedDevices(for: [bruno.userId])
        gate.closeNext()
        let older = Task { try await directory.certifiedDevices(for: [bruno.userId]) }
        await gate.waitForArrival()
        _ = try await directory.certifiedDevices(for: [bruno.userId])
        gate.open()
        _ = try await older.value
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.capabilitySequences[bruno.deviceId], 2,
                       "Une lecture plus ancienne ne fait pas reculer les capacités")
    }

    func testSafetyNumberChoicesNeedAKnownOwnAccountAndAContact() async throws {
        let bruno = Account("bruno")
        let server = Server()
        server.serve(try bundle(bruno, version: 1, features: ["calls"]), for: bruno.userId)
        let uik = bruno.uik.publicKey.x963Representation.base64EncodedString()
        let anonymous = E2EEV2TrustDirectory(
            ownerNamespace: namespace, pins: E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        ) { userId, _ in try server.response(for: userId) }
        await XCTAssertThrowsAsync(try await anonymous.safetyNumberIdentity(userId: bruno.userId),
                                   E2EEV2TrustDirectory.SafetyNumberFailure.ownAccount, "Fermé sans son propre identifiant")

        let pins = E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: pins, ownUserId: alice) { userId, _ in
            try server.response(for: userId)
        }
        await XCTAssertThrowsAsync(try await directory.setVerified(true, userId: alice, uikX963B64: uik),
                                   E2EEV2TrustDirectory.SafetyNumberFailure.ownAccount)
        await XCTAssertThrowsAsync(try await directory.acceptChangedIdentity(userId: alice, uikX963B64: uik, verified: true),
                                   E2EEV2TrustDirectory.SafetyNumberFailure.ownAccount)
        await XCTAssertThrowsAsync(try await directory.acceptChangedIdentity(userId: bruno.userId, uikX963B64: uik, verified: true),
                                   E2EEV2TrustDirectory.SafetyNumberFailure.numberChanged, "Rien d'épinglé : rien à remplacer")
        await XCTAssertThrowsAsync(try await directory.setVerified(true, userId: bruno.userId, uikX963B64: uik),
                                   E2EEV2TrustDirectory.SafetyNumberFailure.numberChanged, "Rien d'épinglé : rien à vérifier")
    }

    func testAcceptingAChangeRefusesAnInvalidNewIdentityOrAPinThatMoved() async throws {
        let bruno = Account("bruno"), reset = Account(userId: bruno.userId, deviceId: "device_bruno_new_01J7ABCD")
        let gate = Gate()
        let responses = LockedValue(try bundle(bruno, version: 1, features: ["calls"]))
        let pins = E2EEV2TrustPinStore(tokenStore: InMemoryTokenStore())
        let directory = E2EEV2TrustDirectory(ownerNamespace: namespace, pins: pins, ownUserId: alice) { _, _ in
            await gate.pass()
            return responses.value
        }
        _ = try await directory.safetyNumberIdentity(userId: bruno.userId)
        let newUIK = reset.uik.publicKey.x963Representation.base64EncodedString()

        // Nouvelle liste signée par une autre clé que la nouvelle UIK : refusée.
        responses.value = try bundle(reset, version: 1, features: ["calls"], listSigner: P256.Signing.PrivateKey())
        await XCTAssertThrowsAsync(
            try await directory.acceptChangedIdentity(userId: bruno.userId, uikX963B64: newUIK, verified: false),
            E2EEV2TrustDirectory.SafetyNumberFailure.refused(.invalidDeviceList)
        )
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.uikX963B64,
                       bruno.uik.publicKey.x963Representation.base64EncodedString())

        // Le pin change pendant la lecture de l'acceptation : rien n'est écrasé.
        responses.value = try bundle(reset, version: 1, features: ["calls"])
        gate.closeNext()
        let accepting = Task {
            try await directory.acceptChangedIdentity(userId: bruno.userId, uikX963B64: newUIK, verified: false)
        }
        await gate.waitForArrival()
        try await directory.setVerified(true, userId: bruno.userId, uikX963B64: bruno.uik.publicKey.x963Representation.base64EncodedString())
        gate.open()
        await XCTAssertThrowsAsync(try await accepting.value, E2EEV2TrustDirectory.SafetyNumberFailure.numberChanged)
        XCTAssertEqual(try pins.pin(userId: bruno.userId, ownerNamespace: namespace)?.uikX963B64,
                       bruno.uik.publicKey.x963Representation.base64EncodedString())
    }

    /// Retient le prochain passage jusqu'à `open()`.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        private var arrived = false

        func closeNext() { lock.withLock { closed = true; arrived = false } }

        func pass() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (held, notify): (Bool, CheckedContinuation<Void, Never>?) = lock.withLock {
                    guard closed else { return (false, nil) }
                    closed = false
                    waiter = continuation
                    arrived = true
                    defer { arrival = nil }
                    return (true, arrival)
                }
                notify?.resume()
                if !held { continuation.resume() }
            }
        }

        func waitForArrival() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let already = lock.withLock {
                    if arrived { return true }
                    arrival = continuation
                    return false
                }
                if already { continuation.resume() }
            }
        }

        func open() {
            let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { waiter = nil }
                return waiter
            }
            held?.resume()
        }
    }

    /// Réponses servies dans l'ordre des appels.
    private final class Responses: @unchecked Sendable {
        private let lock = NSLock()
        private let all: [Data]
        private var index = 0
        init(_ all: [Data]) { self.all = all }
        func next() -> (index: Int, data: Data) {
            lock.withLock {
                defer { index += 1 }
                return (index, all[min(index, all.count - 1)])
            }
        }
        var count: Int { lock.withLock { index } }
    }

    /// Une réponse que le test change entre deux lectures.
    private final class LockedValue: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data
        init(_ value: Data) { stored = value }
        var value: Data {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
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
        next: Int? = nil,
        capabilitySequence: Int = 1,
        listSigner: P256.Signing.PrivateKey? = nil
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
        let signedList = try E2EEV2SignedString.sign(list.canonical, with: listSigner ?? account.uik)
        let certificate = E2EEV2DeviceCertificate(
            userId: account.userId, deviceId: account.deviceId, keyVersion: 1,
            identityKeyB64: account.identity.publicKey.x963Representation.base64EncodedString(),
            signingKeyB64: account.signing.publicKey.x963Representation.base64EncodedString(),
            platform: "ios", createdAtMs: now
        )
        let signedCertificate = try E2EEV2SignedString.sign(certificate.canonical, with: account.uik)
        let document = E2EEV2CapabilitiesDocument(
            userId: account.userId, deviceId: account.deviceId, sequence: capabilitySequence, issuedAtMs: now - 1_000,
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

/// L'expression échoue avec exactement cette erreur.
func XCTAssertThrowsAsync<T, E: Error & Equatable>(
    _ expression: @autoclosure () async throws -> T,
    _ expected: E,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Aucune erreur levée. \(message)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? E, expected, message, file: file, line: line)
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ key: String) { lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ value: Date) { stored = value }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
