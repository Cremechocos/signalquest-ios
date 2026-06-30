import SwiftUI

/// F7 — « Mes mesures sur la carte » : agrège les points géolocalisés des sessions
/// de couverture de l'utilisateur (drive tests iOS + Android) et les affiche sur une
/// carte (nuage de points, réutilise `SessionTraceMapView`). Source = `/api/coverage/sessions`.
@MainActor
final class MyMeasurementsViewModel: ObservableObject {
    @Published private(set) var points: [CoverageSessionPoint] = []
    @Published private(set) var sessionCount = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service: SessionsServicing
    init(service: SessionsServicing) { self.service = service }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let list = try await service.sessions(offset: 0, limit: 40)
            sessionCount = list.sessions.count
            // Récupère les points des sessions les plus récentes EN PARALLÈLE (borné),
            // puis les agrège en un seul nuage.
            let recent = Array(list.sessions.prefix(15))
            let service = self.service
            let collected = await withTaskGroup(of: [CoverageSessionPoint].self) { group -> [CoverageSessionPoint] in
                for session in recent {
                    group.addTask { (try? await service.sessionDetail(id: session.id))?.points ?? [] }
                }
                var all: [CoverageSessionPoint] = []
                for await pts in group { all.append(contentsOf: pts) }
                return all
            }
            points = collected.filter(\.hasValidCoordinate)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MyMeasurementsView: View {
    @StateObject private var model: MyMeasurementsViewModel

    init(service: SessionsServicing) {
        _model = StateObject(wrappedValue: MyMeasurementsViewModel(service: service))
    }

    var body: some View {
        ZStack {
            if model.points.isEmpty && !model.isLoading {
                emptyState
            } else {
                SessionTraceMapView(points: model.points, antennas: [], drawPath: false)
                    .ignoresSafeArea(edges: .bottom)
            }
            if model.isLoading {
                ProgressView().controlSize(.large).tint(SQColor.brandRed)
            }
        }
        .navigationTitle("Mes mesures")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .overlay(alignment: .top) { statsBar }
    }

    @ViewBuilder
    private var statsBar: some View {
        if !model.points.isEmpty {
            Text("\(model.points.count) points · \(model.sessionCount) session\(model.sessionCount > 1 ? "s" : "")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().stroke(SQColor.separator, lineWidth: 1) }
                .padding(.top, SQSpace.sm)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(model.points.count) points de mesure sur \(model.sessionCount) sessions")
        }
    }

    private var emptyState: some View {
        VStack(spacing: SQSpace.md) {
            Image(systemName: "mappin.slash")
                .font(.largeTitle)
                .foregroundStyle(SQColor.labelSecondary)
            Text(model.errorMessage ?? "Aucune mesure géolocalisée pour l'instant.")
                .font(.subheadline)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
            Text("Lance un Drive Test pour enregistrer tes premières mesures.")
                .font(.caption)
                .foregroundStyle(SQColor.labelTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(SQSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SQColor.bg)
    }
}
