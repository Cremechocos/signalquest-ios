import SwiftUI
import UIKit
import CoreLocation
import os

private let speedtestQALogger = Logger(subsystem: "fr.signalquest.ios", category: "SpeedtestQA")

struct SpeedtestView: View {
    private let guestMode: Bool
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var settingsOptionSize: CGFloat = 44
    // Défaut « Auto » : préflight hybride iPerf3 (OVH/Bouygues/Scaleway/MilkyWan)
    // + Cloudflare, le plus rapide gagne.
    @AppStorage("speedtest_download_target") private var downloadTargetRaw = SpeedtestDownloadTarget.hybridAuto.rawValue
    // Défaut 10 s : méthodologie v6 commune avec Android (b40baca2). Réglable de
    // 5 à 30 s pour le test ponctuel seulement : le Drive Test a sa propre durée
    // (`drive_test_duration_seconds`), sinon 30 s ici triplaient le volume de
    // chaque test du trajet (MES-26).
    @AppStorage("speedtest_duration_seconds") private var durationSeconds = 10
    @AppStorage("speedtest_streams") private var streams = 16
    @AppStorage("speedtest_reliability_mode") private var reliabilityMode = true
    /// Serveur LibreSpeed choisi manuellement (hostname). Vide = le plus proche.
    @AppStorage("speedtest_librespeed_host") private var libreSpeedHost = ""
    /// POP iPerf3 choisi dans le catalogue distant (id de catalogue). Persisté à
    /// part de la cible, comme `libreSpeedHost` : la cible dit QUEL moteur, celui-ci
    /// dit LEQUEL de ses serveurs.
    @AppStorage("speedtest_iperf_server_id") private var iperfServerId = ""
    /// Nombre de tests enchaînés en rafale (1 = test simple).
    @AppStorage("speedtest_burst_count") private var burstCount = 1
    /// Distance à parcourir entre deux speedtests d'un Drive Test. Espacer par la
    /// distance plutôt que par le temps répartit les mesures le long du trajet
    /// au lieu de les entasser là où l'on roule lentement.
    @AppStorage("speedtest_drive_interval_meters") private var driveIntervalMeters = 500
    /// Plafond de données d'une session Drive Test, en Mo (0 = illimité).
    /// Un test vaut débit × durée : à 300 Mb/s sur 10 s, c'est ~375 Mo. Sans
    /// plafond une session pouvait engloutir des dizaines de gigaoctets.
    @AppStorage("speedtest_drive_data_cap_mb") private var driveDataCapMB = 5_000
    /// Les anciens speedtests cellulaires sont publiés à leur tour (hors zones
    /// privées) : on le dit une fois, au-dessus de l'historique où l'on masque un test.
    @AppStorage("speedtest_map_publication_notice_seen_v1") private var mapPublicationNoticeSeen = false
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
    /// Sentinelle `burstCount` = mode continu illimité (drive test).
    private static let continuousBurst = 0
    /// La feuille « localisation désactivée » ne s'affiche qu'une fois par
    /// lancement de l'app (MES-09).
    @MainActor private static var deniedLocationSheetShown = false
    /// Avertissement « données mobiles » accepté pour ce lancement (MES-08).
    @MainActor private static var dataWarningAccepted = false
    @State private var showDataWarning = false
    /// Test demandé par Siri, un raccourci ou le Centre de contrôle (MES-34).
    @State private var confirmExternalStart = false
    /// Octets échangés par le dernier test, mesurés par `SpeedtestDataMeter`.
    @State private var lastRunBytes: Int?
    @State private var history: [SpeedtestRunResult] = []
    /// Derniers tests du compte, tous appareils (UI-12). Vide en invité.
    @State private var accountHistory: [SocialShareableSpeedtest] = []
    @State private var errorMessage: String?
    @State private var isRetryingPendingSave = false
    /// Échec du MOTEUR de test (≠ échec de synchronisation) : carte dédiée
    /// dont le bouton relance le test au lieu de re-envoyer l'historique.
    @State private var runErrorMessage: String?
    /// Test de l'historique ouvert en fiche détaillée.
    @State private var detailResult: SpeedtestRunResult?
    /// Débit habituel de l'opérateur autour du dernier test (carte verdict).
    @State private var typicalNearby: SpeedtestVerdictCard.Typical?
    /// Les douze métriques d'expert restent repliées sous le verdict (MES-05).
    @State private var showResultDetails = false
    @State private var runTask: Task<Void, Never>?
    /// Identité de la session propriétaire de l'état partagé. Une tâche annulée
    /// peut terminer après qu'une nouvelle session a démarré ; elle ne doit alors
    /// ni vider `runTask`, ni arrêter la Live Activity de la nouvelle mesure.
    @State private var runSessionID: UUID?
    /// Génération de la mesure en cours. Le puits de progression du moteur est un
    /// `Task { @MainActor }` NON structuré : il n'hérite pas de l'annulation de
    /// `runTask`, et les ticks déjà émis s'exécutent donc APRÈS un `stop()`. Sans
    /// ce jeton, ils réécrivaient `phase`, `liveProgress` et `liveMbps` par-dessus
    /// l'état « arrêté » — d'où l'aiguille qui continuait de monter alors que le
    /// bouton était déjà repassé sur « Relancer ». Incrémenté à chaque run ET à
    /// chaque arrêt : tout tick d'une génération périmée est ignoré.
    @State private var runGeneration: Int = 0
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
    /// Copie qui invalide réellement SwiftUI après un rafraîchissement du catalogue.
    /// Lire directement une globale verrouillée dans le picker ne déclenchait aucun rendu.
    @State private var iperfCatalogServers = activeIPerfServers
    // Partage : le résultat ouvre d'abord un aperçu exact. Le PNG et la feuille
    // système ne sont créés qu'après confirmation des métadonnées publiées.
    @State private var sharePreviewResult: SpeedtestRunResult?

    init(guestMode: Bool = false) {
        self.guestMode = guestMode
    }

    /// Fournisseur affiché dans le bandeau, lié au chemin réellement mesuré.
    ///
    /// En Wi‑Fi, le nom vient de l'IP/ASN (le FAI de la box), jamais de
    /// CoreTelephony qui décrit la SIM inactive. En cellulaire, le résultat puis
    /// le chemin radio priment. Cette séparation évite qu'une SIM SFR fasse croire
    /// qu'un test lancé sur une box Orange utilise le réseau mobile SFR.
    private var headerOperatorName: String? {
        let connection = result?.connectionType ?? currentNetworkStatus.connection
        switch connection {
        case .wifi:
            return result?.networkOperatorName
                ?? detectedOperator?.shortLabel
                ?? detectedOperator?.label
        case .cellular:
            return result?.networkOperatorName
                ?? currentNetworkStatus.operatorName
                ?? detectedOperator?.shortLabel
                ?? detectedOperator?.label
        case .wired, .other:
            return nil
        }
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

                ViewThatFits(in: .horizontal) {
                    signatureDial
                    signatureDial
                        .scaleEffect(0.9)
                        .frame(width: 279, height: 279)
                }
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
                    // Un test sans réception mesurée n'a pas de verdict : « Très
                    // lent » accuserait le réseau d'un échec du test.
                    if result.downloadAverageMbps > 0 {
                        SpeedtestVerdictCard(verdict: SpeedtestVerdict(result: result),
                                             measuredMbps: result.downloadAverageMbps,
                                             typical: typicalNearby,
                                             dataUsedBytes: lastRunBytes)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
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
                        guard !isRetryingPendingSave else { return }
                        isRetryingPendingSave = true
                        Task {
                            defer { isRetryingPendingSave = false }
                            do {
                                try await services.speedtest.retryPendingSavesReporting()
                                self.errorMessage = nil
                            } catch {
                                self.errorMessage = error.userFacingMessage
                            }
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
            .sqReadableWidth()
        }
        // Directement sur le ScrollView (avant tout wrap) : rétraction du dock.
        .sqDockAutoMinimize()
        // En mode invité, la barre de navigation du conteneur (« Fermer »,
        // « Mes tests partagés ») doit rester visible ; sinon l'en-tête custom suffit.
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
        // Siri, raccourci ou contrôle iOS 18 : proposer le test tout de suite,
        // mais le lancer seulement sur confirmation (MES-34).
        .onReceive(services.router.$pendingSpeedtestStart) { pending in
            guard pending else { return }
            services.router.pendingSpeedtestStart = false
            confirmExternalStart = true
        }
        .confirmationDialog("Lancer un test de débit ?", isPresented: $confirmExternalStart, titleVisibility: .visible) {
            Button("Lancer le test") { start() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Demandé depuis Siri, un raccourci ou le Centre de contrôle.")
        }
        .signalQuestBackground()
        .sheet(item: $detailResult) { item in
            SpeedtestDetailSheet(
                result: item,
                // Bouton masqué si le test n'a pas de position : on ne cadre
                // pas la carte sur un lieu qu'on ignore.
                onShowOnMap: item.coordinate == nil ? nil : { coordinate in
                    router.pendingMapFocus = coordinate
                    router.pendingMapLayer = .speedtest
                    router.selectedTab = .map
                },
                visibilityService: services.speedtest,
                guestMode: guestMode
            )
            .id(item.id)
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .alert("Ce test utilise des données mobiles", isPresented: $showDataWarning) {
            Button("Lancer le test") {
                Self.dataWarningAccepted = true
                start()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(verbatim: dataWarningMessage)
        }
        .sheet(isPresented: $showLocationPriming) {
            LocationPrimingSheet(
                isDenied: primingDenied,
                onAllow: { showLocationPriming = false; dispatchConfiguredRun(requestLocation: true) },
                onSkip: { showLocationPriming = false; dispatchConfiguredRun(requestLocation: false) }
            )
            .presentationDetents([.medium, .large])
        }
        .sqAnimation(.snappy(duration: 0.32), value: phase)
        .sqAnimation(.snappy(duration: 0.28), value: result)
        .task(id: result?.id) { await loadTypicalNearby(for: result) }
        .task {
            DriveTestViewModel.migrateLegacyDataCap()
            if await presentSpeedtestSharePreviewQAIfNeeded() { return }
            // L'historique est local : l'afficher tout de suite, avant les appels
            // réseau ci-dessous qui peuvent traîner hors couverture (MES-04).
            history = await services.speedtest.history()
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
            iperfCatalogServers = activeIPerfServers
            await services.speedtest.retryPendingSaves()
            history = await services.speedtest.history()
            await loadAccountHistory()
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
    }

    /// 310 pt sur les iPhone actuels pour laisser respirer la valeur ; repli
    /// proportionnel sur les écrans compacts afin de ne jamais rogner l'arc.
    private var signatureDial: some View {
        VStack(spacing: SQSpace.xs) {
        SignatureSpeedDial(
            value: gaugeDisplay.value,
            unit: gaugeDisplay.unit,
            phaseTitle: liveProgress.stage == "finalizing" ? String(localized: "Finalisation") : phase.dialTitle,
            phase: phase,
            completionLabel: dialCompletionLabel
        )
        if phase == .download || phase == .upload {
            Text(liveProgress.stage == "warmup" ? String(localized: "Chauffe") : liveProgress.stage == "reconnecting" ? String(localized: "Reconnexion") : liveProgress.stage == "preparation" ? String(localized: "Préparation") : String(localized: "Mesure"))
                .font(.caption.weight(.semibold))
            if let useful = liveProgress.usefulElapsedSeconds {
                Text("Temps utile : \(useful, format: .number.precision(.fractionLength(1))) s")
                    .font(.caption).monospacedDigit()
            }
            if let total = liveProgress.totalElapsedSeconds {
                Text("Total : \(total, format: .number.precision(.fractionLength(1))) s")
                    .font(.caption).foregroundStyle(SQColor.labelSecondary).monospacedDigit()
            }
        }
        }
    }

    // MARK: - Header (titre centré + capsule serveur, DA « Crème & Terre cuite »)

    private var header: some View {
        VStack(spacing: SQSpace.sm + 2) {
            // Titre centré entre deux emplacements de même largeur : le Drive Test
            // s'y nomme en toutes lettres quand la place le permet (UI-12).
            HStack(spacing: SQSpace.sm) {
                ViewThatFits(in: .horizontal) {
                    driveTestCapsule
                    headerButton(systemImage: "location.north.line.fill", label: "Mode Drive Test") {
                        showDriveTest = true
                    }
                }
                .accessibilityIdentifier("speedtest.driveTest")
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Speedtest")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                headerButton(systemImage: "slider.horizontal.3", label: "Réglages du test") {
                    showSettings = true
                }
                .accessibilityIdentifier("speedtest.settings")
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            SpeedtestServerBar(
                // Fournisseur du chemin mesuré : FAI IP en Wi‑Fi, opérateur
                // servant/SIM seulement en cellulaire. Cf. headerOperatorName.
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

    private var driveTestCapsule: some View {
        Button { showDriveTest = true } label: {
            Label("Drive Test", systemImage: "location.north.line.fill")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("speedtest.driveTest.label")
                .padding(.horizontal, SQSpace.md)
                .frame(minHeight: 44)
                .background(SQColor.surface, in: Capsule(style: .continuous))
                .sqShadowSoft()
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(Text("Mode Drive Test"))
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
                    .accessibilityIdentifier("speedtest.start")
            }
        }
        // iPad : un bouton, pas une barre de 670 pt (UI-17).
        .sqReadableWidth(440)
    }

    private var dataWarningMessage: String {
        var parts: [String] = []
        if services.networkPath.status.isConstrained {
            parts.append(String(localized: "Le Mode données réduites est activé."))
        }
        parts.append(burstCount > 1
            ? String(localized: "Chaque test peut consommer plusieurs centaines de Mo en 4G ou en 5G, et une rafale en enchaîne \(burstCount).")
            : String(localized: "Un test peut consommer plusieurs centaines de Mo en 4G ou en 5G."))
        if let lastRunBytes, lastRunBytes > 0 {
            let used = ByteCountFormatter.string(fromByteCount: Int64(lastRunBytes), countStyle: .file)
            parts.append(String(localized: "Ton dernier test a utilisé \(used)."))
        }
        return parts.joined(separator: " ")
    }

    private var primaryButtonTitle: String {
        if burstCount == Self.continuousBurst {
            return String(localized: "Ouvrir le Drive Test")
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

    // MARK: - Share panel

    @ViewBuilder
    private func sharePanel(for result: SpeedtestRunResult) -> some View {
        GradientButton(
            "Partager le résultat",
            systemImage: "square.and.arrow.up",
            style: .secondary
        ) {
            sharePreviewResult = result
        }
        .sheet(item: $sharePreviewResult) { selectedResult in
            SpeedtestSharePreviewSheet(
                result: selectedResult,
                theme: SQShareCardTheme.current(colorScheme: colorScheme)
            )
        }
    }

    private func resetShareState() {
        sharePreviewResult = nil
    }

    // MARK: - Detail card (preserves UI test labels)

    /// Débit habituel de l'opérateur autour du test, pour situer le résultat
    /// (MES-05). Seulement en réseau mobile avec une position : en Wi-Fi, la
    /// comparaison n'aurait pas de sens. Silencieux en cas d'échec.
    private func loadTypicalNearby(for result: SpeedtestRunResult?) async {
        typicalNearby = nil
        guard let result, result.connectionType == .cellular,
              let coordinate = result.coordinate else { return }
        let quality = await services.nearbyQuality.verdict(
            latitude: coordinate.latitude, longitude: coordinate.longitude,
            isCellular: true, simPlmn: result.simPlmn, maxAge: 300)
        guard !Task.isCancelled, let quality, let median = quality.medianDownloadMbps, median > 0 else { return }
        // Même opérateur que le test, sinon la comparaison tromperait.
        if let key = result.operatorKey, key != quality.operatorKey { return }
        typicalNearby = SpeedtestVerdictCard.Typical(operatorLabel: quality.operatorLabel, mbps: median)
    }

    /// Les métriques d'expert, repliées sous le verdict : un débutant n'a pas à
    /// lire douze valeurs pour savoir si sa connexion est bonne (MES-05).
    @ViewBuilder
    private func resultDetail(for result: SpeedtestRunResult) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Button {
                Haptics.selection()
                withAnimation(SQMotion.resolve(.snappy(duration: 0.25), reduceMotion)) { showResultDetails.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Détails de la mesure")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                    Spacer()
                    Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .rotationEffect(.degrees(showResultDetails ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showResultDetails ? Text("Déplié") : Text("Replié"))
            .accessibilityIdentifier("speedtest.result.details")

            if showResultDetails {
            Rectangle()
                .fill(SQColor.separator)
                .frame(height: 1)

            LazyVGrid(columns: resultColumns, spacing: SQSpace.md) {
                // Vocabulaire du lexique : plus de « DL max » à côté de « Réception
                // moy. », ni de « Jitter » ici et « Gigue » ailleurs (TRX-25).
                detailItem(label: "Réception (moyenne)", value: speed(result.downloadAverageMbps), highlight: true)
                detailItem(label: "Réception (pic)", value: speed(result.downloadMaxMbps), highlight: true)
                detailItem(label: "Envoi (moyenne)", value: speed(result.uploadAverageMbps))
                detailItem(label: "Envoi (pic)", value: speed(result.uploadMaxMbps))
                detailItem(label: "Latence", value: ms(result.primaryPingMs), trailing: result.pingProtocol)
                detailItem(label: "Gigue", value: ms(result.jitterMs))
                detailItem(label: "Latence en réception", value: ms(result.pingDlMs))
                detailItem(label: "Gigue en réception", value: ms(result.jitterDlMs))
                detailItem(label: "Latence en envoi", value: ms(result.pingUlMs))
                detailItem(label: "Gigue en envoi", value: ms(result.jitterUlMs))
                detailItem(label: "Réseau", value: result.networkShareDisplayName)
                // Le ping ET le download sont mesurés contre la même source (le CDN
                // sélectionné, AWS CloudFront par défaut). On affiche donc ce serveur
                // unique au lieu du VPS de session/upload (qui n'est qu'un détail
                // technique et induisait en erreur ici).
                detailItem(label: "Serveur de mesure", value: result.downloadServerName ?? result.serverName ?? "—")
            }
            }
        }
        .padding(SQSpace.lg + 2)
        .sqCardBackground()
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
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let trailing {
                    Text(trailing)
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
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
                    "\(String(localized: "Rafale")) — \(s.count) test",
                    systemImage: "bolt.fill"
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
            LazyVGrid(columns: resultColumns, spacing: SQSpace.md) {
                detailItem(label: "Réception (moyenne)", value: speed(s.avgDownload), highlight: true)
                detailItem(label: "Réception (pic)", value: speed(s.maxDownload), highlight: true)
                detailItem(label: "Envoi (moyenne)", value: speed(s.avgUpload))
                detailItem(label: "Latence (minimum)", value: ms(s.minPing))
            }
        }
        .padding(SQSpace.lg + 2)
        .sqCardBackground()
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
                    accessibilityContext: String(localized: "Un test tous les"),
                    selection: $driveIntervalMeters
                )
                Text("Prochain test après la distance choisie ou 30 s. « Tester maintenant » le lance aussitôt.")
                    .font(.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: SQSpace.xs) {
                chipRow(
                    title: "Plafond de données",
                    options: [(500, String(localized: "500 Mo")), (2_000, String(localized: "2 Go")), (5_000, String(localized: "5 Go")), (0, String(localized: "Sans limite"))],
                    accessibilityContext: String(localized: "Plafond de données"),
                    selection: $driveDataCapMB
                )
                Text("Le volume dépend du débit et de la durée du test. La session s'arrête après le test qui atteint le plafond ; ce test peut le dépasser.")
                    .font(.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Les libellés restent au-dessus des choix pour ne pas comprimer les capsules.
    private func chipRow(
        title: LocalizedStringKey,
        options: [(value: Int, label: String)],
        accessibilityContext: String,
        selection: Binding<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title).foregroundStyle(SQColor.label)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SQSpace.sm) {
                    chipButtons(options: options, accessibilityContext: accessibilityContext, selection: selection)
                }
            }
        }
    }

    @ViewBuilder
    private func chipButtons(
        options: [(value: Int, label: String)],
        accessibilityContext: String,
        selection: Binding<Int>
    ) -> some View {
        ForEach(options, id: \.value) { option in
                Button {
                    selection.wrappedValue = option.value
                    Haptics.selection()
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize()
                        .padding(.horizontal, SQSpace.md)
                        .frame(minWidth: max(44, settingsOptionSize), minHeight: max(44, settingsOptionSize))
                        .background(
                            selection.wrappedValue == option.value ? SQColor.brandRed : SQColor.fill,
                            in: Capsule(style: .continuous)
                        )
                        .foregroundStyle(selection.wrappedValue == option.value ? SQColor.onAccent : SQColor.label)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(accessibilityContext), \(option.label)")
                .accessibilityAddTraits(selection.wrappedValue == option.value ? [.isSelected] : [])
        }
    }

    // MARK: - Settings sheet (unchanged behaviour)

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    VStack(alignment: .leading, spacing: SQSpace.md + 2) {
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            Text("Nombre de tests").foregroundStyle(SQColor.label)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: SQSpace.sm) {
                                    chipButtons(
                                        options: [(1, "1"), (3, "3"), (5, "5"), (10, "10"),
                                            (Self.continuousBurst, String(localized: "Trajet"))],
                                        accessibilityContext: String(localized: "Nombre de tests"),
                                        selection: $burstCount
                                    )
                                }
                            }
                        }
                        Text(burstCount == Self.continuousBurst
                             ? String(localized: "Trajet : un test après la distance choisie ou 30 s, jusqu’à l’arrêt ou au plafond de données.")
                             : String(localized: "Un seul test, ou plusieurs tests à la suite. Choisis Trajet pour les espacer selon la distance."))
                            .font(.caption).foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if burstCount == Self.continuousBurst {
                            driveTestBudgetSection
                                .accessibilityIdentifier("speedtest.settings.route")
                        }
                        DisclosureGroup("Serveur et durée") {
                        Text("Serveur de test")
                            .font(SQFont.archivo(15, .bold))
                            .foregroundStyle(SQColor.label)
                        SpeedtestServerPicker(
                            selection: Binding(
                                get: { downloadTarget },
                                set: { downloadTargetRaw = $0.rawValue }
                            ),
                            libreSpeedHost: $libreSpeedHost,
                            iperfServerId: $iperfServerId,
                            servers: iperfCatalogServers,
                            // Dernière position CONNUE, jamais une demande : ouvrir
                            // le sélecteur ne doit ni déclencher le prompt système
                            // ni attendre un fix. `nil` = tri par distance masqué.
                            userLocation: services.location.cachedLocation().map {
                                Coordinates(
                                    latitude: $0.coordinate.latitude,
                                    longitude: $0.coordinate.longitude
                                )
                            }
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

                        }
                        .accessibilityIdentifier("speedtest.settings.advanced")

                    }
                    .padding(SQSpace.lg)
                    .sqCardBackground()
                }
                .padding(SQSpace.lg)
            }
            .accessibilityIdentifier("speedtest.settings.scroll")
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

    private var resultColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: SQSpace.md), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    // MARK: - History

    // Fidèle au prototype : les cartes d'historique suivent directement le
    // bouton, sans titre de section (le contexte suffit).
    private var accountOnlyHistory: [SocialShareableSpeedtest] {
        SpeedtestAccountHistory.accountOnly(accountHistory, local: history)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            if !guestMode, !history.isEmpty, !mapPublicationNoticeSeen {
                mapPublicationNotice
            }
            if history.isEmpty && accountOnlyHistory.isEmpty {
                EmptyStateView(
                    title: "Aucun test",
                    message: "Lance ton premier speedtest.",
                    systemImage: "clock",
                    messageColor: SQColor.label
                )
            } else {
                if !history.isEmpty {
                    VStack(spacing: SQSpace.sm + 2) {
                        ForEach(Array(history.enumerated()), id: \.element.id) { _, item in
                            Button {
                                Haptics.selection()
                                detailResult = item
                            } label: {
                                SpeedtestHistoryRow(result: item)
                            }
                            .buttonStyle(SQPressButtonStyle())
                            // Fond de carte commun : liseré en « Noir intense » (TRX-09).
                            .sqCardBackground(cornerRadius: SQRadius.md)
                            .sqFadeUp()
                            .accessibilityHint("Voir le détail du test")
                        }
                    }
                }
                if !accountOnlyHistory.isEmpty {
                    accountHistorySection
                }
            }
        }
    }

    /// Les tests du compte absents de ce téléphone : après une réinstallation
    /// ou sur un nouvel iPhone, l'onglet n'affiche plus « Aucun test » pour un
    /// compte qui en a des centaines (UI-12).
    private var accountHistorySection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm + 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sur ton compte")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                Text("Tes tests faits sur un autre appareil ou avant une réinstallation.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, history.isEmpty ? 0 : SQSpace.sm)
            ForEach(accountOnlyHistory) { test in
                AccountSpeedtestRow(test: test)
                    .sqCardBackground(cornerRadius: SQRadius.md)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speedtest.accountHistory")
    }

    /// Tests du compte (tous appareils). Silencieux : hors ligne ou en invité,
    /// l'historique local suffit.
    private func loadAccountHistory() async {
        guard !guestMode else { return }
        if AppEnvironment.usesDemoData {
            accountHistory = Self.demoAccountHistory
            return
        }
        if let tests = try? await services.feed.mySpeedtests(limit: 20) {
            accountHistory = tests
        }
    }

    /// Démo (`--demo-data`, tours de captures) : trois tests d'un autre appareil.
    private static var demoAccountHistory: [SocialShareableSpeedtest] {
        let now = Date()
        return [
            SocialShareableSpeedtest(id: "demo-a", downloadSpeed: 412.6, uploadSpeed: 61.3, ping: 19,
                                     networkType: "NR", mobileOperator: "Orange", timestamp: now.addingTimeInterval(-86_400 * 2)),
            SocialShareableSpeedtest(id: "demo-b", downloadSpeed: 58.4, uploadSpeed: 12.1, ping: 34,
                                     networkType: "LTE", mobileOperator: "Orange", timestamp: now.addingTimeInterval(-86_400 * 6)),
            SocialShareableSpeedtest(id: "demo-c", downloadSpeed: 7.9, uploadSpeed: 1.8, ping: 72,
                                     networkType: "LTE", mobileOperator: "Orange", timestamp: now.addingTimeInterval(-86_400 * 11)),
        ]
    }

    private var mapPublicationNotice: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Label {
                Text("Tes speedtests sur la carte")
                    .font(SQFont.body(15, .semibold))
                    .foregroundStyle(SQColor.label)
            } icon: {
                Image(systemName: "map")
                    .foregroundStyle(SQColor.brandRed)
            }
            Text("Tes speedtests en réseau mobile, anciens compris, apparaissent sur la carte à l’endroit où tu les as faits. Ceux faits dans tes zones privées restent cachés. Pour en masquer un, ouvre-le dans ton historique.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Compris") {
                Haptics.selection()
                mapPublicationNoticeSeen = true
            }
            .font(SQFont.body(14, .semibold))
            .foregroundStyle(SQColor.accentInk)
            .frame(minHeight: 44)
            .accessibilityIdentifier("speedtest.mapPublicationNotice.dismiss")
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowSoft()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speedtest.mapPublicationNotice")
    }

    // MARK: - Derived state

    private var isRunning: Bool {
        runTask != nil
    }

    /// Le succès de la mesure ne prouve pas sa visibilité publique : zones,
    /// éligibilité et état serveur sont vérifiés dans la fiche détaillée.
    private var dialCompletionLabel: String? {
        guard case .finished = phase else { return nil }
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
        // L'aiguille reste en Mbit/s même au-delà du gigabit : l'unité ne bascule
        // pas en Gbit/s sous une valeur qui, elle, ne change pas d'échelle.
        let mbit = SQUnits.throughputUnit(mbps: 0)
        switch phase {
        case .ping:
            let value = liveProgress.pingLiveMs ?? liveProgress.pingFinalMs ?? result?.primaryPingMs ?? 0
            return (value, "ms")
        case .upload:
            let value = liveProgress.uploadLiveMbps ?? liveProgress.uploadAverageMbps ?? result?.uploadAverageMbps ?? 0
            return (value, mbit)
        case .download:
            let value = liveProgress.downloadLiveMbps ?? liveProgress.downloadAverageMbps ?? result?.downloadAverageMbps ?? 0
            return (value, mbit)
        case .saving, .finished:
            return (result?.downloadAverageMbps ?? liveMbps, mbit)
        default:
            return (0, mbit)
        }
    }

    // MARK: - Lifecycle

    private func start() {
        if burstCount == Self.continuousBurst {
            showDriveTest = true
            return
        }
        // Un Drive Test mesure déjà : deux tests simultanés se partageraient la
        // bande passante et se fausseraient l'un l'autre (MES-18).
        if services.driveTest.isRunning {
            errorMessage = String(localized: "Un Drive Test est en cours : ouvre-le pour suivre ses mesures, ou arrête-le avant un test simple.")
            return
        }
        // Un test lancé depuis la voiture mesure déjà (CAR-05).
        if services.speedtest.isRunning {
            errorMessage = SpeedtestBusyError.alreadyRunning.errorDescription
            return
        }
        // Réseau mobile ou Mode données réduites : un test peut consommer
        // plusieurs centaines de Mo. On prévient une fois par lancement (MES-08).
        let status = services.networkPath.status
        if !AppEnvironment.runsSpeedtestQA, !Self.dataWarningAccepted,
           status.connection == .cellular || status.isConstrained {
            showDataWarning = true
            return
        }
        // Priming des permissions : si la localisation n'a jamais été demandée, on
        // explique POURQUOI avant de déclencher le prompt système (cf. audit UX-01).
        if !AppEnvironment.runsSpeedtestQA, services.location.authorizationStatus == .notDetermined {
            primingDenied = false
            showLocationPriming = true
            return
        }
        // ONB-SEC-01 : localisation refusée + publication carte active → proposer un
        // retour vers les Réglages plutôt que de lancer sans position en silence.
        // Une fois par lancement : la feuille revenait à chaque test (MES-09).
        if !AppEnvironment.runsSpeedtestQA, !Self.deniedLocationSheetShown,
           services.location.authorizationStatus == .denied || services.location.authorizationStatus == .restricted {
            Self.deniedLocationSheetShown = true
            primingDenied = true
            showLocationPriming = true
            return
        }
        let requestLocation = !AppEnvironment.runsSpeedtestQA
        dispatchConfiguredRun(requestLocation: requestLocation)
    }

    /// Lance le test dans le mode CONFIGURÉ (simple / rafale ×N / continu). Utilisé
    /// aussi par les callbacks du priming localisation, qui appelaient auparavant
    /// `performRun` en dur — ignorant la config rafale/continu au 1er test (UXP-07).
    private func dispatchConfiguredRun(requestLocation: Bool) {
        if burstCount == Self.continuousBurst {
            showDriveTest = true
        } else if burstCount > 1 {
            performBurst(count: burstCount, requestLocation: requestLocation)
        } else {
            performRun(requestLocation: requestLocation)
        }
    }

    /// Exécute UNE mesure complète (ping→download→upload→save), pilote la jauge,
    /// la Live Activity (avec index de rafale) et l'historique. Renvoie le résultat.
    private func ensureActiveRunSession(_ sessionID: UUID) throws {
        try Task.checkCancellation()
        guard runSessionID == sessionID else { throw CancellationError() }
    }

    private func executeRun(
        requestLocation: Bool,
        runIndex: Int,
        runTotal: Int,
        sessionID: UUID
    ) async throws -> SpeedtestRunResult {
        // Une tâche de rafale annulée pendant la pause peut reprendre juste assez
        // longtemps pour entrer ici. La session est vérifiée AVANT toute mutation :
        // elle ne repeint donc jamais l'état remis à zéro par `stop()`.
        try ensureActiveRunSession(sessionID)
        // Une génération par mesure — pas par session : en rafale, cela empêche aussi
        // un tick tardif du test N de repeindre la jauge du test N+1.
        runGeneration &+= 1
        let generation = runGeneration
        phase = .ping
        result = nil
        lastRunBytes = nil
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
        try ensureActiveRunSession(sessionID)
        let runStatus = status.merging(operatorName: detectedOperator?.label)
        let settings = runSettings

        let location: Coordinates?
        if requestLocation {
            let requestedLocation = await services.location.currentLocation()
            location = requestedLocation.map {
                Coordinates(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    accuracy: max(0, $0.horizontalAccuracy),
                    observedAt: $0.timestamp
                )
            }
        } else {
            location = nil
        }
        try ensureActiveRunSession(sessionID)
        let bytesBefore = SpeedtestDataMeter.shared.bytes
        let measured = try await services.speedtest.run(
            pathStatus: runStatus,
            location: location,
            settings: settings,
            progress: { update in
                Task { @MainActor in
                    // Tick d'une mesure déjà arrêtée ou remplacée : on le laisse tomber.
                    guard generation == runGeneration, runSessionID == sessionID else { return }
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
        try ensureActiveRunSession(sessionID)
        lastRunBytes = max(0, SpeedtestDataMeter.shared.bytes - bytesBefore)
        result = measured
        sharePreviewResult = nil
        liveProgress = SpeedtestLiveProgress(
            phase: .saving,
            currentMbps: measured.downloadAverageMbps,
            downloadAverageMbps: measured.downloadAverageMbps,
            uploadAverageMbps: measured.uploadAverageMbps,
            pingFinalMs: measured.primaryPingMs,
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
                publishToMap: !isVPNActive,
                shareExactLocation: !isVPNActive
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ensureActiveRunSession(sessionID)
            errorMessage = error.userFacingMessage
        }
        try ensureActiveRunSession(sessionID)
        history = await services.speedtest.history()
        try ensureActiveRunSession(sessionID)
        phase = .finished
        liveProgress = SpeedtestLiveProgress(
            phase: .finished,
            currentMbps: measured.downloadAverageMbps,
            fraction: 1,
            downloadAverageMbps: measured.downloadAverageMbps,
            uploadAverageMbps: measured.uploadAverageMbps,
            pingFinalMs: measured.primaryPingMs,
            jitterMs: measured.jitterMs,
            pingProtocol: measured.pingProtocol,
            serverName: measured.serverName
        )
        return measured
    }

    private func performRun(requestLocation: Bool) {
        Haptics.light()
        errorMessage = nil
        runErrorMessage = nil
        networkAbortMessage = nil
        burstProgress = nil
        burstSummary = nil
        background.begin(name: "speedtest")
        liveActivity.start(serverName: "SignalQuest", network: services.networkPath.status.displayName)
        let sessionID = UUID()
        runSessionID = sessionID
        runTask = Task {
            do {
                let measured = try await executeRun(
                    requestLocation: requestLocation,
                    runIndex: 1,
                    runTotal: 1,
                    sessionID: sessionID
                )
                guard runSessionID == sessionID else { return }
                logQASpeedtestResult(measured)
                liveActivity.end(
                    downloadMbps: measured.downloadAverageMbps,
                    uploadMbps: measured.uploadAverageMbps ?? 0,
                    pingMs: measured.primaryPingMs ?? 0
                )
                Haptics.success()
            } catch is CancellationError {
                guard runSessionID == sessionID else { return }
                liveActivity.cancel()
                handleCancellation()
            } catch {
                guard runSessionID == sessionID else { return }
                liveActivity.cancel()
                runErrorMessage = error.userFacingMessage
                phase = .failed(error.localizedDescription)
                liveProgress = SpeedtestLiveProgress(phase: .failed(error.localizedDescription))
                Haptics.warning()
            }
            guard runSessionID == sessionID else { return }
            background.end()
            runTask = nil
            runSessionID = nil
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
        let total = max(2, min(count, 20))
        burstProgress = (1, total)
        background.begin(name: "speedtest-burst")
        liveActivity.start(serverName: "SignalQuest", network: services.networkPath.status.displayName, runIndex: 1, runTotal: total)
        let sessionID = UUID()
        runSessionID = sessionID
        runTask = Task {
            var results: [SpeedtestRunResult] = []
            var truncatedAt: Int?
            loop: for index in 1...total {
                guard !Task.isCancelled, runSessionID == sessionID else { return }
                burstProgress = (index, total)
                do {
                    // Géolocaliser CHAQUE test de la rafale (pas seulement le 1er) :
                    // sinon les tests 2..N étaient enregistrés/publiés sans position
                    // (TEL-06). currentLocation renvoie le fix récent en cache (peu coûteux).
                    let measured = try await executeRun(
                        requestLocation: requestLocation,
                        runIndex: index,
                        runTotal: total,
                        sessionID: sessionID
                    )
                    guard runSessionID == sessionID else { return }
                    results.append(measured)
                } catch is CancellationError {
                    guard runSessionID == sessionID else { return }
                    truncatedAt = max(0, index - 1)
                    break loop
                } catch {
                    guard runSessionID == sessionID else { return }
                    // Un test raté n'interrompt pas la rafale : on note et on continue.
                    errorMessage = error.userFacingMessage
                    Haptics.warning()
                }
                if index < total {
                    if shouldStopBurstForBackgroundLimit() {
                        truncatedAt = index
                        break loop
                    }

                    if scenePhase == .active {
                        do {
                            try await Task.sleep(nanoseconds: 700_000_000)
                        } catch is CancellationError {
                            return
                        } catch {
                            return
                        }
                    } else {
                        background.renew(name: "speedtest-burst")
                    }
                }
            }
            guard runSessionID == sessionID else { return }
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
            runSessionID = nil
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
        runSessionID = nil
        runTask?.cancel()
        runTask = nil
        // Invalide les ticks déjà en vol AVANT de repeindre l'état : sans cela, le
        // premier tick arrivé après ce point réécrivait tout ce qu'on remet à zéro
        // juste en dessous.
        runGeneration &+= 1
        runStartConnection = nil
        runStartNetworkDisplayName = nil
        networkAbortMessage = nil
        phase = .idle
        liveProgress = SpeedtestLiveProgress(phase: .idle)
        // La jauge lit `liveMbps` : sans remise à zéro, elle restait figée sur la
        // dernière valeur mesurée au lieu de retomber.
        liveMbps = 0
        burstProgress = nil
        // `stop()` n'éteignait ni la Live Activity ni la tâche de fond : elles ne
        // s'arrêtaient qu'au `catch is CancellationError` du moteur, c'est-à-dire
        // après que tout le pipeline se soit déroulé. Entre les deux, l'Île
        // dynamique continuait d'afficher des valeurs qui montaient.
        liveActivity.cancel()
        background.end()
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
        let message = String(localized: "Speedtest arrêté : changement de réseau détecté (\(previousNetwork) -> \(newNetwork)). Relance le test pour mesurer une connexion stable.")
        networkAbortMessage = message
        errorMessage = message
        runSessionID = nil
        runGeneration &+= 1
        runTask?.cancel()
        runTask = nil
        runStartConnection = nil
        runStartNetworkDisplayName = nil
        phase = .failed(message)
        liveProgress = SpeedtestLiveProgress(phase: .failed(message))
        liveMbps = 0
        burstProgress = nil
        liveActivity.cancel()
        background.end()
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

    @MainActor
    private func presentSpeedtestSharePreviewQAIfNeeded() async -> Bool {
        #if DEBUG
        guard AppEnvironment.showsSpeedtestSharePreviewQA else { return false }
        let fixture = SpeedtestRunResult(
            label: "QA partage Speedtest",
            downloadMbps: 734.8,
            downloadAverageMbps: 734.8,
            downloadMaxMbps: 812.4,
            uploadMbps: 126.4,
            uploadAverageMbps: 126.4,
            uploadMaxMbps: 131.0,
            pingMs: 24,
            pingMedianMs: 18,
            pingMinMs: 14,
            pingMaxMs: 30,
            jitterMs: 1.4,
            pingDlMs: 42,
            jitterDlMs: 6.2,
            pingUlMs: 57,
            jitterUlMs: 9.4,
            pingProtocol: "ICMP",
            durationSeconds: 14,
            connectionType: .cellular,
            cellularTechnology: .fiveGNSA,
            networkOperatorName: "Bouygues Telecom",
            networkOperatorMcc: 208,
            networkOperatorMnc: 20,
            marketCode: "FR",
            operatorKey: "bouygues_telecom",
            city: "Lyon",
            serverName: "Paris BBR — serveur au nom volontairement long",
            downloadServerName: "Paris BBR — serveur au nom volontairement long",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            downloadSeriesMbps: [120, 280, 510, 720, 770, 748, 734],
            uploadSeriesMbps: [22, 54, 91, 122, 126, 124],
            downloadGraceWindowCount: 2,
            uploadGraceWindowCount: 1,
            uploadMeasurementSource: "iperf3",
            deviceModel: "iPhone 17 Pro",
            osVersion: "iOS 27"
        )
        result = fixture
        await Task.yield()
        sharePreviewResult = fixture
        return true
        #else
        return false
        #endif
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
        let restarting = new.stage == "reconnecting" || new.stage == "preparation"
        return SpeedtestLiveProgress(
            phase: new.phase,
            currentMbps: new.currentMbps,
            fraction: new.fraction,
            downloadLiveMbps: new.downloadLiveMbps ?? (restarting && new.phase == .download ? nil : current.downloadLiveMbps),
            downloadAverageMbps: new.downloadAverageMbps ?? (restarting && new.phase == .download ? nil : current.downloadAverageMbps),
            uploadLiveMbps: new.uploadLiveMbps ?? (restarting && new.phase == .upload ? nil : current.uploadLiveMbps),
            uploadAverageMbps: new.uploadAverageMbps ?? (restarting && new.phase == .upload ? nil : current.uploadAverageMbps),
            pingLiveMs: new.pingLiveMs ?? current.pingLiveMs,
            pingFinalMs: new.pingFinalMs ?? current.pingFinalMs,
            jitterMs: new.jitterMs ?? current.jitterMs,
            pingProtocol: new.pingProtocol ?? current.pingProtocol,
            pingSampleCount: new.pingSampleCount > 0 ? new.pingSampleCount : current.pingSampleCount,
            pingSampleTarget: new.pingSampleTarget > 0 ? new.pingSampleTarget : current.pingSampleTarget,
            serverName: new.serverName ?? current.serverName,
            notice: new.notice ?? current.notice,
            stage: new.stage,
            usefulElapsedSeconds: new.usefulElapsedSeconds,
            totalElapsedSeconds: new.totalElapsedSeconds ?? current.totalElapsedSeconds
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
    return SQUnits.throughput(mbps: value)
}

private func ms(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "—" }
    return SQUnits.milliseconds(value)
}

// MARK: - Phase extensions

// MARK: - Server picker (iPerf3 OVH + Bouygues)

// MARK: - Comparable helper
