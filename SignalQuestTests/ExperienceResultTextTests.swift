import XCTest
@testable import SignalQuest

/// Phrases du résultat des tests d'expérience, avec les valeurs de la maquette v3 :
/// seule la valeur mesurée est dite, ce qui n'est pas mesuré l'est aussi.
final class ExperienceResultTextTests: XCTestCase {

    private func rung(_ quality: ExperienceVideoQuality, stalls: Int = 0, startupMs: Int64? = nil) -> ExperienceRung {
        ExperienceRung(quality: quality, state: .measured, startupMs: startupMs,
                       stalls: (0..<stalls).map { ExperienceStall(atPlaybackMs: Int64($0 + 1) * 2_000, waitMs: 300) })
    }

    private func opening(_ totalMs: Int64?) -> ExperienceWebOpening {
        ExperienceWebOpening(measured: totalMs != nil, totalMs: totalMs)
    }

    // MARK: Vidéo

    func testLadderSaysTheBestCleanRungAndTheFirstStall() {
        let result = ExperienceLadderResult(state: .measured, rungs: [
            rung(.p480), rung(.p720), rung(.p1080), rung(.p1440, startupMs: 1_400), rung(.p2160, stalls: 4)
        ])
        let line = ExperienceResultText.ladder(result)
        XCTAssertEqual(line.headline, "Jusqu’à 1440p sans coupure")
        XCTAssertEqual(line.detail, "4K : 4 coupures · démarrage 1,4 s en 1440p")

        let interrupted = ExperienceLadderResult(state: .interrupted, reason: .background, rungs: Array(result.rungs.prefix(4)))
        XCTAssertEqual(ExperienceResultText.ladder(interrupted).headline, "Au moins 1440p sans coupure")
        let stalled = ExperienceLadderResult(state: .measured, rungs: [rung(.p480, stalls: 1)])
        XCTAssertEqual(ExperienceResultText.ladder(stalled).headline, "Coupures dès 480p")
        XCTAssertEqual(ExperienceResultText.ladder(stalled).detail, "480p : 1 coupure")
    }

    func testAdaptiveSaysAverageQualityStallsAndScore() {
        var result = ExperienceAdaptiveResult(state: .measured, playbackMs: 30_000)
        result.timeByQualityMs = [.p720: 30_000]
        result.stalls = [ExperienceStall(atPlaybackMs: 21_000, waitMs: 200)]
        result.score = ExperienceVideoScore(total: 67, quality: 18, smoothness: 29, startup: 20)
        let line = ExperienceResultText.adaptive(result)
        XCTAssertEqual(line.headline, "720p en moyenne, 1 coupure de 200 ms")
        XCTAssertEqual(line.score, 67)
        XCTAssertEqual(line.detail, "Qualité 18/40 · Fluidité 29/40 · Démarrage 20/20 pts")

        result.stalls = []
        XCTAssertEqual(ExperienceResultText.adaptive(result).headline, "720p en moyenne, sans coupure")
        let interrupted = ExperienceAdaptiveResult(state: .interrupted, reason: .networkChanged, playbackMs: 17_400)
        let cut = ExperienceResultText.adaptive(interrupted)
        XCTAssertEqual(cut.headline, "Interrompu à 17 s sur 30 · pas de note")
        XCTAssertNil(cut.score, "pas de note sur une lecture incomplète")
    }

    func testAverageQualityIsWeightedByTime() {
        XCTAssertNil(ExperienceResultText.averageQuality([:]))
        // 20 s en 1080p et 10 s en 480p : 4,5 Mbit/s en moyenne, soit 720p tenu.
        let average = ExperienceResultText.averageQuality([.p1080: 20_000, .p480: 10_000])
        XCTAssertEqual(average?.quality, .p720)
        XCTAssertEqual(average?.bps, 4_500_000)
    }

    // MARK: Web

    func testWebSaysTheMedianOfMeasuredOpenings() {
        let result = ExperienceWebResult(state: .measured, openings: [opening(2_000), opening(2_100), opening(2_300)])
        let line = ExperienceResultText.web(result, failure: nil)
        XCTAssertEqual(line.headline, "Une page type s’ouvre en 2,1 s")
        XCTAssertEqual(line.detail, "Médiane de 3 ouvertures · stable · 0 échec sur 3")

        let uneven = ExperienceWebResult(state: .measured, openings: [opening(1_000), opening(nil), opening(3_000)])
        XCTAssertEqual(ExperienceResultText.web(uneven, failure: nil).detail, "Médiane de 2 ouvertures · irrégulière · 1 échec sur 3")
        let stats = ExperienceResultText.webStats(uneven)
        XCTAssertEqual(stats?.failures, 1)
        // Stable sous 30 % de la médiane, strictement : 600 ms d'écart sur 2 s ne l'est plus.
        XCTAssertEqual(ExperienceResultText.webStats(.init(state: .measured, openings: [opening(2_000), opening(2_000), opening(2_590)]))?.isStable, true)
        XCTAssertEqual(ExperienceResultText.webStats(.init(state: .measured, openings: [opening(2_000), opening(2_000), opening(2_600)]))?.isStable, false)

        let busy = ExperienceWebResult(state: .failed, openings: [opening(nil)])
        XCTAssertEqual(ExperienceResultText.web(busy, failure: .serverBusy).headline, "Échec : serveur de mesure occupé")
        XCTAssertEqual(ExperienceResultText.web(busy, failure: nil).headline, "Échec de la mesure")
    }

    // MARK: Jeu et appels

    func testGameVerdictFollowsTheUsageThresholds() {
        var result = ExperienceGameResult(state: .measured, medianMs: 41, jitterMs: 8.1, maxMs: 187, spikeCount: 4)
        let line = ExperienceResultText.game(result, failure: nil)
        XCTAssertEqual(line.headline, "Convient aux appels vidéo et au jeu occasionnel, pas au jeu compétitif")
        XCTAssertEqual(line.detail, "41 ms · gigue 8,1 ms · 4 à-coups · MAX 187 ms")

        result.spikeCount = 0
        XCTAssertEqual(ExperienceResultText.game(result, failure: nil).headline, "Convient à tous les usages, jeu compétitif compris")
        XCTAssertEqual(ExperienceResultText.gameVerdict(medianMs: 120, jitterMs: 12, spikeCount: 0), "Convient aux appels vidéo, pas au jeu")
        XCTAssertEqual(ExperienceResultText.gameVerdict(medianMs: 250, jitterMs: 40, spikeCount: 9), "Convient aux appels audio seulement")
        XCTAssertEqual(ExperienceResultText.gameVerdict(medianMs: 320, jitterMs: 5, spikeCount: 0),
                       "Latence trop élevée pour le jeu et les appels")
        // Gigue décimale arrondie une fois, demi vers le haut, avant le seuil : 10,5 ms ne tient pas 10 ms.
        XCTAssertEqual(ExperienceResultText.game(ExperienceGameResult(state: .measured, medianMs: 40, jitterMs: 10.5, spikeCount: 0),
                                                 failure: nil).headline,
                       "Convient aux appels vidéo et au jeu occasionnel, pas au jeu compétitif")
    }

    // MARK: Envoi

    func testUploadSaysEachFileAndItsRate() {
        let result = ExperienceUploadResult(state: .measured, items: [
            ExperienceUploadItem(kind: .photo, bytes: 5_000_000, totalMs: 4_600),
            ExperienceUploadItem(kind: .video, bytes: 30_000_000, totalMs: 27_300)
        ])
        let line = ExperienceResultText.upload(result, failure: nil)
        XCTAssertEqual(line.headline, "Photo envoyée en 4,6 s · vidéo de 30 s en 27,3 s")
        XCTAssertEqual(line.detail, "8,7 Mb/s et 8,8 Mb/s en montant")
        XCTAssertEqual(ExperienceResultText.upload(ExperienceUploadResult(state: .interrupted, reason: .userStopped), failure: nil),
                       .init(headline: "Interrompu", detail: "test arrêté"))
    }

    // MARK: États et unités

    func testUnselectedOrUnmeasuredTestsSayNotMeasured() {
        var tests = ExperienceTestsResult()
        XCTAssertEqual(ExperienceResultText.line(.webPage, in: tests).headline, "Non mesuré")
        tests.gameAndCalls = ExperienceGameResult(state: .notTested, reason: .offline)
        XCTAssertEqual(ExperienceResultText.line(.gameAndCalls, in: tests).headline, "Non mesuré")
        tests.gameAndCalls = ExperienceGameResult(state: .failed)
        XCTAssertEqual(ExperienceResultText.line(.gameAndCalls, in: tests, failure: .routeChanged).headline,
                       "Échec : serveur de mesure redirigé")
    }

    func testUnits() {
        XCTAssertEqual(ExperienceResultText.megabytes(109_000_000), "109,0 Mo")
        XCTAssertEqual(ExperienceResultText.duration(seconds: 159), "2\u{00A0}min\u{00A0}39\u{00A0}s")
        XCTAssertEqual(ExperienceResultText.duration(seconds: 58), "58\u{00A0}s")
        XCTAssertEqual(ExperienceResultText.about(seconds: 150), "environ 2\u{00A0}min\u{00A0}30")
        XCTAssertEqual(ExperienceResultText.about(seconds: 125), "environ 2\u{00A0}min\u{00A0}05")
        XCTAssertEqual(ExperienceResultText.about(seconds: 50), "environ 50\u{00A0}s")
        XCTAssertEqual(ExperienceResultText.stalls(1), "1 coupure")
        XCTAssertEqual(ExperienceResultText.waiting(850), "850 ms")
        XCTAssertEqual(ExperienceVideoQuality.p2160.label, "4K")
    }
}
