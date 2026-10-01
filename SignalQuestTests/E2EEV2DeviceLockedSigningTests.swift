import CryptoKit
import os
import Security
import XCTest
@testable import SignalQuest

/// Spec §2.6 (v0.4.13) : un appel chiffré se rejoint écran verrouillé. Seule la
/// clé de signature de l'appareil reste utilisable verrouillé, et
/// « verrouillé » n'est jamais « perdu ».
final class E2EEV2DeviceLockedSigningTests: XCTestCase {
    /// Trousseau qui refuse, verrouillé, ce qui est rangé « appareil déverrouillé ».
    private final class LockableTokenStore: TokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: (value: String, accessibility: KeychainAccessibility)] = [:]
        private var readHooks: [String: () -> Void] = [:]
        var locked = false
        var failingRemovals: Set<String> = []

        func string(for key: String) throws -> String? {
            let (item, hook) = lock.withLock { (values[key], readHooks.removeValue(forKey: key)) }
            // Après la lecture, hors du verrou : le crochet peut relire le trousseau.
            hook?()
            guard let item else { return nil }
            if locked && item.accessibility == .whenUnlocked {
                throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed)
            }
            return item.value
        }

        func set(_ value: String, for key: String, accessibility: KeychainAccessibility) throws {
            if locked && accessibility == .whenUnlocked { throw KeychainError.unexpectedStatus(errSecInteractionNotAllowed) }
            lock.withLock { values[key] = (value, accessibility) }
        }

        func remove(_ key: String) throws {
            if failingRemovals.contains(key) { throw KeychainError.unexpectedStatus(errSecIO) }
            lock.withLock { values[key] = nil }
        }

        func keys(withPrefix prefix: String) throws -> [String] { lock.withLock { values.keys.filter { $0.hasPrefix(prefix) } } }
        func removeAll() throws { lock.withLock { values.removeAll() } }
        func accessibility(of key: String) -> KeychainAccessibility? { lock.withLock { values[key]?.accessibility } }
        /// Une seule fois, juste après la prochaine lecture de `key`.
        func afterNextRead(of key: String, _ hook: @escaping () -> Void) { lock.withLock { readHooks[key] = hook } }
    }

    private let namespace = "ns-locked-signing"
    private let message = Data("SQ-E2EE-V2-SIGNED-REQUEST\n1\nPOST\n/api/calls/answer".utf8)

    private func makeStore(_ tokens: LockableTokenStore) -> E2EEV2DeviceIdentityStore {
        E2EEV2DeviceIdentityStore(tokenStore: tokens, allowsOwner: { _ in true }, identityChanged: { _ in })
    }

    private func verify(_ signature: Data, by descriptor: E2EEV2DeviceDescriptor) throws -> Bool {
        let key = try P256.Signing.PublicKey(x963Representation: XCTUnwrap(Data(base64Encoded: descriptor.publicSigningKeyB64)))
        return key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature), for: message)
    }

    func testOnlyTheSigningKeyStillWorksWhenLocked() throws {
        let tokens = LockableTokenStore()
        let store = makeStore(tokens)
        let descriptor = try store.loadOrCreate(ownerNamespace: namespace)
        let copyKey = E2EEV2DeviceIdentityStore.lockedSigningStorageKey(ownerNamespace: namespace)
        XCTAssertEqual(tokens.accessibility(of: copyKey), .afterFirstUnlock, "Lisible dès le premier déverrouillage")
        XCTAssertEqual(tokens.accessibility(of: store.storageKey(ownerNamespace: namespace)), .whenUnlocked,
                       "La clé d'accord reste derrière le déverrouillage")

        tokens.locked = true
        let signature = try store.sign(canonicalRequest: message, ownerNamespace: namespace)
        XCTAssertTrue(try verify(signature, by: descriptor))
        let signed = try store.signWithDeviceId(canonicalRequest: message, ownerNamespace: namespace)
        XCTAssertEqual(signed.deviceId, descriptor.deviceId)
        XCTAssertTrue(try verify(signed.signature, by: descriptor))
        XCTAssertThrowsError(try store.load(ownerNamespace: namespace), "Le reste de l'identité est illisible") {
            XCTAssertTrue(E2EEV2DeviceIdentityStore.isLocked($0))
        }
    }

    /// Sans copie encore écrite : « verrouillé », jamais une nouvelle identité.
    func testLockedIsNeverMistakenForLost() throws {
        let tokens = LockableTokenStore()
        let store = makeStore(tokens)
        let descriptor = try store.loadOrCreate(ownerNamespace: namespace)
        let copyKey = E2EEV2DeviceIdentityStore.lockedSigningStorageKey(ownerNamespace: namespace)
        try tokens.remove(copyKey)

        tokens.locked = true
        XCTAssertThrowsError(try store.sign(canonicalRequest: message, ownerNamespace: namespace)) {
            XCTAssertEqual($0 as? E2EEV2DeviceIdentityError, .locked)
        }
        XCTAssertThrowsError(try store.loadOrCreate(ownerNamespace: namespace)) {
            XCTAssertTrue(E2EEV2DeviceIdentityStore.isLocked($0), "Aucune nouvelle identité verrouillé")
        }

        tokens.locked = false
        XCTAssertEqual(try store.loadOrCreate(ownerNamespace: namespace).deviceId, descriptor.deviceId, "Même identité au déverrouillage")
        XCTAssertNotNil(try tokens.string(for: copyKey), "La copie s'écrit à la lecture suivante")
    }

    func testAReplacementIdentityNeverLeavesTheOldKeyInTheLockedCopy() throws {
        let tokens = LockableTokenStore()
        let store = makeStore(tokens)
        let old = try store.loadOrCreate(ownerNamespace: namespace)
        let candidate = try store.prepareResetCandidate(ownerNamespace: namespace)
        try store.activateResetCandidate(ownerNamespace: namespace, expectedDeviceId: candidate.deviceId)

        tokens.locked = true
        let signed = try store.signWithDeviceId(canonicalRequest: message, ownerNamespace: namespace)
        XCTAssertEqual(signed.deviceId, candidate.deviceId)
        XCTAssertTrue(try verify(signed.signature, by: candidate))
        XCTAssertFalse(try verify(signed.signature, by: old))
    }

    /// Une signature qui a lu l'ancienne clé juste avant le remplacement ne la
    /// recopie pas ensuite dans la copie lisible verrouillé.
    func testASignatureThatReadTheOldKeyDuringAReplacementNeverCopiesIt() throws {
        let tokens = LockableTokenStore()
        let store = makeStore(tokens)
        let old = try store.loadOrCreate(ownerNamespace: namespace)
        let candidate = try store.prepareResetCandidate(ownerNamespace: namespace)
        tokens.afterNextRead(of: store.storageKey(ownerNamespace: namespace)) { [namespace] in
            do {
                try store.activateResetCandidate(ownerNamespace: namespace, expectedDeviceId: candidate.deviceId)
            } catch {
                XCTFail("Remplacement refusé : \(error)")
            }
        }
        XCTAssertTrue(try verify(store.sign(canonicalRequest: message, ownerNamespace: namespace), by: old),
                      "La signature en cours garde la clé qu'elle a lue")

        tokens.locked = true
        let signed = try store.signWithDeviceId(canonicalRequest: message, ownerNamespace: namespace)
        XCTAssertEqual(signed.deviceId, candidate.deviceId)
        XCTAssertTrue(try verify(signed.signature, by: candidate))
    }

    /// Tant que l'ancienne clé ne peut pas quitter la copie, rien ne change.
    func testAReplacementWaitsUntilTheOldKeyLeavesTheLockedCopy() throws {
        let tokens = LockableTokenStore()
        let store = makeStore(tokens)
        let old = try store.loadOrCreate(ownerNamespace: namespace)
        let candidate = try store.prepareResetCandidate(ownerNamespace: namespace)
        tokens.failingRemovals = [E2EEV2DeviceIdentityStore.lockedSigningStorageKey(ownerNamespace: namespace)]
        XCTAssertThrowsError(try store.activateResetCandidate(ownerNamespace: namespace, expectedDeviceId: candidate.deviceId))
        XCTAssertEqual(try store.load(ownerNamespace: namespace)?.deviceId, old.deviceId)
        XCTAssertEqual(try store.loadResetCandidate(ownerNamespace: namespace)?.deviceId, candidate.deviceId, "Reprise possible")

        tokens.failingRemovals = []
        try store.activateResetCandidate(ownerNamespace: namespace, expectedDeviceId: candidate.deviceId)
        tokens.locked = true
        XCTAssertEqual(try store.signWithDeviceId(canonicalRequest: message, ownerNamespace: namespace).deviceId, candidate.deviceId)
    }

    /// Deux premières requêtes signées simultanées : une seule identité.
    func testConcurrentFirstUsesCreateASingleIdentity() {
        let tokens = LockableTokenStore()
        let store = makeStore(tokens)
        let deviceIds = OSAllocatedUnfairLock(initialState: Set<String>())
        let message = message, namespace = namespace
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            guard let signed = try? store.signWithDeviceId(canonicalRequest: message, ownerNamespace: namespace) else { return }
            deviceIds.withLock { _ = $0.insert(signed.deviceId) }
        }
        let created = deviceIds.withLock { $0 }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(try store.load(ownerNamespace: namespace)?.deviceId, created.first)
    }

    func testTheLockedCopyLeavesWithTheAccount() throws {
        let tokens = LockableTokenStore()
        let ownerScopeId = "user:" + String(repeating: "c", count: 64)
        let ownNamespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        let store = makeStore(tokens)
        _ = try store.loadOrCreate(ownerNamespace: ownNamespace)
        let copyKey = E2EEV2DeviceIdentityStore.lockedSigningStorageKey(ownerNamespace: ownNamespace)
        XCTAssertNotNil(try tokens.string(for: copyKey))
        try E2EEV2VaultBoundary.purge(store: tokens, ownerScopeId: ownerScopeId)
        XCTAssertNil(try tokens.string(for: copyKey))
    }

    /// Un effacement qui échoue n'arrête pas les autres ; la copie part d'abord.
    func testTheAccountErasureTriesEverythingAndReportsTheFailure() throws {
        let tokens = LockableTokenStore()
        let ownerScopeId = "user:" + String(repeating: "d", count: 64)
        let ownNamespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        let store = makeStore(tokens)
        _ = try store.loadOrCreate(ownerNamespace: ownNamespace)
        let mainKey = store.storageKey(ownerNamespace: ownNamespace)
        let indexKey = "epoch-v2-owner-index:\(ownNamespace)"
        try tokens.set("{}", for: indexKey, accessibility: .afterFirstUnlock)
        tokens.failingRemovals = [mainKey]

        XCTAssertThrowsError(try E2EEV2VaultBoundary.purge(store: tokens, ownerScopeId: ownerScopeId))
        XCTAssertNil(try tokens.string(for: E2EEV2DeviceIdentityStore.lockedSigningStorageKey(ownerNamespace: ownNamespace)))
        XCTAssertNil(try tokens.string(for: indexKey), "Les autres effacements sont tentés")
        XCTAssertNotNil(try tokens.string(for: mainKey))
    }

    /// Déconnexion : la clé de signature n'est plus lisible verrouillé, et une
    /// signature sans session ne la recopie pas.
    func testLogoutTakesTheSigningKeyOutOfTheLockedCopy() async throws {
        let previousUserId = LocalAccountScope.currentUserId
        LocalAccountScope.activate(userId: "locked-signing-logout")
        defer {
            if let previousUserId { LocalAccountScope.activate(userId: previousUserId) } else { LocalAccountScope.deactivate() }
        }
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let ownNamespace = LocalAccountScope.storageNamespace(for: session.ownerScopeId)
        let tokens = LockableTokenStore()
        let store = E2EEV2DeviceIdentityStore(tokenStore: tokens, identityChanged: { _ in })
        _ = try store.loadOrCreate(ownerNamespace: ownNamespace)
        let copyKey = E2EEV2DeviceIdentityStore.lockedSigningStorageKey(ownerNamespace: ownNamespace)
        XCTAssertNotNil(try tokens.string(for: copyKey))

        let api = APIClient(config: .test, cookieStore: AuthCookieStore(tokenStore: InMemoryTokenStore()))
        await E2EEService(api: api, tokenStore: tokens, privacyLock: {}).lockLocalKeys(expectedSession: session)

        XCTAssertNil(try tokens.string(for: copyKey))
        XCTAssertNotNil(try tokens.string(for: store.storageKey(ownerNamespace: ownNamespace)), "L'identité reste, verrouillée")
        XCTAssertThrowsError(try store.sign(canonicalRequest: message, ownerNamespace: ownNamespace))
        XCTAssertNil(try tokens.string(for: copyKey))
    }

    /// Verrouillé sans copie : la requête n'est pas envoyée, et l'échec dit de
    /// déverrouiller au lieu d'un état local invalide.
    func testALockedDeviceAsksToUnlockAndSendsNothing() async throws {
        let previousUserId = LocalAccountScope.currentUserId
        LocalAccountScope.activate(userId: "locked-signing-transport")
        defer {
            if let previousUserId { LocalAccountScope.activate(userId: previousUserId) } else { LocalAccountScope.deactivate() }
        }
        let session = try XCTUnwrap(LocalAccountScope.sessionSnapshot())
        let ownNamespace = LocalAccountScope.storageNamespace(for: session.ownerScopeId)
        let tokens = LockableTokenStore()
        let store = makeStore(tokens)
        _ = try store.loadOrCreate(ownerNamespace: ownNamespace)
        try tokens.remove(E2EEV2DeviceIdentityStore.lockedSigningStorageKey(ownerNamespace: ownNamespace))
        tokens.locked = true

        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockURLProtocol.requestHandler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("locked-signing-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let result = await E2EEV2APITransport(api: api, identityStore: store).postJSON(
            path: "/api/calls/answer",
            body: Data("{}".utf8),
            expectedOwnerScopeId: session.ownerScopeId,
            capabilitySet: .calls
        )

        guard case .failure(let failure) = result else { return XCTFail("Aucune requête signée verrouillé sans copie") }
        XCTAssertEqual(failure.kind, .retryable)
        XCTAssertEqual(failure.message, "e2ee-device-locked")
        XCTAssertEqual(requestCount, 0)
        XCTAssertNotEqual(
            CallsServiceError.e2eeUnavailable(failure.message).errorDescription,
            CallsServiceError.e2eeUnavailable("e2ee-transport-unavailable").errorDescription,
            "L'appel dit de déverrouiller"
        )
    }
    /// D.0 : DER canonique, forme low-S, quelle que soit la clé (v0.4.14).
    func testEverySignatureIsLowSAndVerifies() throws {
        let tokens = LockableTokenStore()
        let store = makeStore(tokens)
        let descriptor = try store.loadOrCreate(ownerNamespace: namespace)
        let publicKey = try P256.Signing.PublicKey(x963Representation: XCTUnwrap(Data(base64Encoded: descriptor.publicSigningKeyB64)))
        for index in 0..<64 {
            let message = Data("SQ-E2EE-V2-SIGNED-REQUEST\n1\nPOST\n/api/\(index)".utf8)
            let signature = try store.sign(canonicalRequest: message, ownerNamespace: namespace)
            XCTAssertTrue(E2EEV2LowS.isLowS(der: signature), "Signature \(index) en forme high-S")
            XCTAssertTrue(E2EEV2LowS.verify(derSignature: signature, message: message, publicKey: publicKey))
        }
    }

    /// La clé naît dans la Secure Enclave (appareil, ou simulateur d'un Mac Apple
    /// silicon), seul son blob est gardé, et ses signatures suivent le même chemin low-S.
    func testTheSigningKeyLivesInTheSecureEnclave() throws {
        try XCTSkipUnless(E2EEV2DeviceIdentityStore.createsSecureEnclaveKeys, "Pas de Secure Enclave sur cette machine")
        let tokens = LockableTokenStore()
        let store = makeStore(tokens)
        let descriptor = try store.loadOrCreate(ownerNamespace: namespace)
        let raw = try XCTUnwrap(tokens.string(for: store.storageKey(ownerNamespace: namespace)))
        XCTAssertTrue(raw.contains("\"signingStorage\":\"secureEnclave\""))
        let publicKey = try P256.Signing.PublicKey(x963Representation: XCTUnwrap(Data(base64Encoded: descriptor.publicSigningKeyB64)))
        for index in 0..<64 {
            let message = Data("enclave-\(index)".utf8)
            let signature = try store.sign(canonicalRequest: message, ownerNamespace: namespace)
            XCTAssertTrue(E2EEV2LowS.verify(derSignature: signature, message: message, publicKey: publicKey))
        }
    }
}
