import Foundation

/// Journalisation de debug : compilée uniquement hors Release, pour qu'aucun
/// `print()` (erreurs moteur speedtest, échecs de sauvegarde…) ne s'exécute en
/// production. Remplace les `print()` bruts des services (cf. audit SEC-09).
@inline(__always)
func sqDebugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

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

    // Drapeaux de mise en scène QA (carte, navigation, temporisations). Mêmes
    // règles que ci-dessus : en Release ce sont des constantes `false`, donc le
    // compilateur élimine les branches qui les consomment — et avec elles les
    // jeux de données de démonstration (identifiants de photos réels, URLs S3,
    // amis fictifs) qui n'ont rien à faire dans un binaire signé.
    #if DEBUG
    private static func hasArgument(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    static var usesDemoPhotos: Bool { hasArgument("--qa-demo-photos") }
    static var usesDemoFriends: Bool { hasArgument("--qa-demo-friends") }
    static var walksDemoFriends: Bool { hasArgument("--qa-friends-walk") }
    static var opensMapLayers: Bool { hasArgument("--qa-map-layers") }
    static var opensAntennaSheet: Bool { hasArgument("--qa-open-antenna") }
    static var opensPhotoSheet: Bool { hasArgument("--qa-open-photo") }
    static var opensFriendSheet: Bool { hasArgument("--qa-open-friend") }
    static var opensMessagesTab: Bool { hasArgument("--qa-tab-messages") }
    static var opensANFRMap: Bool { hasArgument("--qa-anfr-map") }
    static var opensANFRStats: Bool { hasArgument("--qa-anfr-stats") }
    static var usesLegacyDock: Bool { hasArgument("--qa-legacy-dock") }
    static var delaysLoadForQA: Bool { hasArgument("--qa-slow-load") }
    static var resetsMapOnLaunch: Bool { hasArgument("--reset-map") }
    #else
    static var usesDemoPhotos: Bool { false }
    static var usesDemoFriends: Bool { false }
    static var walksDemoFriends: Bool { false }
    static var opensMapLayers: Bool { false }
    static var opensAntennaSheet: Bool { false }
    static var opensPhotoSheet: Bool { false }
    static var opensFriendSheet: Bool { false }
    static var opensMessagesTab: Bool { false }
    static var opensANFRMap: Bool { false }
    static var opensANFRStats: Bool { false }
    static var usesLegacyDock: Bool { false }
    static var delaysLoadForQA: Bool { false }
    static var resetsMapOnLaunch: Bool { false }
    #endif
}
