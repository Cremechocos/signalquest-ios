import XCTest
@testable import SignalQuest

@MainActor
final class SessionGenerationClassificationTests: XCTestCase {
    func testKnownUnknownAndExplicitNoServiceStaySeparate() {
        XCTAssertEqual(SessionDetailViewModel.generationKey("4G"), "4G")
        XCTAssertEqual(SessionDetailViewModel.generationKey("LTE"), "4G")
        XCTAssertEqual(SessionDetailViewModel.generationKey("Inconnu"), "Inconnu")
        XCTAssertEqual(SessionDetailViewModel.generationKey(nil), "Inconnu")
        XCTAssertEqual(SessionDetailViewModel.generationKey("Aucun"), "Aucun")
        XCTAssertEqual(SessionDetailViewModel.generationKey("no service"), "Aucun")
    }
}

/// Chargement progressif du détail d'une session (pages par curseur).
@MainActor
final class SessionDetailProgressiveLoadingTests: XCTestCase {
    private final class PagedSessions: SessionsServicing, @unchecked Sendable {
        var firstPages: [String]
        var nextPages: [String: Result<String, APIError>]
        private(set) var requestedCursors: [String] = []
        private(set) var firstPageLimits: [Int] = []

        init(firstPages: [String], nextPages: [String: Result<String, APIError>]) {
            self.firstPages = firstPages
            self.nextPages = nextPages
        }

        func sessions(offset: Int, limit: Int, mapPoints: Bool) async throws -> SessionsListResponse {
            throw APIError.cancelled
        }

        func sessionDetail(id: String) async throws -> CoverageSessionDetail {
            throw APIError.cancelled
        }

        func sessionDetail(id: String, pageLimit: Int) async throws -> CoverageSessionDetail {
            firstPageLimits.append(pageLimit)
            let json = firstPages.count > 1 ? firstPages.removeFirst() : firstPages[0]
            return try JSONDecoder().decode(CoverageSessionDetail.self, from: Data(json.utf8))
        }

        func sessionPoints(id: String, after cursor: String, limit: Int) async throws -> SessionPointsPageResponse {
            requestedCursors.append(cursor)
            switch nextPages[cursor] {
            case .success(let json)?:
                return try JSONDecoder().decode(SessionPointsPageResponse.self, from: Data(json.utf8))
            case .failure(let error)?:
                throw error
            case nil:
                XCTFail("Curseur inattendu \(cursor)")
                throw APIError.cancelled
            }
        }
    }

    private static func point(_ id: String, tech: String = "4G", enb: String? = nil, cellId: String? = nil) -> String {
        var fields = ["\"id\":\"\(id)\"", "\"latitude\":45.1", "\"longitude\":5.7", "\"technology\":\"\(tech)\""]
        if let enb { fields.append("\"enb\":\"\(enb)\"") }
        if let cellId { fields.append("\"cellId\":\"\(cellId)\"") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private static func firstPage(_ points: [String], cursor: String?, extra: String = "") -> String {
        let page = cursor.map { "\"page\":{\"limit\":2,\"returned\":\(points.count),\"nextCursor\":\"\($0)\",\"fields\":\"detail\"}" }
            ?? "\"page\":{\"limit\":2,\"returned\":\(points.count),\"nextCursor\":null,\"fields\":\"detail\"}"
        return """
        {"session":{"id":"s1","rawTotalPoints":5,"excludedPoints":1,\(extra)"points":[\(points.joined(separator: ","))]},\(page)}
        """
    }

    private static func nextPage(_ points: [String], cursor: String?) -> String {
        let next = cursor.map { "\"\($0)\"" } ?? "null"
        return """
        {"session":{"id":"s1","points":[\(points.joined(separator: ","))]},"page":{"limit":2,"returned":\(points.count),"nextCursor":\(next),"fields":"detail"}}
        """
    }

    private func makeModel() throws -> SessionDetailViewModel {
        let session = try JSONDecoder().decode(CoverageSession.self, from: Data(#"{"id":"s1"}"#.utf8))
        return SessionDetailViewModel(session: session)
    }

    func testPagesAreAppendedInOrderWithoutDuplicatesAndTheServerBreakdownCoversTheWholeSession() async throws {
        let service = PagedSessions(
            firstPages: [Self.firstPage([Self.point("p1"), Self.point("p2")], cursor: "c1",
                extra: #""technologyBreakdown":[{"technology":"5G","points":3,"logicalPoints":2},{"technology":"4G","points":1,"logicalPoints":1}],"#)],
            nextPages: [
                "c1": .success(Self.nextPage([Self.point("p2"), Self.point("p3")], cursor: "c2")),
                "c2": .success(Self.nextPage([Self.point("p4")], cursor: nil))
            ]
        )
        let model = try makeModel()
        await model.load(service: service)

        XCTAssertEqual(service.firstPageLimits, [SessionDetailViewModel.firstPageLimit])
        XCTAssertEqual(service.requestedCursors, ["c1", "c2"])
        XCTAssertEqual(model.detail?.points.map(\.id), ["p1", "p2", "p3", "p4"], "p2 n'est pas doublé")
        XCTAssertEqual(model.detail?.expectedPointRows, 4)
        XCTAssertFalse(model.isLoadingMorePoints)
        XCTAssertNil(model.errorMessage)
        let shares = model.generationBreakdown
        XCTAssertEqual(shares.map(\.generation), ["5G", "4G"], "Répartition du serveur, pas celle des points chargés")
        XCTAssertEqual(shares.first?.count, 3)
        XCTAssertEqual(shares.first?.pct ?? 0, 75, accuracy: 0.001)
    }

    func testACursorCycleStopsAndAFullyLoadedSessionIsNotReloaded() async throws {
        let cycling = PagedSessions(
            firstPages: [Self.firstPage([Self.point("p1")], cursor: "c1")],
            nextPages: [
                "c1": .success(Self.nextPage([Self.point("p2")], cursor: "c2")),
                "c2": .success(Self.nextPage([Self.point("p3")], cursor: "c1"))
            ]
        )
        let model = try makeModel()
        await model.load(service: cycling)
        XCTAssertEqual(cycling.requestedCursors, ["c1", "c2"], "Un curseur déjà servi n'est jamais redemandé")
        XCTAssertEqual(model.detail?.points.map(\.id), ["p1", "p2", "p3"])

        let complete = PagedSessions(
            firstPages: [Self.firstPage([Self.point("p1")], cursor: "c1")],
            nextPages: ["c1": .success(Self.nextPage([Self.point("p2")], cursor: nil))]
        )
        let loaded = try makeModel()
        await loaded.load(service: complete)
        await loaded.load(service: complete)
        XCTAssertEqual(complete.firstPageLimits.count, 1, "Revenir sur l'écran ne recharge pas une session complète")
        XCTAssertEqual(loaded.detail?.points.map(\.id), ["p1", "p2"])
    }

    func testARefusedCursorRestartsOnceFromTheFirstPage() async throws {
        let refused = APIError.http(status: 400, code: "INVALID_CURSOR", message: "Curseur invalide", requestId: nil, retryAfter: nil)
        let service = PagedSessions(
            firstPages: [
                Self.firstPage([Self.point("p1")], cursor: "old"),
                Self.firstPage([Self.point("p1")], cursor: "new")
            ],
            nextPages: [
                "old": .failure(refused),
                "new": .success(Self.nextPage([Self.point("p2")], cursor: nil))
            ]
        )
        let model = try makeModel()
        await model.load(service: service)

        XCTAssertEqual(service.requestedCursors, ["old", "new"])
        XCTAssertEqual(model.detail?.points.map(\.id), ["p1", "p2"])
        XCTAssertNil(model.errorMessage)
    }

    func testAServerWithoutPaginationIsReadAsOneCompleteResponse() async throws {
        let legacy = #"{"session":{"id":"s1","points":[{"id":"p1","latitude":45.1,"longitude":5.7,"technology":"4G"}]}}"#
        let service = PagedSessions(firstPages: [legacy], nextPages: [:])
        let model = try makeModel()
        await model.load(service: service)

        XCTAssertTrue(service.requestedCursors.isEmpty)
        XCTAssertEqual(model.detail?.points.map(\.id), ["p1"])
        XCTAssertEqual(model.generationBreakdown.map(\.generation), ["4G"], "Repli sur les points sans répartition serveur")
    }

    func testIdentificationSampleOnlyComesFromThePointsOfThatAntenna() throws {
        let json = """
        {"session":{"id":"s1","points":[\(Self.point("other", enb: "999")),\(Self.point("node", enb: "123", cellId: "1")),\(Self.point("cell", enb: "123", cellId: "2"))]},
         "servingAntennas":[
          {"id":"a","ok":true,"result":{"antenna":{"latitude":45.1,"longitude":5.7,"supId":"S1","enb":"123","cellId":"2"}}},
          {"id":"b","ok":true,"result":{"antenna":{"latitude":45.1,"longitude":5.7,"supId":"S2","enb":"555"}}}
         ]}
        """
        let detail = try JSONDecoder().decode(CoverageSessionDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.servingAntennas.count, 2)
        let points = detail.points
        XCTAssertEqual(SessionDetailViewModel.sample(for: detail.servingAntennas[0], in: points)?.id, "cell")
        XCTAssertNil(SessionDetailViewModel.sample(for: detail.servingAntennas[1], in: points),
                     "Jamais le premier point radio d'un autre nœud")
    }

    /// « Voir la session » : la première page déjà reçue n'est pas redemandée, la session
    /// entière part en mémoire, et rouverte depuis la mémoire elle ne coûte aucune requête.
    func testASharedSessionReusesItsFirstPageAndIsRememberedWhole() async throws {
        let first = try JSONDecoder().decode(CoverageSessionDetail.self, from: Data(Self.firstPage([Self.point("p1")], cursor: "c1").utf8))
        let service = PagedSessions(firstPages: [Self.firstPage([], cursor: nil)],
                                    nextPages: ["c1": .success(Self.nextPage([Self.point("p2")], cursor: nil))])
        var remembered: CoverageSessionDetail?
        let model = SessionDetailViewModel(preloaded: first, complete: false)
        model.onComplete = { remembered = $0 }
        await model.load(service: service)

        XCTAssertEqual(service.firstPageLimits, [], "première page reçue avant d'ouvrir le détail")
        XCTAssertEqual(service.requestedCursors, ["c1"])
        XCTAssertEqual(remembered?.points.map(\.id), ["p1", "p2"])

        let reopened = SessionDetailViewModel(preloaded: try XCTUnwrap(remembered), complete: true)
        await reopened.load(service: service)
        XCTAssertEqual(service.firstPageLimits, [])
        XCTAssertEqual(service.requestedCursors, ["c1"], "rien de redemandé")
        XCTAssertEqual(reopened.detail?.points.count, 2)
    }

    /// Une session gardée en mémoire expire au bout de cinq minutes : dépubliée entre-temps,
    /// elle n'est pas resservie, la réouverture repasse par le serveur.
    func testRememberedSessionExpires() throws {
        var account: String? = "user:a|s"
        let memory = SharedSessionMemory(account: { account })
        let detail = try JSONDecoder().decode(CoverageSessionDetail.self, from: Data(Self.firstPage([Self.point("p1")], cursor: nil).utf8))
        let start = Date()
        memory.remember(detail, for: "s1", now: start)
        account = "user:b|s"
        XCTAssertNil(memory.detail(for: "s1", now: start), "jamais servie à un autre compte")
        account = "user:a|s"
        XCTAssertNotNil(memory.detail(for: "s1", now: start.addingTimeInterval(SharedSessionMemory.lifetime - 1)))
        XCTAssertNil(memory.detail(for: "s1", now: start.addingTimeInterval(SharedSessionMemory.lifetime)))
    }

    /// 404 et limite de lecture se disent différemment : un membre à la limite ne doit pas
    /// lire « plus publique » et croire la session supprimée.
    func testSharedSessionErrorsTellNotPublicFromRateLimit() {
        func http(_ status: Int, _ retryAfter: Int?) -> APIError {
            .http(status: status, code: nil, message: "", requestId: nil, retryAfter: retryAfter)
        }
        let notPublic = SharedSessionDetailView.message(for: http(404, nil))
        XCTAssertEqual(notPublic, String(localized: "Cette session n’est plus publique."))
        let seconds = SharedSessionDetailView.message(for: http(429, 20))
        XCTAssertEqual(seconds, String(localized: "Trop de sessions ouvertes. Réessaie dans \(20) s."))
        XCTAssertEqual(SharedSessionDetailView.message(for: http(429, 300)),
                       String(localized: "Trop de sessions ouvertes. Réessaie dans \(5) min."))
        XCTAssertEqual(SharedSessionDetailView.message(for: http(429, 40_000)),
                       String(localized: "Trop de sessions ouvertes aujourd’hui. Réessaie plus tard."))
        XCTAssertNotEqual(notPublic, seconds)
    }
}
