import Foundation

/// Historique des tests d'expérience pour la liste commune : lignes du téléphone, puis pages
/// du serveur tirées à la demande (`GET /api/user/experience-tests`). Sans compte, rien n'est
/// demandé au serveur. Mêmes règles qu'Android (`ExperienceHistoryViewModel.kt`).
@MainActor
final class ExperienceHistoryModel: ObservableObject {
    struct Environment {
        var ownerScopeId: () -> String
        var localItems: () async -> [ExperienceHistoryItem]
        var history: (ExperienceHistoryQuery) async throws -> ExperienceHistoryPage

        static func live(_ service: ExperienceTestsService) -> Environment {
            Environment(
                ownerScopeId: { LocalAccountScope.currentOwnerScopeId },
                localItems: { await service.localItems() },
                history: { try await service.history($0) }
            )
        }
    }

    static let pageSize = 25

    /// Lignes du téléphone (envoyées ou non) du compte ou de l'invité courant.
    @Published private(set) var local: [ExperienceHistoryItem] = []
    /// Lignes du serveur déjà tirées, du plus récent au plus ancien.
    @Published private(set) var remote: [ExperienceHistoryItem] = []
    @Published private(set) var hasMore = false
    @Published private(set) var loading = false
    /// Une page a échoué : ce qui est montré peut être incomplet.
    @Published private(set) var loadFailed = false
    /// Même la première page a échoué : seul le téléphone est montré.
    @Published private(set) var remoteUnavailable = false
    @Published private(set) var signedIn = false

    private let environment: Environment
    private var owner: String?
    private var nextPage = 1
    private var generation = 0

    init(environment: Environment) {
        self.environment = environment
    }

    /// Local + serveur fusionnés : le serveur fait foi. Quand TOUTES ses pages sont là, une ligne
    /// locale confirmée qu'il ne liste plus a été supprimée ailleurs : elle ne reste pas à l'écran.
    var merged: [ExperienceHistoryItem] {
        // Compte changé, page pas encore relue : rien de l'autre compte ne reste à l'écran.
        guard environment.ownerScopeId() == owner else { return [] }
        let complete = signedIn && !hasMore && !loading && !loadFailed && !remoteUnavailable
        let remoteIds = Set(remote.map(\.id))
        let kept = complete ? local.filter { $0.delivery != .synced || remoteIds.contains($0.id) } : local
        return ExperienceHistoryMerge.merge(local: kept, remote: remote)
    }

    /// Ce que l'historique commun peut afficher sans trou. Première page en échec : on n'attend
    /// plus de page qui ne viendra pas, le téléphone seul s'affiche.
    var source: ExperienceHistorySource {
        ExperienceHistorySource(items: merged, hasMore: hasMore && !remoteUnavailable, loadedUntil: remote.last?.measuredAt)
    }

    /// Relit le téléphone et la première page. Un autre compte repart de zéro : les lignes du
    /// précédent ne restent pas à l'écran.
    func refresh() async {
        generation += 1
        let current = generation
        let scope = environment.ownerScopeId()
        if scope != owner {
            owner = scope
            local = []
            remote = []
            hasMore = false
        }
        signedIn = scope.hasPrefix("user:")
        let items = await environment.localItems()
        guard current == generation else { return }
        local = items
        guard signedIn else {
            remote = []
            hasMore = false
            loading = false
            loadFailed = false
            remoteUnavailable = false
            return
        }
        nextPage = 1
        await fetch(page: 1, generation: current)
    }

    /// « Voir plus » : la page suivante, ou celle qui avait échoué.
    func loadMore() async {
        guard signedIn, hasMore, !loading else { return }
        await fetch(page: nextPage, generation: generation)
    }

    private func fetch(page: Int, generation current: Int) async {
        loading = true
        loadFailed = false
        do {
            let result = try await environment.history(ExperienceHistoryQuery(period: "all", limit: Self.pageSize, page: page))
            guard current == generation, environment.ownerScopeId() == owner else { return }
            remote = page == 1 ? result.items : Self.appending(result.items, to: remote)
            hasMore = result.hasMore && !result.items.isEmpty
            nextPage = page + 1
            remoteUnavailable = false
            loading = false
        } catch {
            guard current == generation else { return }
            loading = false
            guard !error.isCancellation else { return }
            loadFailed = true
            if page == 1 {
                remoteUnavailable = true
                hasMore = false
            }
        }
    }

    private static func appending(_ items: [ExperienceHistoryItem], to list: [ExperienceHistoryItem]) -> [ExperienceHistoryItem] {
        let known = Set(list.map(\.id))
        return list + items.filter { !known.contains($0.id) }
    }
}
