import Foundation

/// Collecte les signaux d'engagement du fil et les envoie par lots.
///
/// Porté de `FeedSignalsCollector.kt` (Android), constantes comprises : les deux
/// clients doivent nourrir le même modèle de classement, sinon « Pour toi »
/// apprend deux comportements différents selon la plateforme.
///
/// Pourquoi ça compte : le ranking `foryou` du backend se calcule à partir de
/// ces signaux. Livrer l'onglet sans les émettre donnerait un classement aveugle
/// — d'où la règle du plan, les deux ensemble ou aucun des deux.
///
/// Le tampon part toutes les 30 s, ou dès qu'il atteint `maxBuffer`, ou sur
/// demande explicite au passage en arrière-plan. Un échec réseau n'est pas
/// réessayé : un signal perdu ne vaut pas une file qui grossit indéfiniment.
actor FeedSignalsCollector {

    /// Alignées sur Android — ne pas les faire diverger.
    static let dwellThreshold: TimeInterval = 1.8
    static let flushInterval: TimeInterval = 30
    static let maxBuffer = 80

    struct Signal: Encodable, Sendable {
        let postId: String
        let signalType: String
    }

    private let api: APIClientProtocol
    private var buffer: [Signal] = []
    /// Un `view` par post et par session : sans cette mémoire, le moindre
    /// défilement en rafale enverrait des dizaines de vues pour le même post et
    /// fausserait le classement.
    private var seenViews: Set<String> = []
    private var dwellStart: [String: Date] = [:]
    private var dwellSent: Set<String> = []
    private var flushTask: Task<Void, Never>?

    init(api: APIClientProtocol) {
        self.api = api
    }

    deinit { flushTask?.cancel() }

    /// Appelé quand la liste visible change.
    func onVisibleItems(_ postIds: [String]) {
        ensureFlushLoop()
        let now = Date()
        let visible = Set(postIds)

        for id in visible {
            if seenViews.insert(id).inserted {
                buffer.append(Signal(postId: id, signalType: "view"))
            }
            if dwellStart[id] == nil { dwellStart[id] = now }
        }

        // Les posts qui viennent de SORTIR du viewport : on émet leur temps de
        // lecture s'il dépasse le seuil. Mesurer à la sortie plutôt qu'en
        // continu évite un minuteur par cellule.
        for (id, start) in dwellStart where !visible.contains(id) {
            dwellStart.removeValue(forKey: id)
            if now.timeIntervalSince(start) >= Self.dwellThreshold, dwellSent.insert(id).inserted {
                buffer.append(Signal(postId: id, signalType: "dwell"))
            }
        }

        if buffer.count >= Self.maxBuffer { flush() }
    }

    /// Signal explicite déclenché par une action (like, commentaire, partage…).
    func record(postId: String, type: String) {
        ensureFlushLoop()
        buffer.append(Signal(postId: postId, signalType: type))
        if buffer.count >= Self.maxBuffer { flush() }
    }

    /// Vidage forcé — à appeler au passage en arrière-plan, sinon le dernier
    /// lot est perdu.
    func flushNow() { flush() }

    private func ensureFlushLoop() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.flushInterval * 1_000_000_000))
                guard let self else { return }
                await self.flush()
            }
        }
    }

    private func flush() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        Task { [api] in
            struct Body: Encodable { let signals: [Signal] }
            guard let payload = try? JSONEncoder.signalQuest.encode(Body(signals: batch)) else { return }
            // Best-effort : un signal perdu dégrade marginalement le classement,
            // là où un réessai ferait grossir la file sans fin.
            try? await api.request(
                APIEndpoint(
                    path: "/api/social/feed/signals",
                    method: .post,
                    headers: ["Content-Type": "application/json"],
                    body: payload
                )
            )
        }
    }
}
