import XCTest
@testable import SignalQuest

/// Lot 4b (E2EE-AUTO, révision 10, §7.1 et §7.2) : une époque marquée n'est
/// adoptée pour l'envoi que si son manifeste passe le contrôle du journal ;
/// une époque non marquée, une fois la bascule faite, reste lisible et tourne.
final class E2EEAutoEpochAdoptionTests: XCTestCase {
    private func load(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/\(name).json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: Marqueur servi

    func testTheEpochMarkerIsReadOnlyAsTrue() {
        let base: [String: E2EEV2JSON] = [
            "id": .string("epoch_marker_000000000001"), "epochNumber": .string("3"),
            "status": .string("active"), "createdAt": .string("2026-10-26T20:00:00.000Z"),
        ]
        XCTAssertEqual(E2EEV2EpochContractV2.epoch(.object(base))?.e2eeAuto, false, "Absent = non marquée")
        var marked = base
        marked["e2eeAuto"] = .bool(true)
        XCTAssertEqual(E2EEV2EpochContractV2.epoch(.object(marked))?.e2eeAuto, true)
        var falsy = base
        falsy["e2eeAuto"] = .bool(false)
        XCTAssertNil(E2EEV2EpochContractV2.epoch(.object(falsy)), "Jamais servi à false : refusé comme une clé inconnue")
        var other = base
        other["e2eeAutoAt"] = .string("2026-10-26T20:00:00.000Z")
        XCTAssertNil(E2EEV2EpochContractV2.epoch(.object(other)), "Toute autre clé reste refusée")
    }

    // MARK: Contrôle du journal (vecteurs epoch-recipients-v1)

    /// Les 45 manifestes du vecteur, servis comme époques marquées : le verdict
    /// d'adoption suit le §7.1, une relecture faite pour les comptes concernés.
    func testMarkedEpochsFollowTheManifestVectors() throws {
        let vectors = try load("epoch-recipients-v1")
        for testCase in try XCTUnwrap(vectors["manifests"] as? [[String: Any]]) {
            let name = try XCTUnwrap(testCase["name"] as? String)
            let logSeq = try XCTUnwrap((testCase["logSeq"] as? NSNumber)?.int64Value, name)
            let members = try XCTUnwrap(testCase["memberUserIds"] as? [String], name)
            let manifest = manifest(
                epochNumber: 7, createdAtMs: try XCTUnwrap((testCase["manifestCreatedAtMs"] as? NSNumber)?.int64Value, name),
                excludesWeb: try XCTUnwrap(testCase["excludesWeb"] as? Bool, name),
                own: try XCTUnwrap(testCase["ownManifest"] as? Bool, name)
            )
            var devices = E2EEV2CertifiedDeviceSet(devicesByUser: [:], refusals: [:])
            devices.logAccounts = try E2EEAutoVectorLog.accounts(vectors, atSeq: logSeq)
            if try XCTUnwrap(testCase["refreshed"] as? Bool, name) { devices.logRereadUserIds = Set(members) }
            let nowMs = try XCTUnwrap((testCase["correctedNowMs"] as? NSNumber)?.int64Value, name)
            let result = E2EEV2EpochVerifierV2.autoUse(
                served(marked: true), manifest: manifest, members: Set(members),
                recipients: try XCTUnwrap(testCase["recipients"] as? [String], name).compactMap(E2EEAutoEpoch.Recipient.parse),
                ownUserId: Self.own.userId, ownDeviceId: Self.own.deviceId, devices: devices,
                firstAutoEpochNumber: 2, autoActive: true, nowMs: nowMs
            )
            let expect = try XCTUnwrap(testCase["expect"] as? [String: Any], name)
            switch result {
            case .success(.send):
                XCTAssertEqual(expect["adoptable"] as? Bool, true, name)
            case .success(.readOnly(let alert?)):
                XCTAssertEqual(expect["alert"] as? Bool, true, name)
                XCTAssertEqual(alert.code, expect["reason"] as? String, name)
                XCTAssertEqual(alert.deviceId, expect["deviceId"] as? String, name)
                XCTAssertEqual(alert.epochNumber, 7, name)
            case .success(.readOnly(nil)):
                XCTAssertTrue(["FUTURE", "EXCLUDES_WEB"].contains(expect["reason"] as? String ?? ""), name)
            case .failure(let behind):
                XCTAssertEqual(expect["reason"] as? String, "LOG_BEHIND", name)
                XCTAssertEqual(behind.userIds, expect["userIds"] as? [String], name)
            }
        }
    }

    /// Un membre sans journal vérifié se relit ; une fois relu sans succès,
    /// le journal n'est pas à jour : ni alerte ni adoption.
    func testAMemberWithoutAVerifiedLogIsReadBeforeJudging() {
        let manifest = manifest(epochNumber: 4, createdAtMs: 1_790_036_000_000, excludesWeb: false, own: false)
        let devices = E2EEV2CertifiedDeviceSet(devicesByUser: [:], refusals: [:])
        let result = E2EEV2EpochVerifierV2.autoUse(
            served(marked: true), manifest: manifest, members: ["user_bob_0000000000002"], recipients: [],
            ownUserId: Self.own.userId, ownDeviceId: Self.own.deviceId, devices: devices,
            firstAutoEpochNumber: nil, autoActive: true, nowMs: 1_790_036_000_000
        )
        guard case .failure(let behind) = result else { return XCTFail("Attendu une relecture, reçu \(result)") }
        XCTAssertEqual(behind.userIds, ["user_bob_0000000000002"])
        XCTAssertEqual(E2EEV2EpochVerifierV2.logBehindFailure(behind.userIds, devices: devices).code, "E2EE_DEVICE_LIST_STALE")
        var reread = devices
        reread.logRereadUserIds = ["user_bob_0000000000002"]
        let notUpToDate = E2EEV2EpochVerifierV2.logBehindFailure(behind.userIds, devices: reread)
        XCTAssertNil(notUpToDate.code, "Pas une seconde relecture")
        XCTAssertEqual(notUpToDate.kind, .retryable)
    }

    // MARK: Époques non marquées

    func testUnmarkedEpochsFollowTheSwitch() {
        let devices = E2EEV2CertifiedDeviceSet(devicesByUser: [:], refusals: [:])
        func use(epochNumber: Int, firstAuto: Int?, autoActive: Bool) -> E2EEV2EpochVerifierV2.Use? {
            let manifest = manifest(epochNumber: epochNumber, createdAtMs: 1_790_036_000_000, excludesWeb: false, own: false)
            if case .success(let use) = E2EEV2EpochVerifierV2.autoUse(
                served(marked: false), manifest: manifest, members: [], recipients: [],
                ownUserId: Self.own.userId, ownDeviceId: Self.own.deviceId, devices: devices,
                firstAutoEpochNumber: firstAuto, autoActive: autoActive, nowMs: 1_790_036_000_000
            ) { return use }
            return nil
        }
        XCTAssertEqual(use(epochNumber: 5, firstAuto: nil, autoActive: false), .send, "Avant la bascule : chemin v2")
        XCTAssertEqual(use(epochNumber: 5, firstAuto: nil, autoActive: true), .readOnly(alert: nil), "Ancienne époque v2 : lisible, sans alerte")
        XCTAssertEqual(use(epochNumber: 3, firstAuto: 4, autoActive: true), .readOnly(alert: nil), "Sous la première époque marquée")
        guard case .readOnly(let alert?) = use(epochNumber: 6, firstAuto: 4, autoActive: true) else {
            return XCTFail("Une époque non marquée au-dessus d'une époque marquée est un retour en arrière")
        }
        XCTAssertEqual(alert.code, "UNMARKED_EPOCH")
        XCTAssertEqual(alert.epochNumber, 6)
        guard case .readOnly(let same?) = use(epochNumber: 4, firstAuto: 4, autoActive: true) else {
            return XCTFail("Non marquée au numéro retenu : ligne de sécurité (epoch-markers-v1)")
        }
        XCTAssertEqual(same.epochNumber, 4)
    }

    // MARK: Rotation et état gardé

    func testAReadOnlyOrUnmarkedEpochRotatesBeforeTheNextSend() {
        let membership = E2EEV2MembershipState(members: ["a", "b"], changeNumber: 3)
        func current(auto: Bool?, readOnly: Bool?) -> E2EEV2ConversationStateStore.CurrentEpoch {
            .init(
                conversationId: "conv_x", epochNumber: 4, membershipChangeNumber: 3, memberIds: ["a", "b"],
                recipientsDigest: E2EEV2Canonical.listDigest(tag: E2EEV2EpochManifest.recipientsTag, lines: []),
                excludesWeb: false, createdAtMs: 1_000, acceptedAtMs: 1_000, e2eeAuto: auto, readOnly: readOnly
            )
        }
        func reasons(_ epoch: E2EEV2ConversationStateStore.CurrentEpoch, autoActive: Bool) -> [E2EEV2RotationPolicy.Reason] {
            E2EEV2RotationPolicy.reasons(
                current: epoch, membership: membership, expectedRecipients: [], nowMs: 2_000, autoActive: autoActive
            )
        }
        XCTAssertEqual(reasons(current(auto: nil, readOnly: nil), autoActive: false), [])
        XCTAssertEqual(reasons(current(auto: nil, readOnly: nil), autoActive: true), [.notAdoptable])
        XCTAssertEqual(reasons(current(auto: true, readOnly: nil), autoActive: true), [])
        XCTAssertEqual(reasons(current(auto: true, readOnly: true), autoActive: true), [.notAdoptable])
    }

    func testTheFirstMarkedEpochAndSecurityAlertsAreKept() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let namespace = fixture.session.ownerNamespace
        func advance(_ number: Int, auto: Bool?) throws {
            try fixture.states.advanceCurrentEpoch(
                .init(
                    conversationId: "conv_marker_0000000001", epochNumber: number, membershipChangeNumber: 2,
                    memberIds: ["a", "b"], recipientsDigest: "d", excludesWeb: false, createdAtMs: 1, acceptedAtMs: 1,
                    e2eeAuto: auto
                ),
                ownerNamespace: namespace
            ) {}
        }
        try advance(1, auto: nil)
        try advance(2, auto: true)
        try advance(3, auto: true)
        try advance(4, auto: nil)
        let current = try XCTUnwrap(try fixture.states.currentEpoch(conversationId: "conv_marker_0000000001", ownerNamespace: namespace))
        XCTAssertEqual(current.firstAutoEpochNumber, 2, "Le plus petit numéro marqué reste, même sous une époque non marquée")

        let alert = E2EEV2ConversationStateStore.SecurityAlert(code: "REVOKED", userId: "b", deviceId: "d1", epochNumber: 4, atMs: 5)
        try fixture.states.recordSecurityAlert(alert, conversationId: "conv_marker_0000000001", ownerNamespace: namespace)
        try fixture.states.recordSecurityAlert(alert, conversationId: "conv_marker_0000000001", ownerNamespace: namespace)
        XCTAssertEqual(try fixture.states.securityAlerts(conversationId: "conv_marker_0000000001", ownerNamespace: namespace), [alert])
    }

    func testSecurityAlertsBecomeThreadNotices() {
        let result = E2EEV2MessagesV2(
            snapshot: .init(cursor: 0, messages: [], equivocalRefs: []), unsupported: [], missingByDevice: [:],
            waitingForEpoch: false,
            securityAlerts: [
                .init(code: "REVOKED", userId: "user_bob", deviceId: "d1", epochNumber: 4, atMs: 1),
                .init(code: "KEY_ROTATED", userId: "user_bob", deviceId: "d1", epochNumber: 6, atMs: 2),
                .init(code: "UNMARKED_EPOCH", userId: "user_bob", deviceId: "d2", epochNumber: 7, atMs: 3),
            ]
        )
        let notices = E2EEV2ThreadPresenter.present(result, conversationId: "conv_x", members: [:], deviceOwners: [:]).notices
        XCTAssertEqual(notices, [.keyUnverified, .deviceRefused(userId: "user_bob", name: nil)], "Une ligne par appareil")
    }

    // MARK: Outils

    private static let own = (userId: "user_own_000000000009", deviceId: "device_own_00000009")

    private func manifest(epochNumber: Int, createdAtMs: Int64, excludesWeb: Bool, own: Bool) -> E2EEV2EpochManifest {
        E2EEV2EpochManifest(
            conversationId: "conv_vectors_00000001", epochNumber: epochNumber,
            creatorUserId: own ? Self.own.userId : "user_creator_0000000008",
            creatorDeviceId: own ? Self.own.deviceId : "device_creator_0008",
            keyCommitmentB64: "", recipientCount: 0, recipientsDigest: "", excludesWeb: excludesWeb,
            membershipChangeNumber: 1, membershipDigest: "", createdAtMs: createdAtMs
        )
    }

    private func served(marked: Bool) -> E2EEV2EpochContractV2.Current {
        E2EEV2EpochContractV2.Current(
            accepted: .init(epochId: "epoch_vectors_0000001", epochNumber: 7, createdAt: "2026-10-26T20:00:00.000Z", e2eeAuto: marked),
            manifest: E2EEV2SignedString(canonical: "", signatureB64: ""), recipients: [], envelope: nil
        )
    }
}
