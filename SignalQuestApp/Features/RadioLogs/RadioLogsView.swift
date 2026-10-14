import SwiftUI

private typealias M = RadioLogsMetrics
private typealias P = RadioLogsPalette

/// « Logs antennes » — le journal radio du compte, en liste de SITES.
///
/// L'unité n'est plus la cellule mais le site (eNB/gNB) : `identify/quick` rend
/// le même `siteId` avec ou sans PCI, donc l'identification porte sur le nœud.
/// Les PCI et les ECI restent visibles, dans le dépliage, mais comme
/// CARACTÉRISTIQUES du site — plus aucun bouton pour les valider. Ils décrivent,
/// ils ne demandent rien.
///
/// Le journal est alimenté par la capture Android et lu ici : iOS n'écrit jamais
/// dans le journal, il ne fait qu'en tirer les sites et demander au serveur
/// lesquels sont déjà identifiés.
///
/// Une `List` plutôt qu'une pile : le journal compte des milliers de sites, et
/// une carte par opérateur doit rester paresseuse ligne à ligne.
struct RadioLogsView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RadioLogsViewModel
    @State private var showsFilterSheet = false
    @State private var showsSearch = false
    @State private var identifyTarget: RadioLogSite?
    @State private var chainQueue: RadioLogChainQueue?
    @State private var mapTarget: RadioLogSite?
    @State private var showsPurgeConfirmation = false
    @State private var showsPremiumPaywall = false
    @State private var isRefreshingEntitlement = false

    init(service: RadioLogsServicing, antennas: AntennasServicing, networkPath: NetworkPathMonitor) {
        _model = StateObject(
            wrappedValue: RadioLogsViewModel(service: service, antennas: antennas, networkPath: networkPath)
        )
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.xs, trailing: 0))
                    .listRowBackground(Color.clear)
                if showsSearch {
                    SQSearchField(text: $model.searchText, placeholder: "eNB, gNB, opérateur…")
                        .accessibilityIdentifier("radioLogs.searchField")
                        .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: 0, bottom: SQSpace.xs, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                if let premiumMessage = model.premiumMessage {
                    premiumBanner(premiumMessage)
                        .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: 0, bottom: SQSpace.xs, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                // Avec un journal en cache, l'échec de synchronisation ou de
                // purge ne se voyait nulle part (AF-RAD-08) : le cache reste,
                // l'échec se dit au-dessus.
                if let errorMessage = model.errorMessage, !model.sites.isEmpty, !model.isSyncing {
                    inlineError(errorMessage)
                        .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: 0, bottom: SQSpace.xs, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                if !model.sites.isEmpty || model.isSyncing {
                    summaryCard
                        .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: 0, bottom: SQSpace.xs, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                if !model.sites.isEmpty {
                    SQSegmentedFilter(
                        selection: $model.filter,
                        options: RadioLogsViewModel.Filter.allCases.map { option in
                            (value: option, label: "\(option.label) · \(model.count(for: option).formatted())", icon: String?.none)
                        }
                    )
                    .accessibilityIdentifier("radioLogs.filter")
                    // Le segment ajoute sa propre marge latérale de 16 pt : on la compense.
                    .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: -SQSpace.lg, bottom: 0, trailing: -SQSpace.lg))
                    .listRowBackground(Color.clear)
                    sortSummary
                        .listRowInsets(EdgeInsets(top: 0, leading: SQSpace.xs, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                if !model.chainCandidates.isEmpty {
                    chainCallToAction
                        .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: 0, bottom: SQSpace.xs, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                if model.sites.isEmpty || model.filteredCount == 0 {
                    emptyContent
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .listRowSeparator(.hidden)

            ForEach(model.sections) { section in
                Section {
                    ForEach(section.sites) { site in
                        RadioLogSiteCard(
                            site: site,
                            state: model.state(of: site),
                            siteName: model.siteNames[site.id],
                            isExpanded: model.expandedSiteId == site.id,
                            onIdentify: { identifyTarget = site },
                            onOpenMap: { mapTarget = site },
                            onToggleCells: { model.toggleExpansion(site) }
                        )
                        .listRowBackground(SQColor.surface)
                        .listRowSeparatorTint(SQColor.separator)
                        .onAppear {
                            // La commune n'est chargée que pour ce qui s'affiche —
                            // c'est un GET par site, et la liste en compte des milliers.
                            if model.state(of: site).isIdentified { model.loadSiteName(for: site) }
                        }
                    }
                } header: {
                    if let operatorName = section.operatorName {
                        RadioLogOperatorHeader(
                            operatorName: operatorName,
                            siteCount: section.sites.count,
                            logCount: section.logCount
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .modifier(CompactListMargins())
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Logs antennes")
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .refreshable { await model.refresh() }
        .task { await model.onAppear() }
        .onDisappear { model.stopScan() }
        .sheet(isPresented: $showsPremiumPaywall, onDismiss: {
            // Un achat abouti change le droit côté serveur : resynchroniser.
            Task { await model.refresh() }
        }) {
            NavigationStack {
                PaywallView(store: services.entitlements, entryPoint: .premiumFeature(String(localized: "Logs antennes")))
            }
            .presentationDetents([.large])
        }
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
        .sqAnimation(SQMotion.standard, value: model.expandedSiteId)
    }

    // MARK: - En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(spacing: SQSpace.sm) {
                MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "radioLogs.back") { dismiss() }
                Spacer(minLength: 0)
                MapChipIconButton(
                    systemImage: showsSearch ? "xmark" : "magnifyingglass",
                    label: showsSearch ? "Fermer la recherche" : "Rechercher un site",
                    identifier: "radioLogs.search"
                ) {
                    showsSearch.toggle()
                    if !showsSearch { model.searchText = "" }
                }
                optionsMenu
            }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Logs antennes")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .accessibilityIdentifier("radioLogs.title")
                Text("Les antennes captées par l’app Android pendant tes trajets.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Le menu garde ses trois actions ; la suppression, irréversible, est
    /// rangée à part et annonce par ses points de suspension qu'elle demande
    /// confirmation.
    private var optionsMenu: some View {
        Menu {
            Button {
                showsFilterSheet = true
            } label: {
                Label("Trier et afficher", systemImage: "slider.horizontal.3")
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
                Label("Supprimer le journal…", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .frame(width: 44, height: 44)
                .sqSurface(SQColor.chip, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Plus d'options")
        .accessibilityIdentifier("radioLogs.more")
    }

    // MARK: - Synthèse

    /// Sites, relevés, synchronisation et part vérifiée, en une carte. Pendant la
    /// récupération ou la vérification, la carte porte aussi la tâche en cours et
    /// de quoi la suspendre.
    private var summaryCard: some View {
        // Une pause garde la carte : sans elle, « Reprendre » disparaissait avec le bloc.
        let isWorking = model.isScanning || model.isSyncing || model.isPaused
        return VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .top, spacing: SQSpace.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(siteTally)
                        .foregroundStyle(SQColor.label)
                        .monospacedDigit()
                    Text(tallySubtitle)
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
                if !isWorking && model.totalCount > 0 {
                    verifiedPill
                }
            }
            if isWorking {
                scanBlock
            } else if model.totalCount > 0 {
                progressBar(value: model.completion, height: M.barHeight, tint: P.okInk)
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("radioLogs.summary")
    }

    /// « 214 sites », le nombre en grand : la clé plurielle reste celle du reste
    /// de l'app, seule la part chiffrée change de corps.
    private var siteTally: AttributedString {
        var tally = AttributedString(localized: "\(model.totalCount) site")
        tally.font = SQFont.body(14, .bold)
        tally.foregroundColor = SQColor.labelSecondary
        if let range = tally.characters.firstIndex(where: { !$0.isNumber && !$0.isWhitespace && $0 != "\u{202F}" && $0 != "\u{00A0}" && $0 != "," && $0 != "." }) {
            tally[tally.startIndex..<range].font = SQFont.display(26, .heavy, relativeTo: .title)
            tally[tally.startIndex..<range].foregroundColor = SQColor.label
        }
        return tally
    }

    private var tallySubtitle: String {
        // Traduit, avec les variantes de pluriel du catalogue (« 0 relevé » en
        // français, « 0 measurements » en anglais).
        var parts = [String(localized: "\(model.logCount) relevé")]
        if let lastSyncedAt = model.lastSyncedAt {
            parts.append(String(localized: "synchronisé \(lastSyncedAt.formatted(.relative(presentation: .named)))"))
        }
        return parts.joined(separator: " · ")
    }

    /// La complétude PERMANENTE. Elle reste après le balayage : elle dit l'état de
    /// CONNAISSANCE du catalogue, pas une tâche en cours.
    private var verifiedPill: some View {
        let percent = Int((model.completion * 100).rounded())
        return HStack(spacing: SQSpace.xs) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .accessibilityHidden(true)
            Text("\(percent) % vérifiés")
                .font(SQFont.body(12, .bold))
                .monospacedDigit()
        }
        .foregroundStyle(P.okInk)
        .padding(.horizontal, SQSpace.sm)
        .frame(minHeight: 26)
        .background(P.okSoft, in: Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Catalogue vérifié à \(percent) pour cent")
        .accessibilityIdentifier("radioLogs.verified")
    }

    /// La vérification du catalogue, dans la carte de synthèse : elle se suspend
    /// d'un geste et disparaît une fois le catalogue résolu.
    private var scanBlock: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack(spacing: SQSpace.md) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.isSyncing ? String(localized: "Récupération du journal")
                         : model.isPaused ? String(localized: "Vérification en pause")
                         : String(localized: "Vérification du catalogue"))
                        .font(SQFont.body(12, .bold))
                        .foregroundStyle(OutageTint.degradedInk)
                    Text(scanSubtitle)
                        .font(SQType.caption)
                        .monospacedDigit()
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
                if !model.isSyncing {
                    Button {
                        model.toggleScan()
                        Haptics.selection()
                    } label: {
                        HStack(spacing: SQSpace.xs) {
                            Image(systemName: model.isScanning ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .accessibilityHidden(true)
                            Text(model.isScanning ? String(localized: "Suspendre") : String(localized: "Reprendre"))
                                .font(SQFont.body(12, .bold))
                        }
                        .foregroundStyle(SQColor.label)
                        .padding(.horizontal, SQSpace.md)
                        .frame(minHeight: 32)
                        .sqSurface(SQColor.chip, in: Capsule(style: .continuous))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("radioLogs.scan.toggle")
                }
            }
            progressBar(value: model.isSyncing ? nil : model.completion, height: M.barHeight, tint: OutageTint.degradedInk)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("radioLogs.scan")
    }

    private var scanSubtitle: String {
        if model.isSyncing {
            return model.syncReceived == 0
                ? String(localized: "Connexion au journal…")
                : String(localized: "\(model.syncReceived.formatted()) relevés reçus")
        }
        return String(localized: "\(model.checkedCount.formatted()) sites vérifiés sur \(model.totalCount.formatted())")
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

    // MARK: - Tri et file

    /// « Les plus relevés d'abord · par opérateur » : dit le tri en cours et ouvre
    /// « Trier et afficher ».
    private var sortSummary: some View {
        let parts = [model.sortOrder.summary] + (model.groupByOperator ? [String(localized: "par opérateur")] : [])
        return Button {
            showsFilterSheet = true
        } label: {
            HStack(spacing: SQSpace.xs2) {
                Text(verbatim: parts.joined(separator: " · "))
                    .font(SQFont.body(12, .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(SQColor.labelSecondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Ouvre Trier et afficher")
        .accessibilityIdentifier("radioLogs.sortSummary")
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
                SQIconPastille(systemImage: "list.bullet.rectangle.portrait", size: 38, tint: SQColor.accentInk, fill: SQColor.surface)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identifier \(min(candidates.count, 50)) site à la suite")
                        .font(SQFont.body(14, .bold))
                        .foregroundStyle(SQColor.label)
                    Text("Un site après l’autre, tu t’arrêtes quand tu veux.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SQColor.accentInk)
                    .accessibilityHidden(true)
            }
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(P.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("radioLogs.chain")
    }

    // MARK: - États

    private func inlineError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            SQInlineError(message: message)
            Button("Réessayer") { Task { await model.refresh() } }
                .font(SQFont.body(14, .semibold))
                .foregroundStyle(SQColor.accentInk)
                .frame(minHeight: 44)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.dangerSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    @ViewBuilder
    private var emptyContent: some View {
        if model.sites.isEmpty {
            emptyState
        } else {
            EmptyStateView(
                title: "Aucun site",
                message: "Aucun site ne correspond à ce filtre.",
                systemImage: "line.3.horizontal.decrease.circle"
            )
            .padding(.top, SQSpace.xl)
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
        } else if model.premiumMessage == nil {
            EmptyStateView(
                title: "Aucun relevé",
                message: "Le journal se remplit avec l’app Android, qui capte les antennes pendant tes trajets.",
                systemImage: "antenna.radiowaves.left.and.right"
            )
            .padding(.top, SQSpace.xl)
        }
    }

    /// Refus Premium : dire pourquoi et proposer d'agir (TRX-34). Un abonnement
    /// pris sur Android ou sur le web vaut ici aussi ; l'app le relit à la demande.
    private func premiumBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            HStack(alignment: .top, spacing: SQSpace.sm) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OutageTint.degradedInk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(message)
                        .font(SQFont.body(14, .bold))
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Abonné sur Android ou sur le web ? Ton abonnement vaut aussi ici : actualise-le.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SQSpace.sm) { premiumActions }
                VStack(alignment: .leading, spacing: SQSpace.sm) { premiumActions }
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.warningSoft, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("radioLogs.premium")
    }

    @ViewBuilder
    private var premiumActions: some View {
        premiumAction("Voir l’abonnement", prominent: true, identifier: "radioLogs.premium.paywall") {
            showsPremiumPaywall = true
        }
        premiumAction(isRefreshingEntitlement ? "Vérification…" : "Actualiser mon abonnement",
                      prominent: false, identifier: "radioLogs.premium.refresh") {
            Task { await refreshEntitlement() }
        }
        .disabled(isRefreshingEntitlement)
    }

    private func premiumAction(_ title: LocalizedStringKey, prominent: Bool, identifier: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(prominent ? SQColor.onAccent : SQColor.label)
                .padding(.horizontal, SQSpace.md)
                .frame(minHeight: 44)
                .background {
                    if prominent {
                        Capsule().fill(SQColor.brandRed)
                    } else {
                        Capsule().fill(SQColor.surface)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    /// Relit l'abonnement côté serveur, puis relance la synchronisation.
    private func refreshEntitlement() async {
        isRefreshingEntitlement = true
        defer { isRefreshingEntitlement = false }
        await services.entitlements.refreshBackendSnapshot()
        await model.refresh()
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
                .accessibilityIdentifier("radioLogs.toast")
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
            .onAppear { updateMotion() }
            .onChangeCompat(of: reduceMotion) { _, _ in
                updateMotion()
            }
    }

    private func updateMotion() {
        offset = 0
        guard let animation = SQMotion.repeating(
            .easeInOut(duration: 1.1),
            active: width > 0,
            reduceMotion: reduceMotion
        ) else { return }
        withAnimation(animation) {
            offset = width * 0.7
        }
    }
}

/// Enveloppe `Identifiable` pour présenter la file en `sheet(item:)`.
struct RadioLogChainQueue: Identifiable {
    let id = UUID()
    let sites: [RadioLogSite]
}
