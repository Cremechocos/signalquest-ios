import XCTest
@testable import SignalQuest

/// Ce port doit dire EXACTEMENT ce que disent `TaRingSelection` (Android) et `ta-rings.ts`
/// (site). Un écart ne se verrait pas : iOS tracerait d'autres cercles que l'application
/// Android, ou jugerait convergent ce qu'elle juge divergent, et l'utilisateur qui passe de
/// l'une à l'autre ne saurait plus laquelle croire.
final class TaRingSelectionTests: XCTestCase {

    private let baseLat = 45.188_529
    private let baseLon = 5.724_524

    /// ~111 320 m par degré de latitude.
    private func lat(offsetMeters: Double) -> Double {
        baseLat + offsetMeters / 111_320
    }

    private func reading(
        latitude: Double? = nil,
        longitude: Double? = nil,
        timingAdvance: Int? = 20,
        accuracyMeters: Double? = nil,
        secondsFromEpoch: TimeInterval = 1_786_000_000
    ) -> TaRingSelection.Reading {
        TaRingSelection.Reading(
            latitude: latitude ?? baseLat,
            longitude: longitude ?? baseLon,
            timingAdvance: timingAdvance,
            accuracyMeters: accuracyMeters,
            observedAt: Date(timeIntervalSince1970: secondsFromEpoch)
        )
    }

    func testUnPasDeTaVaut78Metres() {
        XCTAssertEqual(TaRingSelection.distanceMeters(forTimingAdvance: 1), 78.12)
        XCTAssertEqual(TaRingSelection.distanceMeters(forTimingAdvance: 0), 0)
        XCTAssertNil(TaRingSelection.distanceMeters(forTimingAdvance: -1))
        XCTAssertNil(TaRingSelection.distanceMeters(forTimingAdvance: 1283), "hors plage LTE")
    }

    func testUnTaNulOuAbsentNeDonneAucunAnneau() {
        XCTAssertTrue(TaRingSelection.rings(for: [reading(timingAdvance: 0)]).isEmpty)
        XCTAssertTrue(TaRingSelection.rings(for: [reading(timingAdvance: nil)]).isEmpty)
    }

    /// Le champ porte une DISTANCE, pas l'unité TA brute : y passer le TA tel quel traçait un
    /// anneau de « TA » mètres — 37 m au lieu de 2,9 km.
    func testLeRayonEstUneDistance() {
        let rings = TaRingSelection.rings(for: [reading(timingAdvance: 37)])
        XCTAssertEqual(rings.first?.radiusMeters, (37 * 78.12).rounded())
        XCTAssertGreaterThan(rings.first?.radiusMeters ?? 0, 2_800)
    }

    func testLaCouronneSElargitQuandLeGpsEstImprecis() {
        XCTAssertEqual(TaRingSelection.rings(for: [reading(accuracyMeters: 5)]).first?.toleranceMeters, 44)
        XCTAssertEqual(TaRingSelection.rings(for: [reading(accuracyMeters: 800)]).first?.toleranceMeters, 839)
        XCTAssertEqual(
            TaRingSelection.rings(for: [reading(accuracyMeters: nil)]).first?.toleranceMeters,
            289,
            "précision supposée quand elle manque"
        )
    }

    func testLesRelevesAuMemeEndroitNeFontQuUnAnneau() {
        let rings = TaRingSelection.rings(for: [
            reading(secondsFromEpoch: 1_786_000_000),
            reading(secondsFromEpoch: 1_786_000_030),
            reading(latitude: lat(offsetMeters: 10), secondsFromEpoch: 1_786_000_060)
        ])
        XCTAssertEqual(rings.count, 1, "trois relevés à moins de 40 m = un seul anneau")
    }

    /// Prendre les N plus récents ramènerait les N relevés d'un même arrêt : beaucoup de
    /// cercles, aucune intersection utile.
    func testLaSelectionRetientLesPositionsLesPlusDispersees() {
        var readings: [TaRingSelection.Reading] = []
        for i in 0..<20 {
            readings.append(
                reading(
                    latitude: lat(offsetMeters: Double(i) * 45),
                    secondsFromEpoch: 1_786_100_000 + TimeInterval(i)
                )
            )
        }
        readings.append(reading(latitude: lat(offsetMeters: 9_000), secondsFromEpoch: 1_785_000_000))

        let rings = TaRingSelection.rings(for: readings, maxRings: 3)
        XCTAssertEqual(rings.count, 3)
        XCTAssertTrue(
            rings.contains { abs($0.latitude - self.lat(offsetMeters: 9_000)) < 1e-9 },
            "le relevé le plus écarté doit être retenu, même ancien"
        )
    }

    func testLePlafondEstRespecte() {
        let readings = (0..<200).map { reading(latitude: lat(offsetMeters: Double($0) * 200)) }
        XCTAssertEqual(TaRingSelection.rings(for: readings).count, 24)
    }

    func testDesAnneauxQuasiConcentriquesNApprennentRien() {
        let rings = TaRingSelection.rings(for: [
            reading(latitude: lat(offsetMeters: 0)),
            reading(latitude: lat(offsetMeters: 60)),
            reading(latitude: lat(offsetMeters: 120))
        ])
        XCTAssertLessThan(TaRingSelection.spreadMeters(rings), 250)
        XCTAssertEqual(TaRingSelection.assess(rings), .unusable)
    }

    func testMoinsDeTroisAnneauxNePermettentAucunVerdict() {
        let rings = TaRingSelection.rings(for: [reading(), reading(latitude: lat(offsetMeters: 3_000))])
        XCTAssertEqual(TaRingSelection.assess(rings), .unusable)
    }

    /// Trois relevés dont les distances désignent réellement un même point.
    func testDesAnneauxCompatiblesSontConvergents() {
        let points = [
            (baseLat + 0.02, baseLon),
            (baseLat - 0.015, baseLon + 0.01),
            (baseLat + 0.005, baseLon - 0.022)
        ]
        let readings = points.map { point -> TaRingSelection.Reading in
            let dLat = (point.0 - baseLat) * 111_320
            let dLon = (point.1 - baseLon) * 111_320 * cos(baseLat * .pi / 180)
            let distance = (dLat * dLat + dLon * dLon).squareRoot()
            return reading(
                latitude: point.0,
                longitude: point.1,
                timingAdvance: max(1, Int((distance / 78.12).rounded())),
                accuracyMeters: 10
            )
        }
        XCTAssertEqual(TaRingSelection.assess(TaRingSelection.rings(for: readings)), .convergent)
    }

    // MARK: - Garde-fou : les TA qui ne décrivent pas ce site
    //
    // Un TA peut être parfaitement mesuré et pourtant faux POUR CETTE CELLULE — les mesures
    // d'une voisine collées à cette identité. L'anneau est alors un vrai cercle, au mauvais
    // endroit, et un seul suffit à déplacer le site estimé de plusieurs kilomètres.

    /// Un relevé dont le TA correspond EXACTEMENT à sa distance au site : un anneau honnête.
    private func honnete(lat: Double, lon: Double, seconds: TimeInterval) -> TaRingSelection.Reading {
        let dLat = (lat - baseLat) * 111_320
        let dLon = (lon - baseLon) * 111_320 * cos(baseLat * .pi / 180)
        let distance = (dLat * dLat + dLon * dLon).squareRoot()
        return reading(
            latitude: lat,
            longitude: lon,
            timingAdvance: max(1, Int((distance / 78.12).rounded())),
            accuracyMeters: 10,
            secondsFromEpoch: seconds
        )
    }

    private func cercleAutourDuSite(_ n: Int) -> [TaRingSelection.Reading] {
        (0..<n).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(n)
            return honnete(
                lat: baseLat + 0.02 * cos(angle),
                lon: baseLon + 0.02 * sin(angle),
                seconds: 1_786_000_000 + TimeInterval(i)
            )
        }
    }

    /// À 2 km du site mais annonçant 234 m : l'écart dépasse le plancher de 800 m.
    private var menteur: TaRingSelection.Reading {
        reading(
            latitude: baseLat + 0.018,
            timingAdvance: 3,
            accuracyMeters: 10,
            secondsFromEpoch: 1_786_100_000
        )
    }

    func testUnAnneauQuiContreditTousLesAutresEstEcarte() {
        let pruned = TaRingSelection.pruneOutliers(
            TaRingSelection.rings(for: cercleAutourDuSite(5) + [menteur])
        )
        XCTAssertEqual(pruned.discarded.count, 1)
        XCTAssertEqual(pruned.discarded.first?.timingAdvance, 3)
        XCTAssertEqual(pruned.kept.count, 5)
    }

    func testDesAnneauxTousCoherentsNeSontJamaisElagues() {
        let pruned = TaRingSelection.pruneOutliers(TaRingSelection.rings(for: cercleAutourDuSite(6)))
        XCTAssertTrue(pruned.discarded.isEmpty)
        XCTAssertEqual(pruned.kept.count, 6)
    }

    /// À trois, retirer un cercle revient à décréter lequel des trois a raison.
    func testSousQuatreAnneauxOnNeRetireRien() {
        let pruned = TaRingSelection.pruneOutliers(
            TaRingSelection.rings(for: cercleAutourDuSite(2) + [menteur])
        )
        XCTAssertTrue(pruned.discarded.isEmpty)
        XCTAssertEqual(pruned.kept.count, 3)
    }

    /// LE GARDE-FOU DU GARDE-FOU : jeter des mesures jusqu'à ce que le reste s'accorde ne
    /// révèle rien, cela fabrique une convergence.
    func testJamaisPlusDuQuartDesAnneauxNEstEcarte() {
        let menteurs = (0..<4).map { i in
            reading(
                latitude: baseLat + 0.018 + Double(i) * 0.001,
                timingAdvance: 3,
                accuracyMeters: 10,
                secondsFromEpoch: 1_786_200_000 + TimeInterval(i)
            )
        }
        let pruned = TaRingSelection.pruneOutliers(
            TaRingSelection.rings(for: cercleAutourDuSite(8) + menteurs)
        )
        XCTAssertLessThanOrEqual(pruned.discarded.count, 3, "au plus 12/4, jamais les 4 gêneurs")
    }

    func testUnElagageQuiNAmeliorePasEstRefuse() {
        // Des anneaux dispersés sans site commun : retirer le pire ne les réconcilie pas.
        let bruit = [
            reading(latitude: 45.60, longitude: 5.40, timingAdvance: 90, accuracyMeters: 10),
            reading(latitude: 45.70, longitude: 5.50, timingAdvance: 5, accuracyMeters: 10),
            reading(latitude: 45.62, longitude: 5.52, timingAdvance: 80, accuracyMeters: 10),
            reading(latitude: 45.72, longitude: 5.38, timingAdvance: 8, accuracyMeters: 10),
            reading(latitude: 45.58, longitude: 5.46, timingAdvance: 70, accuracyMeters: 10)
        ]
        XCTAssertTrue(TaRingSelection.pruneOutliers(TaRingSelection.rings(for: bruit)).discarded.isEmpty)
    }

    /// Cas réel du journal (eNB 603261, SFR). Neuf relevés concordent à moins de 90 m ; un
    /// dixième, à 937 m, porte en fait le TA d'une cellule de l'eNB 603267 relevée à 77 m du
    /// même point. Sans élagage, ce seul anneau déplaçait le site estimé de 2,8 km.
    func testLeCas603261RedevientExploitable() {
        let releves = [
            reading(latitude: 45.53195, longitude: 5.71489, timingAdvance: 76, accuracyMeters: 1),
            reading(latitude: 45.54535, longitude: 5.65492, timingAdvance: 24),
            reading(latitude: 45.53245, longitude: 5.70472, timingAdvance: 67, accuracyMeters: 1),
            reading(latitude: 45.55152, longitude: 5.63937, timingAdvance: 19, accuracyMeters: 2),
            reading(latitude: 45.55325, longitude: 5.63254, timingAdvance: 22),
            reading(latitude: 45.53333, longitude: 5.68784, timingAdvance: 49, accuracyMeters: 5),
            reading(latitude: 45.53338, longitude: 5.68347, timingAdvance: 12), // l'intrus
            reading(latitude: 45.55410, longitude: 5.63022, timingAdvance: 25, accuracyMeters: 6),
            reading(latitude: 45.55439, longitude: 5.62960, timingAdvance: 25)
        ]
        let brut = TaRingSelection.rings(for: releves)
        XCTAssertEqual(TaRingSelection.assess(brut), .divergent, "sans élagage, rien ne se croise")

        let pruned = TaRingSelection.pruneOutliers(brut)
        XCTAssertTrue(
            pruned.discarded.contains { $0.timingAdvance == 12 },
            "l'anneau de 937 m doit être écarté"
        )
        XCTAssertEqual(TaRingSelection.assess(pruned.kept), .convergent)
    }

    /// Mêmes points, mais des TA qui ne peuvent pas décrire un site unique : on les montre,
    /// en signalant qu'ils se contredisent.
    func testDesAnneauxIncompatiblesSontDivergents() {
        let readings = [
            reading(latitude: baseLat + 0.02, timingAdvance: 3, accuracyMeters: 10),
            reading(latitude: baseLat - 0.015, longitude: baseLon + 0.01, timingAdvance: 60, accuracyMeters: 10),
            reading(latitude: baseLat + 0.005, longitude: baseLon - 0.022, timingAdvance: 4, accuracyMeters: 10)
        ]
        XCTAssertEqual(TaRingSelection.assess(TaRingSelection.rings(for: readings)), .divergent)
    }
}
