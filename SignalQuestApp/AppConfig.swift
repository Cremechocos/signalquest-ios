import Foundation

enum SQDeploymentEnvironment: String, Codable, Sendable {
    case development
    case staging
    case production
    case test
}

/// Indicateurs de fonctionnalité compilés — kill-switch de repli (App Store /
/// prod). Volontairement des constantes : pas de toggle utilisateur ni de
/// remote-config. Pour désactiver une fonctionnalité, passer le flag à `false`
/// puis rebuild ; rien d'autre n'est requis (CALL-SCOPE-17).
enum SQFeatures {
    /// Appels VoIP/CallKit/LiveKit. À passer à `false` si la campagne de
    /// validation device échoue : masque toute initiation d'appel sans bloquer
    /// le reste de l'app (l'enregistrement push reste inchangé).
    static let callsEnabled = true

    /// Le partage d'écran n'est pas encore validé en interopérabilité
    /// Android↔iOS. Le code média reste inaccessible tant que ce verrou compilé
    /// n'est pas explicitement ouvert après la campagne de tests.
    static let callScreenSharingEnabled = false

    /// Achat App Store. Ouvert en build **staging uniquement** le temps de
    /// valider la chaîne complète (produits App Store Connect + endpoint de
    /// validation serveur + App Store Server Notifications) contre un backend de
    /// pré-production. Debug (services prod) et Release restent fermés : passer
    /// ces deux flags à `true` inconditionnellement une fois la recette prod faite.
    #if STAGING
    static let storeKitPurchasesEnabled = true
    #else
    static let storeKitPurchasesEnabled = false
    #endif

    /// Livraison d'une transaction StoreKit vérifiée au backend. Ce second
    /// verrou empêche qu'un simple changement du flag d'UI autorise un achat
    /// local sans octroyer les droits multiplateformes côté serveur. Aligné sur
    /// `storeKitPurchasesEnabled` : les deux doivent être vrais (et le
    /// synchroniseur présent) pour qu'un achat soit éligible.
    #if STAGING
    static let storeKitServerVerificationEnabled = true
    #else
    static let storeKitServerVerificationEnabled = false
    #endif
}

struct AppConfig: Equatable {
    let environment: SQDeploymentEnvironment
    let appBaseURL: URL
    let apiBaseURL: URL
    let debugLogsEnabled: Bool

    static let current = AppConfig(bundle: .main)

    init(
        environment: SQDeploymentEnvironment = .test,
        appBaseURL: URL,
        apiBaseURL: URL,
        debugLogsEnabled: Bool
    ) {
        self.environment = environment
        self.appBaseURL = appBaseURL
        self.apiBaseURL = apiBaseURL
        self.debugLogsEnabled = debugLogsEnabled
    }

    init(bundle: Bundle) {
        let environment = Self.environment(bundle)
        let fallback = Self.fallbackURLs(for: environment)
        self.init(
            environment: environment,
            appBaseURL: Self.url(bundle, "SQ_APP_BASE_URL", fallback: fallback.app),
            apiBaseURL: Self.url(bundle, "SQ_API_BASE_URL", fallback: fallback.api),
            debugLogsEnabled: Self.bool(bundle, "SQ_DEBUG_LOGS", fallback: false)
        )
    }

    /// True when a non-production binary still targets one of the canonical
    /// production services. The Xcode build gate enforces this for Beta; this
    /// property keeps the invariant testable in Swift as well.
    var usesProductionServicesOutsideProduction: Bool {
        guard environment != .production else { return false }
        return serviceURLs.contains { Self.productionHosts.contains($0.host?.lowercased() ?? "") }
    }

    var hasPlaceholderServices: Bool {
        serviceURLs.contains { ($0.host?.lowercased() ?? "").hasSuffix(".invalid") }
    }

    private var serviceURLs: [URL] {
        [appBaseURL, apiBaseURL]
    }

    private static let productionHosts: Set<String> = [
        "signalquest.fr",
        "api.signalquest.fr",
    ]

    /// Une Beta dont les build settings seraient absents doit rester
    /// non-routable. Elle ne doit jamais retomber silencieusement sur production.
    private static func fallbackURLs(for environment: SQDeploymentEnvironment) -> (
        app: String,
        api: String
    ) {
        if environment == .staging {
            return (
                "https://app.staging.invalid",
                "https://api.staging.invalid"
            )
        }
        return (
            "https://signalquest.fr",
            "https://signalquest.fr"
        )
    }

    private static func environment(_ bundle: Bundle) -> SQDeploymentEnvironment {
        let raw = (bundle.object(forInfoDictionaryKey: "SQ_ENVIRONMENT") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let raw, !raw.contains("$("), let value = SQDeploymentEnvironment(rawValue: raw) {
            return value
        }
        #if STAGING
        return .staging
        #elseif DEBUG
        return .development
        #else
        return .production
        #endif
    }

    private static func url(_ bundle: Bundle, _ key: String, fallback: String) -> URL {
        let raw = bundle.object(forInfoDictionaryKey: key) as? String
        let value = raw.flatMap { $0.contains("$(") ? nil : $0 }.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        if let url = URL(string: value) { return url }
        if let url = URL(string: fallback) { return url }
        // Both the (sanitised) bundle value and the hardcoded fallback failed to
        // parse — a programming error, not a runtime state. Fail loudly in debug
        // and degrade to a non-routable URL in release instead of crashing on launch.
        assertionFailure("Invalid SignalQuest URL for \(key): value=\(value) fallback=\(fallback)")
        return URL(fileURLWithPath: "/")
    }

    private static func bool(_ bundle: Bundle, _ key: String, fallback: Bool) -> Bool {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String, !raw.contains("$(") else {
            return fallback
        }
        return ["YES", "TRUE", "1"].contains(raw.uppercased())
    }

    // MARK: - Legal documents
    //
    // Pages servies par le site signalquest.fr. Chemins vérifiés en production
    // (`/terms`, `/privacy`, `/legal` renvoient 200 ; les anciens `/cgu` et
    // `/confidentialite` renvoyaient 404). Centralisés ici pour éviter toute
    // dérive et pour être testables.

    /// Conditions générales d'utilisation (EULA).
    var termsURL: URL { appBaseURL.appendingPathComponent("terms") }
    /// Politique de confidentialité (RGPD, App Store).
    var privacyURL: URL { appBaseURL.appendingPathComponent("privacy") }
    /// Mentions légales (éditeur, hébergeur, médiateur conso).
    var legalURL: URL { appBaseURL.appendingPathComponent("legal") }
    /// Adresse de contact pour la modération / l'exercice des droits RGPD.
    var contactEmail: String { "legal@signalquest.fr" }
    /// Lien `mailto:` prêt à l'emploi pour le contact modération/RGPD.
    var contactMailtoURL: URL? { URL(string: "mailto:\(contactEmail)") }

    /// Lien `mailto:` pré-rempli pour exercer le droit d'accès / portabilité
    /// (RGPD art. 15 & 20). Solution intérimaire tant qu'un endpoint d'export
    /// automatisé n'est pas en place côté backend.
    var dataRequestMailtoURL: URL? {
        var components = URLComponents(string: "mailto:\(contactEmail)")
        components?.queryItems = [
            URLQueryItem(name: "subject", value: "Demande d’accès et d’export de mes données (RGPD)"),
            URLQueryItem(
                name: "body",
                value: """
                Bonjour,

                Je souhaite exercer mon droit d’accès et de portabilité (RGPD art. 15 et 20) et recevoir une copie de mes données personnelles SignalQuest.

                E-mail du compte concerné :

                Merci.
                """
            ),
        ]
        return components?.url
    }
}
