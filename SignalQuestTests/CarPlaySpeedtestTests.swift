import CarPlay
import XCTest
@testable import SignalQuest

/// Verrouille l'écran Speedtest CarPlay (Lot 5).
///
/// Les enjeux ici ne sont pas la justesse de la mesure — le moteur est celui de
/// l'app, déjà couvert ailleurs — mais ce qu'on montre à quelqu'un qui conduit :
/// une seule valeur qui bouge, un seul test à la fois, et des chiffres qui ne
/// défilent pas trop vite pour être lus.
@MainActor
final class CarPlaySpeedtestTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Cadence d'affichage

    /// Le moteur émet plusieurs fois par seconde. Rejouer chaque émission ferait
    /// défiler des chiffres illisibles et malmènerait CarPlay.
    func testRefreshIsThrottled() {
        var throttle = SpeedtestRefreshThrottle()
        XCTAssertTrue(throttle.shouldEmit(now: t0, phaseChanged: false))
        XCTAssertFalse(throttle.shouldEmit(now: t0.addingTimeInterval(0.1), phaseChanged: false))
        XCTAssertTrue(throttle.shouldEmit(now: t0.addingTimeInterval(0.6), phaseChanged: false))
    }

    /// Un changement de phase passe TOUJOURS : « Envoi » qui succède à
    /// « Réception » est l'information la plus utile du test, la retarder d'une
    /// demi-seconde n'a aucun sens.
    func testPhaseChangeAlwaysPassesThroughTheThrottle() {
        var throttle = SpeedtestRefreshThrottle()
        _ = throttle.shouldEmit(now: t0, phaseChanged: false)
        XCTAssertTrue(throttle.shouldEmit(now: t0.addingTimeInterval(0.05), phaseChanged: true))
    }

    // MARK: - Un seul test à la fois

    /// Pendant la mesure, aucun bouton : deux tests concurrents se fausseraient
    /// mutuellement, et le conducteur n'a pas à deviner lequel il regarde.
    func testNoButtonWhileRunning() {
        let template = SpeedtestTemplateBuilder.make(
            state: .running(SpeedtestLiveProgress(phase: .download, currentMbps: 87)),
            actions: .init(start: {})
        )
        XCTAssertTrue(template.actions.isEmpty)
    }

    /// Au repos, une seule pression suffit à lancer — pas de réglage, pas de
    /// saisie : c'est une contrainte de revue autant que d'ergonomie.
    func testSingleTapToStart() {
        let template = SpeedtestTemplateBuilder.make(state: .idle(last: nil), actions: .init(start: {}))
        XCTAssertEqual(template.actions.count, 1)
    }

    func testFailureOffersARetry() {
        let template = SpeedtestTemplateBuilder.make(state: .failed("Réseau indisponible"),
                                                     actions: .init(start: {}))
        XCTAssertEqual(template.actions.count, 1)
        XCTAssertEqual(template.items.first?.detail, "Réseau indisponible")
    }

    // MARK: - Ce qui s'affiche

    /// Une seule valeur qui bouge à la fois : afficher les trois métriques
    /// ferait défiler trois nombres simultanément devant quelqu'un qui conduit.
    func testOnlyTheActivePhaseMetricIsShown() {
        let download = SpeedtestTemplateBuilder.items(
            for: .running(SpeedtestLiveProgress(phase: .download, currentMbps: 87, pingLiveMs: 24)))
        XCTAssertTrue(download.contains { $0.title == String(localized: "Débit") })
        XCTAssertFalse(download.contains { $0.title == String(localized: "Latence") })

        let ping = SpeedtestTemplateBuilder.items(
            for: .running(SpeedtestLiveProgress(phase: .ping, currentMbps: 0, pingLiveMs: 24)))
        XCTAssertTrue(ping.contains { $0.title == String(localized: "Latence") })
        XCTAssertFalse(ping.contains { $0.title == String(localized: "Débit") })
    }

    /// Sans mesure passée, on explique quoi faire plutôt que d'afficher un vide.
    func testEmptyStateExplainsWhatToDo() {
        let items = SpeedtestTemplateBuilder.items(for: .idle(last: nil))
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].detail?.isEmpty ?? true)
    }

    /// Toutes les phases doivent avoir un libellé : un état sans nom laisserait
    /// l'écran figé sur une valeur vide au milieu du test.
    func testEveryPhaseHasALabel() {
        let phases: [SpeedtestPhase] = [.idle, .ping, .download, .upload, .saving, .finished]
        for phase in phases {
            XCTAssertFalse(SpeedtestTemplateBuilder.phaseLabel(phase).isEmpty, "Phase sans libellé : \(phase)")
        }
        XCTAssertEqual(SpeedtestTemplateBuilder.phaseLabel(.failed("Timeout")), "Timeout")
    }

    /// Au-dessus de 10 Mb/s, la décimale n'apporte rien et allonge le nombre à
    /// lire ; en dessous, elle distingue 0,8 de 8.
    func testThroughputRoundingFavoursReadability() {
        XCTAssertEqual(SpeedtestTemplateBuilder.mbps(187.4), String(localized: "187 Mb/s"))
        // 8.26 et non 8.25 : ce dernier n'est pas représentable exactement en
        // binaire et `%.1f` l'arrondit à 8.2, ce qui testerait la norme IEEE 754
        // plutôt que notre règle d'affichage.
        XCTAssertEqual(SpeedtestTemplateBuilder.mbps(8.26), String(localized: "8.3 Mb/s"))
        XCTAssertEqual(SpeedtestTemplateBuilder.mbps(0.8), String(localized: "0.8 Mb/s"))
    }

    /// Plafonds CarPlay, y compris dans l'état le plus chargé.
    func testTemplateStaysWithinCarPlayLimits() {
        let template = SpeedtestTemplateBuilder.make(
            state: .running(SpeedtestLiveProgress(phase: .download, currentMbps: 87,
                                                  serverName: "Paris — OVH")),
            actions: .init(start: {})
        )
        XCTAssertLessThanOrEqual(template.items.count, CarPlayDetailTemplateBuilder.maxItems)
    }
}
