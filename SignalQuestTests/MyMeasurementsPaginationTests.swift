import Foundation
import XCTest
@testable import SignalQuest

@MainActor
final class MyMeasurementsPaginationTests: XCTestCase {
    private enum FixtureError: Error { case offline, unexpectedOffset }

    private func page(
        sessionIDs: [String],
        pointID: String?,
        total: Int,
        offset: Int,
        hasMore: Bool,
        summary: (located: Int, returned: Int, step: Int)? = nil
    ) throws -> Data {
        var body: [String: Any] = [
            "sessions": sessionIDs.map { ["id": $0, "source": "drive_test"] },
            "pagination": ["total": total, "limit": 40, "offset": offset, "hasMore": hasMore],
            "mapPoints": pointID.map { [["id": $0, "lat": 48.86, "lng": 2.35]] } ?? [],
        ]
        if let summary {
            body["mapPointSummary"] = [
                "locatedCount": summary.located,
                "returnedCount": summary.returned,
                "sampleStep": summary.step,
                "maxPoints": 30_000,
            ]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    func testFortySessionPagesReplaceRatherThanAccumulateMapPoints() async throws {
        let first = try page(sessionIDs: (0..<40).map { "session-\($0)" }, pointID: "first-point",
            total: 41, offset: 0, hasMore: true, summary: (1, 1, 1))
        let last = try page(sessionIDs: ["session-40"], pointID: "last-point",
            total: 41, offset: 40, hasMore: false, summary: (30_001, 1, 2))
        var requestedOffsets: [Int] = []
        let model = MyMeasurementsViewModel { offset, limit in
            XCTAssertEqual(limit, 40)
            requestedOffsets.append(offset)
            let data: Data
            switch offset {
            case 0: data = first
            case 40: data = last
            default: throw FixtureError.unexpectedOffset
            }
            return try JSONDecoder().decode(SessionsListResponse.self, from: data)
        }

        await model.load()
        XCTAssertEqual(model.points.map(\.id), ["first-point"])
        XCTAssertEqual(model.pageStart, 1)
        XCTAssertEqual(model.pageEnd, 40)
        XCTAssertEqual(model.totalSessions, 41)
        XCTAssertTrue(model.canGoForward)
        XCTAssertFalse(model.canGoBack)

        await model.nextPage()
        XCTAssertEqual(model.points.map(\.id), ["last-point"])
        XCTAssertEqual(model.pageStart, 41)
        XCTAssertEqual(model.pageEnd, 41)
        XCTAssertTrue(model.pointSummary?.isSampled == true)
        XCTAssertFalse(model.canGoForward)
        XCTAssertTrue(model.canGoBack)

        await model.previousPage()
        XCTAssertEqual(model.points.map(\.id), ["first-point"])
        XCTAssertEqual(requestedOffsets, [0, 40, 0])
    }

    func testFailedNextPageKeepsPreviousMapAndCanRetry() async throws {
        let first = try page(sessionIDs: (0..<40).map { "session-\($0)" }, pointID: "first-point",
            total: 41, offset: 0, hasMore: true)
        let last = try page(sessionIDs: ["session-40"], pointID: nil,
            total: 41, offset: 40, hasMore: false)
        var failNext = true
        let model = MyMeasurementsViewModel { offset, _ in
            if offset == 40 && failNext { throw FixtureError.offline }
            return try JSONDecoder().decode(SessionsListResponse.self, from: offset == 0 ? first : last)
        }

        await model.load()
        XCTAssertNil(model.pointSummary, "An older API response must remain decodable")
        await model.nextPage()
        XCTAssertEqual(model.points.map(\.id), ["first-point"])
        XCTAssertEqual(model.pageOffset, 0)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.canGoForward)

        failNext = false
        await model.nextPage()
        XCTAssertEqual(model.pageOffset, 40)
        XCTAssertTrue(model.points.isEmpty, "A page with no locations must not borrow the previous map")
        XCTAssertEqual(model.sessionCount, 1)
        XCTAssertNil(model.errorMessage)
    }

    func testInitialFailureIsNotReportedAsARealEmptyHistory() async {
        let model = MyMeasurementsViewModel { _, _ in throw FixtureError.offline }

        await model.load()
        XCTAssertFalse(model.hasLoaded)
        XCTAssertNil(model.totalSessions)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.points.isEmpty)
    }
}
