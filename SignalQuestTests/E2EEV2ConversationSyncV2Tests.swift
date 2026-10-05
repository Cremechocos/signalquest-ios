import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 4 (plan 3) : un membre reçoit une conversation v2 créée par un autre
/// (§3.4, §3.5, §12) : chaîne relue et gardée, genèse vérifiée, époque reçue.
final class E2EEV2ConversationSyncV2Tests: XCTestCase {
    private let alice = "user_alice_01J7ABCD23456789"
    private let carla = "user_carla_01J7ABCD23456789"
    private let conversationId = "conv_sync_0123456789ABCDEF"

    private struct Remote {
        let device: E2EEV2CertifiedDevice
        let signing: P256.Signing.PrivateKey
    }

    /// Ce que le serveur sert pour une conversation créée par Alice.
    private struct Served {
        var chain: [E2EEV2SignedString]
        let manifest: Data
        let current: Data
        let epochKey: Data
    }

    func testAMemberReceivesTheConversationAndItStaysV2() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let creator = remote(alice, device: "device_alice_ios_01J7ABCD2345")
        let devices = fixture.deviceSet(adding: [creator.device])
        let served = try serve(fixture, creator: creator, devices: devices)
        MockURLProtocol.requestHandler = Self.server(served)

        let result = await sync(fixture, devices: devices)
        XCTAssertEqual(result, .received(epochNumber: 1))
        let namespace = fixture.session.ownerNamespace
        XCTAssertTrue(try fixture.states.isV2(conversationId: conversationId, ownerNamespace: namespace))
        XCTAssertEqual(try fixture.states.membershipChain(conversationId: conversationId, ownerNamespace: namespace), served.chain)
        XCTAssertEqual(try fixture.keys.load(conversationId: conversationId, ownerNamespace: namespace)?.epochKey, served.epochKey)

        let again = await sync(fixture, devices: devices)
        XCTAssertEqual(again, .upToDate(epochNumber: 1), "Rien de neuf : la chaîne gardée suffit")
    }

    /// Un groupe dont le créateur n'a pas encore été lu par l'annuaire (parti
    /// du groupe, par exemple) : la relève le nomme pour relecture
    /// (`E2EE_DEVICE_LIST_STALE`), puis réussit une fois ses appareils lus.
    func testAnUnreadCreatorIsNamedForRereadInsteadOfFailingVerification() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let creator = remote(alice, device: "device_alice_ios_01J7ABCD2345")
        let devices = fixture.deviceSet(adding: [creator.device])
        MockURLProtocol.requestHandler = Self.server(try serve(fixture, creator: creator, devices: devices))

        let withoutCreator = fixture.deviceSet(adding: [])
        guard case .failure(let failure) = await sync(fixture, devices: withoutCreator) else {
            return XCTFail("Créateur inconnu : rien ne peut se vérifier")
        }
        XCTAssertEqual(failure.code, "E2EE_DEVICE_LIST_STALE")
        XCTAssertTrue(failure.staleUserIds.contains(alice), "Le créateur est nommé pour relecture")
        XCTAssertEqual(try fixture.states.membershipChain(conversationId: conversationId, ownerNamespace: fixture.session.ownerNamespace), [])

        let result = await sync(fixture, devices: devices)
        XCTAssertEqual(result, .received(epochNumber: 1), "Relu, le créateur vérifie la genèse")
    }

    func testAGenesisSignedByAnUnknownKeyKeepsNothing() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let creator = remote(alice, device: "device_alice_ios_01J7ABCD2345")
        let impostor = Remote(device: creator.device, signing: P256.Signing.PrivateKey())
        let devices = fixture.deviceSet(adding: [creator.device])
        MockURLProtocol.requestHandler = Self.server(try serve(fixture, creator: impostor, devices: devices))

        guard case .failure = await sync(fixture, devices: devices) else { return XCTFail("Genèse forgée acceptée") }
        let namespace = fixture.session.ownerNamespace
        XCTAssertFalse(try fixture.states.isV2(conversationId: conversationId, ownerNamespace: namespace))
        XCTAssertEqual(try fixture.states.membershipChain(conversationId: conversationId, ownerNamespace: namespace), [])
    }

    func testAChangeAgainstTheRulesIsNotKept() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let creator = remote(alice, device: "device_alice_ios_01J7ABCD2345")
        let devices = fixture.deviceSet(adding: [creator.device])
        var served = try serve(fixture, creator: creator, devices: devices)
        MockURLProtocol.requestHandler = Self.server(served)
        let first = await sync(fixture, devices: devices)
        XCTAssertEqual(first, .received(epochNumber: 1))

        // On n'ajoute personne à un tête-à-tête, même signé.
        let added = E2EEV2MembershipChange(
            conversationId: conversationId, changeNumber: 3, action: "ADD", targetUserId: carla,
            actorUserId: alice, actorDeviceId: creator.device.deviceId,
            previousChangeDigest: E2EEV2MembershipChange.digest(of: served.chain[1].canonical), createdAtMs: 1_790_000_000_100
        )
        served.chain.append(try E2EEV2SignedString.sign(added.canonical, with: creator.signing))
        MockURLProtocol.requestHandler = Self.server(served)
        guard case .failure = await sync(fixture, devices: devices) else { return XCTFail("Ajout interdit gardé") }
        XCTAssertEqual(try fixture.states.membershipChain(conversationId: conversationId, ownerNamespace: fixture.session.ownerNamespace).count, 2)
    }

    func testADeviceNotYetRecipientWaitsForTheNextEpoch() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let creator = remote(alice, device: "device_alice_ios_01J7ABCD2345")
        let devices = fixture.deviceSet(adding: [creator.device])
        let served = try serve(fixture, creator: creator, devices: devices)
        let base = Self.server(served)
        MockURLProtocol.requestHandler = { request in
            guard request.url?.path.hasSuffix("/epochs/current") == true else { return try base(request) }
            return E2EEV2AccountFixture.response(
                request, Data(#"{"error":"Aucune enveloppe pour cet appareil.","code":"E2EE_EPOCH_ENVELOPE_NOT_FOUND"}"#.utf8), status: 404
            )
        }
        let result = await sync(fixture, devices: devices)
        XCTAssertEqual(result, .waitingForEpoch)
        XCTAssertTrue(try fixture.states.isV2(conversationId: conversationId, ownerNamespace: fixture.session.ownerNamespace),
                      "La genèse vérifiée rend la conversation v2, avant même la clé")
    }

    /// Relecture indépendante du lot 4 : une genèse n'est jamais gardée sans la
    /// chaîne qui la porte, ni avant que toute la chaîne soit relue.
    func testNothingIsKeptWhenTheChainFailsAfterAValidGenesis() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let creator = remote(alice, device: "device_alice_ios_01J7ABCD2345")
        let devices = fixture.deviceSet(adding: [creator.device])
        var served = try serve(fixture, creator: creator, devices: devices)
        let added = E2EEV2MembershipChange(
            conversationId: conversationId, changeNumber: 3, action: "ADD", targetUserId: carla,
            actorUserId: alice, actorDeviceId: creator.device.deviceId,
            previousChangeDigest: E2EEV2MembershipChange.digest(of: served.chain[1].canonical), createdAtMs: 1_790_000_000_100
        )
        served.chain.append(try E2EEV2SignedString.sign(added.canonical, with: creator.signing))
        MockURLProtocol.requestHandler = Self.server(served)

        guard case .failure = await sync(fixture, devices: devices) else { return XCTFail("Chaîne invalide acceptée") }
        let namespace = fixture.session.ownerNamespace
        XCTAssertFalse(try fixture.states.isV2(conversationId: conversationId, ownerNamespace: namespace), "Genèse non gardée")
        XCTAssertEqual(try fixture.states.membershipChain(conversationId: conversationId, ownerNamespace: namespace), [])
    }

    /// La genèse gardée est revérifiée à chaque passage : une chaîne gardée qui
    /// ne la reproduit plus (condensat, auteur) est refusée.
    func testAStoredChainThatNoLongerMatchesTheGenesisIsRefused() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let creator = remote(alice, device: "device_alice_ios_01J7ABCD2345")
        let devices = fixture.deviceSet(adding: [creator.device])
        MockURLProtocol.requestHandler = Self.server(try serve(fixture, creator: creator, devices: devices))
        let first = await sync(fixture, devices: devices)
        XCTAssertEqual(first, .received(epochNumber: 1))

        // Une autre genèse, cohérente en elle-même, remplace la chaîne gardée.
        let other = try E2EEV2MembershipChain.genesis(
            conversationId: conversationId, memberIds: [alice, fixture.user], adminIds: [], isGroup: false,
            actor: .init(userId: alice, deviceId: creator.device.deviceId), createdAtMs: 1_790_000_009_000
        ).map { try E2EEV2SignedString.sign($0.canonical, with: creator.signing) }
        let namespace = fixture.session.ownerNamespace
        let chainKey = E2EEV2ConversationStateStore.prefix(ownerNamespace: namespace)
            + SHA256.hash(data: Data(conversationId.utf8)).map { String(format: "%02x", $0) }.joined() + ":chain"
        try fixture.vault.set(
            E2EEV2CanonicalJSON.encodeString(.array(other.map(E2EEV2MembershipChange.json))), for: chainKey,
            accessibility: .afterFirstUnlock
        )
        guard case .failure = await sync(fixture, devices: devices) else { return XCTFail("Genèse remplacée acceptée") }
    }

    /// Un auteur de la chaîne révoqué depuis ne casse pas la relecture : la
    /// partie gardée a été vérifiée quand elle l'a été.
    func testARevokedAuthorDoesNotBreakTheStoredChain() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let creator = remote(alice, device: "device_alice_ios_01J7ABCD2345")
        let devices = fixture.deviceSet(adding: [creator.device])
        MockURLProtocol.requestHandler = Self.server(try serve(fixture, creator: creator, devices: devices))
        let first = await sync(fixture, devices: devices)
        XCTAssertEqual(first, .received(epochNumber: 1))

        let withoutCreator = fixture.deviceSet(adding: [])
        let again = await sync(fixture, devices: withoutCreator)
        XCTAssertEqual(again, .upToDate(epochNumber: 1))
    }

    /// La ligne de cet appareil doit être exactement son appareil certifié.
    func testAnEpochWithAWrongLineForThisDeviceIsRefused() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let creator = remote(alice, device: "device_alice_ios_01J7ABCD2345")
        let devices = fixture.deviceSet(adding: [creator.device])
        let own = try XCTUnwrap(devices.device(userId: fixture.user, deviceId: fixture.descriptor.deviceId))
        let altered = E2EEV2CertifiedDevice(
            userId: own.userId, deviceId: own.deviceId, keyVersion: own.keyVersion, platform: own.platform,
            identityKeyB64: own.identityKeyB64, signingKeyB64: own.signingKeyB64,
            fingerprint: E2EEV2Canonical.sha256B64URL(Data("autre appareil".utf8)), capabilities: own.capabilities
        )
        let skewed = E2EEV2CertifiedDeviceSet(devicesByUser: [fixture.user: [altered], alice: [creator.device]], refusals: [:])
        MockURLProtocol.requestHandler = Self.server(try serve(fixture, creator: creator, devices: skewed))

        guard case .failure = await sync(fixture, devices: devices) else { return XCTFail("Ligne fausse acceptée") }
        let namespace = fixture.session.ownerNamespace
        XCTAssertTrue(try fixture.states.isV2(conversationId: conversationId, ownerNamespace: namespace), "La genèse, elle, est valide")
        XCTAssertNil(try fixture.keys.load(conversationId: conversationId, ownerNamespace: namespace))
    }

    // MARK: Outils

    func testSkippedEpochsAreReadOneByOne() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let creator = remote(alice, device: "device_alice_ios_01J7ABCD2345")
        let devices = fixture.deviceSet(adding: [creator.device])
        let served = try serve(fixture, creator: creator, devices: devices)
        MockURLProtocol.requestHandler = Self.server(served)
        let first = await sync(fixture, devices: devices)
        XCTAssertEqual(first, .received(epochNumber: 1))

        // Hors ligne pendant deux rotations : le serveur est à l'époque 3.
        let keyTwo = Data(repeating: 0x22, count: 32), keyThree = Data(repeating: 0x33, count: 32)
        let two = try epoch(2, key: keyTwo, fixture, creator: creator, devices: devices, chain: served.chain)
        let three = try epoch(3, key: keyThree, fixture, creator: creator, devices: devices, chain: served.chain)
        let paths = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            paths.append(request, body: [:])
            let path = request.url?.path ?? ""
            if path.hasSuffix("/epochs/2") { return E2EEV2AccountFixture.response(request, two) }
            if path.hasSuffix("/epochs/current") { return E2EEV2AccountFixture.response(request, three) }
            return try Self.server(served)(request)
        }
        let caughtUp = await sync(fixture, devices: devices)
        XCTAssertEqual(caughtUp, .received(epochNumber: 3))
        let namespace = fixture.session.ownerNamespace
        XCTAssertTrue(paths.all.contains { $0.0.url?.path.hasSuffix("/epochs/2") == true }, "L'époque sautée est demandée")
        // E.2 : chaque clé gardée est accusée, signée, corps vide.
        let acks = paths.all.filter { $0.0.url?.path.hasSuffix("/ack") == true }
        XCTAssertEqual(acks.compactMap { $0.0.url?.path.components(separatedBy: "/").dropLast().last }, ["2", "3"])
        XCTAssertTrue(acks.allSatisfy { $0.0.httpMethod == "POST" && $0.0.value(forHTTPHeaderField: E2EEV2SignedRequest.headerSignature) != nil })
        XCTAssertEqual(try fixture.keys.loadEpoch(conversationId: conversationId, epochNumber: 2, ownerNamespace: namespace)?.epochKey, keyTwo,
                       "Ses messages en vol se liront")
        XCTAssertEqual(try fixture.states.acceptedEpochs(conversationId: conversationId, ownerNamespace: namespace).map(\.epochNumber), [1, 2, 3])
        XCTAssertEqual(try fixture.states.currentEpoch(conversationId: conversationId, ownerNamespace: namespace)?.epochNumber, 3)
    }

    /// Serveur A3 (#270) : une époque sautée relue après coup est « retired »,
    /// et l'enveloppe d'un appareil qui a déjà accusé réception revient `null`.
    func testRetiredEpochsAndAcknowledgedEnvelopesFromTheServer() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let creator = remote(alice, device: "device_alice_ios_01J7ABCD2345")
        let devices = fixture.deviceSet(adding: [creator.device])
        let served = try serve(fixture, creator: creator, devices: devices)
        MockURLProtocol.requestHandler = Self.server(served)
        let first = await sync(fixture, devices: devices)
        XCTAssertEqual(first, .received(epochNumber: 1))

        func reshape(_ data: Data, status: String? = nil, nullEnvelope: Bool = false) throws -> Data {
            var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            if let status, var epoch = root["epoch"] as? [String: Any] { epoch["status"] = status; root["epoch"] = epoch }
            if nullEnvelope { root["envelope"] = NSNull() }
            return try JSONSerialization.data(withJSONObject: root)
        }
        let keyTwo = Data(repeating: 0x22, count: 32), keyThree = Data(repeating: 0x33, count: 32)
        let two = try reshape(try epoch(2, key: keyTwo, fixture, creator: creator, devices: devices, chain: served.chain), status: "retired")
        let three = try epoch(3, key: keyThree, fixture, creator: creator, devices: devices, chain: served.chain)
        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/epochs/2") { return E2EEV2AccountFixture.response(request, two) }
            if path.hasSuffix("/epochs/current") { return E2EEV2AccountFixture.response(request, three) }
            return try Self.server(served)(request)
        }
        let caughtUp = await sync(fixture, devices: devices)
        XCTAssertEqual(caughtUp, .received(epochNumber: 3), "Une époque « retired » se relit")
        XCTAssertEqual(try fixture.keys.loadEpoch(conversationId: conversationId, epochNumber: 2,
                                                  ownerNamespace: fixture.session.ownerNamespace)?.epochKey, keyTwo)

        // Époque 4 dont l'enveloppe a été accusée ailleurs : rien n'est cru, on attend.
        let four = try reshape(try epoch(4, key: Data(repeating: 0x44, count: 32), fixture, creator: creator, devices: devices,
                                         chain: served.chain), nullEnvelope: true)
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.hasSuffix("/epochs/current") == true { return E2EEV2AccountFixture.response(request, four) }
            return try Self.server(served)(request)
        }
        let waiting = await sync(fixture, devices: devices)
        XCTAssertEqual(waiting, .waitingForEpoch)
        XCTAssertEqual(try fixture.states.currentEpoch(conversationId: conversationId, ownerNamespace: fixture.session.ownerNamespace)?
            .epochNumber, 3, "Sans clé, l'époque courante ne change pas")
    }

    private func sync(_ fixture: E2EEV2AccountFixture, devices: E2EEV2CertifiedDeviceSet) async -> E2EEV2ConversationSyncResult {
        await E2EEV2ConversationSyncV2(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        ).sync(conversationId: conversationId, isGroup: false, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId)
    }

    /// Tête-à-tête créé par Alice : genèse, manifeste de l'époque 1 et enveloppe
    /// pour l'appareil local, signés par `creator`.
    private func serve(_ fixture: E2EEV2AccountFixture, creator: Remote, devices: E2EEV2CertifiedDeviceSet) throws -> Served {
        let createdAtMs: Int64 = 1_790_000_000_000
        let chain = try E2EEV2MembershipChain.genesis(
            conversationId: conversationId, memberIds: [alice, fixture.user], adminIds: [], isGroup: false,
            actor: .init(userId: alice, deviceId: creator.device.deviceId), createdAtMs: createdAtMs
        ).map { try E2EEV2SignedString.sign($0.canonical, with: creator.signing) }
        let epochKey = Data((0..<32).map { UInt8(0x40 + $0) })
        let commitment = try E2EEV2EpochCrypto.keyCommitment(epochKey)
        let lines = E2EEV2EpochProposals.recipients(
            devices, members: [alice, fixture.user], excludesWeb: false, nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
        ).map { E2EEV2EpochManifest.recipient(userId: $0.userId, deviceId: $0.deviceId, platform: $0.platform, fingerprint: $0.fingerprint) }
        let manifest = E2EEV2EpochManifest.make(
            conversationId: conversationId, epochNumber: 1, creatorUserId: alice, creatorDeviceId: creator.device.deviceId,
            keyCommitmentB64: commitment, recipients: lines, excludesWeb: false, membershipChangeNumber: chain.count,
            membershipDigest: E2EEV2MembershipChange.digest(of: try XCTUnwrap(chain.last?.canonical)), createdAtMs: createdAtMs + 2
        )
        let signed = try E2EEV2SignedString.sign(manifest.canonical, with: creator.signing)
        let manifestObject: [String: Any] = ["manifest": signed.canonical, "signatureB64": signed.signatureB64, "recipients": lines]
        let context = E2EEV2EpochContext(
            conversationId: conversationId, epochNumber: 1,
            senderDeviceId: creator.device.deviceId, recipientDeviceId: fixture.descriptor.deviceId
        )
        let envelope = try E2EEV2EpochCrypto.wrap(
            epochKey: epochKey,
            recipientPublicKey: P256.KeyAgreement.PublicKey(x963Representation: try XCTUnwrap(Data(base64Encoded: fixture.descriptor.publicIdentityKeyB64))),
            ephemeralPrivateKey: P256.KeyAgreement.PrivateKey(), nonce: Data((0..<12).map { UInt8($0) }), context: context
        )
        let signature = try E2EEV2LowS.sign(
            E2EEV2EpochCrypto.signatureCanonical(context: context, keyCommitmentB64: commitment, envelope: envelope),
            with: creator.signing
        )
        return Served(
            chain: chain,
            manifest: try JSONSerialization.data(withJSONObject: ["epochNumber": "1", "manifest": manifestObject]),
            current: try JSONSerialization.data(withJSONObject: [
                "conversationId": conversationId,
                "epoch": ["id": "epoch_sync_00000000000001", "epochNumber": "1", "status": "active", "createdAt": "2026-10-01T06:10:00.000Z"],
                "manifest": manifestObject,
                "envelope": [
                    "recipientDeviceId": envelope.recipientDeviceId, "wrapAlgorithm": envelope.wrapAlgorithm,
                    "ephemeralPublicKeyB64": envelope.ephemeralPublicKeyB64, "wrappedEpochKeyB64": envelope.wrappedEpochKeyB64,
                    "nonceB64": envelope.nonceB64, "aadB64": envelope.aadB64, "signatureB64": signature.base64EncodedString(),
                ],
            ]),
            epochKey: epochKey
        )
    }

    /// Époque `number` créée par Alice sur la même chaîne, telle que
    /// `epochs/current` ou `epochs/{n}` la sert à l'appareil local.
    private func epoch(
        _ number: Int,
        key epochKey: Data,
        _ fixture: E2EEV2AccountFixture,
        creator: Remote,
        devices: E2EEV2CertifiedDeviceSet,
        chain: [E2EEV2SignedString]
    ) throws -> Data {
        let createdAtMs: Int64 = 1_790_000_000_000 + Int64(number) * 1_000
        let commitment = try E2EEV2EpochCrypto.keyCommitment(epochKey)
        let lines = E2EEV2EpochProposals.recipients(
            devices, members: [alice, fixture.user], excludesWeb: false, nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
        ).map { E2EEV2EpochManifest.recipient(userId: $0.userId, deviceId: $0.deviceId, platform: $0.platform, fingerprint: $0.fingerprint) }
        let manifest = E2EEV2EpochManifest.make(
            conversationId: conversationId, epochNumber: number, creatorUserId: alice, creatorDeviceId: creator.device.deviceId,
            keyCommitmentB64: commitment, recipients: lines, excludesWeb: false, membershipChangeNumber: chain.count,
            membershipDigest: E2EEV2MembershipChange.digest(of: try XCTUnwrap(chain.last?.canonical)), createdAtMs: createdAtMs
        )
        let signed = try E2EEV2SignedString.sign(manifest.canonical, with: creator.signing)
        let context = E2EEV2EpochContext(
            conversationId: conversationId, epochNumber: number,
            senderDeviceId: creator.device.deviceId, recipientDeviceId: fixture.descriptor.deviceId
        )
        let envelope = try E2EEV2EpochCrypto.wrap(
            epochKey: epochKey,
            recipientPublicKey: P256.KeyAgreement.PublicKey(x963Representation: try XCTUnwrap(Data(base64Encoded: fixture.descriptor.publicIdentityKeyB64))),
            ephemeralPrivateKey: P256.KeyAgreement.PrivateKey(), nonce: Data((0..<12).map { UInt8($0) }), context: context
        )
        let signature = try E2EEV2LowS.sign(
            E2EEV2EpochCrypto.signatureCanonical(context: context, keyCommitmentB64: commitment, envelope: envelope),
            with: creator.signing
        )
        return try JSONSerialization.data(withJSONObject: [
            "conversationId": conversationId,
            "epoch": ["id": "epoch_sync_0000000000000\(number)", "epochNumber": String(number), "status": "active", "createdAt": "2026-10-01T06:10:00.000Z"],
            "manifest": ["manifest": signed.canonical, "signatureB64": signed.signatureB64, "recipients": lines],
            "envelope": [
                "recipientDeviceId": envelope.recipientDeviceId, "wrapAlgorithm": envelope.wrapAlgorithm,
                "ephemeralPublicKeyB64": envelope.ephemeralPublicKeyB64, "wrappedEpochKeyB64": envelope.wrappedEpochKeyB64,
                "nonceB64": envelope.nonceB64, "aadB64": envelope.aadB64, "signatureB64": signature.base64EncodedString(),
            ],
        ])
    }

    /// Faux serveur : suite de la chaîne, manifeste de l'époque 1, époque courante.
    private static func server(_ served: Served) -> MockURLProtocol.Handler {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/membership") {
                let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "after" }?.value.flatMap(Int.init) ?? 0
                let page = served.chain.dropFirst(after).map { ["change": $0.canonical, "signatureB64": $0.signatureB64] }
                return E2EEV2AccountFixture.response(request, try JSONSerialization.data(withJSONObject: ["changes": page, "hasMore": false]))
            }
            if path.hasSuffix("/epochs/1/manifest") { return E2EEV2AccountFixture.response(request, served.manifest) }
            return E2EEV2AccountFixture.response(request, served.current)
        }
    }

    private func remote(_ user: String, device: String) -> Remote {
        let agreement = P256.KeyAgreement.PrivateKey()
        let signing = P256.Signing.PrivateKey()
        return Remote(
            device: E2EEV2CertifiedDevice(
                userId: user, deviceId: device, keyVersion: 1, platform: "ios",
                identityKeyB64: agreement.publicKey.x963Representation.base64EncodedString(),
                signingKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
                fingerprint: E2EEV2Canonical.deviceFingerprint(
                    identityKeyX963: agreement.publicKey.x963Representation, signingKeyX963: signing.publicKey.x963Representation
                ),
                capabilities: E2EEV2CapabilitiesDocument(
                    userId: user, deviceId: device, sequence: 1, issuedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
                    envelopeVersions: ["2"], payloadVersions: ["2"], kinds: ["DELETE", "EDIT", "TEXT"], features: ["calls"]
                )
            ),
            signing: signing
        )
    }
}
