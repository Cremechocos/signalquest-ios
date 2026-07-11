import Foundation
@testable import SignalQuest

extension AppConfig {
    static let test = AppConfig(
        appBaseURL: URL(string: "https://signalquest.test")!,
        apiBaseURL: URL(string: "https://signalquest.test")!,
        speedtestBaseURL: URL(string: "https://speedtest.signalquest.test")!,
        speedtestDownloadURL: URL(string: "https://speedtest.signalquest.test/download")!,
        speedtestCloudFrontDownloadURL: URL(string: "https://d2d31ihf1e95ah.cloudfront.net/1000MB.bin")!,
        speedtestCloudflareDownloadURL: URL(string: "https://dl.signalquest.test/speedtest/300MB.bin")!,
        debugLogsEnabled: false
    )
}
