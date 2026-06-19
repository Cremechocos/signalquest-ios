import Foundation

/// Indicateurs de fonctionnalité compilés — kill-switch de repli (App Store /
/// prod). Volontairement des constantes : pas de toggle utilisateur ni de
/// remote-config. Pour désactiver une fonctionnalité, passer le flag à `false`
/// puis rebuild ; rien d'autre n'est requis (CALL-SCOPE-17).
enum SQFeatures {
    /// Appels VoIP/CallKit/LiveKit. À passer à `false` si la campagne de
    /// validation device échoue : masque toute initiation d'appel sans bloquer
    /// le reste de l'app (l'enregistrement push reste inchangé).
    static let callsEnabled = true
}

struct AppConfig: Equatable {
    let appBaseURL: URL
    let apiBaseURL: URL
    let speedtestBaseURL: URL
    let speedtestDownloadURL: URL
    let speedtestCloudFrontDownloadURL: URL
    let debugLogsEnabled: Bool

    static let current = AppConfig(bundle: .main)

    init(
        appBaseURL: URL,
        apiBaseURL: URL,
        speedtestBaseURL: URL,
        speedtestDownloadURL: URL,
        speedtestCloudFrontDownloadURL: URL,
        debugLogsEnabled: Bool
    ) {
        self.appBaseURL = appBaseURL
        self.apiBaseURL = apiBaseURL
        self.speedtestBaseURL = speedtestBaseURL
        self.speedtestDownloadURL = speedtestDownloadURL
        self.speedtestCloudFrontDownloadURL = speedtestCloudFrontDownloadURL
        self.debugLogsEnabled = debugLogsEnabled
    }

    init(bundle: Bundle) {
        self.init(
            appBaseURL: Self.url(bundle, "SQ_APP_BASE_URL", fallback: "https://signalquest.fr"),
            apiBaseURL: Self.url(bundle, "SQ_API_BASE_URL", fallback: "https://signalquest.fr"),
            speedtestBaseURL: Self.url(bundle, "SQ_SPEEDTEST_BASE_URL", fallback: "https://speedtest.signalquest.fr"),
            speedtestDownloadURL: Self.url(bundle, "SQ_SPEEDTEST_DOWNLOAD_URL", fallback: "https://speedtest.signalquest.fr/download"),
            speedtestCloudFrontDownloadURL: Self.url(bundle, "SQ_SPEEDTEST_CLOUDFRONT_DOWNLOAD_URL", fallback: "https://d2d31ihf1e95ah.cloudfront.net/1000MB.bin"),
            debugLogsEnabled: Self.bool(bundle, "SQ_DEBUG_LOGS", fallback: false)
        )
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
