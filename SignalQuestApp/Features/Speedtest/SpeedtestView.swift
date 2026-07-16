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
    // Défaut « Auto » : préflight Cloudflare/AWS/VPS, le plus rapide gagne.
    @AppStorage("speedtest_download_target") private var downloadTargetRaw = SpeedtestDownloadTarget.hybridAuto.rawValue
    @AppStorage("speedtest_duration_seconds") private var durationSeconds = 10
    @AppStorage("speedtest_streams") private var streams = 16
    @AppStorage("speedtest_reliability_mode") private var reliabilityMode = true
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
                onAllow: { showLocationPriming = false; performRun(requestLocation: true) },
                onSkip: { showLocationPriming = false; performRun(requestLocation: false) }
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
        .accessibilityLabel(label)
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
            return "Lancer en continu"
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
                print("Failed to prerender share image: \(error)")
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
                detailItem(label: "DL moyen", value: speed(result.downloadAverageMbps), highlight: true)
                detailItem(label: "DL max", value: speed(result.downloadMaxMbps), highlight: true)
                detailItem(label: "UL moyen", value: speed(result.uploadAverageMbps))
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
            Text(label)
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
                        .foregroundStyle(SQColor.labelTertiary)
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
                    "\(sessionIsContinuous ? "Session continue" : "Rafale") — \(s.count) test\(s.count > 1 ? "s" : "")",
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
                detailItem(label: "DL moyen", value: speed(s.avgDownload), highlight: true)
                detailItem(label: "DL max", value: speed(s.maxDownload), highlight: true)
                detailItem(label: "UL moyen", value: speed(s.avgUpload))
                detailItem(label: "Ping min", value: ms(s.minPing))
            }
        }
        .padding(SQSpace.lg + 2)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .sqShadowCard()
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
                            )
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

                        VStack(alignment: .leading, spacing: SQSpace.xs) {
                            Toggle(isOn: mapPublicationBinding) {
                                Text("Publier sur la carte communautaire")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(SQColor.label)
                            }
                            .tint(SQColor.brandRed)
                            Text(guestMode
                                 ? "Désactivé par défaut et redemandé à chaque visite invitée. La mesure et l’opérateur deviennent publics."
                                 : "Désactivé par défaut. Si tu l’actives, ta mesure et ton opérateur deviennent publics ; la position reste floutée sauf consentement séparé dans Confidentialité.")
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
        if errorMessage == nil, mapPublicationEnabled, !isVPNActive {
            return "publié sur la carte ✓"
        }
        return "test terminé ✓"
    }

    private var downloadTarget: SpeedtestDownloadTarget {
        (SpeedtestDownloadTarget(rawValue: downloadTargetRaw) ?? .hybridAuto).migrated
    }

    private var runSettings: SpeedtestRunSettings {
        SpeedtestRunSettings(
            downloadTarget: downloadTarget,
            durationSeconds: durationSeconds.clamped(to: 5...30),
            streams: streams.clamped(to: 1...16),
            reliabilityMode: reliabilityMode
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
                    let measured = try await executeRun(requestLocation: requestLocation && index == 1, runIndex: index, runTotal: total)
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
        print("SQ_QA_SPEEDTEST_START network=\(currentNetworkStatus.displayName)")
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
        print(line)
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

/// Agrégat d'une rafale de tests (moyennes + extrêmes).
struct SpeedtestBurstSummary {
    let count: Int
    let avgDownload: Double
    let maxDownload: Double
    let avgUpload: Double
    let minPing: Double
    /// Index où la rafale a été tronquée (arrière-plan / annulation), sinon nil.
    let truncatedAt: Int?

    init(results: [SpeedtestRunResult], truncatedAt: Int? = nil) {
        count = results.count
        let downloads = results.map { $0.downloadAverageMbps }
        avgDownload = downloads.isEmpty ? 0 : downloads.reduce(0, +) / Double(downloads.count)
        maxDownload = downloads.max() ?? 0
        let uploads = results.compactMap { $0.uploadAverageMbps }
        avgUpload = uploads.isEmpty ? 0 : uploads.reduce(0, +) / Double(uploads.count)
        let pings = results.compactMap { $0.pingMinMs ?? $0.pingMs }
        minPing = pings.min() ?? 0
        self.truncatedAt = truncatedAt
    }

    /// Init memberwise — alimenté par un accumulateur O(1) (mode continu illimité)
    /// pour ne pas retenir tous les résultats en mémoire pendant une longue session.
    init(count: Int, avgDownload: Double, maxDownload: Double, avgUpload: Double, minPing: Double, truncatedAt: Int?) {
        self.count = count
        self.avgDownload = avgDownload
        self.maxDownload = maxDownload
        self.avgUpload = avgUpload
        self.minPing = minPing
        self.truncatedAt = truncatedAt
    }
}

/// Accumulateur O(1) pour une session de rafale continue : agrège les moyennes /
/// max / min au fil des tests sans conserver chaque `SpeedtestRunResult`.
/// Internal (pas `private`) : partagé avec le mode Drive Test.
struct ContinuousSessionAccumulator {
    private(set) var count = 0
    private var sumDownload = 0.0
    private var maxDownload = 0.0
    private var sumUpload = 0.0
    private var uploadCount = 0
    private var minPing = Double.greatestFiniteMagnitude

    mutating func add(_ result: SpeedtestRunResult) {
        count += 1
        sumDownload += result.downloadAverageMbps
        maxDownload = max(maxDownload, result.downloadAverageMbps)
        if let upload = result.uploadAverageMbps {
            sumUpload += upload
            uploadCount += 1
        }
        if let ping = result.pingMinMs ?? result.pingMs {
            minPing = min(minPing, ping)
        }
    }

    func summary(truncatedAt: Int?) -> SpeedtestBurstSummary {
        SpeedtestBurstSummary(
            count: count,
            avgDownload: count == 0 ? 0 : sumDownload / Double(count),
            maxDownload: maxDownload,
            avgUpload: uploadCount == 0 ? 0 : sumUpload / Double(uploadCount),
            minPing: minPing == .greatestFiniteMagnitude ? 0 : minPing,
            truncatedAt: truncatedAt
        )
    }
}

// MARK: - Server bar (capsule sous le titre)

private struct SpeedtestServerBar: View {
    /// Opérateur mobile (Orange, SFR…) lu via CoreTelephony. nil/vide en WiFi ou
    /// quand l'API ne le renvoie pas (placeholder iOS 16.4+).
    let operatorName: String?
    /// Technologie d'accès (5G NSA, 4G, WiFi…).
    let network: String
    /// Serveur de download/ping actif (CDN AWS CloudFront par défaut).
    let server: String

    /// « Orange · 5G NSA · CloudFront Paris » — l'opérateur quand il est connu.
    private var label: String {
        var parts: [String] = []
        if let op = operatorName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !op.isEmpty, op != network {
            parts.append(op)
        }
        parts.append(network)
        parts.append(server)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(SQColor.success)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(label)
                .font(SQFont.body(13, .medium))
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, SQSpace.md + 2)
        .background(SQColor.surface, in: Capsule(style: .continuous))
        .sqShadowSoft()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Réseau : \(label)")
    }
}

// MARK: - Cadran signature (arc 270° qualité DA danger → ambre → olive)

private struct SignatureSpeedDial: View {
    let value: Double
    let unit: String
    let phaseTitle: String
    let phase: SpeedtestPhase
    /// Badge affiché sous la valeur une fois le test terminé
    /// (« publié sur la carte ✓ »…). nil tant qu'aucun résultat n'est acquis.
    let completionLabel: String?

    private let arcSpan: Double = 0.75   // 270°, départ 135°
    private let lineWidth: CGFloat = 18
    private let diameter: CGFloat = 288
    /// Rayon de la ligne médiane de l'arc, des graduations et des libellés.
    private var arcRadius: CGFloat { 100 }
    private var tickInnerRadius: CGFloat { arcRadius + lineWidth / 2 + 5 }
    private var labelRadius: CGFloat { arcRadius + lineWidth / 2 + 22 }

    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var isLatency: Bool { unit == "ms" }

    /// Fraction de remplissage de l'arc : échelle log pour les débits
    /// (1 Gbps = plein), inverse pour la latence (0 ms = plein).
    private var normalized: Double {
        guard value > 0 else { return 0 }
        if isLatency {
            return max(0, min(1, (Self.latencyScaleMax - value) / Self.latencyScaleMax))
        }
        return max(0, min(1, log10(value) / 3))
    }

    /// Latence : 0 ms = plein, 120 ms = vide.
    private static let latencyScaleMax: Double = 120

    /// Graduations de l'échelle : décades 1/10/100/1 G en débit, paliers de
    /// 30 ms en latence. Sans elles, le remplissage de l'arc n'est pas lisible.
    private struct DialTick {
        let fraction: Double
        let label: String?
    }

    private var ticks: [DialTick] {
        if isLatency {
            // 120 → 0 ms (moins = mieux) ; un libellé sur deux pour aérer.
            return stride(from: 0.0, through: 120.0, by: 30.0).map { ms in
                DialTick(
                    fraction: (Self.latencyScaleMax - ms) / Self.latencyScaleMax,
                    label: ms.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(ms))" : nil
                )
            }
        }
        // Débits : décades libellées + graduations fines 2/5 par décade.
        var result: [DialTick] = []
        for decade in 0...3 {
            let base = pow(10.0, Double(decade))
            result.append(DialTick(fraction: Double(decade) / 3, label: Self.speedLabel(base)))
            guard decade < 3 else { continue }
            for step in [2.0, 5.0] {
                result.append(DialTick(fraction: log10(base * step) / 3, label: nil))
            }
        }
        return result
    }

    private static func speedLabel(_ value: Double) -> String {
        value >= 1_000 ? "1 G" : "\(Int(value))"
    }

    /// Position d'une graduation sur l'arc (0° = 3 h, sens horaire).
    private func point(fraction: Double, radius: CGFloat) -> CGPoint {
        let degrees = 135 + 270 * fraction
        let radians = degrees * .pi / 180
        return CGPoint(x: cos(radians) * radius, y: sin(radians) * radius)
    }

    /// Couleur de qualité (brique → ambre → olive) selon le ratio de remplissage.
    private var qualityColor: Color {
        let theme = SpeedtestShareTheme.resolve(colorScheme)
        return SpeedtestQualityPalette.color(forRatio: normalized, stops: theme.qualityStops)
    }

    /// Mesure en cours (latence/téléchargement/envoi/synchro) : badge pulsé.
    private var isRunning: Bool {
        switch phase {
        case .ping, .download, .upload, .saving: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            scaleTicks

            // Piste : assez contrastée pour qu'on lise la part restante
            // (l'ancien surfaceMuted disparaissait sur le fond crème).
            Circle()
                .trim(from: 0, to: arcSpan)
                .stroke(SQColor.labelTertiary.opacity(0.28), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: arcRadius * 2, height: arcRadius * 2)

            // Arc actif teinté par la qualité (brique → ambre → olive).
            // Teinte pleine : le dégradé angulaire laissait une couture visible
            // au départ de l'arc. L'epsilon garde un point quand la valeur est 0.
            Circle()
                .trim(from: 0, to: max(0.0006, arcSpan * normalized))
                .stroke(qualityColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: arcRadius * 2, height: arcRadius * 2)
                .shadow(color: qualityColor.opacity(colorScheme == .dark ? 0.5 : 0.3), radius: 10, x: 0, y: 0)
                .sqAnimation(.snappy(duration: 0.32), value: normalized)

            arcTip

            // Cœur : crème de la DA (le blanc pur tranchait), cerclé et posé —
            // sinon le disque se lit comme un trou dans le fond.
            Circle()
                .fill(SQColor.surface)
                .overlay(Circle().strokeBorder(SQColor.separator.opacity(0.7), lineWidth: 1))
                .sqShadowSoft()
                .frame(width: (arcRadius - lineWidth / 2 - 6) * 2, height: (arcRadius - lineWidth / 2 - 6) * 2)

            VStack(spacing: 1) {
                Text(phaseTitle)
                    .font(SQFont.body(12, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(formattedValue)
                    .font(SQFont.display(58, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text(unit)
                    .font(SQFont.body(14, .medium))
                    .foregroundStyle(SQColor.labelSecondary)
                if isRunning {
                    runningBadge
                } else if let completionLabel {
                    dialBadge(completionLabel, color: SQColor.success, background: SQColor.successSoft)
                }
            }
            .padding(.horizontal, SQSpace.xxl)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Graduations + libellés de décade : rendent l'échelle log lisible.
    private var scaleTicks: some View {
        ZStack {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                let isMajor = tick.label != nil
                let reached = normalized >= tick.fraction - 0.001
                Capsule(style: .continuous)
                    .fill(reached ? qualityColor.opacity(0.55) : SQColor.labelTertiary.opacity(0.35))
                    .frame(width: isMajor ? 2 : 1.5, height: isMajor ? 9 : 5)
                    .offset(y: -(tickInnerRadius + (isMajor ? 4.5 : 2.5)))
                    .rotationEffect(.degrees(135 + 270 * tick.fraction + 90))

                if let label = tick.label {
                    let position = point(fraction: tick.fraction, radius: labelRadius)
                    Text(label)
                        .font(SQFont.body(10, .semibold))
                        .foregroundStyle(reached ? SQColor.labelSecondary : SQColor.labelTertiary)
                        .monospacedDigit()
                        .offset(x: position.x, y: position.y)
                }
            }
        }
        .sqAnimation(.snappy(duration: 0.32), value: normalized)
        .accessibilityHidden(true)
    }

    /// Pointe de l'arc : petit repère crème posé sur le bout, façon point final
    /// du graphe de partage. Masqué sous 2 % — un blob isolé au départ de
    /// chaque phase se lisait comme une anomalie.
    @ViewBuilder
    private var arcTip: some View {
        if normalized > 0.02 {
            let position = point(fraction: normalized, radius: arcRadius)
            Circle()
                .fill(SQColor.onAccent)
                .frame(width: 6, height: 6)
                .offset(x: position.x, y: position.y)
                .sqAnimation(.snappy(duration: 0.32), value: normalized)
                .accessibilityHidden(true)
        }
    }

    /// Mesure en cours : point pulsé teinté qualité sur fond neutre. Le libellé
    /// reste sobre — le teinter virait au rouge au démarrage de chaque phase
    /// (débit encore bas) et annonçait « mauvais » à tort.
    private var runningBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(qualityColor)
                .frame(width: 5, height: 5)
                .opacity(pulsing && !reduceMotion ? 0.25 : 1)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                    value: pulsing
                )
            Text("en cours")
                .font(SQFont.body(11, .semibold))
                .foregroundStyle(SQColor.labelSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(SQColor.fill, in: Capsule(style: .continuous))
        .padding(.top, 5)
        .onAppear { pulsing = true }
        .onDisappear { pulsing = false }
    }

    private func dialBadge(_ text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(SQFont.body(11, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(background, in: Capsule(style: .continuous))
            .padding(.top, 5)
    }

    private var accessibilityText: String {
        var parts = ["\(phaseTitle) \(formattedValue) \(unit)"]
        if isRunning {
            parts.append("mesure en cours")
        } else if let completionLabel {
            parts.append(completionLabel)
        }
        return parts.joined(separator: ", ")
    }

    private var formattedValue: String {
        guard value > 0, value.isFinite else { return "—" }
        if unit == "ms" || value >= 100 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", value)
    }
}

// MARK: - Cartes métriques (Ping / Réception / Envoi)

private struct SpeedtestTriMetric: View {
    let activePhase: SpeedtestPhase
    let progress: SpeedtestLiveProgress
    let result: SpeedtestRunResult?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: SQSpace.md) {
            cell(
                title: "Ping",
                value: pingText,
                state: state(for: .ping),
                quality: pingQuality
            )
            cell(
                title: "Réception",
                value: mbpsText(downloadMbps),
                state: state(for: .download),
                quality: mbpsQuality(downloadMbps)
            )
            cell(
                title: "Envoi",
                value: mbpsText(uploadMbps),
                state: state(for: .upload),
                quality: mbpsQuality(uploadMbps)
            )
        }
    }

    private var qualityStops: [Color] {
        SpeedtestShareTheme.resolve(colorScheme).qualityStops
    }

    private var pingMsValue: Double? {
        let value = result?.pingMinMs ?? progress.pingFinalMs ?? progress.pingLiveMs
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private var downloadMbps: Double? {
        let value = result?.downloadAverageMbps ?? progress.downloadAverageMbps ?? progress.downloadLiveMbps
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private var uploadMbps: Double? {
        let value = result?.uploadAverageMbps ?? progress.uploadAverageMbps ?? progress.uploadLiveMbps
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private var pingText: String {
        guard let value = pingMsValue else { return "—" }
        return "\(Int(value.rounded())) ms"
    }

    private var pingQuality: Color? {
        guard let ms = pingMsValue else { return nil }
        let ratio = max(0, min(1, (120 - ms) / 120))
        return SpeedtestQualityPalette.color(forRatio: ratio, stops: qualityStops)
    }

    private func mbpsQuality(_ mbps: Double?) -> Color? {
        guard let mbps, mbps > 0 else { return nil }
        let ratio = max(0, min(1, log10(mbps) / 3))
        return SpeedtestQualityPalette.color(forRatio: ratio, stops: qualityStops)
    }

    /// Débit sans unité (« 403 », « 38.5 ») — le « Mbps » est porté par le cadran.
    private func mbpsText(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        if value >= 100 { return "\(Int(value.rounded()))" }
        return String(format: "%.1f", value)
    }

    private enum CellState { case pending, active, done }

    private func state(for phase: SpeedtestPhase) -> CellState {
        let target = phase.order
        let current = activePhase.order
        if current > target { return .done }
        if current == target && isLiveTracked(activePhase) { return .active }
        if result != nil { return .done }
        return .pending
    }

    private func isLiveTracked(_ phase: SpeedtestPhase) -> Bool {
        switch phase {
        case .ping, .download, .upload: return true
        default: return false
        }
    }

    private func valueColor(_ value: String, state: CellState, quality: Color?) -> Color {
        if value == "—" { return SQColor.labelTertiary }
        if state == .active { return quality ?? SQColor.brandRed }
        return SQColor.label
    }

    /// Barrette : qualité (phase active) / olive (terminée) / muted (à venir).
    private func barColor(_ state: CellState, quality: Color?) -> Color {
        switch state {
        case .active: return quality ?? SQColor.brandRed
        case .done: return SQColor.success
        case .pending: return SQColor.surfaceMuted
        }
    }

    @ViewBuilder
    private func cell(title: String, value: String, state: CellState, quality: Color?) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(SQFont.body(12))
                .foregroundStyle(SQColor.labelSecondary)
            Text(value)
                .font(SQFont.display(20, .bold, relativeTo: .title3))
                .monospacedDigit()
                .foregroundStyle(valueColor(value, state: state, quality: quality))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(barColor(state, quality: quality))
                .frame(width: 26, height: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.md + 2)
        .padding(.horizontal, SQSpace.sm)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowSoft()
        .sqAnimation(.snappy(duration: 0.25), value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(value == "—" ? "non mesuré" : value)")
    }
}

// MARK: - History row (compact)

private struct SpeedtestHistoryRow: View {
    let result: SpeedtestRunResult

    var body: some View {
        HStack(spacing: SQSpace.md) {
            ZStack {
                Circle()
                    .fill(SQColor.successSoft)
                    .frame(width: 40, height: 40)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SQColor.success)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(titleLine)
                    .font(SQFont.body(15, .semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(subtitleLine)
                    .font(SQFont.body(12.5))
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SQSpace.lg + 2)
        .padding(.vertical, SQSpace.md + 3)
        .accessibilityElement(children: .combine)
    }

    /// « 10 juil. · 388 Mbps · 21 ms »
    private var titleLine: String {
        var parts = [result.createdAt.formatted(.dateTime.day().month(.abbreviated))]
        parts.append("\(shortSpeed(result.downloadAverageMbps)) Mbps")
        if let ping = result.pingMinMs ?? result.pingMs, ping.isFinite, ping >= 0 {
            parts.append("\(Int(ping.rounded())) ms")
        }
        return parts.joined(separator: " · ")
    }

    /// Sous-titre réseau : « 5G NSA · Orange », « WiFi · Freebox »… Repli sur
    /// l'adresse ou la commune quand elles sont connues (contexte de la mesure).
    private var subtitleLine: String {
        var parts = [result.networkDisplayName]
        if let op = result.networkOperatorName?.trimmingCharacters(in: .whitespacesAndNewlines), !op.isEmpty {
            parts.append(op)
        }
        if let city = result.city?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty {
            parts.append(city)
        }
        return parts.joined(separator: " · ")
    }

    private func shortSpeed(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        if value >= 100 { return "\(Int(value.rounded()))" }
        return String(format: "%.1f", value)
    }
}

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

private extension SpeedtestPhase {
    var displayTitle: String {
        switch self {
        case .idle: return "Prêt"
        case .ping: return "Ping"
        case .download: return "Réception"
        case .upload: return "Envoi"
        case .saving: return "Sync"
        case .finished: return "Résultat"
        case .failed: return "Erreur"
        }
    }

    /// Libellé de phase du cadran (casse normale, DA « Crème & Terre cuite »).
    /// `displayTitle` reste utilisé tel quel par la Live Activity.
    var dialTitle: String {
        switch self {
        case .idle: return "Prêt à mesurer"
        case .ping: return "Latence"
        case .download: return "Téléchargement"
        case .upload: return "Envoi"
        case .saving: return "Synchronisation"
        case .finished: return "Téléchargement"
        case .failed: return "Erreur"
        }
    }

    var order: Int {
        switch self {
        case .idle: return 0
        case .ping: return 1
        case .download: return 2
        case .upload: return 3
        case .saving, .finished: return 4
        case .failed: return 0
        }
    }
}

// MARK: - Server picker (iPerf3 OVH + Bouygues)

/// Sélecteur de serveur iPerf3 groupé et repliable.
/// Accordion : une seule section provider ouverte à la fois, animation layout
/// simple (pas de `.move` qui décale le ScrollView parent).
private struct SpeedtestServerPicker: View {
    @Binding var selection: SpeedtestDownloadTarget
    /// `nil` = tout replié (sauf Auto toujours visible).
    @State private var expandedRegion: String?

    private var collapsibleGroups: [(region: String, targets: [SpeedtestDownloadTarget])] {
        SpeedtestDownloadTarget.pickerGroups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Auto + Cloudflare (moteurs, pas des POP) — toujours visibles.
            ForEach(SpeedtestDownloadTarget.ungroupedCases) { target in
                serverRow(target)
            }

            ForEach(collapsibleGroups, id: \.region) { group in
                let isExpanded = expandedRegion == group.region
                let selectedInGroup = group.targets.contains(selection)

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        Haptics.selection()
                        // Accordion : ouvrir celle-ci, fermer l'autre.
                        expandedRegion = isExpanded ? nil : group.region
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(SQColor.labelTertiary)
                                .frame(width: 12)
                                .animation(.easeInOut(duration: 0.22), value: isExpanded)

                            Text(group.region)
                                .font(SQFont.body(14, .semibold))
                                .foregroundStyle(SQColor.label)

                            Text("\(group.targets.count)")
                                .font(SQFont.body(11, .semibold))
                                .foregroundStyle(SQColor.labelTertiary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(SQColor.fill, in: Capsule(style: .continuous))

                            Spacer(minLength: 6)

                            if selectedInGroup, !isExpanded {
                                Text(selection.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(SQColor.brandRed)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, SQSpace.md)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                                .fill(SQColor.surfaceMuted)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(group.region)
                    .accessibilityValue(isExpanded ? "ouvert" : "fermé")

                    if isExpanded {
                        VStack(spacing: 6) {
                            ForEach(group.targets) { target in
                                serverRow(target)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
        // Animation de hauteur/layout uniquement — fluide dans un ScrollView.
        .animation(.easeInOut(duration: 0.25), value: expandedRegion)
        .onAppear {
            expandGroup(containing: selection)
        }
        .onChange(of: selection) { newValue in
            expandGroup(containing: newValue)
        }
    }

    /// Ouvre le groupe du serveur choisi (Auto / Cloudflare n'en ont pas).
    private func expandGroup(containing target: SpeedtestDownloadTarget) {
        let region = target.regionLabel
        guard collapsibleGroups.contains(where: { $0.region == region }) else { return }
        expandedRegion = region
    }

    private func serverRow(_ target: SpeedtestDownloadTarget) -> some View {
        let selected = selection == target
        return Button {
            selection = target
            Haptics.selection()
        } label: {
            HStack(spacing: SQSpace.md) {
                ZStack {
                    Circle()
                        .fill(selected ? SQColor.brandRed.opacity(0.16) : SQColor.fill)
                        .frame(width: 36, height: 36)
                    Image(systemName: target.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? SQColor.brandRed : SQColor.labelSecondary)
                }

                Text(target.displayName)
                    .font(SQFont.body(15, .semibold))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? SQColor.brandRed : SQColor.labelTertiary.opacity(0.5))
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .fill(selected ? SQColor.brandRed.opacity(0.08) : SQColor.surfaceMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .strokeBorder(selected ? SQColor.brandRed.opacity(0.4) : Color.clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.displayName)
        .accessibilityValue(selected ? "sélectionné" : "non sélectionné")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Comparable helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
