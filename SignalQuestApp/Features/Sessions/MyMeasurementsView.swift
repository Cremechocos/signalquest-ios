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
    /// Chips capsules de la DA (actif brique / inactif surface + ombre repos).
    private var coloringPicker: some View {
        HStack(spacing: SQSpace.sm) {
            coloringChip("Signal", value: .rsrp)
            coloringChip("Génération", value: .generation)
        }
        .padding(.horizontal, SQSpace.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coloration de la carte : signal ou génération")
    }

    private func coloringChip(_ label: String, value: SessionPointColoring) -> some View {
        let isSelected = coloring == value
        return Button {
            Haptics.selection()
            coloring = value
        } label: {
            Text(label)
                .font(SQFont.body(13, .semibold))
                .padding(.horizontal, SQSpace.lg - 2)
                .padding(.vertical, SQSpace.sm)
                .frame(minHeight: 34)
                .background(isSelected ? AnyShapeStyle(SQColor.brandRed) : AnyShapeStyle(SQColor.surface), in: Capsule(style: .continuous))
                .foregroundStyle(isSelected ? SQColor.onAccent : SQColor.label)
                .sqShadowSoft()
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Légende de la carte de couverture GÉNÉRATION — couleurs dérivées de
    /// `SessionGenerationColor` (celles des points) pour rester synchrones.
    private var generationLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Génération")
                .font(SQFont.body(12, .semibold, relativeTo: .caption2))
                .foregroundStyle(SQColor.labelSecondary)
            legendRow(Color(uiColor: SessionGenerationColor.ui("5G")), "5G")
            legendRow(Color(uiColor: SessionGenerationColor.ui("4G")), "4G")
            legendRow(Color(uiColor: SessionGenerationColor.ui("3G")), "3G")
            legendRow(Color(uiColor: SessionGenerationColor.ui("2G")), "2G")
            legendRow(Color(uiColor: SessionGenerationColor.ui(nil)), "Aucun")
        }
        .padding(SQSpace.sm + 2)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowSoft()
        .padding(SQSpace.md)
        .accessibilityHidden(true)
    }

    private func legendRow(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label)
                .font(SQFont.body(11.5, relativeTo: .caption2))
                .foregroundStyle(SQColor.label)
        }
    }

    @ViewBuilder
    private var statsBar: some View {
        if !model.points.isEmpty {
            Text("\(model.points.count) points · \(model.sessionCount) session\(model.sessionCount > 1 ? "s" : "")")
                .font(SQFont.body(13, .semibold, relativeTo: .caption))
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.lg - 2)
                .padding(.vertical, SQSpace.sm)
                .background(SQColor.surface, in: Capsule(style: .continuous))
                .sqShadowSoft()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(model.points.count) points de mesure sur \(model.sessionCount) sessions")
        }
    }

    private var emptyState: some View {
        VStack(spacing: SQSpace.lg) {
            EmptyStateView(
                title: "Aucune mesure",
                message: model.errorMessage ?? "Aucune mesure géolocalisée pour l'instant.",
                systemImage: "mappin.slash"
            )
            Text("Lance un Drive Test pour enregistrer tes premières mesures.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SQSpace.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SQColor.bg.ignoresSafeArea())
    }
}
