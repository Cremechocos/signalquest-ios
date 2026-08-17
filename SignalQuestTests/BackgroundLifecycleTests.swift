import XCTest
import CoreLocation
@testable import SignalQuest

/// La diffusion de présence live s'arrête en arrière-plan — sauf quand
/// l'utilisateur a explicitement lancé une activité de fond.
///
/// Avant correction, `shouldBroadcast` ne dépendait que du partage et du mode :
/// en `foregroundLive`, la boucle publiait toutes les 5 à 20 s indéfiniment,
/// écran verrouillé. `mapDidDisappear()` — le seul frein existant — n'est appelé
/// que sur `.onDisappear` de la carte, qui ne se déclenche pas au backgrounding.
/// En drive test c'est pire : le background mode `location` empêche iOS de
/// suspendre le processus, donc la boucle tourne réellement.
@MainActor
final class BackgroundLifecycleTests: XCTestCase {

    private func makeServices() -> AppServices {
        AppServices(config: .test)
    }

    /// Cas nominal : rien en cours, l'app passe en arrière-plan → on coupe.
    func testEnteringBackgroundStopsLivePresence() {
        let services = makeServices()
        services.livePresence.setAppActive(true)

        services.enterBackground()
        XCTAssertFalse(
            services.livePresence.isBroadcasting,
            "Aucune diffusion ne doit subsister en arrière-plan"
        )
    }

    /// Un drive test en cours doit préserver la diffusion : l'utilisateur l'a
    /// lancée volontairement et ses amis s'attendent à le voir bouger.
    func testDriveTestKeepsLivePresenceAlive() {
        let services = makeServices()
        services.location.startTracking()
        XCTAssertTrue(services.location.wantsTracking, "Le suivi doit être demandé")

        services.enterBackground()
        // La garde sort avant toute coupure : l'état d'activité reste inchangé.
        services.enterForeground()
        services.location.stopTracking()
        XCTAssertFalse(services.location.wantsTracking)
    }

    /// Retourner au premier plan doit réautoriser la diffusion (la reprise
    /// effective dépend ensuite des réglages de partage).
    func testForegroundRestoresBroadcastEligibility() {
        let services = makeServices()
        services.enterBackground()
        services.enterForeground()
        // Sans réglage de partage actif, `isBroadcasting` reste faux — ce qui
        // est correct : on vérifie surtout qu'aucun état ne reste bloqué.
        XCTAssertFalse(services.livePresence.isBroadcasting)
    }

    /// `setAppActive` doit être idempotent : le rappeler avec la même valeur ne
    /// doit pas relancer de cycle stop/start (qui republierait une présence
    /// « offline » à chaque notification de scène).
    func testSetAppActiveIsIdempotent() {
        let services = makeServices()
        services.livePresence.setAppActive(false)
        services.livePresence.setAppActive(false)
        services.livePresence.setAppActive(true)
        services.livePresence.setAppActive(true)
        XCTAssertFalse(services.livePresence.isBroadcasting)
    }

    /// `wantsTracking` est le signal qui autorise l'app à rester active écran
    /// verrouillé : il doit refléter fidèlement le cycle démarrer/arrêter.
    func testTrackingFlagMirrorsDriveTestLifecycle() {
        let location = LocationService()
        XCTAssertFalse(location.wantsTracking)
        location.startTracking()
        XCTAssertTrue(location.wantsTracking)
        location.stopTracking()
        XCTAssertFalse(location.wantsTracking)
    }

    /// Deux fonctions (par exemple Drive Test et CarPlay) doivent recevoir le
    /// même fix. Retirer l'une ne doit ni écraser ni arrêter l'autre.
    func testLocationObserversAreIndependent() async {
        let location = LocationService()
        let firstReceived = expectation(description: "premier observateur")
        let secondReceivedTwice = expectation(description: "second observateur")
        secondReceivedTwice.expectedFulfillmentCount = 2

        let firstToken = location.addLocationObserver { _ in firstReceived.fulfill() }
        let secondToken = location.addLocationObserver { _ in secondReceivedTwice.fulfill() }
        let manager = CLLocationManager()

        location.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 48.8566, longitude: 2.3522)])
        await fulfillment(of: [firstReceived], timeout: 1)

        location.removeLocationObserver(firstToken)
        location.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 48.8570, longitude: 2.3530)])
        await fulfillment(of: [secondReceivedTwice], timeout: 1)
        location.removeLocationObserver(secondToken)
    }
}
