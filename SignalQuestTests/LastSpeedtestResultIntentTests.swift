import XCTest
@testable import SignalQuest

/// « Dernier résultat » pour Siri et Raccourcis (plan 3, vague 1). La phrase
/// dépend de la langue du test : on vérifie les valeurs, pas les mots.
final class LastSpeedtestResultIntentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSummaryGivesEveryMeasuredValueAndTheNetwork() {
        let snapshot = SpeedtestWidgetSnapshot(
            downloadMbps: 245.4, uploadMbps: 47.6, pingMs: 18.2,
            network: "Orange", label: "5G", date: now.addingTimeInterval(-7_200)
        )
        let summary = LastSpeedtestResultIntent.summary(of: snapshot, now: now)
        XCTAssertTrue(summary.contains("245"), summary)
        XCTAssertTrue(summary.contains("48"), summary)
        XCTAssertTrue(summary.contains("18"), summary)
        XCTAssertTrue(summary.contains("Orange"), summary)
        let when = RelativeDateTimeFormatter().localizedString(for: snapshot.date, relativeTo: now)
        XCTAssertTrue(summary.contains(when), summary)
    }

    func testSummaryLeavesOutWhatWasNotMeasured() {
        let snapshot = SpeedtestWidgetSnapshot(
            downloadMbps: 12, uploadMbps: nil, pingMs: nil, network: "Wi-Fi", label: "Wi-Fi", date: now
        )
        let summary = LastSpeedtestResultIntent.summary(of: snapshot, now: now)
        XCTAssertTrue(summary.contains("12"), summary)
        XCTAssertEqual(summary.components(separatedBy: ", ").count, 1, "Ni envoi ni latence inventés : \(summary)")
    }
}
