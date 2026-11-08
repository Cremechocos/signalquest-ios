import CryptoKit
import XCTest
@testable import SignalQuest

/// Signataires d'avant la bascule (E2EE-AUTO §12, avant l'étape 5) : une
/// genèse, sa chaîne ou une époque non marquée signées par un appareil v2
/// jamais repris au journal se vérifient par ses certificats v2, et seulement
/// lui.
final class E2EEAutoLegacySignerTests: XCTestCase {
    private static let userId = "user_alice_00000000001"
    private static let salt = Data(repeating: 7, count: 16).base64EncodedString()

    private func state(_ deviceId: String, status: E2EEAutoLog.DeviceStatus = .active) -> E2EEAutoLog.DeviceState {
        let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation.base64EncodedString()
        return E2EEAutoLog.DeviceState(
            deviceId: deviceId, platform: .ios, identityKeyB64: key,
            signingKeyB64: P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString(),
            keyVersion: 1, status: status, addedAtMs: 1, activatedAtMs: 1,
            addEntryHash: E2EEAutoLog.digest("add-\(deviceId)"),
            identityKeys: [.init(keyVersion: 1, identityKeyB64: key, sinceMs: 1)],
            revokeReason: status == .revoked ? .user : nil, revokeSeq: status == .revoked ? 9 : nil,
            revokedAtMs: status == .revoked ? 2 : nil
        )
    }

    private func set(log devices: [E2EEAutoLog.DeviceState]?, legacy: [E2EEAutoLog.DeviceState]) -> E2EEV2CertifiedDeviceSet {
        var set = E2EEV2CertifiedDeviceSet(devicesByUser: [:], refusals: [:])
        if let devices {
            var account = E2EEAutoLog.AccountState(userId: Self.userId, accountSaltB64: Self.salt)
            for device in devices { account.devices[device.deviceId] = device }
            set = E2EEAutoDeviceDirectory.deviceSet(accounts: [Self.userId: .success(account)])
        }
        set.legacyDevicesByUser[Self.userId] = legacy.map { E2EEAutoDeviceDirectory.certifiedDevice(userId: Self.userId, device: $0) }
        return set
    }

    func testActiveDeviceSignsFromTheLog() {
        let active = state("ios_device_active_000000")
        let devices = set(log: [active], legacy: [])
        XCTAssertEqual(
            devices.priorSigningKey(userId: Self.userId, deviceId: active.deviceId)?.x963Representation.base64EncodedString(),
            active.signingKeyB64
        )
        XCTAssertFalse(devices.needsLegacySigner(userId: Self.userId, deviceId: active.deviceId))
    }

    func testDeviceAbsentFromTheLogSignsFromItsV2Certificate() {
        let old = state("ios_device_old_v2_000000")
        var devices = set(log: [state("ios_device_active_000000")], legacy: [])
        devices.legacyDevicesByUser = [:]
        XCTAssertNil(devices.signingKey(userId: Self.userId, deviceId: old.deviceId))
        XCTAssertTrue(devices.needsLegacySigner(userId: Self.userId, deviceId: old.deviceId))

        devices = set(log: [state("ios_device_active_000000")], legacy: [old])
        XCTAssertEqual(
            devices.priorSigningKey(userId: Self.userId, deviceId: old.deviceId)?.x963Representation.base64EncodedString(),
            old.signingKeyB64
        )
        // Lu une fois : plus rien à demander, même si le v2 ne l'a pas servi.
        XCTAssertFalse(set(log: [], legacy: []).needsLegacySigner(userId: Self.userId, deviceId: old.deviceId))
    }

    func testDeviceKnownToTheLogNeverComesBackFromV2() {
        let revoked = state("ios_device_revoked_00000", status: .revoked)
        let devices = set(log: [revoked], legacy: [revoked])
        XCTAssertNil(devices.priorSigningKey(userId: Self.userId, deviceId: revoked.deviceId))
        XCTAssertFalse(devices.needsLegacySigner(userId: Self.userId, deviceId: revoked.deviceId))
    }

    func testAccountWithoutVerifiedLogNeverUsesV2() {
        let old = state("ios_device_old_v2_000000")
        let devices = set(log: nil, legacy: [old])
        XCTAssertNil(devices.priorSigningKey(userId: Self.userId, deviceId: old.deviceId))
        XCTAssertFalse(devices.needsLegacySigner(userId: Self.userId, deviceId: old.deviceId))
    }
}
