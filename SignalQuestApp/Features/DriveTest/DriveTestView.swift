import SwiftUI
import CoreLocation

/// Mode Drive Test : enchaîne des speedtests en continu (rafale illimitée) tout en
/// suivant la position, en affichant les antennes proches sur une carte et en
/// indiquant si l'on est « dans le secteur » de l'antenne la plus proche. Réutilise
/// le moteur speedtest, le suivi de localisation continu et la géométrie de secteur.
@MainActor
final class DriveTestViewModel: ObservableObject {
    // Session speedtest continue.
    @Published private(set) var isRunning = false
    @Published private(set) var testCount = 0
    @Published private(set) var summary: SpeedtestBurstSummary?
    @Published private(set) var lastResult: SpeedtestRunResult?
    @Published private(set) var statusLabel = "Prêt"
    @Published private(set) var errorMessage: String?

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

    var nearestSiteId: String? { nearestSite?.id }
    /// Marché / opérateur pour la feuille de détails antenne (opérateur de la SIM si résolu).
    var antennaDetailMarket: String { resolvedSim?.market ?? MapMarketStore.lastMarket() ?? MapMarketStore.localeMarketCode() }
    var antennaDetailOperator: String { resolvedSim?.operatorKey ?? "ALL" }

    private let services: AppServices
    private var sessionTask: Task<Void, Never>?
    private var accumulator = ContinuousSessionAccumulator()
    private var lastFetchCenter: CLLocationCoordinate2D?
    private var lastFetchOperator: String?
    private var antennaFetchInFlight = false
    private let traceCap = 600
    /// Opérateur de la SIM active résolu une fois (MCC→marché, operatorKey via IP/ASN
    /// ou MNC). Drive test = cellulaire : on n'affiche que SES antennes.
    private var resolvedSim: (market: String, operatorKey: String)?
    private var simResolveInFlight = false
    // Mêmes mécanismes que le speedtest normal : Live Activity + assertion
    // d'arrière-plan pour enchaîner les tests écran verrouillé.
    private let liveActivity = SpeedtestLiveActivityController()
    private var background = BackgroundTaskScope()

    init(services: AppServices) { self.services = services }

    func onAppear() {
        isVPNActive = VPNDetector.isActive()
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

    func onDisappear() {
        stop()
        services.location.onLocationUpdate = nil
    }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        accumulator = ContinuousSessionAccumulator()
        summary = nil
        testCount = 0
        liveMbps = 0
        livePhase = .idle
        isRunning = true
        statusLabel = "Démarrage…"
        services.location.startTracking()
        UIApplication.shared.isIdleTimerDisabled = true
        // Assertion d'arrière-plan + Live Activity : enchaîne les tests écran
        // verrouillé et affiche la progression sur l'écran de verrouillage.
        background.begin(name: "drivetest")
        liveActivity.start(serverName: "SignalQuest", network: services.networkPath.status.displayName, runIndex: 1, runTotal: 0)
        sessionTask = Task { await runLoop() }
    }

    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        if isRunning {
            services.location.stopTracking()
            UIApplication.shared.isIdleTimerDisabled = false
            liveActivity.cancel()
            background.end()
            statusLabel = "Arrêté"
        }
        isRunning = false
        liveMbps = 0
        livePhase = .idle
    }

    // MARK: Position / antennes / secteur

    private func apply(coordinate: CLLocationCoordinate2D) {
        userLocation = coordinate
        appendTrace(coordinate)
        recomputeNearest()
        Task { await refreshAntennasIfNeeded(around: coordinate) }
    }

    private func appendTrace(_ coordinate: CLLocationCoordinate2D) {
        if let last = trace.last {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            if moved < 8 { return } // ignore le bruit GPS sous 8 m
        }
        trace.append(coordinate)
        if trace.count > traceCap { trace.removeFirst(trace.count - traceCap) }
    }

    private func recomputeNearest() {
        guard let user = userLocation,
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
        let market = resolvedSim?.market ?? MapMarketStore.lastMarket() ?? MapMarketStore.localeMarketCode()
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

        guard let operatorKey, let entry, entry.operatorEntry(forKey: operatorKey) != nil else { return }
        let market = entry.marketCode.isEmpty ? entry.code : entry.marketCode
        resolvedSim = (market, operatorKey)
        simOperatorLabel = entry.operatorEntry(forKey: operatorKey)?.shortLabel ?? operatorKey
    }

    // MARK: Boucle speedtest continue

    private func runLoop() async {
        while !Task.isCancelled {
            testCount += 1
            errorMessage = nil
            statusLabel = "Test \(testCount) en cours…"
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
            // Les valeurs (ping/DL/UL) RESTENT affichées ; elles ne se réinitialisent
            // qu'au démarrage du test suivant (dans runOneTest).
            liveMbps = 0
            if Task.isCancelled { break }
            // Renouvelle l'assertion d'arrière-plan entre deux tests (écran verrouillé).
            background.renew(name: "drivetest")
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
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
        try? await services.speedtest.save(measured, streams: settings.streams, publishToMap: publishToMap())
        // Valeurs finales du test (restent affichées jusqu'au test suivant).
        livePhaseFinalize(measured)
        // Affiche le résultat de ce test dans la Live Activity.
        liveActivity.update(
            phaseLabel: "Test \(index) terminé",
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
            phaseLabel: "Test \(testIndex) · \(Self.phaseLabel(live.phase))",
            downloadMbps: liveDownload,
            uploadMbps: liveUpload,
            pingMs: livePing,
            progress: live.fraction,
            runIndex: testIndex, runTotal: 0
        )
    }

    private static func phaseLabel(_ phase: SpeedtestPhase) -> String {
        switch phase {
        case .idle: return "Prêt"
        case .ping: return "Ping"
        case .download: return "Téléchargement"
        case .upload: return "Envoi"
        case .saving: return "Enregistrement"
        case .finished: return "Terminé"
        case .failed: return "Échec"
        }
    }

    private func makeSettings() -> SpeedtestRunSettings {
        let defaults = UserDefaults.standard
        let duration = (defaults.object(forKey: "speedtest_duration_seconds") as? Int) ?? 10
        let streams = (defaults.object(forKey: "speedtest_streams") as? Int) ?? 16
        let reliability = (defaults.object(forKey: "speedtest_reliability_mode") as? Bool) ?? true
        let target = SpeedtestDownloadTarget(rawValue: defaults.string(forKey: "speedtest_download_target") ?? "") ?? .awsCloudFront
        return SpeedtestRunSettings(
            downloadTarget: target,
            durationSeconds: min(max(duration, 5), 30),
            streams: min(max(streams, 1), 16),
            reliabilityMode: reliability
        )
    }

    private func publishToMap() -> Bool {
        // Sous VPN : jamais de publication carte (opérateur du tunnel non fiable).
        guard !VPNDetector.isActive() else { return false }
        return (UserDefaults.standard.object(forKey: "speedtest_publish_to_map") as? Bool) ?? false
    }
}

struct DriveTestView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: DriveTestViewModel
    @State private var selectedAntenna: AntennaSite?

    init(services: AppServices) {
        _model = StateObject(wrappedValue: DriveTestViewModel(services: services))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapLayer
                .ignoresSafeArea()
            controlPanel
                .padding(SQSpace.md)
        }
        .navigationTitle("Drive Test")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
        // Détails antenne au tap — la session speedtest continue en arrière-plan.
        .sheet(item: $selectedAntenna) { site in
            AntennaDetailSheet(
                site: site,
                market: model.antennaDetailMarket,
                operatorName: model.antennaDetailOperator,
                service: services.antennas
            )
        }
    }

    @ViewBuilder
    private var mapLayer: some View {
#if canImport(MapLibre)
        DriveTestMapView(
            antennas: model.antennas,
            trace: model.trace,
            highlightedSiteId: model.nearestSiteId,
            userLocation: model.userLocation,
            colorScheme: colorScheme,
            onSelectSite: { selectedAntenna = $0 }
        )
#else
        SQColor.bg
#endif
    }

    private var controlPanel: some View {
        VStack(spacing: SQSpace.sm + 2) {
            if model.isVPNActive {
                VPNWarningBanner(message: "VPN actif : opérateur non détectable, ces tests ne seront pas publiés sur la carte.")
            }
            sectorBanner
            if model.isRunning { liveReadout }
            Divider().overlay(SQColor.separator)
            sessionStats
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(SQColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
            actionButton
        }
        .padding(SQSpace.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private var liveReadout: some View {
        HStack(spacing: SQSpace.sm) {
            ProgressView().controlSize(.small).tint(SQColor.brandRed)
            Text(model.statusLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
            Spacer()
            if model.livePhase == .download || model.livePhase == .upload {
                Text("\(Int(model.liveMbps.rounded())) Mbps")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SQColor.brandRed)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, SQSpace.sm + 2)
        .padding(.vertical, SQSpace.xs + 2)
        .frame(maxWidth: .infinity)
        .background(SQColor.fill.opacity(0.6), in: Capsule())
    }

    private var sectorBanner: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: sectorIcon)
                .font(.title3.weight(.bold))
                .foregroundStyle(sectorColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(sectorTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(SQColor.label)
                if let detail = sectorDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            Spacer()
            if let operatorLabel = model.simOperatorLabel {
                Label(operatorLabel, systemImage: "antenna.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, SQSpace.sm)
                    .padding(.vertical, 4)
                    .background(SQColor.fill, in: Capsule())
                    .foregroundStyle(SQColor.label)
            }
        }
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
            if let summary = model.summary, summary.count > 0 {
                Text("\(summary.count) test\(summary.count > 1 ? "s" : "") · moy. DL \(Int(summary.avgDownload.rounded())) Mbps · ping min \(Int(summary.minPing.rounded())) ms")
                    .font(.caption2)
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
                Text(value).font(.headline.weight(.bold)).foregroundStyle(SQColor.label)
                if let unit { Text(unit).font(.caption2).foregroundStyle(SQColor.labelSecondary) }
            }
            Text(label).font(.caption2).foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionButton: some View {
        if model.isRunning {
            Button { model.stop() } label: {
                Label("Arrêter le drive test", systemImage: "stop.fill")
                    .font(SQType.button)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SQSpace.md)
                    .foregroundStyle(.white)
                    .background(SQColor.danger, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            GradientButton("Démarrer le drive test", systemImage: "play.fill") { model.start() }
        }
    }

    // MARK: Dérivés UI

    private var sectorIcon: String {
        guard model.nearestSite != nil else { return "antenna.radiowaves.left.and.right.slash" }
        return model.inSector ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var sectorColor: Color {
        guard model.nearestSite != nil else { return SQColor.labelSecondary }
        return model.inSector ? .green : .orange
    }

    private var sectorTitle: String {
        guard model.nearestSite != nil else { return "Recherche d'antennes…" }
        return model.inSector ? "Dans le secteur" : "Hors secteur"
    }

    private var sectorDetail: String? {
        guard let distance = model.nearestDistanceMeters else { return nil }
        let distanceText = distance >= 1000 ? String(format: "%.1f km", distance / 1000) : "\(Int(distance)) m"
        if let offset = model.sectorOffsetDegrees {
            return "Antenne la plus proche · \(distanceText) · écart \(Int(offset.rounded()))°"
        }
        return "Antenne la plus proche · \(distanceText)"
    }
}
