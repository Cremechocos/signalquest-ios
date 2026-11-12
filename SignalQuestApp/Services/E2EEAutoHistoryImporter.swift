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
        /// Pièces v1 à relire et renvoyer en blobs avant l'envoi ; vide : `body` part tel quel.
        var pieces: [V1Piece] = []
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
        /// Une pièce attend (lecture ou envoi) : ce message réessaiera, les autres continuent.
        case waiting
    }

    struct Report: Equatable, Sendable {
        var outcomes: [String: Outcome] = [:]
        /// La tournée s'est arrêtée sur une attente : elle reprendra plus tard.
        var stopped = false
    }

    /// Source d'un message v1 lu (texte déchiffré, ou `content` servi s'il n'a
    /// pas de texte chiffré, comme Android), ou nil s'il ne s'importe pas : ni
    /// système, ni supprimé, ni éphémère déjà passé, 20 pièces au plus, et sous
    /// la limite de 80 Kio du vecteur. Ses pièces partent en blobs (révision 16).
    /// L'échéance d'un éphémère reprend celle que sert la route v1 (révision 16).
    static func source(
        _ item: MessageItem, text: String, conversationId: String, now: Date = Date()
    ) -> E2EEV2LegacyMessageSource? {
        guard item.kind != "SYSTEM", item.deletedAt == nil, item.attachments.count <= E2EEV2HistoryImportBody.maxAttachments,
              item.attachments.allSatisfy({ $0.id.map(E2EEV2Canonical.isOpaque) == true }),
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

    /// Envoie les imports par lots de `batchSize`, dans l'ordre des sources
    /// (`send` rend `outcome(_:)` du résultat, ou `.waiting` pour une pièce en
    /// attente). Une attente du serveur arrête la tournée après le lot en cours.
    static func run(
        _ candidates: [Candidate],
        send: @escaping @Sendable (Candidate) async -> Outcome
    ) async -> Report {
        var report = Report()
        var start = 0
        while start < candidates.count, !Task.isCancelled {
            let batch = Array(candidates[start..<min(start + batchSize, candidates.count)])
            start += batchSize
            let results = await withTaskGroup(of: (String, Outcome).self) { group in
                for candidate in batch {
                    group.addTask { (candidate.source.messageId, await send(candidate)) }
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

// MARK: - Pièces jointes v1 (§8, « Pièces jointes v1 », révision 16)

/// Les pièces d'un message v1 sont celles que la route v1 sert avec lui, dans
/// son ordre. Une pièce dont `metadata.e2eeAttachments[]` porte une entrée de
/// même `url` (non vide) a été chiffrée par le site ; sans entrée, elle est en
/// clair (pièces d'Android). Même lecture qu'Android (`E2EEAutoV1AttachmentRef`).
extension E2EEAutoHistoryImporter {
    /// Au-delà, une pièce est perdue pour l'import (100 Mio de clair).
    static let maxAttachmentPlaintextBytes: Int64 = 104_857_600

    struct V1Piece: Equatable, Sendable {
        /// Adresse `https` de la pièce ; nil : inexploitable, la pièce attend.
        let url: URL?
        /// Chiffrée par le site : son IV. Nil : pièce en clair.
        let ivB64: String?
        /// Entrée retenue mais inexploitable (`v` ≠ 1, `ivB64` absent ou vide) : attend.
        let unknownFormat: Bool
        let fileName: String?
        let mimeType: String?
    }

    enum PieceState: Equatable, Sendable { case importable, lost, pending }

    enum Decision: Equatable, Sendable {
        /// Au moins une pièce en attente : rien ne part, un import est définitif.
        case wait
        /// Les pièces importables partent, dans l'ordre de la source ; les perdues sont omises.
        case importing(indexes: [Int], attachmentMissing: Bool)
    }

    /// Ce qu'a donné la lecture d'une pièce.
    enum PieceRead: Equatable, Sendable {
        case bytes(plaintextSize: Int64)
        /// Statut (autre que 2xx) de la source v1.
        case status(Int)
        /// Chiffrée, la clé v1 détenue, et elle ne s'ouvre pas (IV compris).
        case decryptionFailed
        /// Clé absente, réseau, format inconnu, envoi du blob interrompu.
        case otherFailure
    }

    /// Message v1 qui ne se lit qu'avec la clé de conversation : texte chiffré, ou
    /// pièce chiffrée par le site (une pièce seule n'a pas de texte chiffré).
    static func requiresV1Key(_ item: MessageItem) -> Bool {
        item.isEncrypted || pieces(of: item).contains { $0.ivB64 != nil || $0.unknownFormat }
    }

    static func pieces(of item: MessageItem) -> [V1Piece] {
        let entries: [[String: Any]] = item.metadata
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["e2eeAttachments"] as? [Any] }?
            .compactMap { $0 as? [String: Any] } ?? []
        return item.attachments.map { attachment in
            let address = attachment.url?.absoluteString ?? ""
            let https = attachment.url.flatMap { isReadableSource($0) ? $0 : nil }
            guard !address.isEmpty, let entry = entries.first(where: { ($0["url"] as? String) == address }) else {
                return V1Piece(url: https, ivB64: nil, unknownFormat: false,
                               fileName: attachment.fileName, mimeType: attachment.contentType)
            }
            // `v` absent vaut 1 ; présent, il doit valoir 1.
            let versionOne = entry["v"] == nil || (entry["v"] as? NSNumber).map { $0.doubleValue == 1 } == true
            let iv = (entry["ivB64"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            func text(_ key: String) -> String? {
                (entry[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            }
            return V1Piece(
                url: https, ivB64: iv, unknownFormat: !versionOne || iv == nil,
                fileName: text("originalFileName") ?? attachment.fileName,
                mimeType: text("originalContentType") ?? attachment.contentType
            )
        }
    }

    /// Seul `https` se lit (§8). Exception des builds Debug : le stockage local de
    /// la pile QA (MinIO en `http://127.0.0.1`), jamais un autre hôte en clair.
    static func isReadableSource(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        #if DEBUG
        return url.scheme?.lowercased() == "http" && ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "")
        #else
        return false
        #endif
    }

    static func state(_ read: PieceRead) -> PieceState {
        switch read {
        case .bytes(let size): return size <= maxAttachmentPlaintextBytes ? .importable : .lost
        case .status(let code): return code == 404 || code == 410 ? .lost : .pending
        case .decryptionFailed: return .lost
        case .otherFailure: return .pending
        }
    }

    static func decide(sourceKind: String, states: [PieceState]) -> Decision {
        if states.contains(.pending) { return .wait }
        let indexes = states.indices.filter { states[$0] == .importable }
        return .importing(indexes: indexes, attachmentMissing: sourceKind == "ATTACHMENT" && indexes.isEmpty)
    }

    /// Lit une pièce à sa source v1, sans cookie ni en-tête d'identité (fichier
    /// public), et la déchiffre si le site l'a chiffrée. Le fichier rendu (clair)
    /// est à supprimer par l'appelant.
    static func read(
        _ piece: V1Piece,
        in directory: URL,
        session: URLSession = legacyAttachmentSession,
        decrypt: (Data, Data) async throws -> Data
    ) async -> (read: PieceRead, file: URL?) {
        guard !piece.unknownFormat, let url = piece.url else { return (.otherFailure, nil) }
        var iv: Data?
        if let ivB64 = piece.ivB64 {
            guard let decoded = decodeIV(ivB64), decoded.count == 12 else { return (.decryptionFailed, nil) }
            iv = decoded
        }
        let downloaded: URL
        do {
            let (temporary, response) = try await session.download(from: url)
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: temporary)
                return (.otherFailure, nil)
            }
            guard (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporary)
                return (.status(http.statusCode), nil)
            }
            downloaded = temporary
        } catch {
            return (.otherFailure, nil)
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let size = Int64((try? downloaded.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        // Chiffrée : 16 octets d'étiquette de plus que le clair ; le plafond reste celui du clair.
        guard size <= maxAttachmentPlaintextBytes + (iv == nil ? 0 : 16) else { return (.bytes(plaintextSize: size), nil) }
        let plain = directory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let iv {
                let ciphertext = try Data(contentsOf: downloaded, options: .mappedIfSafe)
                let opened: Data
                do {
                    opened = try await decrypt(iv, ciphertext)
                } catch E2EEError.decryptFailed {
                    return (.decryptionFailed, nil)
                }
                try opened.write(to: plain, options: [.atomic, .completeFileProtection])
                return (.bytes(plaintextSize: Int64(opened.count)), plain)
            }
            try FileManager.default.moveItem(at: downloaded, to: plain)
            return (.bytes(plaintextSize: size), plain)
        } catch {
            try? FileManager.default.removeItem(at: plain)
            return (.otherFailure, nil)
        }
    }

    /// IV du site : base64 standard, avec ou sans remplissage.
    static func decodeIV(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = trimmed.count % 4
        return Data(base64Encoded: remainder == 0 ? trimmed : trimmed + String(repeating: "=", count: 4 - remainder))
    }

    /// Fichier public : session éphémère, sans cookie, cache ni en-tête de l'app.
    static let legacyAttachmentSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    /// Pièce importée : nom et type d'origine, bornés comme le manifeste ;
    /// dimensions et durée nulles, comme Android.
    static func importAttachment(_ manifest: E2EEV2BlobEncryptionManifest, piece: V1Piece) -> E2EEV2HistoryImportAttachment {
        E2EEV2HistoryImportAttachment(
            blobId: manifest.blobId, mediaKeyB64: manifest.mediaKeyB64, noncePrefixB64: manifest.noncePrefixB64,
            plaintextSize: manifest.plaintextSize, ciphertextSize: manifest.ciphertextSize,
            plaintextSha256: manifest.plaintextSha256, ciphertextSha256: manifest.ciphertextSha256,
            fileName: piece.fileName.flatMap { $0.utf16.count <= 512 ? $0 : nil },
            mimeType: piece.mimeType.flatMap { $0.utf16.count <= 255 ? $0 : nil },
            width: nil, height: nil, durationMs: nil
        )
    }

    /// Ordre du contrat pour un message : lire et classer toutes ses pièces, puis
    /// envoyer les blobs des importables, puis rendre le corps à poster aussitôt.
    /// Nil : le message attend (pièce en attente, ou envoi interrompu).
    static func prepareAttachments(
        _ candidate: Candidate,
        workDirectory: URL,
        read: (V1Piece) async -> (read: PieceRead, file: URL?),
        upload: (URL) async -> E2EEV2BlobEncryptionManifest?
    ) async -> E2EEV2HistoryImportBody? {
        var files: [URL?] = []
        defer { for case let file? in files { try? FileManager.default.removeItem(at: file) } }
        var states: [PieceState] = []
        for piece in candidate.pieces {
            let result = await read(piece)
            files.append(result.file)
            states.append(state(result.read))
            if states.last == .pending { return nil }
        }
        guard case .importing(let indexes, _) = decide(sourceKind: candidate.source.kind, states: states) else { return nil }
        var attachments: [E2EEV2HistoryImportAttachment] = []
        for index in indexes {
            guard let file = files[index], let manifest = await upload(file) else { return nil }
            attachments.append(importAttachment(manifest, piece: candidate.pieces[index]))
        }
        return .init(sourceB64: candidate.body.sourceB64, sourceHash: candidate.body.sourceHash, attachments: attachments)
    }
}
