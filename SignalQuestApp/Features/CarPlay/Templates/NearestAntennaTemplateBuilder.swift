import CarPlay
import CoreLocation
import SwiftUI

/// Onglet « Ici » : ce que vaut le réseau à l'endroit où l'on roule, et quelle
/// antenne le dessert.
///
/// C'est l'écran qui justifie SignalQuest en voiture : la carte montre où sont
/// les antennes, celui-ci répond à « pourquoi ça capte mal ». D'où l'ordre des
/// rangées — le verdict d'abord, l'explication ensuite, la comparaison en
/// dernier.
///
/// Une LISTE à images plutôt qu'une fiche (`CPInformationTemplate`) : la fiche
/// alignait des paires clé/valeur grises, sans couleur ni point d'entrée, et ses
/// boutons du bas étaient la seule chose actionnable. Ici chaque rangée porte
/// une pastille aux couleurs de l'app (verdict, opérateur, génération) qui se
/// lit avant le texte, et ouvre ce qu'elle résume — à la molette comme au doigt.
@MainActor
enum NearestAntennaTemplateBuilder {
    /// Rangées de l'écran, portées par `userInfo` : les tests et le coordinateur
    /// les retrouvent sans dépendre du texte traduit.
    enum Row: Equatable {
        case verdict, antenna, connection, compare, location
    }

    enum Phase: Equatable {
        /// Requêtes en vol : chaque rangée le DIT, au lieu d'afficher un « pas
        /// de mesures » qui serait faux tant que la réponse n'est pas arrivée.
        case loading
        /// Position connue, réponses reçues (éventuellement vides).
        case located
        /// Pas de position : on n'affirme rien de local.
        case withoutLocation
    }

    struct Input {
        var phase: Phase = .located
        var path: NetworkPathStatus
        var quality: NearbyNetworkQuality?
        var nearestSite: AntennaSite?
        var nearestDistanceMeters: CLLocationDistance?
        /// Cap vers l'antenne, en degrés depuis le nord.
        var bearingDegrees: Double?
        /// L'utilisateur est-il dans le lobe d'un des secteurs de l'antenne ?
        var isInSector: Bool?
        /// La liste des antennes n'a pas pu être chargée. Ce n'est PAS « aucune
        /// antenne à proximité », et l'écran ne doit pas le laisser croire.
        var antennasUnavailable = false
    }

    struct Actions {
        /// Détail du verdict : signal et débit médians, nombre de mesures.
        var showQuality: ((NearbyNetworkQuality) -> Void)?
        var showAntenna: ((AntennaSite) -> Void)?
        /// Classement des opérateurs à cet endroit. C'est la question que se
        /// pose vraiment quelqu'un qui capte mal — « est-ce moi, ou est-ce
        /// l'endroit ? » — et la seule à laquelle nos données répondent mieux
        /// que n'importe quelle autre app.
        var compareOperators: (() -> Void)?
    }

    static func make(input: Input, actions: Actions) -> CPListTemplate {
        CPListTemplate(title: String(localized: "Ici"), sections: sections(for: input, actions: actions))
    }

    static func sections(for input: Input, actions: Actions) -> [CPListSection] {
        [CPListSection(items: items(for: input, actions: actions))]
    }

    static func items(for input: Input, actions: Actions = .init()) -> [CPListItem] {
        switch input.phase {
        case .withoutLocation:
            // Ni verdict, ni antenne, ni comparaison : tous trois dépendent de
            // l'endroit. La connexion, elle, se lit sans position.
            return [locationUnknownItem(), connectionItem(for: input.path)]
        case .loading, .located:
            return [
                verdictItem(input, actions),
                antennaItem(input, actions),
                connectionItem(for: input.path),
                compareItem(actions),
            ].compactMap { $0 }
        }
    }

    // MARK: - Verdict

    private static func verdictItem(_ input: Input, _ actions: Actions) -> CPListItem {
        if input.phase == .loading {
            return item(.verdict, text: String(localized: "Analyse du réseau ici…"), detail: nil,
                        image: CarPlayImageFactory.badge(fill: SQNetworkColors.unknownUIColor,
                                                         symbol: "cellularbars", variableValue: 0))
        }
        guard let quality = input.quality, quality.level != .unknown else {
            return item(.verdict, text: String(localized: "Pas assez de mesures"),
                        detail: String(localized: "La communauté n'a pas encore assez mesuré cette zone."),
                        image: CarPlayImageFactory.badge(fill: SQNetworkColors.unknownUIColor,
                                                         symbol: "questionmark"))
        }
        let signal = scale(quality.level)
        let row = item(
            .verdict,
            text: verdictTitle(quality.level),
            detail: verdictDetail(quality),
            image: CarPlayImageFactory.badge(fill: quality.level.uiColor, symbol: signal.glyph,
                                             variableValue: signal.glyph == "cellularbars" ? signal.barsFraction : nil)
        )
        if let showQuality = actions.showQuality {
            row.accessoryType = .disclosureIndicator
            row.handler = { _, completion in
                showQuality(quality)
                completion()
            }
        }
        return row
    }

    static func verdictTitle(_ level: CoverageQualityBand) -> String {
        if level == .noService { return String(localized: "Aucun réseau constaté ici") }
        return String(localized: "Réseau ici : \(level.title.lowercased())")
    }

    /// L'opérateur ET le nombre de mesures qualifient le verdict : « mauvais
    /// sur 3 mesures » et « mauvais sur 400 » ne se valent pas, et un verdict
    /// sans opérateur laisserait croire qu'il vaut pour tout le monde.
    static func verdictDetail(_ quality: NearbyNetworkQuality) -> String {
        "\(operatorName(quality)) · \(samplesPhrase(quality))"
    }

    static func samplesPhrase(_ quality: NearbyNetworkQuality) -> String {
        let radius = SQUnits.distanceCompact(meters: Double(quality.radiusMeters))
        return String(localized: "\(quality.sampleCount) mesures à moins de \(radius)")
    }

    /// Nom complet (« Bouygues Telecom ») : le libellé du verdict est le nom
    /// court, fait pour une pastille de l'iPhone, pas pour une ligne de texte.
    static func operatorName(_ quality: NearbyNetworkQuality) -> String {
        SQBrand.operatorName(quality.operatorKey) ?? quality.operatorLabel
    }

    /// Détail du verdict, un niveau sous l'onglet : ce qui ne tient pas sur la
    /// rangée, sans bouton (il n'y a rien à faire de plus à cet endroit).
    static func qualityDetail(_ quality: NearbyNetworkQuality) -> CPInformationTemplate {
        var items = [CPInformationItem(title: String(localized: "Réseau ici"), detail: quality.level.title)]
        if let rsrp = quality.medianRsrpDbm {
            items.append(CPInformationItem(title: String(localized: "Signal médian"), detail: "\(rsrp) dBm"))
        }
        if let download = quality.medianDownloadMbps {
            items.append(CPInformationItem(
                title: String(localized: "Débit médian"),
                detail: "\(download) \(SQUnits.throughputUnit(mbps: Double(download)))"
            ))
        }
        items.append(CPInformationItem(title: String(localized: "Mesures"), detail: samplesPhrase(quality)))
        items.append(CPInformationItem(title: String(localized: "Opérateur"), detail: operatorName(quality)))
        return CPInformationTemplate(
            title: String(localized: "Réseau ici"),
            layout: .twoColumn,
            items: Array(items.prefix(CarPlayDetailTemplateBuilder.maxItems)),
            actions: []
        )
    }

    // MARK: - Antenne

    private static func antennaItem(_ input: Input, _ actions: Actions) -> CPListItem {
        // Sans site connu, pas de point d'opérateur à montrer : le symbole dit
        // de quoi parle la rangée.
        let neutral = CarPlayImageFactory.badge(fill: SQNetworkColors.unknownUIColor,
                                                symbol: "antenna.radiowaves.left.and.right")
        if input.phase == .loading {
            return item(.antenna, text: String(localized: "Recherche des antennes autour…"),
                        detail: nil, image: neutral)
        }
        guard let site = input.nearestSite else {
            if input.antennasUnavailable {
                return item(.antenna, text: String(localized: "Antennes indisponibles"),
                            detail: String(localized: "Impossible de charger pour le moment."), image: neutral)
            }
            return item(.antenna, text: String(localized: "Aucune antenne connue à proximité."),
                        detail: nil, image: neutral)
        }
        let row = item(
            .antenna,
            text: antennaTitle(distanceMeters: input.nearestDistanceMeters, bearingDegrees: input.bearingDegrees),
            detail: antennaDetail(site, isInSector: input.isInSector),
            image: operatorBadge(for: site.operators)
        )
        if let showAntenna = actions.showAntenna {
            row.accessoryType = .disclosureIndicator
            row.handler = { _, completion in
                showAntenna(site)
                completion()
            }
        }
        return row
    }

    /// Distance ET direction : la distance seule ne dit pas où regarder.
    static func antennaTitle(distanceMeters: CLLocationDistance?, bearingDegrees: Double?) -> String {
        guard let distanceMeters else { return String(localized: "Antenne la plus proche") }
        let distance = SQUnits.distance(meters: distanceMeters)
        guard let bearingDegrees else { return String(localized: "Antenne à \(distance)") }
        let direction = CarPlayDetailTemplateBuilder.compassLabel(bearingDegrees)
        return String(localized: "Antenne à \(distance), \(direction)")
    }

    /// Qui émet, si l'on est dans l'axe d'un secteur — ce qui explique une
    /// bonne réception malgré la distance, et l'inverse — puis la génération la
    /// plus récente. Dans cet ordre et en mots courts : la ligne de détail tient
    /// en une quarantaine de caractères sur un écran standard (800 × 480), et
    /// c'est la fin qui est coupée.
    static func antennaDetail(_ site: AntennaSite, isInSector: Bool?) -> String {
        let axis = isInSector.map {
            $0 ? String(localized: "Dans l'axe") : String(localized: "Hors de l'axe")
        }
        return [operatorNames(site.operators), axis, newestGeneration(site.technologies)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// « SFR / Bouygues Telecom » : noms complets, clé brute en secours plutôt
    /// qu'un faux nom.
    static func operatorNames(_ raw: [String]) -> String {
        var seen = Set<String>()
        return raw
            .map { SQBrand.operatorName($0) ?? $0 }
            .filter { seen.insert($0).inserted }
            .joined(separator: " / ")
    }

    /// « 5G, 4G » : générations dédoublonnées, la plus récente d'abord. Le
    /// serveur mélange « LTE », « 4G », « 5G NR »… qu'un conducteur n'a pas à
    /// décoder.
    static func generations(_ raw: [String]) -> String {
        let ranked = Set(raw.map { SQQualityScale.Generation(technology: $0) })
            .filter { $0 != .none }
            .sorted { $0.rank > $1.rank }
        return ranked.map(generationLabel).joined(separator: ", ")
    }

    /// « 5G » : la plus récente seulement, pour une ligne où la place manque.
    static func newestGeneration(_ raw: [String]) -> String? {
        raw.map { SQQualityScale.Generation(technology: $0) }
            .filter { $0 != .none }
            .max { $0.rank < $1.rank }
            .map(generationLabel)
    }

    private static func generationLabel(_ generation: SQQualityScale.Generation) -> String {
        switch generation {
        case .fiveG: return "5G"
        case .fourG: return "4G"
        case .threeG: return "3G"
        case .twoG: return "2G"
        case .none: return ""
        }
    }

    /// Une part par opérateur sur un support partagé : la pastille dit « qui »
    /// avant le texte, avec le point de la carte.
    private static func operatorBadge(for operators: [String]) -> UIImage {
        CarPlayImageFactory.operatorBadge(fills: operators.prefix(4).map { UIColor(SQBrand.operatorColor($0)) })
    }

    // MARK: - Connexion

    /// Ce à quoi l'iPhone est réellement connecté, qui peut différer du verdict
    /// communautaire (autre opérateur, Wi-Fi du véhicule…).
    static func connectionItem(for path: NetworkPathStatus) -> CPListItem {
        let operatorName = path.operatorName
            .flatMap { $0.isEmpty ? nil : (SQBrand.operatorName($0) ?? $0) }
        return item(.connection,
                    text: String(localized: "Connexion : \(path.displayName)"),
                    detail: path.connection == .cellular ? operatorName : nil,
                    image: connectionImage(for: path))
    }

    private static func connectionImage(for path: NetworkPathStatus) -> UIImage {
        switch path.connection {
        case .cellular:
            let generation = SQQualityScale.Generation(technology: path.cellularTechnology?.rawValue)
            guard generation != .none else {
                return CarPlayImageFactory.badge(fill: SQNetworkColors.unknownUIColor,
                                                 symbol: "antenna.radiowaves.left.and.right")
            }
            return CarPlayImageFactory.badge(fill: generation.uiColor, text: generationLabel(generation))
        case .wifi:
            return CarPlayImageFactory.badge(fill: SQNetworkColors.uiColor(SQQualityScale.noServiceHex),
                                             symbol: "wifi")
        case .wired, .other:
            return CarPlayImageFactory.badge(fill: SQNetworkColors.unknownUIColor, symbol: "network")
        }
    }

    // MARK: - Comparaison, position

    private static func compareItem(_ actions: Actions) -> CPListItem? {
        guard let compareOperators = actions.compareOperators else { return nil }
        let row = item(.compare,
                       text: String(localized: "Comparer les opérateurs ici"),
                       detail: String(localized: "Débit médian de chaque réseau"),
                       image: CarPlayImageFactory.badge(fill: CarPlayImageFactory.brandColor,
                                                        symbol: "chart.bar.fill"))
        row.accessoryType = .disclosureIndicator
        row.handler = { _, completion in
            compareOperators()
            completion()
        }
        return row
    }

    private static func locationUnknownItem() -> CPListItem {
        item(.location,
             text: String(localized: "Position inconnue"),
             detail: String(localized: "SignalQuest n'a pas accès à ta position pour l'instant."),
             image: CarPlayImageFactory.badge(fill: SQNetworkColors.unknownUIColor, symbol: "location.slash"))
    }

    // MARK: - Outils

    private static func item(_ row: Row, text: String, detail: String?, image: UIImage) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail, image: image)
        item.userInfo = row
        return item
    }

    private static func scale(_ level: CoverageQualityBand) -> SQQualityScale.Signal {
        switch level {
        case .excellent: return .excellent
        case .good: return .good
        case .fair: return .fair
        case .weak: return .weak
        case .poor: return .poor
        case .noService: return .noService
        case .unknown: return .unknown
        }
    }
}
