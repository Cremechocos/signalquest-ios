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
            case .all: return "Toutes"
            case .driveTest: return "Drive Test"
            case .coverage: return "Couverture"
            }
        }
    }

    private let loadPage: @MainActor (Int, Int) async throws -> SessionsListResponse
    private var offset = 0
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

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.xs, trailing: 0))
                    .listRowBackground(Color.clear)
                SQSegmentedFilter(
                    selection: $model.filter,
                    options: SessionsListViewModel.Filter.allCases.map { (value: $0, label: $0.label, icon: String?.none) }
                )
                .accessibilityIdentifier("sessions.filter")
                // Le segment ajoute sa propre marge latérale de 16 pt : on la compense.
                .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: -SQSpace.lg, bottom: SQSpace.xs, trailing: -SQSpace.lg))
                .listRowBackground(Color.clear)
                if let total = model.total, total > 0 {
                    Text("\(total) trajets · les plus récents d’abord")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .listRowInsets(EdgeInsets(top: 0, leading: SQSpace.xs, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("sessions.summary")
                }
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
                        if model.isLoading {
                            loadingRow
                        } else if model.filtered.isEmpty || model.errorMessage != nil {
                            GradientButton("Afficher les trajets suivants", style: .secondary) {
                                Task { await model.loadMore() }
                            }
                            .accessibilityIdentifier("sessions.loadMore")
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        } else {
                            loadingRow
                                .task { await model.loadMore() }
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
        .navigationTitle("Enregistrements de trajet")
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
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Enregistrements de trajet")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .accessibilityIdentifier("sessions.title")
                Text("Tes trajets enregistrés avec l’app Android : Drive Test et couverture.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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

private struct SessionRow: View {
    let session: CoverageSession

    /// « 240 points · 18,4 km · 40 min · −91 dBm », ce qui est connu seulement.
    private var metrics: String {
        var parts: [String] = []
        if let points = session.totalPoints { parts.append(String(localized: "\(points) points")) }
        if let km = session.distanceKm, km > 0 { parts.append(SQUnits.distance(kilometers: km)) }
        if let duration = session.durationLabel { parts.append(duration) }
        if let rsrp = session.avgRsrpLabel { parts.append(rsrp) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: SQSpace.sm2) {
            SQIconPastille(systemImage: session.isDriveTest ? "car.fill" : "dot.radiowaves.left.and.right", size: 38, font: .system(size: 15, weight: .medium))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name ?? (session.isDriveTest ? String(localized: "Drive Test") : String(localized: "Couverture")))
                    .font(SQFont.body(15.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .sqSingleLine()
                if !metrics.isEmpty {
                    Text(metrics)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 5) {
                    ForEach(session.operators.prefix(4)) { op in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(SessionDetailView.operatorColor(op.colorHex))
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(op.label)
                                .font(SQFont.body(12, .semibold, relativeTo: .caption2))
                                .foregroundStyle(SQColor.label)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(SessionDetailView.operatorColor(op.colorHex).opacity(0.14), in: Capsule(style: .continuous))
                    }
                    if let date = session.startTime {
                        Text(date, format: .dateTime.day().month().hour().minute())
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .sqSingleLine()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SQSpace.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(session.isDriveTest ? Text("Drive Test") : Text("Couverture"))
    }
}
