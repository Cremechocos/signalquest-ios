import Foundation

/// Bilan hebdomadaire d'un contributeur, servi par `GET /api/social/recap`.
///
/// Le backend calcule et met en cache 5 minutes par utilisateur : inutile de
/// mémoriser côté client, un rafraîchissement à l'ouverture suffit.
struct WeeklyRecapStats: Decodable, Equatable {
    let weekStart: Date
    let weekEnd: Date
    let speedtestCount: Int
    let topDownloadMbps: Double?
    let topDownloadTech: String?
    let topDownloadOperator: String?
    let sessionPoints: Int
    let sessionDistanceKm: Double?
    let validationCount: Int
    let photoCount: Int
    let badgeCount: Int
    let signalMomentsShared: Int
    let topCity: String?

    /// Une semaine sans la moindre contribution n'a rien à raconter : proposer
    /// de la partager donnerait une carte vide, et un mauvais souvenir.
    var hasSomethingToShow: Bool {
        speedtestCount > 0 || sessionPoints > 0 || validationCount > 0
            || photoCount > 0 || badgeCount > 0 || signalMomentsShared > 0
    }

    /// Les mesures dominent le récit quand il y en a ; sinon on met en avant ce
    /// qui a effectivement occupé la semaine.
    var headline: RecapHeadline {
        if let mbps = topDownloadMbps, mbps > 0 { return .topSpeed(mbps) }
        if sessionPoints > 0 { return .coverage(sessionPoints) }
        if validationCount > 0 { return .validations(validationCount) }
        if photoCount > 0 { return .photos(photoCount) }
        return .none
    }

    /// Les chiffres sous le titre, sauf celui qu'il montre déjà en grand. Les
    /// sessions et les moments partagés ne s'affichaient jamais, et « 1 badges »
    /// n'était pas accordé (lot F, F-34). Les zéros se taisent.
    var secondaryMetrics: [(value: String, label: String)] {
        let headline = headline
        func count(_ value: Int, _ one: String, _ many: String) -> (value: String, label: String)? {
            value > 0 ? (value.formatted(), value == 1 ? one : many) : nil
        }
        var metrics: [(value: String, label: String)?] = [
            count(speedtestCount, String(localized: "speedtest"), String(localized: "speedtests"))
        ]
        if case .coverage = headline {} else {
            metrics.append(count(sessionPoints, String(localized: "point de couverture"), String(localized: "points de couverture")))
        }
        if let km = sessionDistanceKm, km >= 0.1 {
            metrics.append((km.formatted(.number.precision(.fractionLength(0...1))), String(localized: "km parcourus")))
        }
        if case .validations = headline {} else {
            metrics.append(count(validationCount, String(localized: "validation"), String(localized: "validations")))
        }
        if case .photos = headline {} else {
            metrics.append(count(photoCount, String(localized: "photo"), String(localized: "photos")))
        }
        metrics.append(count(badgeCount, String(localized: "badge"), String(localized: "badges")))
        metrics.append(count(signalMomentsShared, String(localized: "moment partagé"), String(localized: "moments partagés")))
        return metrics.compactMap { $0 }
    }

    enum RecapHeadline: Equatable {
        case topSpeed(Double)
        case coverage(Int)
        case validations(Int)
        case photos(Int)
        case none
    }
}

/// Réponse de `POST /api/social/recap` : publie le bilan sous forme de story.
struct WeeklyRecapPublishResponse: Decodable {
    let stats: WeeklyRecapStats?
    /// Vrai si la story de la semaine existait déjà — republier n'en crée pas
    /// une seconde, et l'UI doit le dire plutôt que de feindre un succès neuf.
    let alreadyExisted: Bool?
}
