import XCTest
@testable import SignalQuest

/// Compteur de données d'un Drive Test.
///
/// Le plafond ne vaut que ce que vaut le compteur : s'il sous-estime, la session
/// dépasse le forfait ; s'il double-compte, elle s'arrête pour rien. Les moteurs
/// passent des TOTAUX CUMULÉS à l'échantillonneur, jamais des deltas — l'erreur
/// naturelle serait de les additionner tels quels.
final class DriveTestDataBudgetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SpeedtestDataMeter.shared.reset()
    }

    override func tearDown() {
        SpeedtestDataMeter.shared.reset()
        super.tearDown()
    }

    /// Un échantillonneur reçoit une suite croissante : le compteur doit retenir
    /// le DERNIER total, pas leur somme.
    func testCumulativeTotalsAreNotSummed() {
        let sampler = SpeedtestLiveSampler()
        for (index, total) in [1_000, 5_000, 20_000, 50_000].enumerated() {
            _ = sampler.observe(totalBytes: total, elapsedMs: Double((index + 1) * 200))
        }
        XCTAssertEqual(
            SpeedtestDataMeter.shared.bytes, 50_000,
            "Les totaux cumulés ont été additionnés au lieu d'être dérivés"
        )
    }

    /// Deux phases (descendant puis montant) = deux échantillonneurs, chacun
    /// repartant de zéro. Les volumes doivent s'ajouter.
    func testPhasesAccumulate() {
        let download = SpeedtestLiveSampler()
        let upload = SpeedtestLiveSampler()
        _ = download.observe(totalBytes: 300_000, elapsedMs: 500)
        _ = download.observe(totalBytes: 900_000, elapsedMs: 1_000)
        _ = upload.observe(totalBytes: 100_000, elapsedMs: 1_500)
        _ = upload.observe(totalBytes: 250_000, elapsedMs: 2_000)
        XCTAssertEqual(SpeedtestDataMeter.shared.bytes, 1_150_000)
    }

    /// Les tout premiers ticks sortent tôt de `observe` (moins de deux points) :
    /// leurs octets ne doivent pas pour autant échapper au comptage.
    func testFirstTickIsCounted() {
        let sampler = SpeedtestLiveSampler()
        _ = sampler.observe(totalBytes: 42_000, elapsedMs: 100)
        XCTAssertEqual(SpeedtestDataMeter.shared.bytes, 42_000)
    }

    /// Un total qui régresse (remise à zéro d'un compteur amont) ne doit jamais
    /// retrancher du volume déjà consommé.
    func testRegressionDoesNotSubtract() {
        let sampler = SpeedtestLiveSampler()
        _ = sampler.observe(totalBytes: 800_000, elapsedMs: 500)
        _ = sampler.observe(totalBytes: 10_000, elapsedMs: 1_000)
        XCTAssertEqual(
            SpeedtestDataMeter.shared.bytes, 800_000,
            "Une régression du total a fait DIMINUER le volume consommé"
        )
    }

    func testResetClearsSession() {
        let sampler = SpeedtestLiveSampler()
        _ = sampler.observe(totalBytes: 1_000_000, elapsedMs: 500)
        SpeedtestDataMeter.shared.reset()
        XCTAssertEqual(SpeedtestDataMeter.shared.bytes, 0)
    }

    /// Le volume affiché doit rester lisible : on vérifie la présence de l'unité
    /// et du chiffre, pas un libellé figé (il suit la langue de l'appareil).
    func testFormattedBytesIsReadable() {
        let small = DriveTestViewModel.formattedBytes(45_000_000)
        let large = DriveTestViewModel.formattedBytes(5_400_000_000)
        XCTAssertTrue(small.contains("45"), "Volume illisible : « \(small) »")
        XCTAssertTrue(large.contains("5"), "Volume illisible : « \(large) »")
        XCTAssertNotEqual(small, large)
        XCTAssertFalse(DriveTestViewModel.formattedBytes(-1).isEmpty, "Un volume négatif ne doit pas produire du vide")
    }
}
