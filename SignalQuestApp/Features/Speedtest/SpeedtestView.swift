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
    /// Nombre de tests enchaînés en rafale (1 = test simple). La distance entre
    /// tests et le plafond de données se règlent dans le Drive Test lui-même.
    @AppStorage("speedtest_burst_count") private var burstCount = 1
    /// Les anciens speedtests cellulaires sont publiés à leur tour (hors zones
    /// privées) : on le dit une fois, au-dessus de l'historique où l'on masque un test.
    @AppStorage("speedtest_map_publication_notice_seen_v1") private var mapPublicationNoticeSeen = false
    @State private var phase: SpeedtestPhase = .idle
    /// Hauteur visible de l'écran : sur iPhone SE ou 8, le cadran pleine taille
    /// repoussait « Lancer le test » sous la barre d'onglets (UI-01).
    @State private var viewportHeight: CGFloat = 0
    @State private var result: SpeedtestRunResult?
    @State private var liveProgress = SpeedtestLiveProgress(phase: .idle)
    @State private var liveMbps: Double = 0
    @State private var liveActivity = SpeedtestLiveActivityController()
    @State private var background = BackgroundTaskScope()
    /// Progression d'une rafale (test courant, total) — nil hors rafale.
    @State private var burstProgress: (index: Int, total: Int)?
    @State private var burstSummary: SpeedtestBurstSummary?
    /// Résultats déjà mesurés de la rafale en cours : `stop()` s'en sert pour
    /// afficher le bilan partiel (la tâche annulée ne le publie plus).
    @State private var burstResults: [SpeedtestRunResult] = []
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
    /// Tests de l'historique pas encore partis vers le serveur (« À envoyer »).
    @State private var pendingHistoryIds: Set<UUID> = []
    /// Derniers tests du compte, tous appareils (UI-12). Vide en invité.
    @State private var accountHistory: [SocialShareableSpeedtest] = []
    @State private var errorMessage: String?
    @State private var isRetryingPendingSave = false
    /// Échec du MOTEUR de test (≠ échec de synchronisation) : carte dédiée
    /// dont le bouton relance le test au lieu de re-envoyer l'historique.
    @State private var runErrorMessage: String?
    /// Nature de `runErrorMessage` : un changement de réseau ou un Drive Test
    /// en cours ne sont pas des échecs, leur carte le dit autrement.
    @State private var runErrorKind: RunErrorKind = .failure
    /// Test de l'historique ouvert en fiche détaillée.
    @State private var detailResult: SpeedtestRunResult?
    /// Débit habituel de l'opérateur autour du dernier test (carte verdict).
    @State private var typicalNearby: SpeedtestVerdictCard.Typical?
    /// Onglet ouvert dans « Détails du test » (nil : feuille fermée).
    @State private var detailsTab: SpeedtestDetailsTab?
    /// Tracé de la phase de débit en cours, sous l'anneau.
    @State private var sparkPoints: [SpeedtestSparkline.Point] = []
    @State private var sparkPhase = -1
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
    /// Page « Serveur de test » ouverte depuis la pastille réseau.
    @State private var showServerPage = false
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
        ScrollViewReader { scrollProxy in
            ScrollView {
                content(scrollProxy: scrollProxy)
            }
            // Directement sur le ScrollView (avant tout wrap) : rétraction du dock.
            .sqDockAutoMinimize()
        }
        // En mode invité, la barre de navigation du conteneur (« Fermer »,
        // « Mes tests partagés ») doit rester visible ; sinon l'en-tête custom suffit.
        .toolbar(guestMode ? .automatic : .hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showDriveTest) {
            DriveTestView(services: services)
        }
        .navigationDestination(isPresented: $showServerPage) { serverPage }
        // F4 : « Lance un Drive Test » (Siri/Raccourcis) → présente Drive Test
        // une fois l'onglet Speed actif.
        .onReceive(router.$pendingDriveTest) { pending in
            if pending {
                showDriveTest = true
                router.pendingDriveTest = false
            }
        }
        // Siri, raccourci ou contrôle iOS 18 : proposer le test tout de suite,
        // mais le lancer seulement sur confirmation (MES-34).
        .onReceive(router.$pendingSpeedtestStart) { pending in
            guard pending else { return }
            router.pendingSpeedtestStart = false
            confirmExternalStart = true
        }
        .confirmationDialog("Lancer un test de débit ?", isPresented: $confirmExternalStart, titleVisibility: .visible) {
            Button("Lancer le test") { start() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Demandé depuis Siri, un raccourci ou le Centre de contrôle.")
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChangeCompat(of: proxy.size.height) { _, height in viewportHeight = height }
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
                    router.pendingMapLayer = .speedtest
                    router.selectedTab = .map
                },
                visibilityService: services.speedtest,
                guestMode: guestMode
            )
            .id(item.id)
        }
        .sheet(item: $detailsTab) { tab in
            if let result {
                SpeedtestTestDetailsSheet(result: result, tab: tab) { detailsTab = nil }
            }
        }
        .sheet(item: $sharePreviewResult) { selectedResult in
            SpeedtestSharePreviewSheet(
                result: selectedResult,
                theme: SQShareCardTheme.current(colorScheme: colorScheme)
            )
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
            .presentationDragIndicator(.visible)
        }
        .sqAnimation(.snappy(duration: 0.32), value: phase)
        .sqAnimation(.snappy(duration: 0.28), value: result)
        .task(id: result?.id) { await loadTypicalNearby(for: result) }
        .task {
            DriveTestViewModel.migrateLegacyDataCap()
            // Ancienne option « Trajet » (0) : un test simple désormais.
            if burstCount < 1 { burstCount = 1 }
            if await presentSpeedtestSharePreviewQAIfNeeded() { return }
            // L'historique est local : l'afficher tout de suite, avant les appels
            // réseau ci-dessous qui peuvent traîner hors couverture (MES-04).
            history = await services.speedtest.history()
            pendingHistoryIds = await services.speedtest.pendingClientIds()
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
            pendingHistoryIds = await services.speedtest.pendingClientIds()
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
                Task {
                    history = await services.speedtest.history()
                    pendingHistoryIds = await services.speedtest.pendingClientIds()
                }
            }
        }
    }

    /// Un seul état à l'écran, comme signalquest.fr/speedtest et Android (piste A) :
    /// le GO au repos, l'anneau pendant la mesure, deux grands chiffres à la fin.
    /// L'historique reste dessous, visible en faisant défiler.
    private func content(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: SQSpace.xl) {
            header {
                withAnimation(SQMotion.resolve(SQMotion.standard, reduceMotion)) {
                    scrollProxy.scrollTo(Self.historyAnchor, anchor: .top)
                }
            }

            if isVPNActive {
                alertCard(
                    title: "VPN actif",
                    message: String(localized: "Ton opérateur ne peut pas être détecté : ce test ne sera pas publié sur la carte."),
                    systemImage: "lock.shield",
                    tone: .warning
                )
            }

            stage

            if let burstSummary {
                burstSummaryCard(burstSummary)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let runErrorMessage {
                runErrorCard(runErrorMessage)
                    .transition(.opacity)
            }

            // Le message brut du serveur (« not found »…) ne dit rien à
            // l'utilisateur : la carte dit ce qui arrive au résultat.
            if errorMessage != nil {
                alertCard(
                    title: "Speedtest non synchronisé",
                    message: String(localized: "Le résultat est gardé sur ton iPhone. Il partira dès que le serveur répondra."),
                    systemImage: "exclamationmark.icloud",
                    tone: .danger,
                    actionTitle: "Réessayer",
                    actionStyle: .secondary,
                    isBusy: isRetryingPendingSave
                ) {
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
                        pendingHistoryIds = await services.speedtest.pendingClientIds()
                    }
                }
                .transition(.opacity)
            }

            historySection
                .id(Self.historyAnchor)
                // La refonte a supprimé le titre « Historique » : l'ancre
                // remplace ce libellé pour les tests UI.
                .accessibilityIdentifier("speedtest.history")
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.sm)
        .padding(.bottom, SQSpace.huge + SQSpace.huge)
        .sqReadableWidth()
    }

    private static let historyAnchor = "speedtest.history.anchor"

    /// GO au repos, anneau pendant la mesure, résultat une fois le test fini.
    @ViewBuilder
    private var stage: some View {
        if isRunning {
            runStage
                .transition(.opacity)
        } else if let result {
            SpeedtestResultSummary(
                result: result,
                deviceBytes: lastRunBytes,
                typical: typicalNearby,
                restartTitle: restartTitle,
                onRestart: start,
                onDetails: { detailsTab = $0 }
            )
            // Une apparition par test, pas à chaque retour sur l'onglet.
            .id(result.id)
            .transition(.opacity)
        } else {
            idleStage
                .transition(.opacity)
        }
    }

    /// Écrans courts (iPhone SE, 8) : le GO et l'anneau rétrécissent pour garder
    /// « Arrêter » et le dernier test au-dessus de la barre d'onglets (UI-01).
    private var stageScale: CGFloat {
        viewportHeight > 0 && viewportHeight < 640 ? 0.82 : 1
    }

    // MARK: - Repos

    private var idleStage: some View {
        VStack(spacing: SQSpace.sm2) {
            SpeedtestGoButton(action: start)
                .scaleEffect(stageScale)
                .frame(width: 300 * stageScale, height: 300 * stageScale)
            networkLine
            serverPill
            if let last = history.first {
                SpeedtestLastTestCard(result: last) { detailResult = last }
                    .padding(.top, SQSpace.sm)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// « ● Orange · 5G NSA » : le lien mesuré, puis son fournisseur. Le point est
    /// vert en ligne, rouge hors ligne.
    private var networkLine: some View {
        let operatorName = headerOperatorName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let network = currentNetworkStatus.displayName
        let parts = [operatorName, network].compactMap { $0 }.filter { !$0.isEmpty }
        return HStack(spacing: 7) {
            Circle()
                .fill(services.networkPath.isOnline ? SQColor.success : SQColor.danger)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(verbatim: parts.joined(separator: " · "))
                .font(SQFont.body(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(SQColor.ink2)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("speedtest.networkLine")
    }

    /// Pastille du serveur : ouvre la page « Serveur de test ».
    private var serverPill: some View {
        Button {
            Haptics.selection()
            showServerPage = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: idleServerLabel)
                    .font(SQFont.body(12.5, .semibold, relativeTo: .footnote))
                    .lineLimit(1)
            }
            .foregroundStyle(SQColor.chipInk)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(SQColor.chip, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityHint("Ouvre le choix du serveur de test")
        .accessibilityIdentifier("speedtest.networkBar")
    }

    /// « Serveur auto » plutôt qu'« Auto » seul, qui ne disait pas de quoi il s'agit.
    private var idleServerLabel: String {
        downloadTarget == .hybridAuto ? String(localized: "Serveur auto") : selectedServerName
    }

    // MARK: - Mesure

    private var runStage: some View {
        VStack(spacing: 14) {
            if let burstProgress {
                burstRunningPill(index: burstProgress.index, total: burstProgress.total)
            }
            SpeedtestRunRing(
                label: ringLabel,
                target: ringTarget,
                unit: phase == .ping ? "ms" : String(localized: "Mbit/s"),
                glides: phase == .download || phase == .upload,
                glideKey: "\(runGeneration)-\(phase.order)",
                progress: ringProgress,
                donePill: donePill
            )
            .scaleEffect(stageScale)
            .frame(width: 300 * stageScale, height: 300 * stageScale)
            .sqAnimation(SQMotion.snappy, value: donePill)

            SpeedtestRunSteps(steps: runSteps)

            SpeedtestSparkline(points: phase == .download || phase == .upload ? sparkPoints : [])

            if let notice = liveProgress.notice {
                Label(notice, systemImage: "arrow.triangle.swap")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.warning)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }

            // L'encre reste réservée à l'action principale : « Arrêter » est discret.
            Button(action: stop) {
                Text(burstProgress == nil ? "Arrêter" : "Arrêter la rafale")
                    .font(SQFont.body(14, .bold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .padding(.horizontal, 26)
                    .frame(minHeight: 48)
                    .background(SQColor.chip, in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityIdentifier("speedtest.stop")
        }
        .frame(maxWidth: .infinity)
    }

    private var ringLabel: String {
        switch liveProgress.stage {
        case "reconnecting": return String(localized: "Reconnexion")
        case "preparation": return String(localized: "Préparation")
        default: break
        }
        switch phase {
        case .ping: return String(localized: "Latence")
        case .download: return String(localized: "Descendant")
        case .upload: return String(localized: "Montant")
        default: return phase.dialTitle
        }
    }

    /// Chiffre visé par l'anneau : la latence telle que mesurée, le débit
    /// instantané pendant les phases de débit (il y glisse).
    private var ringTarget: Double? {
        switch phase {
        case .ping:
            return liveProgress.pingLiveMs ?? liveProgress.pingFinalMs
        case .download:
            return liveProgress.downloadLiveMbps ?? liveProgress.downloadAverageMbps ?? (liveMbps > 0 ? liveMbps : nil)
        case .upload:
            return liveProgress.uploadLiveMbps ?? liveProgress.uploadAverageMbps ?? (liveMbps > 0 ? liveMbps : nil)
        case .saving, .finished:
            return liveProgress.uploadAverageMbps ?? liveProgress.downloadAverageMbps
        default:
            return nil
        }
    }

    private var ringProgress: Double {
        switch phase {
        case .ping:
            guard liveProgress.pingSampleTarget > 0 else { return liveProgress.fraction }
            return Double(liveProgress.pingSampleCount) / Double(liveProgress.pingSampleTarget)
        case .download, .upload:
            return liveProgress.fraction
        case .saving, .finished:
            return 1
        default:
            return 0
        }
    }

    /// Le descendant mesuré se range en haut de l'anneau pendant le montant.
    private var donePill: String? {
        guard phase.order >= SpeedtestPhase.upload.order,
              let down = liveProgress.downloadAverageMbps, down > 0 else { return nil }
        return "↓ \(SQUnits.throughput(mbps: down))"
    }

    private var runSteps: [SpeedtestRunSteps.Step] {
        let current = phase.order
        func state(_ step: SpeedtestPhase) -> SpeedtestRunSteps.Step.State {
            current > step.order ? .done : current == step.order ? .active : .pending
        }
        let ping = liveProgress.pingFinalMs.map { SQUnits.milliseconds($0) }
        let down = liveProgress.downloadAverageMbps.flatMap { $0 > 0 ? SQUnits.throughput(mbps: $0) : nil }
        return [
            .init(id: 0, title: String(localized: "Latence"), value: state(.ping) == .done ? ping : nil, state: state(.ping)),
            .init(id: 1, title: String(localized: "Descendant"), value: state(.download) == .done ? down : nil, state: state(.download)),
            .init(id: 2, title: String(localized: "Montant"), value: nil, state: state(.upload))
        ]
    }

    /// Tracé de la phase de débit en cours : un point par mise à jour, posé à sa
    /// progression ; il repart de zéro à chaque phase ou reprise.
    private func recordSparkPoint(_ update: SpeedtestLiveProgress) {
        let value: Double?
        switch update.phase {
        case .download: value = update.downloadLiveMbps ?? update.currentMbps
        case .upload: value = update.uploadLiveMbps ?? update.currentMbps
        default: value = nil
        }
        let key = update.phase.order
        if key != sparkPhase || (sparkPoints.last.map { update.fraction < $0.progress - 0.05 } ?? false) {
            sparkPhase = key
            sparkPoints = []
        }
        // La chauffe arrive à la progression 0 : la garder dessinait un trait
        // vertical depuis la ligne de base au début du tracé.
        guard let value, value.isFinite, value >= 0, update.fraction > 0,
              update.stage != "warmup", update.stage != "preparation" else { return }
        if let last = sparkPoints.last, update.fraction - last.progress < 0.004 { return }
        sparkPoints.append(.init(progress: update.fraction, value: value))
    }

    // MARK: - En-tête : titre, partage, historique et menu ⋮

    private func header(showHistory: @escaping () -> Void) -> some View {
        HStack(spacing: SQSpace.xs) {
            Text("Speedtest")
                .font(SQFont.display(28, .heavy, relativeTo: .largeTitle))
                .foregroundStyle(SQColor.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sqHeader()
            if !isRunning, let result {
                headerButton(systemImage: "square.and.arrow.up", label: "Partager le résultat") {
                    Haptics.light()
                    sharePreviewResult = result
                }
                .accessibilityIdentifier("speedtest.share")
            }
            headerButton(systemImage: "clock.arrow.circlepath", label: "Historique", action: showHistory)
                .accessibilityIdentifier("speedtest.historyButton")
            Menu {
                Button { showDriveTest = true } label: {
                    Label("Drive Test", systemImage: "location.north.line.fill")
                }
                .accessibilityIdentifier("speedtest.driveTest")
                Picker(selection: $burstCount) {
                    Text("1 test").tag(1)
                    ForEach([3, 5, 10], id: \.self) { count in
                        Text("Rafale de \(count) tests").tag(count)
                    }
                } label: {
                    Label("Rafale", systemImage: "bolt.fill")
                }
                .pickerStyle(.menu)
                .disabled(isRunning)
                Button { showSettings = true } label: {
                    Label("Réglages du test", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("speedtest.settings")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(width: 44, height: 44)
                    .sqSurface(SQColor.chip, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel(Text("Plus : Drive Test, rafale, réglages"))
            .accessibilityIdentifier("speedtest.more")
        }
        .frame(maxWidth: .infinity)
    }

    private func headerButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SQColor.label)
                .frame(width: 44, height: 44)
                .sqSurface(SQColor.chip, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(LocalizedStringKey(label))
    }

    private var dataWarningMessage: String {
        var parts: [String] = []
        if services.networkPath.status.isConstrained {
            parts.append(String(localized: "Le Mode données faibles est activé."))
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

    private var restartTitle: String {
        // Traduits ici : « ×3 » n'était pas une clé du catalogue (TRX-06).
        burstCount > 1 ? String(localized: "Relancer la rafale ×\(burstCount)") : String(localized: "Relancer")
    }

    @ViewBuilder
    private func burstRunningPill(index: Int, total: Int) -> some View {
        HStack(spacing: SQSpace.sm2) {
            Label {
                Text("Rafale · test \(index)/\(total)")
            } icon: {
                Image(systemName: "bolt.fill")
            }
            .font(SQFont.body(12, .semibold))
            .foregroundStyle(SQColor.onInk)
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 28)
            .background(SQColor.label, in: Capsule(style: .continuous))
            // Un segment par test : vert une fois mesuré, encre pour le test en
            // cours, teinte de la piste de la jauge pour les suivants.
            HStack(spacing: SQSpace.xs) {
                ForEach(1...max(total, 1), id: \.self) { step in
                    Capsule(style: .continuous)
                        .fill(step < index ? SQColor.success : step == index ? SQColor.label : SQColor.labelTertiary.opacity(0.28))
                        .frame(width: total > 5 ? 12 : 22, height: 5)
                }
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Share

    private func resetShareState() {
        sharePreviewResult = nil
    }

    // MARK: - Débit habituel autour du test

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

    /// Ligne clé · · · valeur, comme le « Diagnostic radio » du web. Les très
    /// grands textes empilent la clé et la valeur plutôt que de les tronquer.
    private func detailItem(label: String, value: String, trailing: String? = nil, highlight: Bool = false) -> some View {
        let valueText = HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(SQFont.body(14, .bold, relativeTo: .subheadline))
                .monospacedDigit()
                .foregroundStyle(highlight ? SQColor.accentInk : SQColor.label)
                .multilineTextAlignment(.trailing)
            if let trailing {
                Text(trailing)
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        let labelText = Text(LocalizedStringKey(label))
            .font(SQType.subhead(.regular))
            .foregroundStyle(SQColor.labelSecondary)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    labelText
                    valueText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Le libellé et la valeur passent avant les pointillés, qui
                // remplissent seulement l'espace restant.
                HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                    labelText
                        .layoutPriority(1)
                    SQDotLeader()
                        .frame(minWidth: SQSpace.md, maxWidth: .infinity)
                        .frame(height: 1)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    valueText
                        .layoutPriority(1)
                }
                .frame(minHeight: 28)
            }
        }
    }

    // MARK: - Alerts

    enum AlertTone { case warning, danger, brand }

    enum RunErrorKind: Equatable {
        case failure
        case networkChanged(from: String, to: String)
        case driveTestRunning
    }

    @ViewBuilder
    private func runErrorCard(_ message: String) -> some View {
        switch runErrorKind {
        case let .networkChanged(from, to):
            alertCard(
                title: "Test arrêté : réseau changé",
                message: String(localized: "\(from) → \(to) pendant la mesure. Relance le test pour mesurer une connexion stable."),
                systemImage: "arrow.left.arrow.right",
                tone: .warning
            )
        case .driveTestRunning:
            alertCard(
                title: "Un Drive Test est en cours",
                message: String(localized: "Ouvre-le pour suivre ses mesures, ou arrête-le avant un test simple."),
                systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                tone: .brand,
                actionTitle: "Ouvrir le Drive Test",
                actionIcon: nil,
                actionStyle: .secondary
            ) {
                runErrorMessage = nil
                showDriveTest = true
            }
        case .failure:
            alertCard(title: "Speedtest impossible", message: message, systemImage: "exclamationmark.triangle", tone: .danger, actionTitle: "Réessayer") {
                runErrorMessage = nil
                start()
            }
        }
    }

    /// Carte d'alerte Halo : ambre posée sur le fond pour un avertissement,
    /// carte blanche à pastille rouge pour un échec (carmin pour une
    /// information), l'action en dessous. Le message brut du serveur n'y figure
    /// pas : il reste dans les journaux de l'APIClient.
    private func alertCard(
        title: String,
        message: String,
        systemImage: String,
        tone: AlertTone,
        actionTitle: String? = nil,
        actionIcon: String? = "arrow.clockwise",
        actionStyle: GradientButton.Style = .primary,
        isBusy: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.sm2) {
                SQIconPastille(
                    systemImage: systemImage,
                    size: 32,
                    tint: tone == .danger ? SQColor.dangerInk : tone == .brand ? SQColor.accentInk : SQColor.warning,
                    fill: tone == .danger ? SQColor.dangerSoft : tone == .brand ? SQColor.accentSoft : SQColor.chip,
                    font: .system(size: 14, weight: .semibold)
                )
                Text(LocalizedStringKey(title))
                    .font(SQFont.body(15, .bold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(message)
                .font(SQType.subhead(.regular))
                .foregroundStyle(SQColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                GradientButton(actionTitle, systemImage: actionIcon, isBusy: isBusy, style: actionStyle, action: action)
                    .padding(.top, SQSpace.xxs)
            }
        }
        .padding(SQSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if tone == .warning {
                RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                    .fill(SQColor.warningSoft)
            }
        }
        .modifier(AlertCardSurface(isCard: tone != .warning))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Burst summary

    private func burstSummaryCard(_ s: SpeedtestBurstSummary) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(alignment: .center) {
                Label {
                    Text(verbatim: "\(String(localized: "Rafale")) · \(String(localized: "\(s.count) test"))")
                } icon: {
                    Image(systemName: "bolt.fill")
                }
                .font(SQFont.body(12, .bold, relativeTo: .caption))
                .tracking(12 * 0.16)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
                Spacer()
                if s.truncatedAt != nil {
                    Text("arrêtée")
                        .font(SQType.micro)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(SQColor.warningSoft, in: Capsule(style: .continuous))
                        .foregroundStyle(SQColor.warning)
                }
            }
            .frame(minHeight: 28)
            VStack(spacing: SQSpace.xs) {
                detailItem(label: "Réception (moyenne)", value: speed(s.avgDownload), highlight: true)
                detailItem(label: "Réception (pic)", value: speed(s.maxDownload), highlight: true)
                detailItem(label: "Envoi (moyenne)", value: speed(s.avgUpload))
                // Aucun ping valide dans la rafale : le cumul vaut 0, pas « 0 ms ».
                detailItem(label: "Latence (minimum)", value: ms(s.minPing > 0 ? s.minPing : nil))
            }
        }
        .padding(SQSpace.cardPadding)
        .sqCardBackground()
    }

    // MARK: - Settings sheet (unchanged behaviour)

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    MessageSheetHeader(title: "Réglages du test", closeIdentifier: "speedtest.settings.close") {
                        showSettings = false
                    }
                    .padding(.bottom, SQSpace.xs)

                    settingsKicker("Nombre de tests")
                    MapSegmented(
                        selection: $burstCount,
                        options: [(1, String(localized: "1 test")), (3, "3"), (5, "5"), (10, "10")],
                        identifier: "speedtest.settings.burst"
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Nombre de tests")
                    // L'option « Trajet » ouvrait le Drive Test, qui a ses propres
                    // réglages de distance et de plafond : elle faisait doublon.
                    settingsFootnote("Un seul test, ou plusieurs tests à la suite. Pour mesurer en roulant, utilise le Drive Test.")

                    settingsKicker("Serveur et durée")
                        .padding(.top, SQSpace.sm)
                    VStack(spacing: 0) {
                        NavigationLink {
                            serverPage
                        } label: {
                            HStack(spacing: SQSpace.md) {
                                SQIconPastille(systemImage: "server.rack", size: 34, font: .system(size: 14, weight: .semibold))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Serveur de test")
                                        .font(SQFont.body(15, .semibold))
                                        .foregroundStyle(SQColor.label)
                                    Text(verbatim: selectedServerName)
                                        .font(SQType.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(SQColor.labelTertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, SQSpace.cardPadding)
                            .padding(.vertical, SQSpace.sm2)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("speedtest.settings.advanced")

                        Rectangle()
                            .fill(SQColor.separator)
                            .frame(height: 1)
                            .padding(.leading, SQSpace.cardPadding + 34 + SQSpace.md)

                        VStack(alignment: .leading, spacing: SQSpace.xs) {
                            HStack(spacing: SQSpace.md) {
                                SQIconPastille(systemImage: "timer", size: 34, font: .system(size: 14, weight: .semibold))
                                Text("Durée de chaque sens")
                                    .font(SQFont.body(15, .semibold))
                                    .foregroundStyle(SQColor.label)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(verbatim: "\(durationSeconds) s")
                                    .font(SQFont.body(14, .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(SQColor.label)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(durationSeconds) },
                                    set: { durationSeconds = Int($0.rounded()).clamped(to: 5...30) }
                                ),
                                in: 5...30,
                                step: 1
                            ) {
                                Text("Durée de chaque sens")
                            } minimumValueLabel: {
                                Text(verbatim: "5 s").font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                            } maximumValueLabel: {
                                Text(verbatim: "30 s").font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                            }
                            .tint(SQColor.brandRed)
                            .accessibilityValue(String(localized: "\(durationSeconds) seconde"))
                            .padding(.leading, 34 + SQSpace.md)
                        }
                        .padding(.horizontal, SQSpace.cardPadding)
                        .padding(.vertical, SQSpace.sm2)
                    }
                    .padding(.vertical, 2)
                    .sqCardBackground()
                    settingsFootnote("Tes speedtests en réseau mobile apparaissent sur la carte à l’endroit où tu les as faits, sauf dans tes zones privées.")
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.lg)
                .padding(.bottom, SQSpace.xl)
            }
            .accessibilityIdentifier("speedtest.settings.scroll")
            .signalQuestBackground()
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
    }

    private var serverPage: some View {
        SpeedtestServerPage(
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
    }

    /// Serveur affiché sous « Serveur de test » : le POP du catalogue ou le
    /// serveur LibreSpeed choisi, sinon le nom du moteur.
    private var selectedServerName: String {
        switch downloadTarget {
        case .iperfCatalog:
            return iperfCatalogServers.first { $0.id == iperfServerId }?.name ?? downloadTarget.displayName
        case .libreSpeed:
            let host = libreSpeedServers.first { $0.hostname == libreSpeedHost }?.name
            return "\(downloadTarget.displayName) · \(host ?? String(localized: "Le plus proche"))"
        default:
            return downloadTarget.displayName
        }
    }

    private func settingsKicker(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(SQFont.body(12, .bold, relativeTo: .caption))
            .tracking(12 * 0.14)
            .textCase(.uppercase)
            .foregroundStyle(SQColor.labelSecondary)
            .padding(.horizontal, SQSpace.xs)
            .sqHeader()
    }

    private func settingsFootnote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SQSpace.xs)
    }

    // MARK: - History

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
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        historyKicker("Tes tests")
                        VStack(spacing: 0) {
                            ForEach(Array(history.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { historyDivider }
                                Button {
                                    Haptics.selection()
                                    detailResult = item
                                } label: {
                                    SpeedtestHistoryRow(result: item, isPending: pendingHistoryIds.contains(item.id))
                                }
                                .buttonStyle(SQPressButtonStyle())
                                .accessibilityHint("Voir le détail du test")
                            }
                        }
                        .padding(.vertical, 2)
                        // Fond de carte commun : liseré en « Noir intense » (TRX-09).
                        .sqCardBackground()
                        .sqFadeUp()
                    }
                }
                if !accountOnlyHistory.isEmpty {
                    accountHistorySection
                }
            }
        }
    }

    /// Surtitre de section (« Tes tests », « Sur ton compte »), 12 pt : le
    /// kicker de 11 pt ne passe pas l'audit de contraste.
    private func historyKicker(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(SQFont.body(12, .bold, relativeTo: .caption))
            .tracking(12 * 0.14)
            .textCase(.uppercase)
            .foregroundStyle(SQColor.labelSecondary)
            .padding(.horizontal, SQSpace.xs)
            .sqHeader()
    }

    private var historyDivider: some View {
        Rectangle()
            .fill(SQColor.separator)
            .frame(height: 1)
            .padding(.leading, SQSpace.cardPadding)
    }

    /// Les tests du compte absents de ce téléphone : après une réinstallation
    /// ou sur un nouvel iPhone, l'onglet n'affiche plus « Aucun test » pour un
    /// compte qui en a des centaines (UI-12).
    private var accountHistorySection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                historyKicker("Sur ton compte")
                Text("Tes tests faits sur un autre appareil ou avant une réinstallation.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SQSpace.xs)
            }
            .padding(.top, history.isEmpty ? 0 : SQSpace.sm)
            VStack(spacing: 0) {
                ForEach(Array(accountOnlyHistory.enumerated()), id: \.element.id) { index, test in
                    if index > 0 { historyDivider }
                    AccountSpeedtestRow(test: test)
                }
            }
            .padding(.vertical, 2)
            .sqCardBackground()
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
            HStack(spacing: SQSpace.sm2) {
                SQIconPastille(systemImage: "map", size: 32, tint: SQColor.accentInk, fill: SQColor.accentSoft,
                               font: .system(size: 14, weight: .semibold))
                Text("Tes speedtests sur la carte")
                    .font(SQFont.body(15, .bold))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Tes speedtests en réseau mobile, anciens compris, apparaissent sur la carte à l’endroit où tu les as faits. Ceux faits dans tes zones privées restent cachés. Pour en masquer un, ouvre-le dans ton historique.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Compris") {
                Haptics.selection()
                mapPublicationNoticeSeen = true
            }
            .font(SQFont.body(14, .bold))
            .foregroundStyle(SQColor.accentInk)
            .frame(minHeight: 44)
            .accessibilityIdentifier("speedtest.mapPublicationNotice.dismiss")
        }
        .padding(SQSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speedtest.mapPublicationNotice")
    }

    // MARK: - Derived state

    private var isRunning: Bool {
        runTask != nil
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

    // MARK: - Lifecycle

    private func start() {
        // Un Drive Test mesure déjà : deux tests simultanés se partageraient la
        // bande passante et se fausseraient l'un l'autre (MES-18).
        if services.driveTest.isRunning {
            // Ce n'est pas un échec de synchronisation (AF-MES-02).
            runErrorMessage = String(localized: "Un Drive Test est en cours : ouvre-le pour suivre ses mesures, ou arrête-le avant un test simple.")
            runErrorKind = .driveTestRunning
            return
        }
        // Un test lancé depuis la voiture mesure déjà (CAR-05).
        if services.speedtest.isRunning {
            runErrorMessage = SpeedtestBusyError.alreadyRunning.errorDescription
            runErrorKind = .failure
            return
        }
        // Réseau mobile ou Mode données faibles : un test peut consommer
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
        if burstCount > 1 {
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
                    recordSparkPoint(update)
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
        pendingHistoryIds = await services.speedtest.pendingClientIds()
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
                runErrorKind = .failure
                phase = .failed(error.userFacingMessage)
                liveProgress = SpeedtestLiveProgress(phase: .failed(error.userFacingMessage))
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
        burstResults = []
        runTask = Task {
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
                    burstResults.append(measured)
                } catch is CancellationError {
                    guard runSessionID == sessionID else { return }
                    truncatedAt = max(0, index - 1)
                    break loop
                } catch {
                    guard runSessionID == sessionID else { return }
                    // Un test raté n'interrompt pas la rafale : on note et on continue.
                    runErrorMessage = error.userFacingMessage
                    runErrorKind = .failure
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
            let summary = SpeedtestBurstSummary(results: burstResults, truncatedAt: truncatedAt)
            if Task.isCancelled {
                if !burstResults.isEmpty { burstSummary = summary }
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
            runErrorMessage = networkAbortMessage
            phase = .failed(networkAbortMessage)
        } else {
            phase = .idle
            liveProgress = SpeedtestLiveProgress(phase: .idle)
        }
    }

    private func liveActivityPhaseLabel(_ phase: SpeedtestPhase, runIndex: Int, runTotal: Int) -> String {
        runTotal > 1 ? String(localized: "Test \(runIndex)/\(runTotal) · \(phase.displayTitle)") : phase.displayTitle
    }

    /// Bilan partiel d'une rafale interrompue (arrêt ou changement de réseau) :
    /// la tâche annulée ne peut plus le publier une fois la session remise à
    /// zéro, on le construit donc avant.
    private func keepPartialBurstSummary() {
        if let burstProgress, !burstResults.isEmpty {
            burstSummary = SpeedtestBurstSummary(
                results: burstResults,
                truncatedAt: max(0, burstProgress.index - 1)
            )
        }
    }

    private func stop() {
        keepPartialBurstSummary()
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
        runErrorMessage = message
        runErrorKind = .networkChanged(from: previousNetwork, to: newNetwork)
        keepPartialBurstSummary()
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
        // Variante au-delà du gigabit : « 1,722 Gb/s » ne doit déborder nulle part.
        let gigabit = ProcessInfo.processInfo.arguments.contains("--qa-speedtest-gigabit")
        let fixture = SpeedtestRunResult(
            label: "QA partage Speedtest",
            downloadMbps: gigabit ? 1_722.4 : 734.8,
            downloadAverageMbps: gigabit ? 1_722.4 : 734.8,
            downloadMaxMbps: gigabit ? 1_841.2 : 812.4,
            uploadMbps: gigabit ? 1_004.3 : 126.4,
            uploadAverageMbps: gigabit ? 1_004.3 : 126.4,
            uploadMaxMbps: gigabit ? 1_012.9 : 131.0,
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
            // Ping et débit sur la même machine : la note A–F sous charge s'affiche.
            downloadServerHost: "paris.qa.invalid",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            downloadSeriesMbps: [120, 280, 510, 720, 770, 748, 734],
            uploadSeriesMbps: [22, 54, 91, 122, 126, 124],
            downloadGraceWindowCount: 2,
            uploadGraceWindowCount: 1,
            uploadMeasurementSource: "iperf3",
            deviceModel: "iPhone 17 Pro",
            osVersion: "iOS 27",
            pingServerHost: "paris.qa.invalid"
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

/// Gigue : la règle de `SQUnits` (une décimale sous 10 ms), la même qu'au détail du test.
private func jitterLabel(_ value: Double?) -> String {
    guard let value else { return "—" }
    return SQUnits.jitter(value)
}

// MARK: - Phase extensions

// MARK: - Server picker (iPerf3 OVH + Bouygues)

// MARK: - Comparable helper

/// Fond de carte des alertes d'échec ; l'avertissement reste un aplat ambre.
private struct AlertCardSurface: ViewModifier {
    let isCard: Bool

    func body(content: Content) -> some View {
        if isCard {
            content.sqCardBackground()
        } else {
            content
        }
    }
}
