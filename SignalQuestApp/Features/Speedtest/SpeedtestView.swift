import SwiftUI
import UIKit
import CoreLocation
import CoreTransferable
import UniformTypeIdentifiers
import os

private let speedtestQALogger = Logger(subsystem: "fr.signalquest.ios", category: "SpeedtestQA")

struct SpeedtestView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("speedtest_download_target") private var downloadTargetRaw = SpeedtestDownloadTarget.awsCloudFront.rawValue
    @AppStorage("speedtest_duration_seconds") private var durationSeconds = 10
    @AppStorage("speedtest_streams") private var streams = 16
    @AppStorage("speedtest_reliability_mode") private var reliabilityMode = true
    /// Publication sur la carte communautaire publique. Opt-in explicite, OFF par
    /// défaut (RGPD : pas de diffusion de position sans consentement).
    @AppStorage("speedtest_publish_to_map") private var publishToMap = false
    @State private var phase: SpeedtestPhase = .idle
    @State private var result: SpeedtestRunResult?
    @State private var liveProgress = SpeedtestLiveProgress(phase: .idle)
    @State private var liveMbps: Double = 0
    @State private var history: [SpeedtestRunResult] = []
    @State private var errorMessage: String?
    @State private var runTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var showLocationPriming = false
    @State private var currentNetworkStatus: NetworkPathStatus = .unknown
    @State private var runStartConnection: NetworkConnectionKind?
    @State private var runStartNetworkDisplayName: String?
    @State private var networkAbortMessage: String?
    @State private var didRunQASpeedtest = false
    // Partage : image pré-rendue dès qu'un résultat arrive, pour un tap instantané.
    @State private var shareURL: URL?
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var isPreparingShare = false

    var body: some View {
        ZStack {
            // Halo lumineux dynamique sous le cadran
            GeometryReader { proxy in
                RadialGradient(
                    colors: [phaseColor, .clear],
                    center: .init(x: 0.5, y: 0.32),
                    startRadius: 40,
                    endRadius: 280
                )
                .blur(radius: 20)
                .sqAnimation(.easeInOut(duration: 0.6), value: phase)
            }
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: SQSpace.xl) {
                    VStack(spacing: SQSpace.xs) {
                        Text("Mesure terrain")
                            .sqKicker()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SpeedtestServerBar(
                            network: currentNetworkStatus.displayName,
                            // Serveur de mesure (jamais la cible de download/CDN). Tiret
                            // tant qu'aucune session n'a renvoyé de serveur sélectionné.
                            server: liveProgress.serverName ?? result?.serverName ?? "—"
                        )
                    }

                    SignatureSpeedDial(
                        value: gaugeDisplay.value,
                        unit: gaugeDisplay.unit,
                        phaseTitle: phase.displayTitle,
                        subtitle: gaugeDisplay.subtitle,
                        phaseFraction: phaseProgressFraction,
                        phase: phase
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SQSpace.lg)

                    SpeedtestTriMetric(
                        activePhase: phase,
                        progress: liveProgress,
                        result: result
                    )

                    primaryAction

                    if let result {
                        sharePanel(for: result)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        resultDetail(for: result)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if let errorMessage {
                        ErrorStateView(title: "Speedtest non synchronisé", message: errorMessage)
                            .transition(.opacity)
                    }

                    historySection
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.md)
                .padding(.bottom, SQSpace.huge + SQSpace.huge)
            }
        }
        .navigationTitle("Speedtest")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(SQColor.brandRed)
                }
            }
        }
        .signalQuestHeroBackground()
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showLocationPriming) {
            LocationPrimingSheet(
                onAllow: { showLocationPriming = false; performRun(requestLocation: true) },
                onSkip: { showLocationPriming = false; performRun(requestLocation: false) }
            )
            .presentationDetents([.medium])
        }
        .sqAnimation(.snappy(duration: 0.32), value: phase)
        .sqAnimation(.snappy(duration: 0.28), value: result)
        .task {
            currentNetworkStatus = services.networkPath.status
            await services.speedtest.retryPendingSaves()
            history = await services.speedtest.history()
            await runQASpeedtestIfNeeded()
        }
        .onReceive(services.networkPath.$status) { status in
            handleNetworkStatusUpdate(status)
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .background {
                stop()
            }
        }
        .onChange(of: colorScheme) { _, _ in
            // L'image de partage suit le thème iOS : on la re-rend au changement.
            shareURL = nil
            if let result { prerenderShareImage(for: result) }
        }
    }

    // MARK: - Primary action

    @ViewBuilder
    private var primaryAction: some View {
        if isRunning {
            SpeedtestStopButton(title: "Arrêter", systemImage: "stop.fill", action: stop)
        } else {
            GradientButton(result == nil ? "Lancer le test" : "Relancer le test", systemImage: "play.fill", action: start)
                .shadow(color: SQBrand.signatureStart.opacity(0.32), radius: 16, y: 8)
        }
    }

    // MARK: - Share panel (single-tap)

    @ViewBuilder
    private func sharePanel(for result: SpeedtestRunResult) -> some View {
        Button {
            Haptics.light()
            presentShare(for: result)
        } label: {
            HStack(spacing: SQSpace.sm) {
                if isPreparingShare {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                }
                Text("Partager le résultat")
                    .font(SQType.button)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SQSpace.md + 2)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [SQBrand.signatureStart, SQBrand.signatureEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
            )
            .shadow(color: SQBrand.signatureStart.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(SQPressButtonStyle())
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
                .presentationDetents([.medium, .large])
        }
    }

    /// Assemble image (pré-rendue si dispo) + texte et présente la feuille de
    /// partage immédiatement. Si l'image n'est pas encore prête, on la rend à la
    /// volée (SpeedtestShareImageRenderer.render est asynchrone), sans bloquer l'UI.
    private func presentShare(for result: SpeedtestRunResult) {
        let text = SpeedtestShareImageRenderer.shareText(for: result)
        let title = "Speedtest SignalQuest — \(Int(result.downloadAverageMbps.rounded())) Mbps"
        if let url = shareURL {
            shareItems = [ImageAndTextShareItem(fileURL: url, text: text, title: title), text]
            showShareSheet = true
            return
        }
        isPreparingShare = true
        Task {
            do {
                let url = try await SpeedtestShareImageRenderer.render(result, theme: SpeedtestShareTheme.resolve(colorScheme))
                await MainActor.run {
                    self.isPreparingShare = false
                    self.shareURL = url
                    self.shareItems = [ImageAndTextShareItem(fileURL: url, text: text, title: title), text]
                    self.showShareSheet = true
                }
            } catch {
                await MainActor.run {
                    self.isPreparingShare = false
                    self.shareItems = [text]
                    self.showShareSheet = true
                }
            }
        }
    }

    /// Pré-rend l'image de partage hors du chemin critique du tap, dans le thème
    /// iOS courant.
    private func prerenderShareImage(for result: SpeedtestRunResult) {
        let theme = SpeedtestShareTheme.resolve(colorScheme)
        Task {
            do {
                let url = try await SpeedtestShareImageRenderer.render(result, theme: theme)
                await MainActor.run {
                    self.shareURL = url
                }
            } catch {
                print("Failed to prerender share image: \(error)")
            }
        }
    }

    // MARK: - Detail card (preserves UI test labels)

    @ViewBuilder
    private func resultDetail(for result: SpeedtestRunResult) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .center) {
                Label("Résultats", systemImage: "chart.bar.doc.horizontal.fill")
                    .font(SQFont.archivo(17, .bold))
                    .foregroundStyle(SQColor.label)
                Spacer()
                Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            
            Divider()
                .background(SQColor.separator.opacity(colorScheme == .dark ? 0.2 : 0.1))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: SQSpace.md), GridItem(.flexible(), spacing: SQSpace.md)], spacing: SQSpace.md) {
                detailItem(label: "DL moyen", value: speed(result.downloadAverageMbps), color: SQBrand.signatureStart)
                detailItem(label: "DL max", value: speed(result.downloadMaxMbps), color: SQBrand.signatureStart)
                detailItem(label: "UL moyen", value: speed(result.uploadAverageMbps), color: SQBrand.signatureEnd)
                detailItem(label: "UL max", value: speed(result.uploadMaxMbps), color: SQBrand.signatureEnd)
                detailItem(label: "Ping", value: ms(result.pingMinMs ?? result.pingMs), trailing: result.pingProtocol, color: Color(hex: 0x06B6D4))
                detailItem(label: "Jitter", value: ms(result.jitterMs), color: Color(hex: 0x06B6D4))
                detailItem(label: "Ping DL", value: ms(result.pingDlMs), color: Color(hex: 0x06B6D4))
                detailItem(label: "Jitter DL", value: ms(result.jitterDlMs), color: Color(hex: 0x06B6D4))
                detailItem(label: "Ping UL", value: ms(result.pingUlMs), color: Color(hex: 0x06B6D4))
                detailItem(label: "Jitter UL", value: ms(result.jitterUlMs), color: Color(hex: 0x06B6D4))
                detailItem(label: "Réseau", value: result.networkDisplayName, color: SQColor.label)
                detailItem(label: "Serveur", value: result.serverName ?? "—", color: SQColor.label)
            }
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface.opacity(colorScheme == .dark ? 0.35 : 0.65), in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator.opacity(colorScheme == .dark ? 0.25 : 0.15), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.12 : 0.05), radius: 16, x: 0, y: 8)
    }

    private func detailItem(label: String, value: String, trailing: String? = nil, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(SQType.micro)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(SQFont.archivo(17, .semibold, relativeTo: .body))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let trailing {
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(SQColor.labelTertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Settings sheet (unchanged behaviour)

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    SQSheetHandle()
                    VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                        Picker("Cible DL", selection: Binding(
                            get: { downloadTarget },
                            set: { downloadTargetRaw = $0.rawValue }
                        )) {
                            ForEach(SpeedtestDownloadTarget.allCases) { target in
                                Text(target.displayName).tag(target)
                            }
                        }
                        .pickerStyle(.segmented)

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

                        HStack {
                            Text("Streams")
                                .foregroundStyle(SQColor.label)
                            Spacer()
                            ForEach([1, 4, 8, 16], id: \.self) { value in
                                Button {
                                    streams = value
                                    Haptics.selection()
                                } label: {
                                    Text("\(value)x")
                                        .font(.caption.weight(.bold))
                                        .frame(minWidth: 38)
                                        .padding(.vertical, SQSpace.xs + 3)
                                        .background(streams == value ? SQColor.brandRed : SQColor.fill, in: Capsule())
                                        .foregroundStyle(streams == value ? .white : SQColor.label)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Toggle(isOn: $reliabilityMode) {
                            Text("Mode fiabilité")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SQColor.label)
                        }
                        .tint(SQColor.brandRed)

                        Divider().overlay(SQColor.separator)

                        VStack(alignment: .leading, spacing: SQSpace.xs) {
                            Toggle(isOn: $publishToMap) {
                                Text("Publier sur la carte communautaire")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(SQColor.label)
                            }
                            .tint(SQColor.brandRed)
                            Text("Ta position (arrondie à ~100 m) et ton opérateur seront visibles publiquement. Désactivé par défaut.")
                                .font(.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(SQSpace.lg)
                    .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
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
        .presentationDetents([.medium, .large])
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            SQSectionHeader("Historique")
            if history.isEmpty {
                EmptyStateView(title: "Aucun test", message: "Lance ton premier speedtest.", systemImage: "clock")
            } else {
                VStack(spacing: SQSpace.sm + 2) {
                    ForEach(Array(history.enumerated()), id: \.element.id) { _, item in
                        SpeedtestHistoryRow(result: item)
                            .background(SQColor.surface.opacity(colorScheme == .dark ? 0.35 : 0.65), in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                                    .stroke(SQColor.separator.opacity(colorScheme == .dark ? 0.25 : 0.15), lineWidth: 1)
                            }
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.08 : 0.03), radius: 8, x: 0, y: 4)
                            .sqFadeUp()
                    }
                }
            }
        }
    }

    // MARK: - Derived state

    private var phaseColor: Color {
        switch phase {
        case .idle:
            return SQColor.brandRed.opacity(0.12)
        case .ping:
            return Color(hex: 0x06B6D4).opacity(0.18) // Cyan
        case .download:
            return Color(hex: 0x10B981).opacity(0.20) // Green
        case .upload:
            return SQBrand.signatureEnd.opacity(0.22) // Orange/Pink
        case .saving:
            return SQColor.success.opacity(0.15)
        case .finished:
            return SQColor.success.opacity(0.18)
        case .failed:
            return SQColor.danger.opacity(0.20)
        }
    }

    private var isRunning: Bool {
        runTask != nil
    }

    private var downloadTarget: SpeedtestDownloadTarget {
        SpeedtestDownloadTarget(rawValue: downloadTargetRaw) ?? .awsCloudFront
    }

    private var runSettings: SpeedtestRunSettings {
        SpeedtestRunSettings(
            downloadTarget: downloadTarget,
            durationSeconds: durationSeconds.clamped(to: 5...30),
            streams: streams.clamped(to: 1...16),
            reliabilityMode: reliabilityMode
        )
    }

    private var phaseProgressFraction: Double {
        switch phase {
        case .idle: return 0
        case .finished: return 1
        case .failed: return 0
        default: return liveProgress.fraction
        }
    }

    private var gaugeDisplay: (value: Double, unit: String, subtitle: String) {
        switch phase {
        case .ping:
            let value = liveProgress.pingLiveMs ?? liveProgress.pingFinalMs ?? result?.pingMinMs ?? result?.pingMs ?? 0
            let count = liveProgress.pingSampleTarget > 0 ? "\(liveProgress.pingSampleCount)/\(liveProgress.pingSampleTarget)" : "latence"
            return (value, "ms", count)
        case .upload:
            let value = liveProgress.uploadLiveMbps ?? liveProgress.uploadAverageMbps ?? result?.uploadAverageMbps ?? 0
            return (value, "Mbps", "envoi")
        case .download:
            let value = liveProgress.downloadLiveMbps ?? liveProgress.downloadAverageMbps ?? result?.downloadAverageMbps ?? 0
            return (value, "Mbps", "réception")
        case .saving:
            return (result?.downloadAverageMbps ?? liveMbps, "Mbps", "synchronisation")
        case .finished:
            return (result?.downloadAverageMbps ?? liveMbps, "Mbps", "téléchargement")
        default:
            return (0, "Mbps", "prêt")
        }
    }

    // MARK: - Lifecycle

    private func start() {
        // Priming des permissions : si la localisation n'a jamais été demandée, on
        // explique POURQUOI avant de déclencher le prompt système (cf. audit UX-01).
        if !AppEnvironment.runsSpeedtestQA, services.location.authorizationStatus == .notDetermined {
            showLocationPriming = true
            return
        }
        performRun(requestLocation: !AppEnvironment.runsSpeedtestQA)
    }

    private func performRun(requestLocation: Bool) {
        Haptics.light()
        errorMessage = nil
        phase = .ping
        result = nil
        shareURL = nil
        liveProgress = SpeedtestLiveProgress(phase: .ping)
        liveMbps = 0
        networkAbortMessage = nil
        let status = services.networkPath.status
        currentNetworkStatus = status
        runStartConnection = status.connection
        runStartNetworkDisplayName = status.displayName
        let settings = runSettings
        runTask = Task {
            do {
                let location: Coordinates?
                if requestLocation {
                    let requestedLocation = await services.location.currentLocation()
                    location = requestedLocation.map {
                        Coordinates(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                    }
                } else {
                    location = nil
                }
                phase = .download
                let measured = try await services.speedtest.run(
                    pathStatus: status,
                    location: location,
                    settings: settings,
                    progress: { update in
                        Task { @MainActor in
                            phase = update.phase
                            liveProgress = mergeProgress(current: liveProgress, new: update)
                            liveMbps = update.currentMbps
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                result = measured
                shareURL = nil
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
                    try await services.speedtest.save(measured, streams: settings.streams, publishToMap: publishToMap)
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
                logQASpeedtestResult(measured)
                Haptics.success()
            } catch is CancellationError {
                if let networkAbortMessage {
                    errorMessage = networkAbortMessage
                    phase = .failed(networkAbortMessage)
                } else {
                    phase = .idle
                    liveProgress = SpeedtestLiveProgress(phase: .idle)
                }
            } catch {
                errorMessage = error.localizedDescription
                phase = .failed(error.localizedDescription)
                liveProgress = SpeedtestLiveProgress(phase: .failed(error.localizedDescription))
                Haptics.warning()
            }
            runTask = nil
            runStartConnection = nil
            runStartNetworkDisplayName = nil
            networkAbortMessage = nil
            exitAfterQASpeedtestIfNeeded()
        }
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
            serverName: new.serverName ?? current.serverName
        )
    }
}

// MARK: - Server bar (discreet top strip)

private struct SpeedtestServerBar: View {
    let network: String
    let server: String

    var body: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: networkIcon)
                .font(.caption.weight(.bold))
                .foregroundStyle(SQColor.brandRed)
            Text(network)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SQColor.label)
            Circle()
                .fill(SQColor.labelTertiary)
                .frame(width: 3, height: 3)
            Image(systemName: "server.rack")
                .font(.caption2)
                .foregroundStyle(SQColor.labelSecondary)
            Text(server)
                .font(.caption.weight(.medium))
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.sm)
        .padding(.horizontal, SQSpace.md)
        .background(SQColor.surface.opacity(0.65), in: Capsule())
        .overlay { Capsule().stroke(SQColor.separator, lineWidth: 1) }
    }

    private var networkIcon: String {
        let lower = network.lowercased()
        if lower.contains("wifi") || lower.contains("wi-fi") { return "wifi" }
        if lower.contains("5g") || lower.contains("4g") || lower.contains("lte") || lower.contains("cellular") { return "antenna.radiowaves.left.and.right" }
        if lower.contains("ether") || lower.contains("wired") { return "cable.connector" }
        return "network"
    }
}

// MARK: - Signature speed dial (gradient orange → rose de la DA)

private struct SignatureSpeedDial: View {
    let value: Double
    let unit: String
    let phaseTitle: String
    let subtitle: String
    let phaseFraction: Double
    let phase: SpeedtestPhase

    private let arcSpan: Double = 0.75  // 270 degrees
    private let lineWidth: CGFloat = 22

    @State private var animatePulse = false
    @Environment(\.colorScheme) private var colorScheme

    private var normalized: Double {
        if unit == "ms" {
            guard value > 0 else { return 0 }
            return max(0, min(1, (120 - value) / 120))
        }
        guard value > 0 else { return 0 }
        let log = log10(value)
        return max(0, min(1, log / 3))
    }

    /// La mesure est en cours : l'arc actif reçoit un glow.
    private var isLive: Bool {
        switch phase {
        case .ping, .download, .upload: return true
        default: return false
        }
    }

    private var gaugeColors: [Color] {
        [
            Color(hex: 0xEF4444), // Nul (Red)
            Color(hex: 0xF97316), // Bof (Orange)
            Color(hex: 0xFDE047), // Moyen (Yellow)
            Color(hex: 0x22C55E), // Bon (Green)
            Color(hex: 0x15803D)  // Très bon (Dark Green)
        ]
    }

    private func lerpColor(from: Color, to: Color, t: Double) -> Color {
        let uiFrom = UIColor(from)
        let uiTo = UIColor(to)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        uiFrom.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        uiTo.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            .sRGB,
            red: Double(r1 + (r2 - r1) * CGFloat(t)),
            green: Double(g1 + (g2 - g1) * CGFloat(t)),
            blue: Double(b1 + (b2 - b1) * CGFloat(t)),
            opacity: Double(a1 + (a2 - a1) * CGFloat(t))
        )
    }

    private func colorForRatio(_ ratio: Double) -> Color {
        let v = max(0, min(1, ratio))
        let colors = gaugeColors
        let count = colors.count
        guard count > 1 else { return colors.first ?? .gray }
        
        let segment = 1.0 / Double(count - 1)
        let index = Int(v / segment)
        if index >= count - 1 {
            return colors.last!
        }
        let t = (v - Double(index) * segment) / segment
        return lerpColor(from: colors[index], to: colors[index + 1], t: t)
    }

    /// Teinte dynamique basée sur la qualité de la vitesse / latence actuelle.
    private var accent: Color {
        guard normalized > 0 else { return SQColor.brandRed }
        return colorForRatio(normalized)
    }

    /// Gradient de couleur multi-segment pour la jauge représentant la qualité.
    private var arcGradient: AngularGradient {
        AngularGradient(
            colors: gaugeColors,
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360 * arcSpan)
        )
    }

    var body: some View {
        ZStack {
            // Halo de fond interne
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(colorScheme == .dark ? 0.22 : 0.14), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 170
                    )
                )
                .blur(radius: 20)

            // Centre en verre translucide épuré pour donner de la profondeur
            Circle()
                .fill(SQColor.surface.opacity(colorScheme == .dark ? 0.4 : 0.7))
                .padding(lineWidth + 2)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 12, x: 0, y: 6)

            // Cercle d'échelle fin externe style chronomètre
            Circle()
                .trim(from: 0, to: arcSpan)
                .stroke(SQColor.separator.opacity(colorScheme == .dark ? 0.5 : 0.3), style: StrokeStyle(lineWidth: 1))
                .rotationEffect(.degrees(135))
                .padding(-10)

            // Jauge de fond vide
            Circle()
                .trim(from: 0, to: arcSpan)
                .stroke(SQColor.fill.opacity(colorScheme == .dark ? 0.6 : 0.8), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))

            // Jauge active de vitesse
            Circle()
                .trim(from: 0, to: arcSpan * normalized)
                .stroke(arcGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: isLive ? accent.opacity(0.6) : .clear, radius: 12)
                .sqAnimation(.snappy(duration: 0.32), value: normalized)

            // Anneau de progression fin interne
            Circle()
                .trim(from: 0, to: arcSpan * max(0.02, min(1, phaseFraction)))
                .stroke(accent.opacity(colorScheme == .dark ? 0.65 : 0.45), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(lineWidth + 8)
                .sqAnimation(.snappy(duration: 0.32), value: phaseFraction)

            VStack(spacing: 4) {
                Text(phaseTitle.uppercased())
                    .font(SQFont.archivo(11, .bold))
                    .tracking(2.4)
                    .foregroundStyle(isLive ? accent : SQColor.labelSecondary)
                Text(formattedValue)
                    .font(SQFont.archivo(56, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text(unit)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                Text(subtitle)
                    .font(SQFont.archivo(11, .semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, SQSpace.xl)
        }
        .frame(width: 280, height: 280)
        .scaleEffect(isLive && animatePulse ? 1.03 : 1.0)
        .sqAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isLive && animatePulse)
        .onAppear {
            animatePulse = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phaseTitle) \(formattedValue) \(unit)")
    }

    private var formattedValue: String {
        guard value > 0, value.isFinite else { return "—" }
        if unit == "ms" {
            return "\(Int(value.rounded()))"
        }
        if value >= 100 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", value)
    }
}

// MARK: - Tri-metric strip (Ping / Download / Upload)

private struct SpeedtestTriMetric: View {
    let activePhase: SpeedtestPhase
    let progress: SpeedtestLiveProgress
    let result: SpeedtestRunResult?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            cell(
                title: "Ping",
                icon: "timer",
                value: ms(result?.pingMinMs ?? progress.pingFinalMs ?? progress.pingLiveMs),
                state: state(for: .ping),
                accent: SQBrand.signatureStart
            )
            divider
            cell(
                title: "Réception",
                icon: "arrow.down",
                value: speed(result?.downloadAverageMbps ?? progress.downloadAverageMbps ?? progress.downloadLiveMbps),
                state: state(for: .download),
                accent: SQBrand.signatureStart
            )
            divider
            cell(
                title: "Envoi",
                icon: "arrow.up",
                value: speed(result?.uploadAverageMbps ?? progress.uploadAverageMbps ?? progress.uploadLiveMbps),
                state: state(for: .upload),
                accent: SQBrand.signatureEnd
            )
        }
        .padding(.vertical, SQSpace.md)
        .background(SQColor.surface.opacity(colorScheme == .dark ? 0.35 : 0.65), in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator.opacity(colorScheme == .dark ? 0.25 : 0.15), lineWidth: 1)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(SQColor.separator.opacity(colorScheme == .dark ? 0.3 : 0.2))
            .frame(width: 1, height: 32)
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

    @ViewBuilder
    private func cell(title: String, icon: String, value: String, state: CellState, accent: Color) -> some View {
        VStack(spacing: SQSpace.xs + 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                Text(title)
                    .font(SQType.micro)
                    .tracking(0.6)
                    .textCase(.uppercase)
            }
            .foregroundStyle(state == .active ? accent : SQColor.labelSecondary)

            Text(value)
                .font(SQFont.archivo(20, .bold, relativeTo: .title3))
                .monospacedDigit()
                .foregroundStyle(state == .pending ? SQColor.labelTertiary : SQColor.label)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if state == .active {
                Capsule()
                    .fill(accent)
                    .frame(width: 32, height: 4)
                    .shadow(color: accent.opacity(0.6), radius: 4, x: 0, y: 1)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Capsule()
                    .fill(state == .done ? SQColor.success : SQColor.separator.opacity(0.5))
                    .frame(width: 24, height: 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.xs)
        .background(
            state == .active
                ? AnyView(accent.opacity(colorScheme == .dark ? 0.06 : 0.04).clipShape(RoundedRectangle(cornerRadius: SQRadius.md)))
                : AnyView(Color.clear)
        )
        .animation(.snappy(duration: 0.25), value: state)
    }
}

// MARK: - Stop button (même géométrie que GradientButton, teinte danger)

private struct SpeedtestStopButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SQSpace.sm + 2) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SQSpace.md + 3)
            .foregroundStyle(.white)
            .background(SQColor.danger, in: RoundedRectangle(cornerRadius: SQRadius.lg + 2, style: .continuous))
            .shadow(color: SQColor.danger.opacity(0.32), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - History row (compact)

private struct SpeedtestHistoryRow: View {
    let result: SpeedtestRunResult

    var body: some View {
        HStack(alignment: .center, spacing: SQSpace.md) {
            ZStack {
                Circle()
                    .fill(SQColor.brandRed.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: networkIcon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(SQColor.brandRed)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(result.networkDisplayName)
                    .font(SQFont.archivo(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                Text(relativeDate)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: SQSpace.sm)

            HStack(spacing: SQSpace.sm + 2) {
                stat(icon: "arrow.down", value: shortSpeed(result.downloadAverageMbps))
                stat(icon: "arrow.up", value: shortSpeed(result.uploadAverageMbps))
                stat(icon: "timer", value: shortMs(result.pingMinMs ?? result.pingMs))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.md)
    }

    private func stat(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(SQColor.labelSecondary)
            Text(value)
                .font(SQFont.archivo(15, .semibold, relativeTo: .subheadline))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var relativeDate: String {
        result.createdAt.formatted(.relative(presentation: .named))
    }

    private var networkIcon: String {
        switch result.connectionType {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .wired: return "cable.connector"
        case .other: return "network"
        }
    }

    private func shortSpeed(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        if value >= 100 { return "\(Int(value.rounded()))" }
        return String(format: "%.1f", value)
    }

    private func shortMs(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return "\(Int(value.rounded()))"
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

// MARK: - Comparable helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
