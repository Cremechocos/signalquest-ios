import XCTest
@testable import SignalQuest

/// Sélection des échantillons ICMP retenus pour la mesure.
///
/// L'enjeu est la COHÉRENCE entre deux affichages : la latence montrée en direct
/// pendant la mesure et celle du résultat final. Elles viennent du même flux
/// d'échos, mais étaient calculées à deux endroits — les laisser diverger ferait
/// changer le nombre à l'écran au moment où le résultat remplace le direct, sans
/// qu'aucun test ne bronche.
final class SpeedtestIcmpLiveProgressTests: XCTestCase {

    private func sample(_ rtt: Double, _ seq: UInt16) -> ICMPPinger.Sample {
        ICMPPinger.Sample(rttMs: rtt, sequence: seq)
    }

    func testFirstEchoIsDroppedAsWarmup() {
        // Le premier écho paie le réveil du chemin radio : 180 ms puis ~20 ms est
        // le profil typique en cellulaire. Le retenir décalerait la latence
        // affichée vers le haut, et le minimum publié avec elle.
        let values = speedtestIcmpMeasuredValues([
            sample(180, 0), sample(21, 1), sample(19, 2), sample(20, 3),
        ])
        XCTAssertEqual(values, [21, 19, 20])
        XCTAssertEqual(values.min(), 19)
    }

    func testLostEchoesAreExcluded() {
        // Un RTT nul ou négatif est un écho PERDU, pas une latence de 0 ms.
        let values = speedtestIcmpMeasuredValues([
            sample(180, 0), sample(21, 1), sample(0, 2), sample(-1, 3), sample(23, 4),
        ])
        XCTAssertEqual(values, [21, 23])
    }

    func testSingleEchoYieldsNothingMeasurable() {
        // Un seul écho = uniquement l'échauffement : rien à afficher, et surtout
        // pas 180 ms. C'est ce cas qui justifie le `guard !measured.isEmpty` du
        // rappel live — sans lui, la jauge afficherait 0.
        XCTAssertTrue(speedtestIcmpMeasuredValues([sample(180, 0)]).isEmpty)
        XCTAssertTrue(speedtestIcmpMeasuredValues([]).isEmpty)
    }

    /// Le cœur du sujet : ce que l'affichage live montre au dernier échantillon
    /// doit être EXACTEMENT ce que le résultat final retient.
    func testLiveSeriesConvergesToFinalSeries() {
        let full = [
            sample(180, 0), sample(21, 1), sample(19, 2), sample(0, 3), sample(20, 4),
        ]
        // Le rappel live reçoit la série accumulée, écho après écho.
        var lastLive: [Double] = []
        for count in 1...full.count {
            let running = Array(full.prefix(count))
            let measured = speedtestIcmpMeasuredValues(running)
            if !measured.isEmpty { lastLive = measured }
        }
        XCTAssertEqual(lastLive, speedtestIcmpMeasuredValues(full),
                       "la dernière valeur affichée doit égaler le résultat publié")
    }

    func testLiveSeriesOnlyGrows() {
        // Chaque rappel doit ajouter, jamais retirer : une série qui rétrécirait
        // ferait reculer la gigue et le compteur d'échantillons à l'écran.
        let full = [sample(180, 0), sample(21, 1), sample(19, 2), sample(20, 3)]
        var previous = 0
        for count in 1...full.count {
            let measured = speedtestIcmpMeasuredValues(Array(full.prefix(count)))
            XCTAssertGreaterThanOrEqual(measured.count, previous)
            previous = measured.count
        }
    }
}
