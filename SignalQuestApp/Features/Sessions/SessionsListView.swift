import SwiftUI

@MainActor
final class LocalCoverageArchiveViewModel: ObservableObject {
    @Published private(set) var snapshot = LocalCoverageArchiveSnapshot(entries: [], unreadableSources: 0)
    @Published private(set) var isLoading = false

    func reload() async {
        isLoading = true
        let loaded = await Task.detached(priority: .utility) {
            LocalCoverageArchiveReader.load()
        }.value
        snapshot = loaded
        isLoading = false
    }

    /// « Supprimer les archives locales » : efface tout, puis relit l'état réel.
    func eraseAll() async {
        isLoading = true
        _ = await Task.detached(priority: .utility) {
            LocalCoverageArchiveReader.eraseAll()
        }.value
        await reload()
    }
}

@MainActor
final class SessionsListViewModel: ObservableObject {
    @Published var sessions: [CoverageSession] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasMore = false
    @Published var filter: Filter = .all
    /// Total côté serveur (`pagination.total`), quand il est connu.
    @Published private(set) var total: Int?

    enum Filter: String, CaseIterable, Identifiable {
        case all, driveTest, coverage
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "Tous"
            case .driveTest: return "Drive Test"
            case .coverage: return "Couverture"
            }
        }
    }

    private let loadPage: @MainActor (Int, Int) async throws -> SessionsListResponse
    /// Lu par l'écran : chaque page reçue relance le chargement de la suivante.
    private(set) var offset = 0
    private var requestGeneration = UUID()
    /// Quinze, pas trente.
    ///
    /// Le serveur charge TOUS les points de TOUTES les sessions de la page pour
    /// en dériver ses agrégats (distance sans réseau, opérateurs, comptes
    /// logiques) : le coût de la page est proportionnel au nombre de sessions,
    /// pas à leur nombre de lignes. Mesuré : 1,0 s à vingt sessions, 1,8 s à
    /// quarante. Quinze remplit déjà plus d'un écran, et le défilement infini
    /// charge la suite pendant qu'on lit.
    private let pageSize = 15

    init(service: SessionsServicing) {
        loadPage = { offset, limit in
            try await service.sessions(offset: offset, limit: limit, mapPoints: false)
        }
    }

    init(loadPage: @escaping @MainActor (Int, Int) async throws -> SessionsListResponse) {
        self.loadPage = loadPage
    }

    var filtered: [CoverageSession] {
        switch filter {
        case .all: return sessions
        case .driveTest: return sessions.filter { $0.isDriveTest }
        case .coverage: return sessions.filter { !$0.isDriveTest }
        }
    }

    /// Un groupe par mois, dans l'ordre du serveur (les plus récents d'abord).
    struct MonthGroup: Identifiable {
        let id: String
        let title: String
        var sessions: [CoverageSession]
    }

    var monthGroups: [MonthGroup] {
        var groups: [MonthGroup] = []
        let calendar = Calendar.current
        for session in filtered {
            let id: String
            let title: String
            if let date = session.startTime {
                let parts = calendar.dateComponents([.year, .month], from: date)
                id = "\(parts.year ?? 0)-\(parts.month ?? 0)"
                title = date.formatted(.dateTime.month(.wide).year())
            } else {
                id = "undated"
                title = String(localized: "Sans date")
            }
            if let index = groups.firstIndex(where: { $0.id == id }) {
                groups[index].sessions.append(session)
            } else {
                groups.append(MonthGroup(id: id, title: title, sessions: [session]))
            }
        }
        return groups
    }

    var isExhaustedEmpty: Bool {
        filtered.isEmpty && !isLoading && !hasMore && errorMessage == nil
    }

    var showsLocalCoverageArchive: Bool { filter != .driveTest }

    func showsEmptyState(archive: LocalCoverageArchiveSnapshot, archiveIsLoading: Bool) -> Bool {
        guard isExhaustedEmpty else { return false }
        guard showsLocalCoverageArchive else { return true }
        return !archiveIsLoading && archive.entries.isEmpty && archive.unreadableSources == 0
    }

    func reload() async {
        let generation = UUID()
        requestGeneration = generation
        offset = 0
        hasMore = false
        isLoading = true
        errorMessage = nil
        defer { if requestGeneration == generation { isLoading = false } }
        do {
            let page = try await loadPage(0, pageSize)
            guard requestGeneration == generation else { return }
            sessions = page.sessions
            total = page.pagination?.total
            hasMore = !page.sessions.isEmpty && (page.pagination?.hasMore ?? (page.sessions.count >= pageSize))
            offset = page.sessions.count
        } catch {
            guard requestGeneration == generation else { return }
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        let generation = requestGeneration
        let requestedOffset = offset
        isLoading = true
        errorMessage = nil
        defer { if requestGeneration == generation { isLoading = false } }
        do {
            let page = try await loadPage(requestedOffset, pageSize)
            guard requestGeneration == generation else { return }
            var seen = Set(sessions.map(\.id))
            sessions.append(contentsOf: page.sessions.filter { seen.insert($0.id).inserted })
            hasMore = !page.sessions.isEmpty && (page.pagination?.hasMore ?? (page.sessions.count >= pageSize))
            offset += page.sessions.count
        } catch {
            guard requestGeneration == generation else { return }
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }
}

/// Journal des sessions/logs de mesure de l'utilisateur (drive-test + couverture),
/// synchronisées entre Android et iOS via le compte.
struct SessionsListView: View {
    @StateObject private var model: SessionsListViewModel
    @StateObject private var archiveModel = LocalCoverageArchiveViewModel()
    @Environment(\.dismiss) private var dismiss

    init(service: SessionsServicing) {
        _model = StateObject(wrappedValue: SessionsListViewModel(service: service))
    }

    /// Captures et tests : une liste déjà branchée sur ses pages.
    init(model: SessionsListViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.xs, trailing: 0))
                    .listRowBackground(Color.clear)
                // Piste A du 20/11 : le segment sur toute la largeur, le compte dans l'en-tête.
                MapSegmented(
                    selection: $model.filter,
                    options: SessionsListViewModel.Filter.allCases.map { ($0, $0.label) },
                    identifier: "sessions.filter"
                )
                .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: 0, bottom: SQSpace.xs, trailing: 0))
                .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)

            if model.showsEmptyState(archive: archiveModel.snapshot, archiveIsLoading: archiveModel.isLoading) {
                EmptyStateView(
                    title: model.sessions.isEmpty ? "Aucun trajet pour l’instant" : "Aucun trajet de ce type",
                    message: model.sessions.isEmpty
                        ? "Lance un Drive Test ou une session de couverture dans l’app Android : tes trajets apparaîtront ici."
                        : "Aucun trajet ne correspond à ce filtre dans l’historique complet.",
                    systemImage: "point.topleft.down.curvedto.point.bottomright.up"
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } else if model.sessions.isEmpty, !model.isLoading, let errorMessage = model.errorMessage {
                // Rien de chargé : même carte d'erreur que les autres listes.
                ErrorStateView(title: "Trajets indisponibles", message: errorMessage) {
                    Task { await model.reload() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } else {
                ForEach(model.monthGroups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                SessionRow(session: session)
                            }
                            .listRowBackground(SQColor.surface)
                            .listRowSeparatorTint(SQColor.separator)
                            .accessibilityIdentifier("sessions.row.\(session.id)")
                        }
                    } header: {
                        Text(group.title).sqKicker()
                    }
                }
                if model.hasMore {
                    Section {
                        // Une seule ligne de chargement, la même pendant et après la requête :
                        // deux branches séparées par `isLoading` faisaient disparaître la ligne
                        // dès le début du chargement, ce qui annulait sa tâche et sa requête.
                        // Elle repartait aussitôt, sans fin (ticket du 17/11). La page reçue
                        // (`offset`) relance la suivante.
                        if !model.isLoading, model.filtered.isEmpty || model.errorMessage != nil {
                            GradientButton("Afficher les trajets suivants", style: .secondary) {
                                Task { await model.loadMore() }
                            }
                            .accessibilityIdentifier("sessions.loadMore")
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        } else {
                            loadingRow
                                .task(id: model.offset) { await model.loadMore() }
                        }
                    }
                }
            }

            if let errorMessage = model.errorMessage, !model.sessions.isEmpty {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .listRowBackground(Color.clear)
                    if !model.hasMore {
                        GradientButton("Réessayer", style: .secondary) {
                            Task { await model.reload() }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
            }

            if model.showsLocalCoverageArchive && archiveModel.hasContent {
                Section {
                    NavigationLink {
                        LocalCoverageArchivesView(model: archiveModel)
                    } label: {
                        archivesRow
                    }
                    .listRowBackground(SQColor.surface)
                    .accessibilityIdentifier("sessions.localArchives")
                } header: {
                    Text("Sur cet iPhone").sqKicker()
                }
            }
        }
        .listStyle(.insetGrouped)
        .modifier(CompactListMargins())
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Trajets")
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .refreshable {
            await archiveModel.reload()
            await model.reload()
        }
        .overlay {
            if model.isLoading && model.sessions.isEmpty &&
                (!model.showsLocalCoverageArchive || archiveModel.snapshot.entries.isEmpty) {
                SQSpinner().tint(SQColor.brandRed)
            }
        }
        .task { if model.sessions.isEmpty { await model.reload() } }
        .task { await archiveModel.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "sessions.back") { dismiss() }
            // Un titre court et le compte ; l'origine Android n'est dite que dans l'état vide.
            VStack(alignment: .leading, spacing: 2) {
                Text("Trajets")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .accessibilityIdentifier("sessions.title")
                if let total = model.total, total > 0 {
                    Text("\(total) trajets")
                        .font(SQType.callout)
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityIdentifier("sessions.summary")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingRow: some View {
        HStack { Spacer(); SQSpinner().tint(SQColor.brandRed); Spacer() }
            .padding(.vertical, SQSpace.sm)
            .listRowBackground(Color.clear)
    }

    private var archivesRow: some View {
        HStack(spacing: SQSpace.sm2) {
            SQIconPastille(systemImage: "archivebox", size: 38, tint: SQColor.accentInk, font: .system(size: 15, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text(archiveModel.snapshot.entries.isEmpty
                     ? String(localized: "Archives locales")
                     : String(localized: "Archives locales · \(archiveModel.snapshot.entries.count)"))
                    .font(SQFont.body(15.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                Text("Anciennes captures gardées ici, qui ne sont plus envoyées.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, SQSpace.xs)
        .accessibilityElement(children: .combine)
    }
}

private extension LocalCoverageArchiveViewModel {
    var hasContent: Bool { !snapshot.entries.isEmpty || snapshot.unreadableSources > 0 }
}

/// Archives locales : anciennes captures de couverture restées sur l'appareil.
private struct LocalCoverageArchivesView: View {
    @ObservedObject var model: LocalCoverageArchiveViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmErase = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "sessions.localArchives.back") { dismiss() }
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text("Archives locales")
                            .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                            .foregroundStyle(SQColor.label)
                            .sqHeader()
                        Text("Anciennes captures de couverture conservées sur cet appareil. Elles ne sont plus envoyées.")
                            .font(SQType.callout)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.xs, trailing: 0))
                .listRowBackground(Color.clear)
            }
            .listRowSeparator(.hidden)

            if !model.snapshot.entries.isEmpty {
                Section {
                    ForEach(model.snapshot.entries) { archive in
                        NavigationLink {
                            LocalCoverageArchiveDetailView(archive: archive)
                        } label: {
                            LocalCoverageArchiveRow(archive: archive)
                        }
                        .listRowBackground(SQColor.surface)
                        .listRowSeparatorTint(SQColor.separator)
                    }
                }
            }

            if model.snapshot.unreadableSources > 0 {
                Label("Certaines archives locales sont illisibles. Les fichiers ont été conservés.", systemImage: "exclamationmark.triangle")
                    .font(SQType.caption)
                    .foregroundStyle(OutageTint.degradedInk)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("sessions.localArchives.error")
            }

            if model.hasContent {
                Section {
                    Button(role: .destructive) {
                        confirmErase = true
                    } label: {
                        Label("Supprimer les archives locales", systemImage: "trash")
                            .font(SQFont.body(16, .semibold, relativeTo: .body))
                            .foregroundStyle(SQColor.dangerInk)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .listRowBackground(SQColor.surface)
                    .accessibilityIdentifier("sessions.localArchives.erase")
                }
            }
        }
        .confirmationDialog("Supprimer les archives locales ?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                Task {
                    await model.eraseAll()
                    dismiss()
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les anciennes captures de couverture seront effacées de cet iPhone. Cette action est définitive.")
        }
        .listStyle(.insetGrouped)
        .modifier(CompactListMargins())
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Archives locales")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .refreshable { await model.reload() }
    }
}

/// Étiquette d'état d'une archive : interrompue (brouillon) ou terminée.
private struct LocalCoverageArchiveStateTag: View {
    let state: CoverageSessionQueueState

    var body: some View {
        let interrupted = state == .recording
        let tint = interrupted ? OutageTint.degradedInk : OutageTint.resolvedInk
        Text(interrupted ? "Interrompu" : "Terminée")
            .font(SQFont.body(11, .bold, relativeTo: .caption2))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule(style: .continuous))
            .fixedSize()
    }
}

private struct LocalCoverageArchiveRow: View {
    let archive: LocalCoverageArchive

    var body: some View {
        HStack(spacing: SQSpace.sm2) {
            SQIconPastille(systemImage: "archivebox", size: 38, tint: SQColor.accentInk, font: .system(size: 15, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text(archive.state == .recording ? LocalizedStringKey("Brouillon de couverture") : LocalizedStringKey("Ancienne capture de couverture"))
                    .font(SQFont.body(15.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                Text("\(archive.pointCount) points · \(Date(timeIntervalSince1970: Double(archive.startTime) / 1_000).formatted(.dateTime.day().month().year().hour().minute()))")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .monospacedDigit()
            }
            Spacer(minLength: SQSpace.sm)
            LocalCoverageArchiveStateTag(state: archive.state)
        }
        .padding(.vertical, SQSpace.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sessions.localArchive.row")
    }
}

private struct LocalCoverageArchiveDetailView: View {
    let archive: LocalCoverageArchive
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "sessions.localArchive.back") { dismiss() }
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text(archive.state == .recording ? LocalizedStringKey("Brouillon de couverture") : LocalizedStringKey("Ancienne capture de couverture"))
                            .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                            .foregroundStyle(SQColor.label)
                            .sqHeader()
                        Text("Archive conservée sur cet appareil")
                            .font(SQType.callout)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: SQSpace.md) {
                    HStack {
                        Label(archive.state == .recording ? LocalizedStringKey("Brouillon interrompu") : LocalizedStringKey("Capture terminée"), systemImage: "archivebox")
                        Spacer()
                        LocalCoverageArchiveStateTag(state: archive.state)
                    }
                    Divider()
                    HStack {
                        Text("Points enregistrés")
                        Spacer()
                        Text(archive.pointCount, format: .number).monospacedDigit()
                    }
                    HStack {
                        Text("Début")
                        Spacer()
                        Text(Date(timeIntervalSince1970: Double(archive.startTime) / 1_000), format: .dateTime.day().month().year().hour().minute())
                    }
                    if archive.endTime > archive.startTime {
                        HStack {
                            Text("Fin")
                            Spacer()
                            Text(Date(timeIntervalSince1970: Double(archive.endTime) / 1_000), format: .dateTime.day().month().year().hour().minute())
                        }
                    }
                }
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .padding(SQSpace.lg)
                .sqCardBackground(cornerRadius: SQRadius.lg, elevation: .rest)

                Text("Cette consultation reste sur cet appareil et n’envoie aucune coordonnée.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SQSpace.lg)
            .sqReadableWidth()
        }
        .signalQuestBackground()
        .navigationTitle("Archive locale")
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .accessibilityIdentifier("sessions.localArchive.detail")
    }
}

/// Ligne d'un trajet (piste A, choix d'Alexandre du 20/11) : le jour en tuile ; la distance et
/// la durée en titre, l'heure à droite ; les opérateurs en points de couleur ; la qualité en un
/// mot. Les points et les dBm restent dans le détail.
struct SessionRow: View {
    let session: CoverageSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Qualité affichée à droite : le signal moyen aux seuils de la carte, ou le débit moyen
    /// d'un Drive Test connu par son récap seulement.
    enum Quality: Equatable {
        case signal(SQQualityScale.Signal)
        case throughput(Double)
    }

    /// « 27,9 km · 1 h 43 », ce qui est connu seulement.
    nonisolated static func measures(_ session: CoverageSession) -> String? {
        var parts: [String] = []
        if let km = session.distanceKm, km > 0 { parts.append(SQUnits.distance(kilometers: km)) }
        if let duration = session.durationLabel { parts.append(duration) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Le nom donné au trajet s'il y en a un, sinon la distance et la durée ; « 3 tests » pour un
    /// Drive Test sans tracé ni distance ; le type en dernier recours.
    nonisolated static func headline(_ session: CoverageSession) -> String {
        if let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let measures = measures(session) { return measures }
        if session.isSummaryOnly, let tests = session.driveSummary?.testCount { return String(localized: "\(tests) test") }
        return session.isDriveTest ? String(localized: "Drive Test") : String(localized: "Couverture")
    }

    /// Sous un nom donné, la distance et la durée passent en deuxième ligne.
    nonisolated static func detailLine(_ session: CoverageSession) -> String? {
        guard let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return measures(session)
    }

    nonisolated static func quality(of session: CoverageSession) -> Quality? {
        if session.isSummaryOnly {
            guard let average = session.driveSummary?.downloadAvgMbps, average > 0 else { return nil }
            return .throughput(average)
        }
        // Couverture iOS : pas de RSRP, une sentinelle que l'échelle lit « Pas de mesure ».
        switch SQQualityScale.Signal(rsrp: session.avgSignalStrength) {
        case .noService, .unknown: return nil
        case let level: return .signal(level)
        }
    }

    /// Deux opérateurs au plus, puis « +N ».
    nonisolated static func visibleOperators(_ operators: [SessionOperator]) -> (shown: [SessionOperator], overflow: Int) {
        (Array(operators.prefix(2)), max(0, operators.count - 2))
    }

    /// « Bouygues » quand « Bouygues Telecom » ne tient pas.
    nonisolated static func shortLabel(_ op: SessionOperator) -> String {
        SQBrand.operatorShortName(op.key) ?? SQBrand.operatorShortName(op.label) ?? op.label
    }

    /// « Bouygues Telecom », le nom complet de l'app : le serveur sert parfois la clé
    /// brute en étiquette (« BOUYGUES », « ORANGE »), qui s'affichait telle quelle.
    nonisolated static func fullLabel(_ op: SessionOperator) -> String {
        SQBrand.operatorName(op.key) ?? SQBrand.operatorName(op.label) ?? op.label
    }

    /// Une seule phrase pour VoiceOver, dans l'ordre de la ligne.
    nonisolated static func accessibilityText(_ session: CoverageSession) -> String {
        var parts: [String] = []
        if let date = session.startTime {
            parts.append(date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
        }
        parts.append(headline(session))
        if let detail = detailLine(session) { parts.append(detail) }
        if session.isDriveTest { parts.append(String(localized: "Drive Test")) }
        if !session.operators.isEmpty { parts.append(session.operators.map(fullLabel).joined(separator: ", ")) }
        switch quality(of: session) {
        case .signal(let level): parts.append(String(localized: "Signal \(level.label.lowercased())"))
        case .throughput(let mbps): parts.append(String(localized: "\(SQUnits.throughput(mbps: mbps)) en moyenne"))
        case nil: break
        }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        let quality = Self.quality(of: session)
        let stacked = dynamicTypeSize.isAccessibilitySize
        HStack(spacing: SQSpace.sm2) {
            if !stacked { SessionDayTile(date: session.startTime) }
            VStack(alignment: .leading, spacing: 6) {
                if stacked {
                    headlineText
                    detailText
                    if let date = session.startTime {
                        Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                            .font(SQFont.body(13.5, relativeTo: .subheadline))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    operatorsLine
                    // Empilée, la ligne ne peut pas déborder : le mot reste à côté des barres.
                    if let quality { SessionQualityLabel(quality: quality, showsWord: true) }
                } else {
                    // Rien n'est coupé, même sur 320 pt (iPad en Split View) : un titre trop long
                    // pour tenir à côté de l'heure passe au-dessus d'elle.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                            headlineText.fixedSize()
                            Spacer(minLength: SQSpace.sm)
                            timeText
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            headlineText
                            timeText
                        }
                    }
                    detailText
                    // Pas d'espaceur : il prenait la moitié de la place et tronquait « Bouyg… ».
                    // La partie gauche reçoit toute la largeur que laisse la droite.
                    HStack(spacing: SQSpace.sm) {
                        operatorsLine
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Les barres seules (retour d'Alexandre du 20/11) : deux noms d'opérateurs
                        // gardent leur place ; VoiceOver lit toujours la qualité.
                        if let quality {
                            SessionQualityLabel(quality: quality, showsWord: false)
                                .fixedSize()
                        }
                    }
                }
            }
        }
        .padding(.vertical, SQSpace.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.accessibilityText(session)))
    }

    private var headlineText: some View {
        Text(verbatim: Self.headline(session))
            .font(SQFont.body(16, .semibold, relativeTo: .body))
            .foregroundStyle(SQColor.label)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
    }

    @ViewBuilder
    private var timeText: some View {
        if let date = session.startTime {
            Text(date, format: .dateTime.hour().minute())
                .font(SQFont.body(13.5, relativeTo: .subheadline))
                .foregroundStyle(SQColor.labelSecondary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    @ViewBuilder
    private var detailText: some View {
        if let detail = Self.detailLine(session) {
            Text(verbatim: detail)
                .font(SQFont.body(13.5, relativeTo: .subheadline))
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    @ViewBuilder
    private var operatorsLine: some View {
        if session.isDriveTest || !session.operators.isEmpty {
            // Les noms complets, puis les noms courts (« Bouygues »), puis les noms courts sur
            // plusieurs lignes : jamais « B… ».
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SQSpace.sm2) { operatorItems(short: false) }
                HStack(spacing: SQSpace.sm2) { operatorItems(short: true) }
                FlowLayout(spacing: SQSpace.sm) { operatorItems(short: true) }
            }
            .font(SQFont.body(13.5, relativeTo: .subheadline))
            .foregroundStyle(SQColor.labelSecondary)
        }
    }

    /// Chaque élément garde sa largeur : `ViewThatFits` passe à la forme suivante au lieu de couper.
    @ViewBuilder
    private func operatorItems(short: Bool) -> some View {
        let visible = Self.visibleOperators(session.operators)
        if session.isDriveTest {
            Text("Drive Test")
                .font(SQFont.body(11, .semibold, relativeTo: .caption2))
                .foregroundStyle(SQColor.chipInk)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(SQColor.chip, in: Capsule(style: .continuous))
                .fixedSize()
        }
        ForEach(visible.shown) { op in
            HStack(spacing: 6) {
                Circle()
                    .fill(SessionDetailView.operatorColor(op.colorHex))
                    .frame(width: 8, height: 8)
                Text(verbatim: short ? Self.shortLabel(op) : Self.fullLabel(op))
            }
            .fixedSize()
        }
        if visible.overflow > 0 {
            Text(verbatim: "+\(visible.overflow)").fixedSize()
        }
    }
}

/// Jour du trajet : « VEN. » au-dessus de « 20 » ; le mois est dans l'en-tête de section.
private struct SessionDayTile: View {
    let date: Date?
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 50

    var body: some View {
        VStack(spacing: 3) {
            if let date {
                Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(SQFont.body(10, .semibold, relativeTo: .caption2))
                    .tracking(0.8)
                    .foregroundStyle(SQColor.ink2)
                Text(date.formatted(.dateTime.day()))
                    .font(SQFont.display(19, .semibold, relativeTo: .title3))
                    .foregroundStyle(SQColor.label)
            } else {
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: width, height: height)
        .background(SQColor.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// « ▂▄ » aux couleurs de la carte (« ▂▄ Moyen » en très grand texte), ou le débit moyen
/// d'un Drive Test sans tracé.
private struct SessionQualityLabel: View {
    let quality: SessionRow.Quality
    let showsWord: Bool

    var body: some View {
        HStack(spacing: 6) {
            switch quality {
            case .signal(let level):
                SessionSignalBars(level: level)
                if showsWord { Text(level.label) }
            case .throughput(let mbps):
                Image(systemName: "speedometer")
                    .foregroundStyle(SQQualityScale.Throughput(mbps: mbps).color)
                Text(verbatim: SQUnits.throughput(mbps: mbps))
                    .monospacedDigit()
            }
        }
        .font(SQFont.body(13.5, .semibold, relativeTo: .subheadline))
        .foregroundStyle(SQColor.label)
        .lineLimit(1)
    }
}

/// Quatre barres : 4 excellent, 3 bon, 2 moyen, 1 faible ou critique (la couleur les sépare).
private struct SessionSignalBars: View {
    let level: SQQualityScale.Signal
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 14

    private var filled: Int {
        switch level {
        case .excellent: return 4
        case .good: return 3
        case .fair: return 2
        default: return 1
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: height / 8) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < filled ? level.color : SQColor.dots)
                    .frame(width: height / 4, height: height * [0.34, 0.54, 0.76, 1][index])
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
