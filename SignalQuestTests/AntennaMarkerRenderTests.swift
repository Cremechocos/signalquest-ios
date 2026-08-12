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

    // MARK: Pannes communautaires

    private func outagePayload(
        severity: OutageSeverity,
        confirmed: Bool
    ) -> MapAnnotationPayload {
        MapAnnotationPayload(
            id: "community-outage-1", kind: .communityOutage, title: "Site 3079254", subtitle: "SFR",
            coordinate: CLLocationCoordinate2D(latitude: 45.18, longitude: 5.72),
            metric: nil, backendId: "abc", details: nil, antennaId: nil, clusterCount: nil,
            azimuths: [], showsAzimuths: false,
            communityOutage: CommunityOutageMark(severity: severity, confirmed: confirmed)
        )
    }

    /// Le défaut trouvé sur Android : le glyphe était peint en crème quelle que
    /// soit la pastille, donc invisible sur le jaune « dégradé » (~1,8:1). L'encre
    /// doit suivre le remplissage, pas une constante.
    ///
    /// Le témoin d'origine opposait l'ambre au rouge, qui recevaient alors deux
    /// encres distinctes. L'ambre est depuis passé de #EAB308 à #B45309 (palette de
    /// gravité réalignée sur Android) : les deux pastilles sont maintenant sombres
    /// et partagent LÉGITIMEMENT le crème. La propriété qui compte — l'encre se
    /// calcule contre ce qu'on peint — se vérifie donc sur `ink(on:)` lui-même, un
    /// aplat clair face à un aplat sombre.
    func testGlyphInkFollowsTheFillLuminance() throws {
        let degraded = markerView(outagePayload(severity: .degraded, confirmed: true))
        let down = markerView(outagePayload(severity: .down, confirmed: true))
        let onAmber = try XCTUnwrap(degraded.glyphColorForTesting)
        let onRed = try XCTUnwrap(down.glyphColorForTesting)
        // Plancher 3:1 de WCAG 1.4.11 : un pictogramme est un objet graphique, pas
        // du texte. En crème, le jaune d'avant tombait à ~1,8 — sous la moitié.
        XCTAssertGreaterThan(
            contrast(onAmber, UIColor(OutageTint.degraded)), 3,
            "Le glyphe doit rester lisible sur la pastille « dégradé »"
        )
        XCTAssertGreaterThan(contrast(onRed, UIColor(OutageTint.down)), 3)
        // RÉSOLUES avant comparaison : `ink(on:)` rend un `UIColor` dynamique, et
        // deux instances dynamiques distinctes ne sont jamais égales — l'assertion
        // aurait passé quoi qu'il arrive.
        let light = UITraitCollection(userInterfaceStyle: .light)
        XCTAssertNotEqual(
            SQMapKitMarkerView.ink(on: .white).resolvedColor(with: light),
            SQMapKitMarkerView.ink(on: UIColor(OutageTint.down)).resolvedColor(with: light),
            "Un aplat clair et un aplat sombre ne peuvent pas partager la même encre"
        )
    }

    /// Signalée ≠ confirmée : la pastille évidée empêche une voix isolée de se
    /// lire comme un fait établi.
    func testReportedOutageIsHollowAndConfirmedIsSolid() throws {
        let reported = markerView(outagePayload(severity: .down, confirmed: false))
        let confirmed = markerView(outagePayload(severity: .down, confirmed: true))
        let tint = try XCTUnwrap(UIColor(OutageTint.down).cgColor.components)
        XCTAssertNotEqual(try XCTUnwrap(reported.dot.backgroundColor?.cgColor.components), tint)
        XCTAssertEqual(try XCTUnwrap(reported.dot.layer.borderColor?.components), tint)
        XCTAssertEqual(try XCTUnwrap(confirmed.dot.backgroundColor?.cgColor.components), tint)
        XCTAssertNotEqual(try XCTUnwrap(confirmed.dot.layer.borderColor?.components), tint)
    }

    /// Couche pannes éteinte : la panne n'est qu'un badge sur le point d'antenne,
    /// qui reste une antenne — même taille, même remplissage opérateur.
    func testOutageBadgeAnnotatesTheAntennaWithoutRepaintingIt() throws {
        let plain = markerView(payload())
        var annotated = payload()
        annotated.communityOutage = CommunityOutageMark(severity: .degraded, confirmed: false)
        let view = markerView(annotated)
        XCTAssertTrue(plain.outageBadgeIsHiddenForTesting)
        XCTAssertFalse(view.outageBadgeIsHiddenForTesting)
        XCTAssertEqual(view.dot.frame.width, plain.dot.frame.width)
        XCTAssertEqual(
            try XCTUnwrap(view.dot.backgroundColor?.cgColor.components),
            try XCTUnwrap(plain.dot.backgroundColor?.cgColor.components),
            "Le badge annote l'antenne, il ne la repeint pas"
        )
    }

    // MARK: Incidents opérateurs (parité)

    /// Le trou de la vague 3 : une antenne que l'OPÉRATEUR déclare hors service ne portait
    /// AUCUNE marque filtre éteint, alors qu'un simple signalement d'utilisateur en portait une.
    /// C'est l'information la plus fiable qui s'effaçait.
    func testOperatorIncidentBadgeAnnotatesTheAntenna() throws {
        let plain = markerView(payload())
        var annotated = payload()
        annotated.operatorIncident = OperatorIncidentMark(issueType: "down")
        let view = markerView(annotated)
        XCTAssertTrue(plain.operatorBadgeIsHiddenForTesting)
        XCTAssertFalse(view.operatorBadgeIsHiddenForTesting)
        XCTAssertEqual(view.dot.frame.width, plain.dot.frame.width)
        XCTAssertEqual(
            try XCTUnwrap(view.dot.backgroundColor?.cgColor.components),
            try XCTUnwrap(plain.dot.backgroundColor?.cgColor.components),
            "Le badge annote l'antenne, il ne la repeint pas"
        )
    }

    /// Le cas qui vaut toute la fonctionnalité : l'opérateur reconnaît ce que la communauté a
    /// signalé. Les deux badges doivent coexister — et occuper deux diagonales distinctes, sinon
    /// l'un masque l'autre et l'on croit qu'une seule des deux sources s'exprime.
    func testBothOutageBadgesCoexistOnDistinctCorners() {
        var annotated = payload()
        annotated.communityOutage = CommunityOutageMark(severity: .down, confirmed: true)
        annotated.operatorIncident = OperatorIncidentMark(issueType: "down")
        let view = markerView(annotated)
        XCTAssertFalse(view.outageBadgeIsHiddenForTesting)
        XCTAssertFalse(view.operatorBadgeIsHiddenForTesting)
        XCTAssertFalse(
            view.outageBadgeFrameForTesting.intersects(view.operatorBadgeFrameForTesting),
            "Les deux badges doivent occuper deux diagonales distinctes"
        )
    }

    /// Le badge communautaire n'est PAS réservé aux antennes officielles : dans les 44 marchés
    /// sans référentiel public, un site posé à la main est le seul point qui puisse en porter un.
    /// La garde `kind == .antenna` d'avant y faisait disparaître la panne entièrement.
    func testCommunityBadgeAlsoRidesOnACustomSite() {
        var custom = MapAnnotationPayload(
            id: "custom-site-42", kind: .customSite, title: "Pylône du col", subtitle: "BH Telecom",
            coordinate: CLLocationCoordinate2D(latitude: 43.85, longitude: 18.41),
            metric: nil, backendId: "42", details: nil, antennaId: nil, clusterCount: nil,
            azimuths: [], showsAzimuths: false
        )
        custom.communityOutage = CommunityOutageMark(severity: .down, confirmed: false)
        XCTAssertFalse(markerView(custom).outageBadgeIsHiddenForTesting)
    }

    /// « Une cible = une destination » : les 36 pt de la panne posés sur les 26 pt
    /// de l'antenne masquaient le point et le rendaient intappable. `centerOffset`
    /// déplace la vue entière, donc la zone tactile suit le dessin.
    func testCommunityOutageMarkerStepsAsideFromTheAntennaPoint() {
        let outage = markerView(outagePayload(severity: .down, confirmed: true))
        let offset = outage.centerOffset
        let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        // Somme des deux rayons : en deçà, les pastilles se chevauchent encore.
        // La tolérance absorbe le √2 du calcul en diagonale, pas un écart de règle.
        XCTAssertGreaterThan(distance, 26 / 2 + 36 / 2 - 0.001)
        XCTAssertGreaterThan(offset.x, 0, "Vers la droite, comme Android")
        XCTAssertLessThan(offset.y, 0, "Vers le haut, comme Android")
        XCTAssertEqual(markerView(payload()).centerOffset, .zero,
                       "L'antenne, elle, reste sur sa coordonnée")
    }

    /// Un cluster de pannes siège au barycentre d'un groupe et ne désigne aucun
    /// pylône : l'écarter le détacherait de ce qu'il résume.
    func testCommunityOutageClusterStaysOnItsCoordinate() {
        let view = markerView(MapAnnotationPayload(
            id: "community-outage-cluster-1", kind: .communityOutage, title: "12 pannes signalées",
            subtitle: "Zoomer pour le détail",
            coordinate: CLLocationCoordinate2D(latitude: 45.18, longitude: 5.72),
            metric: "cluster", backendId: nil, details: nil, antennaId: nil,
            clusterCount: 12, azimuths: [], showsAzimuths: false
        ))
        XCTAssertEqual(view.centerOffset, .zero)
    }

    /// L'encre doit rester DYNAMIQUE : `dot.backgroundColor` reçoit des couleurs à
    /// deux variantes qu'UIKit re-résout seul au basculement de thème. Une encre
    /// figée à l'instant d'`apply` resterait celle de l'ancien thème sur un fond
    /// qui, lui, a changé.
    func testInkIsRecomputedForEachInterfaceStyle() {
        // Fond clair en mode sombre, fond sombre en mode clair : deux thèmes,
        // deux décisions opposées. Une constante ne pourrait pas les tenir.
        let flipping = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
        let ink = SQMapKitMarkerView.ink(on: flipping)
        let inLight = ink.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let inDark = ink.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertNotEqual(inLight, inDark, "L'encre ne suit plus le thème")
        XCTAssertGreaterThan(contrast(inLight, .black), 3, "Encre illisible sur le fond clair")
        XCTAssertGreaterThan(contrast(inDark, .white), 3, "Encre illisible sur le fond sombre")
    }

    /// Le décalage doit être remis à zéro sur une vue RECYCLÉE, pas seulement neuve.
    ///
    /// Toutes ces pastilles partagent un unique identifiant de recyclage
    /// (`SQMapKitMarkerView.reuseID`) : MapKit réemploie donc la vue d'un marqueur de panne pour
    /// un cluster dès qu'on dézoome, ou pour une antenne. Les deux témoins voisins construisent
    /// chacun leur vue et ne peuvent rien dire de ce cas — le seul qui existe sur la carte.
    ///
    /// L'invariant tient aujourd'hui parce que `resize(to:radius:)` remet `centerOffset` à zéro
    /// et qu'il est appelé sur les DEUX branches d'`apply`. C'est un effet de bord, pas une
    /// intention écrite : déplacer la pose du décalage avant `resize`, ou retirer cette ligne de
    /// `resize`, décalerait silencieusement clusters et antennes de 31 pt.
    func testRecycledViewClearsTheOutageOffset() {
        let view = markerView(outagePayload(severity: .down, confirmed: true))
        XCTAssertNotEqual(view.centerOffset, .zero)

        view.apply(MapAnnotationPayload(
            id: "community-outage-cluster-1", kind: .communityOutage, title: "12 pannes signalées",
            subtitle: "Zoomer pour le détail",
            coordinate: CLLocationCoordinate2D(latitude: 45.18, longitude: 5.72),
            metric: "cluster", backendId: nil, details: nil, antennaId: nil,
            clusterCount: 12, azimuths: [], showsAzimuths: false
        ))
        XCTAssertEqual(view.centerOffset, .zero, "Un cluster réemployé garde le décalage de la panne")

        view.apply(outagePayload(severity: .down, confirmed: true))
        view.apply(payload())
        XCTAssertEqual(view.centerOffset, .zero, "Une antenne réemployée garde le décalage de la panne")
    }

    /// Rapport de contraste WCAG entre deux couleurs opaques.
    private func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        func luminance(_ color: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, al: CGFloat = 0
            color.getRed(&r, green: &g, blue: &bl, alpha: &al)
            func linear(_ c: CGFloat) -> CGFloat {
                c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(bl)
        }
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
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
