import Foundation

enum AppEnvironment {
    private static func boolEnvironmentValue(_ key: String) -> Bool {
        let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["1", "true", "yes", "on"].contains(value ?? "")
    }

    // Drapeaux de lancement réservés à la QA. Gardés derrière #if DEBUG pour qu'un
    // binaire de distribution ne puisse PAS contourner l'authentification (mode
    // démo) ni l'état de session via des arguments de lancement (cf. audit
    // SECURITY-04). En Release, ils valent toujours `false`.
    #if DEBUG
    static var usesDemoData: Bool {
        ProcessInfo.processInfo.arguments.contains("--mock-auth") ||
        ProcessInfo.processInfo.arguments.contains("--demo-data")
    }

    static var resetsAuthOnLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--reset-auth")
    }

    static var startsOnMap: Bool {
        ProcessInfo.processInfo.arguments.contains("--start-map")
    }
    #else
    static var usesDemoData: Bool { false }
    static var resetsAuthOnLaunch: Bool { false }
    static var startsOnMap: Bool { false }
    #endif

    #if DEBUG
    static var runsSpeedtestQA: Bool {
        ProcessInfo.processInfo.arguments.contains("--qa-speedtest-run") ||
        boolEnvironmentValue("SQ_QA_SPEEDTEST_AUTORUN")
    }

    static var exitsAfterSpeedtestQA: Bool {
        ProcessInfo.processInfo.arguments.contains("--qa-speedtest-exit") ||
        boolEnvironmentValue("SQ_QA_SPEEDTEST_EXIT")
    }
    #else
    static var runsSpeedtestQA: Bool { false }
    static var exitsAfterSpeedtestQA: Bool { false }
    #endif

    #if DEBUG
    static var injectedAuthToken: String? {
        let value = ProcessInfo.processInfo.environment["SQ_AUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
    #else
    static var injectedAuthToken: String? { nil }
    #endif
}
