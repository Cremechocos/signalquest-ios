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

    /// Autorise le binaire Release de mesure uniquement dans CoreSimulator.
    /// Sur appareil physique, `targetEnvironment(simulator)` est éliminé à la
    /// compilation : aucune variable d'environnement ne peut ouvrir le mode démo.
    private static var allowsSimulatorPerformanceQA: Bool {
        #if targetEnvironment(simulator)
        boolEnvironmentValue("SQ_PERFORMANCE_QA")
        #else
        false
        #endif
    }

    // Drapeaux de lancement réservés à la QA. Debug les conserve pour les tests
    // courants ; Release ne les accepte que dans le simulateur de performance
    // explicitement marqué. Une archive App Store physique reste fail-closed.
    static var usesDemoData: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--mock-auth") ||
            ProcessInfo.processInfo.arguments.contains("--demo-data")
        #else
        return allowsSimulatorPerformanceQA && (
            ProcessInfo.processInfo.arguments.contains("--mock-auth") ||
            ProcessInfo.processInfo.arguments.contains("--demo-data")
        )
        #endif
    }

    static var resetsAuthOnLaunch: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--reset-auth")
        #else
        return allowsSimulatorPerformanceQA &&
            ProcessInfo.processInfo.arguments.contains("--reset-auth")
        #endif
    }

    /// Réinitialise uniquement le drapeau d'onboarding pour les tests UI qui
    /// doivent démarrer sur une première ouverture. Ne jamais utiliser ce
    /// mécanisme hors Debug : il ne doit pas pouvoir modifier le parcours d'un
    /// utilisateur distribué.
    static var resetsOnboardingOnLaunch: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--reset-onboarding")
        #else
        return allowsSimulatorPerformanceQA &&
            ProcessInfo.processInfo.arguments.contains("--reset-onboarding")
        #endif
    }

    static var startsOnMap: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--start-map")
        #else
        return allowsSimulatorPerformanceQA &&
            ProcessInfo.processInfo.arguments.contains("--start-map")
        #endif
    }

    #if DEBUG
    static var runsSpeedtestQA: Bool {
        ProcessInfo.processInfo.arguments.contains("--qa-speedtest-run") ||
        boolEnvironmentValue("SQ_QA_SPEEDTEST_AUTORUN")
    }

    static var exitsAfterSpeedtestQA: Bool {
        ProcessInfo.processInfo.arguments.contains("--qa-speedtest-exit") ||
        boolEnvironmentValue("SQ_QA_SPEEDTEST_EXIT")
    }

    /// Ouvre directement la prévisualisation de partage avec une mesure
    /// déterministe. Cette porte est réservée aux tests UI et disparaît des
    /// builds de distribution avec le reste du bloc `DEBUG`.
    static var showsSpeedtestSharePreviewQA: Bool {
        ProcessInfo.processInfo.arguments.contains("--qa-speedtest-share-preview")
    }
    /// Formulaire local de recette : aucun lien ni jeton réseau n'est émis.
    static var showsPasswordResetQA: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--qa-password-reset-form")
        #else
        false
        #endif
    }
    /// Affiche le vrai formulaire de vérification 2FA sans passer par la feuille
    /// système de sauvegarde du mot de passe. Strictement Debug + simulateur,
    /// et uniquement vers le serveur HTTPS synthétique local.
    static var showsTwoFactorLoginQA: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--qa-two-factor-login") &&
            AppConfig.current.apiBaseURL.absoluteString == "https://127.0.0.1:4325"
        #else
        false
        #endif
    }
    #else
    static var runsSpeedtestQA: Bool { false }
    static var exitsAfterSpeedtestQA: Bool { false }
    static var showsSpeedtestSharePreviewQA: Bool { false }
    static var showsPasswordResetQA: Bool { false }
    static var showsTwoFactorLoginQA: Bool { false }
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

    // Drapeaux de mise en scène QA (carte, navigation, temporisations). En
    // Release ils exigent la même garde CoreSimulator explicite.
    private static func hasArgument(_ flag: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(flag)
        #else
        return allowsSimulatorPerformanceQA &&
            ProcessInfo.processInfo.arguments.contains(flag)
        #endif
    }

    static var usesDemoPhotos: Bool { hasArgument("--qa-demo-photos") }
    static var showsRemoteImageQA: Bool {
        #if DEBUG && targetEnvironment(simulator)
        hasArgument("--qa-remote-image")
        #else
        false
        #endif
    }
    static var showsSentinelleAlertSettingsQA: Bool {
        #if DEBUG && targetEnvironment(simulator)
        hasArgument("--qa-sentinelle-alerts")
        #else
        false
        #endif
    }
    static var showsE2EEReportQA: Bool {
        #if DEBUG && targetEnvironment(simulator)
        hasArgument("--qa-e2ee-report") || hasArgument("--qa-e2ee-report-unavailable")
            || hasArgument("--qa-e2ee-report-comment")
        #else
        false
        #endif
    }
    static var showsApprovalScannerQA: Bool {
        #if DEBUG && targetEnvironment(simulator)
        hasArgument("--qa-approval-scanner")
        #else
        false
        #endif
    }
    static var showsAccountKeyQA: Bool {
        #if DEBUG && targetEnvironment(simulator)
        hasArgument("--qa-account-key") || hasArgument("--qa-account-key-verified")
            || hasArgument("--qa-account-key-missing")
        #else
        false
        #endif
    }
    static var showsBrowserExclusionQA: Bool {
        #if DEBUG && targetEnvironment(simulator)
        hasArgument("--qa-e2ee-browsers") || hasArgument("--qa-e2ee-browsers-member")
            || hasArgument("--qa-e2ee-browsers-refused")
        #else
        false
        #endif
    }
    static var showsSafetyNumberQA: Bool {
        #if DEBUG && targetEnvironment(simulator)
        hasArgument("--qa-safety-number") || hasArgument("--qa-safety-number-changed")
            || hasArgument("--qa-safety-number-changed-verified")
        #else
        false
        #endif
    }
    static var showsCommentsQA: Bool {
        #if DEBUG && targetEnvironment(simulator)
        hasArgument("--qa-comments") || hasArgument("--qa-comments-replies")
        #else
        false
        #endif
    }
    static var usesDemoFriends: Bool { hasArgument("--qa-demo-friends") }
    static var walksDemoFriends: Bool { hasArgument("--qa-friends-walk") }
    static var opensMapLayers: Bool { hasArgument("--qa-map-layers") }
    static var opensAntennaSheet: Bool { hasArgument("--qa-open-antenna") }
    static var opensPhotoSheet: Bool { hasArgument("--qa-open-photo") }
    static var opensFriendSheet: Bool { hasArgument("--qa-open-friend") }
    static var opensMessagesTab: Bool { hasArgument("--qa-tab-messages") }
    static var startsOnProfileQA: Bool { hasArgument("--qa-tab-profile") }
    static var startsOnCommunityQA: Bool { hasArgument("--qa-tab-community") }
    /// La démo ne restaure pas le dernier onglet (chaque test d'interface part de
    /// l'Accueil), sauf pour le test de « Reprendre où j'en étais ».
    static var restoresLastTabQA: Bool { hasArgument("--qa-restore-tab") }
    static var opensANFRMap: Bool { hasArgument("--qa-anfr-map") }
    static var opensANFRStats: Bool { hasArgument("--qa-anfr-stats") }
    static var usesLegacyDock: Bool { hasArgument("--qa-legacy-dock") }
    static var delaysLoadForQA: Bool { hasArgument("--qa-slow-load") }
    static var resetsMapOnLaunch: Bool { hasArgument("--reset-map") }
    /// Ouvre uniquement le chemin d'appel E2EE v2 local. Le gate réseau vérifie
    /// encore séparément que l'API et LiveKit utilisent des origines loopback.
    static var runsE2EEV2CallQA: Bool { hasArgument("--qa-e2ee-v2-calls") }
    /// Écran de fin d'appel (« Pas de réponse ») pour la relecture au
    /// simulateur, où aucun vrai appel n'aboutit.
    static var showsCallEndQA: Bool { hasArgument("--qa-call-ended") }
    /// Éditeur « Flouter » sur une image générée : le sélecteur de photos du
    /// système ne se pilote pas de façon fiable en test d'interface.
    static var showsBlurEditorQA: Bool { hasArgument("--qa-blur-editor") }
}
