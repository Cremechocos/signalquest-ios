import Foundation
import CoreLocation

/// Cadence des mesures du Drive Test (MES-03).
///
/// La DISTANCE déclenche les mesures : c'est elle qui répartit les points sur le
/// trajet. Le temps ne sert plus que de repli tant qu'aucune position n'a été
/// reçue — sans ce repli, une session sans GPS ne mesurerait jamais. À l'arrêt
/// prolongé, la session se met en pause au lieu d'enchaîner un test toutes les
/// 30 s, qui consommait plusieurs Go par heure au même endroit.
enum DriveTestCadence {
    enum Decision: Equatable {
        /// Lancer une mesure maintenant.
        case testNow
        /// Attendre de parcourir encore `metersRemaining` mètres.
        case waitForDistance(metersRemaining: Int)
        /// Distance parcourue, mais le test précédent est trop récent.
        case waitForSpacing(secondsRemaining: Int)
        /// Aucune position reçue : la prochaine mesure part dans `secondsRemaining` s.
        case waitForTime(secondsRemaining: Int)
        /// À l'arrêt depuis trop longtemps : plus de mesure jusqu'au prochain déplacement.
        case pausedStationary
    }

    /// Écart minimal entre deux mesures, même en roulant vite : à 130 km/h, 500 m
    /// passent en 14 s, soit moins que la durée d'un test.
    static let minimumSecondsBetweenTests = 20
    /// Repli sans aucune position : une mesure au plus toutes les 30 s.
    static let secondsBetweenTestsWithoutFix = 30
    /// Pause automatique après 3 minutes sans s'éloigner de l'ancre.
    static let stationarySecondsBeforePause = 180
    /// Rayon autour de l'ancre en deçà duquel l'appareil est considéré immobile :
    /// un téléphone posé dérive de quelques mètres, et le suivi ne livre plus
    /// rien sous 8 m (filtre de distance).
    static let stationaryRadiusMeters: CLLocationDistance = 50

    /// - Parameters:
    ///   - secondsSinceLastTest: temps écoulé depuis la fin du test précédent.
    ///   - metersMoved: distance entre le point du test précédent et la dernière
    ///     position reçue ; `nil` si l'une des deux manque.
    ///   - stationarySeconds: temps passé sans s'éloigner de l'ancre ; `nil` tant
    ///     qu'aucune position n'a été reçue.
    static func decide(
        testCount: Int,
        secondsSinceLastTest: Int,
        metersMoved: Double?,
        stationarySeconds: Int?,
        intervalMeters: Double
    ) -> Decision {
        if testCount == 0 { return .testNow }
        guard let metersMoved, metersMoved.isFinite, let stationarySeconds else {
            let remaining = secondsBetweenTestsWithoutFix - secondsSinceLastTest
            return remaining <= 0 ? .testNow : .waitForTime(secondsRemaining: remaining)
        }
        if stationarySeconds >= stationarySecondsBeforePause { return .pausedStationary }
        guard metersMoved >= intervalMeters else {
            return .waitForDistance(metersRemaining: max(1, Int((intervalMeters - metersMoved).rounded(.up))))
        }
        let spacing = minimumSecondsBetweenTests - secondsSinceLastTest
        return spacing <= 0 ? .testNow : .waitForSpacing(secondsRemaining: spacing)
    }

    /// Point autour duquel on mesure l'immobilité. Il suit l'appareil dès que
    /// celui-ci s'en éloigne de plus de `stationaryRadiusMeters` ; le temps
    /// passé depuis ce dernier déplacement est la durée d'arrêt.
    ///
    /// L'arrêt se mesure au déplacement, pas à la vitesse : beaucoup de
    /// positions n'ont pas de vitesse valide, et sans mouvement le suivi ne
    /// livre plus de position du tout — on ne peut donc pas attendre un fix
    /// « lent » pour conclure à l'arrêt.
    struct StationaryAnchor {
        private(set) var location: CLLocation?

        mutating func update(with fix: CLLocation) {
            guard let location, location.distance(from: fix) < DriveTestCadence.stationaryRadiusMeters else {
                self.location = fix
                return
            }
        }

        /// `nil` tant qu'aucune position n'a été reçue.
        func stationarySeconds(now: Date) -> Int? {
            location.map { max(0, Int(now.timeIntervalSince($0.timestamp))) }
        }

        mutating func reset() { location = nil }
    }
}
