import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 4c (E2EE-AUTO, révision 10, §3.5 et §7) : une fois la bascule faite,
/// toute conversation naît chiffrée sans repli v1, la version minimale tient
/// lieu de capacités, et un appareil ajouté se voit dans le journal.
final class E2EEAutoNewDeviceTests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD23456789"

    override func tearDown() {
        E2EEV2ServerGate.autoActiveOverrideForTesting = nil
        E2EEV2ServerGate.overrideForTesting = nil
        super.tearDown()
    }

    // MARK: Création et portes

    /// Un membre dont les appareils ne déclarent pas le v2 faisait naître la
    /// conversation en v1 ; après la bascule, elle naît chiffrée.
    func testOnceSwitchedOnCreationNeverFallsBackToV1() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        var devices = fixture.deviceSet(adding: [remote(user: bruno, device: "device_bruno_android_01J7ABCD", kinds: ["DELETE"])])
        devices.logSeqs = [fixture.user: 12, bruno: 3]
        let key = Data((0..<32).map { UInt8($0) })

        E2EEV2ServerGate.autoActiveOverrideForTesting = false
        XCTAssertThrowsError(
            try fixture.make(participants: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices, epochKey: key)
        ) { error in
            XCTAssertEqual(error as? E2EEV2ConversationCreation.Failure, .capabilityMissing)
        }

        E2EEV2ServerGate.autoActiveOverrideForTesting = true
        let creation = try fixture.make(participants: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices, epochKey: key)
        XCTAssertEqual(creation.epoch.recipients.count, 2, "Les deux appareils, sans regarder leurs capacités")
    }

    func testOnceSwitchedOnTheGatesNoLongerWaitForCapabilities() {
        E2EEV2ServerGate.overrideForTesting = []
        E2EEV2ServerGate.autoActiveOverrideForTesting = false
        XCTAssertFalse(E2EEV2ServerGate.messagingOpen)
        XCTAssertFalse(E2EEV2ServerGate.callsOpen)
        XCTAssertFalse(E2EEV2ServerGate.reactionsOpen)
        E2EEV2ServerGate.autoActiveOverrideForTesting = true
        XCTAssertTrue(E2EEV2ServerGate.messagingOpen)
        XCTAssertTrue(E2EEV2ServerGate.callsOpen)
        XCTAssertTrue(E2EEV2ServerGate.reactionsOpen)
    }

    // MARK: Appareils ajoutés

    /// Seules les entrées d'après la dernière lecture comptent ; un `ADD`
    /// `GENESIS` (reprise v2) et un `ADD_PENDING` n'ajoutent aucun appareil.
    func testAddedDevicesComeFromNewAddAndActivateEntriesOnly() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/epoch-recipients-v1.json")
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let log = try XCTUnwrap(vectors["log"] as? [String: Any])
        var entries: [String: [String]] = [:]
        for account in try XCTUnwrap(log["accounts"] as? [[String: Any]]) {
            entries[try XCTUnwrap(account["userId"] as? String)] = try XCTUnwrap(account["entries"] as? [String])
        }
        let alice = try XCTUnwrap(entries["user_alice_00000000001"])
        let bob = try XCTUnwrap(entries["user_bob_0000000000002"])
        XCTAssertEqual(E2EEAutoLogReader.addedDevices(alice, after: 0), ["device_alice_a2_000002", "device_alice_a3_000003"])
        XCTAssertEqual(E2EEAutoLogReader.addedDevices(alice, after: 6), ["device_alice_a3_000003"])
        XCTAssertEqual(E2EEAutoLogReader.addedDevices(alice, after: 16), [])
        XCTAssertEqual(E2EEAutoLogReader.addedDevices(bob, after: 0), ["device_bob_b2_00000002", "device_bob_b3_00000003"])
        XCTAssertEqual(E2EEAutoLogReader.addedDevices(bob, after: 14), ["device_bob_b3_00000003"], "ACTIVATE, pas ADD_PENDING")
    }

    func testAddedDeviceEventsStayWithTheirSession() {
        let added = ["user_bob": Set(["device_b2"])]
        let note = Notification(name: E2EEAutoDeviceEvents.name, userInfo: ["owner": "user:own", "added": added])
        XCTAssertEqual(E2EEAutoDeviceEvents.added(note, ownerScopeId: "user:own"), added)
        XCTAssertNil(E2EEAutoDeviceEvents.added(note, ownerScopeId: "user:other"))
    }

    /// Une ligne par membre, la plus récente ; elle s'efface après 7 jours, et
    /// jamais pour ses propres appareils.
    func testDeviceChangesBecomeThreadNoticesForSevenDays() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let namespace = fixture.session.ownerNamespace
        let conversation = "conv_devices_0000000001"
        try fixture.states.recordDeviceChange(.init(userId: "user_bob", atMs: 1), conversationId: conversation, ownerNamespace: namespace)
        try fixture.states.recordDeviceChange(.init(userId: "user_carol", atMs: 2), conversationId: conversation, ownerNamespace: namespace)
        try fixture.states.recordDeviceChange(.init(userId: "user_bob", atMs: 3), conversationId: conversation, ownerNamespace: namespace)
        let changes = try fixture.states.deviceChanges(conversationId: conversation, ownerNamespace: namespace)
        XCTAssertEqual(changes, [.init(userId: "user_carol", atMs: 2), .init(userId: "user_bob", atMs: 3)])

        let result = E2EEV2MessagesV2(
            snapshot: .init(cursor: 0, messages: [], equivocalRefs: []), unsupported: [], missingByDevice: [:],
            waitingForEpoch: false, deviceChanges: changes + [.init(userId: "user_own", atMs: 3)]
        )
        let bob = MessageUser(id: "user_bob", name: "Bob", email: "bob@example.org", avatarUrl: nil)
        func notices(at nowMs: Int64) -> [E2EEV2ThreadPresentation.Notice] {
            E2EEV2ThreadPresenter.present(
                result, conversationId: conversation, members: ["user_bob": bob], deviceOwners: [:],
                ownUserId: "user_own", nowMs: nowMs
            ).notices
        }
        XCTAssertEqual(notices(at: 10), [
            .devicesChanged(userId: "user_bob", name: "Bob"), .devicesChanged(userId: "user_carol", name: nil),
        ])
        XCTAssertEqual(notices(at: 3 + E2EEV2ThreadPresenter.deviceChangeWindowMs), [])
        XCTAssertEqual(
            E2EEV2ThreadPresentation.Notice.devicesChanged(userId: "user_bob", name: "Bob").text,
            String(localized: "Les appareils de \("Bob") ont changé.")
        )
    }

    // MARK: Outils

    private func remote(user: String, device: String, kinds: [String]) -> E2EEV2CertifiedDevice {
        let agreement = P256.KeyAgreement.PrivateKey()
        let signing = P256.Signing.PrivateKey()
        return E2EEV2CertifiedDevice(
            userId: user, deviceId: device, keyVersion: 1, platform: "android",
            identityKeyB64: agreement.publicKey.x963Representation.base64EncodedString(),
            signingKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            fingerprint: E2EEV2Canonical.deviceFingerprint(
                identityKeyX963: agreement.publicKey.x963Representation,
                signingKeyX963: signing.publicKey.x963Representation
            ),
            capabilities: E2EEV2CapabilitiesDocument(
                userId: user, deviceId: device, sequence: 1, issuedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
                envelopeVersions: ["2"], payloadVersions: ["2"], kinds: kinds, features: []
            )
        )
    }
}
