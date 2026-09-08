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

    /// Shared by every Settings window. Even writing the same value revokes a
    /// confirmation that started before the latest explicit preference change.
    @MainActor private(set) static var mutationRevision = UUID()

    @MainActor
    static func setEnabled(_ enabled: Bool) {
        mutationRevision = UUID()
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}

/// Pilote le verrouillage de l'app par Face ID / Touch ID : verrouille à
/// l'ouverture et après une période d'inactivité en arrière-plan ; déclenche une
/// déconnexion complète au-delà d'un délai d'inactivité plus long.
@MainActor
final class AppLockController: ObservableObject {
    /// Vrai quand l'écran de verrouillage doit masquer le contenu.
    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isInBackground = false
    @Published private(set) var canAuthenticateDeviceOwner: Bool
    @Published private(set) var unlockError: String?

    struct Settings {
        var enabled: Bool
        var lockGrace: TimeInterval
        var autoLogout: TimeInterval

        static var current: Settings {
            Settings(enabled: AppLockSettings.enabled, lockGrace: AppLockSettings.lockGrace,
                autoLogout: AppLockSettings.autoLogout)
        }
    }

    private let settings: () -> Settings
    private let now: () -> TimeInterval
    private let authenticate: @MainActor (String, Bool) async -> Bool
    private let authenticationAvailable: @MainActor () -> Bool
    private var backgroundedAt: TimeInterval?
    private var authenticationID: UUID?
    private var authenticationTask: Task<Bool, Never>?

    init(
        settings: @escaping () -> Settings = { .current },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        canAuthenticateDeviceOwner: @escaping @MainActor () -> Bool = { BiometricAuth.canAuthenticateDeviceOwner },
        authenticate: @escaping @MainActor (String, Bool) async -> Bool = {
            await BiometricAuth.authenticate(reason: $0, allowPasscode: $1)
        }
    ) {
        self.settings = settings
        self.now = now
        authenticationAvailable = canAuthenticateDeviceOwner
        self.canAuthenticateDeviceOwner = canAuthenticateDeviceOwner()
        self.authenticate = authenticate
    }

    /// À appeler quand l'app devient authentifiée (lancement / login) : verrouille
    /// d'emblée si le verrouillage biométrique est activé.
    func lockOnActivationIfNeeded() {
        // Le réglage impose la protection. Une biométrie absente, désactivée ou
        // temporairement bloquée ne doit jamais rendre le contenu accessible.
        guard settings().enabled else { return }
        lock()
    }

    func didEnterBackground() {
        isInBackground = true
        cancelAuthentication()
        let settings = settings()
        guard settings.enabled else {
            backgroundedAt = nil
            return
        }
        // Plusieurs notifications/scènes ne doivent pas prolonger le délai.
        if backgroundedAt == nil { backgroundedAt = now() }
        // Verrouillage immédiat : on masque le contenu DÈS la mise en arrière-plan
        // (pas de flash au retour, et l'aperçu du sélecteur d'apps est masqué).
        if Self.safeInterval(settings.lockGrace) == 0 {
            lock()
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
        // Garder le masque neutre jusqu'à ce que l'expiration de la grâce ait
        // posé le verrou ; aucune fenêtre ne redevient interactive entre les deux.
        defer { isInBackground = false }
        guard let backgroundedAt else { return false }
        self.backgroundedAt = nil
        let settings = settings()
        guard settings.enabled else { return false }
        let duration = now() - backgroundedAt
        // Horloge monotone ; un état temporel incohérent doit fermer le verrou.
        let elapsed = duration.isFinite && duration >= 0 ? duration : .infinity
        let autoLogout = Self.safeInterval(settings.autoLogout)
        if autoLogout > 0, elapsed >= autoLogout {
            lock()   // on verrouille aussi le temps que la déconnexion s'applique
            return true
        }
        if elapsed >= Self.safeInterval(settings.lockGrace) {
            lock()
        }
        return false
    }

    /// Demande Face ID / Touch ID ; déverrouille en cas de succès.
    func unlock() async {
        guard isLocked, !isInBackground, !isAuthenticating else { return }
        refreshAuthenticationAvailability()
        guard canAuthenticateDeviceOwner else { return }
        unlockError = nil
        let id = UUID()
        authenticationID = id
        isAuthenticating = true
        let task = Task { await authenticate(String(localized: "Déverrouille SignalQuest"), true) }
        authenticationTask = task
        let ok = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        // Une réponse positive d'une ancienne invite ne vaut pas pour un nouveau
        // verrou (arrière-plan, nouvelle connexion ou reset pendant l'invite).
        guard authenticationID == id else { return }
        authenticationID = nil
        authenticationTask = nil
        isAuthenticating = false
        guard !Task.isCancelled, !task.isCancelled, !isInBackground else { return }
        guard ok else {
            refreshAuthenticationAvailability()
            if canAuthenticateDeviceOwner {
                unlockError = String(localized: "L’authentification n’a pas abouti. Tu peux réessayer pour déverrouiller SignalQuest.")
            }
            return
        }
        isLocked = false
    }

    func refreshAuthenticationAvailability() {
        let available = authenticationAvailable()
        if canAuthenticateDeviceOwner != available { unlockError = nil }
        canAuthenticateDeviceOwner = available
    }

    /// Réinitialise l'état (au logout) pour ne pas rester verrouillé sur l'écran de login.
    func reset() {
        cancelAuthentication()
        isLocked = false
        isInBackground = false
        backgroundedAt = nil
        unlockError = nil
    }

    private func lock() {
        cancelAuthentication()
        unlockError = nil
        refreshAuthenticationAvailability()
        isLocked = true
    }

    private func cancelAuthentication() {
        authenticationID = nil
        authenticationTask?.cancel()
        authenticationTask = nil
        isAuthenticating = false
    }

    private static func safeInterval(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
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
                    Text(lock.canAuthenticateDeviceOwner
                        ? String(localized: "Utilise Face ID, Touch ID ou le code de ton appareil pour continuer.")
                        : String(localized: "Active un code pour ton appareil dans les Réglages iOS, puis reviens dans SignalQuest pour déverrouiller. Le contenu reste masqué."))
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(.center)
                }
                if let error = lock.unlockError {
                    Text(error)
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.dangerInk)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("app-lock.error")
                }
                GradientButton("Déverrouiller", systemImage: BiometricAuth.kind.systemImage) {
                    Task { await lock.unlock() }
                }
                .disabled(!lock.canAuthenticateDeviceOwner || lock.isAuthenticating || lock.isInBackground)
                .padding(.horizontal, SQSpace.xxl)
            }
            .padding(SQSpace.xxl)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            lock.refreshAuthenticationAvailability()
        }
        .task(id: lock.isInBackground) {
            guard !lock.isInBackground else {
                didAutoPrompt = false
                return
            }
            guard !didAutoPrompt else { return }
            didAutoPrompt = true
            await lock.unlock()
        }
    }
}
