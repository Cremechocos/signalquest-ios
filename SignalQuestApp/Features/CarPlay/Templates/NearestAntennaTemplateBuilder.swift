import CarPlay
import CoreLocation

/// Écran « Ici » : ce que vaut le réseau à l'endroit où l'on se trouve, et
/// quelle antenne le dessert.
///
/// C'est l'écran qui justifie SignalQuest en voiture : la carte montre où sont
/// les antennes, celui-ci répond à « pourquoi ça capte mal ». D'où l'ordre des
/// lignes — le verdict d'abord, l'explication ensuite.
///
/// Comme toutes les fiches CarPlay : 10 items et 3 boutons au maximum, tronqués
/// en silence au-delà.
@MainActor
enum NearestAntennaTemplateBuilder {
    struct Input {
        var path: NetworkPathStatus
        var quality: NearbyNetworkQuality?
        var nearestSite: AntennaSite?
        var nearestDistanceMeters: CLLocationDistance?
        /// Cap vers l'antenne, en degrés depuis le nord.
        var bearingDegrees: Double?
        /// L'utilisateur est-il dans le lobe d'un des secteurs de l'antenne ?
        var isInSector: Bool?
    }

    struct Actions {
        var showOnMap: (() -> Void)?
        var navigate: (() -> Void)?
        /// Classement des opérateurs à cet endroit. C'est la question que se
        /// pose vraiment quelqu'un qui capte mal — « est-ce moi, ou est-ce
        /// l'endroit ? » — et la seule à laquelle nos données répondent mieux
        /// que n'importe quelle autre app.
        var compareOperators: (() -> Void)?
    }

    static func make(input: Input, actions: Actions) -> CPInformationTemplate {
        CPInformationTemplate(
            title: String(localized: "Ici"),
            layout: .twoColumn,
            items: Array(items(for: input).prefix(CarPlayDetailTemplateBuilder.maxItems)),
            actions: buttons(actions)
        )
    }

    static func items(for input: Input) -> [CPInformationItem] {
        var items: [CPInformationItem] = []

        // 1. Le verdict, en premier : c'est la réponse à la question posée.
        if let quality = input.quality {
            items.append(CPInformationItem(
                title: String(localized: "Réseau ici"),
                detail: "\(quality.level.title) · \(quality.operatorLabel)"
            ))
            if let rsrp = quality.medianRsrpDbm {
                items.append(CPInformationItem(title: String(localized: "Signal médian"),
                                               detail: "\(rsrp) dBm"))
            }
            if let download = quality.medianDownloadMbps {
                items.append(CPInformationItem(title: String(localized: "Débit médian"),
                                               detail: "\(download) Mb/s"))
            }
            // Le nombre de mesures qualifie le verdict : « mauvais sur 3 mesures »
            // et « mauvais sur 400 » ne se valent pas, et l'utilisateur qui
            // contribue à ces données est le mieux placé pour le comprendre.
            items.append(CPInformationItem(
                title: String(localized: "Mesures"),
                detail: String(localized: "\(quality.sampleCount) dans \(SQUnits.radius(meters: Double(quality.radiusMeters)))")
            ))
        } else {
            items.append(CPInformationItem(
                title: String(localized: "Réseau ici"),
                detail: String(localized: "Pas assez de mesures dans cette zone.")
            ))
        }

        // 2. Ce à quoi on est réellement connecté, qui peut différer du verdict
        // communautaire (autre opérateur, Wi-Fi du véhicule…).
        items.append(CPInformationItem(
            title: String(localized: "Connexion"),
            detail: [input.path.operatorName, input.path.displayName]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        ))

        // 3. L'antenne qui dessert, avec de quoi la situer.
        if let site = input.nearestSite {
            items.append(CPInformationItem(
                title: String(localized: "Antenne la plus proche"),
                detail: [site.operators.joined(separator: "/"),
                         site.technologies.prefix(3).joined(separator: "/")]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            ))
            if let distance = input.nearestDistanceMeters {
                let direction = input.bearingDegrees.map { CarPlayDetailTemplateBuilder.compassLabel($0) }
                items.append(CPInformationItem(
                    title: String(localized: "Distance"),
                    detail: [SQUnits.distance(meters: distance), direction]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                ))
            }
            if let isInSector = input.isInSector {
                // Être dans l'axe d'un secteur explique une bonne réception
                // malgré la distance — et l'inverse explique le contraire.
                items.append(CPInformationItem(
                    title: String(localized: "Orientation"),
                    detail: isInSector
                        ? String(localized: "Tu es dans l'axe d'un secteur")
                        : String(localized: "Hors de l'axe des secteurs")
                ))
            }
        } else {
            items.append(CPInformationItem(
                title: String(localized: "Antenne la plus proche"),
                detail: String(localized: "Aucune antenne connue à proximité.")
            ))
        }

        return items
    }

    private static func buttons(_ actions: Actions) -> [CPTextButton] {
        var buttons: [CPTextButton] = []
        if let navigate = actions.navigate {
            buttons.append(CPTextButton(title: String(localized: "Y aller"),
                                        textStyle: .confirm) { _ in navigate() })
        }
        if let showOnMap = actions.showOnMap {
            buttons.append(CPTextButton(title: String(localized: "Voir sur la carte"),
                                        textStyle: .normal) { _ in showOnMap() })
        }
        if let compareOperators = actions.compareOperators {
            buttons.append(CPTextButton(title: String(localized: "Comparer"),
                                        textStyle: .normal) { _ in compareOperators() })
        }
        return Array(buttons.prefix(CarPlayDetailTemplateBuilder.maxActions))
    }
}
