import SwiftUI

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
            case .driveTest: return "Drive-test"
            case .coverage: return "Couverture"
            }
        }
    }

    let service: SessionsServicing
    private var offset = 0
    private let pageSize = 30

    init(service: SessionsServicing) { self.service = service }

    var filtered: [CoverageSession] {
        switch filter {
        case .all: return sessions
        case .driveTest: return sessions.filter { $0.isDriveTest }
        case .coverage: return sessions.filter { !$0.isDriveTest }
        }
    }

    func reload() async {
        offset = 0
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await service.sessions(offset: 0, limit: pageSize)
            sessions = page.sessions
            hasMore = page.pagination?.hasMore ?? (page.sessions.count >= pageSize)
            offset = page.sessions.count
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.sessions(offset: offset, limit: pageSize)
            sessions.append(contentsOf: page.sessions)
            hasMore = page.pagination?.hasMore ?? (page.sessions.count >= pageSize)
            offset += page.sessions.count
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }
}

/// Journal des sessions/logs de mesure de l'utilisateur (drive-test + couverture),
/// synchronisées entre Android et iOS via le compte.
struct SessionsListView: View {
    @StateObject private var model: SessionsListViewModel

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

                if model.filtered.isEmpty && !model.isLoading {
                    EmptyStateView(
                        title: "Aucune session",
                        message: "Tes sessions enregistrées (drive-test, couverture) — y compris depuis Android — apparaîtront ici.",
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
                        HStack { Spacer(); ProgressView().tint(SQColor.brandRed); Spacer() }
                            .padding(.vertical, SQSpace.md)
                            .task { await model.loadMore() }
                    }
                }

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.warning)
                        .padding(.horizontal, SQSpace.xs)
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.md)
            .padding(.bottom, SQSpace.xxl)
        }
        .signalQuestBackground()
        .navigationTitle("Mes sessions")
        .toolbarTitleInlineCompat()
        .refreshable { await model.reload() }
        .overlay {
            if model.isLoading && model.sessions.isEmpty {
                ProgressView().tint(SQColor.brandRed)
            }
        }
        .task { if model.sessions.isEmpty { await model.reload() } }
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
                Text(session.name ?? (session.isDriveTest ? "Drive-test" : "Couverture"))
                    .font(SQFont.body(15.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                HStack(spacing: SQSpace.sm) {
                    if let points = session.totalPoints {
                        Label("\(points)", systemImage: "mappin.and.ellipse")
                    }
                    if let km = session.distanceKm, km > 0 {
                        Label(km < 1 ? "\(Int((km * 1000).rounded())) m" : String(format: "%.1f km", km), systemImage: "ruler")
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
