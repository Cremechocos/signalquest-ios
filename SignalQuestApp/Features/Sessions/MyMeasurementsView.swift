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
            // La cause réelle (réseau, session…), comme les autres listes.
            errorMessage = error.userFacingMessage
        }
    }
}

struct MyMeasurementsView: View {
    /// Coloration courante, basculable Génération ↔ Signal. Défaut génération :
    /// l'iPhone ne mesure pas le signal, seules les mesures Android en portent.
    @State private var coloring: SessionPointColoring
    @State private var showsDisplay = false
    private let mapTitle: LocalizedStringKey
    @StateObject private var model: MyMeasurementsViewModel
    @Environment(\.dismiss) private var dismiss

    init(service: SessionsServicing, initialColoring: SessionPointColoring = .generation,
         title: LocalizedStringKey = "Mes mesures") {
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
                    .ignoresSafeArea()
                    .overlay(alignment: .top) { mapHeader }
                    .overlay(alignment: .bottom) {
                        if !model.points.isEmpty {
                            summaryCard
                                .padding(.horizontal, SQSpace.lg)
                                // Au-dessus du dock, en laissant visible l'attribution de MapKit.
                                .padding(.bottom, SQDock.floatingContentInset(subtracting: SQSpace.md) + SQSpace.xl)
                                .sqReadableWidth()
                        }
                    }
            }
            if model.isLoading {
                SQSpinner().controlSize(.large).tint(SQColor.brandRed)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : UIKit coupe le balayage retour, rétabli ici.
        .sqKeepsSwipeBack()
        .navigationTitle(mapTitle)
        .task { await model.load() }
        .sheet(isPresented: $showsDisplay) {
            MeasurementsDisplaySheet(coloring: $coloring, summary: model.pointSummary, shown: model.points.count)
        }
    }

    // MARK: En-tête sur la carte

    private var mapHeader: some View {
        HStack(spacing: SQSpace.sm) {
            MapFloatingIconButton(systemImage: "chevron.left", label: "Retour", identifier: "measurements.back") { dismiss() }
            MapFloatingTitle(title: mapTitle, identifier: "measurements.title")
            Spacer(minLength: 0)
            if !model.points.isEmpty {
                MapFloatingIconButton(systemImage: "slider.horizontal.3", label: "Afficher",
                                      identifier: "measurements.display", showsDot: coloring != .generation) {
                    showsDisplay = true
                }
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.sm)
    }

    // MARK: Carte du bas : total, page, légende

    private var sessionsRangeText: LocalizedStringKey {
        guard let total = model.totalSessions else { return "Sessions \(model.pageStart) à \(model.pageEnd)" }
        return "Sessions \(model.pageStart) à \(model.pageEnd) sur \(total)"
    }

    /// Mesures localisées de la page (avant allègement du nuage).
    private var measurementCount: Int { model.pointSummary?.locatedCount ?? model.points.count }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm2) {
            HStack(spacing: SQSpace.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(measurementCount) mesures")
                        .font(SQType.metricSmall)
                        .foregroundStyle(SQColor.label)
                        .monospacedDigit()
                    if (model.totalSessions ?? model.sessionCount) > 0 {
                        Text(sessionsRangeText)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .monospacedDigit()
                            .accessibilityIdentifier("measurements.pageRange")
                    }
                    if let summary = model.pointSummary, summary.isSampled {
                        Text("Échantillon : \(model.points.count) affichées sur \(summary.locatedCount)")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                pageButton("chevron.left", label: "Page précédente", identifier: "measurements.previousPage",
                           enabled: model.canGoBack) { await model.previousPage() }
                pageButton("chevron.right", label: "Page suivante", identifier: "measurements.nextPage",
                           enabled: model.canGoForward) { await model.nextPage() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("measurements.pageControls")
            if let errorMessage = model.errorMessage {
                HStack(spacing: SQSpace.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .accessibilityHidden(true)
                    Text(errorMessage)
                        .font(SQType.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Réessayer") { Task { await model.load() } }
                        .font(SQType.caption.weight(.semibold))
                        .frame(minHeight: 44)
                        .disabled(model.isLoading)
                }
                .foregroundStyle(SQColor.dangerInk)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("measurements.loadError")
            }
            Divider().overlay(SQColor.separator)
            MeasurementsLegend(coloring: coloring)
        }
        .padding(SQSpace.md2)
        .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
    }

    private func pageButton(_ systemImage: String, label: LocalizedStringKey, identifier: String,
                            enabled: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .frame(width: 44, height: 44)
                .sqSurface(SQColor.chip, in: Circle())
        }
        .buttonStyle(SQPressButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    // MARK: États sans carte

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "measurements.back") { dismiss() }
                    VStack(alignment: .leading, spacing: SQSpace.xs) {
                        Text(mapTitle)
                            .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                            .foregroundStyle(SQColor.label)
                            .sqHeader()
                        Text("Chaque point de couverture que tu as relevé, sur la carte.")
                            .font(SQType.callout)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let errorMessage = model.errorMessage {
                    ErrorStateView(title: String(localized: "Mesures indisponibles"), message: errorMessage) {
                        Task { await model.load() }
                    }
                } else if model.hasLoaded && model.sessionCount > 0 {
                    EmptyStateView(
                        title: "Aucune position sur cette page",
                        message: String(localized: "Aucune des sessions de cette page n’a de position. Passe à la page suivante."),
                        systemImage: "mappin.slash"
                    )
                    HStack(spacing: SQSpace.sm) {
                        pageButton("chevron.left", label: "Page précédente", identifier: "measurements.previousPage",
                                   enabled: model.canGoBack) { await model.previousPage() }
                        Spacer()
                        pageButton("chevron.right", label: "Page suivante", identifier: "measurements.nextPage",
                                   enabled: model.canGoForward) { await model.nextPage() }
                    }
                } else {
                    EmptyStateView(
                        title: "Aucune mesure pour l’instant",
                        message: String(localized: "Lance une session de couverture : chaque point relevé apparaîtra ici, y compris ceux faits avec l’app Android."),
                        systemImage: "mappin.slash"
                    )
                }
            }
            .padding(.horizontal, SQSpace.xl)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQDock.floatingContentInset)
            .sqReadableWidth()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .signalQuestBackground()
    }
}

/// Légende des points, sur la carte du bas et dans la feuille « Afficher ».
/// Couleurs tirées de l'échelle unique, comme les points eux-mêmes.
private struct MeasurementsLegend: View {
    let coloring: SessionPointColoring

    private var entries: [(Color, String)] {
        switch coloring {
        case .generation:
            return [SQQualityScale.Generation.fiveG, .fourG, .threeG, .twoG].map { ($0.color, $0.label) }
                + [(SQQualityScale.Generation.none.color, String(localized: "Inconnue"))]
        case .rsrp:
            return [SQQualityScale.Signal.excellent, .good, .fair, .weak, .poor, .unknown].map { ($0.color, $0.label) }
        }
    }

    var body: some View {
        MapFlowLayout(spacing: SQSpace.sm) {
            ForEach(entries, id: \.1) { color, label in
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 10, height: 10)
                    Text(label)
                        .font(SQFont.body(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(coloring == .generation ? Text("Légende par génération") : Text("Légende par signal"))
        .accessibilityValue(entries.map(\.1).joined(separator: ", "))
        .accessibilityIdentifier("measurements.legend")
    }
}

/// Feuille « Afficher » : couleur des points, légendes et allègement des longs
/// trajets, ce qui encombrait le haut de la carte.
private struct MeasurementsDisplaySheet: View {
    @Binding var coloring: SessionPointColoring
    let summary: SessionMapPointSummary?
    let shown: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                MapSheetHeader(title: String(localized: "Afficher"), closeIdentifier: "measurements.display.close") { dismiss() }
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Couleur des points").sqKicker().accessibilityAddTraits(.isHeader)
                    MapSegmented(
                        selection: $coloring,
                        options: [(.generation, String(localized: "Génération")), (.rsrp, String(localized: "Signal"))],
                        identifier: "measurements.display.coloring"
                    )
                    Text("Le signal vient des mesures faites avec l’app Android : l’iPhone ne le mesure pas. Les points sans signal restent en gris.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Légende").sqKicker().accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: SQSpace.sm2) {
                        MeasurementsLegend(coloring: .generation)
                        Divider().overlay(SQColor.separator)
                        MeasurementsLegend(coloring: .rsrp)
                    }
                    .padding(SQSpace.md2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sqCardBackground(SQColor.bg, cornerRadius: SQRadius.lg, elevation: .rest)
                }
                Label {
                    Group {
                        if let summary, summary.isSampled {
                            Text("Les longs trajets sont allégés à l’affichage : la carte montre un échantillon de \(shown) points sur \(summary.locatedCount). Tes mesures restent toutes enregistrées.")
                        } else {
                            Text("Les longs trajets peuvent être allégés à l’affichage. Tes mesures restent toutes enregistrées.")
                        }
                    }
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.label)
                    // Chiffres tabulaires : seuls à dessiner l'espace fine des milliers.
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(SQColor.labelSecondary)
                }
                .padding(SQSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .background(SQColor.surface.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
