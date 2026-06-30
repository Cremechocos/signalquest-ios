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
    /// Coloration courante, basculable Signal (RSRP) ↔ Génération. Défaut génération
    /// (iOS ne fournit pas de RSRP → la couleur signal est peu informative en iOS pur).
    @State private var coloring: SessionPointColoring
    private let mapTitle: String
    @StateObject private var model: MyMeasurementsViewModel

    init(service: SessionsServicing, initialColoring: SessionPointColoring = .generation, title: String = "Mes mesures") {
        _coloring = State(initialValue: initialColoring)
        self.mapTitle = title
        _model = StateObject(wrappedValue: MyMeasurementsViewModel(service: service))
    }

    var body: some View {
        ZStack {
            if model.points.isEmpty && !model.isLoading {
                emptyState
            } else {
                SessionTraceMapView(points: model.points, antennas: [], drawPath: false, coloring: coloring)
                    .ignoresSafeArea(edges: .bottom)
            }
            if model.isLoading {
                ProgressView().controlSize(.large).tint(SQColor.brandRed)
            }
        }
        .navigationTitle(mapTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .overlay(alignment: .top) {
            VStack(spacing: SQSpace.sm) {
                statsBar
                if !model.points.isEmpty { coloringPicker }
            }
            .padding(.top, SQSpace.sm)
        }
        .overlay(alignment: .bottomLeading) {
            if coloring == .generation && !model.points.isEmpty { generationLegend }
        }
    }

    /// Bascule de coloration de la carte : Signal (RSRP) ↔ Génération.
    private var coloringPicker: some View {
        Picker("Coloration", selection: $coloring) {
            Text("Signal").tag(SessionPointColoring.rsrp)
            Text("Génération").tag(SessionPointColoring.generation)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
        .padding(.horizontal, SQSpace.md)
        .accessibilityLabel("Coloration de la carte : signal ou génération")
    }

    /// Légende de la carte de couverture GÉNÉRATION (couleurs = `SessionGenerationColor`).
    private var generationLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Génération").font(.caption2.weight(.bold)).foregroundStyle(SQColor.labelSecondary)
            legendRow(Color(red: 0.545, green: 0.361, blue: 0.965), "5G")
            legendRow(Color(red: 0.231, green: 0.510, blue: 0.965), "4G")
            legendRow(Color(red: 0.078, green: 0.722, blue: 0.651), "3G")
            legendRow(Color(red: 0.961, green: 0.620, blue: 0.043), "2G")
            legendRow(Color(red: 0.580, green: 0.639, blue: 0.722), "Aucun")
        }
        .padding(SQSpace.sm + 2)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous).stroke(SQColor.separator, lineWidth: 1) }
        .padding(SQSpace.md)
        .accessibilityHidden(true)
    }

    private func legendRow(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.caption2).foregroundStyle(SQColor.label)
        }
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
