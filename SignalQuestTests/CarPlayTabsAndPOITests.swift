import CarPlay
import CoreLocation
import XCTest
@testable import SignalQuest

/// La nouvelle surface : racine à onglets et carte de points d'intérêt.
///
/// Ces deux templates existent pour une raison qui n'est pas cosmétique : ils
/// ramènent la navigation SOUS le plafond de profondeur des apps « driving
/// task » (deux templates empilés). L'ancienne arborescence
/// racine → liste → fiche en demandait trois, et le troisième était refusé.
@MainActor
final class CarPlayTabsAndPOITests: XCTestCase {

    private func makePayload(id: String, title: String, subtitle: String,
                             latitude: Double, longitude: Double) -> MapAnnotationPayload {
        MapAnnotationPayload(
            id: id,
            kind: .antenna,
            title: title,
            subtitle: subtitle,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            metric: nil,
            backendId: id,
            details: nil,
            antennaId: id,
            clusterCount: nil,
            azimuths: [],
            showsAzimuths: false
        )
    }

    // MARK: - Points d'intérêt

    /// CarPlay tronque au-delà de 12, en silence. On coupe nous-mêmes pour
    /// choisir lesquels survivent : les plus proches, pas les douze premiers
    /// renvoyés par le serveur.
    func testPointsAreCappedAndSortedByDistance() {
        let user = CLLocation(latitude: 48.85, longitude: 2.35)
        let payloads = (0..<20).map { index in
            makePayload(id: "site-\(index)", title: "Site \(index)", subtitle: "Orange · 4G",
                        latitude: 48.85 + Double(20 - index) * 0.001, longitude: 2.35)
        }

        let entries = CarPlayPOIBuilder.entries(from: payloads, userLocation: user)

        XCTAssertEqual(entries.count, CarPlayPOIBuilder.maxPoints)
        let distances = entries.compactMap(\.distanceMeters)
        XCTAssertEqual(distances, distances.sorted(), "le plus proche doit venir en premier")
        XCTAssertEqual(entries.first?.payload.title, "Site 19")
    }

    /// Un cluster (« 42 sites ») n'a pas de fiche à ouvrir : il n'a rien à faire
    /// dans le carrousel.
    func testClustersAreExcluded() {
        var cluster = makePayload(id: "c", title: "42 sites", subtitle: "",
                                  latitude: 48.85, longitude: 2.35)
        cluster = MapAnnotationPayload(
            id: cluster.id, kind: .antenna, title: cluster.title, subtitle: cluster.subtitle,
            coordinate: cluster.coordinate, metric: nil, backendId: nil, details: nil,
            antennaId: nil, clusterCount: 42, azimuths: [], showsAzimuths: false
        )
        let single = makePayload(id: "s", title: "Site 1", subtitle: "SFR · 5G",
                                 latitude: 48.86, longitude: 2.35)

        let entries = CarPlayPOIBuilder.entries(from: [cluster, single], userLocation: nil)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.payload.id, "s")
    }

    /// Entre douze épingles, « Site 12345 » ne distingue rien. L'opérateur, si.
    func testHeadlineLeadsWithTheOperator() {
        let entry = CarPlayPOIBuilder.Entry(
            payload: makePayload(id: "1", title: "Site 12345", subtitle: "Orange/SFR · 4G/5G",
                                 latitude: 48.85, longitude: 2.35),
            distanceMeters: 340
        )

        XCTAssertEqual(CarPlayPOIBuilder.headline(for: entry), "Orange/SFR")
        XCTAssertTrue(CarPlayPOIBuilder.subtitle(for: entry).hasPrefix("340 m"),
                      "la distance est le critère de tri : elle se lit en premier")
    }

    /// Sans opérateur connu, on ne doit pas afficher une chaîne vide.
    func testHeadlineFallsBackToTheSiteName() {
        let entry = CarPlayPOIBuilder.Entry(
            payload: makePayload(id: "1", title: "Site 999", subtitle: "",
                                 latitude: 48.85, longitude: 2.35),
            distanceMeters: nil
        )

        XCTAssertEqual(CarPlayPOIBuilder.headline(for: entry), "Site 999")
    }

    /// La fiche doit vivre DANS le template : c'est ce qui évite le push que le
    /// plafond de profondeur refuserait.
    func testDetailIsCarriedByThePointItself() {
        let entries = [CarPlayPOIBuilder.Entry(
            payload: makePayload(id: "1", title: "Site 12345", subtitle: "Orange · 4G",
                                 latitude: 48.86, longitude: 2.35),
            distanceMeters: 1_200
        )]

        let points = CarPlayPOIBuilder.points(
            from: entries,
            userLocation: CLLocation(latitude: 48.85, longitude: 2.35),
            actions: .init(details: { _ in }, navigate: nil)
        )

        let poi = points.first
        XCTAssertEqual(poi?.detailTitle, "Site 12345")
        XCTAssertEqual(poi?.detailSubtitle, "Orange · 4G")
        XCTAssertNotNil(poi?.detailSummary, "la fiche doit porter distance et direction")
        XCTAssertNotNil(poi?.pinImage, "l'épingle porte l'identité visuelle de l'app")
        XCTAssertNotNil(poi?.primaryButton)
        XCTAssertNil(poi?.secondaryButton, "sans guidage possible, pas de bouton « Y aller »")
    }

    // MARK: - Onglets

    /// Le système LÈVE une exception au-delà de `maximumTabCount`. La troncature
    /// n'est pas une précaution de confort.
    func testTabsAreTruncatedToTheAllowedCount() {
        let extra = CarPlayTabBarBuilder.maximumTabCount + 3
        let tabs = (0..<extra).map { CPListTemplate(title: "onglet \($0)", sections: []) }

        let tabBar = CarPlayTabBarBuilder.make(tabs: tabs)

        XCTAssertEqual(tabBar.templates.count, CarPlayTabBarBuilder.maximumTabCount)
    }

    /// Sans titre d'onglet explicite, CarPlay retombe sur le titre du template —
    /// et l'on obtient quatre onglets nommés à l'identique.
    func testEachTabIsNamedAndIllustrated() {
        let template = CPListTemplate(title: "SignalQuest", sections: [])

        _ = CarPlayTabBarBuilder.decorate(template, title: "Ici", systemImage: "speedometer")

        XCTAssertEqual(template.tabTitle, "Ici")
        XCTAssertNotNil(template.tabImage)
    }

    // MARK: - Comparaison d'opérateurs

    func testRankingShowsValueThenConfidence() {
        let stat = OperatorMetricStat(operatorName: "Orange", value: 42, sampleCount: 128, detail: "24 ms")

        let detail = OperatorComparisonTemplateBuilder.detail(for: stat, metric: .download)

        XCTAssertTrue(detail.hasPrefix("42 Mbps"), "la valeur répond à la question posée")
        XCTAssertTrue(detail.contains("128"), "le nombre de mesures dit à quel point s'y fier")
    }

    func testRankingIsNumberedAndStaysWithinCarPlayLimits() {
        let stats = (0..<40).map {
            OperatorMetricStat(operatorName: "Op \($0)", value: 100 - $0, sampleCount: 10, detail: nil)
        }

        let items = OperatorComparisonTemplateBuilder.items(for: stats, metric: .download)

        XCTAssertLessThanOrEqual(items.count, Int(CPListTemplate.maximumItemCount))
        XCTAssertEqual(items.first?.text, "1. Op 0", "un classement se lit par rang")
    }
}
