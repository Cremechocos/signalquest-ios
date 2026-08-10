import XCTest
@testable import SignalQuest

/// Débit crête en fenêtre nPerf (moyenne de la meilleure fenêtre glissante
/// couvrant 30 % de la durée).
///
/// ⚠️ Le vecteur `shared*` ci-dessous est PARTAGÉ avec Android
/// (`SpeedtestPeakWindowTest.kt`) : mêmes échantillons, même attendu. Deux
/// implémentations séparées qui divergeraient rendraient les max des deux apps
/// incomparables sans que rien ne le signale — le défaut même qu'on corrige
/// vis-à-vis de nPerf.
final class SpeedtestPeakWindowTests: XCTestCase {

    private let tickMs: Double = 150
    private let durationMs: Double = 10_000

    private func bytes(mbps: Double, ms: Double) -> Int {
        Int(mbps * 1_000_000 / 8 * (ms / 1_000))
    }

    /// Trace de 10 s à 150 ms, plate à 100 Mb/s, avec une rafale de 600 ms à 800.
    private func burstBox() -> SpeedtestSamplesBox {
        let box = SpeedtestSamplesBox()
        var t: Double = 0
        while t + tickMs <= durationMs {
            let mbps = (t >= 4_200 && t < 4_800) ? 800.0 : 100.0
            box.append(start: t, end: t + tickMs, bytes: bytes(mbps: mbps, ms: tickMs))
            t += tickMs
        }
        return box
    }

    func testShortBurstNoLongerInflatesPeak() {
        let box = burstBox()
        let peak = box.nperfPeakMbps(usefulDurationMs: durationMs, flooredAt: 0)

        // Fenêtre de 3 s : la rafale de 600 ms n'occupe qu'un cinquième de la
        // meilleure fenêtre, elle ne peut donc pas porter le pic à 800.
        XCTAssertLessThan(peak, 300, "pic=\(peak) devrait rester bien sous la rafale (800)")
        XCTAssertGreaterThan(peak, 100, "pic=\(peak) devrait dépasser le palier (100)")

        // L'ancienne définition (max des fenêtres d'1 s) montait, elle, très haut.
        let oldPeak = box.publicStats(
            windowMs: 1_000, graceMs: 0, endMs: durationMs
        ).peak
        XCTAssertGreaterThan(oldPeak, peak, "ancien pic=\(oldPeak) vs nouveau=\(peak)")
    }

    func testStableLinkGivesPeakEqualToAverage() {
        let box = SpeedtestSamplesBox()
        for i in 0..<60 {
            let t = Double(i) * tickMs
            box.append(start: t, end: t + tickMs, bytes: bytes(mbps: 100, ms: tickMs))
        }
        XCTAssertEqual(box.nperfPeakMbps(usefulDurationMs: durationMs, flooredAt: 0), 100, accuracy: 1)
    }

    func testTestShorterThanWindowFallsBackToAverageNotZero() {
        let box = SpeedtestSamplesBox()
        box.append(start: 0, end: tickMs, bytes: bytes(mbps: 100, ms: tickMs))
        XCTAssertEqual(
            box.nperfPeakMbps(usefulDurationMs: durationMs, flooredAt: 42),
            42, accuracy: 0.001,
            "sans fenêtre pleine, la moyenne est la meilleure réponse"
        )
    }

    func testWindowNeverGoesBelowOneSecond() {
        // Durée utile de 2 s → 30 % = 600 ms, sous le plancher : on doit retomber
        // sur 1 s, sinon la sensibilité aux rafales revient par la petite porte.
        let box = burstBox()
        let short = box.nperfPeakMbps(usefulDurationMs: 2_000, flooredAt: 0)
        let atFloor = box.publicStats(windowMs: 1_000, graceMs: 0, endMs: durationMs).peak
        XCTAssertEqual(short, atFloor, accuracy: 0.5, "600 ms doit être remontée à 1 s")
    }

    /// Vecteur partagé avec Android — ne pas modifier d'un seul côté.
    func testSharedVectorWithAndroid() {
        let box = SpeedtestSamplesBox()
        // 4 s à 250 ms : 200 Mb/s, puis 400 sur [1000, 2000), puis 200.
        for i in 0..<16 {
            let start = Double(i) * 250
            let mbps = (start >= 1_000 && start < 2_000) ? 400.0 : 200.0
            box.append(start: start, end: start + 250, bytes: bytes(mbps: mbps, ms: 250))
        }
        // Fenêtre = max(1000, 4000 × 0,30) = 1200 ms. La meilleure fenêtre pleine
        // couvre la totalité du palier à 400 (1000 ms) plus 200 ms à 200 Mb/s :
        // (400×1000 + 200×200) / 1200 = 366,67 Mb/s.
        XCTAssertEqual(
            box.nperfPeakMbps(usefulDurationMs: 4_000, flooredAt: 0),
            366.67, accuracy: 0.01
        )
    }
}
