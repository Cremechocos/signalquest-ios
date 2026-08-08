import CarPlay
import CoreLocation

/// Fiches affichées au tap sur un marqueur : antenne, panne, évolution.
///
/// Reprend le CONTENU des sheets iOS, pas leur forme — `AntennaDetailSheet` fait
/// 1199 lignes de SwiftUI et n'a pas d'équivalent en CarPlay. Ce qui compte ici
/// est la sélection : `CPInformationTemplate` plafonne à **10 items et 3
/// boutons**, tronqués SILENCIEUSEMENT au-delà (`CPInformationTemplate.h:39-40`).
/// Un champ ajouté sans réfléchir en fait donc disparaître un autre, sans erreur.
/// D'où l'ordre ci-dessous, du plus utile au volant au moins utile.
@MainActor
enum CarPlayDetailTemplateBuilder {
    /// Marge de sécurité vis-à-vis des plafonds CarPlay.
    static let maxItems = 10
    static let maxActions = 3

    struct Actions {
        var navigate: (() -> Void)?
        var center: (() -> Void)?
    }

    // MARK: - Antenne

    /// - Parameters:
    ///   - payload: ce que la carte sait déjà — affiché immédiatement, sans attendre le réseau.
    ///   - details: enrichissement serveur, nil tant qu'il n'est pas arrivé (ou s'il échoue).
    ///   - userLocation: pour la distance et le cap. Nil si la position n'est pas connue.
    static func antenna(payload: MapAnnotationPayload,
                        details: AntennaDetails?,
                        userLocation: CLLocation?,
                        actions: Actions) -> CPInformationTemplate {
        var items: [CPInformationItem] = []

        if let bearing = bearingItem(from: userLocation, to: payload.coordinate) {
            // En premier : c'est la seule information qui situe l'antenne par
            // rapport au conducteur, et donc la seule qui se périme en roulant.
            items.append(bearing)
        }
        let operators = details?.operators.isEmpty == false ? details!.operators : []
        if !operators.isEmpty {
            items.append(CPInformationItem(title: String(localized: "Opérateurs"),
                                           detail: operators.joined(separator: ", ")))
        }
        if let technologies = details?.technologies, !technologies.isEmpty {
            items.append(CPInformationItem(title: String(localized: "Technologies"),
                                           detail: technologies.joined(separator: ", ")))
        }
        if let bands = details?.bands, !bands.isEmpty {
            items.append(CPInformationItem(title: String(localized: "Bandes"),
                                           detail: bands.prefix(6).joined(separator: ", ")))
        }
        if let height = details?.height {
            items.append(CPInformationItem(title: String(localized: "Hauteur"),
                                           detail: "\(Int(height.rounded())) m"))
        }
        if let address = details?.address, !address.isEmpty {
            items.append(CPInformationItem(title: String(localized: "Adresse"), detail: address))
        }
        if let siteId = details?.siteId ?? payload.backendId {
            items.append(CPInformationItem(title: String(localized: "Site"), detail: siteId))
        }
        if details == nil {
            // Sans cette ligne, une fiche presque vide passerait pour une antenne
            // sans données, alors que la requête est simplement en cours.
            items.append(CPInformationItem(title: String(localized: "Détails"),
                                           detail: String(localized: "Chargement…")))
        }

        return CPInformationTemplate(
            title: payload.title,
            layout: .twoColumn,
            items: Array(items.prefix(maxItems)),
            actions: buttons(actions)
        )
    }

    // MARK: - Panne

    static func outage(_ site: OutageSiteLive,
                       userLocation: CLLocation?,
                       actions: Actions) -> CPInformationTemplate {
        var items: [CPInformationItem] = []
        if let lat = site.lat, let lon = site.lon,
           let bearing = bearingItem(from: userLocation,
                                     to: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
            items.append(bearing)
        }
        if let status = site.status {
            items.append(CPInformationItem(title: String(localized: "État"), detail: status))
        }
        if let operatorName = site.operator {
            items.append(CPInformationItem(title: String(localized: "Opérateur"), detail: operatorName))
        }
        if let commune = site.commune {
            items.append(CPInformationItem(title: String(localized: "Commune"), detail: commune))
        }
        if let detail = site.detail, !detail.isEmpty {
            items.append(CPInformationItem(title: String(localized: "Détail"), detail: detail))
        }
        if let startedAt = site.startedAt {
            items.append(CPInformationItem(title: String(localized: "Depuis"), detail: startedAt))
        }
        return CPInformationTemplate(
            title: site.siteId ?? String(localized: "Site en panne"),
            layout: .twoColumn,
            items: Array(items.prefix(maxItems)),
            actions: buttons(actions)
        )
    }

    // MARK: - Évolution

    static func planned(_ site: PlannedSiteLive,
                        userLocation: CLLocation?,
                        actions: Actions) -> CPInformationTemplate {
        var items: [CPInformationItem] = []
        if let lat = site.lat, let lon = site.lon,
           let bearing = bearingItem(from: userLocation,
                                     to: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
            items.append(bearing)
        }
        items.append(CPInformationItem(title: String(localized: "Statut"),
                                       detail: statusLabel(site.activation?.status ?? .planned)))
        if let operatorName = site.operator {
            items.append(CPInformationItem(title: String(localized: "Opérateur"), detail: operatorName))
        }
        if !site.technologies.isEmpty {
            items.append(CPInformationItem(title: String(localized: "Technologies prévues"),
                                           detail: site.technologies.joined(separator: ", ")))
        }
        if let commune = site.commune {
            items.append(CPInformationItem(title: String(localized: "Commune"), detail: commune))
        }
        return CPInformationTemplate(
            title: site.codeSite ?? String(localized: "Site prévisionnel"),
            layout: .twoColumn,
            items: Array(items.prefix(maxItems)),
            actions: buttons(actions)
        )
    }

    // MARK: - Communs

    static func statusLabel(_ status: PlannedActivationStatus) -> String {
        switch status {
        case .active: return String(localized: "Actif")
        case .upgradePending: return String(localized: "Upgrade en attente")
        case .declared: return String(localized: "Déclaré")
        case .planned: return String(localized: "Prévu")
        }
    }

    /// « à 340 m, à l'est » — distance ET direction. La distance seule ne dit pas
    /// où regarder, et c'est précisément ce qu'on cherche en roulant.
    static func bearingItem(from userLocation: CLLocation?,
                            to coordinate: CLLocationCoordinate2D) -> CPInformationItem? {
        guard let userLocation else { return nil }
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distance = userLocation.distance(from: target)
        let bearing = AntennaSectorGeometry.bearing(from: userLocation.coordinate, to: coordinate)
        return CPInformationItem(
            title: String(localized: "Distance"),
            detail: "\(SQUnits.distance(meters: distance)) · \(compassLabel(bearing))"
        )
    }

    /// Rose des vents en 8 points : au volant, « est » se comprend d'un coup
    /// d'œil là où « 87° » demande un effort.
    static func compassLabel(_ degrees: Double) -> String {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        switch normalized {
        case ..<22.5, 337.5...: return String(localized: "au nord")
        case ..<67.5: return String(localized: "au nord-est")
        case ..<112.5: return String(localized: "à l'est")
        case ..<157.5: return String(localized: "au sud-est")
        case ..<202.5: return String(localized: "au sud")
        case ..<247.5: return String(localized: "au sud-ouest")
        case ..<292.5: return String(localized: "à l'ouest")
        default: return String(localized: "au nord-ouest")
        }
    }

    private static func buttons(_ actions: Actions) -> [CPTextButton] {
        var buttons: [CPTextButton] = []
        if let navigate = actions.navigate {
            buttons.append(CPTextButton(title: String(localized: "Y aller"),
                                        textStyle: .confirm) { _ in navigate() })
        }
        if let center = actions.center {
            buttons.append(CPTextButton(title: String(localized: "Centrer"),
                                        textStyle: .normal) { _ in center() })
        }
        return Array(buttons.prefix(maxActions))
    }
}
