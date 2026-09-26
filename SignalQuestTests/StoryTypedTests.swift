import XCTest
import ImageIO
import UIKit
@testable import SignalQuest

/// Le serveur décide qu'une story est VIDE en inspectant la présence de
/// `attachRadio` / `metadata`. Un `false` explicite au lieu d'une absence fait
/// donc basculer la validation du mauvais côté — un défaut qui ne se voit qu'au
/// 400 renvoyé, sur une story sans texte ni image.
final class StoryTypedTests: XCTestCase {

    private func encoded(attachRadio: Bool?) throws -> [String: Any] {
        let body = CreateStoryRequest(
            text: nil, mediaUrl: nil, thumbnailUrl: nil, mediaKind: nil,
            durationSeconds: 10, visibility: "friends", ttlHours: 24,
            hiddenUserIds: nil, background: nil,
            attachRadio: attachRadio, metadata: nil
        )
        let data = try JSONEncoder().encode(body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Une story « signal » doit envoyer la clé.
    func testAttachRadioIsSentWhenEnabled() throws {
        let json = try encoded(attachRadio: true)
        XCTAssertEqual(json["attachRadio"] as? Bool, true)
    }

    /// Et surtout : la clé doit être ABSENTE quand l'option est désactivée, pas
    /// présente à `false`.
    func testAttachRadioIsOmittedWhenDisabled() throws {
        let json = try encoded(attachRadio: nil)
        XCTAssertNil(json["attachRadio"], "Un `false` explicite fausserait la validation serveur")
    }

    /// Les durées de vie hors bornes doivent être ramenées dans 1…72 : le
    /// serveur répondrait 400 sinon.
    func testTtlIsClampedToTheServerRange() throws {
        for (input, expected) in [(0, 1), (1, 1), (24, 24), (72, 72), (999, 72)] {
            let body = CreateStoryRequest(
                text: "x", mediaUrl: nil, thumbnailUrl: nil, mediaKind: nil,
                durationSeconds: 10, visibility: "friends",
                ttlHours: min(72, max(1, input)),
                hiddenUserIds: nil, background: nil, attachRadio: nil, metadata: nil
            )
            XCTAssertEqual(body.ttlHours, expected, "ttl \(input)")
        }
    }

    func testSocialImageSanitizerRemovesGPSAndCameraMetadata() throws {
        let original = try makeJpegWithSensitiveMetadata()
        let originalProperties = try properties(of: original)
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary])

        let sanitized = try XCTUnwrap(
            SocialImagePrivacy.sanitizedJPEG(from: original, maxSide: 1600, quality: 0.85)
        )
        let sanitizedProperties = try properties(of: sanitized)
        XCTAssertNil(sanitizedProperties[kCGImagePropertyGPSDictionary])
        let tiff = sanitizedProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel])
        XCTAssertEqual((sanitizedProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 8)
        XCTAssertEqual((sanitizedProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 12)
    }

    func testSocialImageSanitizerFailsClosedForInvalidInput() {
        XCTAssertNil(SocialImagePrivacy.sanitizedJPEG(from: Data("not-an-image".utf8)))
    }

    private func makeJpegWithSensitiveMetadata() throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8), format: format)
        let base = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        }
        let jpeg = try XCTUnwrap(base.jpegData(compressionQuality: 0.95))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)
        )
        let metadata: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "SignalQuest Camera",
                kCGImagePropertyTIFFModel: "Private Pixel",
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 48.85,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.35,
                kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
    }
}

@MainActor
final class StoryReplySubmissionTests: XCTestCase {
    private enum NetworkFailure: Error { case lostResponse }

    @MainActor
    private final class SendGate {
        private var continuation: CheckedContinuation<Void, Error>?

        func wait() async throws {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testFailureKeepsDraftAndRetryUsesTheSameRequestIDUntilAcknowledged() async {
        let submission = StoryReplySubmission()
        submission.draft = "Bonjour"
        var firstRequestID: String?

        let failed = await submission.submit(storyID: "story-1", text: submission.draft) { requestID in
            firstRequestID = requestID
            XCTAssertNil(submission.sentStoryID, "A pending message must never show as sent")
            throw NetworkFailure.lostResponse
        }
        XCTAssertFalse(failed)
        XCTAssertEqual(submission.draft, "Bonjour")
        XCTAssertEqual(submission.failedStoryID, "story-1")
        XCTAssertNil(submission.sentStoryID)
        XCTAssertFalse(submission.isSending)

        let delivered = await submission.submit(storyID: "story-1", text: submission.draft) { requestID in
            XCTAssertEqual(requestID, firstRequestID, "Retry must not create a duplicate message")
        }
        XCTAssertTrue(delivered)
        XCTAssertNil(submission.failedStoryID)
        XCTAssertEqual(submission.sentStoryID, "story-1")
        XCTAssertFalse(submission.isSending)
    }

    func testPendingReplyCannotBeSubmittedTwiceOrConfirmedEarly() async {
        let submission = StoryReplySubmission()
        let gate = SendGate()
        let started = expectation(description: "Network request started")

        let first = Task {
            await submission.submit(storyID: "story-1", text: "👏") { _ in
                started.fulfill()
                try await gate.wait()
            }
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(submission.isSending)
        XCTAssertNil(submission.sentStoryID)

        let duplicate = await submission.submit(storyID: "story-1", text: "👏") { _ in
            XCTFail("A second request must not begin while the first is pending")
        }
        XCTAssertFalse(duplicate)
        gate.finish()
        let delivered = await first.value
        XCTAssertTrue(delivered)
        XCTAssertEqual(submission.sentStoryID, "story-1")
    }

    func testUnencryptedReplyRequiresConsentForTheCurrentStory() {
        var channel = StoryReplyChannelConsent()
        XCTAssertFalse(channel.request(storyID: "story-1", text: "Bonjour", clearDraftOnSuccess: true))
        XCTAssertEqual(channel.pending?.text, "Bonjour")
        XCTAssertNil(channel.confirm(currentStoryID: "story-2"), "Une story suivante ne doit pas recevoir le brouillon précédent")
        XCTAssertNil(channel.pending)

        XCTAssertFalse(channel.request(storyID: "story-1", text: "❤️", clearDraftOnSuccess: false))
        let approved = channel.confirm(currentStoryID: "story-1")
        XCTAssertEqual(approved?.text, "❤️")
        XCTAssertEqual(approved?.clearDraftOnSuccess, false)
        XCTAssertTrue(channel.request(storyID: "story-1", text: "Encore", clearDraftOnSuccess: true))
        XCTAssertFalse(channel.request(storyID: "story-2", text: "Nouvelle", clearDraftOnSuccess: true))
        channel.cancelPending()
        XCTAssertNil(channel.pending)
    }

    func testStoryReplyAcceptsOnlyTheExactUnencryptedDirectConversation() {
        func conversation(ids: [String], encrypted: Bool, group: Bool) -> MessageConversation {
            MessageConversation(
                id: "conversation-1", title: "Fixture", isGroup: group,
                e2eeEnabled: encrypted, groupPhotoUrl: nil, createdAt: nil,
                updatedAt: nil, lastMessageAt: nil, lastReadAt: nil,
                pinnedAt: nil,
                participants: ids.map { id in
                    ConversationParticipant(
                        userId: id, role: "member", joinedAt: nil, lastReadAt: nil,
                        user: MessageUser(id: id, name: id, email: "fixture@example.invalid", avatarUrl: nil),
                        presence: nil
                    )
                },
                lastMessage: nil
            )
        }
        XCTAssertTrue(StoryReplyChannelPolicy.accepts(
            conversation(ids: ["me", "author"], encrypted: false, group: false),
            authorID: "author", currentUserID: "me"
        ))
        XCTAssertFalse(StoryReplyChannelPolicy.accepts(
            conversation(ids: ["me", "author"], encrypted: true, group: false),
            authorID: "author", currentUserID: "me"
        ))
        XCTAssertFalse(StoryReplyChannelPolicy.accepts(
            conversation(ids: ["me", "other"], encrypted: false, group: false),
            authorID: "author", currentUserID: "me"
        ))
        XCTAssertFalse(StoryReplyChannelPolicy.accepts(
            conversation(ids: ["me", "author", "other"], encrypted: false, group: true),
            authorID: "author", currentUserID: "me"
        ))
    }

    func testStoryReplyFetchesCreatedConversationByExactID() async throws {
        defer { MockURLProtocol.requestHandler = nil }
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-story-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(
            config: .test, credentials: credentials,
            session: URLSession(configuration: configuration)
        )
        MockURLProtocol.requestHandler = { request in
            guard request.url?.path == "/api/messages/conversations/old-direct" else {
                throw URLError(.unsupportedURL)
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            let body = #"{"conversation":{"id":"old-direct","isGroup":false,"e2eeEnabled":false,"participants":[{"userId":"me","role":"member","user":{"id":"me","name":"Me"}},{"userId":"author","role":"member","user":{"id":"author","name":"Author"}}]}}"#
            return (response, Data(body.utf8))
        }

        let conversation = try await MessagesService(api: api).conversation(id: "old-direct")
        XCTAssertEqual(conversation.id, "old-direct")
        XCTAssertTrue(StoryReplyChannelPolicy.accepts(
            conversation, authorID: "author", currentUserID: "me"
        ))
    }
}
