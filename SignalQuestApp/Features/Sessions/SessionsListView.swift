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
}

@MainActor
final class SessionsListViewModel: ObservableObject {
    @Published var sessions: [CoverageSession] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasMore = false
    @Published var filter: Filter = .all

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
            hasMore = !page.sessions.isEmpty && (page.pagination?.hasMore ?? (page.sessions.count >= pageSize))
            offset = page.sessions.count
        } catch {
            guard requestGeneration == generation else { return }
            if !error.isCancellation { errorMessage = error.localizedDescription }
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
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }
}

/// Journal des sessions/logs de mesure de l'utilisateur (drive-test + couverture),
/// synchronisées entre Android et iOS via le compte.
struct SessionsListView: View {
    @StateObject private var model: SessionsListViewModel
    @StateObject private var archiveModel = LocalCoverageArchiveViewModel()

    init(service: SessionsServicing) {
        _model = StateObject(wrappedValue: SessionsListViewModel(service: service))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SQSpace.sm + 2) {
                SQSegmentedFilter(
                    selection: $model.filter,
                    options: SessionsListViewModel.Filter.allCases.map { (value: $0, label: $0.label, icon: String?.none) }
                )
                .padding(.horizontal, -SQSpace.lg)
                .padding(.bottom, SQSpace.xs)

                if model.showsEmptyState(archive: archiveModel.snapshot, archiveIsLoading: archiveModel.isLoading) {
                    EmptyStateView(
                        title: "Aucune session",
                        message: model.sessions.isEmpty
                            ? "Tes sessions enregistrées (drive-test, couverture) — y compris depuis Android — apparaîtront ici."
                            : "Aucune session ne correspond à ce filtre dans l’historique complet.",
                        systemImage: "point.topleft.down.curvedto.point.bottomright.up"
                    )
                } else {
                    ForEach(model.filtered) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            SessionRow(session: session)
                        }
                        .buttonStyle(SQPressButtonStyle())
                    }
                    if model.hasMore {
                        if model.isLoading {
                            HStack { Spacer(); ProgressView().tint(SQColor.brandRed); Spacer() }
                                .padding(.vertical, SQSpace.md)
                        } else if model.filtered.isEmpty || model.errorMessage != nil {
                            GradientButton("Charger la suite", style: .secondary) {
                                Task { await model.loadMore() }
                            }
                                .accessibilityIdentifier("sessions.loadMore")
                        } else {
                            HStack { Spacer(); ProgressView().tint(SQColor.brandRed); Spacer() }
                                .padding(.vertical, SQSpace.md)
                                .task { await model.loadMore() }
                        }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.warning)
                        .padding(.horizontal, SQSpace.xs)
                    if !model.hasMore {
                        GradientButton("Réessayer", style: .secondary) {
                            Task { await model.reload() }
                        }
                    }
                }

                if model.showsLocalCoverageArchive && !archiveModel.snapshot.entries.isEmpty {
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text("Archives locales")
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                        Text("Anciennes captures de couverture conservées sur cet appareil. Elles ne sont plus envoyées.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    .padding(.top, SQSpace.lg)
                    .accessibilityIdentifier("sessions.localArchives")

                    ForEach(archiveModel.snapshot.entries) { archive in
                        NavigationLink {
                            LocalCoverageArchiveDetailView(archive: archive)
                        } label: {
                            LocalCoverageArchiveRow(archive: archive)
                        }
                        .buttonStyle(SQPressButtonStyle())
                    }
                }

                if model.showsLocalCoverageArchive && archiveModel.snapshot.unreadableSources > 0 {
                    Label("Certaines archives locales sont illisibles. Les fichiers ont été conservés.", systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.warning)
                        .accessibilityIdentifier("sessions.localArchives.error")
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.md)
            .padding(.bottom, SQSpace.xxl)
            .sqReadableWidth()
        }
        .signalQuestBackground()
        .navigationTitle("Mes enregistrements de trajet")
        .toolbarTitleInlineCompat()
        .refreshable {
            await archiveModel.reload()
            await model.reload()
        }
        .overlay {
            if model.isLoading && model.sessions.isEmpty &&
                (!model.showsLocalCoverageArchive || archiveModel.snapshot.entries.isEmpty) {
                ProgressView().tint(SQColor.brandRed)
            }
        }
        .task { if model.sessions.isEmpty { await model.reload() } }
        .task { await archiveModel.reload() }
    }
}

private struct LocalCoverageArchiveRow: View {
    let archive: LocalCoverageArchive

    var body: some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: "archivebox")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SQColor.accentInk)
                .frame(width: 42, height: 42)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text(archive.state == .recording ? LocalizedStringKey("Brouillon de couverture") : LocalizedStringKey("Ancienne capture de couverture"))
                    .font(SQFont.body(15.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                Text(Date(timeIntervalSince1970: Double(archive.startTime) / 1_000), format: .dateTime.day().month().year().hour().minute())
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer(minLength: SQSpace.sm)
            Image(systemName: "chevron.right")
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(SQSpace.md + 2)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowSoft()
        .contentShape(Rectangle())
        .accessibilityIdentifier("sessions.localArchive.row")
    }
}

private struct LocalCoverageArchiveDetailView: View {
    let archive: LocalCoverageArchive

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                Text("Archive conservée sur cet appareil")
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                Text("Cette consultation reste sur cet appareil et n’envoie aucune coordonnée.")
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)

                VStack(alignment: .leading, spacing: SQSpace.md) {
                    Label(archive.state == .recording ? LocalizedStringKey("Brouillon interrompu") : LocalizedStringKey("Capture terminée"), systemImage: "archivebox")
                    HStack {
                        Text("Points enregistrés")
                        Spacer()
                        Text(archive.pointCount, format: .number)
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
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                .sqShadowSoft()
            }
            .padding(SQSpace.lg)
            .sqReadableWidth()
        }
        .signalQuestBackground()
        .navigationTitle("Archive locale")
        .toolbarTitleInlineCompat()
        .accessibilityIdentifier("sessions.localArchive.detail")
    }
}

private struct SessionRow: View {
    let session: CoverageSession

    var body: some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: session.isDriveTest ? "car.fill" : "dot.radiowaves.left.and.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 42, height: 42)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name ?? (session.isDriveTest ? String(localized: "Drive Test") : String(localized: "Couverture")))
                    .font(SQFont.body(15.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                HStack(spacing: SQSpace.sm) {
                    if let points = session.totalPoints {
                        Label("\(points)", systemImage: "mappin.and.ellipse")
                    }
                    if let km = session.distanceKm, km > 0 {
                        Label(SQUnits.distance(kilometers: km), systemImage: "ruler")
                    }
                    if let rsrp = session.avgSignalStrength {
                        Label("\(Int(rsrp)) dBm", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    if let date = session.startTime {
                        Text(date, format: .dateTime.day().month().year())
                    }
                }
                .font(SQFont.body(11.5, .medium, relativeTo: .caption2))
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(1)
                if !session.operators.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(session.operators.prefix(4)) { op in
                            Text(op.label)
                                .font(SQFont.body(11, .semibold, relativeTo: .caption2))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(SessionDetailView.operatorColor(op.colorHex).opacity(0.14), in: Capsule(style: .continuous))
                                .foregroundStyle(SessionDetailView.operatorColor(op.colorHex))
                        }
                    }
                }
            }
            Spacer(minLength: SQSpace.sm)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(SQSpace.md + 2)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowSoft()
        .contentShape(Rectangle())
    }
}
