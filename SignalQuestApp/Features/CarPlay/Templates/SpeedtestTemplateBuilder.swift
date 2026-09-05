import CarPlay
import CoreLocation

/// Cadence de rafraîchissement de l'écran pendant un test.
///
/// Le moteur émet une progression plusieurs fois par seconde. Rejouer chaque
/// émission sur un `CPInformationTemplate` serait doublement mauvais : CarPlay
/// n'aime pas les mises à jour rapides, et surtout des chiffres qui défilent à
/// 10 Hz sur l'écran d'un véhicule ne se lisent pas — ils attirent le regard
/// sans rien apprendre.
struct SpeedtestRefreshThrottle {
    /// Deux rafraîchissements par seconde : assez pour que le test paraisse
    /// vivant, assez lent pour que les chiffres soient lisibles.
    static let minimumInterval: TimeInterval = 0.5

    private var lastEmittedAt: Date?

    /// Faut-il afficher cette progression ? Une phase qui change passe TOUJOURS,
    /// quel que soit le délai : « Envoi » qui succède à « Réception » est
    /// l'information la plus utile du test, la retenir n'aurait aucun sens.
    mutating func shouldEmit(now: Date, phaseChanged: Bool) -> Bool {
        if phaseChanged {
            lastEmittedAt = now
            return true
        }
        if let lastEmittedAt, now.timeIntervalSince(lastEmittedAt) < Self.minimumInterval {
            return false
        }
        lastEmittedAt = now
        return true
    }
}

/// Écran Speedtest : lancer une mesure et en suivre le déroulement.
///
/// ⚠️ Contrainte de revue autant que d'ergonomie : le déclenchement doit rester
/// UNE SEULE pression, sans réglage ni saisie. Tout ce qui se paramètre sur
/// l'iPhone (durée, flux, serveur) est ici figé sur les valeurs par défaut.
@MainActor
enum SpeedtestTemplateBuilder {
    enum State {
        case idle(last: SpeedtestRunResult?)
        case running(SpeedtestLiveProgress)
        case finished(SpeedtestRunResult)
        case failed(String)
    }

    struct Actions {
        var start: (() -> Void)?
    }

    static func make(state: State, actions: Actions) -> CPInformationTemplate {
        CPInformationTemplate(
            title: String(localized: "Débit"),
            layout: .twoColumn,
            items: Array(items(for: state).prefix(CarPlayDetailTemplateBuilder.maxItems)),
            actions: buttons(for: state, actions: actions)
        )
    }

    static func items(for state: State) -> [CPInformationItem] {
        switch state {
        case .idle(let last):
            guard let last else {
                return [CPInformationItem(
                    title: String(localized: "Aucune mesure"),
                    detail: String(localized: "Lance un test pour mesurer le réseau ici.")
                )]
            }
            return resultItems(last, titlePrefix: String(localized: "Dernier test"))

        case .running(let progress):
            var items = [CPInformationItem(title: String(localized: "En cours"),
                                           detail: phaseLabel(progress.phase))]
            // Pendant la mesure, une seule valeur qui bouge : celle de la phase
            // en cours. Afficher les trois métriques ferait défiler trois nombres
            // à la fois pour quelqu'un qui conduit.
            switch progress.phase {
            case .download, .upload:
                items.append(CPInformationItem(title: String(localized: "Débit"),
                                               detail: mbps(progress.currentMbps)))
            case .ping:
                if let ping = progress.pingLiveMs {
                    items.append(CPInformationItem(title: String(localized: "Latence"),
                                                   detail: "\(Int(ping.rounded())) ms"))
                }
            default:
                break
            }
            if let server = progress.serverName {
                items.append(CPInformationItem(title: String(localized: "Serveur"), detail: server))
            }
            return items

        case .finished(let result):
            return resultItems(result, titlePrefix: nil)

        case .failed(let message):
            return [CPInformationItem(title: String(localized: "Échec"), detail: message)]
        }
    }

    static func resultItems(_ result: SpeedtestRunResult, titlePrefix: String?) -> [CPInformationItem] {
        var items: [CPInformationItem] = []
        if let titlePrefix {
            items.append(CPInformationItem(title: titlePrefix, detail: result.label))
        }
        items.append(CPInformationItem(title: String(localized: "Descendant"),
                                       detail: mbps(result.downloadMbps)))
        if let upload = result.uploadMbps {
            items.append(CPInformationItem(title: String(localized: "Montant"), detail: mbps(upload)))
        }
        if let ping = result.primaryPingMs {
            items.append(CPInformationItem(title: String(localized: "Latence"),
                                           detail: "\(Int(ping.rounded())) ms"))
        }
        if let technology = result.cellularTechnology?.displayName ?? result.networkOperatorName {
            items.append(CPInformationItem(title: String(localized: "Réseau"), detail: technology))
        }
        return items
    }

    /// Un seul test à la fois : pendant la mesure, aucun bouton. Deux tests
    /// concurrents se fausseraient mutuellement, et le conducteur n'a pas à
    /// deviner lequel des deux il regarde.
    private static func buttons(for state: State, actions: Actions) -> [CPTextButton] {
        guard let start = actions.start else { return [] }
        if case .running = state { return [] }
        let title: String
        switch state {
        case .idle(let last): title = last == nil
            ? String(localized: "Lancer le test")
            : String(localized: "Relancer")
        case .finished, .failed: title = String(localized: "Relancer")
        case .running: title = ""
        }
        return [CPTextButton(title: title, textStyle: .confirm) { _ in start() }]
    }

    static func phaseLabel(_ phase: SpeedtestPhase) -> String {
        switch phase {
        case .idle: return String(localized: "Préparation")
        case .ping: return String(localized: "Latence")
        case .download: return String(localized: "Réception")
        case .upload: return String(localized: "Envoi")
        case .saving: return String(localized: "Enregistrement")
        case .finished: return String(localized: "Terminé")
        case .failed(let message): return message
        }
    }

    /// Arrondi à l'entier au-dessus de 10 Mb/s : au volant, la décimale d'un
    /// débit à 187 Mb/s n'apporte rien et allonge le nombre à lire.
    static func mbps(_ value: Double) -> String {
        value >= 10
            ? String(localized: "\(Int(value.rounded())) Mb/s")
            : String(localized: "\(String(format: "%.1f", value)) Mb/s")
    }
}
