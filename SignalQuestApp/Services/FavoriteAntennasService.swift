import Foundation

/// Antennes suivies.
///
/// ⚠️ Le contrat serveur n'offre PAS d'ajout ni de suppression unitaire : `PUT` remplace la liste
/// entière. Ce service porte donc l'état courant et le renvoie complet à chaque modification.
/// C'est aussi pourquoi il est observable et unique dans l'app : deux copies de la liste, et la
/// dernière à écrire effacerait les ajouts de l'autre.
@MainActor
final class FavoriteAntennasService: ObservableObject {
    @Published private(set) var favorites: [FavoriteAntenna] = []
    @Published private(set) var notifyOnIssues: Bool = true
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let api: APIClient
    /// Vrai une fois la liste chargée depuis le serveur. Tant qu'elle est fausse, on n'ÉCRIT
    /// pas : un `PUT` construit sur une liste vide non chargée effacerait tous les favoris.
    private var hasLoaded = false

    init(api: APIClient) { self.api = api }

    private static let path = "/api/android/favorite-antennas"

    func isFavorite(siteId: String, market: String) -> Bool {
        favorites.contains { $0.siteId == siteId && $0.market == market }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let response: FavoriteAntennasResponse = try await api.request(
                APIEndpoint(path: Self.path, method: .get),
                as: FavoriteAntennasResponse.self
            )
            favorites = response.favorites
            notifyOnIssues = response.notifyFavoriteAntennaIssuesPush ?? true
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Ajoute ou retire un site.
    ///
    /// Refuse d'écrire tant que la liste n'a pas été chargée : construire un `PUT` sur un état
    /// vide non confirmé effacerait tous les favoris du compte, y compris ceux posés depuis
    /// Android. Mieux vaut ne rien faire que perdre la liste de quelqu'un.
    @discardableResult
    func toggle(_ favorite: FavoriteAntenna) async -> Bool {
        if !hasLoaded { await load() }
        guard hasLoaded else { return isFavorite(siteId: favorite.siteId, market: favorite.market) }

        let previous = favorites
        let alreadyThere = isFavorite(siteId: favorite.siteId, market: favorite.market)
        let updated = alreadyThere
            ? favorites.filter { !($0.siteId == favorite.siteId && $0.market == favorite.market) }
            : favorites + [favorite]

        // Optimiste : l'étoile bascule tout de suite, on remet l'état d'avant si le serveur
        // refuse. Attendre l'aller-retour ferait douter d'un simple appui.
        favorites = updated
        do {
            let response: FavoriteAntennasResponse = try await api.requestJSON(
                Self.path,
                method: .put,
                body: FavoriteAntennasRequest(
                    favorites: updated,
                    notifyFavoriteAntennaIssuesPush: notifyOnIssues
                )
            )
            favorites = response.favorites
            notifyOnIssues = response.notifyFavoriteAntennaIssuesPush ?? notifyOnIssues
        } catch {
            favorites = previous
            errorMessage = error.localizedDescription
        }
        return isFavorite(siteId: favorite.siteId, market: favorite.market)
    }

    /// Active ou coupe les notifications de panne sur les antennes suivies.
    func setNotifyOnIssues(_ enabled: Bool) async {
        if !hasLoaded { await load() }
        let previous = notifyOnIssues
        notifyOnIssues = enabled
        do {
            let response: FavoriteAntennasResponse = try await api.requestJSON(
                Self.path,
                method: .put,
                body: FavoriteAntennasRequest(
                    favorites: favorites,
                    notifyFavoriteAntennaIssuesPush: enabled
                )
            )
            favorites = response.favorites
            notifyOnIssues = response.notifyFavoriteAntennaIssuesPush ?? enabled
        } catch {
            notifyOnIssues = previous
            errorMessage = error.localizedDescription
        }
    }
}
