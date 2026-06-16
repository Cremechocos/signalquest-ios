import Foundation
import ActivityKit

/// Pilote la Live Activity « speedtest en cours » (iOS 16.2+ pour l'API
/// `ActivityContent` non dépréciée). On ne STOCKE pas l'`Activity` (non Sendable) :
/// on la (re)trouve via `Activity.activities` à l'intérieur du `Task`, ce qui
/// évite tout envoi de valeur non-Sendable hors de l'isolation MainActor.
///
/// Prend en charge les rafales : `runIndex`/`runTotal` portent « test i / N ».
@MainActor
final class SpeedtestLiveActivityController {

    /// Vrai si les Live Activities sont autorisées (réglages système) et l'API dispo.
    var isAvailable: Bool {
        guard #available(iOS 16.2, *) else { return false }
        return ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Démarre (ou réutilise) la Live Activity. Réutilise une activité existante
    /// plutôt que d'en empiler une seconde.
    func start(serverName: String, network: String, runIndex: Int = 1, runTotal: Int = 1) {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = SpeedtestActivityAttributes.ContentState(
            phaseLabel: runTotal > 1 ? "Test \(runIndex)/\(runTotal)" : "Démarrage",
            downloadMbps: 0, uploadMbps: 0, pingMs: 0, progress: 0.04,
            runIndex: runIndex, runTotal: runTotal, finished: false
        )
        if !Activity<SpeedtestActivityAttributes>.activities.isEmpty {
            push(state)
            return
        }
        let attributes = SpeedtestActivityAttributes(serverName: serverName, network: network)
        _ = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil)
        )
    }

    func update(
        phaseLabel: String,
        downloadMbps: Double,
        uploadMbps: Double,
        pingMs: Double,
        progress: Double,
        runIndex: Int = 1,
        runTotal: Int = 1
    ) {
        guard #available(iOS 16.2, *) else { return }
        push(SpeedtestActivityAttributes.ContentState(
            phaseLabel: phaseLabel,
            downloadMbps: downloadMbps, uploadMbps: uploadMbps, pingMs: pingMs,
            progress: progress, runIndex: runIndex, runTotal: runTotal, finished: false
        ))
    }

    /// Termine la Live Activity en affichant le résultat final un court instant.
    func end(downloadMbps: Double = 0, uploadMbps: Double = 0, pingMs: Double = 0, runIndex: Int = 1, runTotal: Int = 1) {
        guard #available(iOS 16.2, *) else { return }
        let content = ActivityContent(
            state: SpeedtestActivityAttributes.ContentState(
                phaseLabel: runTotal > 1 ? "Rafale terminée" : "Terminé",
                downloadMbps: downloadMbps, uploadMbps: uploadMbps, pingMs: pingMs,
                progress: 1, runIndex: runIndex, runTotal: runTotal, finished: true
            ),
            staleDate: nil
        )
        Task {
            for activity in Activity<SpeedtestActivityAttributes>.activities {
                await activity.end(content, dismissalPolicy: .after(.now + 4))
            }
        }
    }

    /// Termine immédiatement toute activité résiduelle (annulation, erreur).
    func cancel() {
        guard #available(iOS 16.2, *) else { return }
        Task {
            for activity in Activity<SpeedtestActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    @available(iOS 16.2, *)
    private func push(_ state: SpeedtestActivityAttributes.ContentState) {
        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            for activity in Activity<SpeedtestActivityAttributes>.activities {
                await activity.update(content)
            }
        }
    }
}
