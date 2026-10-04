import CryptoKit
import XCTest
@testable import SignalQuest

/// Lot 4 (plan 3) : une conversation v2 naît sur l'appareil, avec sa genèse
/// signée et son époque 1 (§3.1, §3.2, §3.5, E.2). Le serveur ne génère rien.
final class E2EEV2ConversationCreationTests: XCTestCase {
    private let bruno = "user_bruno_01J7ABCD23456789"
    private let carla = "user_carla_01J7ABCD23456789"
    private let dora = "user_dora_01J7ABCD234567890"

    /// Appareil distant certifié, avec sa clé d'accord pour relire son enveloppe.
    private struct Remote {
        let device: E2EEV2CertifiedDevice
        let agreement: P256.KeyAgreement.PrivateKey
    }

    func testCreationSignsAGenesisAndAnEpochOneThatEveryRecipientCanVerify() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let brunoPhone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let brunoWeb = remote(user: bruno, device: "device_bruno_web_01J7ABCD23", platform: "web")
        let doraOld = remote(user: dora, device: "device_dora_ios_01J7ABCD2345", platform: "ios", capabilities: false)
        let devices = fixture.deviceSet(adding: [brunoPhone.device, brunoWeb.device, doraOld.device])
        let epochKey = Data((0..<32).map { UInt8($0) })

        let creation = try fixture.make(
            participants: [bruno, carla, dora], isGroup: true, title: "Équipe terrain", excludesWeb: false,
            devices: devices, epochKey: epochKey
        )

        // Corps exact de la requête (E.2).
        let body = try XCTUnwrap(try E2EEV2CanonicalJSON.parseCanonical(String(decoding: creation.body, as: UTF8.self)).objectValue)
        XCTAssertEqual(Set(body.keys), ["conversationId", "isGroup", "title", "participantIds", "membership", "epoch"])
        XCTAssertEqual(body["isGroup"], .bool(true))
        let epoch = try XCTUnwrap(body["epoch"]?.objectValue)
        XCTAssertEqual(Set(epoch.keys), ["epochNumber", "previousEpochNumber", "manifest", "envelopes"])
        XCTAssertEqual(epoch["epochNumber"], .string("1"))
        XCTAssertEqual(epoch["previousEpochNumber"], .string("0"))
        XCTAssertTrue(creation.conversationId.hasPrefix("conv_") && E2EEV2Canonical.isOpaque(creation.conversationId))

        // Ce qu'un autre membre relira : genèse, puis manifeste lié à la genèse.
        var signingKeys: [String: P256.Signing.PublicKey] = [:]
        for device in devices.devicesByUser.values.flatMap({ $0 }) {
            signingKeys["\(device.userId)/\(device.deviceId)"] = device.signingKey
        }
        let chain = try XCTUnwrap(body["membership"]?.arrayValue).compactMap(E2EEV2MembershipChange.signed(from:))
        let wire = try XCTUnwrap(epoch["manifest"].flatMap(E2EEV2EpochManifest.signed(from:)))
        let manifest = try E2EEV2EpochManifest.verify(
            wire.manifest, recipients: wire.recipients,
            creatorSigningKey: try XCTUnwrap(signingKeys["\(fixture.user)/\(fixture.descriptor.deviceId)"])
        )
        let state = try E2EEV2EpochBinding.verifyGenesis(
            manifest, recipients: wire.recipients, chain: chain, isGroup: true
        ) { signingKeys["\($0)/\($1)"] }
        XCTAssertEqual(state.members, [fixture.user, bruno, carla, dora])
        XCTAssertEqual(state.admins, [fixture.user], "Le créateur administre le groupe")
        XCTAssertEqual(manifest.membershipChangeNumber, chain.count)

        // Destinataires : appareils certifiés et à jour, navigateur compris ;
        // un appareil sans capacités récentes et un membre sans appareil attendent.
        let recipientDevices = Set(wire.recipients.compactMap { E2EEV2EpochManifest.Recipient.parse($0)?.deviceId })
        XCTAssertEqual(recipientDevices, [fixture.descriptor.deviceId, brunoPhone.device.deviceId, brunoWeb.device.deviceId])
        XCTAssertEqual(creation.pendingUserIds, [carla, dora].sorted())

        // Chaque destinataire retrouve la clé de l'époque dans son enveloppe.
        for remote in [brunoPhone, brunoWeb] {
            let envelope = try XCTUnwrap(creation.epoch.envelopes.first { $0.recipientDeviceId == remote.device.deviceId })
            let unwrapped = try E2EEV2EpochCrypto.unwrap(
                envelope: envelope.cryptoEnvelope, keyCommitmentB64: manifest.keyCommitmentB64,
                recipientPrivateKey: remote.agreement,
                context: .init(
                    conversationId: creation.conversationId, epochNumber: 1,
                    senderDeviceId: fixture.descriptor.deviceId, recipientDeviceId: remote.device.deviceId
                )
            )
            XCTAssertEqual(unwrapped, epochKey)
        }
    }

    func testExcludedBrowsersStayOutOfTheFirstEpoch() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let brunoPhone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let brunoWeb = remote(user: bruno, device: "device_bruno_web_01J7ABCD23", platform: "web")
        let creation = try fixture.make(
            participants: [bruno], isGroup: false, title: nil, excludesWeb: true,
            devices: fixture.deviceSet(adding: [brunoPhone.device, brunoWeb.device]), epochKey: Data(repeating: 7, count: 32)
        )
        XCTAssertTrue(creation.genesis.excludesWeb)
        XCTAssertEqual(creation.membership.last.flatMap { try? E2EEV2MembershipChange.parse($0.canonical, previousCanonical: creation.membership.dropLast().last?.canonical) }?.action, "EXCLUDE_WEB_ON")
        XCTAssertFalse(creation.epoch.recipients.contains { $0.contains("\nweb\n") }, "Aucun navigateur dans l'époque 1")
        XCTAssertTrue(creation.genesis.admins.isEmpty, "Pas d'administrateur en tête-à-tête")
    }

    func testCreationRefusesAnUncertifiedDeviceOrInvalidMembers() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let brunoPhone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let empty = E2EEV2CertifiedDeviceSet(devicesByUser: [bruno: [brunoPhone.device]], refusals: [:])
        XCTAssertThrowsError(try fixture.make(participants: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: empty, epochKey: Data(count: 32))) {
            XCTAssertEqual($0 as? E2EEV2ConversationCreation.Failure, .deviceNotCertified)
        }
        let impostor = E2EEV2CertifiedDevice(
            userId: fixture.user, deviceId: fixture.descriptor.deviceId, keyVersion: 1, platform: "ios",
            identityKeyB64: brunoPhone.device.identityKeyB64, signingKeyB64: fixture.descriptor.publicSigningKeyB64,
            fingerprint: brunoPhone.device.fingerprint, capabilities: brunoPhone.device.capabilities
        )
        let swapped = E2EEV2CertifiedDeviceSet(devicesByUser: [fixture.user: [impostor], bruno: [brunoPhone.device]], refusals: [:])
        XCTAssertThrowsError(try fixture.make(participants: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: swapped, epochKey: Data(count: 32)),
                             "L'annuaire ne connaît pas cet appareil avec ces clés")
        let devices = fixture.deviceSet(adding: [brunoPhone.device])
        XCTAssertThrowsError(try fixture.make(participants: [bruno, carla], isGroup: false, title: nil, excludesWeb: false, devices: devices, epochKey: Data(count: 32))) {
            XCTAssertEqual($0 as? E2EEV2ConversationCreation.Failure, .invalidMembers, "Un tête-à-tête a deux membres")
        }
        XCTAssertThrowsError(try fixture.make(participants: [fixture.user, bruno], isGroup: true, title: nil, excludesWeb: false, devices: devices, epochKey: Data(count: 32))) {
            XCTAssertEqual($0 as? E2EEV2ConversationCreation.Failure, .invalidMembers, "L'auteur n'est pas un participant invité")
        }
        let refused = E2EEV2CertifiedDeviceSet(devicesByUser: fixture.deviceSet(adding: []).devicesByUser, refusals: [bruno: .uikChanged])
        XCTAssertThrowsError(try fixture.make(participants: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: refused, epochKey: Data(count: 32))) {
            XCTAssertEqual($0 as? E2EEV2ConversationCreation.Failure, .membersNotTrusted([bruno]),
                           "Pas de conversation qui l'exclurait en silence")
        }
    }

    /// §3.1 : une époque ne sert qu'acceptée. La clé et l'état « v2 » ne sont
    /// gardés qu'après le reçu du serveur, exact.
    func testCreatorKeepsTheKeyOnlyOnceTheServerAcceptsTheConversation() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let brunoPhone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let devices = fixture.deviceSet(adding: [brunoPhone.device])
        let creator = E2EEV2ConversationCreator(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )

        // Conflit d'identifiant : rien n'est gardé.
        MockURLProtocol.requestHandler = { request in
            E2EEV2AccountFixture.response(request, Data(#"{"error":"Identifiant déjà utilisé.","code":"CONVERSATION_ID_TAKEN"}"#.utf8), status: 409)
        }
        guard case .failure(let conflict) = await creator.create(
            participantIds: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices,
            expectedOwnerScopeId: fixture.session.ownerScopeId
        ) else { return XCTFail("Un 409 n'est pas une création") }
        XCTAssertEqual(conflict.code, "CONVERSATION_ID_TAKEN")
        XCTAssertTrue(try fixture.storedNothing())

        // Reçu inexact (nombre d'enveloppes) : rien n'est gardé non plus.
        MockURLProtocol.requestHandler = { request in
            let body = try E2EEV2AccountFixture.body(request)
            return E2EEV2AccountFixture.response(request, try E2EEV2AccountFixture.receipt(for: body, recipientCount: 99))
        }
        guard case .failure(let invalid) = await creator.create(
            participantIds: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices,
            expectedOwnerScopeId: fixture.session.ownerScopeId
        ) else { return XCTFail("Un reçu inexact n'est pas une création") }
        XCTAssertEqual(invalid.message, "invalid-e2ee-conversation-creation-response")
        XCTAssertTrue(try fixture.storedNothing())

        // Reçu exact : la clé de l'époque 1 et l'état « v2 » sont gardés.
        let captured = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            let body = try E2EEV2AccountFixture.body(request)
            captured.append(request, body: body)
            let envelopes = (body["epoch"] as? [String: Any])?["envelopes"] as? [[String: Any]] ?? []
            return E2EEV2AccountFixture.response(request, try E2EEV2AccountFixture.receipt(for: body, recipientCount: envelopes.count))
        }
        guard case .created(let conversationId, let pending) = await creator.create(
            participantIds: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices,
            expectedOwnerScopeId: fixture.session.ownerScopeId
        ) else { return XCTFail("Création refusée") }
        XCTAssertEqual(pending, [])
        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.0.httpMethod, "POST")
        XCTAssertEqual(request.0.url?.path, "/api/e2ee/v2/conversations")
        XCTAssertEqual(request.1["conversationId"] as? String, conversationId)
        let stored = try XCTUnwrap(try fixture.keys.load(conversationId: conversationId, ownerNamespace: fixture.session.ownerNamespace))
        XCTAssertEqual(stored.epochNumber, 1)
        XCTAssertEqual(stored.epochId, "epoch_" + conversationId)
        XCTAssertTrue(try fixture.states.isV2(conversationId: conversationId, ownerNamespace: fixture.session.ownerNamespace))
    }

    /// Point 5 du relevé Android (04/10) : un reçu perdu ne laisse jamais de
    /// conversation orpheline ; la même demande renvoie le même corps.
    func testALostReceiptIsReplayedWithTheSameConversationAndBytes() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let brunoPhone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let devices = fixture.deviceSet(adding: [brunoPhone.device])
        let creator = E2EEV2ConversationCreator(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let bodies = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            bodies.append(request, body: [:])
            _ = E2EEV2AccountFixture.rawBody(request)
            return E2EEV2AccountFixture.response(request, Data(#"{"error":"x","code":"INTERNAL_ERROR"}"#.utf8), status: 503)
        }
        guard case .failure = await creator.create(
            participantIds: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices,
            expectedOwnerScopeId: fixture.session.ownerScopeId
        ) else { return XCTFail("503 attendu") }
        let raw = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            let body = try E2EEV2AccountFixture.body(request)
            raw.append(request, body: body)
            let envelopes = (body["epoch"] as? [String: Any])?["envelopes"] as? [[String: Any]] ?? []
            return E2EEV2AccountFixture.response(request, try E2EEV2AccountFixture.receipt(for: body, recipientCount: envelopes.count))
        }
        guard case .created(let conversationId, _) = await creator.create(
            participantIds: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices,
            expectedOwnerScopeId: fixture.session.ownerScopeId
        ) else { return XCTFail("Création reprise") }
        let first = try XCTUnwrap(bodies.first?.0), second = try XCTUnwrap(raw.first?.0)
        XCTAssertEqual(E2EEV2AccountFixture.rawBody(second), E2EEV2AccountFixture.rawBody(first), "Les mêmes octets")
        XCTAssertEqual(raw.first?.1["conversationId"] as? String, conversationId)
        XCTAssertNil(try fixture.states.pendingCreation(
            request: E2EEV2ConversationCreator.creationRequest(participantIds: [bruno], isGroup: false, title: nil, excludesWeb: false),
            ownerNamespace: fixture.session.ownerNamespace
        ), "Plus rien en attente après le reçu")
    }

    // MARK: Migration (§14.2)

    func testAnEncryptedV1ConversationMigratesOnceEveryMemberHasACertifiedDevice() throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let brunoPhone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let carlaPhone = remote(user: carla, device: "device_carla_ios_01J7ABCD2345", platform: "ios")
        let group = v1Conversation(group: true, participants: [(fixture.user, "member"), (bruno, "owner"), (carla, "admin")])
        let partial = fixture.deviceSet(adding: [brunoPhone.device])
        let all = fixture.deviceSet(adding: [brunoPhone.device, carlaPhone.device])

        XCTAssertEqual(E2EEV2ConversationMigration.decide(group, isV2: false, devices: partial, nowMs: nowMs), .membersWaiting([carla]))
        XCTAssertEqual(E2EEV2ConversationMigration.decide(group, isV2: false, devices: all, nowMs: nowMs), .migrate)
        XCTAssertEqual(E2EEV2ConversationMigration.decide(group, isV2: true, devices: all, nowMs: nowMs), .alreadyV2)
        let plain = v1Conversation(group: false, participants: [(fixture.user, "member"), (bruno, "member")], encrypted: false)
        XCTAssertEqual(E2EEV2ConversationMigration.decide(plain, isV2: false, devices: all, nowMs: nowMs), .notEncrypted)

        let epochKey = Data(repeating: 3, count: 32)
        let migration = try E2EEV2ConversationMigration.make(
            group, ownUserId: fixture.user, device: fixture.descriptor, devices: all, epochKey: epochKey, nowMs: nowMs,
            sign: fixture.signer(), wrap: fixture.wrapper(epochKey: epochKey)
        )
        XCTAssertEqual(migration.conversationId, group.id, "La conversation garde son identifiant")
        XCTAssertEqual(migration.genesis.members, [fixture.user, bruno, carla])
        XCTAssertEqual(migration.genesis.admins, [bruno, carla], "Propriétaire et administrateurs v1, l'auteur reste membre")
        XCTAssertEqual(migration.genesis.genesisActor?.userId, fixture.user)
        let body = try XCTUnwrap(try E2EEV2CanonicalJSON.parseCanonical(String(decoding: migration.migrationBody, as: UTF8.self)).objectValue)
        XCTAssertEqual(Set(body.keys), ["membership", "epoch"])

        let stranger = v1Conversation(group: true, participants: [(bruno, "owner"), (carla, "member")])
        XCTAssertThrowsError(try E2EEV2ConversationMigration.make(
            stranger, ownUserId: fixture.user, device: fixture.descriptor, devices: all, epochKey: epochKey, nowMs: nowMs,
            sign: fixture.signer(), wrap: fixture.wrapper(epochKey: epochKey)
        ), "Seul un membre migre une conversation")
    }

    func testMigrationIsPostedOnTheGenesisRouteAndKeptOnlyOnceAccepted() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let brunoPhone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let devices = fixture.deviceSet(adding: [brunoPhone.device])
        let direct = v1Conversation(group: false, participants: [(fixture.user, "member"), (bruno, "member")])
        let creator = E2EEV2ConversationCreator(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let captured = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            let body = try E2EEV2AccountFixture.body(request)
            captured.append(request, body: body)
            let envelopes = (body["epoch"] as? [String: Any])?["envelopes"] as? [[String: Any]] ?? []
            return E2EEV2AccountFixture.response(request, try E2EEV2AccountFixture.receipt(conversationId: direct.id, recipientCount: envelopes.count))
        }
        guard case .created(let conversationId, _) = await creator.migrate(
            direct, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId
        ) else { return XCTFail("Migration refusée") }
        XCTAssertEqual(conversationId, direct.id)
        let (request, body) = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.url?.path, "/api/e2ee/v2/conversations/\(direct.id)/genesis")
        XCTAssertEqual(Set(body.keys), ["membership", "epoch"])
        XCTAssertTrue(try fixture.states.isV2(conversationId: direct.id, ownerNamespace: fixture.session.ownerNamespace))
        XCTAssertEqual(try fixture.states.currentEpoch(conversationId: direct.id, ownerNamespace: fixture.session.ownerNamespace)?.epochNumber, 1)
    }

    /// Relecture indépendante du lot 4 : une migration ne signe qu'une genèse.
    /// Après un échec, le nouvel essai renvoie le même corps, octet pour octet.
    func testAFailedMigrationIsRetriedWithTheSameSignedBody() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let brunoPhone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let devices = fixture.deviceSet(adding: [brunoPhone.device])
        let direct = v1Conversation(group: false, participants: [(fixture.user, "member"), (bruno, "member")])
        XCTAssertEqual(E2EEV2ConversationMigration.decide(direct, isV2: nil, devices: devices, nowMs: 0), .alreadyV2,
                       "État « v2 » illisible : jamais de migration")
        let creator = E2EEV2ConversationCreator(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        let bodies = LockedRequests()
        MockURLProtocol.requestHandler = { request in
            bodies.append(request, body: try E2EEV2AccountFixture.body(request))
            return E2EEV2AccountFixture.response(request, Data(#"{"error":"Indisponible.","code":"UNAVAILABLE"}"#.utf8), status: 503)
        }
        guard case .failure = await creator.migrate(direct, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId)
        else { return XCTFail("Un 503 n'est pas une migration") }
        let namespace = fixture.session.ownerNamespace
        XCTAssertNotNil(try fixture.states.pendingGenesis(conversationId: direct.id, ownerNamespace: namespace))

        MockURLProtocol.requestHandler = { request in
            let body = try E2EEV2AccountFixture.body(request)
            bodies.append(request, body: body)
            let envelopes = (body["epoch"] as? [String: Any])?["envelopes"] as? [[String: Any]] ?? []
            return E2EEV2AccountFixture.response(request, try E2EEV2AccountFixture.receipt(conversationId: direct.id, recipientCount: envelopes.count))
        }
        guard case .created = await creator.migrate(direct, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId)
        else { return XCTFail("Nouvel essai refusé") }
        let sent = bodies.all
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: sent[0].1, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: sent[1].1, options: [.sortedKeys]),
            "Même genèse, même époque 1, mêmes signatures"
        )
        XCTAssertNil(try fixture.states.pendingGenesis(conversationId: direct.id, ownerNamespace: namespace), "Effacé une fois acceptée")
        XCTAssertTrue(try fixture.states.isV2(conversationId: direct.id, ownerNamespace: namespace))
    }

    /// v0.4.16 : une genèse refusée pour de bon n'est jamais renvoyée.
    func testAGenesisRefusedForGoodIsForgotten() async throws {
        let fixture = try E2EEV2AccountFixture(); defer { fixture.close() }
        let brunoPhone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let devices = fixture.deviceSet(adding: [brunoPhone.device])
        let direct = v1Conversation(group: false, participants: [(fixture.user, "member"), (bruno, "member")])
        let creator = E2EEV2ConversationCreator(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )
        for code in ["E2EE_CONVERSATION_ALREADY_V2", "E2EE_GENESIS_NOT_ELIGIBLE"] {
            MockURLProtocol.requestHandler = { request in
                E2EEV2AccountFixture.response(request, Data(#"{"error":"x","code":"\#(code)"}"#.utf8), status: 409)
            }
            guard case .failure(let failure) = await creator.migrate(direct, devices: devices, expectedOwnerScopeId: fixture.session.ownerScopeId)
            else { return XCTFail("409 attendu") }
            XCTAssertEqual(failure.code, code)
            XCTAssertNil(try fixture.states.pendingGenesis(conversationId: direct.id, ownerNamespace: fixture.session.ownerNamespace), code)
        }
    }

    // MARK: Outils

    private func v1Conversation(group: Bool, participants: [(String, String)], encrypted: Bool = true) -> MessageConversation {
        MessageConversation(
            id: "conversation_v1_0123456789AB", title: group ? "Équipe terrain" : nil, isGroup: group, e2eeEnabled: encrypted,
            groupPhotoUrl: nil, createdAt: nil, updatedAt: nil, lastMessageAt: nil, lastReadAt: nil, pinnedAt: nil,
            participants: participants.map {
                ConversationParticipant(
                    userId: $0.0, role: $0.1, joinedAt: nil, lastReadAt: nil,
                    user: MessageUser(id: $0.0, name: nil, email: "", avatarUrl: nil), presence: nil
                )
            },
            lastMessage: nil
        )
    }

    private func remote(user: String, device: String, platform: String, capabilities: Bool = true) -> Remote {
        let agreement = P256.KeyAgreement.PrivateKey()
        let signing = P256.Signing.PrivateKey()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        return Remote(
            device: E2EEV2CertifiedDevice(
                userId: user, deviceId: device, keyVersion: 1, platform: platform,
                identityKeyB64: agreement.publicKey.x963Representation.base64EncodedString(),
                signingKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
                fingerprint: E2EEV2Canonical.deviceFingerprint(
                    identityKeyX963: agreement.publicKey.x963Representation,
                    signingKeyX963: signing.publicKey.x963Representation
                ),
                capabilities: capabilities ? E2EEV2CapabilitiesDocument(
                    userId: user, deviceId: device, sequence: 1, issuedAtMs: nowMs,
                    envelopeVersions: ["2"], payloadVersions: ["2"], kinds: [], features: ["calls"]
                ) : nil
            ),
            agreement: agreement
        )
    }
}
