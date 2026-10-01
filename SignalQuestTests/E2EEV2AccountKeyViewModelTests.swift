import CryptoKit
import XCTest
@testable import SignalQuest

/// Clé de ton compte (§2.3, D.12) : les 30 chiffres montrés sont ceux de la
/// clé gardée, et seule la clé montrée peut être marquée vérifiée.
@MainActor
final class E2EEV2AccountKeyViewModelTests: XCTestCase {
    private let userId = "user_alice_qa_01J7ABCD2345"
    private let namespace = "ns-account-key"

    private func key(_ byte: UInt8) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    func testAnApprovedDeviceShowsItsKeyDigitsThenMarksThemVerified() async throws {
        let tokens = InMemoryTokenStore()
        let store = E2EEV2AccountIdentityStore(tokenStore: tokens) { _ in true }
        let uik = try key(0x11)
        try store.install(uik, ownerNamespace: namespace)
        let model = E2EEV2AccountKeyViewModel(ownUserId: userId, ownerNamespace: namespace, store: store)
        await model.load()
        guard case .ready(let shown) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(shown.digits, E2EEV2SafetyNumber.digits(uikX963: uik.publicKey.x963Representation, userId: userId))
        XCTAssertEqual(shown.digits.count, 30)
        XCTAssertEqual(shown.groups.count, 6)
        XCTAssertFalse(shown.verified, "Reçue à l'approbation : non vérifiée")

        await model.markVerified(shown)
        guard case .ready(let after) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertTrue(after.verified)
        XCTAssertEqual(after.digits, shown.digits)
        XCTAssertTrue(try store.isVerified(ownerNamespace: namespace))
        XCTAssertNil(model.actionError)
    }

    /// Clé remplacée entre l'affichage et le geste : rien n'est marqué, les
    /// nouveaux chiffres s'affichent.
    func testOnlyTheKeyThatWasShownCanBeMarkedVerified() async throws {
        let tokens = InMemoryTokenStore()
        let store = E2EEV2AccountIdentityStore(tokenStore: tokens) { _ in true }
        try store.install(try key(0x11), ownerNamespace: namespace)
        let model = E2EEV2AccountKeyViewModel(ownUserId: userId, ownerNamespace: namespace, store: store)
        await model.load()
        guard case .ready(let shown) = model.state else { return XCTFail("\(model.state)") }

        try tokens.remove(E2EEV2AccountIdentityStore.key(ownerNamespace: namespace))
        try store.install(try key(0x22), ownerNamespace: namespace)
        await model.markVerified(shown)
        XCTAssertFalse(try store.isVerified(ownerNamespace: namespace), "Une autre clé que celle montrée")
        XCTAssertNotNil(model.actionError)
        guard case .ready(let reloaded) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertNotEqual(reloaded.digits, shown.digits)
        XCTAssertFalse(reloaded.verified)
    }

    func testWithoutAKeyNothingIsShown() async {
        let store = E2EEV2AccountIdentityStore(tokenStore: InMemoryTokenStore()) { _ in true }
        let model = E2EEV2AccountKeyViewModel(ownUserId: userId, ownerNamespace: namespace, store: store)
        await model.load()
        XCTAssertEqual(model.state, .failed(String(localized: "Cet appareil n’a pas encore la clé de ton compte.")))
    }
}
