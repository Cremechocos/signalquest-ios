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

