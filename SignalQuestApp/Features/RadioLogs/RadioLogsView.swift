import SwiftUI

private typealias M = RadioLogsMetrics
private typealias P = RadioLogsPalette

/// « Logs antennes » — le journal radio du compte, en liste de SITES.
///
/// L'unité n'est plus la cellule mais le site (eNB/gNB) : `identify/quick` rend
/// le même `siteId` avec ou sans PCI, donc l'identification porte sur le nœud.
/// Les PCI et les ECI restent visibles, en pastilles, mais comme
/// CARACTÉRISTIQUES du site — plus aucun bouton pour les valider. Ils décrivent,
/// ils ne demandent rien.
///
/// Le journal est alimenté par la capture Android et lu ici : iOS n'écrit jamais
/// dans le journal, il ne fait qu'en tirer les sites et demander au serveur
/// lesquels sont déjà identifiés.
struct RadioLogsView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: RadioLogsViewModel
    @State private var showsFilterSheet = false
    @State private var showsSearch = false
    @State private var identifyTarget: RadioLogSite?
    @State private var chainQueue: RadioLogChainQueue?
    @State private var mapTarget: RadioLogSite?
    @State private var showsPurgeConfirmation = false

    init(service: RadioLogsServicing, antennas: AntennasServicing, networkPath: NetworkPathMonitor) {
        _model = StateObject(
            wrappedValue: RadioLogsViewModel(service: service, antennas: antennas, networkPath: networkPath)
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if showsSearch {
                    SQSearchField(text: $model.searchText, placeholder: "eNB, gNB, opérateur…")
                        .padding(.bottom, SQSpace.md)
                }
                if let premiumMessage = model.premiumMessage {
                    premiumBanner(premiumMessage)
                }
                if model.isScanning || model.isSyncing {
                    scanBanner
                }
                tally
                filterRail
                completionLine
                if !model.chainCandidates.isEmpty {
                    chainCallToAction
                }
                content
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.bottom, SQSpace.huge)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .navigationTitle("Logs antennes")
        .toolbarTitleInlineCompat()
        .toolbar { toolbarContent }
        .refreshable { await model.refresh() }
        .task { await model.onAppear() }
        .sheet(isPresented: $showsFilterSheet) {
            RadioLogsFilterSheet(model: model)
        }
        .sheet(item: $identifyTarget) { site in
            RadioLogIdentifySheet(
                site: site,
                service: services.radioLogs,
                identify: services.identify,
                antennas: services.antennas,
                customSites: services.customSites
            ) { siteId in
                model.markIdentified(site, siteId: siteId)
                model.toast = String(localized: "Site identifié.")
            }
        }
        .sheet(item: $chainQueue) { queue in
            RadioLogIdentifyChainView(
                sites: queue.sites,
                service: services.radioLogs,
                identify: services.identify,
                antennas: services.antennas,
                customSites: services.customSites
            ) { site, siteId in
                model.markIdentified(site, siteId: siteId)
            }
        }
        .sheet(item: $mapTarget) { site in
            RadioLogSiteMapSheet(site: site)
        }
        .alert("Supprimer le journal radio ?", isPresented: $showsPurgeConfirmation) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) { Task { await model.purge() } }
        } message: {
            Text("Les \(model.logCount) relevés synchronisés seront effacés du serveur et de cet appareil. Les identifications que tu as faites, elles, sont conservées.")
        }
        .overlay(alignment: .bottom) { toastOverlay }
        .animation(SQMotion.standard, value: model.expandedSiteId)
    }

    // MARK: - Barre supérieure

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: SQSpace.md) {
                Button {
                    showsSearch.toggle()
                    if !showsSearch { model.searchText = "" }
                    Haptics.selection()
                } label: {
                    Image(systemName: showsSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                }
                .accessibilityLabel("Rechercher un site")

                Menu {
                    Button {
                        showsFilterSheet = true
                    } label: {
                        Label("Trier et filtrer", systemImage: "line.3.horizontal.decrease")
                    }
                    Button {
                        model.rescanAll()
                    } label: {
                        Label("Tout revérifier", systemImage: "arrow.clockwise")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showsPurgeConfirmation = true
                    } label: {
                        Label("Supprimer le journal", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Plus d'options")
            }
        }
    }

    // MARK: - Bandeau de balayage

    /// `.scan` — le bandeau de vérification du catalogue.
    ///
    /// C'est un élément de CONTENU, pas une barre système : il partage le
    /// vocabulaire des cartes, se suspend d'un geste, et disparaît une fois le
    /// catalogue résolu.
    private var scanBanner: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: M.scanHeadGap) {
                Circle()
                    .fill(P.accent)
                    .frame(width: M.scanDot, height: M.scanDot)
                    .overlay(Circle().stroke(P.accentSoft, lineWidth: 4))
                    .accessibilityHidden(true)
                Text(model.isSyncing ? "Récupération du journal" : "Vérification du catalogue")
                    .font(SQFont.body(M.scanTitleSize, .bold))
                    .foregroundStyle(P.ink)
                Spacer(minLength: 0)
                if !model.isSyncing {
                    Button {
                        model.toggleScan()
                        Haptics.selection()
                    } label: {
                        Text(model.isScanning ? "Suspendre" : "Reprendre")
                            .font(SQFont.body(M.scanActionSize, .bold))
                            .foregroundStyle(P.accentInk)
                            .padding(.horizontal, M.scanActionPaddingH)
                            .padding(.vertical, M.scanActionPaddingV)
                            .background(P.accentSoft, in: RoundedRectangle(cornerRadius: M.scanActionRadius, style: .continuous))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, M.scanHeadBottom)

            progressBar(value: model.isSyncing ? nil : model.completion, height: M.barHeight, tint: P.accent)

            Text(scanSubtitle)
                .font(SQFont.body(M.scanSubSize))
                .monospacedDigit()
                .foregroundStyle(P.muted)
                .padding(.top, M.scanSubTop)
        }
        .padding(.horizontal, M.scanPaddingH)
        .padding(.vertical, M.scanPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.card, in: RoundedRectangle(cornerRadius: M.scanRadius, style: .continuous))
        .sqShadowCard()
        .padding(.bottom, M.scanBottom)
        .accessibilityElement(children: .contain)
    }

    private var scanSubtitle: String {
        if model.isSyncing {
            return model.syncReceived == 0
                ? String(localized: "Connexion au journal…")
                : "\(model.syncReceived.formatted()) relevés reçus"
        }
        return "\(model.checkedCount.formatted()) sites vérifiés sur \(model.totalCount.formatted())"
    }

    /// Barre de progression. `value == nil` = indéterminée (on ne connaît pas
    /// encore le total à recevoir : afficher une fraction inventée serait faux).
    private func progressBar(value: Double?, height: CGFloat, tint: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(P.barTrack)
                if let value {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, min(1, value)) * proxy.size.width)
                } else {
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * 0.3)
                        .modifier(IndeterminateSlide(width: proxy.size.width))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    // MARK: - Dénombrement et filtres

    /// `.tally` — combien de sites, combien de relevés.
    private var tally: some View {
        HStack(spacing: M.tallyGap) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(P.accentInk)
                .frame(width: M.tallyBadge, height: M.tallyBadge)
                .background(P.accentSoft, in: RoundedRectangle(cornerRadius: M.tallyBadgeRadius, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.totalCount <= 1 ? "\(model.totalCount) site" : "\(model.totalCount.formatted()) sites")
                    .font(SQFont.display(M.tallyNumberSize, .bold))
                    .foregroundStyle(P.ink)
                Text(tallySubtitle)
                    .font(SQFont.body(M.tallySubSize))
                    .foregroundStyle(P.muted)
            }
            .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.bottom, M.tallyBottom)
        .accessibilityElement(children: .combine)
    }

    private var tallySubtitle: String {
        var parts = ["\(model.logCount.formatted()) relevés"]
        if let lastSyncedAt = model.lastSyncedAt {
            parts.append("synchronisé \(lastSyncedAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    /// `.rail` — les compteurs portent sur le CATALOGUE ENTIER, pas sur une
    /// fenêtre chargée.
    private var filterRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: M.railGap) {
                ForEach(RadioLogsViewModel.Filter.allCases) { option in
                    let isSelected = model.filter == option
                    Button {
                        model.filter = option
                        Haptics.selection()
                    } label: {
                        Text("\(option.label) · \(model.count(for: option).formatted())")
                            .font(SQFont.body(M.chipSize, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? P.accentInk : P.chipInk)
                            .padding(.horizontal, M.chipPaddingH)
                            .padding(.vertical, M.chipPaddingV)
                            .background {
                                Capsule(style: .continuous)
                                    .fill(isSelected ? P.accentSoft : P.chip)
                                    .overlay {
                                        if isSelected {
                                            Capsule(style: .continuous)
                                                .strokeBorder(P.accent.opacity(0.32), lineWidth: 1)
                                        }
                                    }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.bottom, M.railBottom)
    }

    /// `.done-line` — la complétude PERMANENTE. Elle reste après le balayage :
    /// elle dit l'état de CONNAISSANCE du catalogue, pas une tâche en cours.
    @ViewBuilder
    private var completionLine: some View {
        if model.totalCount > 0 {
            HStack(spacing: M.doneGap) {
                progressBar(value: model.completion, height: M.doneBarHeight, tint: P.okInk)
                Text("\(Int((model.completion * 100).rounded())) % vérifié")
                    .font(SQFont.body(M.doneTextSize))
                    .monospacedDigit()
                    .foregroundStyle(P.muted)
                    .fixedSize()
            }
            .padding(.bottom, M.doneBottom)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Catalogue vérifié à \(Int((model.completion * 100).rounded())) pour cent")
        }
    }

    /// L'entrée de la file en chaîne. Elle n'ouvre pas douze fois le même écran :
    /// elle ouvre UNE file, dont on sort à tout moment.
    private var chainCallToAction: some View {
        let candidates = model.chainCandidates
        return Button {
            chainQueue = RadioLogChainQueue(sites: Array(candidates.prefix(50)))
            Haptics.selection()
        } label: {
            HStack(spacing: SQSpace.md) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 15, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Identifier \(min(candidates.count, 50)) sites à la suite")
                        .font(SQFont.body(13, .bold))
                    Text("un site après l'autre, sortie à tout moment")
                        .font(SQFont.body(11.5))
                        // Pas d'opacité sous 13 pt sur aplat brique : l'anti-crénelage
                        // mange déjà ~23 % du contraste (DesignTokenContrastTests).
                        .foregroundStyle(P.onAccent)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(P.onAccent)
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(P.accent, in: RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.bottom, M.cardSpacing)
    }

    // MARK: - Liste

    @ViewBuilder
    private var content: some View {
        if model.sites.isEmpty {
            emptyState
        } else if model.filteredCount == 0 {
            EmptyStateView(
                title: "Aucun site",
                message: "Aucun site ne correspond à ce filtre.",
                systemImage: "line.3.horizontal.decrease.circle"
            )
            .padding(.top, SQSpace.xl)
        } else {
            ForEach(model.sections) { section in
                if let operatorName = section.operatorName {
                    RadioLogOperatorHeader(
                        operatorName: operatorName,
                        siteCount: section.sites.count,
                        logCount: section.logCount
                    )
                }
                ForEach(section.sites) { site in
                    RadioLogSiteCard(
                        site: site,
                        state: model.state(of: site),
                        siteName: model.siteNames[site.id],
                        isExpanded: model.expandedSiteId == site.id,
                        onIdentify: { identifyTarget = site },
                        onOpenMap: { mapTarget = site }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleExpansion(site) }
                    .padding(.bottom, M.cardSpacing)
                    .onAppear {
                        // La commune n'est chargée que pour ce qui s'affiche —
                        // c'est un GET par site, et la liste en compte des milliers.
                        if model.state(of: site).isIdentified { model.loadSiteName(for: site) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isSyncing {
            LoadingSkeleton()
                .padding(.top, SQSpace.xl)
        } else if let errorMessage = model.errorMessage {
            ErrorStateView(
                title: "Journal indisponible",
                message: errorMessage,
                retry: { Task { await model.refresh() } }
            )
            .padding(.top, SQSpace.xl)
        } else {
            EmptyStateView(
                title: "Aucun relevé",
                message: "Ton journal radio est vide. Il se remplit depuis l'application Android, qui capte les cellules pendant tes trajets.",
                systemImage: "antenna.radiowaves.left.and.right"
            )
            .padding(.top, SQSpace.xl)
        }
    }

    private func premiumBanner(_ message: String) -> some View {
        Label(message, systemImage: "lock.fill")
            .font(SQType.caption)
            .foregroundStyle(SQColor.warning)
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SQColor.warningSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .padding(.bottom, SQSpace.md)
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = model.toast {
            Text(toast)
                .font(SQType.caption)
                .foregroundStyle(SQColor.onInk)
                .padding(.horizontal, SQSpace.lg)
                .padding(.vertical, SQSpace.md)
                .background(SQColor.label, in: Capsule(style: .continuous))
                .padding(.bottom, SQSpace.xxl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    model.toast = nil
                }
        }
    }
}

/// Glissement de la barre indéterminée. Une animation de 1,1 s, respectueuse de
/// « Réduire les animations » : sous ce réglage la barre reste fixe plutôt que de
/// balayer l'écran en boucle.
private struct IndeterminateSlide: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let width: CGFloat
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    offset = width * 0.7
                }
            }
    }
}

/// Enveloppe `Identifiable` pour présenter la file en `sheet(item:)`.
struct RadioLogChainQueue: Identifiable {
    let id = UUID()
    let sites: [RadioLogSite]
}
