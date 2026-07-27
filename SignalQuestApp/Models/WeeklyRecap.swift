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
