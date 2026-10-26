import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 5 (E2EE-AUTO §2.2, §5.1) : HK rangée sous sa clé publique, et rendue
/// seulement si elle lui correspond.
final class E2EEAutoHistoryKeyStoreTests: XCTestCase {
    private let userId = "user_alice_00000000001"

    func testACreatedKeyIsKeptUnderItsPublicKey() throws {
        let store = E2EEAutoHistoryKeyStore(store: InMemoryTokenStore())
        let hkPubB64 = try store.create(userId: userId)
        let scalar = try XCTUnwrap(try store.scalar(userId: userId, hkPubB64: hkPubB64))
        XCTAssertEqual(E2EEAutoHistoryKey.publicKeyB64(scalar: scalar), hkPubB64)
        XCTAssertNil(try store.scalar(userId: "user_bob_0000000000002", hkPubB64: hkPubB64), "Rangée par compte")
        XCTAssertNotEqual(try store.create(userId: userId), hkPubB64, "Une nouvelle HK à chaque création")
        XCTAssertNotNil(try store.scalar(userId: userId, hkPubB64: hkPubB64), "Les anciennes HK restent (§5.6)")

        try store.discard(userId: userId, hkPubB64: hkPubB64)
        XCTAssertNil(try store.scalar(userId: userId, hkPubB64: hkPubB64))
    }

    func testOnlyAValidScalarIsKeptAndOnlyAMatchingOneIsReturned() throws {
        let tokens = InMemoryTokenStore()
        let store = E2EEAutoHistoryKeyStore(store: tokens)
        XCTAssertThrowsError(try store.keep(scalar: Data(count: 32), userId: userId))
        XCTAssertThrowsError(try store.keep(scalar: Data(E2EEV2LowS.curveOrder), userId: userId), "n n'est pas dans [1, n − 1]")

        // Une entrée synchronisée dont le scalaire n'est pas celui de la clé est ignorée.
        let hkPubB64 = try store.create(userId: userId)
        let key = try XCTUnwrap(try tokens.keys(withPrefix: "hk-v1:\(userId):").first)
        let other = P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        try tokens.set(#"{"hkPubB64":"\#(hkPubB64)","scalarB64":"\#(other)"}"#, for: key, accessibility: .afterFirstUnlock)
        XCTAssertNil(try store.scalar(userId: userId, hkPubB64: hkPubB64))
    }
}
