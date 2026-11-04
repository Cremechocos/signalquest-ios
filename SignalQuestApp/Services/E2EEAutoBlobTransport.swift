import CryptoKit
import Foundation

/// Transport des blobs chiffrés (E2EE-AUTO §7.4, révision 16) : création, parts,
/// fin d'envoi, lecture par plages et purge, toutes en requêtes signées. Le
/// format des blobs (A.5) ne change pas : `E2EEV2BlobCrypto` chiffre, ce
/// transport range des octets opaques. Règles statiques vérifiées contre le
/// vecteur `blob-transport-v1`.
enum E2EEAutoBlobTransport {
    static let minPartSize: Int64 = 5_242_880
    static let maxPartSize: Int64 = 8_388_608
    static let maxParts = 26
    static let maxCiphertextBytes: Int64 = 134_217_728
    static let maxRangeBytes: Int64 = 8_388_608
    /// Parts de 5 Mio : la plus petite borne, assez pour 26 parts de 128 Mio.
    static let partSize = minPartSize
    static let basePath = "/api/e2ee/v2/blobs"

    private static let hashPattern = #"^[0-9a-f]{64}\z"#

    /// Tailles des parts : toutes de `partSize`, sauf la dernière ; `nil` hors bornes.
    static func partSizes(ciphertextSize: Int64, partSize: Int64) -> [Int64]? {
        guard (1...maxCiphertextBytes).contains(ciphertextSize), (minPartSize...maxPartSize).contains(partSize) else {
            return nil
        }
        let count = Int((ciphertextSize + partSize - 1) / partSize)
        guard (1...maxParts).contains(count) else { return nil }
        return (0..<count).map { index in
            index == count - 1 ? ciphertextSize - partSize * Int64(count - 1) : partSize
        }
    }

    /// Corps de `POST /api/e2ee/v2/blobs`, à clés exactes ; `nil` s'il serait refusé.
    static func createBody(blobId: String, ciphertextSha256: String, ciphertextSize: Int64, partSize: Int64) -> Data? {
        let body = E2EEV2CanonicalJSON.encode(.object([
            "version": .string("1"),
            "blobId": .string(blobId),
            "algorithm": .string(E2EEV2BlobCrypto.algorithm),
            "ciphertextSha256": .string(ciphertextSha256),
            "ciphertextSize": .string(String(ciphertextSize)),
            "partSize": .string(String(partSize)),
        ]))
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], isValidCreate(object) else {
            return nil
        }
        return body
    }

    /// Ce que le serveur accepte à la création (400 `E2EE_BLOB_REQUEST_INVALID` sinon).
    static func isValidCreate(_ object: [String: Any]) -> Bool {
        guard Set(object.keys) == ["version", "blobId", "algorithm", "ciphertextSha256", "ciphertextSize", "partSize"],
              object["version"] as? String == "1",
              let blobId = object["blobId"] as? String, E2EEV2Canonical.isOpaque(blobId),
              object["algorithm"] as? String == E2EEV2BlobCrypto.algorithm,
              let hash = object["ciphertextSha256"] as? String, hash.range(of: hashPattern, options: .regularExpression) != nil,
              let size = (object["ciphertextSize"] as? String).flatMap(E2EEV2Canonical.safeInteger),
              let partSize = (object["partSize"] as? String).flatMap(E2EEV2Canonical.safeInteger) else { return false }
        return partSizes(ciphertextSize: size, partSize: partSize) != nil
    }

    /// `offset` et `length` d'une lecture : décimaux canoniques, `length` de 1 à
    /// 8 Mio, sans dépasser la fin (416 `E2EE_BLOB_RANGE_INVALID` sinon).
    static func isValidRange(ciphertextSize: String, offset: String, length: String) -> Bool {
        guard let size = E2EEV2Canonical.safeInteger(ciphertextSize), let start = E2EEV2Canonical.safeInteger(offset),
              let count = E2EEV2Canonical.safeInteger(length) else { return false }
        return (1...maxRangeBytes).contains(count) && start + count <= size
    }

    enum ContentMatch: Equatable, Sendable {
        case ok
        /// Message illisible.
        case unreadable
        /// « Message importé illisible ».
        case unreadableImport
    }

    /// Règle (a) : les `blobId` des manifestes, dans l'ordre du contenu, égaux à
    /// `encryptedBlobIds` (même longueur, même ordre, sans doublon).
    static func contentMatch(kind: String, manifestBlobIds: [String], encryptedBlobIds: [String]) -> ContentMatch {
        if manifestBlobIds == encryptedBlobIds, Set(manifestBlobIds).count == manifestBlobIds.count { return .ok }
        return kind == "HISTORY_IMPORT" ? .unreadableImport : .unreadable
    }

    // MARK: Réponses, à clés exactes

    struct Created: Equatable, Sendable {
        let partSize: Int64
        let partCount: Int
        let uploadExpiresAtMs: Int64
    }

    static func parseCreated(_ data: Data, blobId: String, partSize: Int64, partCount: Int) -> Created? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["blobId", "status", "partSize", "partCount", "uploadExpiresAtMs"],
              object["blobId"] as? String == blobId,
              ["PENDING", "COMPLETE"].contains(object["status"] as? String ?? ""),
              (object["partSize"] as? String).flatMap(E2EEV2Canonical.safeInteger) == partSize,
              (object["partCount"] as? String).flatMap(E2EEV2Canonical.safeInteger) == Int64(partCount),
              let expires = (object["uploadExpiresAtMs"] as? String).flatMap(E2EEV2Canonical.safeInteger) else { return nil }
        return Created(partSize: partSize, partCount: partCount, uploadExpiresAtMs: expires)
    }

    static func isPartReceipt(_ data: Data, blobId: String, partNumber: Int, partSha256: String) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["blobId", "partNumber", "partSha256"] else { return false }
        return object["blobId"] as? String == blobId && object["partNumber"] as? String == String(partNumber)
            && object["partSha256"] as? String == partSha256
    }

    static func isCompleteReceipt(_ data: Data, blobId: String, ciphertextSize: Int64, ciphertextSha256: String) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["blobId", "status", "ciphertextSize", "ciphertextSha256"] else { return false }
        return object["blobId"] as? String == blobId && object["status"] as? String == "COMPLETE"
            && object["ciphertextSize"] as? String == String(ciphertextSize)
            && object["ciphertextSha256"] as? String == ciphertextSha256
    }

    static func parsePurge(_ data: Data) -> (purged: Int64, frozen: Int64)? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["purged", "frozen"],
              let purged = (object["purged"] as? String).flatMap(E2EEV2Canonical.safeInteger),
              let frozen = (object["frozen"] as? String).flatMap(E2EEV2Canonical.safeInteger) else { return nil }
        return (purged, frozen)
    }

    /// Numéros manquants de `409 E2EE_BLOB_PARTS_MISSING`, décimaux croissants.
    static func missingParts(_ failure: E2EEV2TransportFailure, partCount: Int) -> [Int]? {
        guard case .array(let values)? = failure.details?["missing"] else { return nil }
        let numbers = values.compactMap { value -> Int? in
            guard case .string(let text) = value, let number = E2EEV2Canonical.safeInteger(text),
                  (1...Int64(partCount)).contains(number) else { return nil }
            return Int(number)
        }
        guard numbers.count == values.count, !numbers.isEmpty, numbers == numbers.sorted(), Set(numbers).count == numbers.count else {
            return nil
        }
        return numbers
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Client des routes de blobs, aux requêtes injectables (tests).
final class E2EEAutoBlobClient: @unchecked Sendable {
    struct Requests: Sendable {
        var post: @Sendable (_ path: String, _ body: Data) async -> E2EEV2TransportResult<Data>
        var putPart: @Sendable (_ path: String, _ fileURL: URL) async -> E2EEV2TransportResult<Data>
        /// Octets bruts d'une plage, taille totale vérifiée par l'en-tête `x-sq-e2ee-blob-size`.
        var getRange: @Sendable (_ path: String, _ offset: Int64, _ length: Int, _ totalSize: Int64) async -> E2EEV2TransportResult<Data>
    }

    enum UploadOutcome: Equatable, Sendable {
        case complete
        /// Délai dépassé, condensat refusé ou `blobId` pris : rechiffrer sous un nouveau `blobId`.
        case restart
        case failure(E2EEV2TransportFailure)
    }

    enum DownloadOutcome: Equatable, Sendable {
        case done
        /// `410 E2EE_BLOB_DELETED` : « pièce jointe supprimée ».
        case deleted
        /// `404` : inconnu ou illisible pour cet appareil.
        case notFound
        /// Octets reçus qui ne sont pas ceux du manifeste.
        case invalid
        case failure(E2EEV2TransportFailure)
    }

    enum PurgeOutcome: Equatable, Sendable {
        case purged
        /// `400`, `403` ou `404` : retirée de la file, rien à refaire.
        case dropped
        /// Réseau, `429`, `5xx` : gardée pour plus tard.
        case retry
    }

    private let requests: Requests
    private let fileManager: FileManager
    private let workDirectory: URL

    init(requests: Requests, workDirectory: URL, fileManager: FileManager = .default) {
        self.requests = requests
        self.workDirectory = workDirectory
        self.fileManager = fileManager
    }

    /// Requêtes réelles, signées par l'appareil de la session.
    static func live(transport: E2EEV2APITransport, ownerScopeId: String) -> Requests {
        Requests(
            post: { path, body in
                await transport.postJSON(path: path, body: body, expectedOwnerScopeId: ownerScopeId, capabilitySet: .media)
            },
            putPart: { path, fileURL in
                await transport.putEncryptedFile(path: path, fileURL: fileURL, expectedOwnerScopeId: ownerScopeId)
            },
            getRange: { path, offset, length, total in
                await transport.getEncryptedBlobBytes(
                    path: path, offset: offset, length: length, expectedTotalSize: total, expectedOwnerScopeId: ownerScopeId
                )
            }
        )
    }

    /// Envoie un blob chiffré : création (rejouable à l'octet), parts, fin
    /// d'envoi. Une part déjà reçue se rejoue sans erreur ; un blob déjà
    /// `COMPLETE` passe directement à la fin d'envoi, qui se rejoue aussi.
    func upload(_ blob: E2EEV2PreparedBlob, partSize: Int64 = E2EEAutoBlobTransport.partSize) async -> UploadOutcome {
        let manifest = blob.manifest
        let path = "\(E2EEAutoBlobTransport.basePath)/\(manifest.blobId)"
        guard let sizes = E2EEAutoBlobTransport.partSizes(ciphertextSize: manifest.ciphertextSize, partSize: partSize),
              let body = E2EEAutoBlobTransport.createBody(
                  blobId: manifest.blobId, ciphertextSha256: manifest.ciphertextSha256,
                  ciphertextSize: manifest.ciphertextSize, partSize: partSize
              ) else { return .failure(Self.local("invalid-e2ee-blob-upload")) }
        switch await requests.post(E2EEAutoBlobTransport.basePath, body) {
        case .success(let data, _, _):
            guard E2EEAutoBlobTransport.parseCreated(data, blobId: manifest.blobId, partSize: partSize, partCount: sizes.count) != nil else {
                return .failure(Self.local("invalid-e2ee-blob-created"))
            }
        case .failure(let failure) where failure.code == "E2EE_BLOB_ID_TAKEN":
            return .restart
        case .failure(let failure):
            return .failure(failure)
        }
        var pending = Array(1...sizes.count)
        for round in 0..<2 {
            for number in pending {
                switch await putPart(blob, number: number, sizes: sizes, partSize: partSize, path: path) {
                case .complete: continue
                case .restart: return .restart
                case .failure(let failure) where failure.code == "E2EE_BLOB_NOT_PENDING": break
                case .failure(let failure): return .failure(failure)
                }
            }
            switch await requests.post("\(path)/complete", Data(#"{"version":"1"}"#.utf8)) {
            case .success(let data, _, _):
                return E2EEAutoBlobTransport.isCompleteReceipt(
                    data, blobId: manifest.blobId, ciphertextSize: manifest.ciphertextSize,
                    ciphertextSha256: manifest.ciphertextSha256
                ) ? .complete : .failure(Self.local("invalid-e2ee-blob-complete"))
            case .failure(let failure) where failure.code == "E2EE_BLOB_PARTS_MISSING" && round == 0:
                guard let missing = E2EEAutoBlobTransport.missingParts(failure, partCount: sizes.count) else {
                    return .failure(failure)
                }
                pending = missing
            case .failure(let failure)
                where failure.code == "E2EE_BLOB_DIGEST_MISMATCH" || failure.code == "E2EE_BLOB_EXPIRED":
                return .restart
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return .failure(Self.local("e2ee-blob-parts-missing"))
    }

    private func putPart(
        _ blob: E2EEV2PreparedBlob, number: Int, sizes: [Int64], partSize: Int64, path: String
    ) async -> UploadOutcome {
        let partURL = workDirectory.appendingPathComponent(".\(UUID().uuidString).part")
        defer { try? fileManager.removeItem(at: partURL) }
        let hash: String
        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let handle = try FileHandle(forReadingFrom: blob.ciphertextURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(partSize * Int64(number - 1)))
            guard let bytes = try handle.read(upToCount: Int(sizes[number - 1])), bytes.count == Int(sizes[number - 1]) else {
                return .failure(Self.local("invalid-e2ee-blob-part"))
            }
            hash = E2EEAutoBlobTransport.sha256Hex(bytes)
            try bytes.write(to: partURL, options: .atomic)
        } catch {
            return .failure(Self.local("e2ee-blob-part-unreadable"))
        }
        switch await requests.putPart("\(path)/parts/\(number)", partURL) {
        case .success(let data, _, _):
            return E2EEAutoBlobTransport.isPartReceipt(data, blobId: blob.manifest.blobId, partNumber: number, partSha256: hash)
                ? .complete : .failure(Self.local("invalid-e2ee-blob-part-receipt"))
        case .failure(let failure) where failure.code == "E2EE_BLOB_EXPIRED" || failure.code == "E2EE_BLOB_PART_CONFLICT":
            return .restart
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Lit un blob entier par plages de 8 Mio au plus, vérifie taille et
    /// condensat chiffrés, puis le déchiffre bloc par bloc vers `destination`,
    /// condensat clair vérifié. Rien n'est laissé à `destination` en cas d'échec.
    func download(_ manifest: E2EEAutoContentR17.Manifest, to destination: URL) async -> DownloadOutcome {
        let path = "\(E2EEAutoBlobTransport.basePath)/\(manifest.blobId)/download"
        let ciphertextURL = workDirectory.appendingPathComponent(".\(UUID().uuidString).blob")
        defer { try? fileManager.removeItem(at: ciphertextURL) }
        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            fileManager.createFile(atPath: ciphertextURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: ciphertextURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            var offset: Int64 = 0
            while offset < manifest.ciphertextSize {
                let length = Int(min(E2EEAutoBlobTransport.maxRangeBytes, manifest.ciphertextSize - offset))
                switch await requests.getRange(path, offset, length, manifest.ciphertextSize) {
                case .success(let data, _, _):
                    guard data.count == length else { return .invalid }
                    hasher.update(data: data)
                    try handle.write(contentsOf: data)
                    offset += Int64(length)
                case .failure(let failure) where failure.code == "E2EE_BLOB_DELETED":
                    return .deleted
                case .failure(let failure) where failure.statusCode == 404:
                    return .notFound
                case .failure(let failure) where failure.message == "invalid-e2ee-blob-range-response":
                    return .invalid
                case .failure(let failure):
                    return .failure(failure)
                }
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == manifest.ciphertextSha256 else { return .invalid }
        } catch {
            return .failure(Self.local("e2ee-blob-download-unwritable"))
        }
        do {
            try E2EEAutoBlobFileDecryptor.decrypt(ciphertextURL: ciphertextURL, manifest: manifest, to: destination)
            return .done
        } catch {
            return .invalid
        }
    }

    /// Purge des blobs d'un message de ce compte, après son `DELETE` accepté (§7.4, point 6).
    func purge(envelopeId: String) async -> PurgeOutcome {
        guard E2EEV2Canonical.isOpaque(envelopeId) else { return .dropped }
        let body = E2EEV2CanonicalJSON.encode(.object(["version": .string("1"), "envelopeId": .string(envelopeId)]))
        switch await requests.post("\(E2EEAutoBlobTransport.basePath)/purge", body) {
        case .success(let data, _, _):
            return E2EEAutoBlobTransport.parsePurge(data) != nil ? .purged : .retry
        case .failure(let failure) where [400, 403, 404].contains(failure.statusCode ?? 0):
            return .dropped
        case .failure:
            return .retry
        }
    }

    private static func local(_ message: String) -> E2EEV2TransportFailure {
        .init(kind: .localState, message: message)
    }
}

/// Déchiffrement A.5 d'un fichier de blob complet : bloc par bloc, chaque tag
/// vérifié, puis les deux condensats et les deux tailles du manifeste.
enum E2EEAutoBlobFileDecryptor {
    struct Failure: Error {}

    static func decrypt(ciphertextURL: URL, manifest: E2EEAutoContentR17.Manifest, to destination: URL) throws {
        guard var mediaKey = Data(base64Encoded: manifest.mediaKeyB64), var noncePrefix = Data(base64Encoded: manifest.noncePrefixB64) else {
            throw Failure()
        }
        defer {
            mediaKey.resetBytes(in: 0..<mediaKey.count)
            noncePrefix.resetBytes(in: 0..<noncePrefix.count)
        }
        let fileManager = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: partial.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        var finished = false
        defer { if !finished { try? fileManager.removeItem(at: partial) } }
        let input = try FileHandle(forReadingFrom: ciphertextURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        let chunk = E2EEV2BlobCrypto.cryptoChunkBytes
        let chunkCount = max(1, Int((manifest.plaintextSize + Int64(chunk) - 1) / Int64(chunk)))
        var plaintextHasher = SHA256()
        var read: Int64 = 0
        var written: Int64 = 0
        for index in 0..<chunkCount {
            let final = index == chunkCount - 1
            let clear = final ? Int(manifest.plaintextSize - Int64(index * chunk)) : chunk
            guard let sealed = try input.read(upToCount: clear + E2EEV2BlobCrypto.tagBytes),
                  sealed.count == clear + E2EEV2BlobCrypto.tagBytes else { throw Failure() }
            read += Int64(sealed.count)
            var opened = try E2EEV2BlobCrypto.decryptChunk(
                sealed, blobID: manifest.blobId, mediaKey: mediaKey, noncePrefix: noncePrefix,
                chunkIndex: UInt32(index), finalChunk: final, cleartextBytes: clear
            )
            defer { opened.resetBytes(in: 0..<opened.count) }
            plaintextHasher.update(data: opened)
            try output.write(contentsOf: opened)
            written += Int64(opened.count)
        }
        let trailing = try input.read(upToCount: 1) ?? Data()
        let digest = plaintextHasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard trailing.isEmpty, read == manifest.ciphertextSize, written == manifest.plaintextSize,
              digest == manifest.plaintextSha256 else { throw Failure() }
        try output.close()
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: partial, to: destination)
        finished = true
    }
}
