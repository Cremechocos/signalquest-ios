import XCTest
import MapKit
import CoreLocation
@testable import SignalQuest

/// Le marqueur d'antenne encode quatre informations dans un dessin : la couleur
/// opérateur, l'orientation des secteurs, l'identification communautaire et la
/// présence de photos. Rien de tout cela n'est du texte — une régression y est
/// muette. Ces tests vérifient la géométrie produite, pas l'apparence.
final class AntennaMarkerRenderTests: XCTestCase {

    private func payload(
        azimuths: [Double] = [30, 150, 270],
        reach: CGFloat = 24,
        hasEnb: Bool = false,
        hasGnb: Bool = false,
        has5G: Bool = false,
        photos: Int = 0,
        clusterCount: Int? = nil
    ) -> MapAnnotationPayload {
        MapAnnotationPayload(
            id: "antenna-1", kind: .antenna, title: "Site 3079254", subtitle: "SFR · 5G/4G",
            coordinate: CLLocationCoordinate2D(latitude: 45.18, longitude: 5.72),
            metric: nil, backendId: "3079254", details: nil, antennaId: "3079254",
            clusterCount: clusterCount, azimuths: azimuths, showsAzimuths: reach > 0,
            contributionPhotos: photos, hasEnb: hasEnb, hasGnb: hasGnb, has5G: has5G,
            azimuthReachPoints: reach
        )
    }

    private func markerView(_ payload: MapAnnotationPayload) -> SQMapKitMarkerView {
        let annotation = SQMapKitAnnotation(payload: payload)
        let view = SQMapKitMarkerView(annotation: annotation, reuseIdentifier: SQMapKitMarkerView.reuseID)
        view.apply(payload)
        return view
    }

    // MARK: Géométrie

    /// La vue s'agrandit pour contenir les lobes, mais la pastille garde sa
    /// taille et reste centrée sur la coordonnée : un `centerOffset` non nul
    /// décalerait visuellement toutes les antennes de la carte.
    func testViewGrowsWithReachButStaysCentered() {
        let short = markerView(payload(reach: 24))
        let long = markerView(payload(reach: 44))
        XCTAssertEqual(short.frame.width, 48)
        XCTAssertEqual(long.frame.width, 88)
        XCTAssertEqual(short.centerOffset, .zero)
        XCTAssertEqual(long.centerOffset, .zero)
        XCTAssertEqual(short.dot.frame.width, long.dot.frame.width, "La pastille ne dépend pas du zoom")
        XCTAssertEqual(short.dot.frame.midX, short.bounds.midX, accuracy: 0.001)
        XCTAssertEqual(long.dot.frame.midY, long.bounds.midY, accuracy: 0.001)
    }

    /// Une vue de 88 pt de côté qui capterait tous les taps dans son cadre
    /// volerait les sites voisins — soit exactement l'imprécision que les lobes
    /// attachés sont censés éviter.
    func testHitAreaStaysNearTheDotWhateverTheReach() {
        let view = markerView(payload(reach: 44))
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        XCTAssertTrue(view.point(inside: center, with: nil))
        XCTAssertTrue(view.point(inside: CGPoint(x: center.x + 14, y: center.y), with: nil))
        XCTAssertFalse(
            view.point(inside: CGPoint(x: center.x + 40, y: center.y), with: nil),
            "Le bout d'un lobe ne doit pas être tappable"
        )
        XCTAssertFalse(view.point(inside: .zero, with: nil), "Le coin de la vue n'est pas le marqueur")
    }

    /// La pastille est un disque : `cornerRadius` doit valoir exactement la
    /// moitié du côté. À 1 pt près, elle devient un carré arrondi — et le liseré
    /// crème le rend immédiatement visible sur la carte.
    func testDotIsACircleNotARoundedSquare() {
        let antenna = markerView(payload())
        XCTAssertEqual(antenna.dot.layer.cornerRadius, antenna.dot.frame.width / 2, accuracy: 0.001)
        XCTAssertEqual(antenna.dot.frame.width, antenna.dot.frame.height, accuracy: 0.001)

        let cluster = markerView(payload(clusterCount: 12))
        XCTAssertEqual(cluster.dot.layer.cornerRadius, cluster.dot.frame.width / 2, accuracy: 0.001)
    }

    /// Un point coloré, rien d'autre : sur une carte où chaque marqueur est une
    /// antenne, un pictogramme d'antenne ne distingue rien.
    func testAntennaDotCarriesNoGlyph() {
        let antenna = markerView(payload())
        XCTAssertTrue(antenna.glyph.isHidden)
        XCTAssertNil(antenna.glyph.image)
    }

    /// Les autres couches, elles, gardent leur pictogramme : c'est ce qui
    /// distingue une panne d'un speedtest.
    func testOtherLayersKeepTheirGlyph() {
        var outage = payload()
        outage = MapAnnotationPayload(
            id: "outage-1", kind: .outage, title: "Panne", subtitle: "SFR",
            coordinate: outage.coordinate, metric: nil, backendId: nil, details: nil,
            antennaId: nil, clusterCount: nil, azimuths: [], showsAzimuths: false
        )
        let view = markerView(outage)
        XCTAssertFalse(view.glyph.isHidden)
        XCTAssertNotNil(view.glyph.image)
    }

    func testLobesAppearOnlyWhenZoomedIn() {
        XCTAssertNil(markerView(payload(reach: 0)).lobePathForTesting, "Sous z14, pas de lobes")
        XCTAssertNotNil(markerView(payload(reach: 24)).lobePathForTesting)
    }

    func testLobesAreNotDrawnWithoutAzimuths() {
        XCTAssertNil(markerView(payload(azimuths: [], reach: 32)).lobePathForTesting)
    }

    /// Azimut 0 = nord = vers le HAUT de l'écran. Un signe inversé enverrait tous
    /// les secteurs au sud sans que rien ne le signale.
    func testNorthLobePointsUp() throws {
        let view = markerView(payload(azimuths: [0], reach: 40))
        let path = try XCTUnwrap(view.lobePathForTesting)
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let box = path.boundingBox
        XCTAssertLessThan(box.minY, center.y - 20, "Le lobe nord doit s'étendre vers le haut")
        XCTAssertEqual(box.maxY, center.y, accuracy: 1, "…et pas sous le centre")
    }

    func testEastLobePointsRight() throws {
        let view = markerView(payload(azimuths: [90], reach: 40))
        let path = try XCTUnwrap(view.lobePathForTesting)
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let box = path.boundingBox
        XCTAssertGreaterThan(box.maxX, center.x + 20, "Le lobe est doit s'étendre vers la droite")
        XCTAssertEqual(box.minX, center.x, accuracy: 1)
    }

    // MARK: Badges et anneau

    func testCheckAppearsOnlyWhenTheEnbIsKnown() {
        XCTAssertTrue(markerView(payload()).checkBadgeIsHiddenForTesting)
        XCTAssertFalse(markerView(payload(hasEnb: true)).checkBadgeIsHiddenForTesting)
    }

    func testPhotoBadgeFollowsContributions() {
        XCTAssertTrue(markerView(payload(photos: 0)).photoBadgeIsHiddenForTesting)
        XCTAssertFalse(markerView(payload(photos: 4)).photoBadgeIsHiddenForTesting)
    }

    /// L'anneau ne concerne que les sites 5G, et sa couleur porte l'information :
    /// vert = gNB identifié, couleur opérateur = 5G présente mais gNB inconnu.
    func testRingAppearsOnlyOnFiveGSites() {
        XCTAssertNil(markerView(payload(has5G: false)).ringPathForTesting)
        XCTAssertNotNil(markerView(payload(has5G: true)).ringPathForTesting)
    }

    func testRingTurnsGreenWhenTheGnbIsKnown() throws {
        let unknown = markerView(payload(hasGnb: false, has5G: true))
        let known = markerView(payload(hasGnb: true, has5G: true))
        // `SQColor.success` est une couleur d'asset dynamique : on compare les
        // composantes RÉSOLUES, pas les objets — deux `UIColor` équivalents à
        // l'écran ne sont pas égaux si l'un est encore un fournisseur dynamique.
        let green: [CGFloat] = try XCTUnwrap(UIColor(SQColor.success).cgColor.components)
        let knownComponents: [CGFloat] = try XCTUnwrap(known.ringColorForTesting?.components)
        let unknownComponents: [CGFloat] = try XCTUnwrap(unknown.ringColorForTesting?.components)
        XCTAssertEqual(knownComponents, green)
        XCTAssertNotEqual(unknownComponents, green)
    }

    /// Un cluster reste une pastille numérotée : lui coller des lobes ou une
    /// coche prêterait ces attributs à des dizaines de sites d'un coup.
    func testClusterCarriesNoAntennaSignals() {
        let view = markerView(payload(hasEnb: true, has5G: true, photos: 3, clusterCount: 42))
        XCTAssertNil(view.lobePathForTesting)
        XCTAssertNil(view.ringPathForTesting)
        XCTAssertTrue(view.checkBadgeIsHiddenForTesting)
        XCTAssertTrue(view.photoBadgeIsHiddenForTesting)
        XCTAssertEqual(view.countLabel.text, "42")
    }

    // MARK: Rotation de carte

    /// Les lobes sont dessinés en repère écran : sans contre-rotation, faire
    /// pivoter la carte ferait pointer tous les secteurs à côté.
    func testLobesCounterRotateWithTheMap() {
        let view = markerView(payload(reach: 32))
        view.applyMapHeading(90)
        let transform = view.lobeTransformForTesting
        XCTAssertEqual(atan2(transform.m12, transform.m11) * 180 / .pi, -90, accuracy: 0.01)
        view.applyMapHeading(0)
        XCTAssertEqual(atan2(view.lobeTransformForTesting.m12, view.lobeTransformForTesting.m11), 0, accuracy: 0.01)
    }

    // MARK: Planche de rendu

    /// Rend les états du marqueur en image, pour l'inspection visuelle. N'écrit
    /// que si `SQ_MARKER_SHEET_PATH` est fourni : un test ne doit rien déposer
    /// sur disque sans qu'on le lui demande.
    func testRendersReferenceSheet() throws {
        guard let path = ProcessInfo.processInfo.environment["SQ_MARKER_SHEET_PATH"] else {
            throw XCTSkip("SQ_MARKER_SHEET_PATH non fourni")
        }
        let states: [(String, MapAnnotationPayload)] = [
            ("z14 · 4G", payload(reach: 24)),
            ("z15 · eNB", payload(reach: 32, hasEnb: true)),
            ("z16 · 5G, gNB inconnu", payload(reach: 44, hasEnb: true, has5G: true)),
            ("z16 · 5G identifié + photos", payload(reach: 44, hasEnb: true, hasGnb: true, has5G: true, photos: 3)),
            ("z16 · sans identification", payload(reach: 44, has5G: true)),
            ("cluster", payload(clusterCount: 128))
        ]
        let cell = CGSize(width: 120, height: 140)
        let size = CGSize(width: cell.width * CGFloat(states.count), height: cell.height)
        // ⚠️ Rendu HORS ÉCRAN : `layer.render(in:)` ne passe pas par le
        // compositeur, et rend les bordures arrondies moins fidèlement qu'à
        // l'écran (le liseré peut ressortir carré). Cette planche sert à
        // l'inspection d'ensemble — la géométrie exacte, elle, est vérifiée par
        // les assertions ci-dessus, pas par ces pixels. (`drawHierarchy` serait
        // fidèle mais ne dessine rien hors d'une app active.)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(SQColor.bg).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, state) in states.enumerated() {
                let view = markerView(state.1)
                let origin = CGPoint(
                    x: cell.width * CGFloat(index) + (cell.width - view.bounds.width) / 2,
                    y: (cell.height - 30 - view.bounds.height) / 2
                )
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: origin.x, y: origin.y)
                view.layer.render(in: context.cgContext)
                context.cgContext.restoreGState()

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: UIColor(SQColor.labelSecondary)
                ]
                let label = NSAttributedString(string: state.0, attributes: attributes)
                let bounds = label.boundingRect(
                    with: CGSize(width: cell.width - 8, height: 30),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                )
                label.draw(
                    with: CGRect(
                        x: cell.width * CGFloat(index) + (cell.width - bounds.width) / 2,
                        y: cell.height - 26,
                        width: bounds.width,
                        height: bounds.height
                    ),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                )
            }
        }
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: path))
    }
}
