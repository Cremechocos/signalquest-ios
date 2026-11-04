import Foundation

/// Contrat E2EE-AUTO, révision 17 (§7.7) : natures `MEDIA`, `AUDIO`, `POLL`,
/// `POLL_VOTE`, `POLL_CLOSE` et carte de publication (`CARD` `POST`) de la charge
/// `content-payload-v2`. Le serveur ne lit jamais ces charges : c'est la lecture
/// des apps, fixée par le vecteur `content-r17-v1` (lecture de référence
/// `packages/core/e2ee-auto-content-r17.ts`), avec la liste des blobs cités
/// (règle (a), §7.4) et le décompte d'un sondage.
///
/// Longueurs en octets UTF-8, entiers en chaînes décimales canoniques, objets à
/// clés exactes, JSON canonique.
enum E2EEAutoContentR17 {
    static let kinds: Set<String> = ["MEDIA", "AUDIO", "POLL", "POLL_VOTE", "POLL_CLOSE", "CARD"]
    static let maxFileBytes: Int64 = 100 * 1_024 * 1_024
    static let maxCiphertextBytes: Int64 = 128 * 1_024 * 1_024
    static let maxBlobs = 20
    static let maxCaptionBytes = 16_384
    static let maxThumbnailBytes: Int64 = 262_144
    static let maxPostImageBytes: Int64 = 524_288
    static let maxPreviewSide = 1_280
    static let maxDurationMs: Int64 = 86_400_000
    static let pollOptions = 2...20
    static let voiceMimeType = "audio/mp4"
    static let previewMimeTypes: Set<String> = ["image/jpeg", "image/webp"]
    /// Affichés dans le fil ; tout autre `mimeType` est un fichier à enregistrer.
    static let inlineImageTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif", "image/heic", "image/heif"]
    static let inlineVideoTypes: Set<String> = ["video/mp4", "video/quicktime"]

    // MARK: - Modèle

    /// Manifeste A.5 d'un blob cité par la charge.
    struct Manifest: Equatable, Sendable {
        let blobId: String
        let mediaKeyB64: String
        let noncePrefixB64: String
        let plaintextSize: Int64
        let ciphertextSize: Int64
        let plaintextSha256: String
        let ciphertextSha256: String
        let fileName: String
        let mimeType: String
        let width: Int?
        let height: Int?
        let durationMs: Int64?

        var json: E2EEV2JSON {
            func optional(_ value: String?) -> E2EEV2JSON { value.map(E2EEV2JSON.string) ?? .null }
            return .object([
                "algorithm": .string(E2EEV2BlobCrypto.algorithm),
                "blobId": .string(blobId),
                "ciphertextSha256": .string(ciphertextSha256),
                "ciphertextSize": .string(String(ciphertextSize)),
                "cryptoChunkSize": .string(String(E2EEV2BlobCrypto.cryptoChunkBytes)),
                "durationMs": optional(durationMs.map { String($0) }),
                "fileName": .string(fileName),
                "height": optional(height.map { String($0) }),
                "mediaKeyB64": .string(mediaKeyB64),
                "mimeType": .string(mimeType),
                "noncePrefixB64": .string(noncePrefixB64),
                "plaintextSha256": .string(plaintextSha256),
                "plaintextSize": .string(String(plaintextSize)),
                "width": optional(width.map { String($0) }),
            ])
        }
    }

    struct Attachment: Equatable, Sendable {
        let file: Manifest
        let thumbnail: Manifest?
    }

    struct Transcription: Equatable, Sendable {
        let language: String
        let text: String
    }

    struct PollOption: Equatable, Sendable {
        /// 16 octets aléatoires en base64url sans remplissage.
        let id: String
        let label: String
    }

    enum Measure: Equatable, Sendable {
        /// Décimaux à deux chiffres après la virgule au plus, en texte.
        case speedtest(downloadMbps: String, uploadMbps: String?, pingMs: String?, technology: String?, operator: String?)
        case session(points: Int64?, distanceMeters: Int64?, durationSeconds: Int64?, technologies: [String])
        case signal(rsrp: Int?, band: String?, site: String?, operator: String?, technology: String?)
    }

    /// Instantané d'une publication partagée : aucune URL, le lien se reconstruit depuis `postId`.
    struct PostCard: Equatable, Sendable {
        let postId: String
        let authorId: String?
        let authorName: String?
        let authorHandle: String?
        /// ISO 8601 à la milliseconde en `Z`, tel que reçu.
        let postedAt: String
        let text: String?
        let image: Manifest?
        let measure: Measure?

        var postedAtMs: Int64 { E2EEAutoContentR17.isoMs(postedAt) ?? 0 }
    }

    enum Body: Equatable, Sendable {
        case media(caption: String?, attachments: [Attachment])
        case audio(caption: String?, voice: Manifest, waveformB64: String?, transcription: Transcription?)
        /// `closesAt` : ISO 8601 à la milliseconde en `Z`, jugée sur l'heure du serveur.
        case poll(question: String, options: [PollOption], multipleChoice: Bool, closesAt: String?)
        case pollVote(targetRef: String, optionIds: [String])
        case pollClose(targetRef: String)
        case card(PostCard)

        var kind: String {
            switch self {
            case .media: return "MEDIA"
            case .audio: return "AUDIO"
            case .poll: return "POLL"
            case .pollVote: return "POLL_VOTE"
            case .pollClose: return "POLL_CLOSE"
            case .card: return "CARD"
            }
        }

        /// D.16 : un vote ou une clôture n'est ni un aperçu ni un non-lu.
        var delivery: E2EEV2Delivery {
            switch self {
            case .pollVote, .pollClose: return .annotation
            default: return .message
            }
        }

        /// Règle (a) (§7.4) : les `blobId` cités, dans l'ordre du contenu, à comparer à `encryptedBlobIds`.
        var blobIds: [String] {
            switch self {
            case .media(_, let attachments):
                return attachments.flatMap { item in [item.file.blobId] + (item.thumbnail.map { [$0.blobId] } ?? []) }
            case .audio(_, let voice, _, _):
                return [voice.blobId]
            case .card(let card):
                return card.image.map { [$0.blobId] } ?? []
            case .poll, .pollVote, .pollClose:
                return []
            }
        }
    }

    struct Content: Equatable, Sendable {
        let sentAtMs: Int64
        let counter: Int64
        let replyToRef: String?
        let mentions: [String]
        let body: Body
    }

    enum Read: Equatable, Sendable {
        case ok(Content)
        /// Autre version, autre nature, ou `CARD` d'un autre type : « Contenu non pris en charge ».
        case unsupported
        case malformed
    }

    enum Presentation: Equatable, Sendable {
        case image, video, file
    }

    /// Comment le fil affiche une pièce de `MEDIA`, d'après son `mimeType` (jamais exécutée).
    static func presentation(mimeType: String) -> Presentation {
        if inlineImageTypes.contains(mimeType) { return .image }
        if inlineVideoTypes.contains(mimeType) { return .video }
        return .file
    }

    // MARK: - Écriture

    static func json(_ content: Content) -> E2EEV2JSON {
        func optional(_ value: String?) -> E2EEV2JSON { value.map(E2EEV2JSON.string) ?? .null }
        let body: E2EEV2JSON
        switch content.body {
        case .media(let caption, let attachments):
            body = .object([
                "caption": optional(caption),
                "attachments": .array(attachments.map { .object(["file": $0.file.json, "thumbnail": $0.thumbnail?.json ?? .null]) }),
            ])
        case .audio(let caption, let voice, let waveformB64, let transcription):
            body = .object([
                "caption": optional(caption),
                "voice": voice.json,
                "waveformB64": optional(waveformB64),
                "transcription": transcription.map { .object(["language": .string($0.language), "text": .string($0.text)]) } ?? .null,
            ])
        case .poll(let question, let options, let multipleChoice, let closesAt):
            body = .object([
                "question": .string(question),
                "options": .array(options.map { .object(["id": .string($0.id), "label": .string($0.label)]) }),
                "multipleChoice": .bool(multipleChoice),
                "closesAt": optional(closesAt),
            ])
        case .pollVote(let targetRef, let optionIds):
            body = .object(["targetRef": .string(targetRef), "optionIds": .array(optionIds.map(E2EEV2JSON.string))])
        case .pollClose(let targetRef):
            body = .object(["targetRef": .string(targetRef)])
        case .card(let card):
            body = .object([
                "cardType": .string("POST"),
                "cardVersion": .string("1"),
                "payload": .object([
                    "postId": .string(card.postId),
                    "authorId": optional(card.authorId),
                    "authorName": optional(card.authorName),
                    "authorHandle": optional(card.authorHandle),
                    "postedAt": .string(card.postedAt),
                    "text": optional(card.text),
                    "image": card.image?.json ?? .null,
                    "measure": card.measure.map(measureJSON) ?? .null,
                ]),
            ])
        }
        return .object([
            "schema": .string(E2EEV2ContentPayloadV2.schema),
            "version": .string("2"),
            "kind": .string(content.body.kind),
            "sentAtMs": .string(String(content.sentAtMs)),
            "counter": .string(String(content.counter)),
            "replyToRef": optional(content.replyToRef),
            "mentions": .array(content.mentions.map(E2EEV2JSON.string)),
            "body": body,
        ])
    }

    private static func measureJSON(_ measure: Measure) -> E2EEV2JSON {
        func optional(_ value: String?) -> E2EEV2JSON { value.map(E2EEV2JSON.string) ?? .null }
        switch measure {
        case .speedtest(let down, let up, let ping, let technology, let op):
            return .object([
                "type": .string("SPEEDTEST"), "downloadMbps": .string(down), "uploadMbps": optional(up),
                "pingMs": optional(ping), "technology": optional(technology), "operator": optional(op),
            ])
        case .session(let points, let distance, let duration, let technologies):
            return .object([
                "type": .string("SESSION"), "points": optional(points.map { String($0) }),
                "distanceMeters": optional(distance.map { String($0) }),
                "durationSeconds": optional(duration.map { String($0) }),
                "technologies": .array(technologies.map(E2EEV2JSON.string)),
            ])
        case .signal(let rsrp, let band, let site, let op, let technology):
            return .object([
                "type": .string("SIGNAL"), "rsrp": optional(rsrp.map { String($0) }), "band": optional(band),
                "site": optional(site), "operator": optional(op), "technology": optional(technology),
            ])
        }
    }

    /// Octets canoniques de la charge ; une charge hors bornes n'est jamais écrite.
    static func encoded(_ content: Content) throws -> Data {
        let data = E2EEV2CanonicalJSON.encode(json(content))
        guard data.count <= E2EEV2ContentPayloadV2.maxBytes, case .ok(let reread) = read(data), reread == content else {
            throw E2EEV2MessageV2Error.invalidPayload
        }
        return data
    }

    // MARK: - Lecture

    private static let messageRef = #"^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]\z"#
    private static let optionId = #"^[A-Za-z0-9_-]{21}[AQgw]\z"#
    private static let sha256Hex = #"^[0-9a-f]{64}\z"#
    private static let mimePattern = #"^[a-z0-9][a-z0-9!#$&^_.+-]{0,126}/[a-z0-9][a-z0-9!#$&^_.+-]{0,126}\z"#
    private static let languagePattern = #"^[a-z]{2,3}(-[A-Za-z0-9]{2,8}){0,3}\z"#
    private static let isoPattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z"#
    private static let fixed2 = #"^(0|[1-9][0-9]{0,6})(\.[0-9]{1,2})?\z"#
    private static let signedDecimal = #"^(0|-?[1-9][0-9]*)\z"#
    private static let unknownName = #"^[A-Z][A-Z_]{0,31}\z"#
    private static let maxCounter: Int64 = 2_147_483_646

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    static func isMessageRef(_ value: String) -> Bool { matches(value, messageRef) }
    static func isOptionId(_ value: String) -> Bool { matches(value, optionId) }

    /// Lit une charge déchiffrée (sans `fk` ni bourrage) d'une nature de la
    /// révision 17. Les autres natures répondent `unsupported` : elles restent à
    /// `E2EEV2ContentPayloadV2`.
    static func read(_ data: Data) -> Read {
        guard data.count <= E2EEV2ContentPayloadV2.maxBytes,
              let root = (try? E2EEV2CanonicalJSON.parseCanonical(data))?.objectValue,
              root["schema"]?.stringValue == E2EEV2ContentPayloadV2.schema else { return .malformed }
        guard let version = root["version"]?.stringValue else { return .malformed }
        guard version == "2" else { return E2EEV2Canonical.isDecimal(version) ? .unsupported : .malformed }
        guard Set(root.keys) == ["body", "counter", "kind", "mentions", "replyToRef", "schema", "sentAtMs", "version"],
              let sentAtMs = root["sentAtMs"]?.stringValue.flatMap(E2EEV2Canonical.safeInteger),
              let counter = decimal(root["counter"], 1...maxCounter),
              let mentionItems = root["mentions"]?.arrayValue, mentionItems.count <= 100,
              let kind = root["kind"]?.stringValue, let bodyObject = root["body"]?.objectValue else { return .malformed }
        let replyToRef: String?
        switch root["replyToRef"] {
        case .null?: replyToRef = nil
        case .string(let value)? where isMessageRef(value): replyToRef = value
        default: return .malformed
        }
        let mentions = mentionItems.compactMap(\.stringValue)
        guard mentions.count == mentionItems.count, mentions.allSatisfy(E2EEV2Canonical.isOpaque),
              Set(mentions).count == mentions.count else { return .malformed }
        guard kinds.contains(kind) else { return matches(kind, unknownName) ? .unsupported : .malformed }

        let body: Body
        switch kind {
        case "MEDIA": guard let value = readMedia(bodyObject) else { return .malformed }; body = value
        case "AUDIO": guard let value = readAudio(bodyObject) else { return .malformed }; body = value
        case "POLL": guard let value = readPoll(bodyObject) else { return .malformed }; body = value
        case "POLL_VOTE": guard let value = readVote(bodyObject) else { return .malformed }; body = value
        case "POLL_CLOSE":
            guard Set(bodyObject.keys) == ["targetRef"], let ref = bodyObject["targetRef"]?.stringValue,
                  isMessageRef(ref) else { return .malformed }
            body = .pollClose(targetRef: ref)
        default:
            switch readCard(bodyObject) {
            case .card(let value): body = value
            case .unsupported: return .unsupported
            case .malformed: return .malformed
            }
        }
        // Mentions : seulement dans une légende. Réponse : pas pour un vote ni une clôture.
        let caption: String?
        switch body {
        case .media(let value, _), .audio(let value, _, _, _): caption = value
        default: caption = nil
        }
        if !mentions.isEmpty && caption == nil { return .malformed }
        if body.delivery == .annotation && replyToRef != nil { return .malformed }
        return .ok(Content(sentAtMs: sentAtMs, counter: counter, replyToRef: replyToRef, mentions: mentions, body: body))
    }

    private static func decimal(_ value: E2EEV2JSON?, _ range: ClosedRange<Int64>) -> Int64? {
        guard let text = value?.stringValue, text.count <= 16, E2EEV2Canonical.isDecimal(text),
              let number = Int64(text), range.contains(number) else { return nil }
        return number
    }

    /// `.some(nil)` pour `null`, `nil` si refusé.
    private static func nullableDecimal(_ value: E2EEV2JSON?, _ range: ClosedRange<Int64>) -> Int64?? {
        if case .null? = value { return .some(nil) }
        return decimal(value, range).map { .some($0) }
    }

    private static func utf8(_ value: E2EEV2JSON?, _ bytes: ClosedRange<Int>) -> String? {
        guard let text = value?.stringValue, bytes.contains(text.utf8.count) else { return nil }
        return text
    }

    private static func nullableUTF8(_ value: E2EEV2JSON?, max: Int) -> String?? {
        if case .null? = value { return .some(nil) }
        return utf8(value, 1...max).map { .some($0) }
    }

    /// Base64 standard avec remplissage, canonique, d'exactement `count` octets.
    static func isBase64(_ value: String, bytes count: Int) -> Bool {
        guard value.utf8.count == (count + 2) / 3 * 4, let data = Data(base64Encoded: value) else { return false }
        return data.count == count && data.base64EncodedString() == value
    }

    static func isoMs(_ value: String) -> Int64? {
        guard matches(value, isoPattern) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    /// Nom affichable et enregistrable : ni séparateur de chemin ni caractère de contrôle.
    private static func fileName(_ value: E2EEV2JSON?) -> String? {
        guard let name = utf8(value, 1...512), name != ".", name != "..",
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "/" || $0 == "\\" })
        else { return nil }
        return name
    }

    private static func readManifest(_ value: E2EEV2JSON?) -> Manifest? {
        guard let object = value?.objectValue,
              Set(object.keys) == [
                  "algorithm", "blobId", "ciphertextSha256", "ciphertextSize", "cryptoChunkSize", "durationMs", "fileName",
                  "height", "mediaKeyB64", "mimeType", "noncePrefixB64", "plaintextSha256", "plaintextSize", "width",
              ],
              let blobId = object["blobId"]?.stringValue, E2EEV2Canonical.isOpaque(blobId),
              object["algorithm"]?.stringValue == E2EEV2BlobCrypto.algorithm,
              let mediaKey = object["mediaKeyB64"]?.stringValue, isBase64(mediaKey, bytes: 32),
              let noncePrefix = object["noncePrefixB64"]?.stringValue, isBase64(noncePrefix, bytes: 8),
              object["cryptoChunkSize"]?.stringValue == String(E2EEV2BlobCrypto.cryptoChunkBytes),
              let plaintextSize = decimal(object["plaintextSize"], 0...maxFileBytes),
              let ciphertextSize = decimal(object["ciphertextSize"], 1...maxCiphertextBytes),
              let plaintextSha256 = object["plaintextSha256"]?.stringValue, matches(plaintextSha256, sha256Hex),
              let ciphertextSha256 = object["ciphertextSha256"]?.stringValue, matches(ciphertextSha256, sha256Hex),
              let name = fileName(object["fileName"]),
              let mimeType = object["mimeType"]?.stringValue, matches(mimeType, mimePattern),
              let width = nullableDecimal(object["width"], 1...100_000),
              let height = nullableDecimal(object["height"], 1...100_000),
              let durationMs = nullableDecimal(object["durationMs"], 0...maxDurationMs),
              // Largeur et hauteur vont ensemble.
              (width == nil) == (height == nil) else { return nil }
        return Manifest(
            blobId: blobId, mediaKeyB64: mediaKey, noncePrefixB64: noncePrefix, plaintextSize: plaintextSize,
            ciphertextSize: ciphertextSize, plaintextSha256: plaintextSha256, ciphertextSha256: ciphertextSha256,
            fileName: name, mimeType: mimeType, width: width.map { Int($0) }, height: height.map { Int($0) }, durationMs: durationMs
        )
    }

    /// Miniature d'une pièce ou image d'une carte : JPEG ou WebP, dimensions connues, sans durée.
    private static func readPreview(_ value: E2EEV2JSON?, maxBytes: Int64) -> Manifest? {
        guard let manifest = readManifest(value), previewMimeTypes.contains(manifest.mimeType),
              (1...maxBytes).contains(manifest.plaintextSize),
              let width = manifest.width, width <= maxPreviewSide, let height = manifest.height, height <= maxPreviewSide,
              manifest.durationMs == nil else { return nil }
        return manifest
    }

    private static func readMedia(_ body: [String: E2EEV2JSON]) -> Body? {
        guard Set(body.keys) == ["attachments", "caption"], let caption = nullableUTF8(body["caption"], max: maxCaptionBytes),
              let items = body["attachments"]?.arrayValue, (1...maxBlobs).contains(items.count) else { return nil }
        var attachments: [Attachment] = []
        for item in items {
            guard let object = item.objectValue, Set(object.keys) == ["file", "thumbnail"],
                  let file = readManifest(object["file"]) else { return nil }
            var thumbnail: Manifest?
            if object["thumbnail"] != .null {
                guard let preview = readPreview(object["thumbnail"], maxBytes: maxThumbnailBytes) else { return nil }
                thumbnail = preview
            }
            attachments.append(Attachment(file: file, thumbnail: thumbnail))
        }
        let result = Body.media(caption: caption, attachments: attachments)
        let blobIds = result.blobIds
        return blobIds.count <= maxBlobs && Set(blobIds).count == blobIds.count ? result : nil
    }

    private static func readAudio(_ body: [String: E2EEV2JSON]) -> Body? {
        guard Set(body.keys) == ["caption", "transcription", "voice", "waveformB64"],
              let caption = nullableUTF8(body["caption"], max: maxCaptionBytes),
              let voice = readManifest(body["voice"]), voice.mimeType == voiceMimeType, voice.width == nil,
              let duration = voice.durationMs, duration >= 1 else { return nil }
        var waveform: String?
        if body["waveformB64"] != .null {
            guard let value = body["waveformB64"]?.stringValue, isBase64(value, bytes: 64) else { return nil }
            waveform = value
        }
        var transcription: Transcription?
        if body["transcription"] != .null {
            guard let object = body["transcription"]?.objectValue, Set(object.keys) == ["language", "text"],
                  let text = utf8(object["text"], 1...65_536), let language = object["language"]?.stringValue,
                  language.count <= 35, matches(language, languagePattern) else { return nil }
            transcription = Transcription(language: language, text: text)
        }
        return .audio(caption: caption, voice: voice, waveformB64: waveform, transcription: transcription)
    }

    private static func readPoll(_ body: [String: E2EEV2JSON]) -> Body? {
        guard Set(body.keys) == ["closesAt", "multipleChoice", "options", "question"],
              let question = utf8(body["question"], 1...4_096), let multipleChoice = body["multipleChoice"]?.boolValue,
              let items = body["options"]?.arrayValue, pollOptions.contains(items.count) else { return nil }
        var closesAt: String?
        if body["closesAt"] != .null {
            guard let value = body["closesAt"]?.stringValue, isoMs(value) != nil else { return nil }
            closesAt = value
        }
        var options: [PollOption] = []
        for item in items {
            guard let object = item.objectValue, Set(object.keys) == ["id", "label"],
                  let id = object["id"]?.stringValue, isOptionId(id), let label = utf8(object["label"], 1...1_024) else { return nil }
            options.append(PollOption(id: id, label: label))
        }
        guard Set(options.map(\.id)).count == options.count else { return nil }
        return .poll(question: question, options: options, multipleChoice: multipleChoice, closesAt: closesAt)
    }

    private static func readVote(_ body: [String: E2EEV2JSON]) -> Body? {
        guard Set(body.keys) == ["optionIds", "targetRef"], let ref = body["targetRef"]?.stringValue, isMessageRef(ref),
              let items = body["optionIds"]?.arrayValue, items.count <= pollOptions.upperBound else { return nil }
        let ids = items.compactMap(\.stringValue)
        guard ids.count == items.count, ids.allSatisfy(isOptionId), Set(ids).count == ids.count else { return nil }
        return .pollVote(targetRef: ref, optionIds: ids)
    }

    private static func readMeasure(_ value: E2EEV2JSON?) -> Measure?? {
        if case .null? = value { return .some(nil) }
        guard let object = value?.objectValue, let type = object["type"]?.stringValue else { return nil }
        let keys = Set(object.keys)
        switch type {
        case "SPEEDTEST" where keys == ["downloadMbps", "operator", "pingMs", "technology", "type", "uploadMbps"]:
            func fixed(_ raw: E2EEV2JSON?) -> String?? {
                if case .null? = raw { return .some(nil) }
                guard let text = raw?.stringValue, matches(text, fixed2) else { return nil }
                return .some(text)
            }
            guard let downOptional = fixed(object["downloadMbps"]), let down = downOptional,
                  let up = fixed(object["uploadMbps"]), let ping = fixed(object["pingMs"]),
                  let technology = nullableUTF8(object["technology"], max: 32),
                  let op = nullableUTF8(object["operator"], max: 128) else { return nil }
            return .some(.speedtest(downloadMbps: down, uploadMbps: up, pingMs: ping, technology: technology, operator: op))
        case "SESSION" where keys == ["distanceMeters", "durationSeconds", "points", "technologies", "type"]:
            guard let points = nullableDecimal(object["points"], 0...10_000_000),
                  let distance = nullableDecimal(object["distanceMeters"], 0...100_000_000),
                  let duration = nullableDecimal(object["durationSeconds"], 0...31_536_000),
                  let items = object["technologies"]?.arrayValue, items.count <= 10 else { return nil }
            let technologies = items.compactMap { utf8($0, 1...32) }
            guard technologies.count == items.count else { return nil }
            return .some(.session(points: points, distanceMeters: distance, durationSeconds: duration, technologies: technologies))
        case "SIGNAL" where keys == ["band", "operator", "rsrp", "site", "technology", "type"]:
            var rsrp: Int?
            if object["rsrp"] != .null {
                guard let text = object["rsrp"]?.stringValue, matches(text, signedDecimal), let number = Int(text),
                      (-200...0).contains(number) else { return nil }
                rsrp = number
            }
            guard let band = nullableUTF8(object["band"], max: 16), let site = nullableUTF8(object["site"], max: 256),
                  let op = nullableUTF8(object["operator"], max: 128),
                  let technology = nullableUTF8(object["technology"], max: 32) else { return nil }
            return .some(.signal(rsrp: rsrp, band: band, site: site, operator: op, technology: technology))
        default:
            return nil
        }
    }

    private enum CardRead {
        case card(Body)
        case unsupported
        case malformed
    }

    private static func readCard(_ body: [String: E2EEV2JSON]) -> CardRead {
        guard Set(body.keys) == ["cardType", "cardVersion", "payload"], let cardType = body["cardType"]?.stringValue,
              let cardVersion = body["cardVersion"]?.stringValue, E2EEV2Canonical.isDecimal(cardVersion) else { return .malformed }
        guard cardType == "POST", cardVersion == "1" else { return matches(cardType, unknownName) ? .unsupported : .malformed }
        guard let card = body["payload"]?.objectValue,
              Set(card.keys) == ["authorHandle", "authorId", "authorName", "image", "measure", "postId", "postedAt", "text"],
              let postId = card["postId"]?.stringValue, E2EEV2Canonical.isOpaque(postId),
              let authorName = nullableUTF8(card["authorName"], max: 256),
              let authorHandle = nullableUTF8(card["authorHandle"], max: 64),
              let postedAt = card["postedAt"]?.stringValue, isoMs(postedAt) != nil,
              let text = nullableUTF8(card["text"], max: 2_048),
              let measure = readMeasure(card["measure"]) else { return .malformed }
        var authorId: String?
        if card["authorId"] != .null {
            guard let value = card["authorId"]?.stringValue, E2EEV2Canonical.isOpaque(value) else { return .malformed }
            authorId = value
        }
        var image: Manifest?
        if card["image"] != .null {
            guard let preview = readPreview(card["image"], maxBytes: maxPostImageBytes) else { return .malformed }
            image = preview
        }
        return .card(.card(PostCard(
            postId: postId, authorId: authorId, authorName: authorName, authorHandle: authorHandle, postedAt: postedAt,
            text: text, image: image, measure: measure
        )))
    }

    // MARK: - Sondage

    /// Nouveau sondage : `id` de 16 octets aléatoires en base64url sans remplissage,
    /// `closesAt` à la milliseconde en `Z`. `nil` hors des bornes (§7.7).
    static func newPoll(question: String, labels: [String], multipleChoice: Bool, closesAt: Date?) -> Body? {
        guard (1...4_096).contains(question.utf8.count), pollOptions.contains(labels.count),
              labels.allSatisfy({ (1...1_024).contains($0.utf8.count) }) else { return nil }
        var generator = SystemRandomNumberGenerator()
        var ids: [String] = []
        while ids.count < labels.count {
            let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            let id = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            if !ids.contains(id) { ids.append(id) }
        }
        let deadline = closesAt.map { date -> String in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded(.down) / 1_000))
        }
        guard deadline.map({ isoMs($0) != nil }) ?? true else { return nil }
        return .poll(
            question: question, options: zip(ids, labels).map { PollOption(id: $0, label: $1) },
            multipleChoice: multipleChoice, closesAt: deadline
        )
    }

    enum PollEvent: Equatable, Sendable {
        case vote(senderId: String, sequence: Int64, serverTimeMs: Int64, optionIds: [String])
        /// `senderIsAdmin` : selon la chaîne d'appartenance rejouée jusqu'au changement
        /// lié à l'époque de ce message ; `nil` si la chaîne locale n'y est pas encore.
        case close(senderId: String, sequence: Int64, serverTimeMs: Int64, senderIsAdmin: Bool?)

        var sequence: Int64 {
            switch self {
            case .vote(_, let sequence, _, _), .close(_, let sequence, _, _): return sequence
            }
        }
    }

    struct PollTally: Equatable, Sendable {
        let closed: Bool
        /// `sequence` de la clôture retenue.
        let closedBySequence: Int64?
        /// Clôture d'un membre encore indécidable, avant toute clôture retenue.
        let closePending: Bool
        /// Dernier choix retenu par membre ; un membre sans choix n'apparaît pas.
        let votes: [String: [String]]
        /// Nombre de membres par option, dans l'ordre des options du sondage.
        let counts: [(id: String, count: Int)]

        static func == (lhs: PollTally, rhs: PollTally) -> Bool {
            lhs.closed == rhs.closed && lhs.closedBySequence == rhs.closedBySequence && lhs.closePending == rhs.closePending
                && lhs.votes == rhs.votes && lhs.counts.map(\.id) == rhs.counts.map(\.id)
                && lhs.counts.map(\.count) == rhs.counts.map(\.count)
        }
    }

    /// Décompte (§7.7) à partir des votes et clôtures qui visent le sondage, déjà
    /// authentifiés et déchiffrés. Ordre : `sequence` de la conversation, jamais
    /// le compteur d'un appareil. `nowServerMs` : la dernière heure du serveur connue.
    static func tally(
        authorId: String, optionIds: [String], multipleChoice: Bool, closesAtMs: Int64?,
        events: [PollEvent], nowServerMs: Int64
    ) -> PollTally {
        let ordered = events.sorted { $0.sequence < $1.sequence }
        var closedBySequence: Int64?
        var closePending = false
        for case .close(let senderId, let sequence, _, let isAdmin) in ordered {
            if senderId == authorId || isAdmin == true {
                closedBySequence = sequence
                break
            }
            // Indécidable : ni retenue ni rejetée, le sondage reste ouvert jusqu'au rattrapage.
            if isAdmin == nil { closePending = true }
        }
        let known = Set(optionIds)
        var votes: [String: [String]] = [:]
        for case .vote(let senderId, let sequence, let serverTimeMs, let ids) in ordered {
            if let closed = closedBySequence, sequence > closed { continue }
            if let closesAtMs, serverTimeMs >= closesAtMs { continue }
            // Un vote invalide est ignoré en entier : il n'efface pas le précédent.
            guard ids.allSatisfy(known.contains), multipleChoice || ids.count <= 1 else { continue }
            votes[senderId] = ids.isEmpty ? nil : ids
        }
        return PollTally(
            closed: closedBySequence != nil || closesAtMs.map { nowServerMs >= $0 } == true,
            closedBySequence: closedBySequence,
            closePending: closedBySequence == nil && closePending,
            votes: votes,
            counts: optionIds.map { id in (id, votes.values.filter { $0.contains(id) }.count) }
        )
    }
}
