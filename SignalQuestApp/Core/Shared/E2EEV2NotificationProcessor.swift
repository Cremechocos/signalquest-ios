import Foundation
import CryptoKit

/// A notification can select an opaque envelope, never a server URL or clear preview.
struct E2EEV2OpaqueNotificationRequest: Equatable, Sendable {
    let envelopeId: String
    let recipientOwnerScope: String

    init?(envelopeId: String, recipientOwnerScope: String) {
        guard E2EEV2PortableInventoryContract.validOpaqueId(envelopeId),
              recipientOwnerScope.range(of: #"^user:[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            return nil
        }
        self.envelopeId = envelopeId
        self.recipientOwnerScope = recipientOwnerScope
    }
}

/// Optional, revocable notification-only mirror. It never contains epoch/history keys.
/// Persist only in the dedicated shared Keychain group, never in UserDefaults or a file.
struct E2EEV2NotificationContext: Codable, Equatable, Sendable {
    let version: Int
    let revisionId: String
    let ownerScopeId: String
    let sessionId: String
    let authToken: String
    let expiresAtMs: Int64
    let descriptor: E2EEV2DeviceDescriptor
    let identityPrivateRawB64: String
    let signingPrivateRawB64: String
    let privacy: E2EEV2NotificationPrivacy
    let senderNames: [String: String]

    func isValid(now: Date) -> Bool {
        isStructurallyValid && expiresAtMs > Int64(now.timeIntervalSince1970 * 1_000)
    }

    var isStructurallyValid: Bool {
        guard version == 1,
              UUID(uuidString: revisionId) != nil,
              UUID(uuidString: sessionId) != nil,
              ownerScopeId.range(of: #"^user:[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              !authToken.isEmpty, authToken.utf8.count <= 16_384,
              authToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !authToken.contains(";"), !authToken.contains("\u{0}"),
              expiresAtMs > 0,
              E2EEV2PortableInventoryContract.validOpaqueId(descriptor.deviceId),
              descriptor.platform == "ios", descriptor.keyVersion == 1,
              descriptor.identityKeyAlgorithm == E2EEV2DeviceAlgorithms.identityKeyAlgorithm,
              descriptor.signingKeyAlgorithm == E2EEV2DeviceAlgorithms.signingKeyAlgorithm,
              privacy != .hidden,
              senderNames.count <= 500,
              senderNames.allSatisfy({
                  E2EEV2PortableInventoryContract.validOpaqueId($0.key) &&
                      !$0.value.isEmpty && $0.value.count <= 120
              }),
              let identityRaw = Data(base64Encoded: identityPrivateRawB64), identityRaw.count == 32,
              let signingRaw = Data(base64Encoded: signingPrivateRawB64), signingRaw.count == 32,
              let identity = try? P256.KeyAgreement.PrivateKey(rawRepresentation: identityRaw),
              let signing = try? P256.Signing.PrivateKey(rawRepresentation: signingRaw) else { return false }
        return identity.publicKey.x963Representation.base64EncodedString() == descriptor.publicIdentityKeyB64 &&
            signing.publicKey.x963Representation.base64EncodedString() == descriptor.publicSigningKeyB64
    }

    func hasSameContent(as other: Self) -> Bool {
        version == other.version && ownerScopeId == other.ownerScopeId && sessionId == other.sessionId &&
            authToken == other.authToken && expiresAtMs == other.expiresAtMs && descriptor == other.descriptor &&
            identityPrivateRawB64 == other.identityPrivateRawB64 && signingPrivateRawB64 == other.signingPrivateRawB64 &&
            privacy == other.privacy && senderNames == other.senderNames
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
    let fetch: @Sendable (URLRequest) async throws -> Data
    var now: @Sendable () -> Date = { Date() }
}

enum E2EEV2NotificationProcessor {
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
            let networkRequest = try signedRequest(
                request: request,
                context: context,
                apiBaseURL: apiBaseURL,
                allowLocalHTTP: allowLocalHTTP,
                now: dependencies.now()
            )
            let data = try await dependencies.fetch(networkRequest)
            try Task.checkCancellation()
            guard try dependencies.isCurrent(context), context.isValid(now: dependencies.now()) else {
                return .generic(.staleContext)
            }
            guard data.count <= E2EEV2WireLimits.maxJSONResponseBytes,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let envelope = root["envelope"] as? [String: Any],
                  let conversationId = envelope["conversationId"] as? String,
                  let delivery = E2EEV2MessageDeliveryContract.parseAndVerify(
                    data,
                    ownerScopeId: context.ownerScopeId,
                    expectedEnvelopeId: request.envelopeId,
                    expectedConversationId: conversationId,
                    expectedRecipientDeviceId: context.descriptor.deviceId
                  ), delivery.epochDelivery.status != "compromised" else {
                return .generic(.invalidDelivery)
            }
            if let expiresAt = delivery.expiresAt,
               let expiry = E2EEV2PortableInventoryContract.parseInstant(expiresAt),
               expiry <= dependencies.now() {
                return .generic(.expired)
            }
            guard let privateData = Data(base64Encoded: context.identityPrivateRawB64) else {
                return .generic(.contextUnavailable)
            }
            var identityRaw = privateData
            var epochKey = Data()
            defer {
                identityRaw.resetBytes(in: 0..<identityRaw.count)
                epochKey.resetBytes(in: 0..<epochKey.count)
            }
            let identity = try P256.KeyAgreement.PrivateKey(rawRepresentation: identityRaw)
            epochKey = try E2EEV2EpochCrypto.unwrap(
                envelope: delivery.epochDelivery.envelope.cryptoEnvelope,
                keyCommitmentB64: delivery.epochDelivery.keyCommitmentB64,
                recipientPrivateKey: identity,
                context: delivery.epochDelivery.epochContext
            )
            let message = try E2EEV2MessageReceiver.decryptContractPreview(
                input: delivery.incoming,
                epoch: .init(
                    conversationId: conversationId,
                    epochId: delivery.epochDelivery.epochId,
                    epochNumber: delivery.epochDelivery.epochNumber,
                    keyCommitmentB64: delivery.epochDelivery.keyCommitmentB64,
                    epochKey: epochKey
                )
            )
            guard try dependencies.isCurrent(context), !Task.isCancelled else {
                return .generic(.staleContext)
            }
            return .preview(.init(
                presentation: E2EEV2NotificationPresentationPolicy.present(
                    message,
                    privacy: context.privacy,
                    senderName: context.senderNames[delivery.senderId]
                ),
                envelopeId: request.envelopeId,
                conversationId: conversationId,
                ownerScopeId: context.ownerScopeId,
                sessionId: context.sessionId,
                contextRevisionId: context.revisionId
            ))
        } catch is CancellationError {
            return .generic(.cancelled)
        } catch is E2EEV2MessageCryptoError {
            return .generic(.invalidDelivery)
        } catch is E2EEV2EpochCryptoError {
            return .generic(.invalidDelivery)
        } catch {
            return .generic(.transport)
        }
    }

    private static func signedRequest(
        request: E2EEV2OpaqueNotificationRequest,
        context: E2EEV2NotificationContext,
        apiBaseURL: URL,
        allowLocalHTTP: Bool,
        now: Date
    ) throws -> URLRequest {
        guard let components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host, !host.isEmpty,
              components.scheme == "https" || (allowLocalHTTP && components.scheme == "http" &&
                ["localhost", "127.0.0.1", "::1"].contains(host)),
              let raw = Data(base64Encoded: context.signingPrivateRawB64) else {
            throw E2EEV2MessageCryptoError.invalidContext
        }
        let path = "/api/e2ee/v2/envelopes/\(request.envelopeId)/fetch"
        let body = Data("{}".utf8)
        let timestamp = Int64(now.timeIntervalSince1970 * 1_000)
        let nonce = try E2EEV2SignedRequest.newNonce()
        let canonical = try E2EEV2SignedRequest.canonicalRequest(
            method: "POST", path: path, timestampMs: timestamp, nonce: nonce, body: body
        )
        var privateRaw = raw
        defer { privateRaw.resetBytes(in: 0..<privateRaw.count) }
        let signing = try P256.Signing.PrivateKey(rawRepresentation: privateRaw)
        let proof = E2EEV2SignedHeaders(
            deviceId: context.descriptor.deviceId,
            timestampMs: timestamp,
            nonce: nonce,
            signatureB64: try signing.signature(for: canonical).derRepresentation.base64EncodedString()
        )
        var result = URLRequest(url: apiBaseURL.appendingPathComponent(String(path.dropFirst())))
        result.httpMethod = "POST"
        result.httpBody = body
        result.timeoutInterval = 12
        result.cachePolicy = .reloadIgnoringLocalCacheData
        result.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        result.setValue("auth_token=\(context.authToken)", forHTTPHeaderField: "Cookie")
        result.setValue("ios", forHTTPHeaderField: "X-Client-Platform")
        result.setValue(String(E2EEV2ProtocolWire.version), forHTTPHeaderField: E2EEV2ProtocolWire.protocolVersionHeader)
        result.setValue(E2EEV2ProtocolWire.messageCapabilities.sorted().joined(separator: ","),
                        forHTTPHeaderField: E2EEV2ProtocolWire.capabilitiesHeader)
        for (key, value) in proof.values { result.setValue(value, forHTTPHeaderField: key) }
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
