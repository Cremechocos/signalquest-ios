import SwiftUI
import CoreLocation
import Combine
import os

/// Ce qu'un Drive Test enregistre. Choix persisté localement (`@AppStorage`),
/// défaut « Les deux » → la couverture est enregistrée par défaut (le choix d'un
/// mode couverture vaut consentement de publication ; jamais sous VPN).
enum DriveTestMode: String, CaseIterable, Identifiable {
    case coverage, speedtest, both
    var id: String { rawValue }
    static let storageKey = "drivetest_mode"
    static var current: DriveTestMode { DriveTestMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .both }
    var short: String {
        switch self {
        case .coverage: return "Couverture"
        case .speedtest: return "Speedtest"
        case .both: return "Les deux"
        }
    }
    var recordsCoverage: Bool { self != .speedtest }
    var runsSpeedtest: Bool { self != .coverage }
}

/// Point de couverture affiché EN TEMPS RÉEL sur la mini-carte Drive Test
/// (coordonnée + génération, coloré comme la carte principale).
struct DriveCoveragePoint: Equatable {
    let coordinate: CLLocationCoordinate2D
    let generation: String?

    static func == (lhs: DriveCoveragePoint, rhs: DriveCoveragePoint) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.generation == rhs.generation
    }
}

/// Point speedtest géolocalisé affiché sur la mini-carte Drive Test : coloré par
/// débit, tappable → ouvre la feuille de détails. Porte le résultat complet.
struct DriveSpeedtestPoint: Identifiable, Equatable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let result: SpeedtestRunResult

    static func == (lhs: DriveSpeedtestPoint, rhs: DriveSpeedtestPoint) -> Bool {
        lhs.id == rhs.id &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// Mode Drive Test : enchaîne des speedtests en continu (rafale illimitée) tout en
/// suivant la position, en affichant les antennes proches sur une carte et en
/// indiquant si l'on est « dans le secteur » de l'antenne la plus proche. Réutilise
/// le moteur speedtest, le suivi de localisation continu et la géométrie de secteur.
@MainActor
final class DriveTestViewModel: ObservableObject {
    private static let log = Logger(subsystem: "fr.signalquest.ios", category: "DriveTest")
    // Session speedtest continue.
    @Published private(set) var isRunning = false
    @Published private(set) var testCount = 0
    @Published private(set) var summary: SpeedtestBurstSummary?
    @Published private(set) var lastResult: SpeedtestRunResult?
    @Published private(set) var statusLabel = "Prêt"
    @Published private(set) var errorMessage: String?
    /// Vrai quand la localisation est refusée/restreinte : le Drive Test ne peut
    /// enregistrer ni trace ni couverture. La vue propose alors les Réglages plutôt
    /// que de lancer une session muette qui n'enregistre rien (UXP-03/F-05).
    @Published private(set) var locationDenied = false

    // Carte / secteur.
    @Published private(set) var antennas: [AntennaSite] = []
    @Published private(set) var trace: [CLLocationCoordinate2D] = []
    @Published private(set) var userLocation: CLLocationCoordinate2D?
    @Published private(set) var nearestSite: AntennaSite?
    @Published private(set) var nearestDistanceMeters: Double?
    @Published private(set) var inSector = false
    @Published private(set) var sectorOffsetDegrees: Double?

    // Progression live du test en cours (readout du panneau + Live Activity).
    @Published private(set) var liveMbps: Double = 0
    @Published private(set) var livePhase: SpeedtestPhase = .idle
    // Valeurs du test courant : se remplissent en live, RESTENT affichées après le
    // test, et ne se réinitialisent qu'au démarrage du test suivant.
    @Published private(set) var livePing: Double = 0
    @Published private(set) var liveDownload: Double = 0
    @Published private(set) var liveUpload: Double = 0

    /// Libellé de l'opérateur de la SIM dont on affiche les antennes (ex « Orange »),
    /// ou nil si indéterminable (WiFi / VPN) → on retombe sur tous les opérateurs.
    @Published private(set) var simOperatorLabel: String?

    /// VPN actif : sous tunnel, l'opérateur réel n'est pas détectable et les tests
    /// ne sont pas publiés sur la carte. Pilote la bannière d'avertissement.
    @Published private(set) var isVPNActive = false

    /// Octets consommés par les speedtests de la session. Affiché en direct : un
    /// Drive Test peut engloutir plusieurs gigaoctets, et l'utilisateur ne pouvait
    /// pas le savoir avant de recevoir sa facture.
    @Published private(set) var sessionBytes: Int = 0
    /// Session arrêtée parce que le plafond de données a été atteint — état
    /// distinct d'un arrêt manuel, pour l'expliquer plutôt que de s'interrompre.
    @Published private(set) var stoppedByDataCap = false
    /// Distance parcourue depuis le début (mètres), calculée sur la trace réelle.
    @Published private(set) var distanceMeters: Double = 0

    /// Bilan de la dernière session, affiché à l'arrêt. Sans lui, l'écran
    /// retombait sur le sélecteur de mode et tout le trajet disparaissait.
    struct SessionRecap: Equatable {
        let summaryLine: String
        /// Réserve éventuelle : troncature, plafond atteint, marché non identifié.
        let caveat: String?
    }

    @Published private(set) var lastSessionRecap: SessionRecap?

    /// Opérateurs du marché courant : alimente la palette de couleurs des marqueurs.
    @Published private(set) var availableOperators: [MarketRegistryOperator] = []

    var nearestSiteId: String? { nearestSite?.id }
    /// Marché / opérateur pour la feuille de détails antenne (opérateur de la SIM si résolu).
    var antennaDetailMarket: String { resolvedSim?.market ?? MapMarketStore.lastMarket() ?? MapMarketStore.localeMarketCode() }
    var antennaDetailOperator: String { displayedOperatorKey ?? "ALL" }

    /// Opérateur TOUJOURS automatique (SIM / IP-ASN / marché GPS). Il a existé un
    /// override manuel : il écrivait une propriété que ni cette ligne ni
    /// `refreshAntennasIfNeeded` ne lisaient — choisir un opérateur ne faisait
    /// donc rien du tout. Retiré plutôt que rebranché : la couverture doit être
    /// taguée avec l'opérateur RÉEL, pas avec celui qu'on aurait choisi.
    var displayedOperatorKey: String? { resolvedSim?.operatorKey }

    /// Libellé court de l'opérateur affiché, ou nil si indéterminé (→ feedback UI).
    var displayedOperatorLabel: String? {
        guard let key = displayedOperatorKey else { return nil }
        return marketEntry?.operatorEntry(forKey: key)?.shortLabel ?? simOperatorLabel ?? key
    }

    /// Couleur d'un opérateur (registre, repli sur la palette SQBrand).
    func operatorColor(_ key: String?) -> Color {
        marketEntry?.operatorColor(forKey: key) ?? SQBrand.operatorColor(key)
    }

    /// Préfixe « Opérateur · » pour les libellés de la Live Activity (F2) — vide
    /// tant que l'opérateur n'est pas résolu (WiFi/VPN au démarrage).
    private var liveOperatorPrefix: String {
        displayedOperatorLabel.map { "\($0) · " } ?? ""
    }

    private let services: AppServices
    private var sessionTask: Task<Void, Never>?
    private var accumulator = ContinuousSessionAccumulator()

    // MARK: Cadence et plafond de données

    /// Distance par défaut entre deux speedtests. La boucle enchaînait auparavant
    /// les tests avec 800 ms de pause : les mesures s'entassaient là où l'on roule
    /// lentement, et la consommation était sans limite. Espacer par la DISTANCE
    /// répartit les mesures dans l'espace, ce qui est aussi le bon geste
    /// scientifique pour une carte de couverture.
    static let defaultTestIntervalMeters: Double = 500
    /// Plafond par défaut : 5 Go. Au-delà, la session s'arrête proprement et le
    /// dit — jamais en silence.
    static let defaultDataCapMegabytes = 5_120

    private var testIntervalMeters: Double {
        let stored = UserDefaults.standard.object(forKey: "speedtest_drive_interval_meters") as? Int
        return Double(min(max(stored ?? Int(Self.defaultTestIntervalMeters), 100), 5_000))
    }

    /// `nil` = illimité (valeur 0 dans les réglages).
    private var dataCapBytes: Int? {
        let stored = UserDefaults.standard.object(forKey: "speedtest_drive_data_cap_mb") as? Int
            ?? Self.defaultDataCapMegabytes
        return stored <= 0 ? nil : stored * 1_000_000
    }

    /// Position du dernier speedtest — origine de la distance à parcourir avant le
    /// suivant.
    private var lastTestCoordinate: CLLocationCoordinate2D?
    /// L'utilisateur a demandé un test tout de suite (arrêt volontaire, bouchon) :
    /// sans cette échappatoire, une cadence à la distance ne teste jamais à l'arrêt.
    private var manualTestRequested = false
    private var lastFetchCenter: CLLocationCoordinate2D?
    private var lastFetchOperator: String?
    private var antennaFetchInFlight = false
    private let traceCap = 600
    /// Points de couverture iOS le long du trajet (F1) : génération + débit/latence
    /// aux points testés. PAS de signal radio (iOS ne l'expose pas).
    private var coveragePoints: [CoveragePointUpload] = []
    private var lastCoveragePointCoord: CLLocationCoordinate2D?
    /// Distance entre deux points de couverture. Alignée sur la grille de
    /// publication (~50 m) : capturer plus fin produisait cinq points par carreau,
    /// donc cinq fois le stockage et la charge utile pour zéro résolution en plus.
    /// À 130 km/h cela fait un point toutes les 1,4 s — largement assez pour
    /// attraper une bascule 5G→4G ou une entrée en zone blanche.
    private let coverageCaptureIntervalMeters: Double = 50
    /// 20 000 points × 50 m ≈ 1000 km, très en dessous du `MAX_POINTS = 50 000`
    /// du backend. L'ancien plafond de 3000 était atteint après 60 km, et le
    /// dépassement se réglait en SUPPRIMANT le début du trajet, sans rien dire.
    private let coveragePointCap = 20_000
    /// Vrai dès qu'un point a été perdu par dépassement du plafond : la session
    /// n'est plus complète et l'utilisateur doit l'apprendre.
    @Published private(set) var coverageTruncated = false
    /// Identité locale stable de la session, conservée dans le corps et dans
    /// l'Idempotency-Key pendant tous les rejeux réseau.
    private var coverageSessionId: UUID?
    private var coverageStartedAtMs: Int?
    /// Choix de visibilité figé au démarrage, puis persisté avec le brouillon.
    private var coverageShowOnMap = false
    /// Dès qu'un VPN est vu pendant la session, la contribution est supprimée de
    /// la file locale et ne sera jamais rejouée après un redémarrage.
    private var coverageUploadSuppressed = false
    /// Mode figé au démarrage de la session (couverture / speedtest / les deux).
    private var sessionMode: DriveTestMode = .both
    /// Nombre de points de couverture capturés (affiché en mode couverture).
    @Published private(set) var coveragePointCount = 0
    /// Dernière persistance du brouillon de couverture (debounce — PERF-DT-01).
    private var lastCoveragePersistAt: Date = .distantPast
    /// Points de couverture pour l'affichage TEMPS RÉEL sur la carte (par génération).
    @Published private(set) var coverageTrail: [DriveCoveragePoint] = []
    /// Points speedtest géolocalisés (carte Drive Test) — colorés par débit, tappables.
    @Published private(set) var speedtestTrail: [DriveSpeedtestPoint] = []
    /// Session en pause car le téléphone est en WiFi (réseau non représentatif du
    /// mobile) : reprise automatique au retour en cellulaire / zone réelle.
    @Published private(set) var isPausedForWiFi = false
    /// Opérateur de la SIM active résolu une fois (MCC→marché, operatorKey via IP/ASN
    /// ou MNC). Drive test = cellulaire : on n'affiche que SES antennes.
    private var resolvedSim: (market: String, operatorKey: String)?
    private var simResolveInFlight = false
    /// Back-off de la résolution d'opérateur : instant du dernier échec et nombre
    /// d'échecs consécutifs. Sans cela, un marché non résolvable relançait une
    /// requête réseau à CHAQUE point GPS.
    private var lastSimResolveFailureAt: Date?
    private var simResolveFailures = 0
    /// Vrai quand la résolution a échoué assez de fois pour qu'on cesse de dire
    /// « détection en cours » : à un moment, il faut annoncer le résultat.
    var operatorDetectionGaveUp: Bool { resolvedSim == nil && simResolveFailures >= 2 }
    /// Dernier PLMN (MCC/MNC) vu sur la SIM : un changement en cours de session
    /// (échange SIM/eSIM) re-résout l'opérateur SANS arrêter la session (point 5).
    private var lastSimPLMN: (mcc: Int?, mnc: Int?)?
    /// Abonnement au type de connexion (pause auto en WiFi / reprise en cellulaire).
    private var pathCancellable: AnyCancellable?
    /// Entrée de marché courante (couleurs + libellés d'opérateur du sélecteur).
    private var marketEntry: MarketRegistryEntry?
    // Mêmes mécanismes que le speedtest normal : Live Activity + assertion
    // d'arrière-plan pour enchaîner les tests écran verrouillé.
    private let liveActivity = SpeedtestLiveActivityController()
    private var background = BackgroundTaskScope()

    init(services: AppServices) { self.services = services }

    func onAppear() {
        isVPNActive = VPNDetector.isActive()
        // Reprend aussi une session interrompue par un kill précédent. La file
        // reste intacte si le réseau ou l'authentification ne sont pas disponibles.
        Task { await services.sessions.retryPendingCoverageSessions() }
        // Pré-remplit le sélecteur d'opérateur sans attendre une position.
        Task { await prepareOperatorSelector() }
        services.location.onLocationUpdate = { [weak self] location in
            self?.apply(coordinate: location.coordinate)
        }
        // Position initiale (sans déclencher de prompt si pas déjà autorisé).
        guard services.location.authorizationStatus == .authorizedWhenInUse
            || services.location.authorizationStatus == .authorizedAlways else { return }
        if let cached = services.location.lastLocation { apply(coordinate: cached.coordinate) }
        Task {
            if let loc = await services.location.currentLocation(timeoutSeconds: 5) {
                apply(coordinate: loc.coordinate)
            }
        }
    }

    /// SwiftUI émet `onDisappear` DANS LES DEUX CAS : quand on quitte réellement
    /// l'écran (retour arrière) et quand on change simplement d'onglet. Arrêter
    /// sans distinguer revenait à terminer un trajet parce que l'utilisateur
    /// était allé voir où il en était sur la carte — vérifié par
    /// `DriveTestSessionLifecycleQATests.testSessionSurvivesTabSwitch`.
    ///
    /// `isLeavingScreen` tranche : faux = l'écran est seulement masqué derrière
    /// un autre onglet, la session continue et le callback de position qui
    /// l'alimente reste branché.
    func onDisappear(isLeavingScreen: Bool) {
        guard isLeavingScreen else { return }
        stop()
        services.location.onLocationUpdate = nil
    }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        // Un Drive Test sans position n'enregistre ni trace ni couverture : plutôt
        // que lancer une session muette (statut « Enregistrement… » puis « 0 point »),
        // on explique et on renvoie vers les Réglages si la localisation est refusée.
        switch services.location.authorizationStatus {
        case .denied, .restricted:
            locationDenied = true
            statusLabel = "Localisation désactivée"
            errorMessage = "Le Drive Test a besoin de ta position pour tracer le trajet et la couverture. Active la localisation dans les Réglages, puis relance."
            return
        default:
            locationDenied = false
        }
        accumulator = ContinuousSessionAccumulator()
        summary = nil
        testCount = 0
        // Le compteur de données est propre à une session : le remettre à zéro ici
        // et nulle part ailleurs, pour que le plafond porte bien sur CE trajet.
        SpeedtestDataMeter.shared.reset()
        sessionBytes = 0
        stoppedByDataCap = false
        coverageTruncated = false
        lastSessionRecap = nil
        distanceMeters = 0
        lastTestCoordinate = nil
        manualTestRequested = false
        coveragePoints.removeAll()
        coverageTrail.removeAll()
        speedtestTrail.removeAll()
        lastCoveragePointCoord = nil
        coveragePointCount = 0
        sessionMode = DriveTestMode.current
        coverageSessionId = nil
        coverageStartedAtMs = nil
        coverageShowOnMap = coveragePublishToMap()
        coverageUploadSuppressed = VPNDetector.isActive()
        if sessionMode.recordsCoverage {
            let sessionId = UUID()
            let startedAt = Self.nowMs()
            coverageSessionId = sessionId
            coverageStartedAtMs = startedAt
            // Sous VPN, la trace peut rester visible pendant le trajet mais elle
            // n'est jamais écrite dans une file qui pourrait être rejouée plus tard.
            if !coverageUploadSuppressed, let draft = makeCoverageSessionUpload(endTime: startedAt) {
                do {
                    try services.sessions.persistCoverageDraft(draft)
                } catch {
                    coverageSessionId = nil
                    coverageStartedAtMs = nil
                    statusLabel = "Stockage local indisponible"
                    errorMessage = "Impossible de sécuriser ce Drive Test sur l’appareil. Réessaie avant de partir."
                    Self.log.error("création brouillon couverture ÉCHEC : \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
        }
        liveMbps = 0
        livePhase = .idle
        isRunning = true
        // En WiFi (réseau non représentatif du mobile), la session démarre EN PAUSE et
        // reprend automatiquement au retour en cellulaire.
        isPausedForWiFi = Self.isWiFiConnection(services.networkPath.status.connection)
        statusLabel = isPausedForWiFi
            ? "En pause — WiFi détecté"
            : (sessionMode.runsSpeedtest ? "Démarrage…" : "Enregistrement couverture…")
        services.location.startTracking()
        UIApplication.shared.isIdleTimerDisabled = true
        // Assertion d'arrière-plan ; la boucle speedtest + Live Activity ne tournent
        // qu'en mode « speedtest » ou « les deux » (mode « couverture seule » = suivi
        // position + génération, sans test de débit).
        background.begin(name: "drivetest")
        if sessionMode.runsSpeedtest {
            liveActivity.start(serverName: displayedOperatorLabel ?? "SignalQuest", network: services.networkPath.status.displayName, runIndex: 1, runTotal: 0)
            if !isPausedForWiFi { sessionTask = Task { await runLoop() } }
        }
        observeConnectionForPause()
    }

    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        pathCancellable?.cancel()
        pathCancellable = nil
        if isRunning {
            services.location.stopTracking()
            UIApplication.shared.isIdleTimerDisabled = false
            liveActivity.cancel()
            background.end()
            statusLabel = "Arrêté"
            // Composé AVANT l'upload : `uploadCoverageSessionIfNeeded` vide les
            // points et peut écraser `statusLabel`.
            lastSessionRecap = makeSessionRecap()
            uploadCoverageSessionIfNeeded()
            // Draine la file des speedtests en attente (sinon rejeu uniquement à la
            // prochaine visite de l'onglet Speed) : un échec réseau/auth n'est plus perdu.
            Task { await services.speedtest.retryPendingSaves() }
        }
        isRunning = false
        isPausedForWiFi = false
        liveMbps = 0
        livePhase = .idle
    }

    // MARK: Pause auto en WiFi / reprise en cellulaire

    private static func isWiFiConnection(_ connection: NetworkConnectionKind) -> Bool {
        connection == .wifi || connection == .wired
    }

    /// Observe le type de connexion : en WiFi, la session se met en pause (réseau non
    /// représentatif du mobile) ; elle reprend dès le retour en cellulaire / zone réelle.
    /// Une vraie zone blanche (`.other`) n'est PAS une pause : « Aucun signal » est une
    /// mesure de couverture valide.
    private func observeConnectionForPause() {
        pathCancellable = services.networkPath.$status
            .map(\.connection)
            .removeDuplicates()
            .sink { [weak self] connection in
                Task { @MainActor in self?.handleConnectionChange(connection) }
            }
    }

    private func handleConnectionChange(_ connection: NetworkConnectionKind) {
        guard isRunning else { return }
        let onWiFi = Self.isWiFiConnection(connection)
        if onWiFi && !isPausedForWiFi {
            pauseForWiFi()
        } else if !onWiFi && isPausedForWiFi {
            resumeAfterWiFi()
        }
    }

    private func pauseForWiFi() {
        isPausedForWiFi = true
        sessionTask?.cancel()
        sessionTask = nil
        liveMbps = 0
        livePhase = .idle
        statusLabel = "En pause — WiFi détecté"
        // La Live Activity restait figée sur le dernier test : écran verrouillé,
        // rien ne distinguait une session en pause d'une session qui mesure.
        if sessionMode.runsSpeedtest {
            liveActivity.update(
                phaseLabel: String(localized: "En pause — WiFi détecté"),
                downloadMbps: liveDownload,
                uploadMbps: liveUpload,
                pingMs: livePing,
                progress: 0,
                runIndex: testCount,
                runTotal: 0
            )
        }
    }

    private func resumeAfterWiFi() {
        isPausedForWiFi = false
        statusLabel = sessionMode.runsSpeedtest ? "Reprise…" : "Enregistrement couverture…"
        if sessionMode.runsSpeedtest && sessionTask == nil {
            sessionTask = Task { await runLoop() }
        }
    }

    // MARK: Position / antennes / secteur

    private func apply(coordinate: CLLocationCoordinate2D) {
        userLocation = coordinate
        appendTrace(coordinate)
        captureCoveragePoint(coordinate)
        recomputeNearest()
        writeNetworkGlance()
        Task {
            await detectSimChangeIfNeeded()
            await refreshAntennasIfNeeded(around: coordinate)
        }
    }

    private func appendTrace(_ coordinate: CLLocationCoordinate2D) {
        if let last = trace.last {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            if moved < 8 { return } // ignore le bruit GPS sous 8 m
            // Distance cumulée sur la trace RÉELLE (points retenus, donc déjà
            // débruités) : ni le trajet à vol d'oiseau, ni la somme du bruit GPS.
            if isRunning { distanceMeters += moved }
        }
        trace.append(coordinate)
        if trace.count > traceCap { trace.removeFirst(trace.count - traceCap) }
    }

    // MARK: Couverture iOS (F1)

    private static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// Génération courante (CoreTelephony) ou "Aucun" si pas de cellulaire (zone sans réseau).
    private var currentGeneration: String {
        services.networkPath.status.cellularTechnology?.rawValue ?? "Aucun"
    }

    private func appendCoveragePoint(_ point: CoveragePointUpload, at coordinate: CLLocationCoordinate2D) {
        lastCoveragePointCoord = coordinate
        coveragePoints.append(point)
        coverageTrail.append(DriveCoveragePoint(coordinate: coordinate, generation: point.technology))
        if coveragePoints.count > coveragePointCap {
            coveragePoints.removeFirst(coveragePoints.count - coveragePointCap)
            coverageTrail.removeFirst(coverageTrail.count - coveragePointCap)
            // Recaler le début de session sur le premier point RESTANT : sinon
            // startTime restait celui du départ alors que la portion initiale a été
            // tronquée, produisant un horodatage incohérent (TEL-15).
            if let firstKept = coveragePoints.first?.timestamp {
                coverageStartedAtMs = firstKept
            }
            // ... et le DIRE. Le recalage rendait la troncature indétectable : sur
            // un trajet de 1200 km, les 200 premiers disparaissaient sans qu'aucun
            // horodatage ni compteur ne le trahisse.
            if !coverageTruncated {
                coverageTruncated = true
                errorMessage = String(
                    localized: "Trajet très long : les portions les plus anciennes ne seront pas envoyées. Arrête et relance une session pour repartir d'un enregistrement complet."
                )
                Self.log.notice("couverture tronquée : plafond de \(self.coveragePointCap) points atteint")
            }
        } else if !coverageTruncated, coveragePoints.count >= Int(Double(coveragePointCap) * 0.9) {
            // Prévenir AVANT de perdre quoi que ce soit laisse une chance d'agir.
            statusLabel = String(localized: "Bientôt au maximum de points enregistrables")
        }
        coveragePointCount = coveragePoints.count
        persistCoverageSnapshot()
    }

    /// Mémorise un point speedtest géolocalisé pour la carte (borné).
    private func appendSpeedtestPoint(_ result: SpeedtestRunResult, at coordinate: CLLocationCoordinate2D) {
        speedtestTrail.append(DriveSpeedtestPoint(id: result.id, coordinate: coordinate, result: result))
        if speedtestTrail.count > 500 { speedtestTrail.removeFirst(speedtestTrail.count - 500) }
    }

    /// Capture un point « génération seule » une fois la distance de capture
    /// parcourue — voir `coverageCaptureIntervalMeters` pour le choix du pas.
    private func captureCoveragePoint(_ coordinate: CLLocationCoordinate2D) {
        guard sessionMode.recordsCoverage, !isPausedForWiFi else { return }
        if let last = lastCoveragePointCoord {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            if moved < coverageCaptureIntervalMeters { return }
        }
        appendCoveragePoint(
            CoveragePointUpload(latitude: coordinate.latitude, longitude: coordinate.longitude, timestamp: Self.nowMs(), technology: currentGeneration),
            at: coordinate
        )
    }

    /// Point de couverture PORTANT le débit/latence mesurés, à la position du test.
    private func captureMeasuredCoveragePoint(_ result: SpeedtestRunResult) {
        guard sessionMode.recordsCoverage, !isPausedForWiFi,
              let coordinate = services.location.lastLocation?.coordinate ?? userLocation else { return }
        appendCoveragePoint(
            CoveragePointUpload(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                timestamp: Self.nowMs(),
                technology: currentGeneration,
                downloadMbps: result.downloadAverageMbps,
                uploadMbps: result.uploadAverageMbps,
                pingMs: result.pingMinMs ?? result.pingMs
            ),
            at: coordinate
        )
    }

    /// Construit l'instantané complet de la session avec l'identifiant et le choix
    /// `showOnMap` figés au démarrage.
    private func makeCoverageSessionUpload(endTime: Int? = nil) -> CoverageSessionUpload? {
        guard let sessionId = coverageSessionId, let startedAt = coverageStartedAtMs else { return nil }
        let plmn = services.networkPath.simPLMN()
        let market = resolvedSim?.market
            ?? marketEntry.map { $0.marketCode.isEmpty ? $0.code : $0.marketCode }
        return CoverageSessionUpload(
            sessionId: sessionId,
            startTime: startedAt,
            endTime: max(startedAt, endTime ?? coveragePoints.last?.timestamp ?? Self.nowMs()),
            mcc: plmn.mcc,
            mnc: plmn.mnc,
            operatorKey: displayedOperatorKey,
            marketCode: market,
            showOnMap: coverageShowOnMap,
            // Coordonnées tronquées (~111 m) avant persistance/envoi : la trace
            // publiée sur la carte communautaire ne révèle pas le trajet au mètre.
            points: coveragePoints.map { $0.minimizedCoordinates() }
        )
    }

    /// Écrit chaque nouveau point dans le JSON atomique avant toute tentative
    /// réseau. L'opération est volontairement synchrone : un retour de cette méthode
    /// signifie que le point est déjà durable sur disque.
    private func persistCoverageSnapshot(force: Bool = false) {
        guard sessionMode.recordsCoverage, let sessionId = coverageSessionId else { return }
        if VPNDetector.isActive() {
            if !coverageUploadSuppressed {
                try? services.sessions.discardCoverageDraft(sessionId: sessionId)
            }
            coverageUploadSuppressed = true
            return
        }
        guard !coverageUploadSuppressed else { return }
        // Debounce : ne PAS ré-encoder+écrire toute la session (coût O(n) croissant
        // sur le main thread) à CHAQUE point capturé. Au plus une persistance toutes
        // les 3 s ; stop()/finalize écrivent de toute façon l'état complet (PERF-DT-01).
        let now = Date()
        guard force || now.timeIntervalSince(lastCoveragePersistAt) >= 3 else { return }
        guard let draft = makeCoverageSessionUpload() else { return }
        lastCoveragePersistAt = now
        do {
            try services.sessions.persistCoverageDraft(draft)
        } catch {
            errorMessage = "Stockage local interrompu : garde l’app ouverte puis réessaie."
            Self.log.error("persistance point couverture ÉCHEC : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Finalise d'abord la session sur disque, puis tente le téléversement. Un kill
    /// entre ces deux étapes laisse donc une entrée rejouable au prochain lancement.
    private func uploadCoverageSessionIfNeeded() {
        let points = coveragePoints
        let sessionId = coverageSessionId
        defer {
            coveragePoints.removeAll()
            lastCoveragePointCoord = nil
            coverageSessionId = nil
            coverageStartedAtMs = nil
            coverageUploadSuppressed = false
        }
        guard sessionMode.recordsCoverage else { return }
        // Raisons de non-envoi rendues VISIBLES (avant : skip/échec totalement muet).
        if coverageUploadSuppressed || VPNDetector.isActive() {
            if let sessionId { try? services.sessions.discardCoverageDraft(sessionId: sessionId) }
            statusLabel = "Couverture non envoyée — VPN actif"
            Self.log.notice("coverage upload ignoré : VPN actif")
            return
        }
        guard points.count >= 2, let last = points.last else {
            if let sessionId { try? services.sessions.discardCoverageDraft(sessionId: sessionId) }
            statusLabel = "Couverture non envoyée — trajet trop court (\(points.count) pt)"
            Self.log.notice("coverage upload ignoré : \(points.count) point(s) seulement")
            return
        }
        guard let session = makeCoverageSessionUpload(endTime: last.timestamp) else { return }
        // Sans marché, le backend ne peut dériver ni MCC ni MNC, et la tuile de
        // couverture filtre sur `"mobileCountryCode" = …` — qu'un NULL ne satisfait
        // jamais. On envoie quand même (la donnée est réelle et le backend peut la
        // rattacher plus tard), mais on cesse d'annoncer « Couverture envoyée »
        // pour des points qui n'apparaîtront pas.
        let marketResolved = session.marketCode?.isEmpty == false
        let sessions = services.sessions
        let count = points.count
        do {
            // Étape critique synchrone : la file est finalisée AVANT Task/network.
            try sessions.finalizeCoverageDraft(session)
        } catch {
            statusLabel = "Couverture conservée en mémoire — stockage indisponible"
            errorMessage = "Impossible de finaliser le Drive Test sur l’appareil."
            Self.log.error("finalisation couverture ÉCHEC : \(error.localizedDescription, privacy: .public)")
            return
        }
        Task {
            do {
                try await sessions.createCoverageSession(session)
                if marketResolved {
                    statusLabel = String(localized: "Couverture envoyée — \(count) point")
                } else {
                    statusLabel = String(localized: "Couverture envoyée — pays non identifié")
                    errorMessage = String(
                        localized: "Ce trajet n'a pas pu être rattaché à un pays : il risque de ne pas apparaître sur la carte. Cela arrive quand l'opérateur reste indétectable (WiFi, VPN, ou pays non couvert)."
                    )
                }
                Self.log.notice("coverage upload OK : \(count) points, marché résolu=\(marketResolved)")
            } catch {
                errorMessage = Self.uploadFailureMessage(error, subject: "couverture")
                Self.log.error("coverage upload ÉCHEC : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Message d'échec d'upload orienté action : un 401 = session expirée (le token
    /// iOS ne vit que 7 j et n'est pas rafraîchi), donc on invite à se reconnecter.
    private static func uploadFailureMessage(_ error: Error, subject: String) -> String {
        if case APIError.http(let status, _, _, _, _) = error, status == 401 {
            return String(localized: "Session expirée — reconnecte-toi pour enregistrer tes mesures.")
        }
        return String(localized: "Échec d'envoi (\(subject)) : \(error.localizedDescription)")
    }

    /// Met à jour l'instantané « réseau autour de moi » (F8) lu par le widget d'accueil.
    private func writeNetworkGlance() {
        WidgetSharedStore.saveNetworkGlance(NetworkGlanceSnapshot(
            operatorLabel: displayedOperatorLabel,
            generation: services.networkPath.status.cellularTechnology?.rawValue,
            nearestDistanceMeters: nearestDistanceMeters,
            nearestOperator: nearestSite?.operators.first,
            lastDownloadMbps: lastResult?.downloadAverageMbps,
            date: Date()
        ))
    }

    private func recomputeNearest() {
        // Secteur UNIQUEMENT si l'opérateur est identifié (résolu ou choisi) : sinon les
        // antennes chargées sont « ALL » (multi-opérateurs) et désigner « ton secteur »
        // serait faux (ex. SIM Orange en WiFi → secteur SFR). Sans opérateur identifié,
        // aucun secteur n'est affiché (pas de cône sur la carte, bandeau d'invite).
        guard displayedOperatorKey != nil,
              let user = userLocation,
              let nearest = AntennaSectorGeometry.nearest(to: user, among: antennas) else {
            nearestSite = nil; nearestDistanceMeters = nil; inSector = false; sectorOffsetDegrees = nil
            return
        }
        nearestSite = nearest.site
        nearestDistanceMeters = nearest.distanceMeters
        if let lat = nearest.site.latitude, let lon = nearest.site.longitude,
           let best = AntennaSectorGeometry.bestSector(
               antenna: CLLocationCoordinate2D(latitude: lat, longitude: lon),
               azimuths: nearest.site.azimuths,
               user: user
           ) {
            inSector = best.inSector
            sectorOffsetDegrees = best.offset
        } else {
            inSector = false
            sectorOffsetDegrees = nil
        }
    }

    private func refreshAntennasIfNeeded(around coordinate: CLLocationCoordinate2D) async {
        // Résout l'opérateur de la SIM active (une fois) pour ne charger que SES antennes.
        await resolveSimOperatorIfNeeded()
        let market = resolvedSim?.market
            ?? marketEntry.map { $0.marketCode.isEmpty ? $0.code : $0.marketCode }
            ?? MapMarketStore.lastMarket() ?? MapMarketStore.localeMarketCode()
        // Opérateur automatique : SIM résolue (IP/ASN + marché GPS), sinon "ALL".
        let op = resolvedSim?.operatorKey ?? "ALL"

        // Refetch si on a bougé (~400 m) OU si l'opérateur ciblé vient de changer
        // (ex. SIM résolue après un démarrage en WiFi).
        if let center = lastFetchCenter, op == lastFetchOperator {
            let moved = CLLocation(latitude: center.latitude, longitude: center.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            if moved < 400 { return }
        }
        guard !antennaFetchInFlight else { return }
        antennaFetchInFlight = true
        lastFetchCenter = coordinate
        lastFetchOperator = op
        defer { antennaFetchInFlight = false }

        let delta = 0.045 // ~5 km de rayon
        let bbox = BoundingBox(
            north: coordinate.latitude + delta, south: coordinate.latitude - delta,
            east: coordinate.longitude + delta, west: coordinate.longitude - delta
        )
        do {
            antennas = try await services.antennas.list(bbox: bbox, market: market, operatorName: op, technologies: [])
            recomputeNearest()
        } catch {
            // Silencieux : on conserve les antennes précédemment chargées.
        }
    }

    /// Résout l'opérateur de la SIM et son marché, par ordre de fiabilité :
    /// 1) MCC/MNC lus DIRECTEMENT sur la SIM (CoreTelephony — marche aussi en WiFi) ;
    /// 2) `operatorKey` par IP/ASN (`resolve`) quand on est en cellulaire ;
    /// 3) repli sur l'opérateur/marché déjà détectés et persistés par la carte (Lot 1A).
    /// Mis en cache (`resolvedSim`) : un drive test = une SIM stable. Fallback "ALL"
    /// seulement si rien n'est déterminable (ex. SIM masquée iOS 16.4+ sans carte ouverte).
    private func resolveSimOperatorIfNeeded() async {
        guard resolvedSim == nil, !simResolveInFlight else { return }
        // Back-off. Le seul garde était `resolvedSim == nil`, donc tant que la
        // résolution échouait — le cas NOMINAL à l'étranger, en WiFi ou sous VPN —
        // chaque point GPS relançait `refreshNow()`, le registre des marchés, une
        // requête HTTP `resolve()` et un `CLGeocoder` (débité par Apple). Sur un
        // trajet d'une heure cela faisait des milliers d'appels pour un résultat
        // qui, lui, ne changeait pas.
        if let last = lastSimResolveFailureAt {
            let cooldown = simResolveFailures >= 3 ? 300.0 : 60.0
            guard Date().timeIntervalSince(last) >= cooldown else { return }
        }
        simResolveInFlight = true
        defer { simResolveInFlight = false }

        services.networkPath.refreshNow()
        let status = services.networkPath.status
        let payload = await services.markets.registry()

        // 1. Marché via le MCC de la SIM (lecture directe, indépendante du WiFi).
        let plmn = services.networkPath.simPLMN()
        var entry: MarketRegistryEntry?
        if let mcc = plmn.mcc { entry = payload.markets.first { $0.mccs.contains(mcc) } }

        // 2. Opérateur le plus fiable : resolve() (IP/ASN) en cellulaire hors VPN.
        var operatorKey: String?
        if status.connection == .cellular,
           let detected = await services.networkOperator.resolve(viaVpn: VPNDetector.isActive()),
           let key = detected.operatorKey {
            operatorKey = key
            if entry == nil { entry = payload.markets.first { $0.operatorEntry(forKey: key) != nil } }
        }
        // 3. Repli opérateur via le MNC de la SIM.
        if operatorKey == nil, let mnc = plmn.mnc, let entry,
           let op = entry.selectableOperators.first(where: { $0.mncs.contains(mnc) }) {
            operatorKey = op.key
        }
        // 4. Repli : opérateur/marché persistés de la carte (déjà détectés au Lot 1A).
        if operatorKey == nil,
           let persistedOp = MapMarketStore.lastOperator(), persistedOp.uppercased() != "ALL",
           let persistedEntry = payload.market(forCode: MapMarketStore.lastMarket()),
           persistedEntry.operatorEntry(forKey: persistedOp) != nil {
            entry = persistedEntry
            operatorKey = persistedOp
        }

        // Renseigne le sélecteur manuel + la palette à partir du meilleur marché
        // connu — MÊME si l'opérateur n'a pas pu être auto-résolu (WiFi/VPN/SIM
        // masquée) : l'utilisateur peut alors choisir son opérateur à la main.
        // Marché du sélecteur : MCC SIM / opérateur résolu déjà calculés ci-dessus,
        // sinon repli PAYS via le GPS (position réelle), puis locale du téléphone.
        var bestEntry = entry ?? payload.market(forCode: MapMarketStore.lastMarket())
        if bestEntry == nil, let user = userLocation,
           let iso = await reverseGeocodeISOCountry(user) {
            bestEntry = payload.markets.first { $0.countryCode.uppercased() == iso.uppercased() }
        }
        if let bestEntry = bestEntry ?? payload.market(forCode: MapMarketStore.localeMarketCode()) {
            marketEntry = bestEntry
            availableOperators = bestEntry.selectableOperators.filter { $0.key.uppercased() != "ALL" }
        }

        guard let operatorKey, let entry, entry.operatorEntry(forKey: operatorKey) != nil else {
            simResolveFailures += 1
            lastSimResolveFailureAt = Date()
            return
        }
        let market = entry.marketCode.isEmpty ? entry.code : entry.marketCode
        resolvedSim = (market, operatorKey)
        simOperatorLabel = entry.operatorEntry(forKey: operatorKey)?.shortLabel ?? operatorKey
        simResolveFailures = 0
        lastSimResolveFailureAt = nil
    }

    /// Détecte un changement de SIM (PLMN) en cours de session et re-résout l'opérateur
    /// SANS interrompre la boucle speedtest / l'enregistrement de couverture (point 5).
    /// Le choix manuel reste prioritaire pour l'affichage.
    private func detectSimChangeIfNeeded() async {
        let plmn = services.networkPath.simPLMN()
        defer { lastSimPLMN = (plmn.mcc, plmn.mnc) }
        guard let previous = lastSimPLMN else { return } // 1er passage : on mémorise seulement
        guard previous.mcc != plmn.mcc || previous.mnc != plmn.mnc else { return }
        // Nouvelle SIM : on oublie l'ancienne résolution et on relance la détection + le
        // refetch des antennes (la session continue, rien n'est arrêté).
        resolvedSim = nil
        simOperatorLabel = nil
        lastFetchOperator = nil
        await resolveSimOperatorIfNeeded()
    }

    /// Code pays ISO (ex. « FR ») de la position GPS — repli pour peupler le sélecteur
    /// d'opérateur quand la SIM est masquée (point 4).
    private func reverseGeocodeISOCountry(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                continuation.resume(returning: placemarks?.first?.isoCountryCode)
            }
        }
    }

    /// Charge les opérateurs du marché dès l'apparition (sans attendre une position),
    /// à partir du marché de la SIM / persisté / locale. Sert la palette de couleurs
    /// des marqueurs de la carte.
    func prepareOperatorSelector() async {
        guard availableOperators.isEmpty else { return }
        let payload = await services.markets.registry()
        let plmn = services.networkPath.simPLMN()
        let entry = plmn.mcc.flatMap { mcc in payload.markets.first { $0.mccs.contains(mcc) } }
            ?? payload.market(forCode: MapMarketStore.lastMarket())
            ?? payload.market(forCode: MapMarketStore.localeMarketCode())
        if let entry {
            marketEntry = entry
            availableOperators = entry.selectableOperators.filter { $0.key.uppercased() != "ALL" }
        }
    }

    // MARK: Boucle speedtest continue

    private func runLoop() async {
        while !Task.isCancelled {
            guard await waitUntilNextTestIsDue() else { break }
            if dataCapExceeded() { stopForDataCap(); return }

            testCount += 1
            errorMessage = nil
            statusLabel = "Test \(testCount) en cours…"
            lastTestCoordinate = services.location.lastLocation?.coordinate ?? userLocation
            do {
                let result = try await runOneTest()
                lastResult = result
                accumulator.add(result)
                summary = accumulator.summary(truncatedAt: nil)
                statusLabel = "Test \(testCount) terminé"
            } catch is CancellationError {
                break
            } catch {
                // Un test raté n'interrompt pas la session : on note et on continue.
                errorMessage = error.localizedDescription
            }
            refreshSessionBytes()
            // Les valeurs (ping/DL/UL) RESTENT affichées ; elles ne se réinitialisent
            // qu'au démarrage du test suivant (dans runOneTest).
            liveMbps = 0
            if Task.isCancelled { break }
            // Renouvelle l'assertion d'arrière-plan entre deux tests (écran verrouillé).
            background.renew(name: "drivetest")
            if dataCapExceeded() { stopForDataCap(); return }
        }
    }

    /// Attend que le prochain test soit dû : distance parcourue depuis le
    /// précédent, ou demande explicite de l'utilisateur. Renvoie `false` si la
    /// session est annulée pendant l'attente.
    ///
    /// Le premier test part immédiatement — attendre 500 m avant la moindre mesure
    /// donnerait l'impression d'une session qui ne démarre pas.
    private func waitUntilNextTestIsDue() async -> Bool {
        while !Task.isCancelled {
            if manualTestRequested {
                manualTestRequested = false
                return true
            }
            guard let origin = lastTestCoordinate else { return true }
            if let current = services.location.lastLocation?.coordinate ?? userLocation {
                let moved = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                    .distance(from: CLLocation(latitude: current.latitude, longitude: current.longitude))
                if moved >= testIntervalMeters { return true }
                statusLabel = String(
                    localized: "Prochain test dans \(Int((testIntervalMeters - moved).rounded())) m"
                )
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Déclenche un test sans attendre la distance — pour un arrêt volontaire
    /// (bouchon, mesure à un point précis).
    func requestImmediateTest() {
        guard isRunning, sessionMode.runsSpeedtest, !isPausedForWiFi else { return }
        manualTestRequested = true
    }

    /// Bilan honnête : ce qui a été enregistré, et ce qui cloche le cas échéant.
    private func makeSessionRecap() -> SessionRecap {
        var parts: [String] = [
            String(localized: "\(Int(distanceMeters.rounded())) m parcourus")
        ]
        if sessionMode.recordsCoverage {
            parts.append(String(localized: "\(coveragePointCount) point de couverture"))
        }
        if sessionMode.runsSpeedtest {
            parts.append(String(localized: "\(testCount) test"))
            parts.append(String(localized: "\(Self.formattedBytes(sessionBytes)) de données"))
        }

        var caveat: String?
        if coverageTruncated {
            caveat = String(localized: "Trajet trop long : les portions les plus anciennes n'ont pas été envoyées.")
        } else if stoppedByDataCap {
            caveat = String(localized: "Arrêt automatique : plafond de données atteint.")
        } else if VPNDetector.isActive() {
            caveat = String(localized: "VPN actif : rien n'a été publié sur la carte.")
        }
        return SessionRecap(summaryLine: parts.joined(separator: " · "), caveat: caveat)
    }

    private func refreshSessionBytes() {
        sessionBytes = SpeedtestDataMeter.shared.bytes
    }

    private func dataCapExceeded() -> Bool {
        refreshSessionBytes()
        guard let cap = dataCapBytes else { return false }
        return sessionBytes >= cap
    }

    /// Arrêt au plafond : la session se termine comme un arrêt manuel (la
    /// couverture déjà capturée part normalement), mais l'état le DIT.
    private func stopForDataCap() {
        stoppedByDataCap = true
        stop()
        statusLabel = String(localized: "Plafond de données atteint — session arrêtée")
        errorMessage = String(
            localized: "Le Drive Test s'est arrêté à \(Self.formattedBytes(sessionBytes)) de données. Tu peux relever le plafond dans les réglages du test."
        )
    }

    /// Volume lisible. `ByteCountFormatter` plutôt qu'une division maison : il suit
    /// la langue et les conventions locales (Go / GB).
    ///
    /// `nonisolated` : fonction pure, elle ne touche aucun état du modèle — sans
    /// cela elle hériterait de `@MainActor` et resterait inatteignable depuis un
    /// test synchrone.
    nonisolated static func formattedBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: Int64(max(0, bytes)))
    }

    private func runOneTest() async throws -> SpeedtestRunResult {
        let index = testCount
        // Réinitialise les valeurs du test PRÉCÉDENT au démarrage de ce test.
        livePing = 0
        liveDownload = 0
        liveUpload = 0
        liveMbps = 0
        livePhase = .ping
        services.networkPath.refreshNow()
        let status = services.networkPath.status
        isVPNActive = VPNDetector.isActive()
        let coordinate = services.location.lastLocation?.coordinate ?? userLocation
        let location = coordinate.map { Coordinates(latitude: $0.latitude, longitude: $0.longitude) }
        let settings = makeSettings()
        let measured = try await services.speedtest.run(
            pathStatus: status,
            location: location,
            settings: settings,
            progress: { [weak self] live in
                Task { @MainActor in self?.applyLiveProgress(live, testIndex: index) }
            }
        )
        try Task.checkCancellation()
        do {
            // Rattache le speedtest à la session Drive Test en cours (id local) : le
            // backend le reliera à la session de couverture (rattachement direct si déjà
            // importée, sinon backfill à l'import). nil hors enregistrement de couverture.
            try await services.speedtest.save(
                measured,
                streams: settings.streams,
                publishToMap: publishToMap(),
                driveSessionId: coverageSessionId?.uuidString
            )
        } catch {
            // `save` met déjà la mesure en file d'attente locale (rejeu ultérieur) ;
            // on rend la cause visible au lieu de l'avaler silencieusement.
            errorMessage = Self.uploadFailureMessage(error, subject: "speedtest")
            Self.log.error("drive speedtest save ÉCHEC (en file d'attente) : \(error.localizedDescription, privacy: .public)")
        }
        // Valeurs finales du test (restent affichées jusqu'au test suivant).
        livePhaseFinalize(measured)
        // F1 : point de couverture portant le débit mesuré à cette position.
        captureMeasuredCoveragePoint(measured)
        // Point speedtest géolocalisé (carte Drive Test, tappable → détails).
        if let coordinate { appendSpeedtestPoint(measured, at: coordinate) }
        // Affiche le résultat de ce test dans la Live Activity.
        liveActivity.update(
            phaseLabel: "\(liveOperatorPrefix)Test \(index) terminé",
            downloadMbps: measured.downloadAverageMbps,
            uploadMbps: measured.uploadAverageMbps ?? 0,
            pingMs: measured.pingMinMs ?? measured.pingMs ?? 0,
            progress: 1, runIndex: index, runTotal: 0
        )
        return measured
    }

    private func livePhaseFinalize(_ measured: SpeedtestRunResult) {
        livePhase = .finished
        livePing = measured.pingMinMs ?? measured.pingMs ?? livePing
        liveDownload = measured.downloadAverageMbps
        liveUpload = measured.uploadAverageMbps ?? liveUpload
    }

    /// Reflète la progression d'un test (ping → download → upload) dans la jauge du
    /// panneau et la Live Activity (visible écran verrouillé).
    private func applyLiveProgress(_ live: SpeedtestLiveProgress, testIndex: Int) {
        guard isRunning else { return }
        livePhase = live.phase
        liveMbps = live.currentMbps
        // Le compteur monte PENDANT le transfert, pas seulement entre deux tests :
        // c'est là que le volume grimpe, et c'est là que l'utilisateur regarde.
        refreshSessionBytes()
        // On n'écrase une valeur que lorsqu'une mesure est disponible (sinon on garde
        // la valeur déjà acquise — pas de retour à 0 en cours de test).
        if let ping = live.pingFinalMs ?? live.pingLiveMs { livePing = ping }
        if let download = live.downloadAverageMbps ?? live.downloadLiveMbps
            ?? (live.phase == .download ? live.currentMbps : nil) {
            liveDownload = download
        }
        if let upload = live.uploadAverageMbps ?? live.uploadLiveMbps
            ?? (live.phase == .upload ? live.currentMbps : nil) {
            liveUpload = upload
        }
        liveActivity.update(
            phaseLabel: "\(liveOperatorPrefix)Test \(testIndex) · \(Self.phaseLabel(live.phase))",
            downloadMbps: liveDownload,
            uploadMbps: liveUpload,
            pingMs: livePing,
            progress: live.fraction,
            runIndex: testIndex, runTotal: 0
        )
    }

    private static func phaseLabel(_ phase: SpeedtestPhase) -> String {
        switch phase {
        case .idle: return String(localized: "Prêt")
        case .ping: return "Ping"
        case .download: return String(localized: "Téléchargement")
        case .upload: return "Envoi"
        case .saving: return "Enregistrement"
        case .finished: return String(localized: "Terminé")
        case .failed: return String(localized: "Échec")
        }
    }

    private func makeSettings() -> SpeedtestRunSettings {
        let defaults = UserDefaults.standard
        let duration = (defaults.object(forKey: "speedtest_duration_seconds") as? Int) ?? 10
        let streams = (defaults.object(forKey: "speedtest_streams") as? Int) ?? 16
        let reliability = (defaults.object(forKey: "speedtest_reliability_mode") as? Bool) ?? true
        let target = SpeedtestDownloadTarget(rawValue: defaults.string(forKey: "speedtest_download_target") ?? "") ?? .hybridAuto
        return SpeedtestRunSettings(
            downloadTarget: target,
            durationSeconds: min(max(duration, 5), 30),
            streams: min(max(streams, 1), 16),
            reliabilityMode: reliability
        )
    }

    /// Un Drive Test publie TOUJOURS — c'est sa raison d'être : contribuer à la
    /// carte communautaire. L'utilisateur en est informé une fois, avant son
    /// premier trajet (`DriveTestDisclosureView`), sans qu'on lui demande son avis.
    ///
    /// Ces deux méthodes lisaient auparavant la même clé `speedtest_publish_to_map`
    /// avec des défauts OPPOSÉS — `false` pour le speedtest, `true` pour la
    /// couverture. Sur une installation neuve l'interrupteur des réglages affichait
    /// donc « désactivé » pendant que la trace du trajet, elle, était publiée. Ne
    /// plus lire cette clé du tout est ce qui supprime la contradiction ; l'onglet
    /// Speedtest autonome garde son opt-in, un test ponctuel chez soi n'étant pas
    /// une contribution.
    ///
    /// Le garde VPN reste : sous tunnel l'opérateur détecté est celui de la sortie
    /// du tunnel, donc la mesure serait attribuée au mauvais réseau. C'est une
    /// exigence de qualité de donnée, pas un réglage de confidentialité.
    private func publishToMap() -> Bool { !VPNDetector.isActive() }

    private func coveragePublishToMap() -> Bool { !VPNDetector.isActive() }
}

struct DriveTestView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: DriveTestViewModel
    @State private var selectedAntenna: AntennaSite?
    @State private var selectedSpeedtest: DriveSpeedtestPoint?
    @State private var showMapLegend = false
    /// Information « ce qu'un Drive Test partage », une seule fois avant le premier
    /// trajet. Présentée à l'ouverture de l'écran plutôt qu'au tap sur Démarrer :
    /// on informe AVANT que l'utilisateur ait décidé de partir, pas après.
    @State private var showDisclosure = false
    /// Mode du Drive Test, persisté localement. Défaut « Les deux » → la couverture
    /// est enregistrée par défaut (le choix d'un mode couverture vaut consentement).
    @AppStorage(DriveTestMode.storageKey) private var driveTestModeRaw = DriveTestMode.both.rawValue
    private var driveTestMode: DriveTestMode { DriveTestMode(rawValue: driveTestModeRaw) ?? .both }

    init(services: AppServices) {
        _model = StateObject(wrappedValue: DriveTestViewModel(services: services))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
                .ignoresSafeArea()
            controlPanel
                .padding(SQSpace.md)
                // La carte ignore la safe area : le panneau posé dessus retombe au
                // bas PHYSIQUE de l'écran, où le dock flottant le recouvre. Le
                // `sqDockSafeArea()` de l'onglet ne l'atteint pas — même cause que
                // sur Territoires.
                .padding(.bottom, SQDock.floatingContentInset - SQSpace.md)
        }
        .overlay(alignment: .topTrailing) { mapLegendControl }
        .navigationTitle("Drive Test")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.onAppear()
            if !UserDefaults.standard.bool(forKey: DriveTestDisclosureView.seenKey) {
                showDisclosure = true
            }
        }
        .sheet(isPresented: $showDisclosure) {
            DriveTestDisclosureView { showDisclosure = false }
                .interactiveDismissDisabled()
        }
        // L'onglet Tester encore sélectionné = on a quitté l'écran (retour) ;
        // un autre onglet = l'écran est seulement masqué, la session continue.
        .onDisappear { model.onDisappear(isLeavingScreen: services.router.selectedTab == .speed) }
        // Détails antenne au tap — la session speedtest continue en arrière-plan.
        .sheet(item: $selectedAntenna) { site in
            AntennaDetailSheet(
                site: site,
                market: model.antennaDetailMarket,
                operatorName: model.antennaDetailOperator,
                service: services.antennas
            )
        }
        .sheet(item: $selectedSpeedtest) { point in
            DriveSpeedtestDetailSheet(point: point)
        }
    }

    /// Fond des contrôles posés sur la carte : verre crème (`surfaceGlass` sur blur
    /// système) — la profondeur vient des ombres, jamais d'une bordure.
    private func mapGlassBackground<S: InsettableShape>(_ shape: S) -> some View {
        shape
            .fill(SQColor.surfaceGlass)
            .background(.ultraThinMaterial, in: shape)
    }

    /// Bouton de légende (masquée par défaut) + légende compacte génération/débit.
    private var mapLegendControl: some View {
        VStack(alignment: .trailing, spacing: SQSpace.xs) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showMapLegend.toggle() }
            } label: {
                Image(systemName: showMapLegend ? "xmark" : "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 40, height: 40)
                    .background { mapGlassBackground(Circle()) }
                    .sqShadowSoft()
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel(showMapLegend ? "Masquer la légende" : "Afficher la légende")
            if showMapLegend { mapLegend }
        }
        .padding(.trailing, SQSpace.md)
        .padding(.top, SQSpace.sm)
    }

    // Couleurs de la légende : échelles génération / débit des points dessinés sur la
    // carte + la ligne du parcours (terre cuite). La génération inclut « Aucun » (gris,
    // zone sans cellulaire) ; la ligne « Parcours » n'encode AUCUN signal, elle marque
    // seulement le trajet suivi (visible seul quand la session est en pause WiFi).
    private var mapLegend: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            legendSection(
                "Génération",
                items: SQSignalScale.Generation.allCases.map { ($0.label, $0.color, $0.glyph) },
                mark: .circle
            )
            legendSection("Parcours", items: [
                (String(localized: "Trajet suivi"), SQColor.brandOrange, nil)
            ], mark: .line)
            // Échelle complète (7 paliers) réellement dessinée pour les losanges
            // (DriveTestMapView.speedColor), au lieu de 3 couleurs incomplètes qui
            // laissaient les points sans clé de lecture (UI-06).
            legendSection(
                "Débit speedtest (Mbps)",
                items: SQSignalScale.Throughput.allCases.map { ($0.label, $0.color, $0.glyph) },
                mark: .diamond
            )
        }
        .padding(SQSpace.sm + 2)
        .background { mapGlassBackground(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)) }
        .sqShadowCard()
        // Largeur PLAFONNÉE et non figée : à 146 pt fixes, la légende débordait dès
        // les grandes tailles de texte.
        .frame(maxWidth: 190, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
        // La légende est la clé de lecture de la carte : la masquer à VoiceOver
        // revenait à livrer une carte que le lecteur d'écran ne peut pas interpréter.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Légende de la carte")
    }

    private enum LegendMark { case circle, diamond, line }

    private func legendSection(
        _ title: String,
        items: [(String, Color, String?)],
        mark: LegendMark
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title)).font(SQFont.body(11, .semibold)).foregroundStyle(SQColor.labelSecondary)
            ForEach(items, id: \.0) { label, color, glyph in
                HStack(spacing: 6) {
                    legendMark(mark, color: color).frame(width: 14, alignment: .center)
                    // Le glyphe double la couleur : l'échelle reste lisible en
                    // niveaux de gris, sous « Differentiate Without Color », et
                    // pour un daltonien deutan sur qui l'ambre et le vert se
                    // confondent.
                    if let glyph {
                        Image(systemName: glyph)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(color)
                            .frame(width: 12)
                    }
                    Text(LocalizedStringKey(label)).font(SQFont.body(11.5)).foregroundStyle(SQColor.label)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func legendMark(_ mark: LegendMark, color: Color) -> some View {
        switch mark {
        case .circle:
            Circle().fill(color).frame(width: 9, height: 9)
        case .diamond:
            Rectangle().fill(color).frame(width: 8, height: 8).rotationEffect(.degrees(45))
        case .line:
            Capsule().fill(color).frame(width: 14, height: 3)
        }
    }

    private var mapLayer: some View {
        DriveTestMapView(
            antennas: model.antennas,
            trace: model.trace,
            coverageTrail: model.coverageTrail,
            speedtestTrail: model.speedtestTrail,
            highlightedSiteId: model.nearestSiteId,
            userLocation: model.userLocation,
            colorScheme: colorScheme,
            operatorPalette: operatorPalette,
            displayedOperatorKey: model.displayedOperatorKey,
            onSelectSite: { selectedAntenna = $0 },
            onSelectSpeedtest: { selectedSpeedtest = $0 }
        )
    }

    private var controlPanel: some View {
        VStack(spacing: SQSpace.sm + 2) {
            if model.isVPNActive {
                VPNWarningBanner(message: "VPN actif : opérateur non détectable, ces tests ne seront pas publiés sur la carte.")
            }
            operatorRow
            if model.isRunning {
                // Panneau COMPACT pendant l'enregistrement : opérateur + résultats
                // (speedtest) ou nombre de points (couverture) + arrêt. Pas de secteur
                // ni de sélecteur de mode (figé au démarrage).
                if model.isPausedForWiFi { pauseBanner }
                if driveTestMode.runsSpeedtest && !model.isPausedForWiFi {
                    liveReadout
                    sessionStats
                }
                if driveTestMode.recordsCoverage { coverageStatusRow }
                sessionMetricsRow
            } else {
                // Une session vient de se terminer : dire ce qu'elle a produit avant
                // de reproposer un démarrage. Sans ce récapitulatif, l'écran
                // revenait au choix du mode et tout le trajet disparaissait de vue.
                if let recap = model.lastSessionRecap { sessionRecapCard(recap) }
                // Panneau complet avant démarrage : mode + secteur (si opérateur identifié).
                modePicker
                if model.displayedOperatorLabel != nil { sectorBanner }
            }
            if let errorMessage = model.errorMessage {
                VStack(alignment: .leading, spacing: SQSpace.xs) {
                    Text(errorMessage)
                        .font(SQFont.body(12.5, .medium))
                        .foregroundStyle(SQColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(3)
                    if model.locationDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Ouvrir les Réglages", destination: url)
                            .font(SQFont.body(12.5, .semibold))
                            .foregroundStyle(SQColor.brandRed)
                    }
                }
                .padding(.horizontal, SQSpace.sm + 2)
                .padding(.vertical, SQSpace.xs + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SQColor.dangerSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            }
            actionButton
        }
        .padding(SQSpace.lg)
        .background { mapGlassBackground(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)) }
        .sqShadowDock()
    }

    /// Sélecteur du contenu du Drive Test (avant démarrage) : couverture / speedtest /
    /// les deux. Persisté via `@AppStorage`. « Couverture » enregistre la génération le
    /// long du trajet sans lancer de test de débit.
    private var modePicker: some View {
        VStack(spacing: SQSpace.xs + 2) {
            SQSegmentedFilter(
                selection: $driveTestModeRaw,
                options: DriveTestMode.allCases.map { (value: $0.rawValue, label: $0.short, icon: String?.none) }
            )
            .padding(.horizontal, -SQSpace.lg)
            Text(driveTestModeHint)
                .font(SQFont.body(12, .medium))
                .foregroundStyle(SQColor.labelSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode du Drive Test")
        .accessibilityHint("Choisissez d'enregistrer la couverture, de lancer des speedtests, ou les deux")
    }

    private var driveTestModeHint: String {
        switch driveTestMode {
        case .coverage: return String(localized: "Enregistre la génération (5G/4G/…) le long du trajet, sans test de débit.")
        case .speedtest: return String(localized: "Enchaîne des speedtests en continu, sans enregistrer la couverture.")
        case .both: return "Speedtests en continu + enregistrement de la couverture le long du trajet."
        }
    }

    /// Compteur de points de couverture capturés (visible pendant un mode couverture).
    private var coverageStatusRow: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SQColor.brandRed)
            Text("Couverture · \(model.coveragePointCount) point")
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(SQColor.label)
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs + 3)
        .frame(maxWidth: .infinity)
        .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        // Le libellé visible est pluralisé depuis longtemps ; celui-ci ne l'était
        // pas et VoiceOver annonçait « 1 points ». Le défaut ne se voit pas à
        // l'écran, seulement à l'oreille.
        .accessibilityLabel("Couverture enregistrée : \(model.coveragePointCount) point")
    }

    /// Récapitulatif de la session qui vient de s'achever.
    private func sessionRecapCard(_ recap: DriveTestViewModel.SessionRecap) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs + 2) {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SQColor.brandRed)
                Text("Session terminée")
                    .font(SQFont.body(14, .semibold))
                    .foregroundStyle(SQColor.label)
                Spacer()
            }
            Text(recap.summaryLine)
                .font(SQFont.body(12.5))
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let caveat = recap.caveat {
                Text(caveat)
                    .font(SQFont.body(12))
                    .foregroundStyle(SQColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Distance parcourue et données consommées — les deux chiffres qui manquaient
    /// pendant un trajet. Le volume est celui des speedtests : c'est lui qui pèse
    /// sur le forfait, et il pouvait atteindre plusieurs gigaoctets sans que rien
    /// ne l'indique.
    private var sessionMetricsRow: some View {
        HStack(spacing: SQSpace.md) {
            Label {
                Text(distanceText)
                    .font(SQFont.body(13, .semibold))
                    .monospacedDigit()
            } icon: {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(SQColor.label)

            if driveTestMode.runsSpeedtest {
                Divider().frame(height: 14)
                Label {
                    Text(DriveTestViewModel.formattedBytes(model.sessionBytes))
                        .font(SQFont.body(13, .semibold))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(SQColor.label)
            }
            Spacer()
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs + 3)
        .frame(maxWidth: .infinity)
        .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progression de la session")
        .accessibilityValue(
            driveTestMode.runsSpeedtest
            ? Text("\(distanceText) parcourus, \(DriveTestViewModel.formattedBytes(model.sessionBytes)) de données")
            : Text("\(distanceText) parcourus")
        )
    }

    /// Distance lisible : mètres sous 1 km, puis kilomètres à une décimale.
    private var distanceText: String {
        let meters = model.distanceMeters
        let formatter = MeasurementFormatter()
        formatter.numberFormatter.maximumFractionDigits = meters < 1_000 ? 0 : 1
        // `.naturalScale` choisit l'unité selon l'ordre de grandeur — et descend en
        // MILLIMÈTRES sous le mètre : au démarrage d'une session le panneau
        // affichait « 0 mm ». On garde l'unité fournie tant qu'on n'a pas parcouru
        // au moins un mètre.
        formatter.unitOptions = meters < 1 ? .providedUnit : .naturalScale
        return formatter.string(from: Measurement(value: meters, unit: UnitLength.meters))
    }

    /// Bandeau « en pause WiFi » (reprise auto en cellulaire) pendant l'enregistrement :
    /// statut ambre en pastille teintée.
    private var pauseBanner: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SQColor.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text("En pause — WiFi détecté")
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.label)
                Text("Reprise automatique en cellulaire")
                    .font(SQFont.body(11.5))
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs + 3)
        .frame(maxWidth: .infinity)
        .background(SQColor.warningSoft, in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session en pause : WiFi détecté, reprise automatique en cellulaire")
    }

    private var liveReadout: some View {
        HStack(spacing: SQSpace.sm) {
            ProgressView().controlSize(.small).tint(SQColor.brandRed)
            Text(model.statusLabel)
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
            Spacer()
            if model.livePhase == .download || model.livePhase == .upload {
                Text("\(Int(model.liveMbps.rounded())) Mbps")
                    .font(SQFont.body(13, .bold))
                    .foregroundStyle(SQColor.brandRed)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs + 3)
        .frame(maxWidth: .infinity)
        .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
    }

    private var sectorBanner: some View {
        HStack(spacing: SQSpace.sm + 2) {
            Image(systemName: sectorIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(sectorColor)
                .frame(width: 38, height: 38)
                .background(sectorSoftColor, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(sectorTitle)
                    .font(SQFont.body(14.5, .semibold))
                    .foregroundStyle(SQColor.label)
                if let detail = sectorDetail {
                    Text(detail)
                        .font(SQFont.body(12))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            Spacer()
        }
    }

    /// Opérateur détecté AUTOMATIQUEMENT (SIM / IP-ASN / marché GPS). Affichage seul :
    /// plus de sélecteur manuel — la couverture est toujours taguée avec l'opérateur réel,
    /// pour tous les utilisateurs et tous les pays.
    private var operatorRow: some View {
        HStack(spacing: SQSpace.sm) {
            Circle()
                .fill(model.operatorColor(model.displayedOperatorKey))
                .frame(width: 10, height: 10)
                .opacity(model.displayedOperatorKey == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(operatorRowTitle)
                    .font(SQFont.body(15, .semibold))
                    .foregroundStyle(SQColor.label)
                Text(operatorRowSubtitle)
                    .font(SQFont.body(11.5))
                    .foregroundStyle(model.displayedOperatorLabel == nil ? SQColor.warning : SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs + 4)
        .frame(maxWidth: .infinity)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opérateur détecté")
        .accessibilityValue(model.displayedOperatorLabel ?? "en cours de détection")
    }

    private var operatorRowTitle: String {
        if let label = model.displayedOperatorLabel { return label }
        return model.operatorDetectionGaveUp
            ? String(localized: "Opérateur non détecté")
            : String(localized: "Opérateur en cours de détection…")
    }

    /// « Détection en cours… » restait affiché indéfiniment quand l'opérateur
    /// n'était pas résolvable — WiFi, VPN, ou pays absent du registre. Après
    /// plusieurs échecs on annonce le résultat et ses conséquences, plutôt que de
    /// laisser tourner un message d'attente qui n'attend plus rien.
    private var operatorRowSubtitle: String {
        if model.displayedOperatorLabel != nil { return String(localized: "Détecté automatiquement") }
        guard model.operatorDetectionGaveUp else { return String(localized: "Détection en cours…") }
        return String(localized: "La couverture sera enregistrée sans opérateur, et le secteur de l'antenne la plus proche reste indisponible.")
    }

    /// Palette UIKit par clé d'opérateur (MAJ), pour colorer les marqueurs carte.
    private var operatorPalette: [String: UIColor] {
        var map: [String: UIColor] = [:]
        for op in model.availableOperators {
            map[op.key.uppercased()] = UIColor(model.operatorColor(op.key))
        }
        if let key = model.displayedOperatorKey {
            map[key.uppercased()] = UIColor(model.operatorColor(key))
        }
        return map
    }

    private var sessionStats: some View {
        VStack(spacing: SQSpace.xs + 2) {
            // Valeurs du test courant : se remplissent en live et RESTENT jusqu'au test suivant.
            HStack(spacing: 0) {
                stat(label: "Ping", value: liveValue(model.livePing), unit: "ms")
                divider
                stat(label: "Download", value: liveValue(model.liveDownload), unit: "Mbps")
                divider
                stat(label: "Upload", value: liveValue(model.liveUpload), unit: "Mbps")
            }
            .padding(.vertical, SQSpace.sm)
            .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            if let summary = model.summary, summary.count > 0 {
                Text("\(summary.count) test · moy. DL \(Int(summary.avgDownload.rounded())) Mbps · ping min \(Int(summary.minPing.rounded())) ms")
                    .font(SQFont.body(11.5))
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    private func liveValue(_ value: Double) -> String {
        value > 0 ? "\(Int(value.rounded()))" : "—"
    }

    private var divider: some View {
        Rectangle().fill(SQColor.separator).frame(width: 1, height: 26)
    }

    private func stat(label: String, value: String, unit: String?) -> some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(SQFont.display(20, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                if let unit { Text(unit).font(SQFont.body(11)).foregroundStyle(SQColor.labelSecondary) }
            }
            Text(LocalizedStringKey(label)).font(SQFont.body(11)).foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionButton: some View {
        if model.isRunning {
            VStack(spacing: SQSpace.xs + 2) {
                // La cadence est désormais liée à la DISTANCE : à l'arrêt (bouchon,
                // point précis à mesurer) aucun test ne partirait jamais. Ce bouton
                // est l'échappatoire, et il n'a de sens que dans ce cas.
                if driveTestMode.runsSpeedtest && !model.isPausedForWiFi {
                    GradientButton("Tester maintenant", systemImage: "bolt.fill", style: .secondary) {
                        Haptics.selection()
                        model.requestImmediateTest()
                    }
                }
                // Action en cours / stop = capsule brique (la seule grande surface accent).
                GradientButton("Arrêter le drive test", systemImage: "stop.fill", style: .accent) { model.stop() }
            }
        } else {
            GradientButton(startButtonTitle, systemImage: "play.fill") { model.start() }
        }
    }

    private var startButtonTitle: String {
        switch driveTestMode {
        case .coverage: return String(localized: "Démarrer l'enregistrement couverture")
        case .speedtest: return String(localized: "Démarrer le speedtest continu")
        case .both: return String(localized: "Démarrer le drive test")
        }
    }

    // MARK: Dérivés UI

    private var sectorIcon: String {
        guard model.nearestSite != nil else { return "antenna.radiowaves.left.and.right.slash" }
        return model.inSector ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var sectorColor: Color {
        guard model.nearestSite != nil else { return SQColor.labelSecondary }
        return model.inSector ? SQColor.success : SQColor.warning
    }

    /// Teinte douce de la pastille du statut secteur (olive / ambre / neutre).
    private var sectorSoftColor: Color {
        guard model.nearestSite != nil else { return SQColor.surfaceMuted }
        return model.inSector ? SQColor.successSoft : SQColor.warningSoft
    }

    private var sectorTitle: String {
        guard model.nearestSite != nil else { return "Recherche d'antennes…" }
        return model.inSector ? "Dans le secteur" : "Hors secteur"
    }

    private var sectorDetail: String? {
        guard let distance = model.nearestDistanceMeters else { return nil }
        let distanceText = SQUnits.distance(meters: distance)
        if let offset = model.sectorOffsetDegrees {
            return String(localized: "Antenne la plus proche · \(distanceText) · écart \(Int(offset.rounded()))°")
        }
        return "Antenne la plus proche · \(distanceText)"
    }
}
