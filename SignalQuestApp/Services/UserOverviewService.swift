import Foundation

/// Ce qui attend l'utilisateur dans ses contributions (plan 3, vague 2), lu en
/// une fois dans `GET /api/user/overview`, comme l'espace personnel du site.
/// Seuls les compteurs utiles à l'app sont décodés ; les autres champs de la
/// réponse sont ignorés.
struct UserOverview: Decodable, Equatable {
    struct Photos: Decodable, Equatable { let total: Int; let pending: Int }
    struct Identifications: Decodable, Equatable { let total: Int; let conflicts: Int }
    struct Missions: Decodable, Equatable { let claimable: Int; let rewardXp: Int }

    let photos: Photos?
    let identifications: Identifications?
    let missions: Missions?

    /// Une ligne « À faire » du Profil, dans l'ordre d'affichage.
    enum Todo: Equatable {
        case claimMissions(count: Int, rewardXp: Int)
        case photosInReview(count: Int)
        case identificationConflicts(count: Int)
    }

    /// Les missions d'abord : elles rapportent des points tout de suite.
    var todos: [Todo] {
        var items: [Todo] = []
        if let missions, missions.claimable > 0 {
            items.append(.claimMissions(count: missions.claimable, rewardXp: missions.rewardXp))
        }
        if let photos, photos.pending > 0 { items.append(.photosInReview(count: photos.pending)) }
        if let identifications, identifications.conflicts > 0 {
            items.append(.identificationConflicts(count: identifications.conflicts))
        }
        return items
    }

    static let demo = UserOverview(
        photos: Photos(total: 14, pending: 1),
        identifications: Identifications(total: 37, conflicts: 0),
        missions: Missions(claimable: 2, rewardXp: 150)
    )
}

struct UserOverviewService: Sendable {
    let api: APIClient

    func overview() async throws -> UserOverview {
        if AppEnvironment.usesDemoData { return .demo }
        return try await api.request(APIEndpoint(path: "/api/user/overview"), as: UserOverview.self)
    }
}
