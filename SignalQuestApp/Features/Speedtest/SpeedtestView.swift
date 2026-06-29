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
                    if isVPNActive {
                        VPNWarningBanner()
                    }
                    VStack(spacing: SQSpace.xs) {
                        Text("Mesure terrain")
                            .sqKicker()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SpeedtestServerBar(
                            // Opérateur : résultat mesuré → API device → repli IP
                            // (cellulaire). Cf. headerOperatorName.
                            operatorName: headerOperatorName,
                            network: result?.networkDisplayName ?? currentNetworkStatus.displayName,
                            // Serveur de download/ping ACTIF (AWS CloudFront par
                            // défaut). On n'affiche plus le VPS de mesure : l'opérateur
                            // prend sa place dans le bandeau.
                            server: result?.downloadServerName ?? downloadTarget.displayName
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
                .padding(.top, SQSpace.md)
                .padding(.bottom, SQSpace.huge + SQSpace.huge)
            }
        }
        .navigationTitle("Speedtest")
        .toolbarTitleInlineCompat()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showDriveTest = true } label: {
                    Image(systemName: "location.north.line.fill")
                        .foregroundStyle(SQColor.brandRed)
                }
                .accessibilityLabel("Mode Drive Test")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(SQColor.brandRed)
                }
            }
        }
        .navigationDestination(isPresented: $showDriveTest) {
            DriveTestView(services: services)
        }
        .signalQuestHeroBackground()
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

    // MARK: - Primary action

    @ViewBuilder
    private var primaryAction: some View {
        VStack(spacing: SQSpace.sm) {
            if let burstProgress {
                burstRunningPill(index: burstProgress.index, total: burstProgress.total)
            }
            if isRunning {
                SpeedtestStopButton(title: "Arrêter", systemImage: "stop.fill", action: stop)
            } else {
                GradientButton(primaryButtonTitle, systemImage: primaryButtonIcon, action: start)
                    .shadow(color: SQBrand.signatureStart.opacity(0.32), radius: 16, y: 8)
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

    private var primaryButtonIcon: String {
        if burstCount == Self.continuousBurst { return "infinity" }
        return burstCount > 1 ? "bolt.fill" : "play.fill"
    }

    @ViewBuilder
    private func burstRunningPill(index: Int, total: Int) -> some View {
        HStack(spacing: SQSpace.sm) {
            if total == 0 {
                // Session continue (drive test) : pas de total, progression indéterminée.
                Image(systemName: "infinity").foregroundStyle(SQColor.brandOrange)
                Text("Continu · test \(index)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SQColor.label)
                ProgressView()
                    .controlSize(.small)
                    .tint(SQColor.brandOrange)
            } else {
                Image(systemName: "bolt.fill").foregroundStyle(SQColor.brandOrange)
                Text("Rafale · test \(index)/\(total)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SQColor.label)
                ProgressView(value: Double(index), total: Double(total))
                    .frame(width: 90)
                    .tint(SQColor.brandOrange)
            }
        }
        .padding(.horizontal, SQSpace.md).padding(.vertical, SQSpace.sm)
        .background(SQColor.surface.opacity(0.7), in: Capsule())
        .overlay(Capsule().stroke(SQColor.brandOrange.opacity(0.3), lineWidth: 1))
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
        .disabled(isPreparingShare)
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
                detailItem(label: "Réseau", value: result.networkShareDisplayName, color: SQColor.label)
                // Le ping ET le download sont mesurés contre la même source (le CDN
                // sélectionné, AWS CloudFront par défaut). On affiche donc ce serveur
                // unique au lieu du VPS de session/upload (qui n'est qu'un détail
                // technique et induisait en erreur ici).
                detailItem(label: "Serveur ping + DL", value: result.downloadServerName ?? result.serverName ?? "—", color: SQColor.label)
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

    // MARK: - Burst summary

    private func burstSummaryCard(_ s: SpeedtestBurstSummary) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .center) {
                Label(
                    "\(sessionIsContinuous ? "Session continue" : "Rafale") — \(s.count) test\(s.count > 1 ? "s" : "")",
                    systemImage: sessionIsContinuous ? "infinity" : "bolt.fill"
                )
                    .font(SQFont.archivo(17, .bold))
                    .foregroundStyle(SQColor.label)
                Spacer()
                if s.truncatedAt != nil {
                    Text("arrêtée")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(SQColor.warning.opacity(0.18), in: Capsule())
                        .foregroundStyle(SQColor.warning)
                }
            }
            Divider().background(SQColor.separator.opacity(colorScheme == .dark ? 0.2 : 0.1))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: SQSpace.md), GridItem(.flexible(), spacing: SQSpace.md)], spacing: SQSpace.md) {
                detailItem(label: "DL moyen", value: speed(s.avgDownload), color: SQBrand.signatureStart)
                detailItem(label: "DL max", value: speed(s.maxDownload), color: SQBrand.signatureStart)
                detailItem(label: "UL moyen", value: speed(s.avgUpload), color: SQBrand.signatureEnd)
                detailItem(label: "Ping min", value: ms(s.minPing), color: Color(hex: 0x06B6D4))
            }
        }
        .padding(SQSpace.lg)
        .background(SQColor.surface.opacity(colorScheme == .dark ? 0.35 : 0.65), in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator.opacity(colorScheme == .dark ? 0.25 : 0.15), lineWidth: 1)
        }
    }

    // MARK: - Settings sheet (unchanged behaviour)

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    SQSheetHandle()
                    VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                        VStack(alignment: .leading, spacing: SQSpace.xs) {
                            Text("Source du téléchargement")
                                .font(SQFont.archivo(15, .bold))
                                .foregroundStyle(SQColor.label)
                            Text("Origine des octets de download. Le ping est mesuré contre cette même source ; seul l'upload reste sur le serveur SignalQuest (VPS).")
                                .font(.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                        Picker("Source DL", selection: Binding(
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
                                            .background(burstCount == value ? SQColor.brandRed : SQColor.fill, in: Capsule())
                                            .foregroundStyle(burstCount == value ? .white : SQColor.label)
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
                                        .background(burstCount == Self.continuousBurst ? SQColor.brandRed : SQColor.fill, in: Capsule())
                                        .foregroundStyle(burstCount == Self.continuousBurst ? .white : SQColor.label)
                                }
                                .buttonStyle(.plain)
                            }
                            Text("Enchaîne plusieurs tests d'affilée. « ∞ » lance un mode continu (drive test) : tests illimités jusqu'à l'arrêt, position suivie en continu, poursuite écran verrouillé.")
                                .font(.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
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
            primingDenied = false
            showLocationPriming = true
            return
        }
        // ONB-SEC-01 : localisation refusée + publication carte active → proposer un
        // retour vers les Réglages plutôt que de lancer sans position en silence.
        if !AppEnvironment.runsSpeedtestQA, publishToMap,
           services.location.authorizationStatus == .denied || services.location.authorizationStatus == .restricted {
            primingDenied = true
            showLocationPriming = true
            return
        }
        let requestLocation = !AppEnvironment.runsSpeedtestQA
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
        phase = .download
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
            try await services.speedtest.save(measured, streams: settings.streams, publishToMap: publishToMap && !isVPNActive)
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

    private func performRun(requestLocation: Bool) {
        Haptics.light()
        errorMessage = nil
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
                errorMessage = error.localizedDescription
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
            serverName: new.serverName ?? current.serverName
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

// MARK: - Server bar (discreet top strip)

private struct SpeedtestServerBar: View {
    /// Opérateur mobile (Orange, SFR…) lu via CoreTelephony. nil/vide en WiFi ou
    /// quand l'API ne le renvoie pas (placeholder iOS 16.4+).
    let operatorName: String?
    /// Technologie d'accès (5G NSA, 4G, WiFi…).
    let network: String
    /// Serveur de download/ping actif (CDN AWS CloudFront par défaut).
    let server: String

    /// « Orange · 5G NSA » quand l'opérateur est connu, sinon la techno seule.
    private var networkLabel: String {
        if let op = operatorName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !op.isEmpty, op != network {
            return "\(op) · \(network)"
        }
        return network
    }

    var body: some View {
        HStack(spacing: SQSpace.sm) {
            Image(systemName: networkIcon)
                .font(.caption.weight(.bold))
                .foregroundStyle(SQColor.brandRed)
            Text(networkLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
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

    /// Offset (depuis le centre du cadran 280×280) pour placer le dot indicateur
    /// exactement au centre du trait à l'angle de fin de l'arc actif.
    private var arcEndOffset: CGSize {
        let endAngleDeg = 225.0 + 270.0 * normalized
        let endAngleRad = endAngleDeg * Double.pi / 180.0
        let r: CGFloat = 280.0 / 2  // rayon au centre du trait
        return CGSize(
            width: r * CGFloat(sin(endAngleRad)),
            height: -r * CGFloat(cos(endAngleRad))
        )
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

            // Jauge active de vitesse (.butt : pas de capsule flottante en bout d'arc)
            Circle()
                .trim(from: 0, to: arcSpan * normalized)
                .stroke(arcGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(135))
                .shadow(color: isLive ? accent.opacity(0.6) : .clear, radius: 12)
                .sqAnimation(.snappy(duration: 0.32), value: normalized)

            // Dot indicateur positionné exactement au bout de l'arc actif
            if normalized > 0 {
                Circle()
                    .fill(accent)
                    .frame(width: lineWidth, height: lineWidth)
                    .shadow(color: isLive ? accent.opacity(0.8) : .clear, radius: 8)
                    .offset(arcEndOffset)
                    .sqAnimation(.snappy(duration: 0.32), value: normalized)
            }

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
        HStack(alignment: .top, spacing: SQSpace.md) {
            ZStack {
                Circle()
                    .fill(SQColor.brandRed.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: networkIcon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(SQColor.brandRed)
            }

            VStack(alignment: .leading, spacing: SQSpace.xs) {
                // L'adresse occupe désormais toute la largeur (les métriques sont
                // passées sur leur propre rangée juste en dessous).
                Text(locationLine)
                    .font(SQFont.archivo(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(relativeDate)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)

                // Rangée dédiée DL · UL · ping (avec unités, plus de troncature de
                // l'adresse pour leur faire de la place).
                HStack(spacing: SQSpace.md) {
                    stat(icon: "arrow.down", value: shortSpeed(result.downloadAverageMbps), unit: "Mbps")
                    stat(icon: "arrow.up", value: shortSpeed(result.uploadAverageMbps), unit: "Mbps")
                    stat(icon: "timer", value: shortMs(result.pingMinMs ?? result.pingMs), unit: "ms")
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.md)
    }

    private func stat(icon: String, value: String, unit: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityHidden(true)
            Text(value)
                .font(SQFont.archivo(15, .semibold, relativeTo: .subheadline))
                .monospacedDigit()
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
            Text(unit)
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelTertiary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Ligne principale : adresse (rue + commune) reverse-géocodée du point de
    /// mesure. Repli sur la commune seule, puis sur la techno réseau quand la
    /// localisation manque (test sans autorisation, ancien historique).
    private var locationLine: String {
        if let address = result.address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
            return address
        }
        if let city = result.city?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty {
            return city
        }
        return result.networkDisplayName
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
