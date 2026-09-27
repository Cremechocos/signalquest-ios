/// Une requête de l'éditeur appartient à une présentation et à une révision.
/// L'invalidation est explicite : même un retour manuel A → B → A rend le GPS
/// précédent obsolète, sans ajouter de faux changement au brouillon de zone.
@MainActor
final class PrivacyZoneEditorRequest {
    private var revision: UInt64 = 0
    private var isPresented = true
    private var task: Task<Void, Never>?
    private var isDeliverySuspended = false
    private var pendingDelivery: (@MainActor () -> Void)?

    func open() {
        // Une permission système peut rendre la scène inactive puis active.
        // Réactiver une présentation encore ouverte ne remplace pas sa requête.
        guard !isPresented else { return }
        invalidate()
        isPresented = true
    }

    func close() {
        isPresented = false
        isDeliverySuspended = false
        invalidate()
    }

    /// Une écriture peut déjà être commise sur le serveur. En arrière-plan,
    /// laisser son résultat atteindre le modèle, puis différer l'effet de l'UI.
    func suspendDelivery() {
        guard isPresented else { return }
        isDeliverySuspended = true
    }

    func resumeDelivery() {
        guard isPresented else { return }
        isDeliverySuspended = false
        let delivery = pendingDelivery
        pendingDelivery = nil
        delivery?()
    }

    func invalidate() {
        revision &+= 1
        task?.cancel()
        task = nil
        pendingDelivery = nil
    }

    @discardableResult
    func start<Value: Sendable>(operation: @escaping @MainActor () async -> Value,
                               isSessionCurrent: @escaping @MainActor () -> Bool,
                               apply: @escaping @MainActor (Value) -> Void) -> Task<Void, Never>? {
        guard isPresented, !isDeliverySuspended, isSessionCurrent() else { return nil }
        invalidate()
        let expectedRevision = revision
        let pending = Task { [weak self] in
            guard let self else { return }
            defer { if self.revision == expectedRevision { self.task = nil } }
            guard !Task.isCancelled, self.isPresented, self.revision == expectedRevision,
                  isSessionCurrent() else { return }
            let value = await operation()
            // Un fournisseur peut terminer malgré cancel(). Le résultat et les
            // effets UI (erreur, position, dismiss) partagent la même barrière.
            guard !Task.isCancelled, self.isPresented, self.revision == expectedRevision,
                  isSessionCurrent() else { return }
            let delivery: @MainActor () -> Void = { [weak self] in
                guard let self, self.isPresented, self.revision == expectedRevision,
                      isSessionCurrent() else { return }
                apply(value)
            }
            if self.isDeliverySuspended { self.pendingDelivery = delivery }
            else { delivery() }
        }
        task = pending
        return pending
    }
}
