import Foundation
import CryptoKit

/// A notification can select an opaque envelope, never a server URL or clear preview.
struct E2EEV2OpaqueNotificationRequest: Equatable, Sendable {
    let envelopeId: String
    let recipientOwnerScope: String

    init?(envelopeId: String, recipientOwnerScope: String) {
        guard E2EEV2PortableInventoryContract.validOpaqueId(envelopeId),
              recipientOwnerScope.range(of: #"^user:[a-f0-9]{64}\z"#, options: .regularExpression) != nil else {
            return nil
        }
        self.envelopeId = envelopeId
        self.recipientOwnerScope = recipientOwnerScope
    }
}

/// Miroir réservé aux notifications, facultatif et révocable (§2.6) : la
/// session, l'identifiant de l'appareil et les noms des expéditeurs. Aucune clé
/// privée d'appareil : l'extension lit l'enveloppe avec le seul cookie de
/// session, et les clés d'époque vérifiées vivent dans des entrées par
/// conversation (`E2EEV2NotificationConversation`). Rien du tout en mode
/// « aucun aperçu ». Persisté seulement dans le groupe de trousseau dédié,
/// jamais dans UserDefaults ni dans un fichier.
struct E2EEV2NotificationContext: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let revisionId: String
    let ownerScopeId: String
    let sessionId: String
    let authToken: String
    let expiresAtMs: Int64
    let deviceId: String
    let privacy: E2EEV2NotificationPrivacy
    let senderNames: [String: String]

    func isValid(now: Date) -> Bool {
        isStructurallyValid && expiresAtMs > Int64(now.timeIntervalSince1970 * 1_000)
    }

    var isStructurallyValid: Bool {
        version == Self.currentVersion &&
            UUID(uuidString: revisionId) != nil &&
            UUID(uuidString: sessionId) != nil &&
            ownerScopeId.range(of: #"^user:[a-f0-9]{64}\z"#, options: .regularExpression) != nil &&
            !authToken.isEmpty && authToken.utf8.count <= 16_384 &&
            authToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil &&
            !authToken.contains(";") && !authToken.contains("\u{0}") &&
            expiresAtMs > 0 &&
            E2EEV2PortableInventoryContract.validOpaqueId(deviceId) &&
            privacy != .hidden &&
            senderNames.count <= 500 &&
            senderNames.allSatisfy {
                E2EEV2PortableInventoryContract.validOpaqueId($0.key) && !$0.value.isEmpty && $0.value.count <= 120
            }
    }

    func hasSameContent(as other: Self) -> Bool {
        version == other.version && ownerScopeId == other.ownerScopeId && sessionId == other.sessionId &&
            authToken == other.authToken && expiresAtMs == other.expiresAtMs && deviceId == other.deviceId &&
            privacy == other.privacy && senderNames == other.senderNames
    }
}

/// Ce que l'extension peut lire d'une conversation v2, écran verrouillé (§2.6) :
/// les clés d'époque vérifiées (la courante, et celles remplacées depuis moins
/// de 24 heures), leurs membres, et les clés publiques certifiées des appareils
/// de ces membres. Écrite par l'app, jamais par le serveur.
struct E2EEV2NotificationConversation: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maxEpochs = 16
    static let maxSigningKeys = 512

    struct Epoch: Codable, Equatable, Sendable {
        let epochNumber: Int
        let keyB64: String
        let memberIds: [String]
        /// Heure locale de son remplacement ; nil pour l'époque courante.
        let replacedAtMs: Int64?
    }

    let version: Int
    let conversationId: String
    let epochs: [Epoch]
    /// « userId deviceId » → clé publique de signature certifiée (X9.63, b64).
    let signingKeys: [String: String]

    static func signingKeyName(userId: String, deviceId: String) -> String { "\(userId) \(deviceId)" }

    var isStructurallyValid: Bool {
        version == Self.currentVersion &&
            E2EEV2Canonical.isOpaque(conversationId) &&
            (1...Self.maxEpochs).contains(epochs.count) &&
            Set(epochs.map(\.epochNumber)).count == epochs.count &&
            epochs.filter({ $0.replacedAtMs == nil }).count == 1 &&
            epochs.allSatisfy { epoch in
                (1...E2EEV2Canonical.maxSequenceNumber).contains(epoch.epochNumber) &&
                    Data(base64Encoded: epoch.keyB64)?.count == 32 &&
                    !epoch.memberIds.isEmpty && epoch.memberIds.allSatisfy(E2EEV2Canonical.isOpaque)
            } &&
            signingKeys.count <= Self.maxSigningKeys &&
            signingKeys.allSatisfy { name, key in
                let parts = name.split(separator: " ", omittingEmptySubsequences: false)
                return parts.count == 2 && parts.allSatisfy { E2EEV2Canonical.isOpaque(String($0)) }
                    && E2EEV2Canonical.isX963PublicKey(key)
            }
    }
}

enum E2EEV2NotificationFallbackReason: Equatable, Sendable {
    case activationBlocked
    case contextUnavailable
    case wrongAccount
    case staleContext
    case invalidDelivery
    case expired
    case transport
    case cancelled
}

struct E2EEV2PreparedNotification: Equatable, Sendable {
    let presentation: E2EEV2NotificationPresentation
    let envelopeId: String
    let conversationId: String
    let ownerScopeId: String
    let sessionId: String
    let contextRevisionId: String
}

enum E2EEV2NotificationProcessingResult: Equatable, Sendable {
    case preview(E2EEV2PreparedNotification)
    case generic(E2EEV2NotificationFallbackReason)
}

struct E2EEV2NotificationProcessorDependencies: Sendable {
    let loadContext: @Sendable () throws -> E2EEV2NotificationContext?
    let isCurrent: @Sendable (E2EEV2NotificationContext) throws -> Bool
    let loadConversation: @Sendable (String) throws -> E2EEV2NotificationConversation?
    let fetch: @Sendable (URLRequest) async throws -> Data
    var now: @Sendable () -> Date = { Date() }
}

enum E2EEV2NotificationProcessor {
    /// Fenêtre d'une époque remplacée, comme dans l'app (§3.4).
    static let replacedEpochWindowMs: Int64 = 24 * 60 * 60 * 1_000

    static func processRuntime(
        request: E2EEV2OpaqueNotificationRequest,
        apiBaseURL: URL,
        allowLocalHTTP: Bool = false,
        dependencies: E2EEV2NotificationProcessorDependencies
    ) async -> E2EEV2NotificationProcessingResult {
        // No account, token, key or network access before the independent review gate.
        guard E2EEV2RuntimeReadGate.enabled else { return .generic(.activationBlocked) }
        return await processContractPreview(
            request: request,
            apiBaseURL: apiBaseURL,
            allowLocalHTTP: allowLocalHTTP,
            dependencies: dependencies
        )
    }

    /// Lecture de l'enveloppe avec le seul cookie de session (E.0, E.3), puis,
    /// comme l'app : appareil certifié, membre de l'époque, signature avant
    /// tout déchiffrement, franking et charge. Aucune clé privée d'appareil.
    /// Contract tests use this entry point; production enters only through processRuntime.
    static func processContractPreview(
        request: E2EEV2OpaqueNotificationRequest,
        apiBaseURL: URL,
        allowLocalHTTP: Bool = false,
        dependencies: E2EEV2NotificationProcessorDependencies
    ) async -> E2EEV2NotificationProcessingResult {
        do {
            try Task.checkCancellation()
            guard let context = try dependencies.loadContext(), context.isValid(now: dependencies.now()) else {
                return .generic(.contextUnavailable)
            }
            guard context.ownerScopeId == request.recipientOwnerScope else { return .generic(.wrongAccount) }
            guard try dependencies.isCurrent(context) else { return .generic(.staleContext) }
            let data = try await dependencies.fetch(fetchRequest(
                request: request, context: context, apiBaseURL: apiBaseURL, allowLocalHTTP: allowLocalHTTP
            ))
            try Task.checkCancellation()
            guard try dependencies.isCurrent(context), context.isValid(now: dependencies.now()) else {
                return .generic(.staleContext)
            }
            guard let fetched = E2EEV2DeliveredMessageV2.parseFetch(data, envelopeId: request.envelopeId) else {
                return .generic(.invalidDelivery)
            }
            let (conversationId, message) = fetched
            guard let conversation = try dependencies.loadConversation(conversationId),
                  conversation.conversationId == conversationId, conversation.isStructurallyValid else {
                return .generic(.contextUnavailable)
            }
            let envelope = message.signed.envelope
            let nowMs = Int64(dependencies.now().timeIntervalSince1970 * 1_000)
            guard let keyB64 = conversation.signingKeys[E2EEV2NotificationConversation.signingKeyName(
                      userId: message.senderUserId, deviceId: message.senderDeviceId
                  )],
                  let keyData = Data(base64Encoded: keyB64),
                  let senderKey = try? P256.Signing.PublicKey(x963Representation: keyData),
                  let epoch = conversation.epochs.first(where: { $0.epochNumber == envelope.epochNumber }),
                  epoch.replacedAtMs.map({ nowMs - $0 <= replacedEpochWindowMs }) ?? true,
                  epoch.memberIds.contains(message.senderUserId) else {
                return .generic(.invalidDelivery)
            }
            let messageContext = message.signed.context(conversationId: conversationId, senderDeviceId: message.senderDeviceId)
            try E2EEV2MessageCryptoV2.verifySignature(
                context: messageContext, envelope: envelope, signatureDerB64: message.signed.senderSignatureB64,
                senderSigningKey: senderKey
            )
            guard var epochKey = Data(base64Encoded: epoch.keyB64) else { return .generic(.contextUnavailable) }
            defer { epochKey.resetBytes(in: 0..<epochKey.count) }
            let opened = try E2EEV2MessageCryptoV2.decrypt(envelope: envelope, epochKey: epochKey, context: messageContext)
            if envelope.ttlSeconds > 0, opened.payload.sentAtMs + Int64(envelope.ttlSeconds) * 1_000 <= nowMs {
                return .generic(.expired)
            }
            guard try dependencies.isCurrent(context), !Task.isCancelled else {
                return .generic(.staleContext)
            }
            return .preview(.init(
                presentation: E2EEV2NotificationPresentationPolicy.present(
                    opened.payload, privacy: context.privacy, senderName: context.senderNames[message.senderUserId]
                ),
                envelopeId: request.envelopeId,
                conversationId: conversationId,
                ownerScopeId: context.ownerScopeId,
                sessionId: context.sessionId,
                contextRevisionId: context.revisionId
            ))
        } catch is CancellationError {
            return .generic(.cancelled)
        } catch is E2EEV2MessageV2Error {
            return .generic(.invalidDelivery)
        } catch is E2EEV2MessageCryptoError {
            return .generic(.invalidDelivery)
        } catch {
            return .generic(.transport)
        }
    }

    /// `GET`, cookie de session seulement : les lectures ne portent pas de
    /// signature d'appareil (E.0), et l'extension n'a aucune clé privée.
    private static func fetchRequest(
        request: E2EEV2OpaqueNotificationRequest,
        context: E2EEV2NotificationContext,
        apiBaseURL: URL,
        allowLocalHTTP: Bool
    ) throws -> URLRequest {
        guard let components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host, !host.isEmpty,
              components.scheme == "https" || (allowLocalHTTP && components.scheme == "http" &&
                ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
        let path = "/api/e2ee/v2/envelopes/\(request.envelopeId)/fetch"
        var result = URLRequest(url: apiBaseURL.appendingPathComponent(String(path.dropFirst())))
        result.httpMethod = "GET"
        result.timeoutInterval = 12
        result.cachePolicy = .reloadIgnoringLocalCacheData
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        result.setValue("auth_token=\(context.authToken)", forHTTPHeaderField: "Cookie")
        result.setValue("ios", forHTTPHeaderField: "X-Client-Platform")
        result.setValue(String(E2EEV2ProtocolWire.version), forHTTPHeaderField: E2EEV2ProtocolWire.protocolVersionHeader)
        result.setValue(E2EEV2ProtocolWire.messageCapabilities.sorted().joined(separator: ","),
                        forHTTPHeaderField: E2EEV2ProtocolWire.capabilitiesHeader)
        return result
    }
}

private final class E2EEV2NotificationNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum E2EEV2NotificationNetwork {
    static func fetch(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration,
                                 delegate: E2EEV2NotificationNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url == request.url,
              response.expectedContentLength <= Int64(E2EEV2WireLimits.maxJSONResponseBytes) else {
            throw E2EEV2MessageCryptoError.invalidEnvelope
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < E2EEV2WireLimits.maxJSONResponseBytes else {
                throw E2EEV2MessageCryptoError.invalidEnvelope
            }
            data.append(byte)
        }
        return data
    }
}
