import Foundation

/// Départ d'un drive test sans l'écran de l'iPhone : onglet Trajet de CarPlay
/// et Siri (« Lance un drive test »).
///
/// Mêmes règles que l'écran Drive Test (le préflight), plus une : le premier
/// trajet est présenté sur l'iPhone (« Ce qu'un Drive Test partage ») avant
/// de pouvoir partir d'ailleurs. Sans elle, un trajet lancé de la voiture
/// publierait sur la carte communautaire sans que l'utilisateur en ait
/// jamais été informé (choix d'Alexandre du 13/11 : bloquer, phrase neutre).
enum DriveTestHandsFreeStart {
    enum Refusal: Equatable {
        /// « Ce qu'un Drive Test partage » n'a jamais été présenté.
        case disclosureNotSeen
        /// Localisation, stockage ou connexion.
        case preflight(DriveTestPreflightIssue)
    }

    static func refusal(disclosureSeen: Bool, report: DriveTestPreflightReport) -> Refusal? {
        guard disclosureSeen else { return .disclosureNotSeen }
        return report.issues.first { $0.severity == .blocking }.map(Refusal.preflight)
    }

    @MainActor
    static var disclosureSeen: Bool {
        UserDefaults.standard.bool(forKey: DriveTestDisclosureView.seenKey)
    }

    /// Pourquoi on ne peut pas partir, sans consigne : ni l'écran du véhicule
    /// ni Siri en voiture ne doivent envoyer le conducteur sur son téléphone.
    static func reason(_ refusal: Refusal) -> (title: String, detail: String) {
        switch refusal {
        case .disclosureNotSeen:
            return (String(localized: "Premier trajet pas encore présenté"),
                    String(localized: "Ce qu'un trajet partage est présenté avant le premier départ."))
        case .preflight(let issue):
            switch issue.id {
            case .locationPermission:
                return (String(localized: "Localisation non autorisée"),
                        String(localized: "Le trajet a besoin de la position pour placer chaque mesure."))
            case .storage:
                return (String(localized: "Espace de stockage faible"),
                        String(localized: "Il reste \(issue.value ?? 0) Mo, trop peu pour enregistrer un trajet."))
            case .connectivity, .gpsFix, .battery, .wifi, .constrainedNetwork:
                return (String(localized: "Connexion indisponible"),
                        String(localized: "Le speedtest continu nécessite une connexion réseau."))
            }
        }
    }
}
