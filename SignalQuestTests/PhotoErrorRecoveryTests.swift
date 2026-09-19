import XCTest
import SwiftUI
import UIKit
@testable import SignalQuest

@MainActor
final class PhotoErrorRecoveryTests: XCTestCase {
    func testGalleryFailureThenSuccessClearsItsError() async {
        let service = PhotoRecoveryFixture()
        let model = PhotosViewModel(service: service)
        await model.load()
        XCTAssertNotNil(model.errorMessage)
        service.gallery = .success(PhotoListResponse(photos: [.demoList[0]], meta: nil))
        await model.load()
        XCTAssertEqual(model.photos.map(\.id), [Photo.demoList[0].id])
        XCTAssertNil(model.errorMessage)
    }

    func testCommentsFailureKeepsContentAndRetryCanReturnAnAuthoritativeEmpty() async {
        let service = PhotoRecoveryFixture()
        let model = PhotosViewModel(service: service)
        service.commentResult = .success(PhotoComment.demo)
        await model.open(Photo.demoList[0])
        let ids = model.comments.map(\.id)
        XCTAssertFalse(ids.isEmpty)
        service.commentResult = .failure(PhotoRecoveryFixture.Failure.unavailable)
        await model.reloadComments()
        XCTAssertNotNil(model.commentsErrorMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.comments.map(\.id), ids)
        XCTAssertFalse(model.isLoadingComments)
        service.commentResult = .success([])
        await model.reloadComments()
        XCTAssertNil(model.commentsErrorMessage)
        XCTAssertTrue(model.comments.isEmpty)
    }

    func testAnOldCommentFailureCannotOverwriteTheNewPhoto() async {
        let service = PhotoRecoveryFixture()
        let gate = PhotoRecoveryGate<[PhotoComment]>()
        let started = expectation(description: "First photo request pending")
        let first = Photo.demoList[0], second = Photo.demoList[1]
        let secondComments = PhotoComment.demo
        service.commentHandler = { id in
            if id == first.id { started.fulfill(); return try await gate.wait() }
            return secondComments
        }
        let model = PhotosViewModel(service: service)
        let old = Task { await model.open(first) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isLoadingComments)
        await model.open(second)
        await gate.finish(.failure(PhotoRecoveryFixture.Failure.unavailable))
        await old.value
        XCTAssertEqual(model.selectedPhoto?.id, second.id)
        XCTAssertEqual(model.comments, secondComments)
        XCTAssertNil(model.commentsErrorMessage)
        XCTAssertFalse(model.isLoadingComments)
    }

    func testSendingErrorPreservesDraftAndDoesNotBecomeAGalleryError() async {
        let service = PhotoRecoveryFixture()
        let model = PhotosViewModel(service: service)
        await model.open(Photo.demoList[0])
        model.draft = "Commentaire de recette"
        await model.sendComment()
        XCTAssertEqual(model.draft, "Commentaire de recette")
        XCTAssertNotNil(model.commentSendErrorMessage)
        XCTAssertNil(model.errorMessage)
        service.sendResult = .success(PhotoComment.demo[0])
        await model.sendComment()
        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertNil(model.commentSendErrorMessage)
        XCTAssertNotNil(model.commentsErrorMessage, "Sending must not hide an unavailable comment history")
        XCTAssertFalse(model.isSending)
    }

    func testAnOldGalleryErrorCannotReplaceANewerSuccessfulLoad() async {
        let service = PhotoRecoveryFixture()
        let gate = PhotoRecoveryGate<PhotoListResponse>()
        let started = expectation(description: "Old gallery request pending")
        service.galleryHandler = { started.fulfill(); return try await gate.wait() }
        let model = PhotosViewModel(service: service)
        let old = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        service.galleryHandler = nil
        service.gallery = .success(PhotoListResponse(photos: [Photo.demoList[1]], meta: nil))
        await model.load()
        await gate.finish(.failure(PhotoRecoveryFixture.Failure.unavailable))
        await old.value
        XCTAssertEqual(model.photos.map(\.id), [Photo.demoList[1].id])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testASuccessfulSendDoesNotEraseTextEditedWhileWaiting() async {
        let service = PhotoRecoveryFixture()
        let gate = PhotoRecoveryGate<[PhotoComment]>()
        let started = expectation(description: "Comment upload pending")
        service.sendHandler = { started.fulfill(); return (try await gate.wait()).first }
        let model = PhotosViewModel(service: service)
        await model.open(Photo.demoList[0])
        model.draft = "Premier commentaire"
        let send = Task { await model.sendComment() }
        await fulfillment(of: [started], timeout: 2)
        model.draft = "Nouveau brouillon"
        await gate.finish(.success(PhotoComment.demo))
        await send.value
        XCTAssertEqual(model.draft, "Nouveau brouillon")
        XCTAssertNil(model.commentSendErrorMessage)
        XCTAssertFalse(model.isSending)
    }

    func testRenderCommentLoadingErrorAndEmptyStatesInFrenchAndEnglish() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (name, locale, scheme, loading, error) in [
            ("error-fr-dark", "fr", ColorScheme.dark, false, "Connexion indisponible" as String?),
            ("error-en-light", "en", ColorScheme.light, false, "Connection unavailable" as String?),
            ("empty-fr-dark", "fr", ColorScheme.dark, false, nil),
            ("loading-en-light", "en", ColorScheme.light, true, nil)
        ] {
            let view = PhotoCommentsFeedback(isLoading: loading, error: error, isEmpty: true, onRetry: {})
                .padding(16).frame(width: 360).background(SQColor.bg)
                .environment(\.locale, Locale(identifier: locale)).environment(\.colorScheme, scheme)
            // UIKit hosting also captures the native activity indicator,
            // which ImageRenderer represents as an unsupported platform view.
            let host = UIHostingController(rootView: view.ignoresSafeArea())
            host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            let size = host.sizeThatFits(in: CGSize(width: 360, height: 1000))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host
            window.windowLevel = .normal + 1
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            XCTAssertGreaterThan(image.size.height, 40)
            let attachment = XCTAttachment(image: image)
            attachment.name = "photo-feedback-\(name)"; attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

private actor PhotoRecoveryGate<Value: Sendable> {
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    func wait() async throws -> Value {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ value: Result<Value, Error>) {
        result = value; continuation?.resume(with: value); continuation = nil
    }
}

// Responses are changed between awaited calls by these serial MainActor tests.
private final class PhotoRecoveryFixture: PhotoServicing, @unchecked Sendable {
    enum Failure: Error { case unavailable }
    var gallery: Result<PhotoListResponse, Error> = .failure(Failure.unavailable)
    var galleryHandler: (@Sendable () async throws -> PhotoListResponse)?
    var commentResult: Result<[PhotoComment], Error> = .failure(Failure.unavailable)
    var commentHandler: (@Sendable (String) async throws -> [PhotoComment])?
    var sendResult: Result<PhotoComment?, Error> = .failure(Failure.unavailable)
    var sendHandler: (@Sendable () async throws -> PhotoComment?)?
    func listPhotos(filter: String, sortBy: String, page: Int, limit: Int) async throws -> PhotoListResponse {
        if let galleryHandler { return try await galleryHandler() }
        return try gallery.get()
    }
    func photo(id: String) async throws -> Photo { throw Failure.unavailable }
    func comments(photoId: String) async throws -> [PhotoComment] {
        if let commentHandler { return try await commentHandler(photoId) }
        return try commentResult.get()
    }
    func addComment(photoId: String, content: String) async throws -> PhotoComment? {
        if let sendHandler { return try await sendHandler() }
        return try sendResult.get()
    }
    func toggleLike(photoId: String, reaction: String) async throws -> PhotoLikeResponse { throw Failure.unavailable }
    func updatePhotoOperator(photoId: String, operatorName: String) async throws { throw Failure.unavailable }
    func uploadPhoto(data: Data, siteId: String, description: String?, anfrCode: String?, operatorName: String?, exifMetadata: String?) async throws -> Photo { throw Failure.unavailable }
}
