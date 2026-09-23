import Foundation
import XCTest
@testable import SignalQuest

@MainActor
final class NotificationMutationTests: XCTestCase {
    private func item(_ id: String, read: Bool = false) -> AppNotification {
        AppNotification(id: id, type: "social_comment", title: id, message: nil,
            createdAt: nil, read: read, link: nil, metadata: nil)
    }

    func testOfflineReadRemainsUnreadUntilRetrySucceeds() async {
        let service = NotificationMutationMock(items: [item("a")], failReadOnce: true)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()

        await model.markRead("a")
        XCTAssertEqual(model.items.first?.read, false)
        XCTAssertEqual(model.failedAction, .markRead("a"))
        XCTAssertNotNil(model.actionErrorMessage)

        await model.retryFailedAction()
        XCTAssertEqual(model.items.first?.read, true)
        XCTAssertNil(model.failedAction)
        XCTAssertNil(model.actionErrorMessage)
        let count = await service.readCount()
        XCTAssertEqual(count, 2)
    }

    func testFailedGroupActionsPreserveItemsAndCanRetry() async {
        let service = NotificationMutationMock(items: [item("a"), item("b")],
            failMarkAllOnce: true, failDeleteOnce: true)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()

        await model.markAll()
        XCTAssertEqual(model.items.map(\.read), [false, false])
        XCTAssertEqual(model.failedAction, .markAll)
        await model.retryFailedAction()
        XCTAssertEqual(model.items.map(\.read), [true, true])

        await model.deleteAll()
        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.failedAction, .deleteAll)
        await model.retryFailedAction()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.failedAction)
    }

    func testOlderReloadCannotUndoAcknowledgedMarkAll() async {
        let gate = NotificationLoadGate()
        let service = NotificationMutationMock(items: [item("a")], delayedSecondList: gate)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()
        let staleLoad = Task { await model.load() }
        for _ in 0..<100 {
            if await service.listCount() == 2 { break }
            await Task.yield()
        }
        guard await service.listCount() == 2 else {
            await gate.finish()
            staleLoad.cancel()
            return XCTFail("The stale load never started")
        }

        await model.markAll()
        XCTAssertEqual(model.items.first?.read, true)
        await gate.finish()
        await staleLoad.value
        XCTAssertEqual(model.items.first?.read, true)
        XCTAssertFalse(model.isLoading)
    }

    func testOlderReloadCannotUndoAcknowledgedSingleRead() async {
        let gate = NotificationLoadGate()
        let service = NotificationMutationMock(items: [item("a")], delayedSecondList: gate)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()
        let staleLoad = Task { await model.load() }
        for _ in 0..<100 {
            if await service.listCount() == 2 { break }
            await Task.yield()
        }
        guard await service.listCount() == 2 else {
            await gate.finish()
            staleLoad.cancel()
            return XCTFail("The stale load never started")
        }

        await model.markRead("a")
        XCTAssertEqual(model.items.first?.read, true)
        await gate.finish()
        await staleLoad.value
        XCTAssertEqual(model.items.first?.read, true)
        XCTAssertFalse(model.isLoading)
    }

    func testGroupMutationWaitsForSingleReadToSettle() async {
        let gate = NotificationLoadGate()
        let service = NotificationMutationMock(items: [item("a")], delayedRead: gate)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()
        let pendingRead = Task { await model.markRead("a") }
        for _ in 0..<100 {
            if await service.readCount() == 1 { break }
            await Task.yield()
        }
        guard await service.readCount() == 1 else {
            await gate.finish()
            pendingRead.cancel()
            return XCTFail("The single read never started")
        }

        await model.markAll()
        let before = await service.markAllCount()
        XCTAssertEqual(before, 0)
        await gate.finish()
        await pendingRead.value
        await model.markAll()
        let after = await service.markAllCount()
        XCTAssertEqual(after, 1)
    }
}

private actor NotificationLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { finished = true; continuation?.resume(); continuation = nil }
}

private actor NotificationMutationMock: NotificationsServicing {
    enum Failure: Error { case offline }
    private var rows: [AppNotification]
    private var readFailures: Int
    private var markAllFailures: Int
    private var deleteFailures: Int
    private let delayedSecondList: NotificationLoadGate?
    private let delayedRead: NotificationLoadGate?
    private var lists = 0
    private var reads = 0
    private var markAlls = 0

    init(items: [AppNotification], failReadOnce: Bool = false,
         failMarkAllOnce: Bool = false, failDeleteOnce: Bool = false,
         delayedSecondList: NotificationLoadGate? = nil,
         delayedRead: NotificationLoadGate? = nil) {
        rows = items
        readFailures = failReadOnce ? 1 : 0
        markAllFailures = failMarkAllOnce ? 1 : 0
        deleteFailures = failDeleteOnce ? 1 : 0
        self.delayedSecondList = delayedSecondList
        self.delayedRead = delayedRead
    }

    func list(cursor: String?) async throws -> [AppNotification] {
        lists += 1
        let snapshot = rows
        if lists == 2 { await delayedSecondList?.wait() }
        return snapshot
    }
    func markRead(id: String) async throws {
        reads += 1
        await delayedRead?.wait()
        if readFailures > 0 { readFailures -= 1; throw Failure.offline }
    }
    func markAllRead() async throws {
        markAlls += 1
        if markAllFailures > 0 { markAllFailures -= 1; throw Failure.offline }
    }
    func deleteAll() async throws {
        if deleteFailures > 0 { deleteFailures -= 1; throw Failure.offline }
        rows = []
    }
    func listCount() -> Int { lists }
    func readCount() -> Int { reads }
    func markAllCount() -> Int { markAlls }
}
