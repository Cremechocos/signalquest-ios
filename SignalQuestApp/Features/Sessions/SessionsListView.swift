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
        List {
            Section {
                Picker("Type", selection: $model.filter) {
                    ForEach(SessionsListViewModel.Filter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: SQSpace.md, bottom: SQSpace.sm, trailing: SQSpace.md))
                .listRowBackground(Color.clear)
            }

            if model.filtered.isEmpty && !model.isLoading {
                emptyState
                    .listRowBackground(Color.clear)
            } else {
                ForEach(model.filtered) { session in
                    NavigationLink {
                        SessionDetailView(session: session)
                    } label: {
                        SessionRow(session: session)
                    }
                }
                if model.hasMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                        .task { await model.loadMore() }
                }
            }

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(SQColor.warning)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SQColor.bg.ignoresSafeArea())
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

    private var emptyState: some View {
        VStack(spacing: SQSpace.md) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 44))
                .foregroundStyle(SQColor.labelSecondary)
            Text("Aucune session")
                .font(.headline)
                .foregroundStyle(SQColor.label)
            Text("Tes sessions enregistrées (drive-test, couverture) — y compris depuis Android — apparaîtront ici.")
                .font(.subheadline)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.xxl)
    }
}

private struct SessionRow: View {
    let session: CoverageSession

    var body: some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: session.isDriveTest ? "car.fill" : "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(session.isDriveTest ? SQColor.brandBlue : SQColor.brandOrange, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name ?? (session.isDriveTest ? "Drive-test" : "Couverture"))
                    .font(.subheadline.weight(.semibold))
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
                .font(.caption2)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(1)
                if !session.operators.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(session.operators.prefix(4)) { op in
                            Text(op.label)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(SessionDetailView.operatorColor(op.colorHex).opacity(0.18), in: Capsule())
                                .foregroundStyle(SessionDetailView.operatorColor(op.colorHex))
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
