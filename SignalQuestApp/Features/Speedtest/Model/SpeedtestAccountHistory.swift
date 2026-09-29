import Foundation

/// Tests du compte absents de ce téléphone : réinstallation, autre iPhone, app
/// Android (UI-12). Un test local envoyé revient du serveur à quelques secondes
/// près ; un envoi retardé (hors réseau) se reconnaît à son débit identique.
enum SpeedtestAccountHistory {
    static let sameTestWindow: TimeInterval = 120
    static let delayedUploadWindow: TimeInterval = 24 * 3600

    static func accountOnly(_ account: [SocialShareableSpeedtest],
                            local: [SpeedtestRunResult]) -> [SocialShareableSpeedtest] {
        account.filter { test in
            !local.contains { isSameTest(test, $0) }
        }
    }

    static func isSameTest(_ test: SocialShareableSpeedtest, _ local: SpeedtestRunResult) -> Bool {
        guard let date = test.timestamp else { return false }
        let gap = abs(local.createdAt.timeIntervalSince(date))
        if gap <= sameTestWindow { return true }
        guard gap <= delayedUploadWindow, let download = test.downloadAverageMbps else { return false }
        let tolerance = max(0.05, local.downloadAverageMbps * 0.001)
        return abs(download - local.downloadAverageMbps) <= tolerance
    }
}
