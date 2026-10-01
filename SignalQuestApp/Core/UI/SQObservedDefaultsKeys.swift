import Foundation

/// Clés UserDefaults observées par `@AppStorage` (TRX-39).
///
/// SwiftUI n'observe une clé à elle seule que si son nom ne contient pas de
/// point ; sinon la vue se recalcule à CHAQUE écriture dans UserDefaults,
/// quelle que soit la clé écrite (mesuré : 5 écritures d'une autre clé,
/// 5 recalculs). Trois de ces clés vivaient à la racine de l'app : toute
/// écriture recalculait l'arbre entier, et deux vues qui écrivaient pendant
/// leur rendu tournaient en boucle. Les clés observées n'ont donc jamais de
/// point ; les anciennes valeurs sont recopiées une fois, au lancement.
enum SQObservedDefaultsKeys {
    /// Ancienne clé, à point, puis la nouvelle.
    static let renamed: [(old: String, new: String)] = [
        ("sq.hasCompletedOnboarding", OnboardingEntryState.completionKey),
        ("sq.fieldMode.enabled", SQFieldMode.storageKey),
        ("sq.browseAsGuest", RootView.guestPreferenceKey),
        ("sq.security.appLockEnabled", AppLockSettings.enabledKey),
        ("sq.security.appLockGraceSeconds", AppLockSettings.lockGraceKey),
        ("sq.security.autoLogoutSeconds", AppLockSettings.autoLogoutKey),
        ("sq.security.e2eeBiometricEnabled", E2EEBiometric.enabledKey),
        ("sq.carplay.coverageAlerts", CarPlayAlertSettings.coverageAlertsKey),
    ]

    /// Recopie chaque ancienne valeur sous sa nouvelle clé, avant toute vue :
    /// une nouvelle clé déjà écrite l'emporte. L'ancienne reste en place pour
    /// une version antérieure de l'app.
    static func migrate(in defaults: UserDefaults = .standard) {
        for (old, new) in renamed where defaults.object(forKey: new) == nil {
            if let value = defaults.object(forKey: old) { defaults.set(value, forKey: new) }
        }
    }
}
