import CryptoKit
import XCTest
@testable import SignalQuest

final class LockedRequests: @unchecked Sendable {
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

    var all: [(URLRequest, [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// Compte synthétique, coffres en mémoire et faux serveur (`MockURLProtocol`),
/// pour les tests du lot 4 (plan 3).
final class E2EEV2AccountFixture: @unchecked Sendable {
    static let userKey = "SignalQuest.LocalAccountScope.userId.v1"
    static let sessionKey = "SignalQuest.LocalAccountScope.sessionId.v1"
    static let legacyKey = "SignalQuest.E2EE.LegacyCacheLocked.v1"
    let user = "account_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
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
        try receipt(conversationId: try XCTUnwrap(body["conversationId"] as? String), recipientCount: recipientCount)
    }

    /// Entiers en chaînes (D.0).
    static func receipt(conversationId: String, recipientCount: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "conversationId": conversationId,
            "epoch": ["id": "epoch_" + conversationId, "epochNumber": "1", "status": "active", "createdAt": "2026-10-01T05:40:00.000Z"],
            "recipientCount": String(recipientCount),
        ])
    }

    /// Signature et enveloppes par le coffre de l'appareil local.
    func signer() -> (Data) throws -> Data {
        let namespace = session.ownerNamespace
        return { [identity] in try identity.sign(canonicalRequest: $0, ownerNamespace: namespace) }
    }

    func wrapper(epochKey: Data) -> (E2EEV2EpochContext, String) throws -> E2EEV2SignedEpochEnvelope {
        let namespace = session.ownerNamespace
        return { [identity] context, key in
            try identity.createSignedEpochEnvelope(
                context: context, epochKey: epochKey, recipientPublicIdentityKeyB64: key, ownerNamespace: namespace
            )
        }
    }

    static func response(_ request: URLRequest, _ data: Data, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data)
    }
}


/// Appareil distant certifié et ses clés privées (lot 5).
struct E2EEV2TestRemote {
    let device: E2EEV2CertifiedDevice
    let agreement: P256.KeyAgreement.PrivateKey
    let signing: P256.Signing.PrivateKey

    init(user: String, device deviceId: String, platform: String = "android") {
        agreement = P256.KeyAgreement.PrivateKey()
        signing = P256.Signing.PrivateKey()
        device = E2EEV2CertifiedDevice(
            userId: user, deviceId: deviceId, keyVersion: 1, platform: platform,
            identityKeyB64: agreement.publicKey.x963Representation.base64EncodedString(),
            signingKeyB64: signing.publicKey.x963Representation.base64EncodedString(),
            fingerprint: E2EEV2Canonical.deviceFingerprint(
                identityKeyX963: agreement.publicKey.x963Representation,
                signingKeyX963: signing.publicKey.x963Representation
            ),
            capabilities: E2EEV2CapabilitiesDocument(
                userId: user, deviceId: deviceId, sequence: 1, issuedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
                envelopeVersions: ["2"], payloadVersions: ["2"], kinds: [], features: ["calls"]
            )
        )
    }
}

/// Conversation v2 à deux, époque 1 vérifiée et gardée (lot 5).
struct E2EEV2SeededConversation {
    let conversationId: String
    let membership: E2EEV2MembershipState
    let current: E2EEV2ConversationStateStore.CurrentEpoch
    let epochKey: Data
    /// `epochs/current` de l'époque 1, tel que le serveur le sert à l'appareil local.
    let servedCurrent: Data
}

extension E2EEV2AccountFixture {
    func seedConversation(with peer: String, devices: E2EEV2CertifiedDeviceSet) throws -> E2EEV2SeededConversation {
        try seed(participants: [peer], isGroup: false, devices: devices)
    }

    /// Groupe créé par ce compte, qui en est l'administrateur.
    func seedGroup(with peers: [String], devices: E2EEV2CertifiedDeviceSet) throws -> E2EEV2SeededConversation {
        try seed(participants: peers, isGroup: true, devices: devices)
    }

    private func seed(participants: [String], isGroup: Bool, devices: E2EEV2CertifiedDeviceSet) throws -> E2EEV2SeededConversation {
        let epochKey = Data((0..<32).map { UInt8($0) })
        let creation = try make(
            participants: participants, isGroup: isGroup, title: isGroup ? "Groupe" : nil, excludesWeb: false, devices: devices,
            epochKey: epochKey
        )
        let namespace = session.ownerNamespace
        XCTAssertTrue(try keys.put(
            recordInput: .init(conversationId: creation.conversationId, epochId: "epoch_seeded_000000000001", epochNumber: 1, keyCommitmentB64: creation.epoch.keyCommitmentB64),
            epochKey: epochKey, ownerNamespace: namespace, expectedSession: session
        ))
        let current = E2EEV2ConversationStateStore.CurrentEpoch(
            conversationId: creation.conversationId, epochNumber: 1, membershipChangeNumber: creation.genesis.changeNumber,
            memberIds: creation.genesis.members.sorted(),
            recipientsDigest: E2EEV2Canonical.listDigest(tag: E2EEV2EpochManifest.recipientsTag, lines: creation.epoch.recipients),
            excludesWeb: false, createdAtMs: creation.epoch.createdAtMs, acceptedAtMs: creation.epoch.createdAtMs
        )
        try states.appendMembership(creation.membership, conversationId: creation.conversationId, ownerNamespace: namespace)
        try states.record(
            .init(
                conversationId: creation.conversationId, creatorUserId: user, creatorDeviceId: descriptor.deviceId,
                manifestDigest: E2EEV2Canonical.sha256B64URL(Data(creation.epoch.manifest.canonical.utf8)),
                membershipChangeNumber: creation.genesis.changeNumber,
                membershipDigest: E2EEV2MembershipChange.digest(of: try XCTUnwrap(creation.membership.last?.canonical)),
                recordedAtMs: creation.epoch.createdAtMs
            ),
            ownerNamespace: namespace
        )
        try states.recordCurrentEpoch(current, ownerNamespace: namespace)
        let own = try XCTUnwrap(creation.epoch.envelopes.first { $0.recipientDeviceId == descriptor.deviceId })
        let served = E2EEV2CanonicalJSON.encode(.object([
            "conversationId": .string(creation.conversationId),
            "epoch": .object([
                "id": .string("epoch_seeded_000000000001"), "epochNumber": .string("1"), "status": .string("active"),
                "createdAt": .string("2026-10-01T06:00:00.000Z"),
            ]),
            "manifest": E2EEV2EpochManifest.json(creation.epoch.manifest, recipients: creation.epoch.recipients),
            "envelope": .object([
                "recipientDeviceId": .string(own.recipientDeviceId), "wrapAlgorithm": .string(own.wrapAlgorithm),
                "ephemeralPublicKeyB64": .string(own.ephemeralPublicKeyB64), "wrappedEpochKeyB64": .string(own.wrappedEpochKeyB64),
                "nonceB64": .string(own.nonceB64), "aadB64": .string(own.aadB64), "signatureB64": .string(own.signatureB64),
            ]),
        ]))
        return .init(
            conversationId: creation.conversationId, membership: creation.genesis, current: current, epochKey: epochKey,
            servedCurrent: served
        )
    }

    /// Époque suivante gardée localement, mêmes membres et destinataires.
    func advance(_ seeded: E2EEV2SeededConversation, to epochNumber: Int, epochKey: Data) throws {
        let namespace = session.ownerNamespace
        XCTAssertTrue(try keys.put(
            recordInput: .init(
                conversationId: seeded.conversationId, epochId: "epoch_seeded_00000000000\(epochNumber)", epochNumber: epochNumber,
                keyCommitmentB64: try E2EEV2EpochCrypto.keyCommitment(epochKey)
            ),
            epochKey: epochKey, ownerNamespace: namespace, expectedSession: session
        ))
        let current = seeded.current
        try states.recordCurrentEpoch(
            .init(
                conversationId: current.conversationId, epochNumber: epochNumber,
                membershipChangeNumber: current.membershipChangeNumber, memberIds: current.memberIds,
                recipientsDigest: current.recipientsDigest, excludesWeb: current.excludesWeb,
                createdAtMs: current.createdAtMs + 1_000, acceptedAtMs: current.acceptedAtMs + 1_000
            ),
            ownerNamespace: namespace
        )
    }
}

extension E2EEV2AccountFixture {
    /// Octets exacts du corps envoyé, pour l'analyseur strict.
    static func rawBody(_ request: URLRequest) -> Data {
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
        return data
    }
}
