import Foundation
@testable import SignalQuest

extension AppConfig {
    static let test = AppConfig(
        appBaseURL: URL(string: "https://signalquest.test")!,
        apiBaseURL: URL(string: "https://signalquest.test")!,
        debugLogsEnabled: false
    )
}
