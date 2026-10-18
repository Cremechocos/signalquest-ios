import SwiftUI
import MapKit

// MARK: - ViewModel

/// Un site avec l'opérateur et le type de modif de chaque antenne DÉJÀ résolus.
/// Ces deux accesseurs reparsent des chaînes brutes (`lowercased` + `contains`) :
/// les rappeler pour chaque antenne à chaque changement de filtre coûtait des
/// centaines de milliers d'analyses de texte sur le fil principal. Le tableau est
/// construit une fois par relevé (hors fil principal) puis seulement lu.
private struct ANFRIndexedSite: Sendable {
    let site: ANFRMapSite
    /// Parallèles à `site.antennas`.
    let operators: [ANFROperator?]
    let modTypes: [ANFRModType]

    static func build(_ sites: [ANFRMapSite]) -> [ANFRIndexedSite] {
        sites.map { site in
            ANFRIndexedSite(site: site, operators: site.antennas.map(\.operator), modTypes: site.antennas.map(\.modType))
        }
    }
}

private extension ANFRModType {
    /// Un bit par type, pour compter les types présents d'un site sans allocation.
    var presenceBit: Int {
        switch self {
        case .new: return 1
        case .activated: return 2
        case .deleted: return 4
        case .added: return 8
        }
    }
}

@MainActor
final class ANFRMapViewModel: ObservableObject {
    /// Lecture seule hors du modèle : toute écriture passe par `apply`, qui tient
    /// l'index de filtrage à jour.
    @Published private(set) var sites: [ANFRMapSite] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdate: String?
    /// Vrai une fois un premier chargement terminé : avant, une liste vide veut
    /// dire « pas encore de données », pas « aucun site pour ces filtres ».
    @Published private(set) var hasLoadedSnapshot = false

    @Published var operatorFilters: Set<ANFROperator> = Set(ANFROperator.allCases) { didSet { scheduleRecompute() } }
    @Published var selectedModTypes: Set<ANFRModType> = Set(ANFRModType.allCases) { didSet { scheduleRecompute() } }

    /// Dates d'archive d'un même relevé groupées par année, de la plus récente à la
    /// plus ancienne : la liste fait plusieurs centaines de lignes (hebdomadaires).
    struct DateSection: Identifiable {
        let year: String
        var dates: [String]
        var id: String { year }
    }

    @Published var availableDates: [String] = [] { didSet { dateSections = Self.sections(from: availableDates) } }
    @Published private(set) var dateSections: [DateSection] = []
    @Published var currentSnapshotDate: String?
    @Published var selectedDate: String?

    private let service: ANFRServicing
    private var index: [ANFRIndexedSite] = []
    private var recomputeTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    init(service: ANFRServicing) { self.service = service }

    /// Sites filtrés (opérateurs / types de modif actifs), MÉMOÏSÉS : recalculés
    /// seulement sur changement de sites/filtres, pas à chaque accès — le body de
    /// la carte les lit plusieurs fois par rendu (PERF-MAP-01). Le dataset ANFR
    /// national fait des dizaines de milliers de sites.
    @Published private(set) var filteredSites: [ANFRMapSite] = []
    /// Change à chaque recalcul : la carte compare ce nombre au lieu de hacher la
    /// liste pour savoir si elle doit se resynchroniser.
    @Published private(set) var filteredRevision = 0
    /// Sites concernés par chaque type de modif, pour les opérateurs retenus
    /// (indépendant du filtre de type, qui est ce qu'on veut choisir).
    @Published private(set) var modTypeCounts: [ANFRModType: Int] = [:]

    private func apply(sites newSites: [ANFRMapSite], index newIndex: [ANFRIndexedSite]) {
        sites = newSites
        index = newIndex
        recomputeNow()
    }

    /// Plusieurs bascules de puces d'affilée (ou « Réinitialiser », qui change deux
    /// jeux de filtres) ne déclenchent qu'un recalcul et qu'une resynchronisation
    /// des repères de la carte.
    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.recomputeNow()
        }
    }

    private func recomputeNow() {
        recomputeTask?.cancel()
        recomputeTask = nil
        let operators = operatorFilters
        let modTypes = selectedModTypes
        var result: [ANFRMapSite] = []
        result.reserveCapacity(index.count)
        var counts: [ANFRModType: Int] = [:]
        // Au moins une antenne dont l'opérateur et le type de modif passent les
        // filtres actifs. Le repère ne garde que ces antennes : un site Orange +
        // Free filtré sur Free s'affichait en Orange. La fiche relit le site entier.
        for entry in index {
            let antennas = entry.site.antennas
            var keptCount = 0
            var typesPresent = 0
            for i in antennas.indices {
                guard let op = entry.operators[i], operators.contains(op) else { continue }
                typesPresent |= entry.modTypes[i].presenceBit
                if modTypes.contains(entry.modTypes[i]) { keptCount += 1 }
            }
            if typesPresent != 0 {
                for type in ANFRModType.allCases where typesPresent & type.presenceBit != 0 { counts[type, default: 0] += 1 }
            }
            guard keptCount > 0 else { continue }
            if keptCount == antennas.count {
                result.append(entry.site)
                continue
            }
            var kept: [ANFRMapAntenna] = []
            kept.reserveCapacity(keptCount)
            for i in antennas.indices {
                if let op = entry.operators[i], operators.contains(op), modTypes.contains(entry.modTypes[i]) { kept.append(antennas[i]) }
            }
            let site = entry.site
            result.append(ANFRMapSite(supId: site.supId, latitude: site.latitude, longitude: site.longitude,
                                      city: site.city, antennas: kept))
        }
        filteredSites = result
        modTypeCounts = counts
        filteredRevision &+= 1
    }

    private static func sections(from dates: [String]) -> [DateSection] {
        var result: [DateSection] = []
        for date in dates.sorted(by: >) {
            let year = String(date.prefix(4))
            if let last = result.last, last.year == year {
                result[result.count - 1].dates.append(date)
            } else {
                result.append(DateSection(year: year, dates: [date]))
            }
        }
        return result
    }

    func load() async {
        #if DEBUG
        if AppEnvironment.usesDemoData {
            let demo = ANFRDemoData.mapSnapshot.sites
            apply(sites: demo, index: ANFRIndexedSite.build(demo))
            lastUpdate = ANFRDemoData.mapSnapshot.lastUpdate
            availableDates = ANFRDemoData.archiveDates.dates
            currentSnapshotDate = ANFRDemoData.archiveDates.current
            errorMessage = nil
            hasLoadedSnapshot = true
            return
        }
        #endif
        guard sites.isEmpty else { return }
        // Les dates d'archive (une petite réponse) n'attendent plus le relevé
        // national, bien plus lourd : le sélecteur est utilisable tout de suite.
        let datesTask = Task { await loadArchiveDates() }
        await loadSnapshot()
        await datesTask.value
    }

    func loadSnapshot() async {
        #if DEBUG
        if AppEnvironment.usesDemoData {
            let demo = ANFRDemoData.mapSnapshot.sites
            apply(sites: demo, index: ANFRIndexedSite.build(demo))
            lastUpdate = ANFRDemoData.mapSnapshot.lastUpdate
            hasLoadedSnapshot = true
            return
        }
        #endif
        // Une réponse arrivée après le choix d'une autre date est ignorée : elle
        // aurait affiché les sites de la date A sous le libellé de la date B.
        let date = selectedDate
        isLoading = true
        errorMessage = nil
        defer { if date == selectedDate { isLoading = false } }
        do {
            let snapshot = try await service.mapSnapshot(date: date)
            guard date == selectedDate else { return }
            let loaded = snapshot.sites
            // L'index se construit hors du fil principal : le pill de chargement
            // reste animé pendant l'analyse des antennes.
            let built = await Task.detached(priority: .userInitiated) { ANFRIndexedSite.build(loaded) }.value
            guard date == selectedDate else { return }
            apply(sites: loaded, index: built)
            lastUpdate = snapshot.lastUpdate
            hasLoadedSnapshot = true
        } catch {
            if !error.isCancellation, date == selectedDate { errorMessage = error.userFacingMessage }
        }
    }

    /// Dates d'archive : appelée aussi à l'ouverture du sélecteur quand la liste
    /// est restée vide (réponse manquée).
    func loadArchiveDates() async {
        guard let meta = try? await service.archiveDates() else { return }
        availableDates = meta.dates
        currentSnapshotDate = meta.current
    }

    /// « Réessayer » : relit le relevé ET les dates d'archive, que le premier
    /// chargement a pu manquer.
    func reload() async {
        await loadSnapshot()
        if availableDates.isEmpty { await loadArchiveDates() }
    }

    func selectDate(_ date: String?) async {
        guard date != selectedDate else { return }
        selectedDate = date
        apply(sites: [], index: [])
        hasLoadedSnapshot = false
        // Les choix successifs de dates annulent la requête précédente au lieu de
        // laisser télécharger plusieurs relevés nationaux pour n'en garder qu'un.
        snapshotTask?.cancel()
        let task = Task { await loadSnapshot() }
        snapshotTask = task
        await task.value
    }

    func toggleOperator(_ op: ANFROperator) {
        if operatorFilters.contains(op) {
            let next = operatorFilters.subtracting([op])
            operatorFilters = next.isEmpty ? [op] : next
        } else {
            operatorFilters.insert(op)
        }
    }

    func toggleModType(_ type: ANFRModType) {
        if selectedModTypes.contains(type) {
            let next = selectedModTypes.subtracting([type])
            selectedModTypes = next.isEmpty ? [type] : next
        } else {
            selectedModTypes.insert(type)
        }
    }

    func resetFilters() {
        operatorFilters = Set(ANFROperator.allCases)
        selectedModTypes = Set(ANFRModType.allCases)
    }

    var hasActiveFilters: Bool {
        operatorFilters.count != ANFROperator.allCases.count || selectedModTypes.count != ANFRModType.allCases.count
    }

    var dateLabel: String {
        guard let raw = selectedDate ?? currentSnapshotDate,
              let date = ANFRDateParser.date(from: raw) else { return lastUpdate ?? String(localized: "Dernier relevé") }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

// MARK: - Screen

struct ANFRMapView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: ANFRMapViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                // Les contrôles flottants ont des hauteurs fixes : à la taille AX
                // maximale leurs libellés se chevauchent. Les fiches gardent le
                // Dynamic Type demandé par le système.
                .dynamicTypeSize(dynamicTypeSize.isAccessibilitySize ? .xxxLarge : dynamicTypeSize)
        }
        .navigationTitle("Carte ANFR")
        .toolbarTitleInlineCompat()
        .sheet(item: $selectedSite) { site in
            ANFRSiteDetailSheet(site: site, service: services.anfr, snapshotDate: model.selectedDate ?? model.currentSnapshotDate)
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

    private var mapLayer: some View {
        ANFRMapKitView(
            sites: model.filteredSites,
            revision: model.filteredRevision,
            onSelectSite: { site in
                Haptics.light()
                selectedSite = model.sites.first { $0.supId == site.supId } ?? site
            }
        )
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Controls overlay

    private var controlsLayer: some View {
        VStack(spacing: SQSpace.sm2) {
            topBar
            operatorStrip
            Spacer()
            if model.isLoading {
                loadingPill
                    .padding(.bottom, SQSpace.lg)
            } else if model.hasLoadedSnapshot, model.filteredSites.isEmpty, model.errorMessage == nil {
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SQColor.brandRed)
                        .frame(width: 28, height: 28)
                        .background(SQColor.accentSoft, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Relevé")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                        Text(model.dateLabel)
                            .font(SQFont.body(14, .semibold))
                            .foregroundStyle(SQColor.label)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, SQSpace.sm2)
                .frame(height: 48)
                .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityHint("Choisir une date")

            Spacer()

            // Count badge
            HStack(spacing: SQSpace.xs2) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                // Séparateur de milliers : « 61 234 » se lit, « 61234 » pas.
                Text(model.filteredSites.count.formatted(.number.grouping(.automatic)))
                    .font(SQFont.display(15, .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(SQColor.onAccent)
            .padding(.horizontal, SQSpace.md - 1)
            .frame(height: 48)
            .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(model.filteredSites.count) site visible"))

            // Filter button
            Button {
                Haptics.light()
                showFilters = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .foregroundStyle(SQColor.label)
                    if activeFilterCount > 0 {
                        Text("\(activeFilterCount)")
                            .font(SQType.micro)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(SQColor.brandRed, in: Circle())
                            .foregroundStyle(SQColor.onAccent)
                            .offset(x: 5, y: -5)
                    }
                }
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityLabel("Filtres de la carte")
            .accessibilityValue(activeFilterCount > 0 ? Text("Filtres actifs : \(activeFilterCount)") : Text(verbatim: ""))
        }
        .padding(SQSpace.xs + 1)
        .sqCardBackground()
    }

    private var operatorStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SQSpace.sm - 1) {
                ForEach(ANFROperator.allCases) { op in
                    let on = model.operatorFilters.contains(op)
                    SQChip(
                        label: op.label, isSelected: on, dot: op.color, selectedFill: op.color,
                        selectedInk: SQBrand.operatorBadgeForeground(op.label),
                        spokenLabel: "Filtre \(op.label)",
                        spokenValue: on ? "activé" : "désactivé"
                    ) {
                        withAnimation(reduceMotion ? nil : SQMotion.fast) { model.toggleOperator(op) }
                    }
                }
            }
            .padding(.horizontal, SQSpace.xs)
        }
        .frame(minHeight: 44)
    }

    private var loadingPill: some View {
        HStack(spacing: SQSpace.sm) {
            SQSpinner().tint(SQColor.brandRed)
            Text("Chargement des sites ANFR…")
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(SQColor.label)
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm + 1)
        .sqSurface(SQColor.surface, in: Capsule(style: .continuous))
        .sqShadowCard()
    }

    /// Liste vide : soit les filtres excluent tout (et on les remet en un geste),
    /// soit le relevé lui-même ne contient aucun site.
    private var emptyPill: some View {
        VStack(spacing: SQSpace.xs) {
            if model.hasActiveFilters {
                Label("Aucun site pour ces filtres", systemImage: "magnifyingglass")
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    Haptics.light()
                    model.resetFilters()
                } label: {
                    Text("Réinitialiser les filtres")
                        .font(SQFont.body(13, .semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Label("Aucun site pour ce relevé", systemImage: "magnifyingglass")
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm + 1)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .sqShadowCard()
    }

    private func errorPill(_ message: String) -> some View {
        VStack(spacing: SQSpace.sm) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(SQFont.body(13, .semibold))
                .foregroundStyle(SQColor.dangerInk)
                .lineLimit(3)
                .multilineTextAlignment(.center)
            Button {
                Task { await model.reload() }
            } label: {
                Label("Réessayer", systemImage: "arrow.clockwise")
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.accentInk)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm + 1)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .frame(maxWidth: 320)
        .sqShadowCard()
    }

    private var activeFilterCount: Int {
        var count = 0
        if model.operatorFilters.count != ANFROperator.allCases.count { count += 1 }
        if model.selectedModTypes.count != ANFRModType.allCases.count { count += 1 }
        return count
    }
}

// MARK: - Sheet header

/// Titre d'une feuille de la carte et sa sortie : sans bouton, seule la poignée
/// (invisible pour VoiceOver et Contrôle de sélection) fermait la feuille.
private struct ANFRSheetHeader: View {
    let title: LocalizedStringKey
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SQSpace.md) {
            Text(title)
                .font(SQType.title)
                .foregroundStyle(SQColor.label)
                .sqHeader()
            Spacer(minLength: SQSpace.md)
            Button("Terminé", action: onClose)
                .font(SQType.button)
                .foregroundStyle(SQColor.accentInk)
                .frame(minWidth: 44, minHeight: 44)
        }
    }
}

// MARK: - Filter sheet

struct ANFRMapFilterSheet: View {
    @ObservedObject var model: ANFRMapViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                ANFRSheetHeader(title: "Filtres") { dismiss() }

                section(title: "Opérateurs") {
                    FlexibleChips(ANFROperator.allCases) { op in
                        chip(label: op.label, color: op.color, on: model.operatorFilters.contains(op)) {
                            model.toggleOperator(op)
                        }
                    }
                }

                section(title: "Type de modification") {
                    FlexibleChips(ANFRModType.allCases) { type in
                        modTypeChip(type)
                    }
                    // Légende de la carte : le symbole des puces est celui du repère.
                    Text("Sur la carte, un repère prend la couleur de l’opérateur dominant du site ; son symbole est le type de modification le plus marquant.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.hasLoadedSnapshot {
                        Text("Les nombres comptent les sites concernés, pour les opérateurs choisis.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
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
            Text(LocalizedStringKey(title))
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .sqHeader()
            content()
        }
    }

    private func chip(label: String, color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        SQChip(
            label: label, isSelected: on, dot: color, selectedFill: color,
            selectedInk: SQBrand.operatorBadgeForeground(for: color, colorScheme: colorScheme), action: action
        )
    }

    /// Puce d'un type de modification : le symbole du repère sur la carte et, une
    /// fois le relevé chargé, le nombre de sites concernés.
    private func modTypeChip(_ type: ANFRModType) -> some View {
        let label = model.hasLoadedSnapshot
            ? "\(type.label) · \((model.modTypeCounts[type] ?? 0).formatted(.number.grouping(.automatic)))"
            : type.label
        return SQChip(
            label: label, systemImage: type.glyph, isSelected: model.selectedModTypes.contains(type),
            selectedFill: type.color,
            selectedInk: SQBrand.operatorBadgeForeground(for: type.color, colorScheme: colorScheme)
        ) {
            model.toggleModType(type)
        }
    }
}

// MARK: - Date picker sheet

struct ANFRDatePickerSheet: View {
    @ObservedObject var model: ANFRMapViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Paresseux : plusieurs centaines de relevés hebdomadaires, chacun
                // avec ombre, n'ont pas à être tous construits à l'ouverture.
                LazyVStack(alignment: .leading, spacing: SQSpace.md) {
                    ANFRSheetHeader(title: "Choisir une date") { dismiss() }
                    Text("Relevé ANFR")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                    Text("L’ANFR publie un relevé par semaine. La carte montre les antennes à la date choisie et marque celles qui ont changé.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, SQSpace.sm)

                    dateRow(label: "Dernier relevé", value: model.currentSnapshotDate, isSelected: model.selectedDate == nil) {
                        Task { await model.selectDate(nil) }
                        dismiss()
                    }
                    .id("latest")

                    if model.dateSections.isEmpty {
                        Text("Aucune autre date disponible pour le moment.")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                    ForEach(model.dateSections) { section in
                        Text(section.year)
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                            .sqHeader()
                            .padding(.top, SQSpace.sm)
                        ForEach(section.dates, id: \.self) { date in
                            dateRow(label: prettyDate(date), value: nil, isSelected: model.selectedDate == date) {
                                Task { await model.selectDate(date) }
                                dismiss()
                            }
                            .id(date)
                        }
                    }
                }
                .padding(SQSpace.lg)
                .padding(.bottom, SQSpace.huge)
            }
            .signalQuestBackground()
            // La date en cours se retrouve au milieu de la liste, pas en bas d'un défilement.
            .onAppear {
                if let selected = model.selectedDate { proxy.scrollTo(selected, anchor: .center) }
            }
        }
        // Liste vide à l'ouverture : la réponse des dates a pu être manquée.
        .task { if model.availableDates.isEmpty { await model.loadArchiveDates() } }
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
                    Text(LocalizedStringKey(label))
                        .font(SQFont.body(15, .semibold))
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
            .background(
                isSelected ? AnyShapeStyle(SQColor.accentSoft) : AnyShapeStyle(SQColor.surface),
                in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous)
            )
            .sqShadowSoft()
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

// MARK: - Carte ANFR MapKit (migration moteur unique)

/// Annotation MapKit d'un site ANFR (style résolu : couleur opérateur + glyphe modif).
final class ANFRSiteAnnotationMK: NSObject, MKAnnotation {
    let site: ANFRMapSite
    /// Résolu à la demande : MapKit ne demande une vue qu'aux repères affichés hors
    /// amas (quelques centaines), alors qu'on crée des dizaines de milliers
    /// d'annotations. Le calculer dans `init` analysait toutes les antennes du pays.
    lazy var style = ANFRMarkerStyle(site: site)
    var coordinate: CLLocationCoordinate2D { site.coordinate }
    var title: String? { site.city.isEmpty ? String(localized: "Support \(site.supId)") : site.city }
    /// Lu par VoiceOver : sans lui un repère ne disait que sa commune, pas ce qui a changé.
    var subtitle: String? {
        "\(style.operators.map(\.label).joined(separator: ", ")) · \(style.modType.label)"
    }
    init(site: ANFRMapSite) {
        self.site = site
    }
}

/// Carte ANFR nationale rendue avec MapKit (Apple Plan natif). Marqueurs colorés par
/// opérateur dominant + glyphe de type de modif ; clustering natif MapKit.
struct ANFRMapKitView: UIViewRepresentable {
    let sites: [ANFRMapSite]
    /// Change quand `sites` change (`ANFRMapViewModel.filteredRevision`) : évite de
    /// parcourir les dizaines de milliers de sites à chaque rendu de l'écran.
    let revision: Int
    let onSelectSite: (ANFRMapSite) -> Void

    @AppStorage(MapBackdrop.storageKey) private var backdropRaw = MapBackdrop.applePlan.rawValue
    private var backdrop: MapBackdrop { MapBackdrop.resolve(backdropRaw) }

    func makeCoordinator() -> Coordinator { Coordinator(onSelectSite: onSelectSite) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        context.coordinator.applyBackdrop(backdrop, on: map)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "anfr-site")
        // France métropolitaine en entier à l'ouverture.
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 46.7, longitude: 2.4),
                                         span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.applyBackdrop(backdrop, on: map)
        context.coordinator.sync(sites, revision: revision, on: map)
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        private let onSelectSite: (ANFRMapSite) -> Void
        /// Annotations posées sur la carte, par support.
        private var annotations: [String: ANFRSiteAnnotationMK] = [:]
        private var lastRevision = -1
        private var appliedBackdrop: MapBackdrop?
        private var tileOverlay: MKTileOverlay?
        /// Couleur du repère et encre du symbole, par opérateur : leur résolution
        /// analyse le nom de l'opérateur, trop pour chaque repère affiché.
        private var paints: [ANFROperator: (tint: UIColor, ink: UIColor)] = [:]

        init(onSelectSite: @escaping (ANFRMapSite) -> Void) {
            self.onSelectSite = onSelectSite
        }

        func applyBackdrop(_ backdrop: MapBackdrop, on map: MKMapView) {
            guard backdrop != appliedBackdrop else { return }
            appliedBackdrop = backdrop
            if let old = tileOverlay { map.removeOverlay(old); tileOverlay = nil }
            map.showTileAttribution(backdrop.tileAttribution)
            switch backdrop.mapKitKind {
            case .applePlan:
                let c = MKStandardMapConfiguration(elevationStyle: .flat); c.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = c
            case .imagery:
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            case .raster(let template, let maxZoom):
                let c = MKStandardMapConfiguration(elevationStyle: .flat); c.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = c
                let o = MKTileOverlay(urlTemplate: template); o.canReplaceMapContent = true; o.maximumZ = maxZoom
                map.insertOverlay(o, at: 0, level: .aboveLabels); tileOverlay = o
            }
        }

        /// Met la carte au niveau de `sites` en ne touchant QUE les repères qui
        /// changent. Vider puis reposer tous les repères à chaque bascule de filtre
        /// obligeait MapKit à reconstruire ses amas pour tout le pays.
        func sync(_ sites: [ANFRMapSite], revision: Int, on map: MKMapView) {
            guard revision != lastRevision else { return }
            lastRevision = revision
            var next: [String: ANFRSiteAnnotationMK] = [:]
            next.reserveCapacity(sites.count)
            var added: [ANFRSiteAnnotationMK] = []
            for site in sites where next[site.supId] == nil {
                // Même contenu (antennes retenues, type de modif) : le repère reste tel quel.
                if let existing = annotations[site.supId], Self.sameContent(existing.site, site) {
                    next[site.supId] = existing
                } else {
                    let annotation = ANFRSiteAnnotationMK(site: site)
                    next[site.supId] = annotation
                    added.append(annotation)
                }
            }
            var removed: [ANFRSiteAnnotationMK] = []
            for (supId, annotation) in annotations where next[supId] !== annotation { removed.append(annotation) }
            annotations = next
            if !removed.isEmpty { map.removeAnnotations(removed) }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        /// Ce qui détermine l'aspect d'un repère : position, commune et, par antenne,
        /// son identité et son type de modif.
        private static func sameContent(_ a: ANFRMapSite, _ b: ANFRMapSite) -> Bool {
            a.antennas.count == b.antennas.count
                && a.latitude == b.latitude && a.longitude == b.longitude && a.city == b.city
                && zip(a.antennas, b.antennas).allSatisfy { $0.id == $1.id && $0.modTypeRaw == $1.modTypeRaw }
        }

        private func paint(for op: ANFROperator) -> (tint: UIColor, ink: UIColor) {
            if let cached = paints[op] { return cached }
            let made = (tint: UIColor(op.color), ink: UIColor(SQBrand.operatorBadgeForeground(op.label)))
            paints[op] = made
            return made
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let site = annotation as? ANFRSiteAnnotationMK else { return nil } // clusters → vue MapKit par défaut
            let v = map.dequeueReusableAnnotationView(withIdentifier: "anfr-site", for: annotation) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "anfr-site")
            let colors = paint(for: site.style.dominantOperator)
            v.markerTintColor = colors.tint
            // Orange et Bouygues demandent un symbole noir : le blanc par défaut n'y tient pas le contraste.
            v.glyphTintColor = colors.ink
            v.glyphImage = UIImage(systemName: site.style.modType.glyph)
            v.clusteringIdentifier = "anfr"
            v.displayPriority = .defaultLow
            v.canShowCallout = false
            return v
        }

        func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                let region = MKCoordinateRegion(
                    center: cluster.coordinate,
                    span: MKCoordinateSpan(
                        latitudeDelta: max(map.region.span.latitudeDelta / 3, 0.01),
                        longitudeDelta: max(map.region.span.longitudeDelta / 3, 0.01)
                    )
                )
                map.setRegion(region, animated: true)
            } else if let site = view.annotation as? ANFRSiteAnnotationMK {
                onSelectSite(site.site)
            }
            map.deselectAnnotation(view.annotation, animated: false)
        }
    }
}
