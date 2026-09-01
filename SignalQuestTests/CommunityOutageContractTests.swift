import XCTest
@testable import SignalQuest

final class CommunityOutageContractTests: XCTestCase {
    private func contract() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/community-outage-v1.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testIOSMatchesTheSharedCommunityOutageContract() throws {
        let contract = try contract()
        XCTAssertEqual(contract["schema"] as? String, "signalquest.community-outage.contract")
        XCTAssertEqual(contract["version"] as? Int, 1)
        let states = try XCTUnwrap(contract["states"] as? [String: Any])
        XCTAssertEqual(states["open"] as? [String], ["reported", "confirmed", "dormant"])
        XCTAssertEqual(states["visible"] as? [String], ["reported", "confirmed"])

        let samples = try XCTUnwrap(contract["samples"] as? [String: Any])
        let report = try XCTUnwrap(samples["report"] as? [String: Any])
        var draft = OutageReportDraft()
        draft.select(.degraded)
        draft.affectsData = report["affectsData"] as? Bool ?? false
        draft.affectsVoice = report["affectsVoice"] as? Bool ?? false
        draft.technologies = Set(report["affectedTechnologies"] as? [String] ?? [])
        draft.bands = Set(report["affectedBands"] as? [String] ?? [])
        draft.sectors = Set(report["affectedSectors"] as? [Int] ?? [])
        draft.comment = report["comment"] as? String ?? ""
        let reportRequest = try XCTUnwrap(draft.request(
            targetKind: try XCTUnwrap(report["targetKind"] as? String),
            targetId: try XCTUnwrap(report["targetId"] as? String),
            marketCode: try XCTUnwrap(report["marketCode"] as? String),
            operatorKey: try XCTUnwrap(report["operatorKey"] as? String),
            latitude: report["latitude"] as? Double,
            longitude: report["longitude"] as? Double,
            accuracyMeters: report["accuracyMeters"] as? Double,
            deviceId: report["deviceId"] as? String,
            observedAt: report["observedAt"] as? String
        ))
        let encodedReport = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(reportRequest)) as? [String: Any]
        )
        for key in ["targetKind", "targetId", "marketCode", "operatorKey", "severity", "deviceId", "observedAt"] {
            XCTAssertEqual(encodedReport[key] as? String, report[key] as? String, key)
        }
        XCTAssertEqual(encodedReport["affectsSms"] as? Bool, report["affectsSms"] as? Bool)

        let vote = try XCTUnwrap(samples["vote"] as? [String: Any])
        let voteRequest = OutageVoteRequest(
            kind: try XCTUnwrap(vote["kind"] as? String),
            deviceId: try XCTUnwrap(vote["deviceId"] as? String),
            latitude: vote["latitude"] as? Double,
            longitude: vote["longitude"] as? Double,
            accuracyMeters: vote["accuracyMeters"] as? Double
        )
        let encodedVote = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(voteRequest)) as? [String: Any]
        )
        XCTAssertEqual(encodedVote["deviceId"] as? String, vote["deviceId"] as? String)

        for code in contract["writeErrorCodes"] as? [String] ?? [] {
            XCTAssertNotNil(OutageWriteError.phrase(forCode: code), "Code sans phrase iOS: \(code)")
        }
    }
}
