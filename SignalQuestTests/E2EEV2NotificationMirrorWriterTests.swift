import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 5 (plan 3) : entrées du miroir de notification (§2.6), écrites par l'app.
final class E2EEV2NotificationMirrorWriterTests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD23456789"

    func testTheEntryHoldsVerifiedEpochKeysAndCertifiedPublicKeysOnly() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let epochTwo = Data(repeating: 0x42, count: 32)
        try fixture.advance(seeded, to: 2, epochKey: epochTwo)
        let replacedAt = seeded.current.acceptedAtMs + 1_000
        let writer = E2EEV2NotificationMirrorWriter(
            keyStore: fixture.keys, stateStore: fixture.states,
            contextStore: E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore()),
            now: { Date(timeIntervalSince1970: Double(replacedAt + 60_000) / 1_000) }
        )
        let entry = try XCTUnwrap(writer.entry(conversationId: seeded.conversationId, devices: devices, ownerNamespace: fixture.session.ownerNamespace))
        XCTAssertTrue(entry.isStructurallyValid)
        XCTAssertEqual(entry.epochs.map(\.epochNumber), [2, 1], "La courante, puis celle remplacée depuis une minute")
        XCTAssertEqual(entry.epochs.first?.keyB64, epochTwo.base64EncodedString())
        XCTAssertNil(entry.epochs.first?.replacedAtMs)
        XCTAssertEqual(entry.epochs.last?.keyB64, seeded.epochKey.base64EncodedString())
        XCTAssertEqual(Set(entry.epochs.last?.memberIds ?? []), [fixture.user, bruno])
        XCTAssertEqual(entry.signingKeys[E2EEV2NotificationConversation.signingKeyName(userId: bruno, deviceId: phone.device.deviceId)],
                       phone.device.signingKeyB64)
        XCTAssertEqual(entry.signingKeys[E2EEV2NotificationConversation.signingKeyName(userId: fixture.user, deviceId: fixture.descriptor.deviceId)],
                       fixture.descriptor.publicSigningKeyB64, "Ses propres autres appareils aussi")

        let later = E2EEV2NotificationMirrorWriter(
            keyStore: fixture.keys, stateStore: fixture.states,
            contextStore: E2EEV2NotificationContextStore(tokenStore: InMemoryTokenStore()),
            now: { Date(timeIntervalSince1970: Double(replacedAt + 25 * 3_600_000) / 1_000) }
        )
        let next = try XCTUnwrap(later.entry(conversationId: seeded.conversationId, devices: devices, ownerNamespace: fixture.session.ownerNamespace))
        XCTAssertEqual(next.epochs.map(\.epochNumber), [2], "Remplacée depuis plus de 24 heures : sa clé quitte le miroir")
    }

    func testNothingIsWrittenWithoutAnActiveContext() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = E2EEV2TestRemote(user: bruno, device: "device_bruno_android_01J7ABCD")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try fixture.seedConversation(with: bruno, devices: devices)
        let memory = InMemoryTokenStore()
        let writer = E2EEV2NotificationMirrorWriter(
            keyStore: fixture.keys, stateStore: fixture.states, contextStore: E2EEV2NotificationContextStore(tokenStore: memory)
        )
        XCTAssertFalse(writer.update(conversationId: seeded.conversationId, devices: devices, ownerNamespace: fixture.session.ownerNamespace))
        XCTAssertTrue(try memory.keys(withPrefix: "").isEmpty, "Verrou fermé, ou aucun aperçu : aucune clé d'époque dans le groupe partagé")
    }
}
