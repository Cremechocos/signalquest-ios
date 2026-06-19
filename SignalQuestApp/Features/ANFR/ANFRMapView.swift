import SwiftUI
import MapKit
#if canImport(MapLibre)
import MapLibre
#endif

// MARK: - ViewModel

@MainActor
final class ANFRMapViewModel: ObservableObject {
    @Published var sites: [ANFRMapSite] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdate: String?

    @Published var operatorFilters: Set<ANFROperator> = Set(ANFROperator.allCases)
    @Published var selectedModTypes: Set<ANFRModType> = Set(ANFRModType.allCases)

    @Published var availableDates: [String] = []
    @Published var currentSnapshotDate: String?
    @Published var selectedDate: String?

    private let service: ANFRServicing
    init(service: ANFRServicing) { self.service = service }

    /// Sites filtrés selon opérateurs / générations / types de modif actifs.
    var filteredSites: [ANFRMapSite] {
        sites.filter { site in
            // Au moins une antenne dont l'opérateur, la génération et le type
            // de modif passent les filtres actifs.
            site.antennas.contains { antenna in
                let opOK = antenna.operator.map(operatorFilters.contains) ?? false
                let modOK = selectedModTypes.contains(antenna.modType)
                return opOK && modOK
            }
        }
    }

    func load() async {
        if AppEnvironment.usesDemoData {
            sites = ANFRDemoData.mapSnapshot.sites
            lastUpdate = ANFRDemoData.mapSnapshot.lastUpdate
            availableDates = ANFRDemoData.archiveDates.dates
            currentSnapshotDate = ANFRDemoData.archiveDates.current
            errorMessage = nil
            return
        }
        guard sites.isEmpty else { return }
        await loadSnapshot()
        await loadArchiveDates()
    }

    func loadSnapshot() async {
        if AppEnvironment.usesDemoData {
            sites = ANFRDemoData.mapSnapshot.sites
            lastUpdate = ANFRDemoData.mapSnapshot.lastUpdate
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let snapshot = try await service.mapSnapshot(date: selectedDate)
            sites = snapshot.sites
            lastUpdate = snapshot.lastUpdate
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    private func loadArchiveDates() async {
        guard let meta = try? await service.archiveDates() else { return }
        availableDates = meta.dates
        currentSnapshotDate = meta.current
    }

    func selectDate(_ date: String?) async {
        guard date != selectedDate else { return }
        selectedDate = date
        sites = []
        await loadSnapshot()
    }

    func toggleOperator(_ op: ANFROperator) {
        if operatorFilters.contains(op) {
            let next = operatorFilters.subtracting([op])
            operatorFilters = next.isEmpty ? [op] : next
        } else {
            operatorFilters.insert(op)
        }
    }

    func resetFilters() {
        operatorFilters = Set(ANFROperator.allCases)
        selectedModTypes = Set(ANFRModType.allCases)
    }

    var dateLabel: String {
        guard let raw = selectedDate ?? currentSnapshotDate,
              let date = ANFRDateParser.date(from: raw) else { return lastUpdate ?? "Dernier relevé" }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

// MARK: - Screen

struct ANFRMapView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: ANFRMapViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mapCenter = CLLocationCoordinate2D(latitude: 46.7, longitude: 2.4)
    @State private var mapZoom: Double = 5.1
    @State private var selectedSite: ANFRMapSite?
    @State private var showFilters = false
    @State private var showDatePicker = false

    init(service: ANFRServicing) {
        _model = StateObject(wrappedValue: ANFRMapViewModel(service: service))
    }

    var body: some View {
        ZStack {
            mapLayer
            controlsLayer
        }
        .navigationTitle("Carte ANFR")
        .toolbarTitleInlineCompat()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    showDatePicker = true
                } label: {
                    Image(systemName: "calendar")
                        .foregroundStyle(SQColor.brandRed)
                }
            }
        }
        .sheet(item: $selectedSite) { site in
            ANFRSiteDetailSheet(site: site, service: services.anfr)
        }
        .sheet(isPresented: $showFilters) {
            ANFRMapFilterSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationBackgroundCompat(SQColor.bg)
        }
        .sheet(isPresented: $showDatePicker) {
            ANFRDatePickerSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationBackgroundCompat(SQColor.bg)
        }
        .task { await model.load() }
    }

    // MARK: Map

    @ViewBuilder
    private var mapLayer: some View {
#if canImport(MapLibre)
        ANFRMapLibreView(
            sites: model.filteredSites,
            colorScheme: colorScheme,
            center: $mapCenter,
            zoom: $mapZoom,
            onSelectSite: { site in
                Haptics.light()
                selectedSite = site
            }
        )
        .ignoresSafeArea(edges: .bottom)
#else
        fallbackMap
#endif
    }

#if !canImport(MapLibre)
    private var fallbackMap: some View {
        Map(position: .constant(.region(MKCoordinateRegion(
            center: mapCenter,
            span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)
        )))) {
            ForEach(model.filteredSites) { site in
                Annotation(site.city, coordinate: site.coordinate) {
                    Button {
                        Haptics.light()
                        selectedSite = site
                    } label: {
                        let style = ANFRMarkerStyle(site: site)
                        Circle()
                            .fill(style.dominantOperator.color)
                            .frame(width: 22, height: 22)
                            .overlay { Circle().stroke(.white, lineWidth: 2) }
                            .overlay {
                                Image(systemName: style.modType.glyph)
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundStyle(.white)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }
#endif

    // MARK: Controls overlay

    private var controlsLayer: some View {
        VStack(spacing: SQSpace.sm + 2) {
            topBar
            operatorStrip
            Spacer()
            if model.isLoading {
                loadingPill
                    .padding(.bottom, SQSpace.lg)
            } else if model.filteredSites.isEmpty, model.errorMessage == nil {
                emptyPill
                    .padding(.bottom, SQSpace.lg)
            }
            if let error = model.errorMessage {
                errorPill(error)
                    .padding(.bottom, SQSpace.lg)
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.top, SQSpace.sm)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var topBar: some View {
        HStack(spacing: SQSpace.sm) {
            // Date / snapshot
            Button {
                Haptics.light()
                showDatePicker = true
            } label: {
                HStack(spacing: SQSpace.sm - 1) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(SQColor.brandRed)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Relevé").sqKicker()
                        Text(model.dateLabel)
                            .font(SQFont.archivo(14, .bold))
                            .foregroundStyle(SQColor.label)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, SQSpace.md - 2)
                .frame(height: 48)
                .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                        .stroke(SQColor.label, lineWidth: 2)
                }
            }
            .buttonStyle(SQPressButtonStyle())

            Spacer()

            // Count badge
            HStack(spacing: SQSpace.xs + 2) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .bold))
                Text("\(model.filteredSites.count)")
                    .font(SQFont.archivo(15, .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, SQSpace.md - 1)
            .frame(height: 48)
            .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))

            // Filter button
            Button {
                Haptics.light()
                showFilters = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(SQColor.fill, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                                .stroke(SQColor.separator, lineWidth: 1.5)
                        }
                        .foregroundStyle(SQColor.label)
                    if activeFilterCount > 0 {
                        Text("\(activeFilterCount)")
                            .font(SQFont.archivo(10, .bold))
                            .frame(minWidth: 17, minHeight: 17)
                            .background(SQColor.brandRed, in: Circle())
                            .foregroundStyle(.white)
                            .offset(x: 5, y: -5)
                    }
                }
            }
            .buttonStyle(SQPressButtonStyle())
        }
        .padding(SQSpace.xs + 1)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                .stroke(SQColor.separator, lineWidth: 1.5)
        }
        .shadow(color: chromeShadow, radius: 14, y: 6)
    }

    private var operatorStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm - 1) {
                ForEach(ANFROperator.allCases) { op in
                    let on = model.operatorFilters.contains(op)
                    Button {
                        Haptics.selection()
                        withAnimation(reduceMotion ? nil : SQMotion.fast) { model.toggleOperator(op) }
                    } label: {
                        HStack(spacing: SQSpace.xs + 2) {
                            Circle().fill(on ? Color.white : op.color).frame(width: 7, height: 7)
                            Text(op.label).font(SQFont.archivo(13, .bold))
                        }
                        .padding(.horizontal, SQSpace.md - 2)
                        .frame(height: 34)
                        .background(on ? AnyShapeStyle(op.color) : AnyShapeStyle(SQColor.surface), in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                                .stroke(on ? Color.clear : SQColor.separator, lineWidth: 1.5)
                        }
                        .foregroundStyle(on ? Color.white : SQColor.label)
                    }
                    .buttonStyle(SQPressButtonStyle())
                }
            }
            .padding(.horizontal, SQSpace.xs)
        }
        .frame(height: 40)
    }

    private var loadingPill: some View {
        HStack(spacing: SQSpace.sm) {
            ProgressView().tint(SQColor.brandRed)
            Text("Chargement des sites ANFR…")
                .font(SQFont.archivo(13, .semibold))
                .foregroundStyle(SQColor.label)
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm + 1)
        .background(SQColor.surface, in: Capsule())
        .overlay { Capsule().stroke(SQColor.separator, lineWidth: 1.5) }
        .shadow(color: chromeShadow, radius: 12, y: 5)
    }

    private var emptyPill: some View {
        Label("Aucun site pour ces filtres", systemImage: "magnifyingglass")
            .font(SQFont.archivo(13, .semibold))
            .foregroundStyle(SQColor.labelSecondary)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 1)
            .background(SQColor.surface, in: Capsule())
            .overlay { Capsule().stroke(SQColor.separator, lineWidth: 1.5) }
            .shadow(color: chromeShadow, radius: 12, y: 5)
    }

    private func errorPill(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(SQFont.archivo(13, .semibold))
            .foregroundStyle(SQColor.label)
            .lineLimit(2)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm + 1)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .stroke(SQColor.warning.opacity(0.6), lineWidth: 1.5)
            }
            .frame(maxWidth: 320)
            .shadow(color: chromeShadow, radius: 12, y: 5)
    }

    private var chromeShadow: Color {
        Color.black.opacity(colorScheme == .dark ? 0.30 : 0.10)
    }

    private var activeFilterCount: Int {
        var count = 0
        if model.operatorFilters.count != ANFROperator.allCases.count { count += 1 }
        if model.selectedModTypes.count != ANFRModType.allCases.count { count += 1 }
        return count
    }
}

// MARK: - Filter sheet

struct ANFRMapFilterSheet: View {
    @ObservedObject var model: ANFRMapViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                SQSheetHandle()

                section(title: "Opérateurs") {
                    FlexibleChips(ANFROperator.allCases) { op in
                        chip(label: op.label, color: op.color, on: model.operatorFilters.contains(op)) {
                            model.toggleOperator(op)
                        }
                    }
                }

                section(title: "Type de modification") {
                    FlexibleChips(ANFRModType.allCases) { type in
                        chip(label: type.label, color: type.color, on: model.selectedModTypes.contains(type)) {
                            if model.selectedModTypes.contains(type) {
                                let next = model.selectedModTypes.subtracting([type])
                                model.selectedModTypes = next.isEmpty ? [type] : next
                            } else {
                                model.selectedModTypes.insert(type)
                            }
                        }
                    }
                }

                GradientButton("Réinitialiser les filtres", systemImage: "arrow.counterclockwise", style: .secondary) {
                    model.resetFilters()
                }
            }
            .padding(SQSpace.lg)
            .padding(.bottom, SQSpace.huge)
        }
        .signalQuestBackground()
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text(title).sqKicker()
            content()
        }
    }

    private func chip(label: String, color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: SQSpace.xs + 2) {
                Circle().fill(on ? Color.white : color).frame(width: 8, height: 8)
                Text(label).font(SQFont.archivo(14, .bold))
            }
            .padding(.horizontal, SQSpace.md)
            .frame(height: 38)
            .background(on ? AnyShapeStyle(color) : AnyShapeStyle(SQColor.surface), in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                    .stroke(on ? Color.clear : SQColor.separator, lineWidth: 1.5)
            }
            .foregroundStyle(on ? Color.white : SQColor.label)
        }
        .buttonStyle(SQPressButtonStyle())
    }
}

// MARK: - Date picker sheet

struct ANFRDatePickerSheet: View {
    @ObservedObject var model: ANFRMapViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                SQSheetHandle()
                Text("Relevé ANFR").sqKicker()
                Text("Choisir une date")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .padding(.bottom, SQSpace.sm)

                dateRow(label: "Dernier relevé", value: model.currentSnapshotDate, isSelected: model.selectedDate == nil) {
                    Task { await model.selectDate(nil) }
                    dismiss()
                }
                ForEach(model.availableDates, id: \.self) { date in
                    dateRow(label: prettyDate(date), value: nil, isSelected: model.selectedDate == date) {
                        Task { await model.selectDate(date) }
                        dismiss()
                    }
                }
            }
            .padding(SQSpace.lg)
            .padding(.bottom, SQSpace.huge)
        }
        .signalQuestBackground()
    }

    private func dateRow(label: String, value: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: SQSpace.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? SQColor.brandRed : SQColor.labelTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(SQFont.archivo(15, .semibold))
                        .foregroundStyle(SQColor.label)
                    if let value, let pretty = ANFRDateParser.date(from: value)?.formatted(.dateTime.day().month(.wide).year()) {
                        Text(pretty)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, SQSpace.md)
            .padding(.horizontal, SQSpace.md)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
                    .stroke(isSelected ? SQColor.brandRed.opacity(0.5) : SQColor.separator, lineWidth: 1.5)
            }
        }
        .buttonStyle(SQPressButtonStyle())
    }

    private func prettyDate(_ raw: String) -> String {
        ANFRDateParser.date(from: raw)?.formatted(.dateTime.day().month(.wide).year()) ?? raw
    }
}

// MARK: - Simple flow layout for chips

/// Petit conteneur en flux (wrap) pour des puces de filtre.
struct FlexibleChips<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let content: (Data.Element) -> Content

    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    var body: some View {
        ANFRFlowLayout(spacing: SQSpace.sm) {
            ForEach(Array(data), id: \.self) { element in
                content(element)
            }
        }
    }
}

/// Layout en flux maison (wrap horizontal) — évite la dépendance à iOS 16 Layout
/// quirks et garde un comportement déterministe.
struct ANFRFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubview]] = [[]]
        var rowWidths: [CGFloat] = [0]
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let currentWidth = rowWidths[rows.count - 1]
            let needed = (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            if currentWidth + needed > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([subview])
                rowWidths.append(size.width)
            } else {
                rows[rows.count - 1].append(subview)
                rowWidths[rows.count - 1] = currentWidth + needed
            }
        }
        let rowHeight = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        let totalHeight = CGFloat(rows.count) * rowHeight + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: maxWidth == .infinity ? (rowWidths.max() ?? 0) : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        let rowHeight = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}
