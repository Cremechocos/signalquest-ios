import XCTest
@testable import SignalQuest

/// Échelle de repli de l'upload.
///
/// iOS plafonnait à 8 flux montants là où Android en utilise 16 — les débits des deux
/// apps n'étaient donc pas comparables. En montant iOS à 16, le point de vigilance
/// devient le REPLI : certains POP publics (Scaleway, Bouygues) coupent la connexion à
/// 16 flux, et l'ancienne échelle `[16, 4]` les aurait fait tomber directement à 4 —
/// soit une mesure plus basse qu'avant le changement. D'où le palier à 8.
final class SpeedtestUploadStreamLadderTests: XCTestCase {

    private func ladder(_ requested: Int) -> [Int] {
        speedtestUploadStreamLadder(requested: requested, hardMax: 16, fallback: 8, last: 4)
    }

    /// Le cas nominal : trois barreaux, du plus ambitieux au plus prudent.
    func testFullLadderFromTheCap() {
        XCTAssertEqual(ladder(16), [16, 8, 4])
    }

    /// Le barreau intermédiaire est la raison d'être de ce test : sans lui, un POP qui
    /// refuse 16 flux mesurerait à 4 et le passage de 8 à 16 aurait DÉGRADÉ le résultat.
    func testTheIntermediateRungExists() {
        XCTAssertTrue(ladder(16).contains(8), "Le palier à 8 est ce qui rend la montée à 16 sûre")
    }

    /// L'échelle ne doit jamais remonter : chaque essai est une tentative plus prudente
    /// que la précédente.
    func testLadderIsStrictlyDecreasing() {
        for requested in 1...16 {
            let rungs = ladder(requested)
            XCTAssertEqual(rungs, rungs.sorted(by: >), "Échelle non décroissante pour \(requested) : \(rungs)")
            XCTAssertEqual(Set(rungs).count, rungs.count, "Palier répété pour \(requested) : \(rungs)")
        }
    }

    /// Une demande sous le plafond ne doit pas être dépassée — sinon on essaierait plus
    /// de flux que ce que l'utilisateur ou le profil a demandé.
    func testNeverExceedsTheRequestedCount() {
        XCTAssertEqual(ladder(8), [8, 4])
        XCTAssertEqual(ladder(4), [4])
        for requested in 1...16 {
            XCTAssertLessThanOrEqual(ladder(requested).first ?? 0, requested)
        }
    }

    /// Demander 4 flux donnait naïvement `[4, 8, 4]` : au-dessus de la demande, puis le
    /// même palier rejoué. Une seule tentative suffit.
    func testASmallRequestCollapsesToASingleAttempt() {
        XCTAssertEqual(ladder(4), [4])
        XCTAssertEqual(ladder(1), [1])
    }

    /// Le plafond borne toujours, même si l'appelant demande davantage.
    func testCapsAnOversizedRequest() {
        XCTAssertEqual(ladder(64), [16, 8, 4])
    }

    /// Aucune valeur absurde ne doit sortir : une demande nulle ou négative reste une
    /// tentative valide plutôt qu'une échelle vide, qui annulerait la phase d'upload.
    func testDegenerateRequestsStayUsable() {
        XCTAssertEqual(ladder(0), [1])
        XCTAssertEqual(ladder(-3), [1])
        XCTAssertFalse(ladder(0).isEmpty, "Une échelle vide supprimerait la mesure d'upload")
    }
}
