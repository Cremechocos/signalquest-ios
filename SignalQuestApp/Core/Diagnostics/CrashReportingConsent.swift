import Foundation
import FirebaseCore
import FirebaseCrashlytics

/// Consentement aux rapports de plantage, comme sur Android (choix d'Alexandre du
/// 21/11, avant la 1.0) : rien ne part vers Crashlytics sans un « oui » enregistré
/// sur cet appareil. L'Info.plist coupe la collecte automatique
/// (`FirebaseCrashlyticsCollectionEnabled` = NO) ; tant que la personne n'a rien
/// choisi, le SDK garde les rapports sur l'appareil sans les envoyer.
///
/// Le réglage du SDK est persistant mais ne prend effet qu'au lancement suivant :
/// un « oui » envoie donc aussi tout de suite les rapports en attente, et un
/// « non » les supprime. Les non-fatals de l'app (`SQDiagnostics`, MetricKit, sonde
/// de gel) lisent le choix à chaque envoi, sans attendre le relancement.
enum CrashReportingConsent {
    enum Choice: String, Sendable {
        case granted
        case denied
    }

    static let defaultsKey = "sq.crashReporting.consent.v1"

    /// Ce que le choix commande au SDK : remplaçable dans les tests.
    struct Collector: Sendable {
        var setCollectionEnabled: @Sendable (Bool) -> Void
        var sendUnsentReports: @Sendable () -> Void
        var deleteUnsentReports: @Sendable () -> Void

        static let crashlytics = Collector(
            setCollectionEnabled: { Crashlytics.crashlytics().setCrashlyticsCollectionEnabled($0) },
            sendUnsentReports: { Crashlytics.crashlytics().sendUnsentReports() },
            deleteUnsentReports: { Crashlytics.crashlytics().deleteUnsentReports() }
        )

        /// Le SDK n'existe qu'après `FirebaseApp.configure()` : sans
        /// `GoogleService-Info.plist` (clone frais), il n'y a rien à commander.
        static var live: Collector? { FirebaseApp.app() != nil ? .crashlytics : nil }
    }

    static func choice(in defaults: UserDefaults = .standard) -> Choice? {
        defaults.string(forKey: defaultsKey).flatMap(Choice.init(rawValue:))
    }

    /// Lu à chaque non-fatal, depuis n'importe quel fil (UserDefaults l'accepte).
    static func allowsReports(in defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        // La preuve de chaîne, demandée explicitement sur un poste de développement.
        if AppEnvironment.hasQAFlag("crashlytics-proof") { return true }
        #endif
        return choice(in: defaults) == .granted
    }

    /// Au lancement, juste après `FirebaseApp.configure()`.
    static func applyAtLaunch(defaults: UserDefaults = .standard, collector: Collector) {
        switch choice(in: defaults) {
        case .granted:
            collector.setCollectionEnabled(true)
        case .denied:
            // Un plantage survenu après un retrait, dans le même lancement, attendait ici.
            collector.setCollectionEnabled(false)
            collector.deleteUnsentReports()
        case nil:
            #if DEBUG
            // La collecte reste coupée : la preuve part avec les rapports en attente,
            // donc au lancement qui suit celui qui l'a notée (le drapeau aux deux).
            if AppEnvironment.hasQAFlag("crashlytics-proof") { collector.sendUnsentReports() }
            #endif
        }
    }

    static func record(_ choice: Choice, defaults: UserDefaults = .standard, collector: Collector?) {
        defaults.set(choice.rawValue, forKey: defaultsKey)
        guard let collector else { return }
        switch choice {
        case .granted:
            collector.setCollectionEnabled(true)
            collector.sendUnsentReports()
        case .denied:
            collector.setCollectionEnabled(false)
            collector.deleteUnsentReports()
        }
    }

    /// L'écran plein écran du premier lancement, montré à chacun une fois, y compris
    /// à ceux qui avaient déjà l'app. Jamais en démo. En Debug, il bloquerait les
    /// tests UI et le poste de développement : `--qa-crash-consent` le montre.
    static var asksAtLaunch: Bool {
        guard !AppEnvironment.usesDemoData, FirebaseApp.app() != nil else { return false }
        #if DEBUG
        return AppEnvironment.hasQAFlag("crash-consent")
        #else
        return true
        #endif
    }
}

/// Le choix pour les écrans : l'invite du premier lancement, le réglage de
/// Confidentialité et le lien de l'écran de connexion (seul accès d'un invité).
@MainActor
final class CrashReportingConsentStore: ObservableObject {
    static let shared = CrashReportingConsentStore()

    @Published private(set) var choice: CrashReportingConsent.Choice?
    private let defaults: UserDefaults
    private let asks: Bool
    private let collector: () -> CrashReportingConsent.Collector?

    init(defaults: UserDefaults = .standard,
         asks: Bool = CrashReportingConsent.asksAtLaunch,
         collector: @escaping () -> CrashReportingConsent.Collector? = { CrashReportingConsent.Collector.live }) {
        self.defaults = defaults
        self.asks = asks
        self.collector = collector
        choice = CrashReportingConsent.choice(in: defaults)
    }

    var needsDecision: Bool { asks && choice == nil }

    /// Le réglage n'a de sens que si le SDK tourne.
    var isAvailable: Bool { collector() != nil }

    func choose(_ choice: CrashReportingConsent.Choice) {
        CrashReportingConsent.record(choice, defaults: defaults, collector: collector())
        self.choice = choice
    }
}
