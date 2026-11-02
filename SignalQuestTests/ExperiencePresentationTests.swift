import XCTest
@testable import SignalQuest

/// Présentation commune des tests d'expérience : le vecteur `presentation-v1`
/// (copie à l'octet de contracts/experience-tests/presentation-v1.json, map-nextjs
/// 6428dad08, servi le 02/11) rejoué dans les deux langues.
final class ExperiencePresentationTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/experience-tests/presentation-v1.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCatalogMatchesTheContract() throws {
        let texts = try XCTUnwrap(try vector()["texts"] as? [String: [String: Any]])
        XCTAssertEqual(Set(texts.keys), Set(ExperiencePresentation.texts.keys))
        for (key, served) in texts {
            let entry = try XCTUnwrap(ExperiencePresentation.texts[key], key)
            XCTAssertEqual(served["fr"] as? String, entry.fr, key)
            XCTAssertEqual(served["en"] as? String, entry.en, key)
            XCTAssertEqual(served["args"] as? [String: String] ?? [:], entry.args.mapValues(\.rawValue), key)
            XCTAssertEqual(served["local"] as? Bool ?? false, entry.local, key)
        }
        let rules = try XCTUnwrap(try vector()["rules"] as? [String: Any])
        XCTAssertEqual(rules["shareMaxChars"] as? Int, ExperiencePresentation.shareMaxChars)
        XCTAssertEqual(rules["adaptivePlannedS"] as? Int, ExperiencePresentation.adaptivePlannedS)
    }

    /// Les débits du catalogue et ceux du reste de l'app (`SQUnits`) suivent la même règle.
    func testRatesFollowTheCommonRule() throws {
        let rates = try XCTUnwrap(try vector()["rates"] as? [[String: Any]])
        XCTAssertFalse(rates.isEmpty)
        for rate in rates {
            let kbps = try XCTUnwrap(rate["kbps"] as? Int)
            for language in ExperienceShareLanguage.allCases {
                let expected = try XCTUnwrap(rate[language.rawValue] as? String)
                XCTAssertEqual(ExperiencePresentation.format(.rate, .int(kbps), language), expected, "\(kbps) \(language)")
                XCTAssertEqual(SQUnits.throughput(mbps: Double(kbps) / 1_000, locale: language.locale), expected, "SQUnits \(kbps) \(language)")
            }
        }
    }

    func testSpikeThresholds() throws {
        let spikes = try XCTUnwrap(try vector()["spikes"] as? [String: Any])
        let thresholds = try XCTUnwrap(spikes["thresholds"] as? [[String: Any]])
        XCTAssertFalse(thresholds.isEmpty)
        for item in thresholds {
            let median = try XCTUnwrap(item["medianMs"] as? Int), methodology = try XCTUnwrap(item["methodology"] as? String)
            XCTAssertEqual(ExperiencePresentation.spikeThresholdMs(medianMs: median, methodology: methodology),
                           item["thresholdMs"] as? Int, "\(median) \(methodology)")
        }
    }

    func testGameVerdictsAndCaps() throws {
        let verdicts = try XCTUnwrap(try vector()["gameVerdicts"] as? [[String: Any]])
        XCTAssertFalse(verdicts.isEmpty)
        for item in verdicts {
            let name = item["name"] as? String ?? "?"
            let verdict = ExperiencePresentation.gameVerdict(try XCTUnwrap(item["game"] as? [String: Any], name))
            XCTAssertEqual(verdict?.rawValue, item["verdict"] as? String, name)
            XCTAssertEqual(verdict?.scoreCap, item["scoreCap"] as? Int, name)
        }
    }

    func testCases() throws {
        let cases = try XCTUnwrap(try vector()["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for vector in cases {
            let name = vector["name"] as? String ?? "?"
            let tests = vector["tests"] as? [String: Any] ?? [:]
            let methodology = try XCTUnwrap(vector["methodology"] as? String, name)
            let expected = try XCTUnwrap(vector["expected"] as? [String: [String: Any]], name)
            let uses = ExperiencePresentation.uses(tests: tests, methodology: methodology)
            for use in ExperiencePresentation.Use.allCases {
                let label = "\(name) · \(use.rawValue)"
                let want = try XCTUnwrap(expected[use.rawValue], label)
                let got = try XCTUnwrap(uses[use], label)
                XCTAssertEqual(got.state, want["state"] as? String, label)
                XCTAssertEqual(got.score, want["score"] as? Int, "\(label) · score")
                try assertTexts(got.lines, want["lines"], label: "\(label) · lines")
                try assertTexts(got.keyValue.map { [$0] } ?? [], (want["keyValue"] as? [String: Any]).map { [$0] } ?? [], label: "\(label) · keyValue")
                try assertTexts(got.detail, want["detail"], label: "\(label) · detail")
                try assertTexts([got.share], [want["share"] as Any], label: "\(label) · share")
                XCTAssertLessThanOrEqual(got.share.rendered(.fr).count, ExperiencePresentation.shareMaxChars, label)
                XCTAssertLessThanOrEqual(got.share.rendered(.en).count, ExperiencePresentation.shareMaxChars, label)
            }
        }
    }

    private func assertTexts(_ got: [ExperiencePresentation.Text], _ want: Any?, label: String) throws {
        let want = (want as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        XCTAssertEqual(got.map(\.key), want.compactMap { $0["key"] as? String }, label)
        for (text, served) in zip(got, want) {
            XCTAssertEqual(text.rendered(.fr), served["fr"] as? String, "\(label) · fr")
            XCTAssertEqual(text.rendered(.en), served["en"] as? String, "\(label) · en")
        }
    }

    /// Un test ancien, sans verdict ni plafond servi : la note du jeu est plafonnée à la lecture.
    func testGameScoreIsCappedByItsVerdict() {
        let tests: [String: Any] = ["gameAndCalls": ["state": "measured", "medianMs": 60, "jitterMs": 5, "maxMs": 120, "spikeCount": 0, "spikeShare": 0]]
        XCTAssertEqual(ExperiencePresentation.gameVerdict(tests["gameAndCalls"] as! [String: Any]), .casual)
        XCTAssertEqual(ExperienceScores(tests: tests).gameAndCalls, 85)
    }
}
