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

/// Page Trajets, piste A (choix d'Alexandre du 20/11) : ce que dit chaque ligne.
@MainActor
final class SessionRowTests: XCTestCase {
    /// Les trajets de la capture du 20/11 (l'heure du 19 au soir y était coupée : 19:02 ici), puis
    /// un Drive Test connu par son récap, un trajet nommé et une couverture iOS sans RSRP.
    static let pageJSON = """
    {"sessions":[
     {"id":"t1","source":"manual","startTime":"2026-11-20T11:59:00.000Z","duration":6180,"totalPoints":2348,"distance":27.9,
      "avgSignalStrength":-91.3,"operators":[{"key":"ORANGE","label":"Orange","color":"#FF7900"}]},
     {"id":"t2","source":"manual","startTime":"2026-11-19T18:02:00.000Z","duration":2340,"totalPoints":736,"distance":9.1,
      "avgSignalStrength":-64.2,"operators":[{"key":"ORANGE","label":"Orange","color":"#FF7900"},
      {"key":"BOUYGUES","label":"Bouygues Telecom","color":"#009DDC"}]},
     {"id":"t3","source":"manual","startTime":"2026-11-19T13:13:00.000Z","duration":1260,"totalPoints":1020,"distance":11.0,
      "avgSignalStrength":-63.0,"operators":[{"key":"ORANGE","label":"Orange","color":"#FF7900"},
      {"key":"BOUYGUES","label":"Bouygues Telecom","color":"#009DDC"}]},
     {"id":"t4","source":"manual","startTime":"2026-09-10T08:11:00.000Z","duration":28380,"totalPoints":2927,"distance":168.6,
      "avgSignalStrength":-92.4,"operators":[{"key":"SFR","label":"SFR","color":"#E2001A"}]},
     {"id":"t5","source":"manual","startTime":"2026-09-08T11:32:00.000Z","duration":24300,"totalPoints":2121,"distance":97.4,
      "avgSignalStrength":-94.1,"operators":[{"key":"SFR","label":"SFR","color":"#E2001A"}]},
     {"id":"d2","source":"drive_test","startTime":"2026-09-06T10:20:00.000Z","duration":4200,"totalPoints":410,"distance":52.3,
      "avgSignalStrength":-104.6,"operators":[{"key":"BOUYGUES","label":"Bouygues Telecom","color":"#009DDC"},
      {"key":"FREE","label":"Free Mobile","color":"#CD1E25"}]},
     {"id":"d1","source":"drive_test","startTime":"2026-09-05T15:40:00.000Z","totalPoints":0,
      "driveSummary":{"testCount":3,"downloadAvgMbps":245.3},"operators":[{"key":"FREE","label":"Free Mobile","color":"#CD1E25"}]},
     {"id":"n1","name":"Tournée du plateau","source":"manual","startTime":"2026-09-02T07:05:00.000Z","duration":3000,
      "totalPoints":640,"distance":33.6,"avgSignalStrength":-89.4,"operators":[{"key":"SFR","label":"SFR","color":"#E2001A"},
      {"key":"ORANGE","label":"Orange","color":"#FF7900"},{"key":"FREE","label":"Free Mobile","color":"#CD1E25"}]},
     {"id":"i1","source":"ios","startTime":"2026-09-01T09:00:00.000Z","duration":900,"totalPoints":120,"distance":4.2,
      "avgSignalStrength":0,"operators":[{"key":"ORANGE","label":"Orange","color":"#FF7900"}]}
    ],"pagination":{"hasMore":false,"total":111}}
    """

    private func sessions() throws -> [String: CoverageSession] {
        let page = try JSONDecoder.signalQuest.decode(SessionsListResponse.self, from: Data(Self.pageJSON.utf8))
        return Dictionary(uniqueKeysWithValues: page.sessions.map { ($0.id, $0) })
    }

    /// La distance et la durée en titre, plus « Couverture » ni « 2 348 points » ; un nom donné passe
    /// devant et la distance descend d'une ligne ; un Drive Test sans tracé dit ses tests.
    func testHeadlineIsDistanceAndDurationUnlessTheTripIsNamed() throws {
        let rows = try sessions()
        let t1 = try XCTUnwrap(rows["t1"])
        XCTAssertEqual(SessionRow.headline(t1), "\(SQUnits.distance(kilometers: 27.9)) · 1 h 43")
        XCTAssertNil(SessionRow.detailLine(t1))
        XCTAssertEqual(SessionRow.headline(try XCTUnwrap(rows["t4"])), "\(SQUnits.distance(kilometers: 168.6)) · 7 h 53")
        let named = try XCTUnwrap(rows["n1"])
        XCTAssertEqual(SessionRow.headline(named), "Tournée du plateau")
        XCTAssertEqual(SessionRow.detailLine(named), "\(SQUnits.distance(kilometers: 33.6)) · 50 min")
        XCTAssertEqual(SessionRow.headline(try XCTUnwrap(rows["d1"])), String(localized: "\(3) test"))
    }

    /// Les seuils de la carte (−80, −90, −100, −110) ; rien sans RSRP (couverture iOS) ; le débit
    /// moyen pour un Drive Test connu par son récap.
    func testQualityFollowsTheMapScale() throws {
        let rows = try sessions()
        XCTAssertEqual(SessionRow.quality(of: try XCTUnwrap(rows["t1"])), .signal(.fair))
        XCTAssertEqual(SessionRow.quality(of: try XCTUnwrap(rows["t2"])), .signal(.excellent))
        XCTAssertEqual(SessionRow.quality(of: try XCTUnwrap(rows["t5"])), .signal(.fair))
        XCTAssertEqual(SessionRow.quality(of: try XCTUnwrap(rows["n1"])), .signal(.good))
        XCTAssertEqual(SessionRow.quality(of: try XCTUnwrap(rows["d1"])), .throughput(245.3))
        XCTAssertEqual(SessionRow.quality(of: try XCTUnwrap(rows["d2"])), .signal(.weak))
        XCTAssertNil(SessionRow.quality(of: try XCTUnwrap(rows["i1"])), "une couverture iOS n'a pas de RSRP")
    }

    /// Deux opérateurs, puis « +1 » ; « Bouygues » quand le nom complet ne tient pas.
    func testOperatorsShowTwoThenACount() throws {
        let rows = try sessions()
        let three = SessionRow.visibleOperators(try XCTUnwrap(rows["n1"]).operators)
        XCTAssertEqual(three.shown.map(\.key), ["SFR", "ORANGE"])
        XCTAssertEqual(three.overflow, 1)
        let pair = try XCTUnwrap(rows["t2"]).operators
        XCTAssertEqual(SessionRow.visibleOperators(pair).overflow, 0)
        XCTAssertEqual(pair.map(SessionRow.shortLabel), ["Orange", "Bouygues"])
        XCTAssertEqual(SessionRow.shortLabel(SessionOperator(key: "XYZ", label: "Opérateur local", colorHex: nil, count: nil)),
                       "Opérateur local")
    }

    /// VoiceOver lit la ligne dans l'ordre : jour et heure, distance et durée, type, opérateurs
    /// en entier, qualité. Ni points ni dBm, comme à l'écran.
    func testAccessibilityTextReadsTheRow() throws {
        guard Bundle.main.preferredLocalizations.first == "fr" else { throw XCTSkip("textes français seulement") }
        let rows = try sessions()
        let t2 = SessionRow.accessibilityText(try XCTUnwrap(rows["t2"]))
        XCTAssertTrue(t2.hasPrefix("jeudi 19 novembre"), t2)
        XCTAssertTrue(t2.contains("9,1 km · 39 min. Orange, Bouygues Telecom. Signal excellent"), t2)
        XCTAssertFalse(t2.contains("dBm") || t2.contains("points"), t2)
        let drive = SessionRow.accessibilityText(try XCTUnwrap(rows["d1"]))
        XCTAssertTrue(drive.contains("3 tests. Drive Test. Free Mobile. \(SQUnits.throughput(mbps: 245.3)) en moyenne"), drive)
        XCTAssertEqual(SessionsListViewModel.Filter.all.label, "Tous")
    }

    /// Captures de revue : la page entière dans une vraie fenêtre, clair, sombre, AX, et sur 320 pt
    /// (iPad en Split View) pour le pire cas : Drive Test, Bouygues Telecom et Free Mobile.
    func testCaptureTripsListForReview() async throws {
        guard let output = ProcessInfo.processInfo.environment["SQ_TRIPS_SHOTS"] else {
            throw XCTSkip("SQ_TRIPS_SHOTS absent")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let data = Data(Self.pageJSON.utf8)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        let variants: [(String, ColorScheme, DynamicTypeSize)] = [
            ("clair", .light, .large), ("sombre", .dark, .large), ("ax", .light, .accessibility2), ("etroit", .light, .large),
        ]
        let full = scene.coordinateSpace.bounds
        for (variant, scheme, size) in variants {
            window.frame = variant == "etroit" ? CGRect(x: 0, y: 0, width: 320, height: full.height) : full
            let model = SessionsListViewModel { _, _ in
                try JSONDecoder.signalQuest.decode(SessionsListResponse.self, from: data)
            }
            await model.reload()
            let view = NavigationStack { SessionsListView(model: model) }
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size)
            let host = UIHostingController(rootView: view)
            host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = host
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: output).appendingPathComponent("trajets-\(variant).png"))
        }
    }
}
