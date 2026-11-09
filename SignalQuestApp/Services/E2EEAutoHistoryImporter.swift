import Foundation

/// E2EE-AUTO §8 : import des messages v1 d'une conversation devenue
/// automatique. L'appareil qui tient la clé v1 lit les messages par la route v1,
/// les déchiffre lui-même et envoie chacun en message v2 `HISTORY_IMPORT` sous
/// `history:<id v1>:<16 hex>`. Le serveur ne garde que le premier import d'un
/// message : un doublon venu d'ailleurs se vérifie par la relecture du fil.
enum E2EEAutoHistoryImporter {
    /// Envois en vol au plus (§8).
    static let batchSize = 5

    struct Candidate: Equatable, Sendable {
        let source: E2EEV2LegacyMessageSource
        let body: E2EEV2HistoryImportBody
        let clientRequestId: String
        /// Source éphémère : reste jusqu'à `source.expiresAt`, en secondes
        /// arrondies au supérieur (§8) ; 0 pour un message permanent.
        let ttlSeconds: Int
    }

    enum Outcome: Equatable, Sendable {
        /// Accepté, ou déjà accepté de cet appareil.
        case imported
        /// Un import existe déjà (`E2EE_IMPORT_EXISTS`, ou `E2EE_MESSAGE_CONFLICT`
        /// sans le corps gardé) : il se vérifie dans le fil, jamais renvoyé.
        case exists
        /// Source refusée par le serveur : ce message ne repart pas.
        case refused
        /// Réseau, époque ou membre en attente : la tournée s'arrête là.
        case retry
    }

    struct Report: Equatable, Sendable {
        var outcomes: [String: Outcome] = [:]
        /// La tournée s'est arrêtée sur une attente : elle reprendra plus tard.
        var stopped = false
    }

    /// Source d'un message v1 déchiffré, ou nil s'il ne s'importe pas : sans
    /// pièce jointe tant que le serveur ne transporte pas les blobs, ni
    /// supprimé, ni éphémère déjà passé, et sous la limite de 80 Kio du vecteur.
    /// L'échéance d'un éphémère reprend celle que sert la route v1 (révision 16).
    static func source(
        _ item: MessageItem, text: String, conversationId: String, now: Date = Date()
    ) -> E2EEV2LegacyMessageSource? {
        guard item.isEncrypted, item.deletedAt == nil, item.attachments.isEmpty,
              item.expiresAt.map({ $0 > now }) ?? true,
              let senderId = item.senderId, let createdAt = item.createdAt else { return nil }
        let source = E2EEV2LegacyMessageSource(
            version: E2EEV2HistoryMigrationContract.version, conversationId: conversationId, messageId: item.id,
            senderId: senderId, kind: item.kind, content: text, metadata: item.metadata, createdAt: iso(createdAt),
            editedAt: item.editedAt.map(iso), replyToId: item.replyToId, expiresAt: item.expiresAt.map(iso)
        )
        guard (try? E2EEV2HistoryMigrationContract.canonicalSource(source)) != nil,
              E2EEV2HistoryMigrationContract.attachmentCount(source) == 0 else { return nil }
        return source
    }

    static func candidate(_ source: E2EEV2LegacyMessageSource, now: Date = Date()) -> Candidate? {
        var ttlSeconds = 0
        if let expiresAt = source.expiresAt {
            guard let expiry = E2EEV2PortableInventoryContract.parseInstant(expiresAt) else { return nil }
            let remaining = Int(expiry.timeIntervalSince(now).rounded(.up))
            guard remaining >= 1 else { return nil }
            ttlSeconds = min(remaining, maxTTLSeconds)
        }
        guard let bytes = try? E2EEV2HistoryMigrationContract.canonicalSource(source),
              let hash = try? E2EEV2HistoryMigrationContract.sourceHash(source),
              let clientRequestId = try? E2EEV2HistoryMigrationContract.clientRequestId(
                  messageId: source.messageId, sourceHash: hash
              ) else { return nil }
        return Candidate(
            source: source, body: .init(sourceB64: bytes.base64EncodedString(), sourceHash: hash, attachments: []),
            clientRequestId: clientRequestId, ttlSeconds: ttlSeconds
        )
    }

    /// Borne du `ttlSeconds` d'une enveloppe (30 jours).
    static let maxTTLSeconds = 2_592_000

    /// Échéance de lecture d'un import : la plus proche de celle de l'enveloppe
    /// signée et de `source.expiresAt` (§8).
    static func expiresAtMs(signedMs: Int64?, source: E2EEV2LegacyMessageSource?) -> Int64? {
        let sourceMs = source?.expiresAt
            .flatMap(E2EEV2PortableInventoryContract.parseInstant)
            .map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
        switch (signedMs, sourceMs) {
        case let (signed?, source?): return min(signed, source)
        default: return signedMs ?? sourceMs
        }
    }

    static func outcome(_ result: E2EEV2MessageSendResultV2) -> Outcome {
        switch result {
        case .sent, .alreadyAccepted:
            return .imported
        case .failure(let failure) where failure.statusCode == 409
            && ["E2EE_IMPORT_EXISTS", "E2EE_MESSAGE_CONFLICT"].contains(failure.code ?? ""):
            return .exists
        case .failure(let failure) where failure.statusCode == 400 && failure.code == "E2EE_IMPORT_SOURCE_INVALID":
            return .refused
        case .failure, .needsEpoch, .needsRotation, .compromisedEpoch, .membersNotTrusted, .capabilityMissing:
            return .retry
        }
    }

    /// Envoie les imports par lots de `batchSize`, dans l'ordre des sources.
    /// Une attente arrête la tournée après le lot en cours.
    static func run(
        _ candidates: [Candidate],
        send: @escaping @Sendable (Candidate) async -> E2EEV2MessageSendResultV2
    ) async -> Report {
        var report = Report()
        var start = 0
        while start < candidates.count, !Task.isCancelled {
            let batch = Array(candidates[start..<min(start + batchSize, candidates.count)])
            start += batchSize
            let results = await withTaskGroup(of: (String, Outcome).self) { group in
                for candidate in batch {
                    group.addTask { (candidate.source.messageId, outcome(await send(candidate))) }
                }
                var results: [(String, Outcome)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (messageId, outcome) in results { report.outcomes[messageId] = outcome }
            if results.contains(where: { $0.1 == .retry }) {
                report.stopped = true
                break
            }
        }
        return report
    }

    /// Imports vérifiés dont la source diffère de la lecture v1 de cet
    /// appareil : « import contesté ». `local` et `imported` : condensat par
    /// identifiant v1.
    static func contested(local: [String: String], imported: [String: String]) -> Set<String> {
        Set(imported.compactMap { messageId, hash in
            local[messageId].flatMap { $0 == hash ? nil : messageId }
        })
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
