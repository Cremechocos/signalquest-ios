import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 4 (plan 3) : rotation décidée par l'appareil (§3.3), en
/// comparaison-échange (§3.1), avec adoption vérifiée de l'époque acceptée.
final class E2EEV2EpochRotationV2Tests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD23456789"

    /// Appareil distant certifié et ses clés privées.
    private struct Remote {
        let device: E2EEV2CertifiedDevice
        let agreement: P256.KeyAgreement.PrivateKey
        let signing: P256.Signing.PrivateKey
    }

    /// Conversation créée à deux, époque 1 vérifiée et gardée.
    private struct Seeded {
        let conversationId: String
        let genesis: E2EEV2MembershipState
        let current: E2EEV2ConversationStateStore.CurrentEpoch
    }

    // MARK: Règle

    func testRotationReasonsFollowTheRule() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let seeded = try seed(fixture, devices: fixture.deviceSet(adding: [phone.device]))
        let nowMs = seeded.current.createdAtMs + 1_000
        func reasons(_ devices: [E2EEV2CertifiedDevice], membership: E2EEV2MembershipState? = nil, at time: Int64? = nil) -> [E2EEV2RotationPolicy.Reason] {
            let state = membership ?? seeded.genesis
            let lines = E2EEV2EpochProposals.recipients(
                fixture.deviceSet(adding: devices), members: state.members, excludesWeb: state.excludesWeb, nowMs: time ?? nowMs
            ).map { E2EEV2EpochManifest.recipient(userId: $0.userId, deviceId: $0.deviceId, platform: $0.platform, fingerprint: $0.fingerprint) }
            return E2EEV2RotationPolicy.reasons(current: seeded.current, membership: state, expectedRecipients: lines, nowMs: time ?? nowMs)
        }
        XCTAssertEqual(reasons([phone.device]), [], "Rien n'a changé")
        let tablet = remote(user: bruno, device: "device_bruno_tablet_01J7ABCD", platform: "android")
        XCTAssertEqual(reasons([phone.device, tablet.device]), [.devices], "Appareil ajouté")
        XCTAssertEqual(reasons([]), [.devices], "Appareil révoqué ou mis à l'écart")
        var excluding = seeded.genesis
        excluding.excludesWeb = true
        XCTAssertEqual(reasons([phone.device], membership: excluding), [.browsers], "Réglage des navigateurs, même sans navigateur")
        var shrunk = seeded.genesis
        shrunk.members.remove(bruno)
        XCTAssertEqual(reasons([phone.device], membership: shrunk), [.members, .devices], "Membre retiré")
        XCTAssertEqual(reasons([phone.device], at: seeded.current.acceptedAtMs + E2EEV2RotationPolicy.maxEpochAgeMs), [.age],
                       "30 jours depuis l'acceptation locale")
    }

    func testCurrentEpochOnlyMovesForward() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let seeded = try seed(fixture, devices: fixture.deviceSet(adding: [phone.device]))
        let namespace = fixture.session.ownerNamespace
        let same = seeded.current
        XCTAssertThrowsError(try fixture.states.recordCurrentEpoch(same, ownerNamespace: namespace)) {
            XCTAssertEqual($0 as? E2EEV2ConversationStateStore.Failure, .regressed)
        }
        let olderMembership = E2EEV2ConversationStateStore.CurrentEpoch(
            conversationId: same.conversationId, epochNumber: 2, membershipChangeNumber: same.membershipChangeNumber - 1,
            memberIds: same.memberIds, recipientsDigest: same.recipientsDigest, excludesWeb: false,
            createdAtMs: same.createdAtMs, acceptedAtMs: same.acceptedAtMs
        )
        XCTAssertThrowsError(try fixture.states.recordCurrentEpoch(olderMembership, ownerNamespace: namespace))
        try E2EEV2VaultBoundary.purge(store: fixture.vault, ownerScopeId: fixture.session.ownerScopeId)
        XCTAssertNil(try fixture.states.currentEpoch(conversationId: same.conversationId, ownerNamespace: namespace), "Effacée avec le compte")
    }

    // MARK: Rotation

    func testUnchangedDevicesNeedNoRotation() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let devices = fixture.deviceSet(adding: [phone.device])
        let seeded = try seed(fixture, devices: devices)
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Aucune requête sans rotation")
            throw URLError(.badURL)
        }
        let result = await rotator(fixture).rotateIfNeeded(
            conversationId: seeded.conversationId, membership: seeded.genesis, membershipAt: { _ in seeded.genesis },
            devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(result, .upToDate)
    }

    func testAMemberWhoseIdentityIsNotTrustedIsNeverDroppedSilently() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let seeded = try seed(fixture, devices: fixture.deviceSet(adding: [phone.device]))
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Aucune époque sans Bruno")
            throw URLError(.badURL)
        }
        // Le numéro de Bruno a changé : ses appareils ne sont plus crus.
        let refused = E2EEV2CertifiedDeviceSet(
            devicesByUser: fixture.deviceSet(adding: []).devicesByUser, refusals: [bruno: .uikChanged]
        )
        let result = await rotator(fixture).rotateIfNeeded(
            conversationId: seeded.conversationId, membership: seeded.genesis, membershipAt: { _ in seeded.genesis },
            devices: refused, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(result, .membersNotTrusted([bruno]))
    }

    func testAnAddedDeviceRotatesWithTheNextNumberAndKeepsTheKeyOnceAccepted() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let seeded = try seed(fixture, devices: fixture.deviceSet(adding: [phone.device]))
        let tablet = remote(user: bruno, device: "device_bruno_tablet_01J7ABCD", platform: "android")
        let devices = fixture.deviceSet(adding: [phone.device, tablet.device])
        let captured = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            let body = try E2EEV2AccountFixture.body(request)
            captured.append(request, body: body)
            let envelopes = body["envelopes"] as? [[String: Any]] ?? []
            return E2EEV2AccountFixture.response(request, try JSONSerialization.data(withJSONObject: [
                "epoch": ["id": "epoch_rotation_000000000002", "epochNumber": "2", "status": "active", "createdAt": "2026-10-01T06:00:00.000Z"],
                "recipientCount": String(envelopes.count),
            ]))
        }
        let result = await rotator(fixture).rotateIfNeeded(
            conversationId: seeded.conversationId, membership: seeded.genesis, membershipAt: { _ in seeded.genesis },
            devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(result, .rotated(epochNumber: 2))
        let (request, body) = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.url?.path, "/api/e2ee/v2/conversations/\(seeded.conversationId)/epochs")
        XCTAssertEqual(Set(body.keys), ["epochNumber", "previousEpochNumber", "manifest", "envelopes"])
        XCTAssertEqual(body["epochNumber"] as? String, "2")
        XCTAssertEqual(body["previousEpochNumber"] as? String, "1")
        let manifestObject = try XCTUnwrap(body["manifest"] as? [String: Any])
        let recipients = try XCTUnwrap(manifestObject["recipients"] as? [String])
        let manifest = try E2EEV2EpochManifest.verify(
            E2EEV2SignedString(canonical: try XCTUnwrap(manifestObject["manifest"] as? String), signatureB64: try XCTUnwrap(manifestObject["signatureB64"] as? String)),
            recipients: recipients, creatorSigningKey: try XCTUnwrap(devices.signingKey(userId: fixture.user, deviceId: fixture.descriptor.deviceId))
        )
        XCTAssertEqual(manifest.membershipChangeNumber, seeded.genesis.changeNumber)
        XCTAssertTrue(recipients.contains { $0.contains(tablet.device.deviceId) }, "Le nouvel appareil reçoit l'époque")

        let stored = try XCTUnwrap(try fixture.keys.load(conversationId: seeded.conversationId, ownerNamespace: fixture.session.ownerNamespace))
        XCTAssertEqual(stored.epochNumber, 2)
        XCTAssertEqual(try fixture.states.currentEpoch(conversationId: seeded.conversationId, ownerNamespace: fixture.session.ownerNamespace)?.epochNumber, 2)
    }

    /// Conflit : l'époque acceptée entre-temps est relue, vérifiée et adoptée.
    func testAConflictAdoptsTheAcceptedEpochAfterVerifyingIt() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let seeded = try seed(fixture, devices: fixture.deviceSet(adding: [phone.device]))
        let tablet = remote(user: bruno, device: "device_bruno_tablet_01J7ABCD", platform: "android")
        let devices = fixture.deviceSet(adding: [phone.device, tablet.device])
        let acceptedKey = Data((0..<32).map { UInt8(0xA0 + $0) })
        let served = try servedEpoch(fixture, seeded: seeded, devices: devices, creator: phone, epochKey: acceptedKey)
        MockURLProtocol.requestHandler = Self.conflictThen(served)

        let result = await rotator(fixture).rotateIfNeeded(
            conversationId: seeded.conversationId, membership: seeded.genesis, membershipAt: { $0 == seeded.genesis.changeNumber ? seeded.genesis : nil },
            devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(result, .adopted(epochNumber: 2))
        let stored = try XCTUnwrap(try fixture.keys.load(conversationId: seeded.conversationId, ownerNamespace: fixture.session.ownerNamespace))
        XCTAssertEqual(stored.epochNumber, 2)
        XCTAssertEqual(stored.epochKey, acceptedKey, "La clé de l'époque adoptée, ouverte avec notre clé d'appareil")
    }

    func testAForgedOrAheadAcceptedEpochIsNotAdopted() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let seeded = try seed(fixture, devices: fixture.deviceSet(adding: [phone.device]))
        let tablet = remote(user: bruno, device: "device_bruno_tablet_01J7ABCD", platform: "android")
        let devices = fixture.deviceSet(adding: [phone.device, tablet.device])
        let namespace = fixture.session.ownerNamespace

        // Enveloppe signée par un autre que le créateur du manifeste.
        let forged = try servedEpoch(fixture, seeded: seeded, devices: devices, creator: phone, epochKey: Data(repeating: 1, count: 32), envelopeSigner: tablet.signing)
        MockURLProtocol.requestHandler = Self.conflictThen(forged)
        guard case .failure = await rotator(fixture).rotateIfNeeded(
            conversationId: seeded.conversationId, membership: seeded.genesis, membershipAt: { _ in seeded.genesis },
            devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        ) else { return XCTFail("Enveloppe falsifiée adoptée") }
        XCTAssertEqual(try fixture.states.currentEpoch(conversationId: seeded.conversationId, ownerNamespace: namespace)?.epochNumber, 1)

        // Manifeste fondé sur un état d'appartenance que la chaîne locale n'a pas encore.
        let ahead = try servedEpoch(fixture, seeded: seeded, devices: devices, creator: phone, epochKey: Data(repeating: 2, count: 32))
        MockURLProtocol.requestHandler = Self.conflictThen(ahead)
        let result = await rotator(fixture).rotateIfNeeded(
            conversationId: seeded.conversationId, membership: seeded.genesis, membershipAt: { _ in nil },
            devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(result, .needsMembershipSync)
        XCTAssertEqual(try fixture.states.currentEpoch(conversationId: seeded.conversationId, ownerNamespace: namespace)?.epochNumber, 1)

        MockURLProtocol.requestHandler = { request in
            E2EEV2AccountFixture.response(request, Data(#"{"error":"Appartenance dépassée.","code":"E2EE_MEMBERSHIP_STALE"}"#.utf8), status: 409)
        }
        let stale = await rotator(fixture).rotateIfNeeded(
            conversationId: seeded.conversationId, membership: seeded.genesis, membershipAt: { _ in seeded.genesis },
            devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        )
        XCTAssertEqual(stale, .needsMembershipSync)
        XCTAssertEqual(try fixture.keys.load(conversationId: seeded.conversationId, ownerNamespace: namespace)?.epochNumber, 1)
    }

    /// Relecture indépendante du lot 4 : une époque qui recule (numéro ou état
    /// d'appartenance) ne déplace jamais le pointeur de clé, même vérifiée sur
    /// un état devenu ancien.
    func testKeepNeverMovesTheKeyForAnEpochThatGoesBack() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let seeded = try seed(fixture, devices: fixture.deviceSet(adding: [phone.device]))
        let namespace = fixture.session.ownerNamespace
        func keep(_ number: Int, _ byte: UInt8, membership: E2EEV2MembershipState) throws -> Bool {
            let key = Data(repeating: byte, count: 32)
            return E2EEV2EpochVerifierV2.keep(
                epochKey: key,
                accepted: .init(epochId: "epoch_keep_\(number)_0123456789", epochNumber: number, createdAt: "2026-10-01T07:00:00.000Z"),
                conversationId: seeded.conversationId, commitment: try E2EEV2EpochCrypto.keyCommitment(key),
                membership: membership, recipients: ["ligne"], createdAtMs: 0, acceptedAtMs: 0,
                session: fixture.session, keyStore: fixture.keys, stateStore: fixture.states
            )
        }
        XCTAssertTrue(try keep(3, 0x33, membership: seeded.genesis))
        XCTAssertFalse(try keep(2, 0x22, membership: seeded.genesis), "Numéro qui recule")
        var older = seeded.genesis
        older.changeNumber -= 1
        XCTAssertFalse(try keep(4, 0x44, membership: older), "État d'appartenance qui recule")
        let stored = try XCTUnwrap(try fixture.keys.load(conversationId: seeded.conversationId, ownerNamespace: namespace))
        XCTAssertEqual(stored.epochNumber, 3)
        XCTAssertEqual(stored.epochKey, Data(repeating: 0x33, count: 32))
    }

    func testTheLastEpochNumberNeverOverflows() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let phone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let seeded = try seed(fixture, devices: fixture.deviceSet(adding: [phone.device]))
        let last = seeded.current
        try fixture.states.recordCurrentEpoch(
            .init(
                conversationId: last.conversationId, epochNumber: E2EEV2Canonical.maxSequenceNumber,
                membershipChangeNumber: last.membershipChangeNumber, memberIds: last.memberIds,
                recipientsDigest: last.recipientsDigest, excludesWeb: false, createdAtMs: 0, acceptedAtMs: 0
            ),
            ownerNamespace: fixture.session.ownerNamespace
        )
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Aucune proposition au-delà du dernier numéro")
            throw URLError(.badURL)
        }
        let tablet = remote(user: bruno, device: "device_bruno_tablet_01J7ABCD", platform: "android")
        guard case .failure = await rotator(fixture).rotateIfNeeded(
            conversationId: seeded.conversationId, membership: seeded.genesis, membershipAt: { _ in seeded.genesis },
            devices: fixture.deviceSet(adding: [phone.device, tablet.device]), expectedOwnerScopeId: fixture.session.ownerScopeId
        ) else { return XCTFail("Rotation au-delà du dernier numéro") }
    }

    // MARK: Outils

    private func rotator(_ fixture: E2EEV2AccountFixture) -> E2EEV2EpochRotatorV2 {
        E2EEV2EpochRotatorV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
    }

    /// Tête-à-tête créé localement, époque 1 gardée comme si le serveur l'avait acceptée.
    private func seed(_ fixture: E2EEV2AccountFixture, devices: E2EEV2CertifiedDeviceSet) throws -> Seeded {
        let epochKey = Data((0..<32).map { UInt8($0) })
        let creation = try fixture.make(participants: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices, epochKey: epochKey)
        let namespace = fixture.session.ownerNamespace
        XCTAssertTrue(try fixture.keys.put(
            recordInput: .init(conversationId: creation.conversationId, epochId: "epoch_rotation_000000000001", epochNumber: 1, keyCommitmentB64: creation.epoch.keyCommitmentB64),
            epochKey: epochKey, ownerNamespace: namespace, expectedSession: fixture.session
        ))
        let current = E2EEV2ConversationStateStore.CurrentEpoch(
            conversationId: creation.conversationId, epochNumber: 1, membershipChangeNumber: creation.genesis.changeNumber,
            memberIds: creation.genesis.members.sorted(),
            recipientsDigest: E2EEV2Canonical.listDigest(tag: E2EEV2EpochManifest.recipientsTag, lines: creation.epoch.recipients),
            excludesWeb: false, createdAtMs: creation.epoch.createdAtMs, acceptedAtMs: creation.epoch.createdAtMs
        )
        try fixture.states.appendMembership(creation.membership, conversationId: creation.conversationId, ownerNamespace: namespace)
        try fixture.states.record(
            .init(
                conversationId: creation.conversationId, creatorUserId: fixture.user, creatorDeviceId: fixture.descriptor.deviceId,
                manifestDigest: E2EEV2Canonical.sha256B64URL(Data(creation.epoch.manifest.canonical.utf8)),
                membershipChangeNumber: creation.genesis.changeNumber,
                membershipDigest: E2EEV2MembershipChange.digest(of: try XCTUnwrap(creation.membership.last?.canonical)),
                recordedAtMs: creation.epoch.createdAtMs
            ),
            ownerNamespace: namespace
        )
        try fixture.states.recordCurrentEpoch(current, ownerNamespace: namespace)
        return Seeded(conversationId: creation.conversationId, genesis: creation.genesis, current: current)
    }

    /// Époque 2 acceptée, créée par un appareil de Bruno, telle que le serveur la sert.
    private func servedEpoch(
        _ fixture: E2EEV2AccountFixture,
        seeded: Seeded,
        devices: E2EEV2CertifiedDeviceSet,
        creator: Remote,
        epochKey: Data,
        envelopeSigner: P256.Signing.PrivateKey? = nil
    ) throws -> Data {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let lines = E2EEV2EpochProposals.recipients(devices, members: seeded.genesis.members, excludesWeb: false, nowMs: nowMs)
            .map { E2EEV2EpochManifest.recipient(userId: $0.userId, deviceId: $0.deviceId, platform: $0.platform, fingerprint: $0.fingerprint) }
        let commitment = try E2EEV2EpochCrypto.keyCommitment(epochKey)
        let manifest = E2EEV2EpochManifest.make(
            conversationId: seeded.conversationId, epochNumber: 2, creatorUserId: creator.device.userId,
            creatorDeviceId: creator.device.deviceId, keyCommitmentB64: commitment, recipients: lines, excludesWeb: false,
            membershipChangeNumber: seeded.genesis.changeNumber,
            membershipDigest: E2EEV2MembershipChange.digest(of: try XCTUnwrap(seeded.genesis.lastCanonical)), createdAtMs: nowMs
        )
        let signed = try E2EEV2SignedString.sign(manifest.canonical, with: creator.signing)
        let context = E2EEV2EpochContext(
            conversationId: seeded.conversationId, epochNumber: 2,
            senderDeviceId: creator.device.deviceId, recipientDeviceId: fixture.descriptor.deviceId
        )
        let envelope = try E2EEV2EpochCrypto.wrap(
            epochKey: epochKey,
            recipientPublicKey: P256.KeyAgreement.PublicKey(x963Representation: try XCTUnwrap(Data(base64Encoded: fixture.descriptor.publicIdentityKeyB64))),
            ephemeralPrivateKey: P256.KeyAgreement.PrivateKey(),
            nonce: Data((0..<12).map { UInt8($0) }),
            context: context
        )
        let signature = try E2EEV2LowS.sign(
            E2EEV2EpochCrypto.signatureCanonical(context: context, keyCommitmentB64: commitment, envelope: envelope),
            with: envelopeSigner ?? creator.signing
        )
        return try JSONSerialization.data(withJSONObject: [
            "conversationId": seeded.conversationId,
            "epoch": ["id": "epoch_rotation_000000000002", "epochNumber": "2", "status": "active", "createdAt": "2026-10-01T06:00:00.000Z"],
            "manifest": ["manifest": signed.canonical, "signatureB64": signed.signatureB64, "recipients": lines],
            "envelope": [
                "recipientDeviceId": envelope.recipientDeviceId, "wrapAlgorithm": envelope.wrapAlgorithm,
                "ephemeralPublicKeyB64": envelope.ephemeralPublicKeyB64, "wrappedEpochKeyB64": envelope.wrappedEpochKeyB64,
                "nonceB64": envelope.nonceB64, "aadB64": envelope.aadB64, "signatureB64": signature.base64EncodedString(),
            ],
        ])
    }

    /// 409 sur la proposition, puis l'époque courante sur sa relecture.
    private static func conflictThen(_ current: Data) -> MockURLProtocol.Handler {
        { request in
            if request.httpMethod == "POST" {
                return E2EEV2AccountFixture.response(request, Data(#"{"error":"Époque dépassée.","code":"E2EE_EPOCH_STALE"}"#.utf8), status: 409)
            }
            XCTAssertTrue(request.url?.path.hasSuffix("/epochs/current") == true)
            return E2EEV2AccountFixture.response(request, current)
        }
    }

    private func remote(user: String, device: String, platform: String) -> Remote {
        let agreement = P256.KeyAgreement.PrivateKey()
        let signing = P256.Signing.PrivateKey()
        return Remote(
            device: E2EEV2CertifiedDevice(
                userId: user, deviceId: device, keyVersion: 1, platform: platform,
                identityKeyB64: agreement.publicKey.x963Representation.base64EncodedString(),
                signingKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
                fingerprint: E2EEV2Canonical.deviceFingerprint(
                    identityKeyX963: agreement.publicKey.x963Representation,
                    signingKeyX963: signing.publicKey.x963Representation
                ),
                capabilities: E2EEV2CapabilitiesDocument(
                    userId: user, deviceId: device, sequence: 1, issuedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
                    envelopeVersions: ["2"], payloadVersions: ["2"], kinds: [], features: ["calls"]
                )
            ),
            agreement: agreement,
            signing: signing
        )
    }
}
