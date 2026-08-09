import CarPlay
import CoreLocation
import XCTest
@testable import SignalQuest

/// Verrouille la politique d'alerte CarPlay (Lot 8).
///
/// C'est la règle la plus facile à rendre insupportable de tout le chantier :
/// une alerte de trop pendant la conduite, et l'app se désinstalle. Chaque
/// garde-fou a donc son test, y compris ceux qui paraissent évidents.
@MainActor
final class CarPlayAlertPolicyTests: XCTestCase {

    private let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func context(
        isEnabled: Bool = true,
        verdict: CoverageQualityBand? = .poor,
        sampleCount: Int = 50,
        speed: CLLocationSpeed = 20,
        coordinate: CLLocationCoordinate2D? = nil,
        lastAlertAt: Date? = nil,
        lastAlertCoordinate: CLLocationCoordinate2D? = nil,
        now: Date? = nil,
        isManeuverImminent: Bool = false
    ) -> CarPlayAlertPolicy.Context {
        .init(isEnabled: isEnabled, verdict: verdict, sampleCount: sampleCount, speed: speed,
              coordinate: coordinate ?? paris, lastAlertAt: lastAlertAt,
              lastAlertCoordinate: lastAlertCoordinate, now: now ?? t0,
              isManeuverImminent: isManeuverImminent)
    }

    func testAlertsFireOnPoorCoverage() {
        XCTAssertTrue(CarPlayAlertPolicy.shouldAlert(context()))
    }

    /// Opt-in : personne ne doit découvrir cette fonctionnalité en sursautant.
    func testNothingHappensWhenDisabled() {
        XCTAssertFalse(CarPlayAlertPolicy.shouldAlert(context(isEnabled: false)))
    }

    /// Rien ne doit couvrir une manœuvre annoncée : le conducteur a besoin de
    /// son attention pour tourner, pas pour apprendre que le réseau est mauvais.
    func testManeuverSilencesTheAlert() {
        XCTAssertFalse(CarPlayAlertPolicy.shouldAlert(context(isManeuverImminent: true)))
    }

    /// Un bon réseau n'a rien à signaler.
    func testGoodCoverageNeverAlerts() {
        for band in [CoverageQualityBand.excellent, .good, .fair, .unknown] {
            XCTAssertFalse(CarPlayAlertPolicy.shouldAlert(context(verdict: band)),
                           "\(band) ne doit pas alerter")
        }
    }

    /// « Mauvais sur trois relevés » est une fausse alerte présentée comme un
    /// fait. On exige un socle de mesures.
    func testThinEvidenceDoesNotAlert() {
        XCTAssertFalse(CarPlayAlertPolicy.shouldAlert(context(sampleCount: 3)))
    }

    /// À l'arrêt, on ne « traverse » rien : l'alerte serait du bruit.
    func testStandingStillDoesNotAlert() {
        XCTAssertFalse(CarPlayAlertPolicy.shouldAlert(context(speed: 0)))
        XCTAssertFalse(CarPlayAlertPolicy.shouldAlert(context(speed: 2)))
    }

    /// Pas deux alertes coup sur coup.
    func testAlertsAreRateLimited() {
        let recent = t0.addingTimeInterval(-60)
        XCTAssertFalse(CarPlayAlertPolicy.shouldAlert(context(lastAlertAt: recent)))

        let old = t0.addingTimeInterval(-CarPlayAlertPolicy.minimumInterval - 1)
        XCTAssertTrue(CarPlayAlertPolicy.shouldAlert(
            context(lastAlertAt: old,
                    // Zone différente, sinon c'est l'autre garde-fou qui bloque.
                    lastAlertCoordinate: CLLocationCoordinate2D(latitude: 49.5, longitude: 2.35))))
    }

    /// Deux alertes pour la même zone, c'est une alerte de trop — y compris
    /// après le délai, par exemple sur un aller-retour.
    func testSameZoneIsNeverAlertedTwice() {
        let old = t0.addingTimeInterval(-CarPlayAlertPolicy.minimumInterval - 1)
        let nearby = CLLocationCoordinate2D(latitude: 48.858, longitude: 2.354)
        XCTAssertFalse(CarPlayAlertPolicy.shouldAlert(
            context(lastAlertAt: old, lastAlertCoordinate: nearby)))
    }

    /// Une zone franchement différente, elle, peut alerter.
    func testDistantZoneCanAlertAgain() {
        let old = t0.addingTimeInterval(-CarPlayAlertPolicy.minimumInterval - 1)
        let faraway = CLLocationCoordinate2D(latitude: 48.90, longitude: 2.35)
        XCTAssertTrue(CarPlayAlertPolicy.shouldAlert(
            context(lastAlertAt: old, lastAlertCoordinate: faraway)))
    }

    /// Le message nomme l'opérateur : « réseau mauvais » sans dire pour qui
    /// laisserait croire que c'est le cas pour tout le monde.
    func testMessageNamesTheOperator() {
        let message = CarPlayAlertPolicy.message(for: .poor, operatorLabel: "Orange")
        XCTAssertTrue(message.contains("Orange"))
    }

    // MARK: - Catégories

    /// Sans `.allowInCarPlay`, iOS ne relaie RIEN vers l'écran du véhicule, même
    /// si la notification s'affiche parfaitement sur l'iPhone.
    func testEveryCategoryIsAllowedInCarPlay() {
        let categories = CarPlayNotificationCategories.all()
        XCTAssertFalse(categories.isEmpty)
        for category in categories {
            XCTAssertTrue(category.options.contains(.allowInCarPlay),
                          "\(category.identifier) n'atteindrait jamais CarPlay")
        }
    }

    /// L'identifiant Sentinelle doit rester CELUI attendu par le backend : c'est
    /// le seul lien entre le payload APNs et l'affichage dans le véhicule.
    func testSentinelleCategoryIdentifierIsStable() {
        XCTAssertEqual(CarPlayNotificationCategories.sentinelleAlert, "SENTINELLE_ALERT")
    }
}
