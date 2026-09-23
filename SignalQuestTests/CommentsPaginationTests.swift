import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import SignalQuest

@MainActor
final class CommentsPaginationTests: XCTestCase {
    private func page(_ ids: [String], parentID: String? = nil, next: String? = nil) throws -> Data {
        let rows: [[String: Any]] = ids.map { id in
            ["id": id, "postId": "post-1", "parentId": parentID as Any? ?? NSNull(),
             "author": ["id": "author", "name": "Camille"], "text": id,
             "repliesCount": parentID == nil ? 21 : 0, "likesCount": 1]
        }
        return try JSONSerialization.data(withJSONObject: [
            parentID == nil ? "comments" : "replies": rows,
            "nextCursor": next as Any? ?? NSNull(), "totalCount": ids.count,
        ])
    }

    func testFiftyFirstParentRemainsReachableWithoutDuplicates() async throws {
        let first = try page((0..<50).map { "parent-\($0)" }, next: "after-50")
        let last = try page(["parent-49", "parent-50"])
        let service = CommentPages(parentPages: ["first": first, "after-50": last])
        let model = CommentsViewModel(service: service, postId: "post-1")

        await model.load()
        XCTAssertEqual(model.comments.count, 50)
        XCTAssertEqual(model.nextCursor, "after-50")
        await model.loadMore()
        XCTAssertEqual(model.comments.count, 51)
        XCTAssertEqual(model.comments.last?.id, "parent-50")
        XCTAssertNil(model.nextCursor)
        let cursors = await service.requestedParentCursors()
        XCTAssertEqual(cursors, ["first", "after-50"])
    }

    func testRepliesLoadOnDemandAndContinuePastTwenty() async throws {
        let parents = try page(["parent-1"])
        let first = try page((0..<20).map { "reply-\($0)" }, parentID: "parent-1", next: "after-20")
        let last = try page(["reply-19", "reply-20", "sent-parent-1"], parentID: "parent-1")
        let service = CommentPages(parentPages: ["first": parents],
            replyPages: ["parent-1|first": first, "parent-1|after-20": last])
        let model = CommentsViewModel(service: service, postId: "post-1")

        await model.load()
        let parent = try XCTUnwrap(model.comments.first)
        XCTAssertNil(model.repliesByParent[parent.id])
        await model.toggleReplies(for: parent)
        XCTAssertEqual(model.repliesByParent[parent.id]?.comments.count, 20)
        XCTAssertEqual(model.repliesByParent[parent.id]?.nextCursor, "after-20")
        model.beginReply(to: parent)
        model.draft = "A new reply"
        await model.send()
        XCTAssertEqual(model.repliesByParent[parent.id]?.sentComments.map(\.text), ["A new reply"])
        await model.loadMoreReplies(for: parent.id)
        XCTAssertEqual(model.repliesByParent[parent.id]?.comments.count, 22)
        XCTAssertTrue(model.repliesByParent[parent.id]?.sentComments.isEmpty == true,
            "The server copy replaces the locally sent reply")
        XCTAssertNil(model.repliesByParent[parent.id]?.nextCursor)
        await model.toggleReplies(for: parent)
        await model.toggleReplies(for: parent)
        let requests = await service.requestedReplyCursors()
        XCTAssertEqual(requests, ["parent-1|first", "parent-1|after-20"])
    }

    func testDelayedReplyToAIsNotAppliedToTheDraftForB() async throws {
        let parents = try page(["parent-A", "parent-B"])
        let repliesA = try page(["sent-parent-A"], parentID: "parent-A")
        let repliesB = try page(["sent-parent-B"], parentID: "parent-B")
        let gate = CommentSendGate()
        let service = CommentPages(parentPages: ["first": parents],
            replyPages: ["parent-A|first": repliesA, "parent-B|first": repliesB],
            delayedParentID: "parent-A", sendGate: gate)
        let model = CommentsViewModel(service: service, postId: "post-1")
        await model.load()
        let parentA = try XCTUnwrap(model.comments.first(where: { $0.id == "parent-A" }))
        let parentB = try XCTUnwrap(model.comments.first(where: { $0.id == "parent-B" }))
        model.beginReply(to: parentA)
        model.draft = "Text for A"
        let sendA = Task { await model.send() }
        for _ in 0..<100 {
            if await service.addCount() == 1 { break }
            await Task.yield()
        }
        let started = await service.addCount()
        guard started == 1 else {
            await gate.finish()
            sendA.cancel()
            return XCTFail("The first reply never started")
        }

        model.beginReply(to: parentB)
        model.draft = "Draft for B"
        await gate.finish()
        await sendA.value
        XCTAssertEqual(model.replyTo?.id, "parent-B")
        XCTAssertEqual(model.draft, "Draft for B")
        XCTAssertFalse(model.repliesByParent["parent-B"]?.comments.contains(where: { $0.text == "Text for A" }) ?? false)

        await model.send()
        let calls = await service.requestedAdds()
        XCTAssertEqual(calls.map { $0.parentID }, ["parent-A", "parent-B"])
        XCTAssertEqual(calls.map { $0.text }, ["Text for A", "Draft for B"])
    }

    func testOlderSlowCommentPageCannotReplaceANewerReload() async throws {
        let oldPage = try page(["old"])
        let newPage = try page(["new"])
        let gate = CommentSendGate()
        let service = CommentPages(parentPages: ["first": newPage],
            delayedFirstPage: oldPage, firstPageGate: gate)
        let model = CommentsViewModel(service: service, postId: "post-1")

        let oldRequest = Task { await model.load() }
        for _ in 0..<100 {
            if await service.parentRequestCount() == 1 { break }
            await Task.yield()
        }
        let started = await service.parentRequestCount()
        guard started == 1 else {
            await gate.finish()
            oldRequest.cancel()
            return XCTFail("The first page never started")
        }
        await model.load()
        XCTAssertEqual(model.comments.map(\.id), ["new"])

        await gate.finish()
        await oldRequest.value
        XCTAssertEqual(model.comments.map(\.id), ["new"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testFailedNextPageKeepsReadingPositionAndRetriesSameCursor() async throws {
        let first = try page((0..<50).map { "parent-\($0)" }, next: "after-50")
        let last = try page(["parent-50"])
        let service = CommentPages(parentPages: ["first": first, "after-50": last],
            failCursorOnce: "after-50")
        let model = CommentsViewModel(service: service, postId: "post-1")

        await model.load()
        await model.loadMore()
        XCTAssertEqual(model.comments.count, 50)
        XCTAssertEqual(model.nextCursor, "after-50")
        XCTAssertNotNil(model.paginationErrorMessage)

        await model.loadMore()
        XCTAssertEqual(model.comments.count, 51)
        XCTAssertNil(model.nextCursor)
        XCTAssertNil(model.paginationErrorMessage)
        let cursors = await service.requestedParentCursors()
        XCTAssertEqual(cursors, ["first", "after-50", "after-50"])
    }

    func testFailedReplyPageKeepsVisibleRepliesAndRetriesSameCursor() async throws {
        let parents = try page(["parent-1"])
        let first = try page(["reply-1"], parentID: "parent-1", next: "after-1")
        let last = try page(["reply-2"], parentID: "parent-1")
        let service = CommentPages(parentPages: ["first": parents],
            replyPages: ["parent-1|first": first, "parent-1|after-1": last],
            failReplyCursorOnce: "parent-1|after-1")
        let model = CommentsViewModel(service: service, postId: "post-1")
        await model.load()
        let parent = try XCTUnwrap(model.comments.first)
        await model.toggleReplies(for: parent)

        await model.loadMoreReplies(for: parent.id)
        XCTAssertEqual(model.repliesByParent[parent.id]?.comments.map(\.id), ["reply-1"])
        XCTAssertEqual(model.repliesByParent[parent.id]?.nextCursor, "after-1")
        XCTAssertNotNil(model.repliesByParent[parent.id]?.errorMessage)

        await model.retryReplies(for: parent.id)
        XCTAssertEqual(model.repliesByParent[parent.id]?.comments.map(\.id), ["reply-1", "reply-2"])
        XCTAssertNil(model.repliesByParent[parent.id]?.errorMessage)
        let cursors = await service.requestedReplyCursors()
        XCTAssertEqual(cursors,
            ["parent-1|first", "parent-1|after-1", "parent-1|after-1"])
    }

    func testExpandedRepliesRenderInFrenchAndEnglish() async throws {
        let parents = try page(["parent-1"])
        let replies = try page(["reply-1"], parentID: "parent-1")
        let service = CommentPages(parentPages: ["first": parents],
            replyPages: ["parent-1|first": replies])
        let model = CommentsViewModel(service: service, postId: "post-1")
        await model.load()
        let parent = try XCTUnwrap(model.comments.first)
        await model.toggleReplies(for: parent)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = UIDevice.current.userInterfaceIdiom == .pad
            ? CGSize(width: 700, height: 900) : CGSize(width: 360, height: 740)

        for locale in ["fr", "en"] {
            let view = CommentsSheet(model: model)
                .environment(\.locale, Locale(identifier: locale))
                .environment(\.colorScheme, .light)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = host
            window.windowLevel = .normal + 1
            window.isHidden = false
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "comments-expanded-\(locale)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }

    func testAReplyLikeReconcilesInsideTheExpandedThread() async throws {
        let parents = try page(["parent-1"])
        let replies = try page(["reply-1"], parentID: "parent-1")
        let service = CommentPages(parentPages: ["first": parents],
            replyPages: ["parent-1|first": replies])
        let model = CommentsViewModel(service: service, postId: "post-1")
        await model.load()
        let parent = try XCTUnwrap(model.comments.first)
        await model.toggleReplies(for: parent)
        let reply = try XCTUnwrap(model.repliesByParent[parent.id]?.comments.first)
        XCTAssertEqual(reply.likes, 1, "The live API names the field likesCount")

        model.toggleLike(reply)
        for _ in 0..<100 {
            if model.repliesByParent[parent.id]?.comments.first?.likes == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(model.repliesByParent[parent.id]?.comments.first?.likes, 2)
        XCTAssertTrue(model.repliesByParent[parent.id]?.comments.first?.likedByMe == true)
    }
}

private actor CommentSendGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { finished = true; continuation?.resume(); continuation = nil }
}

private actor CommentPages: CommentsServicing {
    enum Failure: Error { case missingPage, offline, unused }
    private let parentPages: [String: Data]
    private let replyPages: [String: Data]
    private let delayedParentID: String?
    private let sendGate: CommentSendGate?
    private let delayedFirstPage: Data?
    private let firstPageGate: CommentSendGate?
    private let failCursorOnce: String?
    private let failReplyCursorOnce: String?
    private var failedCursors: Set<String> = []
    private var parentCursors: [String] = []
    private var replyCursors: [String] = []
    private var addCalls: [(parentID: String?, text: String)] = []

    init(parentPages: [String: Data], replyPages: [String: Data] = [:],
         delayedParentID: String? = nil, sendGate: CommentSendGate? = nil,
         delayedFirstPage: Data? = nil, firstPageGate: CommentSendGate? = nil,
         failCursorOnce: String? = nil, failReplyCursorOnce: String? = nil) {
        self.parentPages = parentPages
        self.replyPages = replyPages
        self.delayedParentID = delayedParentID
        self.sendGate = sendGate
        self.delayedFirstPage = delayedFirstPage
        self.firstPageGate = firstPageGate
        self.failCursorOnce = failCursorOnce
        self.failReplyCursorOnce = failReplyCursorOnce
    }

    func list(postId: String, cursor: String?) async throws -> SocialCommentsResponse {
        let key = cursor ?? "first"
        parentCursors.append(key)
        if key == failCursorOnce, !failedCursors.contains(key) {
            failedCursors.insert(key)
            throw Failure.offline
        }
        if cursor == nil, parentCursors.count == 1, let delayedFirstPage {
            await firstPageGate?.wait()
            return try JSONDecoder.signalQuest.decode(SocialCommentsResponse.self, from: delayedFirstPage)
        }
        guard let data = parentPages[key] else { throw Failure.missingPage }
        return try JSONDecoder.signalQuest.decode(SocialCommentsResponse.self, from: data)
    }

    func replies(postId: String, commentId: String, cursor: String?) async throws -> SocialCommentsResponse {
        let key = "\(commentId)|\(cursor ?? "first")"
        replyCursors.append(key)
        if key == failReplyCursorOnce, !failedCursors.contains(key) {
            failedCursors.insert(key)
            throw Failure.offline
        }
        guard let data = replyPages[key] else { throw Failure.missingPage }
        return try JSONDecoder.signalQuest.decode(SocialCommentsResponse.self, from: data)
    }

    func add(postId: String, text: String, parentId: String?) async throws -> SocialComment {
        addCalls.append((parentId, text))
        if let delayedParentID, parentId == delayedParentID { await sendGate?.wait() }
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "sent-\(parentId ?? "top")", "postId": postId,
            "parentId": parentId as Any? ?? NSNull(),
            "author": ["id": "me", "name": "Moi"], "text": text,
        ])
        return try JSONDecoder.signalQuest.decode(SocialComment.self, from: data)
    }
    func like(postId: String, commentId: String) async throws -> CommentReactionResponse {
        try JSONDecoder().decode(CommentReactionResponse.self, from: Data(#"{"liked":true,"count":2}"#.utf8))
    }
    func unlike(postId: String, commentId: String) async throws -> CommentReactionResponse {
        try JSONDecoder().decode(CommentReactionResponse.self, from: Data(#"{"liked":false,"count":0}"#.utf8))
    }
    func requestedParentCursors() -> [String] { parentCursors }
    func requestedReplyCursors() -> [String] { replyCursors }
    func requestedAdds() -> [(parentID: String?, text: String)] { addCalls }
    func addCount() -> Int { addCalls.count }
    func parentRequestCount() -> Int { parentCursors.count }
}
