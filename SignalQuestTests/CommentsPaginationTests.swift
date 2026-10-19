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

// MARK: - Salons (ROOM-1)

/// Les règles locales des salons : « Ton salon », départements, opérateurs, fusion des pages.
final class RoomsLogicTests: XCTestCase {
    private let ara = RoomRegion(slug: "auvergne-rhone-alpes", name: "Auvergne-Rhône-Alpes")
    private let corse = RoomRegion(slug: "corse", name: "Corse")

    private var metroRooms: [RoomSummary] {
        var rooms: [RoomSummary] = []
        for key in ["ORANGE", "SFR", "BOUYGUES", "FREE"] {
            rooms.append(RoomSummary(id: "fr-ara-\(key.lowercased())", name: "\(key) · ARA", region: ara,
                                     departments: ["001", "038", "069"], operatorKey: key))
            rooms.append(RoomSummary(id: "fr-corse-\(key.lowercased())", name: "\(key) · Corse", region: corse,
                                     departments: ["02A", "02B"], operatorKey: key))
            rooms.append(RoomSummary(id: "fr-national-\(key.lowercased())", scope: "national", name: "\(key) · France",
                                     operatorKey: key))
        }
        rooms.append(RoomSummary(id: "fr-national-5g-sa", scope: "national", name: "5G SA · France", technology: "5G_SA"))
        return rooms
    }

    private var dromRooms: [RoomSummary] {
        let guadeloupe = RoomRegion(slug: "guadeloupe", name: "Guadeloupe")
        return [
            RoomSummary(id: "drom-guadeloupe-orange", market: "DROM", name: "Orange · Guadeloupe", region: guadeloupe,
                        departments: ["971"], operatorKey: "ORANGE"),
            RoomSummary(id: "drom-guadeloupe-digicel", market: "DROM", name: "Digicel · Guadeloupe", region: guadeloupe,
                        departments: ["971"], operatorKey: "DIGICEL"),
        ]
    }

    func testYourRoomIsTheRegionRoomOfTheDepartmentAndOperator() {
        XCTAssertEqual(RoomsLogic.yourRoom(in: metroRooms, operatorKey: "SFR", department: "038")?.id, "fr-ara-sfr")
        XCTAssertEqual(RoomsLogic.yourRoom(in: metroRooms, operatorKey: "Orange F", department: "069")?.id, "fr-ara-orange")
    }

    func testCorsicanDepartmentsReachTheCorsicaRooms() {
        XCTAssertEqual(RoomsLogic.yourRoom(in: metroRooms, operatorKey: "FREE", department: "02A")?.id, "fr-corse-free")
        XCTAssertEqual(RoomsLogic.yourRoom(in: metroRooms, operatorKey: "FREE", department: "02B")?.id, "fr-corse-free")
    }

    func testWithoutADepartmentOrWithOneThatHasNoRoomItIsTheOperatorsNationalRoom() {
        XCTAssertEqual(RoomsLogic.yourRoom(in: metroRooms, operatorKey: "SFR", department: nil)?.id, "fr-national-sfr")
        XCTAssertEqual(RoomsLogic.yourRoom(in: metroRooms, operatorKey: "BOUYGUES", department: "075")?.id, "fr-national-bouygues")
    }

    func testAnUnknownOperatorHasNoRoomOfItsOwn() {
        XCTAssertNil(RoomsLogic.yourRoom(in: metroRooms, operatorKey: nil, department: "038"))
        XCTAssertNil(RoomsLogic.yourRoom(in: metroRooms, operatorKey: "Lycamobile", department: "038"))
    }

    func testOverseasDepartmentsUseTheirTerritoryRoomsAndNeverFallBackToMetropolitanOnes() {
        XCTAssertEqual(RoomsLogic.yourRoom(in: dromRooms, operatorKey: "ORANGE", department: "971")?.id, "drom-guadeloupe-orange")
        XCTAssertEqual(RoomsLogic.yourRoom(in: dromRooms, operatorKey: "DIGICEL", department: "971")?.id, "drom-guadeloupe-digicel")
        XCTAssertNil(RoomsLogic.yourRoom(in: dromRooms, operatorKey: "SFR", department: "971"))
        XCTAssertNil(RoomsLogic.yourRoom(in: metroRooms + dromRooms, operatorKey: "SFR", department: "971"))
    }

    func testPostalCodesBecomeThreeCharacterDepartmentCodes() {
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "38000"), "038")
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "75008"), "075")
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "01000"), "001")
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "95000"), "095")
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "20000"), "02A")
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "20167"), "02A")
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "20199"), "02A")
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "20200"), "02B")
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "20600"), "02B")
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "97100"), "971")
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "97400"), "974")
        XCTAssertEqual(RoomsLogic.departmentCode(postalCode: "97600"), "976")
    }

    func testPostalCodesWithoutARoomOrIncompleteGiveNoDepartment() {
        XCTAssertNil(RoomsLogic.departmentCode(postalCode: "98000"), "Monaco")
        XCTAssertNil(RoomsLogic.departmentCode(postalCode: "97500"), "Saint-Pierre-et-Miquelon n'a pas de salon")
        XCTAssertNil(RoomsLogic.departmentCode(postalCode: "3800"))
        XCTAssertNil(RoomsLogic.departmentCode(postalCode: "38 00"))
        XCTAssertNil(RoomsLogic.departmentCode(postalCode: "ABCDE"))
        XCTAssertNil(RoomsLogic.departmentCode(postalCode: nil))
    }

    func testOperatorNamesMapToTheRoomOperators() {
        XCTAssertEqual(RoomsLogic.operatorKey(from: "ORANGE"), "ORANGE")
        XCTAssertEqual(RoomsLogic.operatorKey(from: "Orange F"), "ORANGE")
        XCTAssertEqual(RoomsLogic.operatorKey(from: "F SFR"), "SFR")
        XCTAssertEqual(RoomsLogic.operatorKey(from: "Bouygues Telecom"), "BOUYGUES")
        XCTAssertEqual(RoomsLogic.operatorKey(from: "Free"), "FREE")
        XCTAssertEqual(RoomsLogic.operatorKey(from: "Free Mobile"), "FREE")
        XCTAssertEqual(RoomsLogic.operatorKey(from: "OUTREMER_TELECOM"), "OUTREMER_TELECOM")
        XCTAssertNil(RoomsLogic.operatorKey(from: "SFR Réunion"), "Un nom ultramarin n'est pas ramené à son homonyme métropolitain")
        XCTAssertNil(RoomsLogic.operatorKey(from: "Freebox"))
        XCTAssertNil(RoomsLogic.operatorKey(from: "Lycamobile"))
        XCTAssertNil(RoomsLogic.operatorKey(from: "  "))
        XCTAssertNil(RoomsLogic.operatorKey(from: nil))
    }

    // MARK: Fusion des pages

    private func message(_ id: String, minutesAgo: Double) -> RoomMessage {
        RoomMessage(id: id, text: id, createdAt: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60),
                    radio: nil,
                    author: SocialFeedAuthor(id: "a", name: "A", handle: nil, avatarUrl: nil, isFriend: nil,
                                             isFollowing: nil, liveRadio: nil),
                    own: false, canDelete: false)
    }

    func testRefreshPutsNewMessagesFirstAndKeepsTheOlderPagesBelow() {
        let existing = [message("m5", minutesAgo: 5), message("m4", minutesAgo: 6), message("m3", minutesAgo: 7),
                        message("m2", minutesAgo: 8), message("m1", minutesAgo: 9)]
        let firstPage = [message("m6", minutesAgo: 1), message("m5", minutesAgo: 5), message("m4", minutesAgo: 6)]
        let merged = RoomsLogic.refreshed(firstPage: firstPage, hasMore: true, existing: existing)
        XCTAssertEqual(merged.map(\.id), ["m6", "m5", "m4", "m3", "m2", "m1"])
        XCTAssertEqual(RoomsLogic.newIds(in: merged, comparedTo: existing), ["m6"])
    }

    func testRefreshDropsAMessageDeletedInsideTheRereadWindowOnly() {
        let existing = [message("m5", minutesAgo: 5), message("m4", minutesAgo: 6), message("m3", minutesAgo: 7),
                        message("m2", minutesAgo: 8), message("m1", minutesAgo: 9)]
        // m4 a été supprimé : la première page relue couvre jusqu'à m3.
        let firstPage = [message("m5", minutesAgo: 5), message("m3", minutesAgo: 7)]
        let merged = RoomsLogic.refreshed(firstPage: firstPage, hasMore: true, existing: existing)
        XCTAssertEqual(merged.map(\.id), ["m5", "m3", "m2", "m1"])
    }

    func testRefreshOfAWholeRoomIsExactlyTheFirstPage() {
        let existing = [message("m2", minutesAgo: 2), message("m1", minutesAgo: 3)]
        let firstPage = [message("m2", minutesAgo: 2)]
        XCTAssertEqual(RoomsLogic.refreshed(firstPage: firstPage, hasMore: false, existing: existing).map(\.id), ["m2"])
    }

    func testAppendingAnOlderPageNeverDuplicates() {
        let existing = [message("m3", minutesAgo: 3), message("m2", minutesAgo: 4)]
        let page = [message("m2", minutesAgo: 4), message("m1", minutesAgo: 5)]
        XCTAssertEqual(RoomsLogic.appending(page, to: existing).map(\.id), ["m3", "m2", "m1"])
    }
}

/// Le salon ouvert : première page, relecture sans déplacer la lecture, envoi, suppression.
@MainActor
final class RoomThreadModelTests: XCTestCase {
    private final class FakeRooms: RoomsServicing, @unchecked Sendable {
        var first: RoomMessagesPage = RoomMessagesPage(messages: [], nextCursor: nil)
        var older: [String: RoomMessagesPage] = [:]
        var postResult: Result<RoomMessage, Error> = .failure(APIError.cancelled)
        var postedTexts: [String] = []
        var deleted: [String] = []
        var failsReads = false

        func rooms(market: String) async throws -> [RoomSummary] { [] }
        func messages(roomId: String, cursor: String?) async throws -> RoomMessagesPage {
            if failsReads { throw APIError.cancelled }
            guard let cursor else { return first }
            return older[cursor] ?? RoomMessagesPage(messages: [], nextCursor: nil)
        }
        func post(roomId: String, text: String) async throws -> RoomMessage {
            postedTexts.append(text)
            return try postResult.get()
        }
        func delete(messageId: String) async throws { deleted.append(messageId) }
        func live(roomId: String) async throws -> [RoomLiveShare] { [] }
    }

    private func message(_ id: String, minutesAgo: Double, own: Bool = false) -> RoomMessage {
        RoomMessage(id: id, text: id, createdAt: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60),
                    radio: nil,
                    author: SocialFeedAuthor(id: "a", name: "A", handle: nil, avatarUrl: nil, isFriend: nil,
                                             isFollowing: nil, liveRadio: nil),
                    own: own, canDelete: own)
    }

    private func makeModel(_ service: FakeRooms) -> RoomThreadModel {
        RoomThreadModel(roomId: "fr-national-sfr", service: service)
    }

    func testLoadShowsTheFirstPageAndItsCursor() async {
        let service = FakeRooms()
        service.first = RoomMessagesPage(messages: [message("m2", minutesAgo: 1), message("m1", minutesAgo: 2)], nextCursor: "c1")
        let model = makeModel(service)
        await model.load()
        XCTAssertEqual(model.messages.map(\.id), ["m2", "m1"])
        XCTAssertEqual(model.nextCursor, "c1")
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.loadError)
    }

    func testRefreshAtTheTopShowsNewMessagesAtOnce() async {
        let service = FakeRooms()
        service.first = RoomMessagesPage(messages: [message("m1", minutesAgo: 2)], nextCursor: nil)
        let model = makeModel(service)
        await model.load()
        service.first = RoomMessagesPage(messages: [message("m2", minutesAgo: 1), message("m1", minutesAgo: 2)], nextCursor: nil)
        await model.refresh(isAtTop: true)
        XCTAssertEqual(model.messages.map(\.id), ["m2", "m1"])
        XCTAssertEqual(model.pendingCount, 0)
    }

    func testRefreshWhileReadingLowerKeepsTheListStillUntilTheReaderAsks() async {
        let service = FakeRooms()
        service.first = RoomMessagesPage(messages: [message("m1", minutesAgo: 2)], nextCursor: nil)
        let model = makeModel(service)
        await model.load()
        service.first = RoomMessagesPage(messages: [message("m3", minutesAgo: 0.5), message("m2", minutesAgo: 1), message("m1", minutesAgo: 2)],
                                         nextCursor: nil)
        await model.refresh(isAtTop: false)
        XCTAssertEqual(model.messages.map(\.id), ["m1"], "Rien ne bouge sous le doigt")
        XCTAssertEqual(model.pendingCount, 2)
        // Une seconde relecture sans rien de neuf garde le même compte.
        await model.refresh(isAtTop: false)
        XCTAssertEqual(model.pendingCount, 2)
        model.applyPending()
        XCTAssertEqual(model.messages.map(\.id), ["m3", "m2", "m1"])
        XCTAssertEqual(model.pendingCount, 0)
    }

    func testRefreshKeepsThePagesAlreadyReadAndTheirCursor() async {
        let service = FakeRooms()
        service.first = RoomMessagesPage(messages: [message("m4", minutesAgo: 1), message("m3", minutesAgo: 2)], nextCursor: "c1")
        service.older["c1"] = RoomMessagesPage(messages: [message("m2", minutesAgo: 3), message("m1", minutesAgo: 4)], nextCursor: "c2")
        let model = makeModel(service)
        await model.load()
        await model.loadMore()
        XCTAssertEqual(model.messages.map(\.id), ["m4", "m3", "m2", "m1"])
        XCTAssertEqual(model.nextCursor, "c2")

        service.first = RoomMessagesPage(messages: [message("m5", minutesAgo: 0.5), message("m4", minutesAgo: 1)], nextCursor: "c0")
        await model.refresh(isAtTop: true)
        XCTAssertEqual(model.messages.map(\.id), ["m5", "m4", "m3", "m2", "m1"])
        XCTAssertEqual(model.nextCursor, "c2", "Le curseur des pages plus anciennes ne revient pas en arrière")
    }

    func testAFailedRefreshKeepsWhatIsDisplayed() async {
        let service = FakeRooms()
        service.first = RoomMessagesPage(messages: [message("m1", minutesAgo: 2)], nextCursor: nil)
        let model = makeModel(service)
        await model.load()
        service.failsReads = true
        await model.refresh(isAtTop: true)
        XCTAssertEqual(model.messages.map(\.id), ["m1"])
        XCTAssertNil(model.loadError)
    }

    func testPostingShowsTheServerMessageFirst() async {
        let service = FakeRooms()
        service.first = RoomMessagesPage(messages: [message("m1", minutesAgo: 2)], nextCursor: nil)
        service.postResult = .success(message("m9", minutesAgo: 0, own: true))
        let model = makeModel(service)
        await model.load()
        let sent = await model.post("  Bonjour  ")
        XCTAssertTrue(sent)
        XCTAssertEqual(service.postedTexts, ["Bonjour"])
        XCTAssertEqual(model.messages.map(\.id), ["m9", "m1"])
    }

    func testAFailedPostKeepsTheDraftToTheCaller() async {
        let service = FakeRooms()
        service.postResult = .failure(APIError.http(status: 429, code: "NEW_ACCOUNT_DAILY_LIMIT", message: "limite",
                                                     requestId: nil, retryAfter: nil))
        let model = makeModel(service)
        await model.load()
        let sent = await model.post("Bonjour")
        XCTAssertFalse(sent)
        XCTAssertNotNil(model.postError)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testDeletingRemovesTheMessageAfterTheServerAnswers() async {
        let service = FakeRooms()
        let mine = message("m1", minutesAgo: 2, own: true)
        service.first = RoomMessagesPage(messages: [message("m2", minutesAgo: 1), mine], nextCursor: nil)
        let model = makeModel(service)
        await model.load()
        await model.delete(mine)
        XCTAssertEqual(service.deleted, ["m1"])
        XCTAssertEqual(model.messages.map(\.id), ["m2"])
    }
}
