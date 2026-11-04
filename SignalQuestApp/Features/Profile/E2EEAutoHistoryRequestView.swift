import SwiftUI
import UserNotifications

// MARK: - « C'est moi » : demande et service de HK (E2EE-AUTO §5.3)

/// Les deux côtés d'une demande d'historique. Le demandeur attend d'abord la
/// synchro du trousseau iCloud (120 s), puis ouvre sa demande et la relit
/// toutes les 10 s, 15 min au plus, tant que l'écran d'attente est affiché.
/// Un appareil qui détient HK relit les demandes ouvertes à l'ouverture de
/// l'app, au retour au premier plan et toutes les 60 s tant qu'elle est
/// visible : la notification n'en est que le réveil.
@MainActor
final class E2EEAutoHistoryRequestCoordinator: ObservableObject {
    /// HK du compte absente de cet appareil (publication `.missing`), ou, avec
    /// `activate: true`, appareil inscrit en attente (mode renforcé, §6).
    nonisolated static let historyKeyMissing = Notification.Name("SignalQuest.E2EEAuto.HistoryKeyMissing")
    /// Push `e2ee_history_request` ou `e2ee_history_request_closed` : relire.
    nonisolated static let requestsChanged = Notification.Name("SignalQuest.E2EEAuto.HistoryRequestsChanged")

    nonisolated static let syncWait: TimeInterval = 120
    nonisolated static let pollInterval: Duration = .seconds(10)
    nonisolated static let pollWindow: TimeInterval = 15 * 60
    nonisolated static let listInterval: Duration = .seconds(60)

    /// Ce que le coordinateur utilise de `E2EEAutoHistoryRequests`.
    struct Client: Sendable {
        var start: @Sendable () async -> E2EEAutoHistoryRequests.RequestOutcome
        var check: @Sendable () async -> E2EEAutoHistoryRequests.RequestOutcome
        var hasOpenRequest: @Sendable () async -> Bool
        var ownFingerprint: @Sendable () async -> [String]?
        var openRequests: @Sendable () async -> E2EEAutoHistoryRequests.Listing
        var approve: @Sendable (_ requestId: String) async -> E2EEAutoHistoryRequests.ApproveOutcome

        static func live(_ requests: E2EEAutoHistoryRequests) -> Client {
            Client(
                start: { await requests.start() },
                check: { await requests.check() },
                hasOpenRequest: { await requests.hasOpenRequest },
                ownFingerprint: { await requests.ownFingerprint() },
                openRequests: { await requests.openRequests() },
                approve: { await requests.approve(requestId: $0) }
            )
        }
    }

    struct Dependencies {
        /// Client de la session courante (nil : déconnecté ou mode automatique fermé).
        var client: () -> Client?
        var historyKeyHeld: (_ hkPubB64: String) -> Bool
        /// Publication, restauration et sauvegarde des époques (§5.1, §5.2).
        var continueWithHistoryKey: () async -> Void
        var removeDelivered: (_ requestId: String) -> Void = {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [$0])
        }
        var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var now: () -> Date = Date.init
    }

    enum RequesterPhase: Equatable {
        case waiting
        /// Plus de relecture automatique après 15 min : « Vérifier ».
        case paused
        case checking
        case received
        case closed
        case failed
    }

    struct Requester: Equatable {
        let fingerprint: [String]
        var phase: RequesterPhase
        var startedAt: Date
        /// Appareil en attente (mode renforcé, §6) : « C'est moi » l'active.
        var activating = false
    }

    enum ApprovalPhase: Equatable {
        case ready
        case acting
        case served
        case closed
        case noHistoryKey
        case unknownDevice
        case tooRecent
        case failed
    }

    struct Approval: Equatable {
        let pending: E2EEAutoHistoryRequests.Pending
        var phase: ApprovalPhase
    }

    @Published private(set) var requester: Requester?
    /// « Continuer sans l'historique » : la demande reste ouverte, l'écran revient au prochain lancement.
    @Published private(set) var requesterHidden = false
    @Published private(set) var approval: Approval?

    var presentsRequester: Bool { requester != nil && !requesterHidden }

    private let dependencies: Dependencies
    private var requesterTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var listing = false
    /// « Pas maintenant » : plus présentée avant le prochain lancement.
    private var postponedApprovals: Set<String> = []

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: Demandeur

    /// §5.3 point 2 : la synchro du trousseau d'abord, puis la demande. Une
    /// demande déjà ouverte n'attend pas.
    func historyKeyMissing(hkPubB64: String) {
        guard requesterTask == nil, requester == nil else { return }
        requesterTask = Task { [weak self] in
            await self?.runRequester(hkPubB64: hkPubB64)
            self?.requesterTask = nil
        }
    }

    /// Appareil en attente : pas d'attente de synchro, HK ne l'activerait pas.
    func activationNeeded() {
        guard requesterTask == nil, requester == nil else { return }
        requesterHidden = false
        requesterTask = Task { [weak self] in
            await self?.runActivation()
            self?.requesterTask = nil
        }
    }

    private func runActivation() async {
        guard let client = dependencies.client() else { return }
        await handle(await client.start(), client: client)
    }

    private func runRequester(hkPubB64: String) async {
        guard let client = dependencies.client() else { return }
        if await !client.hasOpenRequest() {
            let deadline = dependencies.now().addingTimeInterval(Self.syncWait)
            while dependencies.now() < deadline {
                if dependencies.historyKeyHeld(hkPubB64) {
                    await dependencies.continueWithHistoryKey()
                    return
                }
                do { try await dependencies.sleep(Self.pollInterval) } catch { return }
            }
        }
        await handle(await client.start(), client: client)
    }

    /// Relectures de l'écran d'attente : toutes les 10 s, 15 min au plus.
    func pollWhileVisible() async {
        guard let client = dependencies.client() else { return }
        while let current = requester, current.phase == .waiting, !Task.isCancelled {
            guard dependencies.now().timeIntervalSince(current.startedAt) < Self.pollWindow else {
                requester?.phase = .paused
                return
            }
            do { try await dependencies.sleep(Self.pollInterval) } catch { return }
            guard requester?.phase == .waiting else { return }
            await handle(await client.check(), client: client)
        }
    }

    /// « Vérifier » : une relecture ; toujours ouverte, le bouton reste.
    func verify() async {
        guard let client = dependencies.client(), let phase = requester?.phase,
              phase == .paused || phase == .failed else { return }
        requester?.phase = .checking
        let outcome = await client.check()
        if case .waiting = outcome {
            requester?.phase = .paused
        } else {
            await handle(outcome, client: client)
        }
    }

    /// Demande close sans HK : une nouvelle, relue de nouveau pendant 15 min.
    func requestAgain() async {
        guard let client = dependencies.client(), requester?.phase == .closed else { return }
        requester?.phase = .checking
        requester?.startedAt = dependencies.now()
        await handle(await client.start(), client: client)
    }

    func hideRequester() {
        if requester?.phase == .received { requester = nil } else { requesterHidden = true }
    }

    private func handle(_ outcome: E2EEAutoHistoryRequests.RequestOutcome, client: Client) async {
        switch outcome {
        case .present:
            // Écran affiché : il le dit ; sinon rien ne s'affiche.
            if presentsRequester { requester?.phase = .received } else { requester = nil }
            await dependencies.continueWithHistoryKey()
        case .waiting(let open):
            if requester == nil {
                requester = Requester(
                    fingerprint: await client.ownFingerprint() ?? [], phase: .waiting, startedAt: dependencies.now(),
                    activating: open.activate == true
                )
            } else {
                requester?.phase = .waiting
                requester?.activating = open.activate == true
            }
        case .closed:
            requester?.phase = .closed
        case .activated:
            // Activé sans HK : la suite habituelle la publie ou la redemande (§5.3).
            requester = nil
            requesterHidden = false
            await dependencies.continueWithHistoryKey()
        case .noHistoryKey, .notActive:
            // Pas de HK au compte : l'appareil la publie (§5.1) ; en attente : mode renforcé (§6).
            requester = nil
        case .retryLater:
            if requester?.phase == .checking { requester?.phase = .paused }
        case .logRefused, .failed:
            requester?.phase = .failed
        }
    }

    // MARK: Approbateur

    /// Retour au premier plan : les demandes ouvertes, puis toutes les 60 s ;
    /// une demande de cet appareil est relue sans rien afficher.
    func becameActive() {
        listTask?.cancel()
        listTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await self?.dependencies.sleep(Self.listInterval) } catch { return }
            }
        }
    }

    func resignedActive() {
        listTask?.cancel()
        listTask = nil
    }

    func refresh() async {
        await refreshApprovals()
        guard let client = dependencies.client(), requesterTask == nil,
              requester?.phase != .checking, requester?.phase != .received,
              await client.hasOpenRequest() else { return }
        await handle(await client.check(), client: client)
    }

    func refreshApprovals() async {
        guard approval == nil, !listing, let client = dependencies.client() else { return }
        listing = true
        defer { listing = false }
        guard case .requests(let items) = await client.openRequests(), approval == nil,
              let next = items.first(where: { !postponedApprovals.contains($0.requestId) }) else { return }
        approval = Approval(pending: next, phase: .ready)
    }

    func approve() async {
        guard let current = approval, current.phase == .ready || current.phase == .failed,
              let client = dependencies.client() else { return }
        approval?.phase = .acting
        let outcome = await client.approve(current.pending.requestId)
        guard approval?.pending.requestId == current.pending.requestId else { return }
        switch outcome {
        case .served, .alreadyServed:
            approval?.phase = .served
            dependencies.removeDelivered(current.pending.requestId)
        case .closed:
            approval?.phase = .closed
            dependencies.removeDelivered(current.pending.requestId)
        case .noHistoryKey: approval?.phase = .noHistoryKey
        case .unknownDevice: approval?.phase = .unknownDevice
        case .tooRecent: approval?.phase = .tooRecent
        case .notActive, .retryLater, .logRefused, .failed: approval?.phase = .failed
        }
    }

    /// Fermeture : une demande encore à servir revient au prochain lancement.
    func closeApproval() {
        guard let current = approval else { return }
        if current.phase == .ready || current.phase == .failed {
            postponedApprovals.insert(current.pending.requestId)
        }
        approval = nil
    }

    /// `e2ee_history_request_closed` : la notification se retire ; une demande
    /// à l'écran, servie ailleurs, se ferme ; le demandeur relit la sienne.
    func requestClosed(_ requestId: String) async {
        dependencies.removeDelivered(requestId)
        if approval?.pending.requestId == requestId, approval?.phase == .ready { approval = nil }
        await refresh()
    }

    /// Déconnexion : rien d'un compte ne reste à l'écran du suivant.
    func reset() {
        requesterTask?.cancel()
        requesterTask = nil
        listTask?.cancel()
        listTask = nil
        requester = nil
        requesterHidden = false
        approval = nil
        postponedApprovals = []
    }
}

extension E2EEAutoHistoryRequestCoordinator {
    static func live(services: AppServices) -> E2EEAutoHistoryRequestCoordinator {
        let api = services.api
        let historyKeys = E2EEAutoHistoryKeyStore()
        var cached: (namespace: String, client: Client)?
        return E2EEAutoHistoryRequestCoordinator(dependencies: Dependencies(
            client: {
                guard SQFeatures.e2eeAutoLogEnabled, let session = LocalAccountScope.sessionSnapshot() else { return nil }
                if let cached, cached.namespace == session.ownerNamespace { return cached.client }
                guard let requests = E2EEAutoHistoryRequests.live(session: session, api: api) else { return nil }
                let client = Client.live(requests)
                cached = (session.ownerNamespace, client)
                return client
            },
            historyKeyHeld: { hkPubB64 in
                guard let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId.hasPrefix("user:") else { return false }
                return (try? historyKeys.scalar(userId: String(session.ownerScopeId.dropFirst(5)), hkPubB64: hkPubB64)) != nil
            },
            continueWithHistoryKey: { await services.runE2EEAutoHistoryKeySteps() }
        ))
    }
}

// MARK: - Écran du demandeur

struct E2EEAutoHistoryRequesterView: View {
    @ObservedObject var coordinator: E2EEAutoHistoryRequestCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                Image(systemName: "key.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .accessibilityHidden(true)
                Group {
                    if coordinator.requester?.activating == true {
                        Text("Activer cet appareil")
                    } else {
                        Text("Ouvrir ton historique sur cet appareil")
                    }
                }
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                if let requester = coordinator.requester {
                    if requester.phase == .received {
                        Text("Ton historique est ouvert sur cet appareil. Tes anciens messages arrivent.")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                        GradientButton(String(localized: "OK")) { coordinator.hideRequester() }
                            .accessibilityIdentifier("e2eeAuto.historyRequest.done")
                    } else {
                        Group {
                            if requester.activating {
                                Text("Le mode renforcé protège ton compte : cet appareil ne reçoit ni n’envoie de messages chiffrés tant qu’un autre de tes appareils ne l’a pas activé. Touche « C’est moi » sur cet autre appareil : une notification vient d’y arriver.")
                            } else {
                                Text("Tes nouveaux messages arrivent déjà ici. Pour lire les plus anciens, touche « C’est moi » sur un autre de tes appareils : une notification vient d’y arriver.")
                            }
                        }
                            .font(SQType.body)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !requester.fingerprint.isEmpty {
                            E2EEAutoHistoryFingerprintCard(
                                title: String(localized: "Vérifie que l’autre appareil affiche cette empreinte"),
                                fingerprint: requester.fingerprint
                            )
                        }
                        status(requester.phase)
                        GradientButton(
                            requester.activating ? String(localized: "Plus tard") : String(localized: "Continuer sans l’historique"), style: .ghost
                        ) { coordinator.hideRequester() }
                            .accessibilityIdentifier("e2eeAuto.historyRequest.later")
                        Text("La demande reste ouverte 24 h.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth()
        }
        .background(SQColor.bg.ignoresSafeArea())
        .task(id: coordinator.requester?.phase) {
            if coordinator.requester?.phase == .waiting { await coordinator.pollWhileVisible() }
        }
    }

    @ViewBuilder
    private func status(_ phase: E2EEAutoHistoryRequestCoordinator.RequesterPhase) -> some View {
        switch phase {
        case .waiting, .checking:
            HStack(spacing: SQSpace.sm) {
                ProgressView()
                Text("En attente de confirmation…")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .accessibilityElement(children: .combine)
        case .paused, .failed:
            Group {
                if phase == .failed {
                    Text("Vérification impossible pour le moment.")
                } else {
                    Text("Toujours en attente de confirmation.")
                }
            }
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(String(localized: "Vérifier")) { Task { await coordinator.verify() } }
                .accessibilityIdentifier("e2eeAuto.historyRequest.verify")
        case .closed:
            Text("La demande a pris fin sans réponse.")
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(String(localized: "Refaire une demande")) { Task { await coordinator.requestAgain() } }
                .accessibilityIdentifier("e2eeAuto.historyRequest.again")
        case .received:
            EmptyView()
        }
    }
}

// MARK: - Écran « C'est moi » de l'approbateur

/// Tout ce qui est montré vient du journal vérifié (§5.3 point 4) : la
/// plateforme et l'heure de l'`ADD` du demandeur, son empreinte courte. Le
/// libellé servi par le serveur n'y figure pas.
struct E2EEAutoHistoryApprovalView: View {
    @ObservedObject var coordinator: E2EEAutoHistoryRequestCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                Image(systemName: "key.fill")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(SQColor.brandRed)
                    .accessibilityHidden(true)
                Group {
                    if coordinator.approval?.pending.activate == true {
                        Text("Activer un nouvel appareil ?")
                    } else {
                        Text("Ouvrir l’historique sur un nouvel appareil ?")
                    }
                }
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                if let approval = coordinator.approval {
                    content(approval)
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.vertical, SQSpace.lg)
            .sqReadableWidth()
        }
        .background(SQColor.bg.ignoresSafeArea())
    }

    @ViewBuilder
    private func content(_ approval: E2EEAutoHistoryRequestCoordinator.Approval) -> some View {
        if let result = Self.resultText(approval.phase, activate: approval.pending.activate) {
            Text(result)
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(String(localized: "OK")) { coordinator.closeApproval() }
                .accessibilityIdentifier("e2eeAuto.historyApproval.done")
        } else {
            Group {
                if approval.pending.activate {
                    Text("Un appareil attend d’être activé sur ton compte, en mode renforcé. Une fois activé, il lira et enverra tes messages chiffrés. Touche « C’est moi » seulement si c’est le tien et que son écran affiche la même empreinte.")
                } else {
                    Text("Un appareil de ton compte demande l’historique de tes messages chiffrés. Touche « C’est moi » seulement si c’est le tien et que son écran affiche la même empreinte.")
                }
            }
                .font(SQType.body)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text(Self.platformName(approval.pending.platform))
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                Text("Ajouté le \(Self.date(approval.pending.addedAtMs))")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            E2EEAutoHistoryFingerprintCard(title: String(localized: "Empreinte"), fingerprint: approval.pending.fingerprint)
            if approval.phase == .failed {
                Label(String(localized: "Impossible pour le moment. Réessaie dans un instant."), systemImage: "exclamationmark.triangle.fill")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GradientButton(String(localized: "C’est moi"), isBusy: approval.phase == .acting) {
                Task { await coordinator.approve() }
            }
            .disabled(approval.phase == .acting)
            .accessibilityIdentifier("e2eeAuto.historyApproval.itsMe")
            GradientButton(String(localized: "Pas maintenant"), style: .ghost) { coordinator.closeApproval() }
                .disabled(approval.phase == .acting)
                .accessibilityIdentifier("e2eeAuto.historyApproval.later")
            Text("Si ce n’est pas toi, retire cet appareil dans Réglages > Appareils.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func resultText(_ phase: E2EEAutoHistoryRequestCoordinator.ApprovalPhase, activate: Bool = false) -> String? {
        switch phase {
        case .ready, .acting, .failed: return nil
        case .served:
            return activate
                ? String(localized: "C’est fait : l’autre appareil est activé.")
                : String(localized: "C’est fait : l’historique s’ouvre sur l’autre appareil.")
        case .tooRecent:
            return String(localized: "Cet appareil a été ajouté il y a moins de 24 h : confirme depuis un appareil plus ancien.")
        case .closed: return String(localized: "Cette demande n’est plus ouverte.")
        case .noHistoryKey: return String(localized: "Cet appareil n’a pas encore l’historique. Confirme depuis un autre de tes appareils.")
        case .unknownDevice: return String(localized: "Cet appareil n’est plus sur ton compte.")
        }
    }

    static func platformName(_ platform: E2EEAutoLog.Platform) -> String {
        switch platform {
        case .android: return "Android"
        case .web: return String(localized: "Navigateur web")
        case .ios: return String(localized: "iPhone ou iPad")
        }
    }

    private static func date(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1_000).formatted(date: .abbreviated, time: .shortened)
    }
}

/// Empreinte courte (4 groupes de 5 chiffres), lue groupe par groupe.
struct E2EEAutoHistoryFingerprintCard: View {
    let title: String
    let fingerprint: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title)
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(fingerprint.joined(separator: " "))
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .textSelection(.enabled)
                .accessibilityLabel(String(localized: "Empreinte \(fingerprint.joined(separator: ", "))"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.lg)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }
}

/// Banc visuel (simulateur Debug) : `--qa-auto-history-request` (demandeur),
/// `--qa-auto-history-approval` (« C'est moi ») ; avec `--qa-auto-history-activation`,
/// la variante du mode renforcé (§6).
struct E2EEAutoHistoryRequestQAScreen: View {
    #if DEBUG && targetEnvironment(simulator)
    nonisolated private static let activation = AppEnvironment.hasQAFlag("auto-history-activation")
    @StateObject private var coordinator = E2EEAutoHistoryRequestCoordinator(dependencies: .init(
        client: {
            .init(
                start: { .waiting(.init(requestId: "hreq_qa_000000000000001", expiresAtMs: Int64.max, activate: Self.activation ? true : nil)) },
                check: { .waiting(.init(requestId: "hreq_qa_000000000000001", expiresAtMs: Int64.max, activate: Self.activation ? true : nil)) },
                hasOpenRequest: { true },
                ownFingerprint: { ["48213", "09177", "66402", "31958"] },
                openRequests: {
                    .requests([.init(
                        requestId: "hreq_qa_000000000000002", deviceId: "android_device_qa_0000001", platform: .android,
                        addedAtMs: 1_793_000_000_000, fingerprint: ["48213", "09177", "66402", "31958"], expiresAtMs: Int64.max,
                        activate: Self.activation
                    )])
                },
                approve: { _ in .served }
            )
        },
        historyKeyHeld: { _ in false },
        continueWithHistoryKey: {},
        removeDelivered: { _ in },
        sleep: { try await Task.sleep(for: $0 == E2EEAutoHistoryRequestCoordinator.pollInterval ? .seconds(3_600) : $0) }
    ))
    let approval: Bool
    #else
    let approval: Bool
    #endif

    var body: some View {
        #if DEBUG && targetEnvironment(simulator)
        Group {
            if approval {
                E2EEAutoHistoryApprovalView(coordinator: coordinator)
            } else {
                E2EEAutoHistoryRequesterView(coordinator: coordinator)
            }
        }
        .task {
            if approval { await coordinator.refreshApprovals() } else { await coordinator.refresh() }
        }
        #else
        EmptyView()
        #endif
    }
}
