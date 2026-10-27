import XCTest
@testable import SignalQuest

/// Barème `experience-score-v1` (méthode v3, §9) : rejoué à l'identique par le serveur et
/// les trois apps sur les vecteurs communs.
final class ExperienceScoreTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testSharedScoreVectors() throws {
        let vectors = try fixture("experience-score-v1-vectors")
        XCTAssertEqual(vectors["scoreScale"] as? String, ExperienceScores.scale)
        let cases = try XCTUnwrap(vectors["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 13)
        for vector in cases {
            let name = vector["name"] as? String ?? "?"
            let expected = try XCTUnwrap(vector["expected"] as? [String: Any], name)
            func value(_ key: String) -> Int? { (expected[key] as? NSNumber)?.intValue }
            let scores = ExperienceScores(tests: vector["tests"] as? [String: Any] ?? [:])
            XCTAssertEqual(scores, ExperienceScores(
                videoLadder: value("videoLadder"), videoAdaptive: value("videoAdaptive"), video: value("video"),
                webPage: value("webPage"), gameAndCalls: value("gameAndCalls"), upload: value("upload"), overall: value("overall")
            ), name)
        }
    }

    func testRoundingIsHalfUpOnceAfterSixDecimals() {
        XCTAssertEqual(ExperienceScores.final(59.5), 60)
        XCTAssertEqual(ExperienceScores.final(100 * 2975 / 5000), 60, "100 × 2975 ÷ 5000 vaut 59,499… en flottant")
        XCTAssertEqual(ExperienceScores.final(59.4999994), 59)
        XCTAssertEqual(ExperienceScores.mean([0, 45]), 23)
        XCTAssertEqual(ExperienceScores.mean([74, 72, 81, 63]), 73)
    }

    func testALocalRunIsScoredOnTheJitterSentToTheServer() {
        // Gigue 27,5 ms gardée en décimal : le serveur reçoit 28, la note aussi.
        var tests = ExperienceTestsResult()
        tests.gameAndCalls = ExperienceGameResult(state: .measured, probeMethod: "tcp_connect", medianMs: 41, jitterMs: 27.5,
                                                  spikeCount: 0, spikeShare: 0)
        tests.webPage = ExperienceWebResult(state: .measured, openings: [ExperienceWebOpening(measured: true, totalMs: 2_000)])
        let scores = ExperienceScores(tests)
        // (40 × 259/280 + 25 × 22/45 + 15) ÷ 80 × 100 = 80,27… → 80 ; sur 27,5 ms, ce serait 81.
        XCTAssertEqual(scores.gameAndCalls, 80)
        XCTAssertEqual(scores.webPage, 80)
        XCTAssertEqual(scores.overall, 80)
        XCTAssertEqual(scores.ratedUses, 2)
    }

    func testOnlyMeasuredTestsAreScored() {
        var tests = ExperienceTestsResult()
        tests.videoLadder = ExperienceLadderResult(state: .interrupted, rungs: [ExperienceRung(quality: .p1080, state: .measured)])
        tests.videoAdaptive = ExperienceAdaptiveResult(state: .failed)
        tests.upload = ExperienceUploadResult(state: .measured, items: [])
        let scores = ExperienceScores(tests)
        XCTAssertNil(scores.videoLadder)
        XCTAssertNil(scores.video)
        XCTAssertNil(scores.upload, "aucun élément envoyé : pas de note, jamais 0")
        XCTAssertNil(scores.overall)
        XCTAssertTrue(scores.isEmpty)
    }

    func testServedScoresAreReadStrictly() throws {
        let json = #"{"videoLadder":40,"videoAdaptive":null,"video":40,"webPage":101,"gameAndCalls":61.5,"upload":"65","overall":51}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let scores = try XCTUnwrap(ExperienceScores(served: value))
        XCTAssertEqual(scores, ExperienceScores(videoLadder: 40, video: 40, overall: 51))
        XCTAssertNil(ExperienceScores(served: nil))
    }
}
