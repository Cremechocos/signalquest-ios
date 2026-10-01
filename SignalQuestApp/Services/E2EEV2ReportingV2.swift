import CryptoKit
import Foundation

/// Clé publique de modération épinglée dans l'app (§11, D.10). La paire vient
/// de l'outil hors ligne de l'administrateur (SRV-A6) ; en changer demande une
/// mise à jour de l'app. Sans elle, le signalement d'une conversation v2 est
/// indisponible : jamais de repli en clair.
enum E2EEV2ModerationKey {
    struct Pinned: Equatable, Sendable {
        let keyId: String
        let publicKeyX963B64: String
    }

    static let pinned: Pinned? = nil
}

enum E2EEV2ReportResultV2: Equatable, Sendable {
    case sent(reportId: String)
    /// Aucune clé de modération épinglée dans cette version de l'app.
    case unavailable
    /// Le corps dépasserait 512 Kio (D.10) : rien n'est parti, il faut moins
    /// de messages.
    case tooLarge
    case failure(E2EEV2TransportFailure)
}

/// Signalement en deux parties (§11, D.10, E.3) : la partie en clair ne dit
/// rien que le serveur ne sache déjà ; la partie scellée, pour la seule clé de
/// modération, porte la charge exacte et `fk` de chaque message, jamais une
/// clé d'époque.
final class E2EEV2ReportSenderV2: @unchecked Sendable {
    static let maxMessages = 50

    private let transport: E2EEV2APITransport
    private let moderationKey: E2EEV2ModerationKey.Pinned?
    private let expectedSession: LocalAccountSession?

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        moderationKey: E2EEV2ModerationKey.Pinned? = E2EEV2ModerationKey.pinned,
        expectedSession: LocalAccountSession? = nil
    ) {
        self.moderationKey = moderationKey
        self.expectedSession = expectedSession
        transport = E2EEV2APITransport(api: api, identityStore: identityStore)
    }

    /// `messages` : des messages reçus par cet appareil, vérifiés et frankés,
    /// de la même conversation.
    func report(
        _ messages: [E2EEV2ReceivedMessageV2],
        reason: String,
        conversationId: String,
        expectedOwnerScopeId: String
    ) async -> E2EEV2ReportResultV2 {
        guard let moderationKey, E2EEV2Canonical.isOpaque(moderationKey.keyId),
              E2EEV2Canonical.isX963PublicKey(moderationKey.publicKeyX963B64),
              let keyData = Data(base64Encoded: moderationKey.publicKeyX963B64),
              let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: keyData) else {
            return .unavailable
        }
        guard let session = expectedSession ?? LocalAccountScope.sessionSnapshot(), session.isCurrent,
              session.ownerScopeId == expectedOwnerScopeId, expectedOwnerScopeId.hasPrefix("user:"),
              E2EEV2Canonical.isOpaque(conversationId), E2EEV2Report.reasons.contains(reason),
              (1...Self.maxMessages).contains(messages.count),
              Set(messages.map(\.envelopeId)).count == messages.count else {
            return .failure(localError("invalid-e2ee-report"))
        }
        // Dans l'ordre des messages.
        let ordered = messages.sorted { $0.sequence < $1.sequence }
        let body: Data
        let reportId: String
        do {
            reportId = "report_" + E2EEV2Canonical.base64URL(try E2EEV2MessageComposerV2.randomBytes(16))
            let clear = E2EEV2Report.clearJSON(
                reportId: reportId, conversationId: conversationId, reason: reason,
                items: ordered.map {
                    .init(envelopeId: $0.envelopeId, frankTagB64: $0.frankTagB64, serverTagB64: $0.serverTagB64, blobIds: [])
                }
            )
            _ = try E2EEV2Report.parseClear(clear)
            let sealed = try E2EEV2Report.seal(
                clearJSON: clear,
                items: ordered.map { .init(envelopeId: $0.envelopeId, payload: $0.payloadBytes, fk: $0.fk, mediaKeys: []) },
                moderationKey: publicKey
            )
            body = E2EEV2CanonicalJSON.encode(.object([
                "clear": .string(clear),
                "encB64": .string(sealed.enc.base64EncodedString()),
                "sealedB64": .string(sealed.sealed.base64EncodedString()),
                "moderationKeyId": .string(moderationKey.keyId),
            ]))
        } catch {
            return .failure(localError("e2ee-report-preparation-failed"))
        }
        // Le corps tient en 512 Kio (D.10) : sinon, moins de messages.
        guard body.count <= E2EEV2WireLimits.maxJSONResponseBytes else { return .tooLarge }
        switch await transport.bound(to: session).postJSON(
            path: "/api/e2ee/v2/reports", body: body, expectedOwnerScopeId: expectedOwnerScopeId, capabilitySet: .message
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let data, _, _):
            guard let root = (try? E2EEV2CanonicalJSON.parseStrict(data))?.objectValue, Set(root.keys) == ["reportId"],
                  root["reportId"]?.stringValue == reportId else {
                return .failure(localError("invalid-e2ee-report-response"))
            }
            return .sent(reportId: reportId)
        }
    }

    private func localError(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}
