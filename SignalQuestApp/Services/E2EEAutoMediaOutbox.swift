import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Une pièce prête à chiffrer : octets déjà sans lieu (E2EE-AUTO §7.7, vie
/// privée à l'envoi), type et dimensions, et sa miniature JPEG s'il en faut une.
struct E2EEAutoMediaSource: Sendable {
    let data: Data
    let fileName: String
    let mimeType: String
    let width: Int?
    let height: Int?
    let durationMs: Int64?
    let thumbnail: Thumbnail?

    struct Thumbnail: Sendable, Equatable {
        let data: Data
        let width: Int
        let height: Int
    }
}

/// Préparation des pièces jointes chiffrées. Une image fixe part en JPEG de
/// 1 280 px au plus, réencodée donc sans métadonnée, comme en clair ; un GIF
/// ou un WebP animé, une vidéo et une image envoyée en fichier gardent leurs
/// octets, lieu mis à zéro (`MediaLocationStripper`).
enum E2EEAutoMediaPreparation {
    /// Côté de la miniature : bien sous les 1 280 px et les 256 Kio permis.
    static let thumbnailSide: CGFloat = 480

    static func photo(_ raw: Data) -> E2EEAutoMediaSource? {
        if let animated = MediaLocationStripper.animatedImage(raw) {
            let mime = animated.type.preferredMIMEType ?? "image/gif"
            let ext = animated.type.preferredFilenameExtension ?? "gif"
            return source(
                animated.data, fileName: "image.\(ext)", mimeType: mime, width: animated.width, height: animated.height,
                durationMs: nil, thumbnailFrom: animated.data
            )
        }
        guard let image = ImagePipeline.downsample(data: raw, maxPixel: 1280), let cgImage = image.cgImage,
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        return source(
            jpeg, fileName: "photo.jpg", mimeType: "image/jpeg", width: cgImage.width, height: cgImage.height,
            durationMs: nil, thumbnailFrom: jpeg
        )
    }

    /// Vidéo : lieu QuickTime mis à zéro, dimensions affichées et durée lues de la piste.
    static func video(at url: URL, fileName: String) async -> E2EEAutoMediaSource? {
        guard let raw = try? Data(contentsOf: url, options: .mappedIfSafe), !raw.isEmpty else { return nil }
        let data = MediaLocationStripper.strippedMovie(raw)
        let asset = AVURLAsset(url: url)
        var width: Int?, height: Int?, durationMs: Int64?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let loaded = try? await track.load(.naturalSize, .preferredTransform) {
            let shown = loaded.0.applying(loaded.1)
            width = Int(abs(shown.width).rounded())
            height = Int(abs(shown.height).rounded())
        }
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            durationMs = Int64((duration.seconds * 1_000).rounded())
        }
        var thumbnail: E2EEAutoMediaSource.Thumbnail?
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailSide, height: thumbnailSide)
        if let frame = try? await generator.image(at: .zero).image {
            thumbnail = jpegThumbnail(frame)
        }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType?.lowercased() ?? "video/quicktime"
        guard width.map({ $0 > 0 }) ?? true, height.map({ $0 > 0 }) ?? true else { return nil }
        return E2EEAutoMediaSource(
            data: data, fileName: sanitizedFileName(fileName, fallback: "video.\(ext.isEmpty ? "mov" : ext)"),
            mimeType: mime, width: width, height: height, durationMs: durationMs, thumbnail: thumbnail
        )
    }

    /// Fichier choisi hors photothèque : une image ou une vidéo y perd aussi son lieu (§7.7).
    static func file(_ raw: Data, fileName: String) -> E2EEAutoMediaSource {
        let ext = (fileName as NSString).pathExtension
        let type = UTType(filenameExtension: ext)
        let mime = type?.preferredMIMEType?.lowercased() ?? "application/octet-stream"
        let isImage = type?.conforms(to: .image) == true, isMovie = type?.conforms(to: .movie) == true
        let data = isMovie ? MediaLocationStripper.strippedMovie(raw) : isImage ? MediaLocationStripper.strippedImage(raw) : raw
        var width: Int?, height: Int?
        if isImage, let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0, w <= 100_000, h <= 100_000 {
            let rotated = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            (width, height) = rotated ? (h, w) : (w, h)
        }
        let thumbnail = isImage && data.count > Int(E2EEAutoContentR17.maxThumbnailBytes)
            ? ImagePipeline.downsample(data: data, maxPixel: thumbnailSide)?.cgImage.flatMap(jpegThumbnail) : nil
        return E2EEAutoMediaSource(
            data: data, fileName: sanitizedFileName(fileName, fallback: "fichier"), mimeType: mime,
            width: width, height: height, durationMs: nil, thumbnail: thumbnail
        )
    }

    private static func source(
        _ data: Data, fileName: String, mimeType: String, width: Int, height: Int, durationMs: Int64?, thumbnailFrom: Data
    ) -> E2EEAutoMediaSource {
        // Miniature recommandée au-delà de 256 Kio (§7.7) : la case se remplit avant la pièce.
        let thumbnail = data.count > Int(E2EEAutoContentR17.maxThumbnailBytes)
            ? ImagePipeline.downsample(data: thumbnailFrom, maxPixel: thumbnailSide)?.cgImage.flatMap(jpegThumbnail) : nil
        return E2EEAutoMediaSource(
            data: data, fileName: fileName, mimeType: mimeType, width: width, height: height,
            durationMs: durationMs, thumbnail: thumbnail
        )
    }

    /// JPEG sans métadonnée, sous 256 Kio, qualité baissée au besoin.
    static func jpegThumbnail(_ image: CGImage) -> E2EEAutoMediaSource.Thumbnail? {
        let side = max(image.width, image.height)
        guard side > 0, side <= E2EEAutoContentR17.maxPreviewSide else { return nil }
        let uiImage = UIImage(cgImage: image)
        for quality in [0.7, 0.5, 0.3] as [CGFloat] {
            if let data = uiImage.jpegData(compressionQuality: quality), data.count <= Int(E2EEAutoContentR17.maxThumbnailBytes) {
                return .init(data: data, width: image.width, height: image.height)
            }
        }
        return nil
    }

    /// `fileName` permis par §7.7 : 1 à 512 octets, ni `/`, `\`, caractère de contrôle, ni `.` ou `..`.
    static func sanitizedFileName(_ name: String, fallback: String) -> String {
        var cleaned = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" })
            .trimmingCharacters(in: .whitespaces)
        while cleaned.utf8.count > 512 { cleaned.removeFirst() }
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? fallback : cleaned
    }

    /// Identifiant de blob tiré par l'app avant de chiffrer (A.1) : il entre dans la clé du blob.
    static func newBlobId() -> String {
        var bytes = Data(count: 16)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return "blob_" + bytes.base64URLEncodedNoPadding()
    }
}

extension E2EEAutoContentR17.Manifest {
    init(_ encrypted: E2EEV2BlobEncryptionManifest, fileName: String, mimeType: String, width: Int?, height: Int?, durationMs: Int64?) {
        self.init(
            blobId: encrypted.blobId, mediaKeyB64: encrypted.mediaKeyB64, noncePrefixB64: encrypted.noncePrefixB64,
            plaintextSize: encrypted.plaintextSize, ciphertextSize: encrypted.ciphertextSize,
            plaintextSha256: encrypted.plaintextSha256, ciphertextSha256: encrypted.ciphertextSha256,
            fileName: fileName, mimeType: mimeType, width: width, height: height, durationMs: durationMs
        )
    }
}

/// File durable des pièces jointes chiffrées (§7.4, §7.7) : chaque envoi garde
/// ses sources, ses blobs chiffrés et leurs manifestes jusqu'à l'accusé du
/// message. Un blob envoyé ne repart pas ; un blob expiré ou refusé est
/// rechiffré sous un nouveau `blobId`. Le dossier est exclu des sauvegardes ;
/// la liste, qui porte les clés des blobs, est scellée avec une clé du trousseau
/// propre à l'appareil. La file garde aussi les purges à envoyer après un `DELETE`.
actor E2EEAutoMediaOutbox {
    static let keyService = "fr.signalquest.ios.e2ee-media-outbox"
    /// Au-delà, un envoi n'est plus repris : ses blobs ont expiré depuis longtemps (24 h).
    static let maxAgeMs: Int64 = 7 * 24 * 3_600 * 1_000
    static let maxRestarts = 2

    struct Blob: Codable, Equatable, Sendable {
        var blobId: String
        /// Source en clair, sans lieu, dans le dossier de l'envoi.
        let sourceName: String
        let fileName: String
        let mimeType: String
        let width: Int?
        let height: Int?
        let durationMs: Int64?
        var encrypted: E2EEV2BlobEncryptionManifest?
        var uploaded = false

        var manifest: E2EEAutoContentR17.Manifest? {
            encrypted.map { .init($0, fileName: fileName, mimeType: mimeType, width: width, height: height, durationMs: durationMs) }
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        var file: Blob
        var thumbnail: Blob?
    }

    /// Ce qu'accompagne un vocal (§7.7, `AUDIO`).
    struct Voice: Codable, Equatable, Sendable {
        let waveformB64: String?
        let transcriptionLanguage: String?
        let transcriptionText: String?
    }

    struct Record: Codable, Equatable, Sendable {
        var clientRequestId: String
        let conversationId: String
        let isGroup: Bool
        let participantIds: [String]
        let caption: String?
        let mentions: [String]
        let replyToRef: String?
        let ttlSeconds: Int
        let createdAtMs: Int64
        var entries: [Entry]
        var voice: Voice?
        /// Refus définitif : la bulle reste « Non envoyé », la reprise ne la rejoue plus.
        var failureReason: String?
        /// Premier `clientRequestId`, gardé quand des blobs refusés imposent un nouvel identifiant :
        /// la bulle locale le suit d'un essai à l'autre.
        var localKey: String?

        var key: String { localKey ?? clientRequestId }

        var body: E2EEAutoContentR17.Body? {
            if let voice {
                guard entries.count == 1, let manifest = entries[0].file.manifest else { return nil }
                var transcription: E2EEAutoContentR17.Transcription?
                if let language = voice.transcriptionLanguage, let text = voice.transcriptionText {
                    transcription = .init(language: language, text: text)
                }
                return .audio(caption: caption, voice: manifest, waveformB64: voice.waveformB64, transcription: transcription)
            }
            var attachments: [E2EEAutoContentR17.Attachment] = []
            for entry in entries {
                guard let file = entry.file.manifest else { return nil }
                let thumbnail = entry.thumbnail?.manifest
                if entry.thumbnail != nil, thumbnail == nil { return nil }
                attachments.append(.init(file: file, thumbnail: thumbnail))
            }
            return .media(caption: caption, attachments: attachments)
        }
    }

    private struct File: Codable {
        var version = 1
        var records: [Record] = []
        var purges: [String] = []
    }

    enum Outcome: Equatable, Sendable {
        case sent
        /// Passager : réessayé plus tard, sources gardées.
        case retry
        /// Refus définitif, gardé « Non envoyé » avec sa raison.
        case failed(String)
    }

    typealias Send = @Sendable (E2EEV2MessageSenderV2.Draft, Record) async -> E2EEV2MessageSendResultV2

    private let rootURL: URL
    private let keyStore: TokenStore
    private let fileManager = FileManager.default
    private var running: Set<String> = []

    init(rootURL: URL? = nil, keyStore: TokenStore = KeychainStore(service: keyService)) {
        self.keyStore = keyStore
        self.rootURL = rootURL ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("SignalQuestPrivate", isDirectory: true)
            .appendingPathComponent("e2ee-media-outbox", isDirectory: true)
    }

    static let shared = E2EEAutoMediaOutbox()

    // MARK: Envois

    /// Garde un envoi avant tout réseau : sources écrites, liste scellée.
    func stage(
        _ sources: [E2EEAutoMediaSource], voice: Voice? = nil, caption: String?, mentions: [String] = [], replyToRef: String?,
        ttlSeconds: Int, conversationId: String, isGroup: Bool, participantIds: [String], ownerScopeId: String,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> Record {
        let clientRequestId = UUID().uuidString
        let directory = folder(ownerScopeId).appendingPathComponent(clientRequestId, isDirectory: true)
        try makeDirectory(directory)
        func blob(_ data: Data, name: String, fileName: String, mimeType: String, width: Int?, height: Int?, durationMs: Int64?) throws -> Blob {
            try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
            return Blob(
                blobId: E2EEAutoMediaPreparation.newBlobId(), sourceName: name, fileName: fileName, mimeType: mimeType,
                width: width, height: height, durationMs: durationMs
            )
        }
        var entries: [Entry] = []
        for (index, source) in sources.enumerated() {
            let file = try blob(
                source.data, name: "\(index).source", fileName: source.fileName, mimeType: source.mimeType,
                width: source.width, height: source.height, durationMs: source.durationMs
            )
            let thumbnail = try source.thumbnail.map {
                try blob($0.data, name: "\(index).thumbnail", fileName: "thumbnail.jpg", mimeType: "image/jpeg",
                         width: $0.width, height: $0.height, durationMs: nil)
            }
            entries.append(.init(file: file, thumbnail: thumbnail))
        }
        let record = Record(
            clientRequestId: clientRequestId, conversationId: conversationId, isGroup: isGroup, participantIds: participantIds,
            caption: caption, mentions: caption == nil ? [] : mentions, replyToRef: replyToRef, ttlSeconds: ttlSeconds,
            createdAtMs: nowMs, entries: entries, voice: voice, localKey: clientRequestId
        )
        var file = try read(ownerScopeId)
        file.records.append(record)
        try write(file, ownerScopeId)
        return record
    }

    func records(ownerScopeId: String) -> [Record] {
        (try? read(ownerScopeId).records) ?? []
    }

    /// Source en clair d'un blob de l'envoi (aperçu local de la bulle, copie au cache après l'accusé).
    func sourceURL(_ blob: Blob, clientRequestId: String, ownerScopeId: String) -> URL {
        folder(ownerScopeId).appendingPathComponent(clientRequestId, isDirectory: true).appendingPathComponent(blob.sourceName)
    }

    /// Chiffre, envoie les blobs qui manquent, puis le message, sous le même
    /// `clientRequestId` à chaque essai : jamais deux signatures pour un message.
    func process(
        clientRequestId: String, ownerScopeId: String, client: E2EEAutoBlobClient, cache: E2EEAutoMediaCache? = nil,
        send: Send, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) async -> Outcome {
        guard running.insert(clientRequestId).inserted else { return .retry }
        defer { running.remove(clientRequestId) }
        guard var record = try? read(ownerScopeId).records.first(where: { $0.clientRequestId == clientRequestId || $0.key == clientRequestId }) else {
            return .sent
        }
        if let reason = record.failureReason { return .failed(reason) }
        guard nowMs - record.createdAtMs <= Self.maxAgeMs else {
            remove(record.clientRequestId, ownerScopeId: ownerScopeId)
            return .failed(String(localized: "Cette pièce jointe n’a pas pu être envoyée à temps."))
        }
        let directory = folder(ownerScopeId).appendingPathComponent(record.clientRequestId, isDirectory: true)
        for index in record.entries.indices {
            for isThumbnail in [false, true] {
                guard var blob = isThumbnail ? record.entries[index].thumbnail : record.entries[index].file else { continue }
                var restarts = 0
                while !blob.uploaded {
                    if blob.encrypted == nil {
                        guard let prepared = try? E2EEV2BlobFileEncryptor.encryptFile(
                            sourceURL: directory.appendingPathComponent(blob.sourceName),
                            ciphertextURL: directory.appendingPathComponent(blob.blobId + ".blob"), blobId: blob.blobId
                        ) else { return fail(&record, ownerScopeId, String(localized: "Cette pièce jointe est illisible.")) }
                        blob.encrypted = prepared.manifest
                        save(&record, blob, index: index, thumbnail: isThumbnail, ownerScopeId)
                    }
                    guard let manifest = blob.encrypted else { return .retry }
                    let prepared = E2EEV2PreparedBlob(
                        ciphertextURL: directory.appendingPathComponent(manifest.blobId + ".blob"), manifest: manifest
                    )
                    switch await client.upload(prepared) {
                    case .complete:
                        blob.uploaded = true
                        try? fileManager.removeItem(at: prepared.ciphertextURL)
                    case .restart:
                        restarts += 1
                        guard restarts <= Self.maxRestarts else { return .retry }
                        try? fileManager.removeItem(at: prepared.ciphertextURL)
                        blob.blobId = E2EEAutoMediaPreparation.newBlobId()
                        blob.encrypted = nil
                    case .failure(let failure) where failure.statusCode == 413 || failure.code == "E2EE_BLOB_QUOTA":
                        return fail(&record, ownerScopeId, String(localized: "Ton espace pour les pièces jointes chiffrées est plein."))
                    case .failure(let failure) where failure.kind == .permanent:
                        return fail(&record, ownerScopeId, String(localized: "Cette pièce jointe n’a pas pu être envoyée."))
                    case .failure:
                        save(&record, blob, index: index, thumbnail: isThumbnail, ownerScopeId)
                        return .retry
                    }
                    save(&record, blob, index: index, thumbnail: isThumbnail, ownerScopeId)
                }
            }
        }
        guard let body = record.body else { return fail(&record, ownerScopeId, String(localized: "Cette pièce jointe n’a pas pu être envoyée.")) }
        let draft = E2EEV2MessageSenderV2.Draft(
            body: .r17(body), replyToRef: record.replyToRef, mentions: record.mentions, ttlSeconds: record.ttlSeconds
        )
        switch await send(draft, record) {
        case .sent, .alreadyAccepted:
            // La pièce envoyée s'affiche aussitôt chez son auteur, sans la retélécharger.
            if let cache {
                for entry in record.entries {
                    for blob in [entry.file] + (entry.thumbnail.map { [$0] } ?? []) {
                        await cache.adopt(
                            directory.appendingPathComponent(blob.sourceName), blobId: blob.blobId,
                            fileName: blob.fileName, ownerScopeId: ownerScopeId
                        )
                    }
                }
            }
            remove(record.clientRequestId, ownerScopeId: ownerScopeId)
            return .sent
        case .failure(let failure) where failure.code == "E2EE_BLOB_INVALID":
            // Blob expiré ou déjà cité : tout repart sous de nouveaux blobs et un nouvel identifiant.
            for index in record.entries.indices {
                record.entries[index].file = reset(record.entries[index].file, directory)
                record.entries[index].thumbnail = record.entries[index].thumbnail.map { reset($0, directory) }
            }
            let previous = record.clientRequestId
            record.clientRequestId = UUID().uuidString
            try? fileManager.moveItem(at: directory, to: folder(ownerScopeId).appendingPathComponent(record.clientRequestId))
            replace(previous, with: record, ownerScopeId)
            return .retry
        case .failure(let failure) where MessageRequestLimitError.isPending(failure):
            return fail(&record, ownerScopeId, String(localized: "Ta demande de message n’a pas encore été acceptée."))
        case .failure(let failure) where failure.kind == .permanent:
            return fail(&record, ownerScopeId, String(localized: "Cette pièce jointe n’a pas pu être envoyée."))
        default:
            return .retry
        }
    }

    /// Reprend tout ce qui attend, dans l'ordre d'arrivée.
    func retryAll(ownerScopeId: String, client: E2EEAutoBlobClient, cache: E2EEAutoMediaCache?, send: Send) async {
        for record in records(ownerScopeId: ownerScopeId) where record.failureReason == nil {
            _ = await process(clientRequestId: record.clientRequestId, ownerScopeId: ownerScopeId, client: client, cache: cache, send: send)
        }
    }

    /// Abandonne un envoi (par son identifiant ou sa clé locale) : sources et blobs locaux partent avec lui.
    func remove(_ clientRequestId: String, ownerScopeId: String) {
        guard var file = try? read(ownerScopeId) else { return }
        let gone = file.records.filter { $0.clientRequestId == clientRequestId || $0.key == clientRequestId }
        file.records.removeAll { $0.clientRequestId == clientRequestId || $0.key == clientRequestId }
        try? write(file, ownerScopeId)
        for record in gone {
            try? fileManager.removeItem(at: folder(ownerScopeId).appendingPathComponent(record.clientRequestId, isDirectory: true))
        }
    }

    private func reset(_ blob: Blob, _ directory: URL) -> Blob {
        var blob = blob
        if let encrypted = blob.encrypted { try? fileManager.removeItem(at: directory.appendingPathComponent(encrypted.blobId + ".blob")) }
        blob.blobId = E2EEAutoMediaPreparation.newBlobId()
        blob.encrypted = nil
        blob.uploaded = false
        return blob
    }

    private func save(_ record: inout Record, _ blob: Blob, index: Int, thumbnail: Bool, _ ownerScopeId: String) {
        if thumbnail { record.entries[index].thumbnail = blob } else { record.entries[index].file = blob }
        replace(record.clientRequestId, with: record, ownerScopeId)
    }

    private func fail(_ record: inout Record, _ ownerScopeId: String, _ reason: String) -> Outcome {
        record.failureReason = reason
        replace(record.clientRequestId, with: record, ownerScopeId)
        return .failed(reason)
    }

    private func replace(_ clientRequestId: String, with record: Record, _ ownerScopeId: String) {
        guard var file = try? read(ownerScopeId), let index = file.records.firstIndex(where: { $0.clientRequestId == clientRequestId }) else {
            return
        }
        file.records[index] = record
        try? write(file, ownerScopeId)
    }

    // MARK: Purges (§7.4, point 6)

    func enqueuePurge(envelopeId: String, ownerScopeId: String) {
        guard var file = try? read(ownerScopeId), !file.purges.contains(envelopeId) else { return }
        file.purges.append(envelopeId)
        try? write(file, ownerScopeId)
    }

    func pendingPurges(ownerScopeId: String) -> [String] {
        (try? read(ownerScopeId).purges) ?? []
    }

    /// `200`, `400`, `403` et `404` retirent la purge ; réseau, `429` et `5xx` la gardent.
    func drainPurges(ownerScopeId: String, client: E2EEAutoBlobClient) async {
        for envelopeId in pendingPurges(ownerScopeId: ownerScopeId) {
            switch await client.purge(envelopeId: envelopeId) {
            case .purged, .dropped:
                guard var file = try? read(ownerScopeId) else { return }
                file.purges.removeAll { $0 == envelopeId }
                try? write(file, ownerScopeId)
            case .retry:
                return
            }
        }
    }

    // MARK: Fichiers

    func purge(ownerScopeId: String) throws {
        let directory = folder(ownerScopeId)
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
        try keyStore.remove(Self.digest(ownerScopeId))
    }

    private func folder(_ ownerScopeId: String) -> URL {
        rootURL.appendingPathComponent(Self.digest(ownerScopeId), isDirectory: true)
    }

    private func makeDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = rootURL
        try? root.setResourceValues(values)
    }

    private func read(_ ownerScopeId: String) throws -> File {
        let url = folder(ownerScopeId).appendingPathComponent("outbox.sealed")
        guard fileManager.fileExists(atPath: url.path) else { return File() }
        guard let key = try sealingKey(ownerScopeId, create: false), let box = try? AES.GCM.SealedBox(combined: Data(contentsOf: url)),
              let clear = try? AES.GCM.open(box, using: key, authenticating: Data(ownerScopeId.utf8)),
              let file = try? JSONDecoder().decode(File.self, from: clear), file.version == 1 else {
            throw E2EEV2ConversationStateStore.Failure.invalidRecord
        }
        return file
    }

    private func write(_ file: File, _ ownerScopeId: String) throws {
        try makeDirectory(folder(ownerScopeId))
        guard let key = try sealingKey(ownerScopeId, create: true),
              let combined = try AES.GCM.seal(JSONEncoder().encode(file), using: key, authenticating: Data(ownerScopeId.utf8)).combined else {
            throw E2EEV2ConversationStateStore.Failure.invalidRecord
        }
        try combined.write(to: folder(ownerScopeId).appendingPathComponent("outbox.sealed"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func sealingKey(_ ownerScopeId: String, create: Bool) throws -> SymmetricKey? {
        let name = Self.digest(ownerScopeId)
        if let stored = try keyStore.string(for: name), let data = Data(base64Encoded: stored), data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        try keyStore.set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: name, accessibility: .afterFirstUnlock)
        return key
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Pièces jointes chiffrées déchiffrées sur l'appareil, par `blobId` : dans les
/// caches (jamais sauvegardés), protégées tant que l'appareil est verrouillé,
/// effacées avec la session. Une pièce n'est téléchargée qu'une fois à la fois.
actor E2EEAutoMediaCache {
    enum Result: Equatable, Sendable {
        case file(URL)
        /// « Pièce jointe supprimée » (§7.4, `410 E2EE_BLOB_DELETED`).
        case deleted
        case unavailable
    }

    static let shared = E2EEAutoMediaCache()

    private let rootURL: URL
    private let fileManager = FileManager.default
    private var inFlight: [String: Task<Result, Never>] = [:]
    private var deleted: Set<String> = []

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? Self.defaultRoot
    }

    private static var defaultRoot: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("SignalQuestPrivate", isDirectory: true)
            .appendingPathComponent("e2ee-media", isDirectory: true)
    }

    /// Le fichier déchiffré, téléchargé au besoin et vérifié contre son manifeste.
    func file(for manifest: E2EEAutoContentR17.Manifest, ownerScopeId: String, client: E2EEAutoBlobClient) async -> Result {
        let destination = url(blobId: manifest.blobId, fileName: manifest.fileName, ownerScopeId: ownerScopeId)
        if fileManager.fileExists(atPath: destination.path) { return .file(destination) }
        if deleted.contains(manifest.blobId) { return .deleted }
        if let task = inFlight[manifest.blobId] { return await task.value }
        let task = Task<Result, Never> {
            switch await client.download(manifest, to: destination) {
            case .done: return .file(destination)
            case .deleted: return .deleted
            case .notFound, .invalid, .failure: return .unavailable
            }
        }
        inFlight[manifest.blobId] = task
        let result = await task.value
        inFlight[manifest.blobId] = nil
        if result == .deleted { deleted.insert(manifest.blobId) }
        return result
    }

    /// Ce qui est déjà déchiffré, sans réseau.
    func cached(blobId: String, fileName: String, ownerScopeId: String) -> URL? {
        let destination = url(blobId: blobId, fileName: fileName, ownerScopeId: ownerScopeId)
        return fileManager.fileExists(atPath: destination.path) ? destination : nil
    }

    /// La source d'une pièce que cet appareil vient d'envoyer.
    func adopt(_ source: URL, blobId: String, fileName: String, ownerScopeId: String) {
        let destination = url(blobId: blobId, fileName: fileName, ownerScopeId: ownerScopeId)
        try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: destination)
        try? fileManager.copyItem(at: source, to: destination)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
    }

    private func url(blobId: String, fileName: String, ownerScopeId: String) -> URL {
        rootURL.appendingPathComponent(Self.digest(ownerScopeId), isDirectory: true)
            .appendingPathComponent(Self.digest(blobId), isDirectory: true)
            .appendingPathComponent(E2EEAutoMediaPreparation.sanitizedFileName(fileName, fallback: "fichier"))
    }

    nonisolated static func purge(ownerScopeId: String) {
        try? FileManager.default.removeItem(at: defaultRoot.appendingPathComponent(digest(ownerScopeId), isDirectory: true))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
