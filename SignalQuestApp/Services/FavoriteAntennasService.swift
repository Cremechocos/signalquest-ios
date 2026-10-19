import Foundation
import Combine

/// Antennes suivies du compte courant : suivis de sites (`/api/me/follows`) confirmés +
/// intentions locales durables. Un suivi est propre à un opérateur. Toutes les mutations
/// réseau sont atomiques et sérialisées, jamais un PUT de liste complète. Une intention
/// n'est retirée qu'après sa confirmation serveur.
///
/// Les intentions déjà en file avant la bascule (`upsert`, `remove`, `preferences`) partent
/// encore par la passerelle `/api/android/favorite-antennas` (protocole 2), puis la liste
/// des suivis est relue : aucun geste n'écrit dans les deux modèles.
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
    /// Passerelle des anciennes intentions en file (protocole 2).
    private static let path = "/api/android/favorite-antennas"
    private static let followsPath = "/api/me/follows"

    init(api: APIClient, store: (any FavoriteAntennasStoring)? = nil,
         sessionSnapshot: @escaping () -> LocalAccountSession? = LocalAccountScope.sessionSnapshot) {
        self.api = api
        self.store = store ?? FavoriteAntennasLocalStore(environmentID: api.config.apiBaseURL.absoluteString)
        self.sessionSnapshot = sessionSnapshot
    }

    /// Sans opérateur : le site est suivi chez au moins un opérateur. Avec : chez celui-là.
    func isFavorite(siteId: String, market: String, operator operatorName: String? = nil) -> Bool {
        let target = FavoriteAntenna.key(siteId: siteId, market: market)
        return favorites.contains {
            operatorName == nil ? $0.isSameSite(key: target) : $0.isFollowed(siteKey: target, operator: operatorName)
        }
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

    func isPending(siteId: String, market: String, operator operatorName: String? = nil) -> Bool {
        guard ownsPresentation else { return false }
        let target = FavoriteAntenna.key(siteId: siteId, market: market)
        return presentedState?.pending.contains {
            $0.operation != .preferences && $0.siteKey == target
                && (operatorName == nil || $0.favorite == nil
                    || FavoriteAntenna.operatorToken($0.favorite?.operator) == FavoriteAntenna.operatorToken(operatorName))
        } == true
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
        let operatorName = favorite.operator
        guard isCurrent(context), hasLoaded else { return isFavorite(siteId: favorite.siteId, market: favorite.market, operator: operatorName) }
        // Un suivi vise un opérateur précis : sans lui (« ALL »), il n'y a rien à suivre.
        guard FavoriteAntenna.isFollowableOperator(operatorName) else {
            presentedError = String(localized: "Cette antenne ne peut pas être suivie.")
            return false
        }
        let present = !isFavorite(siteId: favorite.siteId, market: favorite.market, operator: operatorName)
        await enqueue(.follow(favorite, present: present), context: context)
        return isCurrent(context) && isFavorite(siteId: favorite.siteId, market: favorite.market, operator: operatorName)
    }

    func remove(_ favorite: FavoriteAntenna, matching scope: ActionScope? = nil) async {
        guard scope.map(isCurrent) != false else { return }
        guard let context = activateCurrentContext(), await loadLocal(context) else { return }
        if !hasLoaded { await synchronize(context) }
        guard isCurrent(context), hasLoaded else { return }
        // La suppression d'une ligne n'est pas un toggle : même si un autre appareil l'a
        // déjà retirée, le geste ne doit jamais la recréer. Une ligne sans opérateur (reste
        // de l'ancien cache) se retire comme avant, par site.
        await enqueue(FavoriteAntenna.isFollowableOperator(favorite.operator) ? .follow(favorite, present: false)
                                                                              : .favorite(favorite, present: false), context: context)
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
        if let favorite = intent.favorite, intent.operation == .upsert || intent.operation == .follow {
            guard !favorite.siteId.filter({ !$0.isWhitespace }).isEmpty, favorite.siteId.count <= 96,
                  !favorite.market.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                presentedError = String(localized: "Cette antenne ne peut pas être suivie.")
                return
            }
            if !state.favorites.contains(where: { $0.followKey == favorite.followKey }) && state.favorites.count >= 500 {
                presentedError = String(localized: "Tu peux suivre au maximum 500 antennes. Arrête d’en suivre une avant d’en ajouter une autre.")
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
            // Les intentions d'abord, puis la liste des suivis : elle reflète alors ce qui vient
            // de partir. Une intention ajoutée pendant la relecture déclenche un nouveau tour,
            // car elle ne trouverait plus de worker pour l'envoyer.
            repeat {
                guard try await sendPendingIntents(expected) else { return }
                let follows = try await requestFollows(expected)
                guard isCurrent(expected), var state = states[expected.owner] else { return }
                state.receive(follows: follows.antennas)
                publish(state, for: expected)
                guard await persist(state, for: expected) else { return }
            } while isCurrent(expected) && states[expected.owner]?.nextIntent != nil
        } catch {
            guard isCurrent(expected), !error.isCancellation else { return }
            presentedError = error.userFacingMessage
            // La liste et les intentions restent locales. Un réessai réutilise
            // leurs requestId ; aucune liste vide ni restauration périmée n'est envoyée.
        }
    }

    /// Envoie les intentions une à une. `false` : le contexte a changé ou le disque a refusé.
    private func sendPendingIntents(_ expected: Context) async throws -> Bool {
        while isCurrent(expected), let intent = states[expected.owner]?.nextIntent {
            try Task.checkCancellation()
            // L'intention la plus récente, y compris celles ajoutées pendant
            // un aller-retour précédent, est durable AVANT de partir au réseau.
            guard var pending = states[expected.owner] else { return false }
            pending.markAttempted(intent.requestId)
            publish(pending, for: expected)
            guard await persist(pending, for: expected) else { return false }
            guard states[expected.owner]?.pending.contains(where: { $0.requestId == intent.requestId }) == true else { continue }
            if intent.operation == .follow || intent.operation == .unfollow {
                do { try await sendFollow(intent, context: expected) }
                catch {
                    guard Self.isTerminalFollowRejection(error), isCurrent(expected), var rejected = states[expected.owner] else { throw error }
                    // Refus définitif (site ou opérateur inconnu, limite atteinte) : réessayer ne
                    // changerait rien, le geste est annulé et la liste relue dit la vérité.
                    rejected.rejectTerminal(intent.requestId)
                    publish(rejected, for: expected)
                    guard await persist(rejected, for: expected) else { return false }
                    if !rejected.pending.contains(where: { $0.targetKey == intent.targetKey }) {
                        presentedError = Self.followRejectionMessage(error)
                    }
                    continue
                }
                guard isCurrent(expected), var done = states[expected.owner] else { return false }
                done.acknowledge(intent.requestId)
                publish(done, for: expected)
                guard await persist(done, for: expected) else { return false }
                continue
            }
            let endpoint = APIEndpoint(path: Self.path, method: .patch,
                headers: ["Content-Type": "application/json"], body: try JSONEncoder.signalQuest.encode(intent),
                idempotencyKey: intent.requestId)
            let response: FavoriteAntennasResponse
            do { response = try await mutate(endpoint, intent: intent, context: expected) }
            catch {
                if error is TerminalCapacityRejection, isCurrent(expected), var rejected = states[expected.owner] {
                    rejected.rejectTerminal(intent.requestId)
                    publish(rejected, for: expected)
                    guard await persist(rejected, for: expected) else { return false }
                    // L'UUID refusé est terminal côté serveur. Une action
                    // inverse plus récente peut continuer ; un nouvel ajout
                    // nécessitera un nouveau geste et donc un nouvel UUID.
                    if !rejected.pending.contains(where: { $0.targetKey == intent.targetKey }) {
                        presentedError = error.userFacingMessage
                    }
                    continue
                }
                throw error
            }
            guard response.success == true else { throw APIError.decoding("unconfirmed-favorite-mutation") }
            guard isCurrent(expected), var latest = states[expected.owner] else { return false }
            latest.receive(response, acknowledging: intent.requestId)
            publish(latest, for: expected)
            guard await persist(latest, for: expected) else { return false }
        }
        return true
    }

    /// Suivre : `POST` avec l'opérateur affiché (idempotent, 200 si le suivi existe déjà).
    /// Ne plus suivre : l'id est lu par `/status`, et seul le suivi de CET opérateur part ;
    /// un suivi déjà absent est un retrait réussi.
    private func sendFollow(_ intent: FavoriteAntennaIntent, context expected: Context) async throws {
        guard isCurrent(expected) else { throw APIError.cancelled }
        guard let favorite = intent.favorite, let key = SiteFollowKey(favorite) else {
            throw APIError.http(status: 400, code: "INVALID_PARAMS", message: "", requestId: nil, retryAfter: nil)
        }
        switch intent.operation {
        case .follow:
            try await api.request(APIEndpoint(path: Self.followsPath, method: .post,
                headers: ["Content-Type": "application/json"], body: try JSONEncoder().encode(key.followBody)),
                expectedSessionID: expected.credentialsID)
        case .unfollow:
            let status = try await api.request(APIEndpoint(path: "\(Self.followsPath)/status", query: key.queryItems),
                as: SiteFollowStatus.self, expectedSessionID: expected.credentialsID)
            guard let followId = status.followId, status.following else { return }
            do {
                try await api.request(APIEndpoint(path: "\(Self.followsPath)/\(followId)", method: .delete),
                    expectedSessionID: expected.credentialsID)
            } catch APIError.http(status: 404, _, _, _, _) {}
        case .upsert, .remove, .preferences: break
        }
    }

    private static func isTerminalFollowRejection(_ error: Error) -> Bool {
        guard case APIError.http(let status, _, _, _, _) = error else { return false }
        return [400, 403, 404, 409, 413, 422].contains(status)
    }

    /// Le message du serveur est en français : les refus attendus ont leur libellé localisé.
    private static func followRejectionMessage(_ error: Error) -> String {
        guard case APIError.http(let status, let code, _, _, _) = error else { return error.userFacingMessage }
        if code == "FOLLOW_LIMIT" {
            return String(localized: "Tu peux suivre au maximum 500 antennes. Arrête d’en suivre une avant d’en ajouter une autre.")
        }
        if code == "SITE_NOT_FOUND" || code == "INVALID_PARAMS" || status == 404 {
            return String(localized: "Cette antenne ne peut pas être suivie pour cet opérateur.")
        }
        return error.userFacingMessage
    }

    private func requestFollows(_ expected: Context) async throws -> SiteFollowsResponse {
        guard isCurrent(expected) else { throw APIError.cancelled }
        let response = try await api.request(APIEndpoint(path: Self.followsPath, headers: ["Cache-Control": "no-cache"]),
            as: SiteFollowsResponse.self, expectedSessionID: expected.credentialsID)
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
