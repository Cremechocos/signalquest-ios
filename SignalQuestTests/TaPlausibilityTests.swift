import XCTest
@testable import SignalQuest

/// Ce port doit retenir EXACTEMENT les mêmes sites que `TaPlausibility` côté Android et
/// `ta-plausibility.ts` côté site. Un écart ne se verrait pas : iOS proposerait un candidat
/// que l'application Android masque, et l'utilisateur ne saurait plus laquelle croire.
final class TaPlausibilityTests: XCTestCase {

    private let siteLat = 45.188_529
    private let siteLon = 5.724_524

    private struct Site {
        let id: String
        let latitude: Double
        let longitude: Double
    }

    private func at(_ site: Site) -> (latitude: Double, longitude: Double)? {
        site.latitude.isFinite ? (site.latitude, site.longitude) : nil
    }

    /// Un relevé dont le TA correspond exactement à sa distance au site.
    private func honnete(lat: Double, lon: Double, seconds: TimeInterval) -> TaRingSelection.Reading {
        let dLat = (lat - siteLat) * 111_320
        let dLon = (lon - siteLon) * 111_320 * cos(siteLat * .pi / 180)
        let distance = (dLat * dLat + dLon * dLon).squareRoot()
        return TaRingSelection.Reading(
            latitude: lat,
            longitude: lon,
            timingAdvance: max(1, Int((distance / 78.12).rounded())),
            accuracyMeters: 10,
            observedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func anneauxAutourDuSite(_ n: Int = 5) -> [TaRingSelection.Ring] {
        TaRingSelection.rings(for: (0..<n).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(n)
            return honnete(
                lat: siteLat + 0.02 * cos(angle),
                lon: siteLon + 0.02 * sin(angle),
                seconds: 1_786_000_000 + TimeInterval(i)
            )
        })
    }

    func testLeScoreEstUnNombreDeCouronnesSatisfaites() {
        let rings = anneauxAutourDuSite()
        XCTAssertEqual(
            TaPlausibility.matchedRings(latitude: siteLat, longitude: siteLon, rings: rings),
            rings.count,
            "le vrai site les satisfait toutes"
        )
        XCTAssertEqual(
            TaPlausibility.matchedRings(latitude: siteLat + 0.5, longitude: siteLon, rings: rings),
            0,
            "à 55 km, aucune"
        )
    }

    func testLeSiteReelEstRetenuLesLointainsEcartes() {
        let rings = anneauxAutourDuSite()
        let sites = [
            Site(id: "vrai", latitude: siteLat, longitude: siteLon),
            Site(id: "loin", latitude: siteLat + 0.3, longitude: siteLon + 0.3),
            Site(id: "tres-loin", latitude: siteLat - 0.5, longitude: siteLon)
        ]
        let kept = TaPlausibility.filterPlausible(sites, rings: rings, position: at)
        XCTAssertNotNil(kept)
        XCTAssertEqual(kept?.map(\.item.id), ["vrai"])
        XCTAssertEqual(kept?.first?.matchedRings, rings.count)
        XCTAssertEqual(kept?.first?.totalRings, rings.count)
    }

    /// À 0 d'écart de rang, un candidat compatible avec 4 couronnes sur 5 disparaîtrait.
    func testLePelotonDeTeteEstGarde() {
        let rings = anneauxAutourDuSite()
        let sites = [
            Site(id: "exact", latitude: siteLat, longitude: siteLon),
            Site(id: "voisin", latitude: siteLat + 0.0036, longitude: siteLon),
            Site(id: "loin", latitude: siteLat + 0.3, longitude: siteLon)
        ]
        let kept = TaPlausibility.filterPlausible(sites, rings: rings, position: at)
        XCTAssertNotNil(kept)
        let ids = kept?.map(\.item.id) ?? []
        XCTAssertTrue(ids.contains("exact"))
        XCTAssertFalse(ids.contains("loin"))
        XCTAssertGreaterThanOrEqual(
            kept?.first?.matchedRings ?? 0,
            kept?.last?.matchedRings ?? 0,
            "trié par score décroissant"
        )
    }

    /// S'ABSTENIR PLUTÔT QUE MENTIR : avec deux couronnes, la moitié d'un secteur les satisfait.
    func testSousTroisAnneauxLeFiltreSAbstient() {
        let rings = TaRingSelection.rings(for: [
            honnete(lat: siteLat + 0.02, lon: siteLon, seconds: 1_786_000_000),
            honnete(lat: siteLat - 0.02, lon: siteLon, seconds: 1_786_000_001)
        ])
        let sites = [Site(id: "a", latitude: siteLat, longitude: siteLon)]
        XCTAssertNil(TaPlausibility.filterPlausible(sites, rings: rings, position: at))
    }

    func testSiAucunSiteNeSatisfaitLaMoindreCouronneLeFiltreSAbstient() {
        let sites = [
            Site(id: "loin", latitude: siteLat + 1, longitude: siteLon + 1),
            Site(id: "plus-loin", latitude: siteLat + 2, longitude: siteLon)
        ]
        XCTAssertNil(
            TaPlausibility.filterPlausible(sites, rings: anneauxAutourDuSite(), position: at),
            "la géométrie n'a rien à dire ici"
        )
    }

    func testUneListeVideNeDeclenchePasDeFiltrage() {
        XCTAssertNil(
            TaPlausibility.filterPlausible([Site](), rings: anneauxAutourDuSite(), position: at)
        )
    }

    func testUnSiteSansPositionEstIgnoreSansFaireEchouerLeTri() {
        let sites = [
            Site(id: "vrai", latitude: siteLat, longitude: siteLon),
            Site(id: "sans-position", latitude: .nan, longitude: .nan)
        ]
        let kept = TaPlausibility.filterPlausible(sites, rings: anneauxAutourDuSite(), position: at)
        XCTAssertEqual(kept?.map(\.item.id), ["vrai"])
    }
}
