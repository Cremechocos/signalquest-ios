import CryptoKit
import XCTest
@testable import SignalQuest

/// Écran du code de sécurité (E2EE-AUTO §7, lot 6c) : le code tiré des deux
/// journaux vérifiés, la marque « vérifié » gardée sur l'appareil, l'avis de
/// changement et la comparaison par QR.
@MainActor
final class E2EEAutoSafetyCodeViewModelTests: XCTestCase {
    private let ownUserId = "user_alice_00000000001"
    private let peerUserId = "user_bruno_00000000002"

    private func account(_ userId: String, seeds: [UInt8]) -> E2EEAutoLog.AccountState {
        var account = E2EEAutoLog.AccountState(userId: userId, accountSaltB64: Data(count: 16).base64EncodedString())
        for seed in seeds {
            let signing = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
                .publicKey.x963Representation.base64EncodedString()
            let id = "device_\(userId.suffix(4))_\(seed)_0000000000"
            account.devices[id] = E2EEAutoLog.DeviceState(
                deviceId: id, platform: .ios, identityKeyB64: signing, signingKeyB64: signing, keyVersion: 1, status: .active,
                addedAtMs: 0, activatedAtMs: 0, addEntryHash: E2EEAutoLog.digest(id), identityKeys: []
            )
        }
        return account
    }

    private func verifications() -> E2EEAutoSafetyCodeVerifications {
        let suite = "e2ee-auto-safety-code-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return E2EEAutoSafetyCodeVerifications(defaults: UserDefaults(suiteName: suite)!)
    }

    private final class Accounts: @unchecked Sendable {
        var read: E2EEAutoSafetyCode.AccountsRead
        init(_ read: E2EEAutoSafetyCode.AccountsRead) { self.read = read }
    }

    private func model(_ accounts: Accounts, _ store: E2EEAutoSafetyCodeVerifications) -> E2EEAutoSafetyCodeViewModel {
        E2EEAutoSafetyCodeViewModel(
            peerUserId: peerUserId, peerName: "Bruno",
            dependencies: .init(readAccounts: { accounts.read }, verifications: store, ownerNamespace: "ns")
        )
    }

    private func content(_ model: E2EEAutoSafetyCodeViewModel, file: StaticString = #filePath, line: UInt = #line) throws -> E2EEAutoSafetyCodeViewModel.Content {
        guard case .ready(let content) = model.state else {
            XCTFail("état : \(model.state)", file: file, line: line)
            throw CocoaError(.coderInvalidValue)
        }
        return content
    }

    func testMarkedCodeTurnsChangedWhenADeviceIsAddedAndClearsBack() async throws {
        let own = account(ownUserId, seeds: [0x11]), peer = account(peerUserId, seeds: [0x21])
        let accounts = Accounts(.verified(own: own, peer: peer))
        let store = verifications()
        let model = model(accounts, store)
        await model.load()
        var shown = try content(model)
        XCTAssertEqual(shown.status, .unverified)
        XCTAssertEqual(shown.code, E2EEAutoSafetyCode.code(own, peer))
        XCTAssertEqual(shown.code.groups.count, 12)
        XCTAssertNotNil(shown.qrImage)

        model.markVerified(shown)
        shown = try content(model)
        XCTAssertEqual(shown.status, .verified)
        XCTAssertEqual(store.verifiedDigits(peerUserId: peerUserId, ownerNamespace: "ns"), shown.code.digits)

        // Bruno ajoute un appareil : le code change, la marque reste sur l'ancien.
        accounts.read = .verified(own: own, peer: account(peerUserId, seeds: [0x21, 0x22]))
        await model.load()
        let changed = try content(model)
        XCTAssertEqual(changed.status, .changed)
        XCTAssertNotEqual(changed.code, shown.code)

        // Un geste sur un code déjà remplacé ne fait rien.
        model.markVerified(shown)
        XCTAssertEqual(try content(model).status, .changed)

        model.markVerified(changed)
        XCTAssertEqual(try content(model).status, .verified)
        model.clearVerification(try content(model))
        XCTAssertEqual(try content(model).status, .unverified)
        XCTAssertNil(store.verifiedDigits(peerUserId: peerUserId, ownerNamespace: "ns"))
    }

    func testScannedCodeVerifiesOnlyTheSameCode() async throws {
        let own = account(ownUserId, seeds: [0x11]), peer = account(peerUserId, seeds: [0x21])
        let model = model(Accounts(.verified(own: own, peer: peer)), verifications())
        await model.load()
        let shown = try content(model)

        model.scanned("https://example.com")
        XCTAssertEqual(model.scanResult, .notACode)

        // Le code de l'autre côté ne voit pas encore un appareil : différent, rien n'est marqué.
        let other = try XCTUnwrap(E2EEAutoSafetyCode.code(own, account(peerUserId, seeds: [0x21, 0x22])))
        model.scanned(other.qr)
        XCTAssertEqual(model.scanResult, .mismatch)
        XCTAssertEqual(try content(model).status, .unverified)

        // Le même code des deux côtés : vérifié.
        model.scanned(shown.code.qr)
        XCTAssertEqual(model.scanResult, .match)
        XCTAssertEqual(try content(model).status, .verified)
    }

    func testUnreadableLogsAndOwnAccountSayWhy() async {
        let accounts = Accounts(.refused)
        let model = model(accounts, verifications())
        await model.load()
        guard case .failed(let refused) = model.state else { return XCTFail("\(model.state)") }

        accounts.read = .inconclusive
        await model.load()
        guard case .failed(let inconclusive) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertNotEqual(refused, inconclusive)

        let own = account(ownUserId, seeds: [0x11])
        accounts.read = .verified(own: own, peer: own)
        await model.load()
        guard case .failed = model.state else { return XCTFail("\(model.state)") }
    }

    func testVerificationsArePerAccountAndPerContact() {
        let store = verifications()
        store.setVerified("1", peerUserId: "a", ownerNamespace: "ns1")
        store.setVerified("2", peerUserId: "b", ownerNamespace: "ns1")
        XCTAssertNil(store.verifiedDigits(peerUserId: "a", ownerNamespace: "ns2"))
        XCTAssertEqual(store.verifiedDigits(peerUserId: "b", ownerNamespace: "ns1"), "2")
        store.setVerified(nil, peerUserId: "a", ownerNamespace: "ns1")
        XCTAssertNil(store.verifiedDigits(peerUserId: "a", ownerNamespace: "ns1"))
        XCTAssertEqual(store.verifiedDigits(peerUserId: "b", ownerNamespace: "ns1"), "2")
    }
}
