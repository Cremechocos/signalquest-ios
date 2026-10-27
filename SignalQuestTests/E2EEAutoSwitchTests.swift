import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 4 (E2EE-AUTO, révision 10, §7.1 et §7.2) : l'interrupteur global du
/// serveur décide du champ envoyé avec une époque, `memberLogSeqs` une fois la
/// bascule faite, `memberListVersions` avant.
final class E2EEAutoSwitchTests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD23456789"

    override func tearDown() {
        E2EEV2ServerGate.autoActiveOverrideForTesting = nil
        super.tearDown()
    }

    // MARK: version-policy

    func testVersionPolicyReadsTheSwitchOnlyFromATrueBoolean() throws {
        func decode(_ extra: String) throws -> AppVersionPolicy {
            try JSONDecoder.signalQuest.decode(
                AppVersionPolicy.self, from: Data(#"{"minVersionCode":1,"recommendedVersionCode":1\#(extra)}"#.utf8)
            )
        }
        XCTAssertTrue(try decode(#","e2eeAutoActive":true"#).e2eeAutoActive)
        XCTAssertFalse(try decode(#","e2eeAutoActive":false"#).e2eeAutoActive)
        XCTAssertFalse(try decode("").e2eeAutoActive, "Champ absent = false")
        XCTAssertFalse(try decode(#","e2eeAutoActive":"true""#).e2eeAutoActive, "Une chaîne n'allume rien")
        XCTAssertFalse(try decode(#","e2eeAutoActive":null"#).e2eeAutoActive)
    }

    /// Le serveur ne rabaisse jamais l'interrupteur : une fois vu, il reste allumé.
    func testTheSwitchOnlyTurnsOn() {
        E2EEV2ServerGate.autoActiveOverrideForTesting = false
        XCTAssertFalse(E2EEV2ServerGate.autoActive)
        XCTAssertTrue(E2EEV2ServerGate.recordAutoActive())
        XCTAssertTrue(E2EEV2ServerGate.autoActive)
        XCTAssertFalse(E2EEV2ServerGate.recordAutoActive(), "Déjà allumé : rien ne change")
        XCTAssertTrue(E2EEV2ServerGate.autoActive)
    }

    /// Un `400 E2EE_AUTO_REQUIRED` vient d'un serveur déjà basculé : l'interrupteur
    /// est retenu allumé et l'opération refaite une fois, comptes relus.
    func testAutoRequiredSwitchesOnAndRetriesOnce() {
        E2EEV2ServerGate.autoActiveOverrideForTesting = false
        let required = E2EEV2TransportFailure(kind: .permanent, statusCode: 400, code: "E2EE_AUTO_REQUIRED", message: "e2ee-auto-required")
        XCTAssertEqual(E2EEV2MessagingRuntime.stale(required), [])
        XCTAssertTrue(E2EEV2ServerGate.autoActive)
        XCTAssertNil(E2EEV2MessagingRuntime.stale(required), "Déjà allumé : un second refus est une erreur, sans boucle")
        let inactive = E2EEV2TransportFailure(kind: .permanent, statusCode: 400, code: "E2EE_AUTO_INACTIVE", message: "e2ee-auto-inactive")
        XCTAssertNil(E2EEV2MessagingRuntime.stale(inactive), "L'interrupteur ne s'éteint jamais")

        // Écriture sous une époque non marquée : `409`, même traitement.
        E2EEV2ServerGate.autoActiveOverrideForTesting = false
        let write = E2EEV2TransportFailure(kind: .permanent, statusCode: 409, code: "E2EE_AUTO_REQUIRED", message: "e2ee-auto-required")
        XCTAssertEqual(E2EEV2MessagingRuntime.stale(write), [])
        XCTAssertTrue(E2EEV2ServerGate.autoActive)
    }

    // MARK: Création

    func testCreationCarriesMemberLogSeqsAtTheRootOnceSwitchedOn() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = remote(user: bruno, device: "device_bruno_android_01J7ABCD")
        var devices = fixture.deviceSet(adding: [phone])
        devices.listVersions = [fixture.user: 3, bruno: 7]
        devices.logSeqs = [fixture.user: 12, bruno: 0, "user_absent_01J7ABCD23456789": 40]

        E2EEV2ServerGate.autoActiveOverrideForTesting = false
        let before = try body(fixture.make(participants: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices, epochKey: key))
        XCTAssertNil(before["memberLogSeqs"], "Avant la bascule : corps v2 inchangé")

        E2EEV2ServerGate.autoActiveOverrideForTesting = true
        let after = try body(fixture.make(participants: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices, epochKey: key))
        XCTAssertEqual(Set(after.keys), ["conversationId", "isGroup", "title", "participantIds", "membership", "epoch", "memberLogSeqs"])
        XCTAssertEqual(after["memberLogSeqs"] as? [String: String], [fixture.user: "12", bruno: "0"], "Exactement les membres, émetteur compris")
        XCTAssertNil((after["epoch"] as? [String: Any])?["memberLogSeqs"], "À la racine, pas dans l'époque")
    }

    func testCreationWaitsForAMemberWhoseLogWasNotRead() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        var devices = fixture.deviceSet(adding: [remote(user: bruno, device: "device_bruno_android_01J7ABCD")])
        devices.logSeqs = [fixture.user: 12]
        E2EEV2ServerGate.autoActiveOverrideForTesting = true
        XCTAssertThrowsError(
            try fixture.make(participants: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices, epochKey: key)
        ) { error in
            XCTAssertEqual(error as? E2EEV2ConversationCreation.Failure, .membersUnlogged([bruno]))
        }
    }

    // MARK: Appels

    /// Le descripteur ne nomme que l'appareil : un même deviceId sous deux
    /// comptes membres, avec deux clés, rend l'appelant indécidable.
    func testACallerDeviceIdSharedByTwoMembersWithTwoKeysIsRefused() {
        let carla = "user_carla_01J7ABCD23456789"
        let shared = "device_shared_01J7ABCD"
        let fromBruno = remote(user: bruno, device: shared)
        let fromCarla = remote(user: carla, device: shared)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        func members(_ devices: [E2EEV2CertifiedDevice], _ ids: Set<String>) -> E2EEV2MessagingRuntime.CallMembers {
            E2EEV2MessagingRuntime.CallMembers(
                devices: E2EEV2CertifiedDeviceSet(devicesByUser: Dictionary(grouping: devices, by: \.userId), refusals: [:]),
                members: ids, excludesWeb: false, ownUserId: "user_own_01J7ABCD23456789", ownerNamespace: "test"
            )
        }
        XCTAssertNil(E2EEV2CallRuntime.callSigningKey(
            deviceId: shared, in: members([fromBruno, fromCarla], [bruno, carla]), nowMs: nowMs
        ))
        XCTAssertEqual(
            E2EEV2CallRuntime.callSigningKey(deviceId: shared, in: members([fromBruno, fromCarla], [bruno]), nowMs: nowMs)?
                .x963Representation.base64EncodedString(),
            fromBruno.signingKeyB64,
            "Un seul membre porte ce deviceId : c'est lui"
        )
    }

    /// Sous une époque marquée, aucun appareil web n'appelle ni ne participe,
    /// quel que soit `excludesWeb` (§7.3, révision 15).
    func testAMarkedEpochKeepsWebDevicesOutOfCalls() {
        func epoch(_ auto: Bool?) -> E2EEV2ConversationStateStore.CurrentEpoch {
            .init(
                conversationId: "conv_01J7ABCD23456789", epochNumber: 2, membershipChangeNumber: 1, memberIds: [bruno],
                recipientsDigest: "digest", excludesWeb: false, createdAtMs: 0, acceptedAtMs: 0, e2eeAuto: auto
            )
        }
        XCTAssertTrue(E2EEV2MessagingRuntime.callExcludesWeb(stored: false, currentEpoch: epoch(true)))
        XCTAssertTrue(E2EEV2MessagingRuntime.callExcludesWeb(stored: true, currentEpoch: epoch(nil)))
        XCTAssertFalse(E2EEV2MessagingRuntime.callExcludesWeb(stored: false, currentEpoch: epoch(nil)))
        XCTAssertFalse(E2EEV2MessagingRuntime.callExcludesWeb(stored: false, currentEpoch: nil))

        let browser = remote(user: bruno, device: "device_web_01J7ABCD", platform: "web")
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        func members(excludesWeb: Bool) -> E2EEV2MessagingRuntime.CallMembers {
            E2EEV2MessagingRuntime.CallMembers(
                devices: E2EEV2CertifiedDeviceSet(devicesByUser: [bruno: [browser]], refusals: [:]),
                members: [bruno], excludesWeb: excludesWeb, ownUserId: "user_own_01J7ABCD23456789", ownerNamespace: "test"
            )
        }
        XCTAssertNotNil(E2EEV2CallRuntime.callSigningKey(deviceId: browser.deviceId, in: members(excludesWeb: false), nowMs: nowMs))
        XCTAssertNil(E2EEV2CallRuntime.callSigningKey(
            deviceId: browser.deviceId,
            in: members(excludesWeb: E2EEV2MessagingRuntime.callExcludesWeb(stored: false, currentEpoch: epoch(true))),
            nowMs: nowMs
        ))
    }

    // MARK: Outils

    private let key = Data((0..<32).map { UInt8($0) })

    private func body(_ creation: E2EEV2ConversationCreation) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: creation.body) as? [String: Any])
    }

    private func remote(user: String, device: String, platform: String = "android") -> E2EEV2CertifiedDevice {
        let agreement = P256.KeyAgreement.PrivateKey()
        let signing = P256.Signing.PrivateKey()
        return E2EEV2CertifiedDevice(
            userId: user, deviceId: device, keyVersion: 1, platform: platform,
            identityKeyB64: agreement.publicKey.x963Representation.base64EncodedString(),
            signingKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            fingerprint: E2EEV2Canonical.deviceFingerprint(
                identityKeyX963: agreement.publicKey.x963Representation,
                signingKeyX963: signing.publicKey.x963Representation
            ),
            capabilities: E2EEV2CapabilitiesDocument(
                userId: user, deviceId: device, sequence: 1, issuedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
                envelopeVersions: ["2"], payloadVersions: ["2"], kinds: ["DELETE", "EDIT", "TEXT"], features: ["calls"]
            )
        )
    }
}
