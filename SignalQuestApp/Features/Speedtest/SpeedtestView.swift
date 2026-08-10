import SwiftUI
import UIKit
import CoreLocation
import CoreTransferable
import UniformTypeIdentifiers
import os

private let speedtestQALogger = Logger(subsystem: "fr.signalquest.ios", category: "SpeedtestQA")

private struct SpeedtestSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private enum SpeedtestSharePreparation: Equatable {
    case idle
    case rendering(UUID)
}

struct SpeedtestView: View {
    private let guestMode: Bool
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    // Défaut « Auto » : préflight hybride iPerf3 (OVH/Bouygues/Scaleway/MilkyWan)
    // + Cloudflare, le plus rapide gagne.
    @AppStorage("speedtest_download_target") private var downloadTargetRaw = SpeedtestDownloadTarget.hybridAuto.rawValue
    // Défaut 14 s (et non 10) : sur une ligne fibre/5G rapide la rampe TCP/BBR
    // dure quelques secondes ; une fenêtre trop courte sous-évalue le débit
    // (moyenne cumulée plombée par le démarrage). 14 s laisse la mesure se
    // stabiliser sans allonger excessivement le test. Le drive test garde 10 s
    // (résolution spatiale du trajet).
    @AppStorage("speedtest_duration_seconds") private var durationSeconds = 14
    @AppStorage("speedtest_streams") private var streams = 16
    @AppStorage("speedtest_reliability_mode") private var reliabilityMode = true
    /// Serveur LibreSpeed choisi manuellement (hostname). Vide = le plus proche.
    @AppStorage("speedtest_librespeed_host") private var libreSpeedHost = ""
    /// POP iPerf3 choisi dans le catalogue distant (id de catalogue). Persisté à
    /// part de la cible, comme `libreSpeedHost` : la cible dit QUEL moteur, celui-ci
    /// dit LEQUEL de ses serveurs.
    @AppStorage("speedtest_iperf_server_id") private var iperfServerId = ""
    /// Publication sur la carte communautaire publique. Opt-in explicite, mémorisé
    /// localement, et jamais publié sous VPN. La précision publique dépend ensuite
    /// du réglage global de confidentialité côté serveur.
    @AppStorage("speedtest_publish_to_map") private var publishToMap = false
    @AppStorage(MeasurementPrivacySettings.shareExactMeasurementsKey) private var shareExactMeasurements = false
    /// Les choix invités sont volontairement éphémères : chaque nouvelle session
    /// redemande le consentement de publication et de précision.
    @State private var guestPublishToMap = false
    @State private var guestShareExactLocation = false
    /// Nombre de tests enchaînés en rafale (1 = test simple).
    @AppStorage("speedtest_burst_count") private var burstCount = 1
    /// Distance à parcourir entre deux speedtests d'un Drive Test. Espacer par la
    /// distance plutôt que par le temps répartit les mesures le long du trajet
    /// au lieu de les entasser là où l'on roule lentement.
    @AppStorage("speedtest_drive_interval_meters") private var driveIntervalMeters = 500
    /// Plafond de données d'une session Drive Test, en Mo (0 = illimité).
    /// Un test vaut débit × durée : à 300 Mb/s sur 10 s, c'est ~375 Mo. Sans
    /// plafond une session pouvait engloutir des dizaines de gigaoctets.
    @AppStorage("speedtest_drive_data_cap_mb") private var driveDataCapMB = 5_120
    @State private var phase: SpeedtestPhase = .idle
    @State private var result: SpeedtestRunResult?
    @State private var liveProgress = SpeedtestLiveProgress(phase: .idle)
    @State private var liveMbps: Double = 0
    @State private var liveActivity = SpeedtestLiveActivityController()
    @State private var background = BackgroundTaskScope()
    /// Progression d'une rafale (test courant, total) — nil hors rafale.
    /// `total == 0` ⇒ session continue illimitée (drive test).
    @State private var burstProgress: (index: Int, total: Int)?
    @State private var burstSummary: SpeedtestBurstSummary?
    /// Vrai pendant une session continue (∞) : adapte les libellés (pill, résumé).
    @State private var sessionIsContinuous = false
    /// Sentinelle `burstCount` = mode continu illimité (drive test).
    private static let continuousBurst = 0
    @State private var history: [SpeedtestRunResult] = []
    @State private var errorMessage: String?
    /// Échec du MOTEUR de test (≠ échec de synchronisation) : carte dédiée
    /// dont le bouton relance le test au lieu de re-envoyer l'historique.
    @State private var runErrorMessage: String?
    /// Test de l'historique ouvert en fiche détaillée.
    @State private var detailResult: SpeedtestRunResult?
    /// Id serveur du test ouvert : sans lui, pas de publication possible.
    @State private var detailServerId: String?
    @State private var isPublishingDetail = false
    @State private var publishFeedback: String?
    @State private var runTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var showDriveTest = false
    @State private var showLocationPriming = false
    @State private var primingDenied = false
    @State private var currentNetworkStatus: NetworkPathStatus = .unknown
    /// Opérateur résolu par IP (ASN) côté backend — repli quand CoreTelephony ne
    /// renvoie rien (iOS 16.4+). Nul sous VPN (l'IP refléterait le tunnel).
    @State private var detectedOperator: DetectedOperator?
    @State private var runStartConnection: NetworkConnectionKind?
    @State private var runStartNetworkDisplayName: String?
    @State private var networkAbortMessage: String?
    /// VPN actif : on masque la publication carte et on affiche un avertissement
    /// (sous tunnel, l'opérateur réel n'est pas détectable).
    @State private var isVPNActive = false
    @State private var didRunQASpeedtest = false
    // Partage : image pré-rendue dès qu'un résultat arrive, puis présentée via
    // un payload atomique pour éviter les feuilles Apple vides au premier tap.
    @State private var shareURL: URL?
    @State private var sharePayload: SpeedtestSharePayload?
    @State private var sharePreparation: SpeedtestSharePreparation = .idle
    @State private var shareRenderTask: Task<Void, Never>?
    @State private var sharePrerenderTask: Task<Void, Never>?

    init(guestMode: Bool = false) {
        self.guestMode = guestMode
    }

    private var mapPublicationEnabled: Bool {
        guestMode ? guestPublishToMap : publishToMap
    }

    private var exactLocationEnabled: Bool {
        mapPublicationEnabled && (guestMode ? guestShareExactLocation : shareExactMeasurements)
    }

    private var mapPublicationBinding: Binding<Bool> {
        Binding(
            get: { mapPublicationEnabled },
            set: { enabled in
                if guestMode {
                    guestPublishToMap = enabled
                    if !enabled { guestShareExactLocation = false }
                } else {
                    publishToMap = enabled
                }
            }
        )
    }

    private var isPreparingShare: Bool {
        if case .rendering = sharePreparation { return true }
        return false
    }

    /// Opérateur affiché dans le bandeau : priorité au résultat mesuré, puis à
    /// l'API device (CoreTelephony), puis — en cellulaire uniquement — à
    /// l'opérateur résolu par IP côté backend (le FAI WiFi n'a pas sa place ici).
    private var headerOperatorName: String? {
        if let measured = result?.networkOperatorName { return measured }
        if let live = currentNetworkStatus.operatorName { return live }
        // Repli IP : opérateur mobile en cellulaire, FAI en WiFi.
        return detectedOperator?.label
    }

    /// Résout l'opérateur via IP (ASN) côté backend, en transmettant l'état VPN
    /// détecté localement. Silencieux en cas d'échec (repli sur l'API device).
    private func resolveDetectedOperator() async {
        detectedOperator = await services.networkOperator.resolve(viaVpn: VPNDetector.isActive())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SQSpace.xl) {
                header

                if isVPNActive {
                    VPNWarningBanner()
                }

                SignatureSpeedDial(
                    value: gaugeDisplay.value,
                    unit: gaugeDisplay.unit,
                    phaseTitle: phase.dialTitle,
                    phase: phase,
                    completionLabel: dialCompletionLabel
                )
                .frame(maxWidth: .infinity)

                SpeedtestTriMetric(
                    activePhase: phase,
                    progress: liveProgress,
                    result: result
                )

                primaryAction

                if let burstSummary {
                    burstSummaryCard(burstSummary)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if let result {
                    sharePanel(for: result)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    resultDetail(for: result)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if let runErrorMessage {
                    ErrorStateView(title: "Speedtest impossible", message: runErrorMessage) {
                        self.runErrorMessage = nil
                        start()
                    }
                    .transition(.opacity)
                }

                if let errorMessage {
                    ErrorStateView(title: "Speedtest non synchronisé", message: errorMessage) {
                        self.errorMessage = nil
                        Task {
                            await services.speedtest.retryPendingSaves()
                            history = await services.speedtest.history()
                        }
                    }
                    .transition(.opacity)
                }

                historySection
                    // La refonte a supprimé le titre « Historique » : l'ancre
                    // remplace ce libellé pour les tests UI.
                    .accessibilityIdentifier("speedtest.history")
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.huge + SQSpace.huge)
        }
        // Directement sur le ScrollView (avant tout wrap) : rétraction du dock.
        .sqDockAutoMinimize()
        // En mode invité, la barre de navigation du conteneur (« Fermer »,
        // « Mes reçus ») doit rester visible ; sinon l'en-tête custom suffit.
        .toolbar(guestMode ? .automatic : .hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showDriveTest) {
            DriveTestView(services: services)
        }
        // F4 : « Lance un Drive Test » (Siri/Raccourcis) → présente Drive Test
        // une fois l'onglet Speed actif.
        .onReceive(services.router.$pendingDriveTest) { pending in
            if pending {
                showDriveTest = true
                services.router.pendingDriveTest = false
            }
        }
        .signalQuestBackground()
        .sheet(item: $detailResult) { item in
            SpeedtestDetailSheet(
                result: item,
                // Bouton masqué si le test n'a pas de position : on ne cadre
                // pas la carte sur un lieu qu'on ignore.
                onShowOnMap: item.coordinate == nil ? nil : { coordinate in
                    router.pendingMapFocus = coordinate
                    router.selectedTab = .map
                },
                // Publication : uniquement quand elle peut RÉELLEMENT aboutir.
                // Un compte (la route exige une auth), un id serveur mémorisé,
                // une position à cartographier, et pas de VPN (l'opérateur du
                // tunnel n'est pas celui qu'on mesure). Sinon aucun bouton,
                // plutôt qu'un bouton qui échouerait.
                onPublish: canPublish(item) ? { publishDetail(item) } : nil,
                isPublishing: isPublishingDetail
            )
            .task { detailServerId = await services.speedtest.serverId(forClientId: item.id) }
        }
        .alert("Publication", isPresented: Binding(
            get: { publishFeedback != nil },
            set: { if !$0 { publishFeedback = nil } }
        )) {
            Button("OK", role: .cancel) { publishFeedback = nil }
        } message: {
            Text(publishFeedback ?? "")
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showLocationPriming) {
            LocationPrimingSheet(
                isDenied: primingDenied,
                onAllow: { showLocationPriming = false; dispatchConfiguredRun(requestLocation: true) },
                onSkip: { showLocationPriming = false; dispatchConfiguredRun(requestLocation: false) }
            )
            .presentationDetents([.medium])
        }
        .sqAnimation(.snappy(duration: 0.32), value: phase)
        .sqAnimation(.snappy(duration: 0.28), value: result)
        .task {
            // Relecture fraîche de CoreTelephony (opérateur/techno) à l'ouverture
            // de la page, plutôt que le dernier statut publié au démarrage.
            services.networkPath.refreshNow()
            currentNetworkStatus = services.networkPath.status
            isVPNActive = VPNDetector.isActive()
            await resolveDetectedOperator()
            // Catalogue des POPs iPerf3 : rafraîchi ICI et pas pendant un test — le
            // catalogue doit rester figé pour la durée d'une mesure, sinon l'id
            // publié pourrait ne plus correspondre au serveur réellement mesuré.
            // Best-effort : une API injoignable laisse le catalogue précédent.
            await services.iperfCatalog.refreshIfNeeded()
            await services.speedtest.retryPendingSaves()
            history = await services.speedtest.history()
            await runQASpeedtestIfNeeded()
        }
        .onReceive(services.networkPath.$status) { status in
            handleNetworkStatusUpdate(status)
        }
        .onChangeCompat(of: scenePhase) { _, newValue in
            // Le test CONTINUE en arrière-plan (assertion `beginBackgroundTask`).
            // Au retour au premier plan, on resynchronise l'historique au cas où
            // un test/rafale se serait terminé pendant l'absence.
            if newValue == .active { isVPNActive = VPNDetector.isActive() }
            if newValue == .active, runTask == nil {
                Task { history = await services.speedtest.history() }
            }
        }
        .onChangeCompat(of: colorScheme) { _, _ in
            // L'image de partage suit le thème iOS : on la re-rend au changement.
            shareURL = nil
            sharePrerenderTask?.cancel()
            if let result { prerenderShareImage(for: result) }
        }
        .onDisappear {
            shareRenderTask?.cancel()
            sharePrerenderTask?.cancel()
        }
    }

    // MARK: - Header (titre centré + capsule serveur, DA « Crème & Terre cuite »)

    private var header: some View {
        VStack(spacing: SQSpace.sm + 2) {
            ZStack {
                HStack {
                    headerButton(systemImage: "location.north.line.fill", label: "Mode Drive Test") {
                        showDriveTest = true
                    }
                    Spacer()
                    headerButton(systemImage: "slider.horizontal.3", label: "Réglages du test") {
                        showSettings = true
                    }
                }
                Text("Speedtest")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
            }
            SpeedtestServerBar(
                // Opérateur : résultat mesuré → API device → repli IP
                // (cellulaire). Cf. headerOperatorName.
                operatorName: headerOperatorName,
                network: result?.networkDisplayName ?? currentNetworkStatus.displayName,
                // Serveur de download/ping ACTIF. On n'affiche plus le VPS de
                // mesure : l'opérateur prend sa place dans le bandeau.
                server: result?.downloadServerName ?? (isRunning ? liveProgress.serverName : nil) ?? downloadTarget.displayName
            )
            if isRunning, let notice = liveProgress.notice {
                Label(notice, systemImage: "arrow.triangle.swap")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.warning)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
    }

    private func headerButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SQColor.label)
                .frame(width: 44, height: 44)
                .background(SQColor.surface, in: Circle())
                .sqShadowSoft()
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(LocalizedStringKey(label))
    }

    // MARK: - Primary action

    @ViewBuilder
    private var primaryAction: some View {
        VStack(spacing: SQSpace.sm) {
            if let burstProgress {
                burstRunningPill(index: burstProgress.index, total: burstProgress.total)
            }
            if isRunning {
                GradientButton("Arrêter", systemImage: "stop.fill", style: .accent, action: stop)
            } else {
                GradientButton(primaryButtonTitle, systemImage: primaryButtonIcon, action: start)
            }
        }
    }

    private var primaryButtonTitle: String {
        if burstCount == Self.continuousBurst {
            return String(localized: "Lancer en continu")
        }
        if burstCount > 1 {
            return result == nil ? "Lancer la rafale ×\(burstCount)" : "Relancer la rafale ×\(burstCount)"
        }
        return result == nil ? "Lancer le test" : "Relancer le test"
    }

    private var primaryButtonIcon: String? {
        if burstCount == Self.continuousBurst { return "infinity" }
        return burstCount > 1 ? "bolt.fill" : nil
    }

    @ViewBuilder
    private func burstRunningPill(index: Int, total: Int) -> some View {
        HStack(spacing: SQSpace.sm) {
            if total == 0 {
                // Session continue (drive test) : pas de total, progression indéterminée.
                Image(systemName: "infinity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.brandRed)
                Text("Continu · test \(index)")
                    .font(SQFont.body(12, .semibold))
                    .foregroundStyle(SQColor.label)
                ProgressView()
                    .controlSize(.small)
                    .tint(SQColor.brandRed)
            } else {
                Image(systemName: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.brandRed)
                Text("Rafale · test \(index)/\(total)")
                    .font(SQFont.body(12, .semibold))
                    .foregroundStyle(SQColor.label)
                ProgressView(value: Double(index), total: Double(total))
                    .frame(width: 90)
                    .tint(SQColor.brandRed)
            }
        }
        .padding(.horizontal, SQSpace.md).padding(.vertical, SQSpace.sm)
        .background(SQColor.surface, in: Capsule(style: .continuous))
        .sqShadowSoft()
    }

    // MARK: - Share panel (single-tap)

    @ViewBuilder
    private func sharePanel(for result: SpeedtestRunResult) -> some View {
        GradientButton(
            "Partager le résultat",
            systemImage: "square.and.arrow.up",
            isBusy: isPreparingShare,
            style: .secondary
        ) {
            presentShare(for: result)
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
                .presentationDetents([.medium, .large])
        }
    }

    /// Assemble image (pré-rendue si dispo) + texte et présente la feuille de
    /// partage immédiatement. Si l'image n'est pas encore prête, on la rend à la
    /// volée (SpeedtestShareImageRenderer.render est asynchrone), sans bloquer l'UI.
    private func presentShare(for result: SpeedtestRunResult) {
        guard !isPreparingShare else { return }
        let text = SpeedtestShareImageRenderer.shareText(for: result)
        let title = "Speedtest SignalQuest — \(Int(result.downloadAverageMbps.rounded())) Mbps"
        if let url = shareURL {
            sharePayload = SpeedtestSharePayload(items: shareItems(fileURL: url, text: text, title: title))
            return
        }
        sharePreparation = .rendering(result.id)
        shareRenderTask?.cancel()
        shareRenderTask = Task {
            do {
                let url = try await SpeedtestShareImageRenderer.render(result, theme: SpeedtestShareTheme.resolve(colorScheme))
                await MainActor.run {
                    guard self.result?.id == result.id else {
                        self.sharePreparation = .idle
                        return
                    }
                    self.sharePreparation = .idle
                    self.shareURL = url
                    self.sharePayload = SpeedtestSharePayload(items: self.shareItems(fileURL: url, text: text, title: title))
                }
            } catch {
                await MainActor.run {
                    guard self.result?.id == result.id else {
                        self.sharePreparation = .idle
                        return
                    }
                    self.sharePreparation = .idle
                    self.sharePayload = SpeedtestSharePayload(items: [text])
                }
            }
        }
    }

    /// Pré-rend l'image de partage hors du chemin critique du tap, dans le thème
    /// iOS courant.
    private func prerenderShareImage(for result: SpeedtestRunResult) {
        let theme = SpeedtestShareTheme.resolve(colorScheme)
        sharePrerenderTask?.cancel()
        sharePrerenderTask = Task {
            do {
                let url = try await SpeedtestShareImageRenderer.render(result, theme: theme)
                await MainActor.run {
                    if self.result?.id == result.id {
                        self.shareURL = url
                    }
                }
            } catch {
                sqDebugLog("Failed to prerender share image: \(error)")
            }
        }
    }

    private func shareItems(fileURL: URL, text: String, title: String) -> [Any] {
        [ImageAndTextShareItem(fileURL: fileURL, text: text, title: title), text]
    }

    private func resetShareState() {
        shareRenderTask?.cancel()
        sharePrerenderTask?.cancel()
        shareURL = nil
        sharePayload = nil
        sharePreparation = .idle
    }

    // MARK: - Detail card (preserves UI test labels)

    @ViewBuilder
    private func resultDetail(for result: SpeedtestRunResult) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Résultats")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                Spacer()
                Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }

            Rectangle()
                .fill(SQColor.separator)
                .frame(height: 1)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: SQSpace.md), GridItem(.flexible(), spacing: SQSpace.md)], spacing: SQSpace.md) {
                detailItem(label: "Réception moy.", value: speed(result.downloadAverageMbps), highlight: true)
                detailItem(label: "DL max", value: speed(result.downloadMaxMbps), highlight: true)
                detailItem(label: "Envoi moy.", value: speed(result.uploadAverageMbps))
                detailItem(label: "UL max", value: speed(result.uploadMaxMbps))
                detailItem(label: "Ping", value: ms(result.pingMinMs ?? result.pingMs), trailing: result.pingProtocol)
                detailItem(label: "Jitter", value: ms(result.jitterMs))
                detailItem(label: "Ping DL", value: ms(result.pingDlMs))
                detailItem(label: "Jitter DL", value: ms(result.jitterDlMs))
                detailItem(label: "Ping UL", value: ms(result.pingUlMs))
                detailItem(label: "Jitter UL", value: ms(result.jitterUlMs))
                detailItem(label: "Réseau", value: result.networkShareDisplayName)
                // Le ping ET le download sont mesurés contre la même source (le CDN
                // sélectionné, AWS CloudFront par défaut). On affiche donc ce serveur
                // unique au lieu du VPS de session/upload (qui n'est qu'un détail
                // technique et induisait en erreur ici).
                detailItem(label: "Serveur ping + DL", value: result.downloadServerName ?? result.serverName ?? "—")
            }
        }
        .padding(SQSpace.lg + 2)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    private func detailItem(label: String, value: String, trailing: String? = nil, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label))
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(SQFont.display(17, .semibold, relativeTo: .body))
                    .monospacedDigit()
                    .foregroundStyle(highlight ? SQColor.brandRed : SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let trailing {
                    Text(trailing)
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Burst summary

    private func burstSummaryCard(_ s: SpeedtestBurstSummary) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .center) {
                Label(
                    "\(sessionIsContinuous ? "Session continue" : "Rafale") — \(s.count) test",
                    systemImage: sessionIsContinuous ? "infinity" : "bolt.fill"
                )
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                Spacer()
                if s.truncatedAt != nil {
                    Text("arrêtée")
                        .font(SQType.micro)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(SQColor.warningSoft, in: Capsule(style: .continuous))
                        .foregroundStyle(SQColor.warning)
                }
            }
            Rectangle()
                .fill(SQColor.separator)
                .frame(height: 1)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: SQSpace.md), GridItem(.flexible(), spacing: SQSpace.md)], spacing: SQSpace.md) {
                detailItem(label: "Réception moy.", value: speed(s.avgDownload), highlight: true)
                detailItem(label: "DL max", value: speed(s.maxDownload), highlight: true)
                detailItem(label: "Envoi moy.", value: speed(s.avgUpload))
                detailItem(label: "Ping min", value: ms(s.minPing))
            }
        }
        .padding(SQSpace.lg + 2)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
    }

    // MARK: - Réglages Drive Test (cadence + budget de données)

    /// Deux réglages qui n'existaient pas et dont l'absence coûtait cher : la
    /// boucle enchaînait les tests avec 800 ms de pause, sans aucun plafond.
    private var driveTestBudgetSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Drive Test")
                .font(SQFont.archivo(15, .bold))
                .foregroundStyle(SQColor.label)

            VStack(alignment: .leading, spacing: SQSpace.xs) {
                chipRow(
                    title: "Un test tous les",
                    options: [(250, "250 m"), (500, "500 m"), (1_000, "1 km"), (2_000, "2 km")],
                    selection: $driveIntervalMeters
                )
                Text("Les tests s'espacent selon la DISTANCE parcourue, pas le temps : les mesures se répartissent le long du trajet au lieu de s'entasser dans les bouchons. À l'arrêt, « Tester maintenant » force une mesure.")
                    .font(.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: SQSpace.xs) {
                chipRow(
                    title: "Plafond de données",
                    options: [(500, "500 Mo"), (2_000, "2 Go"), (5_120, "5 Go"), (0, "∞")],
                    selection: $driveDataCapMB
                )
                Text("Un speedtest consomme son débit × sa durée : environ 375 Mo à 300 Mb/s sur 10 s. La session s'arrête proprement au plafond et te le dit.")
                    .font(.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Rangée de puces à sélection unique — même grammaire visuelle que « Rafale ».
    private func chipRow(
        title: LocalizedStringKey,
        options: [(value: Int, label: String)],
        selection: Binding<Int>
    ) -> some View {
        HStack {
            Text(title).foregroundStyle(SQColor.label)
            Spacer()
            ForEach(options, id: \.value) { option in
                Button {
                    selection.wrappedValue = option.value
                    Haptics.selection()
                } label: {
                    Text(option.label)
                        .font(.caption.weight(.bold))
                        .frame(minWidth: 44)
                        .padding(.vertical, SQSpace.xs + 3)
                        .background(
                            selection.wrappedValue == option.value ? SQColor.brandRed : SQColor.fill,
                            in: Capsule(style: .continuous)
                        )
                        .foregroundStyle(selection.wrappedValue == option.value ? SQColor.onAccent : SQColor.label)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection.wrappedValue == option.value ? [.isSelected] : [])
            }
        }
    }

    // MARK: - Settings sheet (unchanged behaviour)

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    SQSheetHandle()
                    VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                        Text("Serveur de test")
                            .font(SQFont.archivo(15, .bold))
                            .foregroundStyle(SQColor.label)
                        SpeedtestServerPicker(
                            selection: Binding(
                                get: { downloadTarget },
                                set: { downloadTargetRaw = $0.rawValue }
                            ),
                            libreSpeedHost: $libreSpeedHost,
                            iperfServerId: $iperfServerId
                        )

                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            HStack {
                                Text("Durée").foregroundStyle(SQColor.label)
                                Spacer()
                                Text("\(durationSeconds)s")
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(durationSeconds) },
                                    set: { durationSeconds = Int($0.rounded()).clamped(to: 5...30) }
                                ),
                                in: 5...30,
                                step: 1
                            )
                            .tint(SQColor.brandRed)
                        }

                        // Streams et « mode fiabilité » ne sont plus exposés :
                        // le moteur utilise d'office le multi-stream maximal
                        // (16 DL / 12 UL) avec reprise automatique — les presets
                        // manuels (1×/4×) produisaient des mesures faussement
                        // basses sans bénéfice utilisateur.

                        VStack(alignment: .leading, spacing: SQSpace.xs) {
                            HStack {
                                Text("Rafale")
                                    .foregroundStyle(SQColor.label)
                                Spacer()
                                ForEach([1, 3, 5, 10], id: \.self) { value in
                                    Button {
                                        burstCount = value
                                        Haptics.selection()
                                    } label: {
                                        Text(value == 1 ? "1" : "×\(value)")
                                            .font(.caption.weight(.bold))
                                            .frame(minWidth: 38)
                                            .padding(.vertical, SQSpace.xs + 3)
                                            .background(burstCount == value ? SQColor.brandRed : SQColor.fill, in: Capsule(style: .continuous))
                                            .foregroundStyle(burstCount == value ? SQColor.onAccent : SQColor.label)
                                    }
                                    .buttonStyle(.plain)
                                }
                                // Mode continu illimité (drive test) : sentinelle burstCount == 0.
                                Button {
                                    burstCount = Self.continuousBurst
                                    Haptics.selection()
                                } label: {
                                    Image(systemName: "infinity")
                                        .font(.caption.weight(.bold))
                                        .frame(minWidth: 38)
                                        .padding(.vertical, SQSpace.xs + 3)
                                        .background(burstCount == Self.continuousBurst ? SQColor.brandRed : SQColor.fill, in: Capsule(style: .continuous))
                                        .foregroundStyle(burstCount == Self.continuousBurst ? SQColor.onAccent : SQColor.label)
                                }
                                .buttonStyle(.plain)
                            }
                            Text("Enchaîne plusieurs tests d'affilée. « ∞ » lance un mode continu (drive test) : tests illimités jusqu'à l'arrêt, position suivie en continu, poursuite écran verrouillé.")
                                .font(.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Divider().overlay(SQColor.separator)

                        driveTestBudgetSection

                        Divider().overlay(SQColor.separator)

                        VStack(alignment: .leading, spacing: SQSpace.xs) {
                            Toggle(isOn: mapPublicationBinding) {
                                Text("Publier sur la carte communautaire")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(SQColor.label)
                            }
                            .tint(SQColor.brandRed)
                            // Précision indispensable depuis que le Drive Test
                            // publie systématiquement : sans elle, ce réglage
                            // laisserait croire qu'il couvre AUSSI les trajets.
                            Text(guestMode
                                 ? "Désactivé par défaut et redemandé à chaque visite invitée. La mesure et l’opérateur deviennent publics. Ne concerne pas le Drive Test, qui publie toujours."
                                 : "Désactivé par défaut, et ne concerne que les tests lancés depuis cet écran : un Drive Test publie toujours, c'est sa raison d'être. Si tu l’actives, ta mesure et ton opérateur deviennent publics ; la position reste floutée sauf consentement séparé dans Confidentialité.")
                                .font(.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if guestMode && guestPublishToMap {
                                Toggle("Partager ma position exacte pour ce test", isOn: $guestShareExactLocation)
                                    .font(.subheadline.weight(.semibold))
                                Text("Facultatif et valable uniquement pour ce test. Sans ce choix, le serveur publie une position floutée.")
                                    .font(.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                        }
                    }
                    .padding(SQSpace.lg)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                    .sqShadowCard()
                }
                .padding(SQSpace.lg)
            }
            .signalQuestBackground()
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") { showSettings = false }
                        .tint(SQColor.brandRed)
                }
            }
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - History

    // Fidèle au prototype : les cartes d'historique suivent directement le
    // bouton, sans titre de section (le contexte suffit).
    private var historySection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if history.isEmpty {
                EmptyStateView(title: "Aucun test", message: "Lance ton premier speedtest.", systemImage: "clock")
            } else {
                VStack(spacing: SQSpace.sm + 2) {
                    ForEach(Array(history.enumerated()), id: \.element.id) { _, item in
                        Button {
                            Haptics.selection()
                            detailResult = item
                        } label: {
                            SpeedtestHistoryRow(result: item)
                        }
                        .buttonStyle(SQPressButtonStyle())
                        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .sqShadowSoft()
                        .sqFadeUp()
                        .accessibilityHint("Voir le détail du test")
                    }
                }
            }
        }
    }

    // MARK: - Derived state

    private var isRunning: Bool {
        runTask != nil
    }

    /// Badge sous la valeur du cadran une fois le test terminé : confirme la
    /// publication communautaire quand elle a réellement été demandée (opt-in,
    /// hors VPN, sans erreur de sync), sinon simple confirmation de fin.
    private var dialCompletionLabel: String? {
        guard case .finished = phase else { return nil }
        // N'annoncer « publié sur la carte » que si le test a réellement une position
        // (un test sans coordonnée ne peut PAS être cartographié — TEL-04).
        if errorMessage == nil, mapPublicationEnabled, !isVPNActive, result?.coordinate != nil {
            return String(localized: "publié sur la carte ✓")
        }
        return String(localized: "test terminé ✓")
    }

    private var downloadTarget: SpeedtestDownloadTarget {
        (SpeedtestDownloadTarget(rawValue: downloadTargetRaw) ?? .hybridAuto).migrated
    }

    private var runSettings: SpeedtestRunSettings {
        SpeedtestRunSettings(
            downloadTarget: downloadTarget,
            durationSeconds: durationSeconds.clamped(to: 5...30),
            streams: streams.clamped(to: 1...16),
            reliabilityMode: reliabilityMode,
            libreSpeedHost: libreSpeedHost.isEmpty ? nil : libreSpeedHost,
            iperfServerId: iperfServerId.isEmpty ? nil : iperfServerId
        )
    }

    /// Progression grossière (0→1) par phase, pour la Live Activity.
    private func liveActivityFraction(_ phase: SpeedtestPhase) -> Double {
        switch phase {
        case .ping: return 0.15
        case .download: return 0.5
        case .upload: return 0.85
        case .saving: return 0.95
        case .finished: return 1
        default: return 0.05
        }
    }

    /// Valeur affichée par l'aiguille du cadran. Pendant les phases DL/UL, les
    /// champs `*LiveMbps` portent le débit INSTANTANÉ (fenêtre glissante 1 s,
    /// léger EMA — cf. `SpeedtestLiveSampler`) : l'aiguille suit le réseau en
    /// temps réel. La valeur finale (phases saving/finished) reste la MOYENNE.
    private var gaugeDisplay: (value: Double, unit: String) {
        switch phase {
        case .ping:
            let value = liveProgress.pingLiveMs ?? liveProgress.pingFinalMs ?? result?.pingMinMs ?? result?.pingMs ?? 0
            return (value, "ms")
        case .upload:
            let value = liveProgress.uploadLiveMbps ?? liveProgress.uploadAverageMbps ?? result?.uploadAverageMbps ?? 0
            return (value, "Mbps")
        case .download:
            let value = liveProgress.downloadLiveMbps ?? liveProgress.downloadAverageMbps ?? result?.downloadAverageMbps ?? 0
            return (value, "Mbps")
        case .saving, .finished:
            return (result?.downloadAverageMbps ?? liveMbps, "Mbps")
        default:
            return (0, "Mbps")
        }
    }

    // MARK: - Lifecycle

    private func start() {
        // Priming des permissions : si la localisation n'a jamais été demandée, on
        // explique POURQUOI avant de déclencher le prompt système (cf. audit UX-01).
        if !AppEnvironment.runsSpeedtestQA, services.location.authorizationStatus == .notDetermined {
            primingDenied = false
            showLocationPriming = true
            return
        }
        // ONB-SEC-01 : localisation refusée + publication carte active → proposer un
        // retour vers les Réglages plutôt que de lancer sans position en silence.
        if !AppEnvironment.runsSpeedtestQA, mapPublicationEnabled,
           services.location.authorizationStatus == .denied || services.location.authorizationStatus == .restricted {
            primingDenied = true
            showLocationPriming = true
            return
        }
        let requestLocation = !AppEnvironment.runsSpeedtestQA && (!guestMode || mapPublicationEnabled)
        dispatchConfiguredRun(requestLocation: requestLocation)
    }

    /// Lance le test dans le mode CONFIGURÉ (simple / rafale ×N / continu). Utilisé
    /// aussi par les callbacks du priming localisation, qui appelaient auparavant
    /// `performRun` en dur — ignorant la config rafale/continu au 1er test (UXP-07).
    private func dispatchConfiguredRun(requestLocation: Bool) {
        if burstCount == Self.continuousBurst {
            performContinuousSession(requestLocation: requestLocation)
        } else if burstCount > 1 {
            performBurst(count: burstCount, requestLocation: requestLocation)
        } else {
            performRun(requestLocation: requestLocation)
        }
    }

    /// Exécute UNE mesure complète (ping→download→upload→save), pilote la jauge,
    /// la Live Activity (avec index de rafale) et l'historique. Renvoie le résultat.
    private func executeRun(requestLocation: Bool, runIndex: Int, runTotal: Int) async throws -> SpeedtestRunResult {
        phase = .ping
        result = nil
        resetShareState()
        liveProgress = SpeedtestLiveProgress(phase: .ping)
        liveMbps = 0
        // Relit l'opérateur/techno au moment du test, sans dépendre d'un statut
        // potentiellement mis en cache (carrier CoreTelephony lu à la demande).
        services.networkPath.refreshNow()
        let status = services.networkPath.status
        currentNetworkStatus = status
        isVPNActive = VPNDetector.isActive()
        runStartConnection = status.connection
        runStartNetworkDisplayName = status.displayName
        // Repli opérateur par IP quand l'API device est muette (carrier en
        // cellulaire, FAI en WiFi) : injecté dans le pathStatus pour remonter dans
        // le résultat + l'image de partage.
        await resolveDetectedOperator()
        let runStatus = status.merging(operatorName: detectedOperator?.label)
        let settings = runSettings

        let location: Coordinates?
        if requestLocation {
            let requestedLocation = await services.location.currentLocation()
            location = requestedLocation.map {
                Coordinates(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            }
        } else {
            location = nil
        }
        let measured = try await services.speedtest.run(
            pathStatus: runStatus,
            location: location,
            settings: settings,
            progress: { update in
                Task { @MainActor in
                    phase = update.phase
                    let merged = mergeProgress(current: liveProgress, new: update)
                    liveProgress = merged
                    liveMbps = update.currentMbps
                    liveActivity.update(
                        phaseLabel: liveActivityPhaseLabel(update.phase, runIndex: runIndex, runTotal: runTotal),
                        downloadMbps: merged.downloadAverageMbps ?? merged.downloadLiveMbps ?? (update.phase == .download ? update.currentMbps : 0),
                        uploadMbps: merged.uploadAverageMbps ?? merged.uploadLiveMbps ?? (update.phase == .upload ? update.currentMbps : 0),
                        pingMs: merged.pingFinalMs ?? merged.pingLiveMs ?? 0,
                        progress: liveActivityFraction(update.phase),
                        runIndex: runIndex, runTotal: runTotal
                    )
                }
            }
        )
        try Task.checkCancellation()
        result = measured
        shareURL = nil
        sharePayload = nil
        prerenderShareImage(for: measured)
        liveProgress = SpeedtestLiveProgress(
            phase: .saving,
            currentMbps: measured.downloadAverageMbps,
            downloadAverageMbps: measured.downloadAverageMbps,
            uploadAverageMbps: measured.uploadAverageMbps,
            pingFinalMs: measured.pingMinMs ?? measured.pingMs,
            jitterMs: measured.jitterMs,
            pingProtocol: measured.pingProtocol,
            serverName: measured.serverName
        )
        phase = .saving
        do {
            // Sous VPN : jamais de publication carte (opérateur du tunnel non fiable).
            try await services.speedtest.save(
                measured,
                streams: settings.streams,
                publishToMap: mapPublicationEnabled && !isVPNActive,
                shareExactLocation: exactLocationEnabled && !isVPNActive
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        history = await services.speedtest.history()
        phase = .finished
        liveProgress = SpeedtestLiveProgress(
            phase: .finished,
            currentMbps: measured.downloadAverageMbps,
            fraction: 1,
            downloadAverageMbps: measured.downloadAverageMbps,
            uploadAverageMbps: measured.uploadAverageMbps,
            pingFinalMs: measured.pingMinMs ?? measured.pingMs,
            jitterMs: measured.jitterMs,
            pingProtocol: measured.pingProtocol,
            serverName: measured.serverName
        )
        return measured
    }

    /// La publication n'est proposée que si elle peut aboutir : compte requis
    /// (la route PATCH rejette les invités), id serveur mémorisé à l'envoi,
    /// position à cartographier, et hors VPN.
    private func canPublish(_ result: SpeedtestRunResult) -> Bool {
        !guestMode
            && detailServerId != nil
            && result.coordinate != nil
            && !isVPNActive
    }

    private func publishDetail(_ result: SpeedtestRunResult) {
        guard !isPublishingDetail else { return }
        isPublishingDetail = true
        Task {
            do {
                try await services.speedtest.publishOnMap(
                    clientId: result.id,
                    shareExactLocation: exactLocationEnabled
                )
                Haptics.success()
                publishFeedback = "Test publié sur la carte."
            } catch {
                Haptics.warning()
                publishFeedback = error.localizedDescription
            }
            isPublishingDetail = false
        }
    }

    private func performRun(requestLocation: Bool) {
        Haptics.light()
        errorMessage = nil
        runErrorMessage = nil
        networkAbortMessage = nil
        burstProgress = nil
        burstSummary = nil
        sessionIsContinuous = false
        background.begin(name: "speedtest")
        liveActivity.start(serverName: "SignalQuest", network: services.networkPath.status.displayName)
        runTask = Task {
            do {
                let measured = try await executeRun(requestLocation: requestLocation, runIndex: 1, runTotal: 1)
                logQASpeedtestResult(measured)
                liveActivity.end(
                    downloadMbps: measured.downloadAverageMbps,
                    uploadMbps: measured.uploadAverageMbps ?? 0,
                    pingMs: measured.pingMinMs ?? measured.pingMs ?? 0
                )
                Haptics.success()
            } catch is CancellationError {
                liveActivity.cancel()
                handleCancellation()
            } catch {
                liveActivity.cancel()
                runErrorMessage = error.localizedDescription
                phase = .failed(error.localizedDescription)
                liveProgress = SpeedtestLiveProgress(phase: .failed(error.localizedDescription))
                Haptics.warning()
            }
            background.end()
            runTask = nil
            runStartConnection = nil
            runStartNetworkDisplayName = nil
            networkAbortMessage = nil
            exitAfterQASpeedtestIfNeeded()
        }
    }

    /// Rafale : enchaîne `count` tests, met à jour la Live Activity (« test i/N »)
    /// et continue en arrière-plan tant que le système l'autorise.
    private func performBurst(count: Int, requestLocation: Bool) {
        Haptics.light()
        errorMessage = nil
        runErrorMessage = nil
        networkAbortMessage = nil
        burstSummary = nil
        sessionIsContinuous = false
        let total = max(2, min(count, 20))
        burstProgress = (1, total)
        background.begin(name: "speedtest-burst")
        liveActivity.start(serverName: "SignalQuest", network: services.networkPath.status.displayName, runIndex: 1, runTotal: total)
        runTask = Task {
            var results: [SpeedtestRunResult] = []
            var truncatedAt: Int?
            loop: for index in 1...total {
                burstProgress = (index, total)
                do {
                    // Géolocaliser CHAQUE test de la rafale (pas seulement le 1er) :
                    // sinon les tests 2..N étaient enregistrés/publiés sans position
                    // (TEL-06). currentLocation renvoie le fix récent en cache (peu coûteux).
                    let measured = try await executeRun(requestLocation: requestLocation, runIndex: index, runTotal: total)
                    results.append(measured)
                } catch is CancellationError {
                    truncatedAt = max(0, index - 1)
                    break loop
                } catch {
                    // Un test raté n'interrompt pas la rafale : on note et on continue.
                    errorMessage = error.localizedDescription
                    Haptics.warning()
                }
                if index < total {
                    if shouldStopBurstForBackgroundLimit() {
                        truncatedAt = index
                        break loop
                    }

                    if scenePhase == .active {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                    } else {
                        background.renew(name: "speedtest-burst")
                    }
                }
            }
            let summary = SpeedtestBurstSummary(results: results, truncatedAt: truncatedAt)
            if Task.isCancelled {
                if !results.isEmpty { burstSummary = summary }
                liveActivity.cancel()
                handleCancellation()
            } else {
                burstSummary = summary
                phase = .finished
                liveActivity.end(
                    downloadMbps: summary.avgDownload,
                    uploadMbps: summary.avgUpload,
                    pingMs: summary.minPing,
                    runIndex: total, runTotal: total
                )
                Haptics.success()
            }
            background.end()
            burstProgress = nil
            runTask = nil
            runStartConnection = nil
            runStartNetworkDisplayName = nil
            networkAbortMessage = nil
            exitAfterQASpeedtestIfNeeded()
        }
    }

    /// Mode continu illimité (drive test) : enchaîne les speedtests jusqu'à l'arrêt
    /// manuel, en re-géolocalisant à chaque test. Le suivi de localisation continu
    /// maintient l'app active écran verrouillé. Agrège la session en O(1) (sans
    /// retenir chaque résultat) et empêche la veille de l'écran au premier plan.
    private func performContinuousSession(requestLocation: Bool) {
        Haptics.light()
        errorMessage = nil
        runErrorMessage = nil
        networkAbortMessage = nil
        burstSummary = nil
        sessionIsContinuous = true
        burstProgress = (1, 0) // total = 0 → session illimitée
        background.begin(name: "speedtest-continuous")
        if requestLocation { services.location.startTracking() }
        UIApplication.shared.isIdleTimerDisabled = true
        liveActivity.start(serverName: "SignalQuest", network: services.networkPath.status.displayName, runIndex: 1, runTotal: 0)
        runTask = Task {
            var accumulator = ContinuousSessionAccumulator()
            var index = 0
            loop: while !Task.isCancelled {
                index += 1
                burstProgress = (index, 0)
                do {
                    // Drive test : on re-géolocalise à CHAQUE test (pas seulement le 1er).
                    let measured = try await executeRun(requestLocation: requestLocation, runIndex: index, runTotal: 0)
                    accumulator.add(measured)
                    burstSummary = accumulator.summary(truncatedAt: nil)
                } catch is CancellationError {
                    break loop
                } catch {
                    // Un test raté n'interrompt pas la session : on note et on continue.
                    errorMessage = error.localizedDescription
                    Haptics.warning()
                }
                // Pause entre tests ; en arrière-plan le suivi de localisation garde
                // l'app active (on renouvelle l'assertion par sécurité).
                if scenePhase == .active {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                } else {
                    background.renew(name: "speedtest-continuous")
                }
            }
            if accumulator.count > 0 {
                burstSummary = accumulator.summary(truncatedAt: nil)
            }
            // Une session continue se termine toujours par un arrêt (manuel/réseau).
            liveActivity.cancel()
            handleCancellation()
            services.location.stopTracking()
            UIApplication.shared.isIdleTimerDisabled = false
            background.end()
            burstProgress = nil
            runTask = nil
            runStartConnection = nil
            runStartNetworkDisplayName = nil
            networkAbortMessage = nil
            exitAfterQASpeedtestIfNeeded()
        }
    }

    private func shouldStopBurstForBackgroundLimit() -> Bool {
        guard scenePhase != .active else { return false }
        let remaining = background.remainingSeconds
        guard remaining.isFinite else { return false }
        return remaining < 6
    }

    private func handleCancellation() {
        if let networkAbortMessage {
            errorMessage = networkAbortMessage
            phase = .failed(networkAbortMessage)
        } else {
            phase = .idle
            liveProgress = SpeedtestLiveProgress(phase: .idle)
        }
    }

    private func liveActivityPhaseLabel(_ phase: SpeedtestPhase, runIndex: Int, runTotal: Int) -> String {
        runTotal > 1 ? "Test \(runIndex)/\(runTotal) · \(phase.displayTitle)" : phase.displayTitle
    }

    private func stop() {
        runTask?.cancel()
        runTask = nil
        runStartConnection = nil
        runStartNetworkDisplayName = nil
        networkAbortMessage = nil
        phase = .idle
        liveProgress = SpeedtestLiveProgress(phase: .idle)
    }

    private func handleNetworkStatusUpdate(_ newStatus: NetworkPathStatus) {
        let previousStatus = currentNetworkStatus
        currentNetworkStatus = newStatus
        guard isRunning,
              let runStartConnection,
              runStartConnection.isWiFiCellularBoundaryChange(to: newStatus.connection) else {
            return
        }
        abortForNetworkChange(
            from: runStartNetworkDisplayName ?? previousStatus.displayName,
            to: newStatus.displayName
        )
    }

    private func abortForNetworkChange(from previousNetwork: String, to newNetwork: String) {
        let message = "Speedtest arrêté : changement de réseau détecté (\(previousNetwork) -> \(newNetwork)). Relance le test pour mesurer une connexion stable."
        networkAbortMessage = message
        errorMessage = message
        runTask?.cancel()
        runTask = nil
        runStartConnection = nil
        runStartNetworkDisplayName = nil
        phase = .failed(message)
        liveProgress = SpeedtestLiveProgress(phase: .failed(message))
        Haptics.warning()
    }

    @MainActor
    private func runQASpeedtestIfNeeded() async {
        guard AppEnvironment.runsSpeedtestQA, !didRunQASpeedtest else { return }
        didRunQASpeedtest = true
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        currentNetworkStatus = services.networkPath.status
        speedtestQALogger.notice("SQ_QA_SPEEDTEST_START network=\(currentNetworkStatus.displayName, privacy: .public)")
        start()
    }

    private func logQASpeedtestResult(_ result: SpeedtestRunResult) {
        guard AppEnvironment.runsSpeedtestQA else { return }
        let uploadAverage = result.uploadAverageMbps ?? 0
        let uploadMax = result.uploadMaxMbps ?? 0
        let pingMin = result.pingMinMs ?? 0
        let pingAverage = result.pingMs ?? 0
        let jitter = result.jitterMs ?? 0
        let line = "SQ_QA_SPEEDTEST_RESULT dl_avg=\(result.downloadAverageMbps) dl_max=\(result.downloadMaxMbps) ul_avg=\(uploadAverage) ul_max=\(uploadMax) ping_min=\(pingMin) ping_avg=\(pingAverage) jitter=\(jitter) network=\(result.networkDisplayName)"
        speedtestQALogger.notice("\(line, privacy: .public)")
    }

    private func exitAfterQASpeedtestIfNeeded() {
        guard AppEnvironment.runsSpeedtestQA, AppEnvironment.exitsAfterSpeedtestQA else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            exit(0)
        }
    }

    private func mergeProgress(current: SpeedtestLiveProgress, new: SpeedtestLiveProgress) -> SpeedtestLiveProgress {
        SpeedtestLiveProgress(
            phase: new.phase,
            currentMbps: new.currentMbps,
            fraction: new.fraction,
            downloadLiveMbps: new.downloadLiveMbps ?? current.downloadLiveMbps,
            downloadAverageMbps: new.downloadAverageMbps ?? current.downloadAverageMbps,
            uploadLiveMbps: new.uploadLiveMbps ?? current.uploadLiveMbps,
            uploadAverageMbps: new.uploadAverageMbps ?? current.uploadAverageMbps,
            pingLiveMs: new.pingLiveMs ?? current.pingLiveMs,
            pingFinalMs: new.pingFinalMs ?? current.pingFinalMs,
            jitterMs: new.jitterMs ?? current.jitterMs,
            pingProtocol: new.pingProtocol ?? current.pingProtocol,
            pingSampleCount: new.pingSampleCount > 0 ? new.pingSampleCount : current.pingSampleCount,
            pingSampleTarget: new.pingSampleTarget > 0 ? new.pingSampleTarget : current.pingSampleTarget,
            serverName: new.serverName ?? current.serverName,
            notice: new.notice ?? current.notice
        )
    }
}

// MARK: - Burst summary model

// MARK: - Server bar (capsule sous le titre)

// MARK: - Cadran signature (arc 270° qualité DA danger → ambre → olive)

// MARK: - Cartes métriques (Ping / Réception / Envoi)

// MARK: - History row (compact)

// MARK: - Formatting helpers

private func speed(_ value: Double?) -> String {
    guard let value, value.isFinite, value > 0 else { return "—" }
    if value >= 100 {
        return "\(Int(value.rounded())) Mbps"
    }
    return "\(String(format: "%.1f", value)) Mbps"
}

private func ms(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return "\(Int(value.rounded())) ms"
}

// MARK: - Phase extensions

// MARK: - Server picker (iPerf3 OVH + Bouygues)

// MARK: - Comparable helper

