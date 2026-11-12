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
        /// Mesure terminée mais non sauvegardée : le résultat reste lisible, avec
        /// la mention qu'il ne figurera pas dans l'historique.
        case finishedUnsaved(SpeedtestRunResult)
        case failed(String)
    }

    struct Actions {
        var start: (() -> Void)?
    }

    static func make(state: State, actions: Actions, now: Date = Date()) -> CPInformationTemplate {
        CPInformationTemplate(
            title: title(for: state, now: now),
            layout: .twoColumn,
            items: Array(items(for: state).prefix(CarPlayDetailTemplateBuilder.maxItems)),
            actions: buttons(for: state, actions: actions)
        )
    }

    /// Un verdict et sa date en titre (« Très bon · il y a 2 h ») : des
    /// chiffres seuls ne disent pas si c'est bien, et un résultat sans date ne
    /// dit pas s'il vaut encore ici. Le verdict suit l'échelle de débit de
    /// l'app, sur le débit descendant.
    static func title(for state: State, now: Date = Date()) -> String {
        let result: SpeedtestRunResult
        switch state {
        case .idle(let last?): result = last
        case .finished(let finished), .finishedUnsaved(let finished): result = finished
        case .idle(.none), .running, .failed: return String(localized: "Speedtest")
        }
        let verdict = SQQualityScale.Throughput(mbps: result.downloadMbps).label
        return "\(verdict) · \(relativeDate(result.createdAt, now: now))"
    }

    /// « il y a 2 h », « maintenant » juste après la mesure.
    static func relativeDate(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        let elapsed = date.timeIntervalSince(now)
        return formatter.localizedString(fromTimeInterval: abs(elapsed) < 60 ? 0 : min(elapsed, 0))
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
            return resultItems(last)

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
            return resultItems(result)

        case .finishedUnsaved(let result):
            return resultItems(result) + [CPInformationItem(
                title: String(localized: "Non enregistré"),
                detail: String(localized: "Ce résultat n’a pas pu être sauvegardé.")
            )]

        case .failed(let message):
            return [CPInformationItem(title: String(localized: "Échec"), detail: message)]
        }
    }

    /// Les quatre valeurs de la maquette : descendant, montant, latence, réseau.
    /// Le libellé interne du test (« iOS speedtest ») n'y figure plus.
    static func resultItems(_ result: SpeedtestRunResult) -> [CPInformationItem] {
        var items: [CPInformationItem] = []
        items.append(CPInformationItem(title: String(localized: "Descendant"),
                                       detail: mbps(result.downloadMbps)))
        if let upload = result.uploadMbps {
            items.append(CPInformationItem(title: String(localized: "Montant"), detail: mbps(upload)))
        }
        if let ping = result.primaryPingMs {
            items.append(CPInformationItem(title: String(localized: "Latence"),
                                           detail: "\(Int(ping.rounded())) ms"))
        }
        if let network = networkLabel(result) {
            items.append(CPInformationItem(title: String(localized: "Réseau"), detail: network))
        }
        return items
    }

    /// « Bouygues 5G », « Wi-Fi » : le réseau mesuré, en nom court (la
    /// colonne est étroite). L'opérateur est celui du réseau hôte
    /// (`operatorKey`), pas la marque de la SIM d'un MVNO.
    static func networkLabel(_ result: SpeedtestRunResult) -> String? {
        switch result.connectionType {
        case .wifi:
            return "Wi-Fi"
        case .cellular:
            let raw = result.operatorKey ?? result.networkOperatorName ?? result.carrierName
            let name = SQBrand.operatorShortName(raw) ?? raw.flatMap { $0.isEmpty ? nil : $0 }
            let generation = SQQualityScale.Generation(technology: result.cellularTechnology?.rawValue)
            let parts = [name, generation == .none ? nil : generation.label].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case .wired, .other:
            return nil
        }
    }

    /// Un seul test à la fois : pendant la mesure, aucun bouton. Deux tests
    /// concurrents se fausseraient mutuellement, et le conducteur n'a pas à
    /// deviner lequel des deux il regarde.
    private static func buttons(for state: State, actions: Actions) -> [CPTextButton] {
        guard let start = actions.start else { return [] }
        if case .running = state { return [] }
        // Au repos, même avec un ancien résultat, c'est un NOUVEAU test qu'on
        // lance ; « Relancer » ne vaut que juste après une mesure ou un échec.
        let title: String
        switch state {
        case .idle: title = String(localized: "Lancer le test")
        case .finished, .finishedUnsaved, .failed: title = String(localized: "Relancer")
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

    /// Arrondi à l'entier au-dessus de 10 Mbit/s : au volant, la décimale d'un
    /// débit à 187 Mbit/s n'apporte rien et allonge le nombre à lire. L'unité et
    /// le séparateur décimal sont ceux du reste de l'app (`SQUnits`).
    static func mbps(_ value: Double) -> String {
        guard value.isFinite, value >= 10, value < 1_000 else { return SQUnits.throughput(mbps: value) }
        return "\(Int(value.rounded())) \(SQUnits.throughputUnit(mbps: value))"
    }
}
