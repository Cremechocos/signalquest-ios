import Combine
import CoreLocation
import Foundation

/// Durée annoncée de chaque test (méthode révision 8), comme Android (`ExperienceEstimate`).
enum ExperienceEstimate {
    static func durationSeconds(_ test: ExperienceTestKind) -> Int {
        switch test {
        case .videoLadder:
            Int(Int64(ExperienceVideoQuality.allCases.count * ExperienceMethod.ladderSegmentsPerRung) * ExperienceMethod.segmentMs / 1_000)
        case .videoAdaptive: Int(ExperienceMethod.adaptivePlaybackMs / 1_000)
        case .webPage: 10
        case .gameAndCalls:
            Int(Int64(ExperienceMethod.gameProbeSlots) * ExperienceMethod.gameProbeIntervalMs / 1_000 + 2 * ExperienceMethod.loadSeconds)
        case .upload: 20
        }
    }

    static func durationSeconds(_ selection: Set<ExperienceTestKind>) -> Int {
        selection.reduce(0) { $0 + durationSeconds($1) }
    }
}

/// Comment la suite s'est terminée : choisit l'écran (résultat, interrompu, arrêté).
enum ExperienceFinish: Equatable, Sendable {
    case completed, userStopped, networkChanged, background, offline

    init(_ stop: ExperienceStopReason?) {
        switch stop {
        case nil: self = .completed
        case .userStopped: self = .userStopped
        case .networkChanged: self = .networkChanged
        case .background: self = .background
        case .offline: self = .offline
        }
    }
}

/// Où en est l'enregistrement du résultat (journal local puis file d'envoi).
enum ExperienceSaveState: Equatable, Sendable {
    /// Aucun test mesuré : rien n'est gardé.
    case none
    case saving
    /// Gardé et mis en file : visible par les amis une fois envoyé (visibilité par défaut).
    case queued
    /// Gardé sur ce téléphone seulement (sans compte).
    case localOnly
    /// Gardé sur ce téléphone, jamais envoyé : corps refusé avant l'envoi.
    case keptOnPhone
}

/// Le réseau du lancement, tel que l'entrée et le résultat l'affichent.
struct ExperienceNetworkDisplay: Equatable, Sendable {
    var connection: NetworkConnectionKind = .other
    var technology: CellularRadioTechnology?

    init(_ status: NetworkPathStatus) {
        connection = status.connection
        technology = status.connection == .cellular ? status.cellularTechnology : nil
    }

    init() {}

    /// Données mobiles : avertissement de consommation, jamais un blocage. Réseau inconnu = comme le Wi-Fi.
    var isMobile: Bool { connection == .cellular }

    /// `connectionType` du contrat : `cellular`, `wifi` ou `unknown`.
    var connectionType: String {
        switch connection {
        case .cellular: "cellular"
        case .wifi: "wifi"
        case .wired, .other: "unknown"
        }
    }
}

/// Un lancement terminé (complet, arrêté ou interrompu).
struct ExperienceFinished: Identifiable, Sendable {
    let id = UUID()
    let run: ExperienceRun
    let finish: ExperienceFinish
    let selected: Set<ExperienceTestKind>
    let endedAt: Date
    let network: ExperienceNetworkDisplay
    /// Âge du speedtest dont les latences sous charge ont été reprises ; nil sans reprise.
    let reusedSpeedtestAge: TimeInterval?
    var save: ExperienceSaveState

    var maxBytes: Int64 { ExperienceBudget.maxBytes(selected, recentLatencyReused: reusedSpeedtestAge != nil) }
}

/// Règles de la ville d'un résultat : jamais une position, jamais en zone privée.
enum ExperienceLocationPolicy {
    /// Zones lues : pas dans une zone active qui masque les speedtests. Zones illisibles pour un
    /// compte connecté : on ne sait pas si la position est privée, donc pas de ville. Sans compte : oui.
    static func allowsCity(zones: [PrivacyZone]?, signedIn: Bool, at coordinate: CLLocationCoordinate2D) -> Bool {
        guard let zones else { return !signedIn }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return !zones.contains { zone in
            guard zone.isActive, zone.hideSpeedtestsOnMap, let latitude = zone.latitude, let longitude = zone.longitude,
                  let radius = zone.radius else { return false }
            return here.distance(from: CLLocation(latitude: latitude, longitude: longitude)) <= max(radius, 1)
        }
    }

    /// Nom de ville du géocodeur nettoyé (contrôles, espaces, 100 caractères), nil s'il est vide.
    static func cleanCity(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? nil : String(cleaned.prefix(100))
    }
}

/// Ce que le moteur expose à l'écran ; `ExperienceEngine` en est la version réseau.
protocol ExperienceSuiteRunning: AnyObject, Sendable {
    func run(_ selected: Set<ExperienceTestKind>, onLive: @escaping @Sendable (ExperienceLive) -> Void) async -> ExperienceRun
    func requestStop(_ reason: ExperienceStopReason)
}

extension ExperienceEngine: ExperienceSuiteRunning {}

/// Conditions relues par le moteur pendant le test : premier plan, même réseau, en ligne.
final class ExperienceSessionFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var foreground = true
    private var start: NetworkConnectionKind?
    private var current: NetworkConnectionKind = .other
    private var online = true

    func set(foreground: Bool) { lock.withLock { self.foreground = foreground } }
    func set(connection: NetworkConnectionKind, online: Bool) { lock.withLock { current = connection; self.online = online } }
    func begin() { lock.withLock { start = current } }

    var conditions: ExperienceConditions {
        ExperienceConditions(
            isForeground: { [self] in lock.withLock { foreground } },
            isSameNetwork: { [self] in
                lock.withLock { start.map { !$0.isWiFiCellularBoundaryChange(to: current) } ?? true }
            },
            isOnline: { [self] in lock.withLock { online } }
        )
    }
}

/// État du mode Expérience v3. Ne lance jamais rien tout seul : un test ne part que sur l'appui
/// de l'utilisateur, et l'arrière-plan l'arrête avec la cause `background`.
@MainActor
final class ExperienceTestsModel: ObservableObject {
    enum Page: Equatable {
        case home
        case detail(ExperienceTestKind)
        case usage
    }

    /// Contexte du lancement : opérateur, marché, SSID, et la ville seulement si elle peut être gardée.
    struct LaunchContext: Sendable {
        var operatorKey: String?
        var marketCode: String?
        var ssid: String?
        var location: ExperienceSubmission.Location?
    }

    struct Environment {
        var makeEngine: @Sendable (ExperienceConditions, ExperienceUnderLoad?) -> any ExperienceSuiteRunning
        var context: (NetworkPathStatus) async -> LaunchContext
        var save: (ExperienceSubmission, ExperienceRun) async -> ExperienceTestsService.SaveOutcome
        var localItems: () async -> [ExperienceHistoryItem]
        var recentLatency: () -> ExperienceLatencyReuse.Snapshot?
        var appVersion: String?
        var now: () -> Date = Date.init
    }

    @Published private(set) var network = ExperienceNetworkDisplay()
    /// Au moins un réseau actif ; sinon un lancement s'arrête sur « Pas de connexion ».
    @Published private(set) var online = true
    @Published private(set) var selected = ExperienceBudget.defaultSelection(onMobileData: false)
    @Published private(set) var running = false
    @Published private(set) var live: ExperienceLive?
    @Published private(set) var finished: ExperienceFinished?
    @Published private(set) var page: Page = .home
    /// Lancement refusé faute de connexion : rien n'a été consommé.
    @Published private(set) var offlineAtStart = false
    @Published private(set) var lastTest: ExperienceHistoryItem?

    private let environment: Environment
    private let flags = ExperienceSessionFlags()
    private var status = NetworkPathStatus.unknown
    private var selectionTouched = false
    private var engine: (any ExperienceSuiteRunning)?
    private var stopRequested = false
    private var generation = 0
    private var pathSubscription: AnyCancellable?

    init(environment: Environment) {
        self.environment = environment
    }

    var maxMegabytes: Int { ExperienceBudget.megabytesCeil(ExperienceBudget.maxBytes(selected)) }
    var estimatedSeconds: Int { ExperienceEstimate.durationSeconds(selected) }
    /// Rang du test en cours (à partir de 1) parmi ceux lancés, dans l'ordre de la méthode.
    var liveRank: (index: Int, total: Int)? {
        guard let live else { return nil }
        let order = ExperienceMethod.order.filter(selected.contains)
        return order.firstIndex(of: live.test).map { ($0 + 1, order.count) }
    }

    // MARK: Réseau et cycle de vie

    func update(status: NetworkPathStatus, online: Bool) {
        self.status = status
        flags.set(connection: status.connection, online: online)
        network = ExperienceNetworkDisplay(status)
        self.online = online
        if !selectionTouched, !running, finished == nil {
            selected = ExperienceBudget.defaultSelection(onMobileData: network.isMobile)
        }
    }

    /// Suit le réseau actif : sélection par défaut, « Pas de connexion », arrêt sur changement.
    func bind(to path: NetworkPathMonitor) {
        update(status: path.status, online: path.isOnline)
        pathSubscription = Publishers.CombineLatest(path.$status, path.$isOnline)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status, online in
                MainActor.assumeIsolated { self?.update(status: status, online: online) }
            }
    }

    func setForeground(_ foreground: Bool) {
        flags.set(foreground: foreground)
        if !foreground { engine?.requestStop(.background) }
    }

    func refreshLastTest() async {
        lastTest = await environment.localItems().first { !$0.highlights.isEmpty }
    }

    // MARK: Sélection et lancement

    func toggle(_ test: ExperienceTestKind) {
        guard !running else { return }
        selectionTouched = true
        if selected.contains(test) { selected.remove(test) } else { selected.insert(test) }
    }

    func start() async {
        guard !running, !selected.isEmpty else { return }
        guard online else {
            offlineAtStart = true
            finished = nil
            page = .home
            return
        }
        generation &+= 1
        let current = generation
        let selection = selected
        let startStatus = status
        let display = network
        flags.begin()
        stopRequested = false
        offlineAtStart = false
        finished = nil
        page = .home
        live = nil
        running = true

        let context = await environment.context(startStatus)
        guard generation == current else { return }
        let startedAt = environment.now()
        // Reprise des latences d'un speedtest récent du MÊME réseau prouvé, sinon courte charge.
        var reuse: ExperienceUnderLoad?
        var reusedAge: TimeInterval?
        if selection.contains(.gameAndCalls), let snapshot = environment.recentLatency() {
            let path = ExperienceRecentLatency.path(
                connection: startStatus.connection, ssid: context.ssid, carrierOperatorKey: context.operatorKey
            )
            reuse = ExperienceLatencyReuse.reuse(snapshot, now: path, at: startedAt)
            if reuse != nil { reusedAge = max(0, startedAt.timeIntervalSince(snapshot.measuredAt)) }
        }
        let engine = environment.makeEngine(flags.conditions, reuse)
        self.engine = engine
        if stopRequested { engine.requestStop(.userStopped) }
        let run = await engine.run(selection) { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.running else { return }
                self.live = update
            }
        }
        if generation == current { self.engine = nil }
        await finish(run, selection: selection, display: display, context: context, reusedAge: reusedAge, generation: current)
    }

    /// « Arrêter » : les tests finis sont gardés, le test en cours est marqué interrompu.
    func stop() {
        guard running else { return }
        stopRequested = true
        engine?.requestStop(.userStopped)
    }

    /// Changement de compte : le test en cours s'arrête et rien n'est enregistré dans le suivant.
    func discard() {
        generation &+= 1
        engine?.requestStop(.userStopped)
        engine = nil
        running = false
        live = nil
        finished = nil
        offlineAtStart = false
        lastTest = nil
        page = .home
    }

    private func finish(
        _ run: ExperienceRun, selection: Set<ExperienceTestKind>, display: ExperienceNetworkDisplay,
        context: LaunchContext, reusedAge: TimeInterval?, generation current: Int
    ) async {
        guard generation == current else { return }
        let endedAt = environment.now()
        let saving = ExperienceTestKind.allCases.contains { run.tests.state(of: $0) == .measured }
        running = false
        live = nil
        finished = ExperienceFinished(
            run: run, finish: ExperienceFinish(run.stop), selected: selection, endedAt: endedAt, network: display,
            reusedSpeedtestAge: reusedAge, save: saving ? .saving : .none
        )
        page = .home
        guard saving else { return }
        let submission = ExperienceSubmission(
            clientSubmissionId: UUID(), appVersion: environment.appVersion, measuredAt: endedAt,
            durationMs: run.durationMs, bytesUsed: run.bytesUsed,
            network: .init(
                connectionType: display.connectionType, technology: display.technology?.rawValue,
                operatorKey: context.operatorKey, marketCode: context.marketCode
            ),
            location: context.location, tests: run.tests
        )
        let outcome = await environment.save(submission, run)
        let state: ExperienceSaveState = switch outcome {
        case .queued: .queued
        case .localOnly: .localOnly
        case .refused: .keptOnPhone
        case .nothingMeasured: .none
        }
        if generation == current, finished != nil { finished?.save = state }
        await refreshLastTest()
    }

    // MARK: Navigation

    func openDetail(_ test: ExperienceTestKind) { if finished != nil { page = .detail(test) } }
    func openUsage() { if finished != nil { page = .usage } }
    func back() { page = .home }

    /// « Nouveau test » : retour à l'entrée ; le résultat reste enregistré.
    func newTest() {
        finished = nil
        offlineAtStart = false
        page = .home
    }

    func dismissOffline() { offlineAtStart = false }
}

extension ExperienceTestsModel.Environment {
    /// Réseau réel : moteur sur `speed.cloudflare.com`, contexte résolu comme un speedtest, ville
    /// seulement hors zone privée, résultat gardé par `ExperienceTestsService`.
    @MainActor
    static func live(services: AppServices) -> Self {
        let speedtest = services.speedtest, location = services.location, privacy = services.privacy
        let store = services.experienceTests
        return Self(
            makeEngine: { conditions, reuse in
                ExperienceEngine(transport: URLSessionExperienceTransport(), conditions: conditions, recentLatency: reuse)
            },
            context: { status in
                // Position déjà autorisée seulement : le test ne demande jamais la permission.
                let fix = LocationFixPolicy.isAuthorized(location.authorizationStatus)
                    ? await location.currentLocation(timeoutSeconds: 4) : nil
                let coordinates = fix.map { Coordinates(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, accuracy: $0.horizontalAccuracy) }
                let resolved = await speedtest.experienceContext(pathStatus: status, location: coordinates)
                var context = ExperienceTestsModel.LaunchContext(
                    operatorKey: resolved.operatorKey, marketCode: resolved.marketCode, ssid: resolved.ssid
                )
                if let fix, let city = ExperienceLocationPolicy.cleanCity(resolved.city), let market = resolved.marketCode {
                    let signedIn = LocalAccountScope.currentOwnerScopeId.hasPrefix("user:")
                    let zones = signedIn ? try? await privacy.zones() : nil
                    if ExperienceLocationPolicy.allowsCity(zones: zones, signedIn: signedIn, at: fix.coordinate) {
                        context.location = .init(city: city, marketCode: market)
                    }
                }
                return context
            },
            save: { submission, run in await store.save(submission, run: run) },
            localItems: { await store.localItems() },
            recentLatency: { ExperienceRecentLatency.current },
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }
}
