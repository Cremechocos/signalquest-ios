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
        let fixture = try CreationFixture(); defer { fixture.close() }
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
        let fixture = try CreationFixture(); defer { fixture.close() }
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
        let fixture = try CreationFixture(); defer { fixture.close() }
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
    }

    /// §3.1 : une époque ne sert qu'acceptée. La clé et l'état « v2 » ne sont
    /// gardés qu'après le reçu du serveur, exact.
    func testCreatorKeepsTheKeyOnlyOnceTheServerAcceptsTheConversation() async throws {
        let fixture = try CreationFixture(); defer { fixture.close() }
        let brunoPhone = remote(user: bruno, device: "device_bruno_android_01J7ABCD", platform: "android")
        let devices = fixture.deviceSet(adding: [brunoPhone.device])
        let creator = E2EEV2ConversationCreator(
            api: fixture.api, identityStore: fixture.identity, keyStore: fixture.keys, stateStore: fixture.states,
            expectedSession: fixture.session
        )

        // Conflit d'identifiant : rien n'est gardé.
        MockURLProtocol.requestHandler = { request in
            CreationFixture.response(request, Data(#"{"error":"Identifiant déjà utilisé.","code":"CONVERSATION_ID_TAKEN"}"#.utf8), status: 409)
        }
        guard case .failure(let conflict) = await creator.create(
            participantIds: [bruno], isGroup: false, title: nil, excludesWeb: false, devices: devices,
            expectedOwnerScopeId: fixture.session.ownerScopeId
        ) else { return XCTFail("Un 409 n'est pas une création") }
        XCTAssertEqual(conflict.code, "CONVERSATION_ID_TAKEN")
        XCTAssertTrue(try fixture.storedNothing())

        // Reçu inexact (nombre d'enveloppes) : rien n'est gardé non plus.
        MockURLProtocol.requestHandler = { request in
            let body = try CreationFixture.body(request)
            return CreationFixture.response(request, try CreationFixture.receipt(for: body, recipientCount: 99))
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
            let body = try CreationFixture.body(request)
            captured.append(request, body: body)
            let envelopes = (body["epoch"] as? [String: Any])?["envelopes"] as? [[String: Any]] ?? []
            return CreationFixture.response(request, try CreationFixture.receipt(for: body, recipientCount: envelopes.count))
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

    // MARK: Outils

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

private final class LockedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(URLRequest, [String: Any])] = []

    func append(_ request: URLRequest, body: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        items.append((request, body))
    }

    var first: (URLRequest, [String: Any])? {
        lock.lock(); defer { lock.unlock() }
        return items.first
    }
}

/// Compte synthétique, coffres en mémoire et faux serveur (`MockURLProtocol`).
private final class CreationFixture: @unchecked Sendable {
    static let userKey = "SignalQuest.LocalAccountScope.userId.v1"
    static let sessionKey = "SignalQuest.LocalAccountScope.sessionId.v1"
    static let legacyKey = "SignalQuest.E2EE.LegacyCacheLocked.v1"
    let user = "creation_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let vault = InMemoryTokenStore()
    let identity: E2EEV2DeviceIdentityStore
    let keys: E2EEV2EpochKeyStore
    let states: E2EEV2ConversationStateStore
    let descriptor: E2EEV2DeviceDescriptor
    let api: APIClient
    let network: URLSession
    let session: LocalAccountSession
    private let previous: [String: Any]

    init() throws {
        let defaults = UserDefaults.standard
        var previous: [String: Any] = [:]
        for key in [Self.userKey, Self.sessionKey, Self.legacyKey] {
            if let value = defaults.object(forKey: key) { previous[key] = value }
        }
        self.previous = previous
        LocalAccountScope.deactivate()
        LocalAccountScope.activate(userId: user)
        identity = E2EEV2DeviceIdentityStore(tokenStore: vault, identityChanged: { namespace in
            if LocalAccountScope.storageNamespace == namespace {
                guard let userId = LocalAccountScope.currentUserId else { return }
                LocalAccountScope.invalidateNotificationSession()
                LocalAccountScope.activate(userId: userId)
            }
        })
        keys = E2EEV2EpochKeyStore(tokenStore: vault)
        states = E2EEV2ConversationStateStore(tokenStore: vault)
        descriptor = try identity.loadOrCreate(ownerNamespace: LocalAccountScope.storageNamespace, label: "Synthetic iOS device")
        session = LocalAccountScope.sessionSnapshot()!
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken(Self.token(user))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        network = URLSession(configuration: configuration)
        api = APIClient(config: .test, credentials: credentials, session: network)
    }

    /// L'appareil local, certifié tel que l'annuaire le connaît, et d'autres.
    func deviceSet(adding remotes: [E2EEV2CertifiedDevice]) -> E2EEV2CertifiedDeviceSet {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let identityKey = Data(base64Encoded: descriptor.publicIdentityKeyB64) ?? Data()
        let signingKey = Data(base64Encoded: descriptor.publicSigningKeyB64) ?? Data()
        let own = E2EEV2CertifiedDevice(
            userId: user, deviceId: descriptor.deviceId, keyVersion: 1, platform: "ios",
            identityKeyB64: descriptor.publicIdentityKeyB64, signingKeyB64: descriptor.publicSigningKeyB64,
            fingerprint: E2EEV2Canonical.deviceFingerprint(identityKeyX963: identityKey, signingKeyX963: signingKey),
            capabilities: E2EEV2CapabilitiesDocument(
                userId: user, deviceId: descriptor.deviceId, sequence: 1, issuedAtMs: nowMs,
                envelopeVersions: ["2"], payloadVersions: ["2"], kinds: [], features: ["calls"]
            )
        )
        var byUser: [String: [E2EEV2CertifiedDevice]] = [user: [own]]
        for device in remotes { byUser[device.userId, default: []].append(device) }
        return E2EEV2CertifiedDeviceSet(devicesByUser: byUser, refusals: [:])
    }

    func make(
        participants: [String],
        isGroup: Bool,
        title: String?,
        excludesWeb: Bool,
        devices: E2EEV2CertifiedDeviceSet,
        epochKey: Data
    ) throws -> E2EEV2ConversationCreation {
        let namespace = session.ownerNamespace
        return try E2EEV2ConversationCreation.make(
            conversationId: try E2EEV2ConversationCreation.newConversationId(), ownUserId: user, device: descriptor,
            participantIds: participants, isGroup: isGroup, title: title, excludesWeb: excludesWeb, devices: devices,
            epochKey: epochKey, nowMs: Int64(Date().timeIntervalSince1970 * 1_000),
            sign: { try self.identity.sign(canonicalRequest: $0, ownerNamespace: namespace) },
            wrap: { context, key in
                try self.identity.createSignedEpochEnvelope(
                    context: context, epochKey: epochKey, recipientPublicIdentityKeyB64: key, ownerNamespace: namespace
                )
            }
        )
    }

    /// Ni clé d'époque ni état « v2 » dans le coffre du compte.
    func storedNothing() throws -> Bool {
        let namespace = session.ownerNamespace
        return try vault.keys(withPrefix: "epoch-v2:\(namespace):").isEmpty
            && vault.keys(withPrefix: E2EEV2ConversationStateStore.prefix(ownerNamespace: namespace)).isEmpty
    }

    func close() {
        MockURLProtocol.requestHandler = nil
        network.invalidateAndCancel()
        LocalAccountScope.deactivate()
        if let previousUser = previous[Self.userKey] as? String {
            LocalAccountScope.activate(userId: previousUser)
            if previous[Self.sessionKey] == nil { LocalAccountScope.invalidateNotificationSession() }
        }
        if let legacy = previous[Self.legacyKey] { UserDefaults.standard.set(legacy, forKey: Self.legacyKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.legacyKey) }
    }

    static func token(_ user: String) -> String {
        func b64(_ value: Data) -> String {
            value.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let payload = try! JSONSerialization.data(withJSONObject: ["userId": user, "kind": "session", "exp": Int(Date().timeIntervalSince1970) + 3_600])
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "HS256"])
        return b64(header) + "." + b64(payload) + ".synthetic"
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Reçu de création proposé par iOS (E.2).
    static func receipt(for body: [String: Any], recipientCount: Int) throws -> Data {
        let conversationId = try XCTUnwrap(body["conversationId"] as? String)
        return try JSONSerialization.data(withJSONObject: [
            "conversation": ["id": conversationId, "e2eeProtocolVersion": 2, "isGroup": body["isGroup"] ?? false],
            "epoch": ["id": "epoch_" + conversationId, "epochNumber": 1, "status": "active", "createdAt": "2026-10-01T05:40:00.000Z"],
            "recipientCount": recipientCount,
        ])
    }

    static func response(_ request: URLRequest, _ data: Data, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data)
    }
}

