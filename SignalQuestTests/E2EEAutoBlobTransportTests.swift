import AVFoundation
import CryptoKit
import UIKit
import XCTest
@testable import SignalQuest

/// Transport des blobs (E2EE-AUTO §7.4, révision 16) contre le vecteur
/// `blob-transport-v1`, puis contre un serveur simulé qui suit le contrat :
/// création rejouable, parts, fin d'envoi, lecture par plages, purge.
final class E2EEAutoBlobTransportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("blob-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func vector() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto/blob-transport-v1.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testCreateRequestsMatchTheVector() throws {
        let create = try XCTUnwrap(vector()["createRequest"] as? [String: Any])
        let valid = try XCTUnwrap(create["valid"] as? [[String: Any]])
        XCTAssertEqual(valid.count, 6)
        for item in valid {
            let name = try XCTUnwrap(item["name"] as? String)
            let body = try XCTUnwrap(item["body"] as? [String: Any])
            XCTAssertTrue(E2EEAutoBlobTransport.isValidCreate(body), name)
            let size = try XCTUnwrap(Int64(body["ciphertextSize"] as? String ?? ""))
            let partSize = try XCTUnwrap(Int64(body["partSize"] as? String ?? ""))
            let sizes = try XCTUnwrap(E2EEAutoBlobTransport.partSizes(ciphertextSize: size, partSize: partSize), name)
            XCTAssertEqual(sizes.map(String.init), item["partSizes"] as? [String], name)
            XCTAssertEqual(String(sizes.count), item["partCount"] as? String, name)
            // Le corps écrit par l'app est celui du vecteur, clé pour clé.
            let written = try XCTUnwrap(E2EEAutoBlobTransport.createBody(
                blobId: body["blobId"] as? String ?? "", ciphertextSha256: body["ciphertextSha256"] as? String ?? "",
                ciphertextSize: size, partSize: partSize
            ))
            let reread = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: String])
            XCTAssertEqual(reread, body as? [String: String], name)
        }
        let negative = try XCTUnwrap(create["negative"] as? [[String: Any]])
        XCTAssertEqual(negative.count, 12)
        for item in negative {
            XCTAssertFalse(E2EEAutoBlobTransport.isValidCreate(try XCTUnwrap(item["body"] as? [String: Any])), item["name"] as? String ?? "")
        }
    }

    func testDownloadRangesMatchTheVector() throws {
        let ranges = try XCTUnwrap(vector()["downloadRange"] as? [[String: String]])
        XCTAssertEqual(ranges.count, 8)
        for item in ranges {
            XCTAssertEqual(
                E2EEAutoBlobTransport.isValidRange(
                    ciphertextSize: item["ciphertextSize"] ?? "", offset: item["offset"] ?? "", length: item["length"] ?? ""
                ),
                item["expected"] == "OK", item["name"] ?? ""
            )
        }
    }

    func testContentMatchFollowsRuleA() throws {
        let cases = try XCTUnwrap(vector()["contentMatch"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 9)
        for item in cases {
            let result = E2EEAutoBlobTransport.contentMatch(
                kind: item["kind"] as? String ?? "", manifestBlobIds: item["manifestBlobIds"] as? [String] ?? [],
                encryptedBlobIds: item["encryptedBlobIds"] as? [String] ?? []
            )
            let expected: E2EEAutoBlobTransport.ContentMatch = switch item["expected"] as? String {
            case "OK": .ok
            case "UNREADABLE_IMPORT": .unreadableImport
            default: .unreadable
            }
            XCTAssertEqual(result, expected, item["name"] as? String ?? "")
        }
    }

    // MARK: Serveur simulé

    private func encrypted(bytes: Int, blobId: String = E2EEAutoMediaPreparation.newBlobId()) throws -> (E2EEV2PreparedBlob, Data) {
        var clear = Data(count: bytes)
        _ = clear.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        let source = directory.appendingPathComponent("\(blobId).clear")
        try clear.write(to: source)
        let prepared = try E2EEV2BlobFileEncryptor.encryptFile(
            sourceURL: source, ciphertextURL: directory.appendingPathComponent("\(blobId).blob"), blobId: blobId
        )
        return (prepared, clear)
    }

    private func manifest(_ prepared: E2EEV2PreparedBlob) -> E2EEAutoContentR17.Manifest {
        .init(prepared.manifest, fileName: "photo.jpg", mimeType: "image/jpeg", width: 10, height: 10, durationMs: nil)
    }

    func testUploadThenDownloadRoundTripsInTwoParts() async throws {
        let server = FakeBlobServer()
        let client = E2EEAutoBlobClient(requests: server.requests, workDirectory: directory)
        let (prepared, clear) = try encrypted(bytes: 6_000_000)
        let outcome = await client.upload(prepared)
        XCTAssertEqual(outcome, .complete)
        let calls = await server.calls
        XCTAssertEqual(calls, ["create", "part 1", "part 2", "complete"])
        // Rejouer l'envoi entier rend le même blob, sans erreur (création et parts rejouées).
        let replay = await client.upload(prepared)
        XCTAssertEqual(replay, .complete)
        let destination = directory.appendingPathComponent("out/photo.jpg")
        let downloaded = await client.download(manifest(prepared), to: destination)
        XCTAssertEqual(downloaded, .done)
        XCTAssertEqual(try Data(contentsOf: destination), clear)
        let ranges = await server.ranges
        XCTAssertEqual(ranges.map(\.length), [Int(prepared.manifest.ciphertextSize)])
    }

    func testLargeBlobIsReadInRangesOfEightMebibytes() async throws {
        let server = FakeBlobServer()
        let client = E2EEAutoBlobClient(requests: server.requests, workDirectory: directory)
        let (prepared, clear) = try encrypted(bytes: 9_000_000)
        let value1 = await client.upload(prepared)
        XCTAssertEqual(value1, .complete)
        let destination = directory.appendingPathComponent("out/video.mov")
        let value2 = await client.download(manifest(prepared), to: destination)
        XCTAssertEqual(value2, .done)
        XCTAssertEqual(try Data(contentsOf: destination), clear)
        let ranges = await server.ranges
        XCTAssertEqual(ranges.map(\.offset), [0, 8_388_608])
        XCTAssertTrue(ranges.allSatisfy { $0.length <= 8_388_608 })
    }

    func testMissingPartsAreSentAgainOnce() async throws {
        let server = FakeBlobServer()
        await server.setLosesPart(2)
        let client = E2EEAutoBlobClient(requests: server.requests, workDirectory: directory)
        let (prepared, _) = try encrypted(bytes: 6_000_000)
        let value3 = await client.upload(prepared)
        XCTAssertEqual(value3, .complete)
        let calls = await server.calls
        XCTAssertEqual(calls, ["create", "part 1", "part 2", "complete", "part 2", "complete"])
    }

    func testExpiredOrTakenBlobRestarts() async throws {
        let server = FakeBlobServer()
        let client = E2EEAutoBlobClient(requests: server.requests, workDirectory: directory)
        let (prepared, _) = try encrypted(bytes: 1_000)
        await server.setExpired(prepared.manifest.blobId)
        let value4 = await client.upload(prepared)
        XCTAssertEqual(value4, .restart)
        let (other, _) = try encrypted(bytes: 1_000)
        await server.takeId(other.manifest.blobId)
        let value5 = await client.upload(other)
        XCTAssertEqual(value5, .restart)
    }

    func testDeletedTamperedAndUnknownBlobs() async throws {
        let server = FakeBlobServer()
        let client = E2EEAutoBlobClient(requests: server.requests, workDirectory: directory)
        let (prepared, _) = try encrypted(bytes: 300_000)
        let value6 = await client.upload(prepared)
        XCTAssertEqual(value6, .complete)
        await server.tamper(prepared.manifest.blobId)
        let destination = directory.appendingPathComponent("out/x.jpg")
        let value7 = await client.download(manifest(prepared), to: destination)
        XCTAssertEqual(value7, .invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await server.purgeAll()
        let value8 = await client.download(manifest(prepared), to: destination)
        XCTAssertEqual(value8, .deleted)
        let (unknown, _) = try encrypted(bytes: 10)
        let value9 = await client.download(manifest(unknown), to: destination)
        XCTAssertEqual(value9, .notFound)
    }

    func testPurgeKeepsOnlyRetryableFailures() async {
        let server = FakeBlobServer()
        let client = E2EEAutoBlobClient(requests: server.requests, workDirectory: directory)
        let envelope = "env_0123456789abcdef"
        await server.setPurgeStatus(200)
        let value10 = await client.purge(envelopeId: envelope)
        XCTAssertEqual(value10, .purged)
        for status in [400, 403, 404] {
            await server.setPurgeStatus(status)
            let value11 = await client.purge(envelopeId: envelope)
            XCTAssertEqual(value11, .dropped)
        }
        for status in [429, 500, 503] {
            await server.setPurgeStatus(status)
            let value12 = await client.purge(envelopeId: envelope)
            XCTAssertEqual(value12, .retry)
        }
    }

    // MARK: File durable

    func testOutboxSendsBlobsThenTheMessageOnce() async throws {
        let server = FakeBlobServer()
        let client = E2EEAutoBlobClient(requests: server.requests, workDirectory: directory)
        let outbox = E2EEAutoMediaOutbox(rootURL: directory.appendingPathComponent("outbox"), keyStore: InMemoryTokenStore())
        let cache = E2EEAutoMediaCache(rootURL: directory.appendingPathComponent("cache"))
        let owner = "user:outbox-test"
        let photo = Data(repeating: 7, count: 400_000)
        let source = E2EEAutoMediaSource(
            data: photo, fileName: "photo.jpg", mimeType: "image/jpeg", width: 20, height: 10, durationMs: nil,
            thumbnail: .init(data: Data(repeating: 1, count: 2_000), width: 8, height: 4)
        )
        let record = try await outbox.stage(
            [source], caption: "Légende", replyToRef: nil, ttlSeconds: 0, conversationId: "conv_0123456789abcdef",
            isGroup: false, participantIds: ["a", "b"], ownerScopeId: owner
        )
        let sentDrafts = DraftBox()
        // Premier essai : le message ne part pas (réseau) ; les blobs ne repartent pas au second.
        let first = await outbox.process(clientRequestId: record.clientRequestId, ownerScopeId: owner, client: client, cache: cache) { draft, _ in
            await sentDrafts.append(draft)
            return .failure(.init(kind: .retryable, message: "offline"))
        }
        XCTAssertEqual(first, .retry)
        let afterFirst = await server.calls
        let second = await outbox.process(clientRequestId: record.clientRequestId, ownerScopeId: owner, client: client, cache: cache) { draft, _ in
            await sentDrafts.append(draft)
            return .alreadyAccepted(messageRef: String(repeating: "A", count: 43))
        }
        XCTAssertEqual(second, .sent)
        let afterSecond = await server.calls
        XCTAssertEqual(afterSecond, afterFirst, "aucun blob renvoyé")
        let drafts = await sentDrafts.items
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0], drafts[1], "la même charge à chaque essai")
        guard case .r17(.media(let caption, let attachments)) = drafts[0].body else { return XCTFail("MEDIA attendu") }
        XCTAssertEqual(caption, "Légende")
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(drafts[0].body, .r17(.media(caption: caption, attachments: attachments)))
        // La charge se relit (révision 17) : manifeste, miniature, règle (a).
        let payload = try E2EEV2ContentPayloadV2(sentAtMs: 1, counter: 1, replyToRef: nil, mentions: [], body: drafts[0].body).encoded()
        let reread = try E2EEV2ContentPayloadV2.parse(payload)
        guard case .r17(let body) = reread.body else { return XCTFail("relu") }
        XCTAssertEqual(body.blobIds, [attachments[0].file.blobId, try XCTUnwrap(attachments[0].thumbnail).blobId])
        // Chez l'auteur, la pièce est déjà déchiffrée ; la file est vide.
        let cached = await cache.cached(blobId: attachments[0].file.blobId, fileName: "photo.jpg", ownerScopeId: owner)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(cached)), photo)
        let remaining = await outbox.records(ownerScopeId: owner)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testOutboxReencryptsWhenTheServerRefusesTheBlobs() async throws {
        let server = FakeBlobServer()
        let client = E2EEAutoBlobClient(requests: server.requests, workDirectory: directory)
        let outbox = E2EEAutoMediaOutbox(rootURL: directory.appendingPathComponent("outbox"), keyStore: InMemoryTokenStore())
        let owner = "user:outbox-test"
        let record = try await outbox.stage(
            [E2EEAutoMediaSource(data: Data([1, 2, 3]), fileName: "note.txt", mimeType: "text/plain", width: nil, height: nil, durationMs: nil, thumbnail: nil)],
            caption: nil, replyToRef: nil, ttlSeconds: 0, conversationId: "conv_0123456789abcdef", isGroup: false,
            participantIds: [], ownerScopeId: owner
        )
        let refused = await outbox.process(clientRequestId: record.clientRequestId, ownerScopeId: owner, client: client) { _, _ in
            .failure(.init(kind: .permanent, statusCode: 409, code: "E2EE_BLOB_INVALID", message: "expired"))
        }
        XCTAssertEqual(refused, .retry)
        let renewedOptional = await outbox.records(ownerScopeId: owner).first
        let renewed = try XCTUnwrap(renewedOptional)
        XCTAssertNotEqual(renewed.clientRequestId, record.clientRequestId)
        XCTAssertNotEqual(renewed.entries[0].file.blobId, record.entries[0].file.blobId)
        XCTAssertFalse(renewed.entries[0].file.uploaded)
        let sent = await outbox.process(clientRequestId: renewed.clientRequestId, ownerScopeId: owner, client: client) { _, _ in
            .alreadyAccepted(messageRef: String(repeating: "A", count: 43))
        }
        XCTAssertEqual(sent, .sent)
    }

    func testOutboxQueuesPurgesUntilTheServerSettlesThem() async throws {
        let server = FakeBlobServer()
        let client = E2EEAutoBlobClient(requests: server.requests, workDirectory: directory)
        let outbox = E2EEAutoMediaOutbox(rootURL: directory.appendingPathComponent("outbox"), keyStore: InMemoryTokenStore())
        let owner = "user:purge-test"
        await outbox.enqueuePurge(envelopeId: "env_0123456789abcdef", ownerScopeId: owner)
        await server.setPurgeStatus(503)
        await outbox.drainPurges(ownerScopeId: owner, client: client)
        let value13 = await outbox.pendingPurges(ownerScopeId: owner)
        XCTAssertEqual(value13, ["env_0123456789abcdef"])
        await server.setPurgeStatus(404)
        await outbox.drainPurges(ownerScopeId: owner, client: client)
        let value14 = await outbox.pendingPurges(ownerScopeId: owner)
        XCTAssertEqual(value14, [])
    }

    /// §7.8 G : un transfert reprend les manifestes reçus, clés comprises, et cite les mêmes blobs.
    func testForwardReusesTheReceivedManifestsAndBlobs() throws {
        let photo = manifest(try encrypted(bytes: 2_000).0)
        let video = E2EEAutoContentR17.Manifest(
            try encrypted(bytes: 3_000).0.manifest, fileName: "clip.mp4", mimeType: "video/mp4", width: 640, height: 360, durationMs: 4_000
        )
        let poster = manifest(try encrypted(bytes: 500).0)
        let received = E2EEAutoContentR17.Body.media(
            caption: "Antenne", attachments: [.init(file: photo, thumbnail: nil), .init(file: video, thumbnail: poster)]
        )
        var media: [String: E2EEAutoMediaRef] = [:]
        let attachments = E2EEAutoMediaRef.attachments(of: received, into: &media)

        let forwarded = try XCTUnwrap(E2EEAutoMediaRef.forwardBody(of: attachments, caption: "Antenne", media: media))
        XCTAssertEqual(forwarded, received)
        XCTAssertEqual(forwarded.blobIds, [photo.blobId, video.blobId, poster.blobId])
        let payload = E2EEV2ContentPayloadV2(sentAtMs: 1, counter: 1, replyToRef: nil, mentions: [], body: .r17(forwarded))
        XCTAssertEqual(try E2EEV2ContentPayloadV2.parse(payload.encoded()).body, .r17(forwarded))
        XCTAssertEqual(
            E2EEAutoMediaRef.forwardBody(of: attachments, caption: "", media: media),
            .media(caption: nil, attachments: [.init(file: photo, thumbnail: nil), .init(file: video, thumbnail: poster)])
        )

        // Vocal : seul, sans la transcription de l'expéditeur d'origine.
        let voice = E2EEAutoContentR17.Manifest(
            try encrypted(bytes: 800).0.manifest, fileName: "voice.m4a", mimeType: "audio/mp4", width: nil, height: nil, durationMs: 2_000
        )
        let waveform = Data(repeating: 7, count: 64).base64EncodedString()
        var voiceMedia: [String: E2EEAutoMediaRef] = [:]
        let voiceAttachments = E2EEAutoMediaRef.attachments(
            of: .audio(caption: nil, voice: voice, waveformB64: waveform, transcription: .init(language: "fr-FR", text: "salut")),
            into: &voiceMedia
        )
        XCTAssertEqual(
            E2EEAutoMediaRef.forwardBody(of: voiceAttachments, caption: nil, media: voiceMedia),
            .audio(caption: nil, voice: voice, waveformB64: waveform, transcription: nil)
        )

        // Rien sans manifeste connu, ni pour une pièce locale, ni pour un vocal mêlé à d'autres pièces.
        XCTAssertNil(E2EEAutoMediaRef.forwardBody(of: attachments, caption: nil, media: [:]))
        XCTAssertNil(E2EEAutoMediaRef.forwardBody(of: [], caption: nil, media: media))
        media.merge(voiceMedia) { first, _ in first }
        XCTAssertNil(E2EEAutoMediaRef.forwardBody(of: attachments + voiceAttachments, caption: nil, media: media))
        let local = MessageAttachment(
            id: photo.blobId, kind: "IMAGE", url: URL(fileURLWithPath: "/tmp/photo.jpg"), fileName: "photo.jpg",
            contentType: "image/jpeg", size: 2_000, width: 10, height: 10
        )
        XCTAssertNil(E2EEAutoMediaRef.forwardBody(of: [local], caption: nil, media: media))
    }

    func testVectorChecksum() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/e2ee-auto")
        let sums = try String(contentsOf: dir.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        let line = try XCTUnwrap(sums.split(separator: "\n").first { $0.hasSuffix("  blob-transport-v1.json") })
        let data = try Data(contentsOf: dir.appendingPathComponent("blob-transport-v1.json"))
        XCTAssertEqual(String(line.prefix(64)), SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: Vocal (§7.7, AUDIO)

    /// Un vocal AAC de 1,5 s, silencieux puis fort : la forme d'onde doit monter.
    private func recordedVoice() throws -> URL {
        let url = directory.appendingPathComponent("recorded.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate * 1.5)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            let amplitude: Float = Double(index) < format.sampleRate * 0.75 ? 0.02 : 0.8
            channel[index] = amplitude * sin(Float(index) * 2 * .pi * 440 / Float(format.sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    func testVoiceSourceIsAACInMP4WithA64ByteWaveform() throws {
        let prepared = try XCTUnwrap(E2EEAutoVoice.source(at: try recordedVoice()))
        XCTAssertEqual(prepared.source.mimeType, "audio/mp4")
        XCTAssertEqual(prepared.source.fileName, "voice.m4a")
        XCTAssertNil(prepared.source.width)
        let duration = try XCTUnwrap(prepared.source.durationMs)
        XCTAssertEqual(Double(duration), 1_500, accuracy: 80)
        let waveform = try XCTUnwrap(prepared.waveformB64)
        XCTAssertEqual(waveform.count, 88)
        let bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: waveform)))
        XCTAssertEqual(bytes.count, 64)
        XCTAssertLessThan(Int(bytes[10]), 40, "début silencieux")
        XCTAssertGreaterThan(Int(bytes[50]), 200, "fin forte")
        XCTAssertEqual(E2EEAutoVoice.levels(fromWaveformB64: waveform).count, 64)
    }

    func testWaveformAndTranscriptionBounds() {
        XCTAssertNil(E2EEAutoVoice.waveformB64(Array(repeating: 0.5, count: 63)))
        let clamped = E2EEAutoVoice.waveformB64([-1, 2] + Array(repeating: 0, count: 62))
        XCTAssertEqual(Data(base64Encoded: clamped ?? "").map { [UInt8]($0).prefix(2) }, [0, 255])
        XCTAssertEqual(E2EEAutoVoice.levels(fromWaveformB64: "AAAA"), [])
        XCTAssertEqual(E2EEAutoVoiceTranscriber.languageTag(Locale(identifier: "fr_FR")), "fr-FR")
        XCTAssertEqual(E2EEAutoVoiceTranscriber.languageTag(Locale(identifier: "en")), "en")
        XCTAssertNil(E2EEAutoVoiceTranscriber.languageTag(Locale(identifier: "x")))
        let long = String(repeating: "é", count: 40_000)
        let bounded = E2EEAutoVoiceTranscriber.bounded(long)
        XCTAssertLessThanOrEqual(bounded.utf8.count, 65_536)
        XCTAssertEqual(bounded.count, 32_768, "aucun caractère coupé")
        XCTAssertEqual(E2EEAutoVoiceTranscriber.bounded("court"), "court")
    }

    func testOutboxSendsAVoiceWithTheSenderTranscriptionOnlyBeforeItsFirstAttempt() async throws {
        let server = FakeBlobServer()
        let client = E2EEAutoBlobClient(requests: server.requests, workDirectory: directory)
        let outbox = E2EEAutoMediaOutbox(rootURL: directory.appendingPathComponent("outbox"), keyStore: InMemoryTokenStore())
        let cache = E2EEAutoMediaCache(rootURL: directory.appendingPathComponent("cache"))
        let owner = "user:voice-test"
        let prepared = try XCTUnwrap(E2EEAutoVoice.source(at: try recordedVoice()))
        func stage() async throws -> E2EEAutoMediaOutbox.Record {
            try await outbox.stage(
                [prepared.source], voice: .init(waveformB64: prepared.waveformB64, transcriptionLanguage: nil, transcriptionText: nil),
                caption: nil, replyToRef: nil, ttlSeconds: 0, conversationId: "conv_0123456789abcdef",
                isGroup: false, participantIds: ["a", "b"], ownerScopeId: owner
            )
        }
        let spoken = E2EEAutoContentR17.Transcription(language: "fr-FR", text: "On se retrouve à l’antenne.")
        // Transcription jointe avant l'envoi : elle part dans la charge.
        let record = try await stage()
        await outbox.setTranscription(spoken, key: record.key, ownerScopeId: owner)
        let drafts = DraftBox()
        let sent = await outbox.process(clientRequestId: record.clientRequestId, ownerScopeId: owner, client: client, cache: cache) { draft, _ in
            await drafts.append(draft)
            return .alreadyAccepted(messageRef: String(repeating: "A", count: 43))
        }
        XCTAssertEqual(sent, .sent)
        let sentDrafts = await drafts.items
        let first = try XCTUnwrap(sentDrafts.first)
        guard case .r17(.audio(let caption, let voice, let waveform, let transcription)) = first.body else { return XCTFail("AUDIO attendu") }
        XCTAssertNil(caption)
        XCTAssertEqual(voice.mimeType, "audio/mp4")
        XCTAssertEqual(voice.durationMs, prepared.source.durationMs)
        XCTAssertEqual(waveform, prepared.waveformB64)
        XCTAssertEqual(transcription, spoken)
        let payload = try E2EEV2ContentPayloadV2(sentAtMs: 1, counter: 1, replyToRef: nil, mentions: [], body: first.body).encoded()
        XCTAssertEqual(try E2EEV2ContentPayloadV2.parse(payload).body, first.body, "la charge se relit")
        // Un vocal déjà tenté ne change plus : le même clientRequestId porte la même charge.
        let retried = try await stage()
        let failing = DraftBox()
        let firstTry = await outbox.process(clientRequestId: retried.clientRequestId, ownerScopeId: owner, client: client, cache: cache) { draft, _ in
            await failing.append(draft)
            return .failure(.init(kind: .retryable, message: "offline"))
        }
        XCTAssertEqual(firstTry, .retry)
        await outbox.setTranscription(spoken, key: retried.key, ownerScopeId: owner)
        _ = await outbox.process(clientRequestId: retried.clientRequestId, ownerScopeId: owner, client: client, cache: cache) { draft, _ in
            await failing.append(draft)
            return .alreadyAccepted(messageRef: String(repeating: "B", count: 43))
        }
        let attempts = await failing.items
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], attempts[1])
        guard case .r17(.audio(_, _, _, let none)) = attempts[1].body else { return XCTFail("AUDIO attendu") }
        XCTAssertNil(none)
    }

    func testOutboxSendsACardWithItsEncryptedImageAsTheOnlyBlob() async throws {
        let server = FakeBlobServer()
        let client = E2EEAutoBlobClient(requests: server.requests, workDirectory: directory)
        let outbox = E2EEAutoMediaOutbox(rootURL: directory.appendingPathComponent("outbox"), keyStore: InMemoryTokenStore())
        let owner = "user:card-test"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let source = try XCTUnwrap(E2EEAutoPostShare.preview(image))
        let card = E2EEAutoMediaOutbox.Card(
            postId: "cmh1post00000000000000001", authorId: "cmh1user00000000000000001", authorName: "Alice", authorHandle: "alice",
            postedAt: "2026-09-20T08:15:00.000Z", text: "Belle antenne",
            measure: .speedtest(downloadMbps: "842.5", uploadMbps: nil, pingMs: "18", technology: "5G", operator: nil)
        )
        let record = try await outbox.stage(
            [source], card: card, caption: nil, replyToRef: nil, ttlSeconds: 0, conversationId: "conv_0123456789abcdef",
            isGroup: false, participantIds: ["a", "b"], ownerScopeId: owner
        )
        let drafts = DraftBox()
        let sent = await outbox.process(clientRequestId: record.clientRequestId, ownerScopeId: owner, client: client) { draft, _ in
            await drafts.append(draft)
            return .alreadyAccepted(messageRef: String(repeating: "A", count: 43))
        }
        XCTAssertEqual(sent, .sent)
        let sentDrafts = await drafts.items
        let draft = try XCTUnwrap(sentDrafts.first)
        guard case .r17(.card(let post)) = draft.body else { return XCTFail("CARD attendu") }
        let preview = try XCTUnwrap(post.image)
        XCTAssertEqual(preview.mimeType, "image/jpeg")
        XCTAssertEqual(preview.width, source.width)
        XCTAssertEqual(post.measure, card.measure)
        XCTAssertEqual(E2EEAutoContentR17.Body.card(post).blobIds, [preview.blobId], "l'image est la seule pièce citée")
        let payload = try E2EEV2ContentPayloadV2(sentAtMs: 1, counter: 1, replyToRef: nil, mentions: [], body: draft.body).encoded()
        XCTAssertEqual(try E2EEV2ContentPayloadV2.parse(payload).body, draft.body, "la charge se relit")
        let calls = await server.calls
        XCTAssertEqual(calls.filter { $0 == "complete" }.count, 1, "un seul blob envoyé")
    }
}

private actor DraftBox {
    var items: [E2EEV2MessageSenderV2.Draft] = []
    func append(_ draft: E2EEV2MessageSenderV2.Draft) { items.append(draft) }
}

/// Serveur des blobs selon §7.4 : clés exactes, rejeux, parts, fin d'envoi, plages, purge.
private actor FakeBlobServer {
    struct Blob {
        let body: Data
        let size: Int64
        let sha: String
        let partSize: Int64
        var parts: [Int: Data] = [:]
        var assembled: Data?
    }

    private(set) var calls: [String] = []
    private(set) var ranges: [(offset: Int64, length: Int)] = []
    private var blobs: [String: Blob] = [:]
    private var expired: Set<String> = []
    private var taken: Set<String> = []
    private var losesPart: Int?
    private var deleted = false
    private var purgeStatus = 200

    func setLosesPart(_ number: Int) { losesPart = number }
    func setExpired(_ blobId: String) { expired.insert(blobId) }
    func takeId(_ blobId: String) { taken.insert(blobId) }
    func purgeAll() { deleted = true }
    func setPurgeStatus(_ status: Int) { purgeStatus = status }
    func tamper(_ blobId: String) {
        guard var data = blobs[blobId]?.assembled else { return }
        data[data.count / 2] ^= 0x01
        blobs[blobId]?.assembled = data
    }

    nonisolated var requests: E2EEAutoBlobClient.Requests {
        .init(
            post: { path, body in await self.post(path, body) },
            putPart: { path, url in await self.put(path, (try? Data(contentsOf: url)) ?? Data()) },
            getRange: { path, offset, length, total in await self.get(path, offset, length, total) }
        )
    }

    private func ok(_ object: [String: String], status: Int = 200) -> E2EEV2TransportResult<Data> {
        .success(value: try! JSONSerialization.data(withJSONObject: object), statusCode: status, idempotentReplay: false)
    }

    private func error(_ status: Int, _ code: String, details: [String: JSONValue]? = nil) -> E2EEV2TransportResult<Data> {
        .failure(.init(kind: status >= 500 || status == 429 ? .retryable : .permanent, statusCode: status, code: code,
                       message: code, details: details))
    }

    private func post(_ path: String, _ body: Data) -> E2EEV2TransportResult<Data> {
        if path == "/api/e2ee/v2/blobs" {
            calls.append("create")
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  E2EEAutoBlobTransport.isValidCreate(object), let id = object["blobId"] as? String,
                  let size = Int64(object["ciphertextSize"] as? String ?? ""), let partSize = Int64(object["partSize"] as? String ?? "") else {
                return error(400, "E2EE_BLOB_REQUEST_INVALID")
            }
            if taken.contains(id) { return error(409, "E2EE_BLOB_ID_TAKEN") }
            if let known = blobs[id], known.body != body { return error(409, "E2EE_BLOB_ID_TAKEN") }
            if blobs[id] == nil {
                blobs[id] = Blob(body: body, size: size, sha: object["ciphertextSha256"] as! String, partSize: partSize)
            }
            let count = (size + partSize - 1) / partSize
            return ok([
                "blobId": id, "status": blobs[id]?.assembled == nil ? "PENDING" : "COMPLETE", "partSize": String(partSize),
                "partCount": String(count), "uploadExpiresAtMs": "1800000000000",
            ], status: 201)
        }
        if path == "/api/e2ee/v2/blobs/purge" {
            calls.append("purge")
            return purgeStatus == 200 ? ok(["purged": "1", "frozen": "0"]) : error(purgeStatus, "E2EE_PURGE_\(purgeStatus)")
        }
        let id = path.components(separatedBy: "/")[5]
        calls.append("complete")
        guard var blob = blobs[id] else { return error(404, "E2EE_BLOB_NOT_FOUND") }
        if expired.contains(id) { return error(410, "E2EE_BLOB_EXPIRED") }
        let count = Int((blob.size + blob.partSize - 1) / blob.partSize)
        let missing = (1...count).filter { blob.parts[$0] == nil }
        if blob.assembled == nil {
            guard missing.isEmpty else {
                return error(409, "E2EE_BLOB_PARTS_MISSING", details: ["missing": .array(missing.map { .string(String($0)) })])
            }
            let data = (1...count).reduce(into: Data()) { $0.append(blob.parts[$1]!) }
            guard E2EEAutoBlobTransport.sha256Hex(data) == blob.sha, Int64(data.count) == blob.size else {
                return error(409, "E2EE_BLOB_DIGEST_MISMATCH")
            }
            blob.assembled = data
            blobs[id] = blob
        }
        return ok(["blobId": id, "status": "COMPLETE", "ciphertextSize": String(blob.size), "ciphertextSha256": blob.sha])
    }

    private func put(_ path: String, _ data: Data) -> E2EEV2TransportResult<Data> {
        let pieces = path.components(separatedBy: "/")
        let id = pieces[5], number = Int(pieces[7]) ?? 0
        calls.append("part \(number)")
        guard var blob = blobs[id] else { return error(404, "E2EE_BLOB_NOT_FOUND") }
        if expired.contains(id) { return error(410, "E2EE_BLOB_EXPIRED") }
        if blob.assembled != nil { return error(409, "E2EE_BLOB_NOT_PENDING") }
        if let known = blob.parts[number], known != data { return error(409, "E2EE_BLOB_PART_CONFLICT") }
        if losesPart == number {
            losesPart = nil
        } else {
            blob.parts[number] = data
            blobs[id] = blob
        }
        return ok(["blobId": id, "partNumber": String(number), "partSha256": E2EEAutoBlobTransport.sha256Hex(data)])
    }

    private func get(_ path: String, _ offset: Int64, _ length: Int, _ total: Int64) -> E2EEV2TransportResult<Data> {
        let id = path.components(separatedBy: "/")[5]
        ranges.append((offset, length))
        guard let data = blobs[id]?.assembled else { return error(404, "E2EE_BLOB_NOT_FOUND") }
        if deleted { return error(410, "E2EE_BLOB_DELETED") }
        guard E2EEAutoBlobTransport.isValidRange(ciphertextSize: String(data.count), offset: String(offset), length: String(length)) else {
            return error(416, "E2EE_BLOB_RANGE_INVALID")
        }
        return .success(value: data.subdata(in: Int(offset)..<Int(offset) + length), statusCode: 200, idempotentReplay: false)
    }
}
