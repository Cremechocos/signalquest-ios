import Foundation
import SwiftUI
import XCTest
@testable import SignalQuest

@MainActor
final class SessionsListPaginationTests: XCTestCase {
    private enum FixtureError: Error { case unexpectedOffset }

    private func page(_ rows: [(String, String)], hasMore: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "sessions": rows.map { ["id": $0.0, "source": $0.1] },
            "pagination": ["hasMore": hasMore],
        ])
    }

    func testFilteredHistoryCanReachAMatchBeyondTheFirstPage() async throws {
        let first = try page((0..<15).map { ("coverage-\($0)", "manual") }, hasMore: true)
        let second = try page([
            ("coverage-14", "manual"), // same row repeated after a concurrent insertion
            ("drive-later", "drive_test"),
        ], hasMore: false)
        let model = SessionsListViewModel { offset, _ in
            let data: Data
            switch offset {
            case 0: data = first
            case 15: data = second
            default: throw FixtureError.unexpectedOffset
            }
            return try JSONDecoder().decode(SessionsListResponse.self, from: data)
        }
        model.filter = .driveTest

        await model.reload()
        XCTAssertTrue(model.filtered.isEmpty)
        XCTAssertTrue(model.hasMore)
        XCTAssertFalse(model.isExhaustedEmpty, "A local empty page must not hide later matches")

        await model.loadMore()
        XCTAssertEqual(model.filtered.map(\.id), ["drive-later"])
        XCTAssertFalse(model.hasMore)
        XCTAssertFalse(model.isExhaustedEmpty)
        XCTAssertEqual(model.sessions.count, 16, "A shifted page must not duplicate a row")
        model.filter = .coverage
        XCTAssertEqual(model.filtered.count, 15)
        model.filter = .all
        XCTAssertEqual(model.filtered.count, 16)
    }

    func testEmptyFilteredStateAppearsOnlyAfterTheLastPage() async throws {
        let first = try page((0..<15).map { ("coverage-\($0)", "manual") }, hasMore: true)
        let last = try page([("coverage-last", "manual")], hasMore: false)
        let model = SessionsListViewModel { offset, _ in
            try JSONDecoder().decode(SessionsListResponse.self, from: offset == 0 ? first : last)
        }
        model.filter = .driveTest

        await model.reload()
        XCTAssertFalse(model.isExhaustedEmpty)
        await model.loadMore()
        XCTAssertTrue(model.isExhaustedEmpty)
    }

    func testDriveTestFilterHidesLocalCoverageArchivesAndKeepsItsEmptyState() async throws {
        let emptyPage = try page([], hasMore: false)
        let model = SessionsListViewModel { _, _ in
            try JSONDecoder().decode(SessionsListResponse.self, from: emptyPage)
        }
        await model.reload()
        let upload = CoverageSessionUpload(
            sessionId: UUID(), startTime: 1_000, endTime: 2_000,
            showOnMap: false, points: []
        )
        let archive = LocalCoverageArchiveSnapshot(
            entries: [LocalCoverageArchive(PendingCoverageSession(
                upload: upload, state: .queued, updatedAtMs: 2_000
            ))],
            unreadableSources: 0
        )
        let unreadableOnly = LocalCoverageArchiveSnapshot(entries: [], unreadableSources: 1)

        model.filter = .driveTest
        XCTAssertFalse(model.showsLocalCoverageArchive)
        XCTAssertTrue(model.showsEmptyState(archive: archive, archiveIsLoading: false))
        XCTAssertTrue(model.showsEmptyState(archive: unreadableOnly, archiveIsLoading: false))

        model.filter = .all
        XCTAssertTrue(model.showsLocalCoverageArchive)
        XCTAssertFalse(model.showsEmptyState(archive: archive, archiveIsLoading: false))
        XCTAssertFalse(model.showsEmptyState(archive: unreadableOnly, archiveIsLoading: false))

        model.filter = .coverage
        XCTAssertTrue(model.showsLocalCoverageArchive)
        XCTAssertFalse(model.showsEmptyState(archive: archive, archiveIsLoading: false))
    }

    func testOlderReloadCannotReplaceANewerResult() async throws {
        let older = try page([("old", "manual")], hasMore: false)
        let newer = try page([("new", "drive_test")], hasMore: false)
        let delayed = DelayedFirstPage(newer: newer)
        let model = SessionsListViewModel { _, _ in
            let data = await delayed.load()
            return try JSONDecoder().decode(SessionsListResponse.self, from: data)
        }

        let oldRequest = Task { await model.reload() }
        for _ in 0..<100 {
            if delayed.calls == 1 { break }
            await Task.yield()
        }
        guard delayed.calls == 1 else {
            oldRequest.cancel()
            return XCTFail("The first request never started")
        }
        await model.reload()
        XCTAssertEqual(model.sessions.map(\.id), ["new"])

        delayed.finishFirst(with: older)
        await oldRequest.value
        XCTAssertEqual(model.sessions.map(\.id), ["new"])
    }

    /// L'écran entier, pas seulement le modèle : la ligne du bas lançait la page suivante dans un
    /// `.task`, puis passait sur une autre branche dès `isLoading`, ce qui annulait la tâche, donc
    /// la requête. Le chargement repartait aussitôt et s'annulait encore : un spinner sans fin
    /// au bas de la liste dès qu'un compte avait plus d'une page (ticket du 17/11, build 186).
    func testTheScreenLoadsTheNextPageInsteadOfSpinningForever() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Une scène UIKit active est nécessaire pour afficher l'écran")
        }
        let service = SlowNextPageSessions(
            first: try page([("first-a", "manual"), ("first-b", "manual")], hasMore: true),
            next: try page([("next-c", "manual")], hasMore: false)
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let controller = UIHostingController(rootView: NavigationStack { SessionsListView(service: service) })
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        try await Task.sleep(for: .seconds(3))

        let counts = service.counts()
        XCTAssertEqual(counts.completed, 1, "La page suivante arrive")
        XCTAssertEqual(counts.cancelled, 0, "Sa requête n'est jamais annulée par l'écran")
        XCTAssertEqual(counts.started, 1, "Une seule requête pour la page suivante")
    }
}

@MainActor
private final class DelayedFirstPage {
    private let newer: Data
    private var first: CheckedContinuation<Data, Never>?
    private(set) var calls = 0

    init(newer: Data) { self.newer = newer }

    func load() async -> Data {
        calls += 1
        if calls == 1 {
            return await withCheckedContinuation { first = $0 }
        }
        return newer
    }

    func finishFirst(with data: Data) {
        first?.resume(returning: data)
        first = nil
    }
}

/// Première page tout de suite, la suivante après 0,3 s : le temps qu'une annulation se voie.
private final class SlowNextPageSessions: SessionsServicing, @unchecked Sendable {
    private let first: Data
    private let next: Data
    private let lock = NSLock()
    private var started = 0
    private var completed = 0
    private var cancelled = 0

    init(first: Data, next: Data) {
        self.first = first
        self.next = next
    }

    func counts() -> (started: Int, completed: Int, cancelled: Int) {
        lock.withLock { (started, completed, cancelled) }
    }

    func sessions(offset: Int, limit: Int, mapPoints: Bool) async throws -> SessionsListResponse {
        guard offset > 0 else { return try JSONDecoder().decode(SessionsListResponse.self, from: first) }
        lock.withLock { started += 1 }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            lock.withLock { cancelled += 1 }
            throw error
        }
        lock.withLock { completed += 1 }
        return try JSONDecoder().decode(SessionsListResponse.self, from: next)
    }

    func sessionDetail(id: String) async throws -> CoverageSessionDetail {
        throw APIError.cancelled
    }
}
