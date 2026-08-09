import CarPlay
import CoreLocation
import XCTest
@testable import SignalQuest

/// Verrouille l'écran « Ici » (Lot 4) — celui qui répond à « pourquoi ça capte
/// mal ». Ses pièges sont moins géométriques que ceux du guidage et plus
/// éditoriaux : ne rien afficher de trompeur quand la donnée manque, et ne pas
/// laisser un verdict sans son nombre de mesures.
@MainActor
final class CarPlayHereTests: XCTestCase {

    private func quality(level: CoverageQualityBand = .poor,
                         samples: Int = 42) -> NearbyNetworkQuality {
        NearbyNetworkQuality(
            level: level, signalBand: level, speedBand: level,
            medianRsrpDbm: -108, medianDownloadMbps: 12,
            operatorLabel: "Orange", operatorKey: "ORANGE",
            sampleCount: samples, radiusMeters: 1000
        )
    }

    private func cellularPath() -> NetworkPathStatus {
        NetworkPathStatus(
            connection: .cellular, cellularTechnology: nil, operatorName: "Orange",
            operatorMcc: 208, operatorMnc: 1, isExpensive: true, isConstrained: false
        )
    }

    private func site() throws -> AntennaSite {
        let json = """
        {"id":"1","siteId":"75-1234","lat":48.86,"lng":2.36,
         "operators":["ORANGE"],"technologies":["4G","5G"],"azimuts":[0,120,240]}
        """
        return try JSONDecoder.signalQuest.decode(AntennaSite.self, from: Data(json.utf8))
    }

    /// Le verdict passe avant tout le reste : c'est la question que l'utilisateur
    /// se pose en ouvrant cet écran.
    func testVerdictComesFirst() {
        let items = NearestAntennaTemplateBuilder.items(
            for: .init(path: cellularPath(), quality: quality())
        )
        XCTAssertEqual(items.first?.title, String(localized: "Réseau ici"))
    }

    /// « Mauvais sur 3 mesures » et « mauvais sur 400 » ne se valent pas : le
    /// verdict ne doit jamais être affiché sans ce qui le qualifie.
    func testVerdictIsAlwaysAccompaniedByItsSampleCount() {
        let items = NearestAntennaTemplateBuilder.items(
            for: .init(path: cellularPath(), quality: quality(samples: 3))
        )
        XCTAssertTrue(items.contains { $0.title == String(localized: "Mesures") })
    }

    /// Sans mesures, on le DIT. Un écran muet laisserait croire à un bug, ou
    /// pire, à une absence de réseau.
    func testMissingQualityIsStatedExplicitly() {
        let items = NearestAntennaTemplateBuilder.items(
            for: .init(path: cellularPath(), quality: nil)
        )
        let verdict = items.first { $0.title == String(localized: "Réseau ici") }
        XCTAssertNotNil(verdict)
        XCTAssertFalse(verdict?.detail?.isEmpty ?? true)
    }

    /// Idem pour l'antenne : pas de ligne vide, une phrase.
    func testMissingAntennaIsStatedExplicitly() {
        let items = NearestAntennaTemplateBuilder.items(
            for: .init(path: cellularPath(), quality: quality(), nearestSite: nil)
        )
        let antenna = items.first { $0.title == String(localized: "Antenne la plus proche") }
        XCTAssertNotNil(antenna)
        XCTAssertFalse(antenna?.detail?.isEmpty ?? true)
    }

    /// Distance ET direction : la distance seule ne dit pas où regarder.
    func testDistanceIsPairedWithADirection() throws {
        let items = NearestAntennaTemplateBuilder.items(
            for: .init(path: cellularPath(), quality: quality(),
                       nearestSite: try site(), nearestDistanceMeters: 340, bearingDegrees: 90)
        )
        let distance = items.first { $0.title == String(localized: "Distance") }
        XCTAssertEqual(distance?.detail?.contains(String(localized: "à l'est")), true)
    }

    /// Être dans l'axe d'un secteur explique une bonne réception malgré la
    /// distance — c'est l'information qui rend l'écran utile plutôt que descriptif.
    func testSectorAlignmentIsReported() throws {
        let aligned = NearestAntennaTemplateBuilder.items(
            for: .init(path: cellularPath(), quality: quality(),
                       nearestSite: try site(), nearestDistanceMeters: 340,
                       bearingDegrees: 90, isInSector: true)
        )
        let off = NearestAntennaTemplateBuilder.items(
            for: .init(path: cellularPath(), quality: quality(),
                       nearestSite: try site(), nearestDistanceMeters: 340,
                       bearingDegrees: 90, isInSector: false)
        )
        let alignedDetail = aligned.first { $0.title == String(localized: "Orientation") }?.detail
        let offDetail = off.first { $0.title == String(localized: "Orientation") }?.detail
        XCTAssertNotNil(alignedDetail)
        XCTAssertNotEqual(alignedDetail, offDetail)
    }

    /// Plafonds CarPlay, même avec toutes les données réunies.
    func testTemplateStaysWithinCarPlayLimits() throws {
        let template = NearestAntennaTemplateBuilder.make(
            input: .init(path: cellularPath(), quality: quality(),
                         nearestSite: try site(), nearestDistanceMeters: 340,
                         bearingDegrees: 90, isInSector: true),
            actions: .init(showOnMap: {}, navigate: {})
        )
        XCTAssertLessThanOrEqual(template.items.count, CarPlayDetailTemplateBuilder.maxItems)
        XCTAssertLessThanOrEqual(template.actions.count, CarPlayDetailTemplateBuilder.maxActions)
    }

    /// Sans action fournie (mode liste, où il n'y a pas de carte à centrer),
    /// aucun bouton ne doit apparaître.
    func testNoButtonsWhenNoActionsProvided() {
        let template = NearestAntennaTemplateBuilder.make(
            input: .init(path: cellularPath(), quality: quality()),
            actions: .init()
        )
        XCTAssertTrue(template.actions.isEmpty)
    }
}
