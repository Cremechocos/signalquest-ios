import CarPlay
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
              showHere: {}, showNearby: {}, stopGuidance: onStop, showSpeedtest: {},
              showPanning: {}, dismissPanning: {})
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

    // MARK: - Manœuvre ratée (CAR-04)

    /// Itinéraire en L : ~445 m vers le nord, virage à droite, ~290 m vers l'est.
    private func lShapedPlan() -> RoutePlan {
        let corner = CLLocationCoordinate2D(latitude: 48.854, longitude: 2.35)
        let end = CLLocationCoordinate2D(latitude: 48.854, longitude: 2.354)
        let polyline = [
            CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35),
            CLLocationCoordinate2D(latitude: 48.852, longitude: 2.35),
            corner,
            CLLocationCoordinate2D(latitude: 48.854, longitude: 2.352),
            end,
        ]
        return RoutePlan(
            polyline: polyline,
            steps: [
                RoutePlan.Step(instruction: "Tournez à droite", distanceMeters: 445, maneuverCoordinate: corner),
                RoutePlan.Step(instruction: "Vous êtes arrivé", distanceMeters: 293, maneuverCoordinate: end),
            ],
            totalDistanceMeters: 738,
            expectedTravelTime: 120
        )
    }

    /// Virage pris sans jamais passer à 25 m de son point (GPS décalé) : une
    /// fois sur la route suivante, le guidage passe à l'étape d'après au lieu
    /// de rester figé sur « Tournez à droite ».
    func testMissedManeuverAdvancesOnceOnTheNextRoad() {
        let tracker = RouteProgressTracker(plan: lShapedPlan())
        // 60 m après le virage, 12 m au nord de la route (≈ 61 m du point).
        let progress = tracker.update(with: CLLocation(latitude: 48.854108, longitude: 2.350819))
        XCTAssertEqual(progress.stepIndex, 1)
        XCTAssertFalse(progress.isOffRoute)
    }

    /// À l'arrêt 30 m avant le virage, la dérive du GPS ne doit pas faire
    /// annoncer la manœuvre suivante.
    func testWaitingBeforeTheTurnDoesNotAdvance() {
        let tracker = RouteProgressTracker(plan: lShapedPlan())
        for longitude in [2.35, 2.35008, 2.34992] {
            let progress = tracker.update(with: CLLocation(latitude: 48.85373, longitude: longitude))
            XCTAssertEqual(progress.stepIndex, 0)
        }
    }

    /// Le temps restant suit la distance, au lieu d'un zéro permanent.
    func testTimeRemainingIsProportionalToDistance() {
        let plan = lShapedPlan()
        XCTAssertEqual(ManeuverMapper.timeRemaining(forDistance: 369, in: plan), 60, accuracy: 0.001)
        XCTAssertEqual(ManeuverMapper.timeRemaining(forDistance: -5, in: plan), 0)
    }

    // MARK: - Pictogrammes en anglais (CAR-04)

    func testEnglishInstructionsGetTheirArrow() {
        XCTAssertEqual(ManeuverMapper.symbolName(for: "Turn right onto Main Street"), "arrow.turn.up.right")
        XCTAssertEqual(ManeuverMapper.symbolName(for: "Keep left at the fork"), "arrow.up.left")
        XCTAssertEqual(ManeuverMapper.symbolName(for: "Make a U-turn"), "arrow.uturn.left")
        XCTAssertEqual(ManeuverMapper.symbolName(for: "Enter the roundabout"), "arrow.triangle.turn.up.right.circle")
        XCTAssertEqual(ManeuverMapper.symbolName(for: "Tournez à gauche sur la rue de Rivoli"), "arrow.turn.up.left")
        XCTAssertEqual(ManeuverMapper.symbolName(for: "Continuez tout droit"), "arrow.up")
    }

    /// Le nom de la voie ne décide jamais du sens : « Wright » n'est pas « right ».
    func testStreetNameNeverFlipsTheArrow() {
        XCTAssertEqual(ManeuverMapper.symbolName(for: "Turn left onto Wright Street"), "arrow.turn.up.left")
        XCTAssertEqual(ManeuverMapper.symbolName(for: "Head toward Wrightsville"), "arrow.up")
        XCTAssertEqual(ManeuverMapper.instructionVariants(for: "Turn left onto Wright Street").last, "Turn left")
    }

    // MARK: - Voix

    /// La voix parle la langue des annonces, avec l'accent de l'appareil quand
    /// il parle la même langue.
    func testVoiceFollowsTheAppLanguage() {
        XCTAssertEqual(CarPlayVoiceGuide.voiceLanguage(appLanguage: "en", deviceLanguage: "fr-FR"), "en-US")
        XCTAssertEqual(CarPlayVoiceGuide.voiceLanguage(appLanguage: "fr", deviceLanguage: "fr-CA"), "fr-CA")
        XCTAssertEqual(CarPlayVoiceGuide.voiceLanguage(appLanguage: "en", deviceLanguage: "en-GB"), "en-GB")
        XCTAssertEqual(CarPlayVoiceGuide.voiceLanguage(appLanguage: "fr", deviceLanguage: "de-DE"), "fr-FR")
    }

    // MARK: - Carte : panoramique et délégué (CAR-03)

    /// Quatre boutons au plus ; le premier déplace la carte quand elle suit le
    /// véhicule, et la recentre une fois déplacée.
    func testFirstMapButtonSwitchesBetweenPanAndRecenter() {
        let following = CarPlayMapTemplateBuilder.mapButtons(isFollowingUser: true, actions: mapActions())
        let moved = CarPlayMapTemplateBuilder.mapButtons(isFollowingUser: false, actions: mapActions())
        XCTAssertEqual(following.count, 4)
        XCTAssertEqual(moved.count, 4)
        // Comparées au rendu : deux `UIImage` du même symbole ne sont pas
        // forcément le même objet.
        let pan = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")?.pngData()
        let recenter = UIImage(systemName: "location.fill")?.pngData()
        XCTAssertNotNil(pan)
        XCTAssertEqual(following.first?.image?.pngData(), pan)
        XCTAssertEqual(moved.first?.image?.pngData(), recenter)
    }

    /// CarPlay ne fournit aucun bouton pour sortir du panoramique ; « Arrêter »
    /// reste accessible pendant un trajet.
    func testPanningBarOffersDoneAndKeepsStop() {
        let idle = CarPlayMapTemplateBuilder.trailingButtons(isGuiding: false, isPanning: true, actions: mapActions())
        let guiding = CarPlayMapTemplateBuilder.trailingButtons(isGuiding: true, isPanning: true, actions: mapActions())
        XCTAssertEqual(idle.map(\.title), [String(localized: "Terminé")])
        XCTAssertEqual(guiding.map(\.title), [String(localized: "Terminé"), String(localized: "Arrêter")])
    }

    /// Le système transmet la translation cumulée du geste ; la carte reçoit
    /// des incréments, repartis de zéro à chaque nouveau geste.
    func testPanGestureIsForwardedAsIncrements() {
        let delegate = CarPlayMapTemplateDelegate()
        var deltas: [CGPoint] = []
        delegate.onPanGesture = { deltas.append($0) }
        let template = CPMapTemplate()

        delegate.mapTemplateDidBeginPanGesture(template)
        delegate.mapTemplate(template, didUpdatePanGestureWithTranslation: CGPoint(x: 10, y: 0), velocity: .zero)
        delegate.mapTemplate(template, didUpdatePanGestureWithTranslation: CGPoint(x: 25, y: -5), velocity: .zero)
        delegate.mapTemplateDidBeginPanGesture(template)
        delegate.mapTemplate(template, didUpdatePanGestureWithTranslation: CGPoint(x: 4, y: 4), velocity: .zero)

        XCTAssertEqual(deltas, [CGPoint(x: 10, y: 0), CGPoint(x: 15, y: -5), CGPoint(x: 4, y: 4)])
    }

    /// Navigation native du véhicule ou autre app de guidage : le système
    /// annule notre trajet, et il faut le savoir pour couper voix et GPS.
    func testSystemCancellationIsForwarded() {
        let delegate = CarPlayMapTemplateDelegate()
        var cancelled = 0
        delegate.onNavigationCancelledBySystem = { cancelled += 1 }
        delegate.mapTemplateDidCancelNavigation(CPMapTemplate())
        XCTAssertEqual(cancelled, 1)
        XCTAssertTrue(delegate.mapTemplate(CPMapTemplate(), shouldShowNotificationFor: CPManeuver()),
                      "La manœuvre s'affiche en bannière quand l'écran montre une autre app")
    }
}
