import SwiftUI

/// Clés UserDefaults des réglages de sécurité (verrouillage app + auto-logout).
/// Partagées entre `AppLockController` (lecture) et `SettingsView` (édition via
/// `@AppStorage`).
enum AppLockSettings {
    static let enabledKey = "sq.security.appLockEnabled"
    /// Inactivité (s) avant verrouillage. 0 = immédiat (verrouille dès la mise en arrière-plan).
    static let lockGraceKey = "sq.security.appLockGraceSeconds"
    /// Inactivité (s) avant déconnexion complète. 0 = jamais.
    static let autoLogoutKey = "sq.security.autoLogoutSeconds"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var lockGrace: TimeInterval { UserDefaults.standard.double(forKey: lockGraceKey) }
    static var autoLogout: TimeInterval { UserDefaults.standard.double(forKey: autoLogoutKey) }
}

/// Pilote le verrouillage de l'app par Face ID / Touch ID : verrouille à
/// l'ouverture et après une période d'inactivité en arrière-plan ; déclenche une
/// déconnexion complète au-delà d'un délai d'inactivité plus long.
@MainActor
final class AppLockController: ObservableObject {
    /// Vrai quand l'écran de verrouillage doit masquer le contenu.
    @Published private(set) var isLocked = false

    private var backgroundedAt: Date?

    /// À appeler quand l'app devient authentifiée (lancement / login) : verrouille
    /// d'emblée si le verrouillage biométrique est activé.
    func lockOnActivationIfNeeded() {
        guard AppLockSettings.enabled, BiometricAuth.isAvailable else { return }
        isLocked = true
    }

    func didEnterBackground() {
        guard AppLockSettings.enabled, BiometricAuth.isAvailable else {
            backgroundedAt = nil
            return
        }
        backgroundedAt = Date()
        // Verrouillage immédiat : on masque le contenu DÈS la mise en arrière-plan
        // (pas de flash au retour, et l'aperçu du sélecteur d'apps est masqué).
        if AppLockSettings.lockGrace == 0 {
            isLocked = true
        }
    }

    /// Retour au premier plan APRÈS un vrai passage en arrière-plan. Renvoie `true`
    /// si la session doit être déconnectée (inactivité ≥ auto-logout).
    ///
    /// ⚠️ Garde anti-boucle : si `backgroundedAt == nil`, on N'EST PAS revenu d'un
    /// arrière-plan réel — c'est un simple `.active` (retour de l'invite Face ID,
    /// du sélecteur d'apps…). Dans ce cas on ne (re)verrouille JAMAIS, sinon
    /// l'invite biométrique qui fait osciller la scène crée une boucle
    /// verrouille → Face ID → déverrouille → verrouille…
    func willEnterForeground() -> Bool {
        guard let backgroundedAt else { return false }
        self.backgroundedAt = nil
        guard AppLockSettings.enabled, BiometricAuth.isAvailable else { return false }
        let elapsed = Date().timeIntervalSince(backgroundedAt)
        let autoLogout = AppLockSettings.autoLogout
        if autoLogout > 0, elapsed >= autoLogout {
            isLocked = true   // on verrouille aussi le temps que la déconnexion s'applique
            return true
        }
        if elapsed >= AppLockSettings.lockGrace {
            isLocked = true
        }
        return false
    }

    /// Demande Face ID / Touch ID ; déverrouille en cas de succès.
    func unlock() async {
        let ok = await BiometricAuth.authenticate(reason: "Déverrouille SignalQuest")
        if ok { isLocked = false }
    }

    /// Réinitialise l'état (au logout) pour ne pas rester verrouillé sur l'écran de login.
    func reset() {
        isLocked = false
        backgroundedAt = nil
    }
}

/// Écran de verrouillage plein écran, présenté tant que l'app est verrouillée.
/// Déclenche Face ID / Touch ID automatiquement à l'apparition.
struct AppLockScreen: View {
    @ObservedObject var lock: AppLockController
    @State private var didAutoPrompt = false

    var body: some View {
        ZStack {
            Color.clear.signalQuestHeroBackground().ignoresSafeArea()
            VStack(spacing: SQSpace.xl) {
                Image("SQLogoMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.xxl, style: .continuous))
                    .shadow(color: SQColor.brandRed.opacity(0.35), radius: 18, y: 8)
                    .accessibilityHidden(true)
                VStack(spacing: SQSpace.xs) {
                    Text("SignalQuest est verrouillé")
                        .font(SQType.title)
                        .foregroundStyle(SQColor.label)
                        .multilineTextAlignment(.center)
                    Text("Déverrouille avec \(BiometricAuth.kind.label) pour continuer.")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(.center)
                }
                GradientButton("Déverrouiller", systemImage: BiometricAuth.kind.systemImage) {
                    Task { await lock.unlock() }
                }
                .padding(.horizontal, SQSpace.xxl)
            }
            .padding(SQSpace.xxl)
        }
        .task {
            guard !didAutoPrompt else { return }
            didAutoPrompt = true
            await lock.unlock()
        }
    }
}
