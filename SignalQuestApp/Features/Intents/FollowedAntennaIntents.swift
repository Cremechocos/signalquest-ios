import AppIntents
import Foundation

/// Antenne suivie, proposée dans Raccourcis et Siri (plan 3, vague 1). Lue dans
/// les favoris du compte, déjà gardés sur l'appareil.
struct FollowedAntennaEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Antenne suivie"
    static let defaultQuery = FollowedAntennaQuery()

    /// Clé du favori (« FR:37199 ») : un même site peut être suivi dans deux marchés.
    let id: String
    let siteId: String
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    /// Même présentation que la liste des antennes suivies du Profil.
    init(_ favorite: FavoriteAntenna) {
        id = favorite.id
        siteId = favorite.siteId
        title = favorite.displayName
        subtitle = [favorite.operator, favorite.market]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct FollowedAntennaQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [FollowedAntennaEntity.ID]) async throws -> [FollowedAntennaEntity] {
        let favorites = await Self.favorites()
        return identifiers.compactMap { id in
            favorites.first { $0.id == id }.map(FollowedAntennaEntity.init)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [FollowedAntennaEntity] {
        await Self.favorites().map(FollowedAntennaEntity.init)
    }

    @MainActor
    private static func favorites() async -> [FavoriteAntenna] {
        let service = AppServicesHolder.services.favoriteAntennas
        if !service.hasLoaded { await service.load() }
        return service.favorites
    }
}

/// « Ouvrir une antenne suivie » : la fiche du site sur la carte, par le même
/// chemin que la liste des antennes suivies du Profil.
struct OpenFollowedAntennaIntent: AppIntent {
    static let title: LocalizedStringResource = "Ouvrir une antenne suivie"
    static let description = IntentDescription("Ouvre la fiche d’une antenne que tu suis, sur la carte.")
    static let openAppWhenRun = true

    @Parameter(title: "Antenne")
    var antenna: FollowedAntennaEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        Self.open(antenna, with: AppServicesHolder.services.router)
        return .result()
    }

    @MainActor
    static func open(_ antenna: FollowedAntennaEntity, with router: AppRouter) {
        router.route(toSite: antenna.siteId)
    }
}
