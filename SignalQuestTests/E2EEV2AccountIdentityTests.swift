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
}
