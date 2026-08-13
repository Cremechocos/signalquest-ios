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
