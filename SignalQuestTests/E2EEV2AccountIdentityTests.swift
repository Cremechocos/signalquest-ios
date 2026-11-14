import CryptoKit
import XCTest
@testable import SignalQuest

/// Clé de compte (UIK) de la v2 à approbations, que seule la vérification des
/// anciens signataires lit encore, et effacement des entrées v2 retirées
/// (E2EE-AUTO lot 10).
final class E2EEV2AccountIdentityTests: XCTestCase {
    fileprivate let userId = "user_alice_01J7ABCD2345"
    private let namespace = "ns-alice"

    private func store(_ key: P256.Signing.PrivateKey, ownerNamespace: String, in tokens: TokenStore) throws {
        try tokens.set(
            key.rawRepresentation.base64EncodedString(),
            for: E2EEV2AccountIdentityStore.key(ownerNamespace: ownerNamespace),
            accessibility: .whenUnlocked
        )
    }

    func testTheAccountKeyIsReadOnlyInItsAccount() throws {
        let tokens = InMemoryTokenStore()
        let accounts = E2EEV2AccountIdentityStore(tokenStore: tokens) { $0 == "ns-alice" }
        XCTAssertNil(try accounts.load(ownerNamespace: namespace))

        let key = P256.Signing.PrivateKey()
        try store(key, ownerNamespace: namespace, in: tokens)
        XCTAssertEqual(try accounts.load(ownerNamespace: namespace)?.rawRepresentation, key.rawRepresentation)
        XCTAssertThrowsError(try accounts.load(ownerNamespace: "ns-other")) {
            XCTAssertEqual($0 as? E2EEV2AccountIdentityStore.Failure, .otherAccount)
        }

        try tokens.set("pas une clé", for: E2EEV2AccountIdentityStore.key(ownerNamespace: namespace), accessibility: .whenUnlocked)
        XCTAssertThrowsError(try accounts.load(ownerNamespace: namespace)) {
            XCTAssertEqual($0 as? E2EEV2AccountIdentityStore.Failure, .invalidRecord)
        }
    }

    func testTheAccountErasurePurgesTheAccountKeyAndTheRetiredEntries() throws {
        let tokens = InMemoryTokenStore()
        let accounts = E2EEV2AccountIdentityStore(tokenStore: tokens) { _ in true }
        let ownerScopeId = "user:\(userId)"
        let ownNamespace = LocalAccountScope.storageNamespace(for: ownerScopeId)
        try store(P256.Signing.PrivateKey(), ownerNamespace: ownNamespace, in: tokens)
        try store(P256.Signing.PrivateKey(), ownerNamespace: "ns-other", in: tokens)
        for key in E2EEV2RetiredStorage.keychainKeys(ownerNamespace: ownNamespace)
            + E2EEV2RetiredStorage.keychainKeys(ownerNamespace: "ns-other") {
            try tokens.set("1", for: key, accessibility: .whenUnlocked)
        }

        try E2EEV2VaultBoundary.purge(store: tokens, ownerScopeId: ownerScopeId)
        XCTAssertNil(try accounts.load(ownerNamespace: ownNamespace))
        for key in E2EEV2RetiredStorage.keychainKeys(ownerNamespace: ownNamespace) {
            XCTAssertNil(try tokens.string(for: key), key)
        }
        XCTAssertNotNil(try accounts.load(ownerNamespace: "ns-other"), "Les autres comptes gardent leur clé")
        for key in E2EEV2RetiredStorage.keychainKeys(ownerNamespace: "ns-other") {
            XCTAssertNotNil(try tokens.string(for: key), "Hors du compte effacé : \(key)")
        }
    }

    /// Une fois par compte : les entrées retirées partent, la clé de compte
    /// reste ; un échec laisse la marque absente et l'effacement repart.
    func testRetiredV2EntriesArePurgedOnceAndTheAccountKeyStays() throws {
        let tokens = InMemoryTokenStore()
        let suite = "e2ee-v2-retired-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = E2EEV2AccountIdentityStore(tokenStore: tokens) { _ in true }
        let key = P256.Signing.PrivateKey()
        try store(key, ownerNamespace: namespace, in: tokens)
        let retired = E2EEV2RetiredStorage.keychainKeys(ownerNamespace: namespace)
        XCTAssertEqual(Set(retired), [
            "uik-verified-v1:\(namespace)", "uik-bootstrap-v1:\(namespace)", "uik-approval-v1:\(namespace)",
            "uik-reset-v1:\(namespace)", "capabilities-v1:\(namespace)", "device-v2-reset-candidate:\(namespace)",
        ])
        for entry in retired { try tokens.set("1", for: entry, accessibility: .whenUnlocked) }
        try tokens.set("1", for: "uik-verified-v1:ns-other", accessibility: .whenUnlocked)

        struct OutboxBusy: Error {}
        var outboxCalls = 0
        XCTAssertFalse(E2EEV2RetiredStorage.purgeIfNeeded(
            ownerNamespace: namespace, store: tokens, defaults: defaults,
            removeOutbox: { outboxCalls += 1; throw OutboxBusy() }
        ))
        for entry in retired { XCTAssertNil(try tokens.string(for: entry), entry) }
        XCTAssertFalse(defaults.bool(forKey: E2EEV2RetiredStorage.doneKey(ownerNamespace: namespace)))

        XCTAssertTrue(E2EEV2RetiredStorage.purgeIfNeeded(
            ownerNamespace: namespace, store: tokens, defaults: defaults, removeOutbox: { outboxCalls += 1 }
        ))
        XCTAssertEqual(outboxCalls, 2, "Repris après l'échec")
        XCTAssertTrue(E2EEV2RetiredStorage.purgeIfNeeded(
            ownerNamespace: namespace, store: tokens, defaults: defaults, removeOutbox: { outboxCalls += 1 }
        ))
        XCTAssertEqual(outboxCalls, 2, "Fait une seule fois par compte")
        XCTAssertEqual(try accounts.load(ownerNamespace: namespace)?.rawRepresentation, key.rawRepresentation,
                       "La clé de compte sert encore aux anciens signataires")
        XCTAssertEqual(try tokens.string(for: "uik-verified-v1:ns-other"), "1", "Les autres comptes attendent leur tour")
    }

    func testTheRetiredOutboxDirectoryGoesWithItsFiles() throws {
        let fileManager = FileManager.default
        let directory = try XCTUnwrap(E2EEV2RetiredStorage.outboxDirectory(fileManager: fileManager))
        XCTAssertEqual(directory.lastPathComponent, "e2ee-v2-outbox")
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "SignalQuestPrivate")
        try fileManager.createDirectory(at: directory.appendingPathComponent("owner", isDirectory: true),
                                        withIntermediateDirectories: true)
        try Data("chiffré".utf8).write(to: directory.appendingPathComponent("owner/blob.bin"))

        try E2EEV2RetiredStorage.removeOutboxDirectory(fileManager: fileManager)
        XCTAssertFalse(fileManager.fileExists(atPath: directory.path))
        XCTAssertNoThrow(try E2EEV2RetiredStorage.removeOutboxDirectory(fileManager: fileManager), "Absent : rien à faire")
    }
}
