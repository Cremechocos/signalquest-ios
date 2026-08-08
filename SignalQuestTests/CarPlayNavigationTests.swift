import CoreLocation
import XCTest
@testable import SignalQuest

/// Verrouille le guidage CarPlay (Lot 3).
///
/// C'est le lot le plus couvert du chantier, et pour une raison précise : MapKit
/// calcule l'itinéraire mais ne guide pas. Le suivi, la détection de sortie de
/// route, le budget de recalcul et le rythme des annonces sont écrits par nous —
/// donc faux par défaut tant que rien ne les vérifie. Et une erreur ici n'est
/// pas un pixel de travers : c'est une instruction donnée au mauvais moment à
/// quelqu'un qui conduit.
@MainActor
final class CarPlayNavigationTests: XCTestCase {

    /// Itinéraire droit vers l'est, ~700 m, une seule manœuvre à la fin.
    private func straightPlan() -> RoutePlan {
        let coordinates = (0...7).map {
            CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35 + Double($0) * 0.001)
        }
        return RoutePlan(
            polyline: coordinates,
            steps: [
                RoutePlan.Step(instruction: "Tournez à droite sur la rue de Rivoli",
                               distanceMeters: 700,
                               maneuverCoordinate: coordinates.last!)
            ],
            totalDistanceMeters: 700,
            expectedTravelTime: 90
        )
    }

    // MARK: - Géométrie

    /// Le point le plus proche d'un tracé est sur un SEGMENT, pas sur un sommet.
    /// Mesurer jusqu'au sommet le plus proche donnerait un écart énorme au milieu
    /// d'une ligne droite à sommets espacés — et déclencherait un recalcul alors
    /// qu'on roule exactement sur la route.
    func testDistanceIsMeasuredToTheSegmentNotTheVertex() {
        let start = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)
        let end = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.36)
        // Pile au milieu du segment, sur la ligne.
        let middle = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.355)
        let toSegment = RouteProgressTracker.distanceToSegment(middle, start, end)
        XCTAssertLessThan(toSegment, 1, "Sur la ligne, l'écart doit être quasi nul")

        let toNearestVertex = min(RouteProgressTracker.distance(from: middle, to: start),
                                  RouteProgressTracker.distance(from: middle, to: end))
        XCTAssertGreaterThan(toNearestVertex, 300, "Le sommet le plus proche est pourtant loin")
    }

    /// Au-delà du segment, le point le plus proche est une extrémité.
    ///
    /// Tolérance à 0,5 % et non en mètres absolus : la projection travaille en
    /// plan local, `CLLocation.distance` en géodésique. L'écart croît avec la
    /// distance (ici ~5 m sur 2,9 km) et n'a aucune incidence sur l'usage réel,
    /// où l'on mesure des écarts de quelques dizaines de mètres.
    func testProjectionIsClampedToTheSegment() {
        let start = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)
        let end = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.36)
        let beyond = CLLocationCoordinate2D(latitude: 48.85, longitude: 2.40)
        let toSegment = RouteProgressTracker.distanceToSegment(beyond, start, end)
        let toEnd = RouteProgressTracker.distance(from: beyond, to: end)
        XCTAssertEqual(toSegment, toEnd, accuracy: toEnd * 0.005)
    }

    // MARK: - Sortie de route

    /// Un seul point aberrant ne doit RIEN déclencher : en ville, un GPS masqué
    /// par les immeubles dérive de 20 à 30 m sans que personne n'ait tourné, et
    /// chaque recalcul se paie sur un quota Apple.
    func testSingleGpsGlitchDoesNotTriggerOffRoute() {
        let tracker = RouteProgressTracker(plan: straightPlan(), confirmationsRequired: 3)
        let onRoute = CLLocation(latitude: 48.85, longitude: 2.352)
        let glitch = CLLocation(latitude: 48.86, longitude: 2.352) // ~1,1 km au nord

        _ = tracker.update(with: onRoute)
        let afterGlitch = tracker.update(with: glitch)
        XCTAssertGreaterThan(afterGlitch.offRouteMeters, 50, "L'écart est bien mesuré…")
        XCTAssertFalse(afterGlitch.isOffRoute, "…mais un point isolé ne confirme rien")
    }

    /// En revanche, une sortie soutenue doit être déclarée.
    func testSustainedDeviationIsConfirmed() {
        let tracker = RouteProgressTracker(plan: straightPlan(), confirmationsRequired: 3)
        let off = CLLocation(latitude: 48.86, longitude: 2.352)
        _ = tracker.update(with: off)
        _ = tracker.update(with: off)
        XCTAssertTrue(tracker.update(with: off).isOffRoute)
    }

    /// Revenir sur l'itinéraire doit remettre le compteur à zéro, sinon deux
    /// écarts espacés d'un kilomètre finiraient par se cumuler.
    func testReturningToRouteResetsConfirmations() {
        let tracker = RouteProgressTracker(plan: straightPlan(), confirmationsRequired: 3)
        let off = CLLocation(latitude: 48.86, longitude: 2.352)
        let on = CLLocation(latitude: 48.85, longitude: 2.352)
        _ = tracker.update(with: off)
        _ = tracker.update(with: off)
        _ = tracker.update(with: on)
        XCTAssertFalse(tracker.update(with: off).isOffRoute)
    }

    // MARK: - Progression

    func testDistanceToManeuverDecreasesWhileApproaching() {
        let plan = straightPlan()
        let tracker = RouteProgressTracker(plan: plan)
        let far = tracker.update(with: CLLocation(latitude: 48.85, longitude: 2.351))
        let near = tracker.update(with: CLLocation(latitude: 48.85, longitude: 2.356))
        XCTAssertLessThan(near.distanceToManeuver, far.distanceToManeuver)
    }

    func testArrivalIsDetectedAtDestination() {
        let plan = straightPlan()
        let tracker = RouteProgressTracker(plan: plan)
        let progress = tracker.update(with: CLLocation(latitude: 48.85, longitude: 2.357))
        XCTAssertTrue(progress.hasArrived)
    }

    // MARK: - Budget de recalcul

    /// `MKDirections` est throttlé par Apple : recalculer à chaque sortie
    /// détectée épuiserait le quota et arrêterait le guidage pour de bon.
    func testRecalculationIsRateLimited() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let service = CarPlayRouteService(now: { now })

        XCTAssertTrue(service.canRecalculate(), "Le premier calcul est toujours permis")
        // Simule une requête émise à l'instant courant, sans réseau.
        service.noteRequest()
        XCTAssertFalse(service.canRecalculate(), "Deux recalculs coup sur coup : refusé")

        now = now.addingTimeInterval(CarPlayRouteService.minimumRecalculationInterval + 1)
        XCTAssertTrue(service.canRecalculate(), "Passé le délai, c'est de nouveau permis")
    }

    // MARK: - Annonces vocales

    /// Trois paliers, dans l'ordre décroissant, une seule fois chacun.
    func testAnnouncementsFireOncePerThreshold() {
        XCTAssertEqual(VoiceAnnouncementPolicy.announcement(distanceToManeuver: 900, lastAnnounced: nil), nil)
        XCTAssertEqual(VoiceAnnouncementPolicy.announcement(distanceToManeuver: 700, lastAnnounced: nil), 800)
        XCTAssertEqual(VoiceAnnouncementPolicy.announcement(distanceToManeuver: 700, lastAnnounced: 800), nil)
        XCTAssertEqual(VoiceAnnouncementPolicy.announcement(distanceToManeuver: 250, lastAnnounced: 800), 300)
        XCTAssertEqual(VoiceAnnouncementPolicy.announcement(distanceToManeuver: 40, lastAnnounced: 300), 50)
    }

    /// Un recul GPS ne doit pas relancer une annonce déjà faite : le conducteur
    /// entendrait « Dans 300 mètres » deux fois pour la même manœuvre.
    func testBackwardsGpsDoesNotRepeatAnAnnouncement() {
        XCTAssertNil(VoiceAnnouncementPolicy.announcement(distanceToManeuver: 320, lastAnnounced: 300))
    }

    /// Sur un fix espacé (route rapide), on saute directement au bon palier
    /// plutôt que d'annoncer « dans 800 m » alors qu'il en reste 200.
    func testFastApproachSkipsToTheRelevantThreshold() {
        XCTAssertEqual(VoiceAnnouncementPolicy.announcement(distanceToManeuver: 200, lastAnnounced: nil), 300)
    }

    /// Au dernier palier, on prononce l'instruction seule : « Dans 50 mètres,
    /// tournez » arriverait après le carrefour.
    func testFinalAnnouncementDropsTheDistance() {
        let text = VoiceAnnouncementPolicy.spokenText(instruction: "Tournez à droite", threshold: 50)
        XCTAssertEqual(text, "Tournez à droite")
    }

    // MARK: - Manœuvres

    /// Un symbole faux est pire que pas de symbole : il enverrait le conducteur
    /// du mauvais côté. Le repli doit être neutre.
    func testUnknownInstructionFallsBackToNeutralSymbol() {
        XCTAssertNotNil(ManeuverMapper.symbol(for: "Continuez sur 2 kilomètres"))
        XCTAssertNotNil(ManeuverMapper.symbol(for: "Tournez à gauche"))
    }

    /// CarPlay choisit la variante qui tient dans la largeur du véhicule : il en
    /// faut au moins une courte quand l'instruction est longue.
    func testInstructionVariantsOfferAShortForm() {
        let variants = ManeuverMapper.instructionVariants(for: "Tournez à droite sur la rue de Rivoli")
        XCTAssertEqual(variants.count, 2)
        XCTAssertEqual(variants.last, "Tournez à droite")
        XCTAssertLessThan(variants.last!.count, variants.first!.count)
    }

    func testEmptyInstructionStillProducesSomethingToSay() {
        XCTAssertFalse(ManeuverMapper.instructionVariants(for: "   ").first!.isEmpty)
    }

    /// On pousse la manœuvre courante et la suivante, jamais au-delà de la fin.
    func testManeuverLookaheadStopsAtTheLastStep() {
        let plan = straightPlan()
        XCTAssertEqual(ManeuverMapper.maneuvers(for: plan, from: 0).count, 1)
        XCTAssertTrue(ManeuverMapper.maneuvers(for: plan, from: 1).isEmpty)
    }

    // MARK: - Arrêt du guidage

    private func mapActions(onStop: @escaping () -> Void = {}) -> CarPlayMapTemplateBuilder.Actions {
        .init(recenter: {}, zoomIn: {}, zoomOut: {}, showLayers: {},
              showHere: {}, showNearby: {}, stopGuidance: onStop, showSpeedtest: {})
    }

    /// Un guidage qu'on ne peut pas interrompre depuis l'écran du véhicule est
    /// un motif de rejet en revue — et personne ne décrochera son iPhone en
    /// roulant pour arrêter un itinéraire.
    func testStopButtonAppearsOnlyWhileGuiding() {
        let idle = CarPlayMapTemplateBuilder.trailingButtons(isGuiding: false, actions: mapActions())
        let guiding = CarPlayMapTemplateBuilder.trailingButtons(isGuiding: true, actions: mapActions())
        XCTAssertEqual(idle.count, 1, "Hors guidage, pas de bouton d'arrêt à occuper la barre")
        XCTAssertEqual(guiding.count, 2)
    }

    /// CarPlay plafonne à deux boutons par côté de barre.
    func testTrailingButtonsStayWithinCarPlayLimit() {
        XCTAssertLessThanOrEqual(
            CarPlayMapTemplateBuilder.trailingButtons(isGuiding: true, actions: mapActions()).count, 2)
    }

    /// Le plus à droite, donc le plus facile à viser : c'est l'action la plus
    /// recherchée pendant un trajet.
    func testStopButtonIsTheOutermost() {
        let buttons = CarPlayMapTemplateBuilder.trailingButtons(isGuiding: true, actions: mapActions())
        XCTAssertEqual(buttons.last?.title, String(localized: "Arrêter"))
    }

    // Pas de test d'invocation du handler : `CPBarButton` ne l'expose qu'à
    // l'init, il n'est pas relisible. Le câblage effectif de `stopGuidance` se
    // vérifie donc en voiture (ou au simulateur CarPlay), pas ici.
}
