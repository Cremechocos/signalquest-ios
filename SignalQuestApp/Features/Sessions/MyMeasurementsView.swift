import SwiftUI

/// F7 — « Mes mesures sur la carte » : consulte les positions des sessions de
/// couverture historiques et Android, par pages bornées. Source = `/api/coverage/sessions`.
@MainActor
final class MyMeasurementsViewModel: ObservableObject {
    @Published private(set) var points: [CoverageSessionPoint] = []
    @Published private(set) var sessionCount = 0
    @Published private(set) var totalSessions: Int?
    @Published private(set) var pageOffset = 0
    @Published private(set) var hasMore = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var pointSummary: SessionMapPointSummary?
    @Published private(set) var renderVersion = UUID()
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let fetch: @MainActor (Int, Int) async throws -> SessionsListResponse
    private let pageSize = 40
    private var nextOffset = 0
    private var previousOffsets: [Int] = []
    private var requestGeneration = UUID()
    private enum PageMove { case stay, forward, backward }

    init(service: SessionsServicing) {
        fetch = { offset, limit in
            try await service.sessions(offset: offset, limit: limit, mapPoints: true)
        }
    }

    init(fetch: @escaping @MainActor (Int, Int) async throws -> SessionsListResponse) {
        self.fetch = fetch
    }

    var canGoBack: Bool { hasLoaded && !previousOffsets.isEmpty && !isLoading }
    var canGoForward: Bool { hasLoaded && hasMore && !isLoading }
    var pageStart: Int { sessionCount == 0 ? 0 : pageOffset + 1 }
    var pageEnd: Int { pageOffset + sessionCount }

    func load() async {
        await loadPage(at: pageOffset, move: .stay)
    }

    func nextPage() async {
        guard canGoForward else { return }
        await loadPage(at: nextOffset, move: .forward)
    }

    func previousPage() async {
        guard canGoBack else { return }
        await loadPage(at: previousOffsets[previousOffsets.count - 1], move: .backward)
    }

    private func loadPage(at offset: Int, move: PageMove) async {
        let generation = UUID()
        requestGeneration = generation
        isLoading = true
        errorMessage = nil
        defer { if requestGeneration == generation { isLoading = false } }
        do {
            // Une seule page et son nuage allégé. Changer de page remplace les
            // points au lieu de les accumuler sans limite sur la carte.
            let list = try await fetch(offset, pageSize)
            guard requestGeneration == generation else { return }
            switch move {
            case .stay: break
            case .forward: previousOffsets.append(pageOffset)
            case .backward: previousOffsets.removeLast()
            }
            pageOffset = offset
            sessionCount = list.sessions.count
            totalSessions = list.pagination?.total
            hasMore = !list.sessions.isEmpty && (list.pagination?.hasMore ?? (list.sessions.count >= pageSize))
            nextOffset = offset + list.sessions.count
            points = list.mapPoints.filter(\.hasValidCoordinate)
            pointSummary = list.mapPointSummary
            renderVersion = UUID()
            hasLoaded = true
        } catch {
            guard requestGeneration == generation, !error.isCancellation else { return }
            errorMessage = String(localized: "Impossible de charger les mesures. Réessaie.")
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
                SessionTraceMapView(points: model.points, antennas: [], drawPath: false,
                    coloring: coloring, renderID: model.renderVersion)
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
                if model.hasLoaded, (model.totalSessions ?? model.sessionCount) > 0 {
                    pageControls
                }
                statsBar
                if let errorMessage = model.errorMessage, !model.points.isEmpty {
                    HStack(spacing: SQSpace.sm) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(errorMessage).font(SQType.caption)
                        Button("Réessayer") { Task { await model.load() } }
                            .disabled(model.isLoading)
                    }
                    .foregroundStyle(SQColor.dangerInk)
                    .padding(SQSpace.sm)
                    .background(SQColor.surface, in: Capsule())
                    .accessibilityIdentifier("measurements.loadError")
                }
                if !model.points.isEmpty { coloringPicker }
            }
            .padding(.top, SQSpace.sm)
        }
        .overlay(alignment: .bottomLeading) {
            if coloring == .generation && !model.points.isEmpty { generationLegend }
        }
    }

    private var pageControls: some View {
        HStack(spacing: SQSpace.sm) {
            Button { Task { await model.previousPage() } } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .disabled(!model.canGoBack)
            .accessibilityLabel("Précédent")
            Text("Sessions")
                .font(SQType.caption)
            Text(verbatim: "\(model.pageStart)–\(model.pageEnd) / \(model.totalSessions.map(String.init) ?? "…")")
                .font(SQType.caption)
                .monospacedDigit()
                .lineLimit(1)
            Button { Task { await model.nextPage() } } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .disabled(!model.canGoForward)
            .accessibilityLabel("Suivant")
        }
        .foregroundStyle(SQColor.label)
        .padding(.horizontal, SQSpace.xs)
        .background(SQColor.surface, in: Capsule())
        .sqShadowSoft()
        .buttonStyle(SQPressButtonStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("measurements.pageControls")
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
            Text(LocalizedStringKey(label))
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
            Text(LocalizedStringKey(label))
                .font(SQFont.body(11.5, relativeTo: .caption2))
                .foregroundStyle(SQColor.label)
        }
    }

    @ViewBuilder
    private var statsBar: some View {
        if !model.points.isEmpty {
            VStack(spacing: SQSpace.xxs) {
                HStack(spacing: SQSpace.xs) {
                    Text(verbatim: "\(model.points.count)")
                    Text("Points affichés")
                }
                if let summary = model.pointSummary, summary.isSampled {
                    HStack(spacing: SQSpace.xs) {
                        Text("Échantillon")
                        Text(verbatim: "\(model.points.count) / \(summary.locatedCount)")
                            .monospacedDigit()
                    }
                    .font(SQType.caption)
                } else if model.pointSummary == nil {
                    Text("Les longs trajets peuvent être allégés.")
                        .font(SQType.caption)
                }
            }
                .font(SQFont.body(13, .semibold, relativeTo: .caption))
                .foregroundStyle(SQColor.label)
                .padding(.horizontal, SQSpace.lg - 2)
                .padding(.vertical, SQSpace.sm)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md))
                .sqShadowSoft()
                .accessibilityElement(children: .combine)
        }
    }

    private var emptyState: some View {
        VStack(spacing: SQSpace.lg) {
            EmptyStateView(
                title: model.errorMessage != nil ? "Chargement impossible"
                    : model.hasLoaded && model.sessionCount > 0
                        ? "Aucune position sur cette page" : "Aucune mesure",
                message: model.errorMessage ?? (model.hasLoaded && model.sessionCount > 0
                    ? "Aucune position utilisable sur cette page."
                    : "Aucune mesure géolocalisée pour l'instant."),
                systemImage: "mappin.slash"
            )
            if model.errorMessage != nil {
                GradientButton("Réessayer", style: .secondary) { Task { await model.load() } }
                    .padding(.horizontal, SQSpace.xl)
            } else if !model.hasLoaded || model.totalSessions == 0 {
                Text("Les anciennes sessions de couverture, y compris depuis Android, apparaîtront ici.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SQSpace.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SQColor.bg.ignoresSafeArea())
    }
}
