import Foundation
import Combine

/// Favoris du compte courant : snapshot confirmé + intentions locales durables.
/// Toutes les mutations réseau sont atomiques et sérialisées, jamais un PUT de
/// liste complète. Une intention n'est retirée qu'après son reçu serveur.
@MainActor
final class FavoriteAntennasService: ObservableObject {
    struct ActionScope: Equatable, Sendable {
        let session: LocalAccountSession
        let credentialsID: UUID
    }
    private struct TerminalCapacityRejection: LocalizedError {
        let underlying: APIError
        var errorDescription: String? { underlying.errorDescription }
    }
    @Published private var presentedState: FavoriteAntennasLocalState?
    @Published private(set) var isLoading = false
    @Published private(set) var isSynchronizing = false
    @Published private var presentedError: String?

    var errorMessage: String? { ownsPresentation ? presentedError : nil }
    var favorites: [FavoriteAntenna] { ownsPresentation ? presentedState?.favorites ?? [] : [] }
    var notifyOnIssues: Bool { ownsPresentation ? presentedState?.notifyOnIssues ?? false : false }
    var hasLoaded: Bool { ownsPresentation && presentedState?.hasSnapshot == true }
    var pendingCount: Int { ownsPresentation ? presentedState?.pending.count ?? 0 : 0 }
    var hasAccount: Bool { sessionSnapshot() != nil }

    private struct Context: Equatable, Sendable {
        let session: LocalAccountSession
        let credentialsID: UUID
        let generation: UUID
        var owner: String { session.ownerScopeId }
    }
    private let api: APIClient
    private let store: any FavoriteAntennasStoring
    private let sessionSnapshot: () -> LocalAccountSession?
    private var context: Context?
    private var states: [String: FavoriteAntennasLocalState] = [:]
    private var localReady: Set<String> = []
    private var localLoad: (id: UUID, owner: String, task: Task<FavoriteAntennasLocalState?, Error>)?
    private var synchronization: (id: UUID, task: Task<Void, Never>)?
    private static let path = "/api/android/favorite-antennas"

    init(api: APIClient, store: (any FavoriteAntennasStoring)? = nil,
         sessionSnapshot: @escaping () -> LocalAccountSession? = LocalAccountScope.sessionSnapshot) {
        self.api = api
        self.store = store ?? FavoriteAntennasLocalStore(environmentID: api.config.apiBaseURL.absoluteString)
        self.sessionSnapshot = sessionSnapshot
    }

    func isFavorite(siteId: String, market: String) -> Bool {
        favorites.contains { $0.id == FavoriteAntenna.key(siteId: siteId, market: market) }
    }

    /// Capture synchrone dans le geste UI, avant de créer un Task qui pourrait
    /// ne démarrer qu'après un changement de compte.
    func captureActionScope() -> ActionScope? {
        guard let session = sessionSnapshot() else { return nil }
        return ActionScope(session: session, credentialsID: api.credentials.snapshot().sessionID)
    }

    func isCurrent(_ scope: ActionScope) -> Bool {
        sessionSnapshot() == scope.session && api.credentials.snapshot().sessionID == scope.credentialsID
    }

    func isPending(siteId: String, market: String) -> Bool {
        guard ownsPresentation else { return false }
        return presentedState?.pending.contains { $0.targetKey == FavoriteAntenna.key(siteId: siteId, market: market) } == true
    }

    /// À raccorder au reset de présentation du compte. Les caches de A restent
    /// propriétaires de A ; aucune liste ou erreur de A n'est exposée sous B.
    func resetForAccountChange() { _ = activateCurrentContext() }

    func load() async {
        guard let context = activateCurrentContext(), await loadLocal(context) else { return }
        await synchronize(context)
    }

    @discardableResult
    func toggle(_ favorite: FavoriteAntenna, matching scope: ActionScope? = nil) async -> Bool {
        guard scope.map(isCurrent) != false else { return false }
        guard let context = activateCurrentContext(), await loadLocal(context) else { return false }
        if !hasLoaded { await synchronize(context) }
        guard isCurrent(context), hasLoaded else { return isFavorite(siteId: favorite.siteId, market: favorite.market) }
        let present = !isFavorite(siteId: favorite.siteId, market: favorite.market)
        await enqueue(.favorite(favorite, present: present), context: context)
        return isCurrent(context) && isFavorite(siteId: favorite.siteId, market: favorite.market)
    }

    func remove(_ favorite: FavoriteAntenna, matching scope: ActionScope? = nil) async {
        guard scope.map(isCurrent) != false else { return }
        guard let context = activateCurrentContext(), await loadLocal(context) else { return }
        if !hasLoaded { await synchronize(context) }
        guard isCurrent(context), hasLoaded else { return }
        // La suppression d'une ligne n'est pas un toggle : même si Android l'a
        // déjà retirée, le geste ne doit jamais la recréer.
        await enqueue(.favorite(favorite, present: false), context: context)
    }

    func setNotifyOnIssues(_ enabled: Bool, matching scope: ActionScope? = nil) async {
        guard scope.map(isCurrent) != false else { return }
        guard let context = activateCurrentContext(), await loadLocal(context) else { return }
        if !hasLoaded { await synchronize(context) }
        guard isCurrent(context), hasLoaded, notifyOnIssues != enabled else { return }
        await enqueue(.notifications(enabled), context: context)
    }

    /// Uniquement après confirmation de suppression de ce compte côté serveur.
    func eraseLocalDataForDeletedAccount(ownerScopeID: String) async throws {
        if context?.owner == ownerScopeID {
            synchronization?.task.cancel(); synchronization = nil
            localLoad?.task.cancel(); localLoad = nil
            context = nil; presentedState = nil
            isLoading = false; isSynchronizing = false; presentedError = nil
        }
        states.removeValue(forKey: ownerScopeID)
        localReady.remove(ownerScopeID)
        try await store.remove(ownerScopeID: ownerScopeID)
    }

    private var ownsPresentation: Bool {
        guard let context else { return false }
        return isCurrent(context)
    }

    private func isCurrent(_ expected: Context) -> Bool {
        context == expected && sessionSnapshot() == expected.session
            && api.credentials.snapshot().sessionID == expected.credentialsID
    }

    private func activateCurrentContext() -> Context? {
        guard let session = sessionSnapshot() else {
            synchronization?.task.cancel(); synchronization = nil
            localLoad?.task.cancel(); localLoad = nil
            context = nil; presentedState = nil
            isLoading = false; isSynchronizing = false; presentedError = nil
            return nil
        }
        let credentialID = api.credentials.snapshot().sessionID
        if let context, context.session == session, context.credentialsID == credentialID { return context }
        synchronization?.task.cancel(); synchronization = nil
        localLoad?.task.cancel(); localLoad = nil
        let next = Context(session: session, credentialsID: credentialID, generation: UUID())
        context = next
        presentedState = states[next.owner]
        isLoading = false; isSynchronizing = false; presentedError = nil
        return next
    }

    private func loadLocal(_ expected: Context) async -> Bool {
        guard isCurrent(expected) else { return false }
        if localReady.contains(expected.owner) { return true }
        isLoading = true
        let item: (id: UUID, owner: String, task: Task<FavoriteAntennasLocalState?, Error>)
        if let localLoad, localLoad.owner == expected.owner { item = localLoad }
        else {
            let store = self.store
            item = (UUID(), expected.owner, Task { try await store.load(ownerScopeID: expected.owner) })
            localLoad = item
        }
        defer {
            if localLoad?.id == item.id { localLoad = nil }
            if isCurrent(expected) { isLoading = false }
        }
        do {
            let stored = try await item.task.value
            guard isCurrent(expected) else { return false }
            // Un autre appelant du même chargement a pu déjà ajouter une intention.
            if !localReady.contains(expected.owner) {
                let value = stored ?? FavoriteAntennasLocalState(ownerScopeID: expected.owner)
                try value.validate(owner: expected.owner)
                states[expected.owner] = value
                presentedState = value
                localReady.insert(expected.owner)
            }
            return true
        } catch {
            guard isCurrent(expected), !error.isCancellation else { return false }
            presentedError = String(localized: "Les favoris enregistrés sur cet appareil sont indisponibles. Réessaie avant de les modifier.")
            return false
        }
    }

    private func enqueue(_ intent: FavoriteAntennaIntent, context expected: Context) async {
        guard isCurrent(expected), var state = states[expected.owner] else { return }
        if let favorite = intent.favorite {
            guard !favorite.siteId.filter({ !$0.isWhitespace }).isEmpty, favorite.siteId.count <= 128,
                  !favorite.market.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                presentedError = String(localized: "Cette antenne ne peut pas être ajoutée aux favoris.")
                return
            }
            if !state.favorites.contains(where: { $0.id == favorite.id }) && state.favorites.count >= 500 {
                presentedError = String(localized: "Tu peux suivre au maximum 500 antennes. Retire un favori avant d’en ajouter un autre.")
                return
            }
        }
        state.enqueue(intent)
        guard state.pending.count <= 2000 else {
            presentedError = String(localized: "Synchronise les modifications en attente avant d’en ajouter d’autres.")
            return
        }
        publish(state, for: expected)
        guard await persist(state, for: expected) else { return }
        await synchronize(expected)
    }

    private func publish(_ value: FavoriteAntennasLocalState, for expected: Context) {
        guard isCurrent(expected) else { return }
        states[expected.owner] = value
        presentedState = value
    }

    private func persist(_ value: FavoriteAntennasLocalState, for expected: Context) async -> Bool {
        do {
            try await store.save(value)
            return isCurrent(expected)
        } catch {
            guard isCurrent(expected), !error.isCancellation else { return false }
            presentedError = String(localized: "Les derniers changements n’ont pas pu être enregistrés sur cet appareil. Réessaie avant de fermer l’app.")
            return false
        }
    }

    private func synchronize(_ expected: Context) async {
        guard isCurrent(expected) else { return }
        if let synchronization { await synchronization.task.value; return }
        let id = UUID()
        let worker = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runSynchronization(expected, workerID: id)
        }
        synchronization = (id, worker)
        await worker.value
        if synchronization?.id == id { synchronization = nil }
    }

    private func runSynchronization(_ expected: Context, workerID: UUID) async {
        guard isCurrent(expected) else { return }
        isLoading = true; isSynchronizing = true; presentedError = nil
        defer {
            // Libérer le slot dans le worker, avant sa complétion : une nouvelle
            // intention ne doit pas rejoindre une tâche déjà terminée sans réveil.
            if synchronization?.id == workerID { synchronization = nil }
            if isCurrent(expected) { isLoading = false; isSynchronizing = false }
        }
        do {
            let snapshot = try await request(APIEndpoint(path: Self.path,
                headers: ["Cache-Control": "no-cache"]), context: expected)
            guard isCurrent(expected), var state = states[expected.owner] else { return }
            state.receive(snapshot)
            publish(state, for: expected)
            guard await persist(state, for: expected) else { return }
            isLoading = false
            while isCurrent(expected), let intent = states[expected.owner]?.nextIntent {
                try Task.checkCancellation()
                // L'intention la plus récente, y compris celles ajoutées pendant
                // un aller-retour précédent, est durable AVANT de partir au réseau.
                guard var pending = states[expected.owner] else { return }
                pending.markAttempted(intent.requestId)
                publish(pending, for: expected)
                guard await persist(pending, for: expected) else { return }
                guard states[expected.owner]?.pending.contains(where: { $0.requestId == intent.requestId }) == true else { continue }
                let endpoint = APIEndpoint(path: Self.path, method: .patch,
                    headers: ["Content-Type": "application/json"], body: try JSONEncoder.signalQuest.encode(intent),
                    idempotencyKey: intent.requestId)
                let response: FavoriteAntennasResponse
                do { response = try await mutate(endpoint, intent: intent, context: expected) }
                catch {
                    if error is TerminalCapacityRejection, isCurrent(expected), var rejected = states[expected.owner] {
                        rejected.rejectTerminal(intent.requestId)
                        publish(rejected, for: expected)
                        guard await persist(rejected, for: expected) else { return }
                        // L'UUID refusé est terminal côté serveur. Une action
                        // inverse plus récente peut continuer ; un nouvel ajout
                        // nécessitera un nouveau geste et donc un nouvel UUID.
                        if !rejected.pending.contains(where: { $0.targetKey == intent.targetKey }) {
                            presentedError = error.localizedDescription
                        }
                        continue
                    }
                    throw error
                }
                guard response.success == true else { throw APIError.decoding("unconfirmed-favorite-mutation") }
                guard isCurrent(expected), var latest = states[expected.owner] else { return }
                latest.receive(response, acknowledging: intent.requestId)
                publish(latest, for: expected)
                guard await persist(latest, for: expected) else { return }
            }
        } catch {
            guard isCurrent(expected), !error.isCancellation else { return }
            presentedError = error.localizedDescription
            // Le snapshot et les intentions restent locaux. Un réessai réutilise
            // leurs requestId ; aucune liste vide ni restauration périmée n'est envoyée.
        }
    }

    private func request(_ endpoint: APIEndpoint, context expected: Context) async throws -> FavoriteAntennasResponse {
        guard isCurrent(expected) else { throw APIError.cancelled }
        let response = try await api.request(endpoint, as: FavoriteAntennasResponse.self,
            expectedSessionID: expected.credentialsID)
        guard isCurrent(expected) else { throw APIError.cancelled }
        try response.validate()
        return response
    }

    private func mutate(_ endpoint: APIEndpoint, intent: FavoriteAntennaIntent, context expected: Context) async throws -> FavoriteAntennasResponse {
        guard isCurrent(expected) else { throw APIError.cancelled }
        // Cette voie conserve le corps des erreurs : le marqueur de reçu terminal
        // ne doit pas être déduit d'un 413 générique de proxy. Le prochain cycle
        // recommence par GET (refresh normal), puis reprend le même requestId.
        let (data, http) = try await api.performSingleAttempt(endpoint,
            expectedCredentialSessionID: expected.credentialsID)
        guard isCurrent(expected) else { throw APIError.cancelled }
        if (200..<300).contains(http.statusCode) {
            do {
                let response = try JSONDecoder.signalQuest.decode(FavoriteAntennasResponse.self, from: data)
                try response.validate()
                return response
            } catch { throw APIError.decoding(error.localizedDescription) }
        }
        let body = try? JSONDecoder.signalQuest.decode(BackendErrorResponse.self, from: data)
        let error = APIError.http(status: http.statusCode, code: body?.code, message: body?.error ?? "",
            requestId: body?.requestId ?? http.value(forHTTPHeaderField: "X-Request-Id"),
            retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        if http.statusCode == 413, body?.code == "TOO_MANY_FAVORITES",
           case .string(let rejectedID)? = body?.details?["requestId"],
           let serverID = UUID(uuidString: rejectedID), let mutationID = UUID(uuidString: intent.requestId), serverID == mutationID,
           body?.details?["mutationOutcome"] == .string("rejected") {
            throw TerminalCapacityRejection(underlying: error)
        }
        throw error
    }
}
