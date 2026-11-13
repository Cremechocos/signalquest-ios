import CarPlay

/// Onglet Trajet : lancer un drive test depuis la voiture et en suivre
/// l'avancée (lot 4, choix d'Alexandre du 13/11).
///
/// Le moteur est celui de l'iPhone (`DriveTestViewModel`, partagé par
/// `AppServices`) : cet écran ne fait que montrer son état et poser un bouton.
/// Une seule pression pour démarrer ; un simple avertissement du préflight
/// (GPS, batterie, réseau restreint) s'affiche sans bloquer ; un vrai blocage
/// (`DriveTestHandsFreeStart`) remplace le bouton par une phrase neutre, qui
/// dit pourquoi sans envoyer le conducteur sur son iPhone.
@MainActor
enum DriveTripTemplateBuilder {
    /// CarPlay limite les mises à jour de données à une toutes les 10 s, et
    /// une distance ou un compte de tests n'a pas besoin d'aller plus vite.
    static let refreshInterval: TimeInterval = 10

    struct Running: Equatable {
        var startedAt: Date
        /// Pause Wi-Fi ou à l'arrêt : le titre le dit à la place de « En cours ».
        var isPaused: Bool
        var distanceMeters: Double
        /// Tests terminés de ce trajet.
        var completedTests: Int
        /// Descendant du dernier test de CE trajet ; nil avant le premier.
        var lastDownloadMbps: Double?
        var network: String?
        /// Alertes « réseau faible » émises pendant ce trajet.
        var weakZones: Int
        /// « Prochain test dans 300 m », « En pause — à l'arrêt »…
        var status: String
        /// Avertissements du préflight au départ, montrés jusqu'au premier test.
        var warnings: [DriveTestPreflightIssue] = []
    }

    enum State: Equatable {
        /// Au repos, avec le dernier trajet s'il existe, et la raison d'un
        /// départ refusé à l'instant (un speedtest qui mesure déjà, par exemple).
        case idle(lastTrip: DriveTestViewModel.SessionRecap?, notice: String?)
        /// Démarrer est impossible : premier trajet pas encore présenté,
        /// localisation, stockage ou connexion.
        case blocked(DriveTestHandsFreeStart.Refusal)
        case running(Running)
    }

    struct Actions {
        var start: (() -> Void)?
        var stop: (() -> Void)?
    }

    static func make(state: State, actions: Actions, now: Date = Date()) -> CPInformationTemplate {
        CPInformationTemplate(
            title: title(for: state, now: now),
            layout: .twoColumn,
            items: Array(items(for: state).prefix(CarPlayDetailTemplateBuilder.maxItems)),
            actions: buttons(for: state, actions: actions)
        )
    }

    /// En roulant, la durée (« En cours · 12 min ») ; au repos, la date du
    /// dernier trajet, pour savoir s'il vaut encore quelque chose.
    static func title(for state: State, now: Date = Date()) -> String {
        switch state {
        case .running(let running):
            let elapsed = duration(now.timeIntervalSince(running.startedAt))
            return running.isPaused
                ? String(localized: "En pause · \(elapsed)")
                : String(localized: "En cours · \(elapsed)")
        case .idle(let last?, _):
            let when = SpeedtestTemplateBuilder.relativeDate(last.endedAt, now: now)
            return String(localized: "Dernier trajet · \(when)")
        case .idle(.none, _), .blocked:
            return String(localized: "Trajet")
        }
    }

    static func items(for state: State) -> [CPInformationItem] {
        switch state {
        case .running(let running):
            return runningItems(running)

        case .idle(let last, let notice):
            var items: [CPInformationItem]
            if let last {
                items = recapItems(last)
            } else {
                items = [CPInformationItem(
                    title: String(localized: "Aucun trajet"),
                    // Courte : la colonne de droite tient deux lignes d'une
                    // vingtaine de caractères en taille Minimum (CarPlay
                    // Simulator, 13/11) et coupait l'ancienne phrase.
                    detail: String(localized: "Des speedtests le long de la route.")
                )]
            }
            if let notice, !notice.isEmpty {
                items.insert(CPInformationItem(title: String(localized: "Impossible de démarrer"), detail: notice),
                             at: 0)
            }
            return items

        case .blocked(let refusal):
            let reason = DriveTestHandsFreeStart.reason(refusal)
            return [CPInformationItem(title: reason.title, detail: reason.detail)]
        }
    }

    /// Les six valeurs de la maquette, toujours dans le même ordre : une
    /// valeur encore inconnue s'affiche « — » plutôt que de décaler les autres.
    static func runningItems(_ running: Running) -> [CPInformationItem] {
        var items = [
            CPInformationItem(title: String(localized: "Distance"),
                              detail: SQUnits.distance(meters: running.distanceMeters)),
            CPInformationItem(title: String(localized: "Tests"), detail: "\(running.completedTests)"),
            CPInformationItem(title: String(localized: "Dernier débit"),
                              detail: running.lastDownloadMbps.map(SpeedtestTemplateBuilder.mbps) ?? "—"),
            CPInformationItem(title: String(localized: "Réseau"), detail: running.network ?? "—"),
            CPInformationItem(title: String(localized: "Zones faibles"), detail: "\(running.weakZones)"),
            CPInformationItem(title: String(localized: "État"), detail: running.status),
        ]
        // Un avertissement du départ ne vaut que tant qu'aucun test n'a abouti :
        // une fois une mesure faite, le GPS ou la connexion ont fait leurs preuves.
        let warnings = running.completedTests == 0 ? running.warnings.compactMap(warningLabel) : []
        if !warnings.isEmpty {
            items.append(CPInformationItem(title: String(localized: "Attention"),
                                           detail: warnings.joined(separator: " · ")))
        }
        return items
    }

    static func recapItems(_ recap: DriveTestViewModel.SessionRecap) -> [CPInformationItem] {
        var items = [CPInformationItem(title: String(localized: "Distance"),
                                       detail: SQUnits.distance(meters: recap.distanceMeters))]
        if let startedAt = recap.startedAt {
            items.append(CPInformationItem(title: String(localized: "Durée"),
                                           detail: duration(recap.endedAt.timeIntervalSince(startedAt))))
        }
        items.append(CPInformationItem(title: String(localized: "Tests"), detail: "\(recap.testCount)"))
        if let average = recap.averageDownloadMbps {
            items.append(CPInformationItem(title: String(localized: "Débit moyen"),
                                           detail: SpeedtestTemplateBuilder.mbps(average)))
        }
        return items
    }

    /// « 12 min », « 1 h 05 min » : la seconde ne se lit pas en conduisant et
    /// changerait le titre à chaque rafraîchissement.
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: max(0, seconds)) ?? ""
    }

    /// « Bouygues 5G », « Wi-Fi » : le réseau du moment, au même format que
    /// l'onglet Speedtest. L'opérateur est celui que le drive test a résolu
    /// (réseau hôte), pas une marque de SIM.
    static func networkLabel(connection: NetworkConnectionKind, operatorLabel: String?,
                             technology: CellularRadioTechnology?) -> String? {
        switch connection {
        case .wifi:
            return "Wi-Fi"
        case .cellular:
            let name = SQBrand.operatorShortName(operatorLabel) ?? operatorLabel.flatMap { $0.isEmpty ? nil : $0 }
            let generation = SQQualityScale.Generation(technology: technology?.rawValue)
            let parts = [name, generation == .none ? nil : generation.label].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case .wired, .other:
            return nil
        }
    }

    /// Libellé court d'un avertissement. Le Wi-Fi n'en a pas : l'état
    /// « En pause — Wi-Fi détecté » le dit déjà.
    static func warningLabel(_ issue: DriveTestPreflightIssue) -> String? {
        switch issue.id {
        case .gpsFix: return String(localized: "Position GPS en cours d'acquisition")
        case .storage: return String(localized: "Espace de stockage faible")
        case .battery: return String(localized: "Batterie faible")
        case .constrainedNetwork: return String(localized: "Mode données faibles actif")
        case .wifi, .locationPermission, .connectivity: return nil
        }
    }

    /// « Démarrer » au repos, « Arrêter » en roulant, rien quand c'est bloqué.
    private static func buttons(for state: State, actions: Actions) -> [CPTextButton] {
        switch state {
        case .idle:
            guard let start = actions.start else { return [] }
            return [CPTextButton(title: String(localized: "Démarrer"), textStyle: .confirm) { _ in start() }]
        case .running:
            guard let stop = actions.stop else { return [] }
            return [CPTextButton(title: String(localized: "Arrêter"), textStyle: .cancel) { _ in stop() }]
        case .blocked:
            return []
        }
    }
}
