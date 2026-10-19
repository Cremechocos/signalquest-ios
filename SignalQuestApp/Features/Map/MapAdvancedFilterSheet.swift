import SwiftUI
import MapKit

/// Écran ANFR à ouvrir une fois la feuille Carte fermée.
enum MapANFRDestination {
    case map
    case stats
    /// Comparatif d'opérateurs autour du centre de la carte (équivalent de l'appui long).
    case zoneCompare
}

extension MapFilterSelection {
    /// Réglages fins qui s'écartent du défaut : le chiffre du bouton Filtres.
    /// Pays, opérateur et couches n'en font pas partie : la pastille d'état les montre.
    var activeRefinementCount: Int {
        var count = 0
        if !technologies.isEmpty { count += 1 }
        if !bands.isEmpty { count += 1 }
        if !sharing.isEmpty { count += 1 }
        if speedtestDays != 0 { count += 1 }
        if coverageDays != 0 { count += 1 }
        if azimuthStyle != .lines { count += 1 }
        if !includeObserved { count += 1 }
        if layers.contains(.planned), plannedStatuses != Set(PlannedActivationStatus.allCases) { count += 1 }
        return count
    }
}

/// Feuille Filtres : seulement les réglages des couches affichées. Pays,
/// opérateur et couches se choisissent dans la feuille Carte.
struct MapAdvancedFilterSheet: View {
    @State private var baseline: MapFilterSelection
    @State private var draft: MapFilterSelection
    @State private var applyError: String?
    private let dromRegion: DromRegion?
    let allMarkets: [MarketRegistryEntry]
    let onApply: (MapFilterSelection) -> Bool
    @Environment(\.dismiss) private var dismiss

    init(selection: MapFilterSelection, allMarkets: [MarketRegistryEntry],
         dromRegion: DromRegion?, onApply: @escaping (MapFilterSelection) -> Bool) {
        _baseline = State(initialValue: selection)
        _draft = State(initialValue: selection)
        self.dromRegion = dromRegion
        self.allMarkets = allMarkets
        self.onApply = onApply
    }

    private var selectedEntry: MarketRegistryEntry? {
        allMarkets.first { $0.code.caseInsensitiveCompare(draft.market) == .orderedSame
            || $0.marketCode.caseInsensitiveCompare(draft.market) == .orderedSame }
    }
    private var catalogMarket: String { selectedEntry?.marketCode ?? draft.market }
    private var communityAvailable: Bool { selectedEntry?.capabilities.communityLayers == true }
    private var plannedAvailable: Bool { selectedEntry?.capabilities.previsionnel == true }

    /// Couches qui ont des réglages ici.
    private static let filterableLayers: Set<MapDisplayItem.Kind> = [.antenna, .coverage, .speedtest, .planned, .communitySite]
    private var shownFilterableLayers: [MapDisplayItem.Kind] {
        MapLayersSheet.layerOrder.filter { draft.layers.contains($0) && Self.filterableLayers.contains($0) }
    }
    private var sharingOptions: [MapFilterCatalog.SharingOption] { MapFilterCatalog.sharing(forMarket: catalogMarket) }
    private var showsRadio: Bool { !shownFilterableLayers.isEmpty }
    private var showsSharing: Bool { draft.layers.contains(.antenna) && !sharingOptions.isEmpty }
    private var showsSectors: Bool { draft.layers.contains(.antenna) }
    private var showsPlanned: Bool { plannedAvailable && draft.layers.contains(.planned) }
    private var showsObserved: Bool {
        communityAvailable && (draft.layers.contains(.antenna) || draft.layers.contains(.communitySite))
    }

    private var title: String {
        guard shownFilterableLayers.count == 1, let only = shownFilterableLayers.first else {
            return String(localized: "Filtres")
        }
        let layer = MapLayersSheet.layerTitle(only, communityOnly: selectedEntry?.isCommunityOnly == true)
        return String(localized: "Filtres · \(layer)")
    }

    private var subtitle: String {
        let count = draft.activeRefinementCount
        return count == 0 ? String(localized: "Aucun filtre actif") : String(localized: "\(count) filtres actifs")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: SQSpace.xl) {
                        MapSheetHeader(title: title, subtitle: subtitle, closeIdentifier: "map.filters.cancel") { dismiss() }
                        if !showsRadio {
                            SQNotice(message: "Les couches affichées n’ont pas de filtre. Choisis-les avec le bouton Carte.")
                        }
                        if showsRadio { technologySection }
                        if showsRadio || showsSharing { refineSection }
                        if showsSectors { sectorsSection }
                        if draft.layers.contains(.speedtest) || draft.layers.contains(.coverage) { periodSection }
                        if showsPlanned { plannedSection }
                        if showsObserved { observedSection }
                    }
                    .padding(.horizontal, SQSpace.lg)
                    .padding(.top, SQSpace.lg)
                    .padding(.bottom, SQSpace.xl)
                }
                .accessibilityIdentifier("map.filters.content")
                footer
            }
            .background(SQColor.surface)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: Sections

    /// La plus récente en tête.
    private var technologies: [MapFilterCatalog.TechOption] {
        MapFilterCatalog.technologies(forMarket: catalogMarket).reversed()
    }

    private var technologySection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            HStack {
                Text("Technologies").sqKicker().accessibilityAddTraits(.isHeader)
                Spacer(minLength: SQSpace.sm)
                if !draft.technologies.isEmpty {
                    Button {
                        Haptics.selection()
                        draft.technologies.removeAll()
                    } label: {
                        Text("Tout").font(SQType.caption.weight(.semibold)).foregroundStyle(SQColor.ink2)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Toutes les technologies")
                    .accessibilityIdentifier("map.filters.technology.all")
                }
            }
            MapRowsTile {
                ForEach(Array(technologies.enumerated()), id: \.element.value) { index, technology in
                    MapCheckRow(isOn: draft.technologies.isEmpty || draft.technologies.contains(technology.value),
                                identifier: "map.filters.technology.\(technology.value)") {
                        toggleTechnology(technology.value)
                    } label: {
                        MapTechTag(technology: technology.value, label: technology.label)
                            .accessibilityHidden(true)
                        Text(technology.label).font(SQType.callout(.semibold)).foregroundStyle(SQColor.label)
                    }
                    .mapRowDivider(index > 0)
                }
            }
        }
    }

    private var refineSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Affiner").sqKicker().accessibilityAddTraits(.isHeader)
            MapRowsTile {
                if showsRadio {
                    NavigationLink {
                        MapBandsPage(draft: $draft, catalogMarket: catalogMarket,
                                     marketName: selectedEntry.map(MapMarketNaming.name) ?? catalogMarket)
                    } label: {
                        refineRow(String(localized: "Bandes"), value: bandsSummary, active: !draft.bands.isEmpty)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("map.filters.bands")
                }
                if showsSharing {
                    NavigationLink {
                        MapSharingPage(draft: $draft, options: sharingOptions)
                    } label: {
                        refineRow(String(localized: "Partage"), value: sharingSummary, active: !draft.sharing.isEmpty)
                    }
                    .buttonStyle(.plain)
                    .mapRowDivider(showsRadio)
                    .accessibilityIdentifier("map.filters.sharing")
                }
            }
        }
    }

    private var sectorsSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Secteurs sur la carte").sqKicker().accessibilityAddTraits(.isHeader)
            MapSegmented(selection: $draft.azimuthStyle,
                         options: AzimuthStyle.allCases.map { ($0, $0.label) },
                         identifier: "map.filters.azimuth")
        }
    }

    private var periodSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Période").sqKicker().accessibilityAddTraits(.isHeader)
            if draft.layers.contains(.speedtest) {
                periodPicker(String(localized: "Débits"), selection: $draft.speedtestDays, identifier: "map.filters.speedtestDays")
            }
            if draft.layers.contains(.coverage) {
                periodPicker(String(localized: "Couverture"), selection: $draft.coverageDays, identifier: "map.filters.coverageDays")
            }
        }
    }

    private var plannedSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Statut prévisionnel").sqKicker().accessibilityAddTraits(.isHeader)
            MapRowsTile {
                ForEach(Array(PlannedActivationStatus.allCases.enumerated()), id: \.element) { index, status in
                    MapCheckRow(isOn: draft.plannedStatuses.contains(status),
                                identifier: "map.filters.planned.\(status.rawValue)") {
                        toggle(status, in: &draft.plannedStatuses)
                    } label: {
                        Image(systemName: MapExplorerView.plannedStatusGlyph(status))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(MapExplorerView.plannedStatusLabel(status)))
                            .font(SQType.callout(.semibold)).foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .mapRowDivider(index > 0)
                }
            }
        }
    }

    private var observedSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Cellules observées").sqKicker().accessibilityAddTraits(.isHeader)
            Toggle("Inclure les cellules non consolidées", isOn: $draft.includeObserved)
                .font(SQType.callout(.semibold))
                .foregroundStyle(SQColor.label)
                .tint(SQColor.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("map.filters.includeObserved")
            Text("Affiche aussi les cellules captées, en plus des sites probables consolidés")
                .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(spacing: SQSpace.sm) {
            if let applyError {
                Text(applyError).font(SQType.caption).foregroundStyle(SQColor.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: SQSpace.sm2) {
                Button { resetDraft() } label: {
                    Text("Réinitialiser")
                        .font(SQType.button).foregroundStyle(SQColor.label)
                        .padding(.horizontal, SQSpace.xs2)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(draft.activeRefinementCount == 0)
                .accessibilityIdentifier("map.filters.reset")
                GradientButton("Afficher les résultats") {
                    if onApply(draft) { dismiss() }
                    else { applyError = String(localized: "Les pays disponibles ont changé. Vérifie ton choix.") }
                }
                .disabled(selectedEntry == nil)
                .accessibilityIdentifier("map.filters.done")
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.md)
        .padding(.bottom, SQSpace.sm)
        .background(SQColor.surface)
        .overlay(alignment: .top) { Rectangle().fill(SQColor.separator).frame(height: 1) }
    }

    // MARK: Aides

    private var bandsSummary: String {
        guard !draft.bands.isEmpty else { return String(localized: "Toutes") }
        return MapBandsPage.sorted(MapFilterCatalog.bands(forMarket: catalogMarket))
            .filter { draft.bands.contains($0.band) }
            .map { MapBandsPage.frequency(of: $0) }
            .joined(separator: ", ")
    }

    private var sharingSummary: String {
        guard !draft.sharing.isEmpty else { return String(localized: "Tous") }
        return sharingOptions.filter { draft.sharing.contains($0.value) }.map(\.label).joined(separator: ", ")
    }

    private func refineRow(_ title: String, value: String, active: Bool) -> some View {
        HStack(spacing: SQSpace.sm2) {
            Text(LocalizedStringKey(title)).font(SQType.callout(.semibold)).foregroundStyle(SQColor.label)
            Spacer(minLength: SQSpace.sm)
            Text(value)
                .font(SQType.caption.weight(active ? .bold : .semibold))
                .foregroundStyle(active ? SQColor.accentInk : SQColor.labelSecondary)
                .multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 46)
        .contentShape(Rectangle())
    }

    private func periodPicker(_ title: String, selection: Binding<Int>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            Text(LocalizedStringKey(title)).font(SQType.subhead).foregroundStyle(SQColor.labelSecondary)
            MapSegmented(selection: selection,
                         options: [0, 7, 30, 90].map { ($0, periodLabel($0)) },
                         identifier: identifier)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(LocalizedStringKey(title)))
        }
    }

    private func periodLabel(_ days: Int) -> String {
        switch days {
        case 7: return String(localized: "7 j")
        case 30: return String(localized: "30 j")
        case 90: return String(localized: "90 j")
        default: return String(localized: "Tout")
        }
    }

    /// Aucune case cochée vaut « toutes » : on ne décoche donc pas la dernière.
    private func toggleTechnology(_ value: String) {
        let all = Set(technologies.map(\.value))
        var current = draft.technologies.isEmpty ? all : draft.technologies
        if current.contains(value) {
            guard current.count > 1 else { return }
            current.remove(value)
        } else {
            current.insert(value)
        }
        draft.technologies = current == all ? [] : current
    }

    /// Pays, opérateur et couches ne bougent pas : ils ne se règlent pas ici.
    private func resetDraft() {
        applyError = nil
        var next = MapFilterSelection.defaults(market: draft.market, operatorName: draft.operatorName)
        next.layers = draft.layers
        next.photosFriendsOnly = draft.photosFriendsOnly
        if let selectedEntry { next = next.normalized(for: selectedEntry, dromRegion: dromRegion) }
        draft = next
    }

    private func toggle<Value: Hashable>(_ value: Value, in set: inout Set<Value>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}

// MARK: - Sous-pages

/// Bandes, en lignes à cocher, et la règle de croisement.
struct MapBandsPage: View {
    @Binding var draft: MapFilterSelection
    let catalogMarket: String
    let marketName: String
    @Environment(\.dismiss) private var dismiss

    private var bands: [MapFilterCatalog.BandOption] { Self.sorted(MapFilterCatalog.bands(forMarket: catalogMarket)) }

    /// Du plus bas au plus haut en fréquence, comme on les cite.
    static func sorted(_ bands: [MapFilterCatalog.BandOption]) -> [MapFilterCatalog.BandOption] {
        bands.sorted {
            (Int(frequency(of: $0)) ?? .max, $0.band) < (Int(frequency(of: $1)) ?? .max, $1.band)
        }
    }

    /// « B3 (1800) » → « 1800 » ; un libellé sans fréquence reste entier.
    static func frequency(of band: MapFilterCatalog.BandOption) -> String {
        guard let open = band.label.firstIndex(of: "("), let close = band.label.lastIndex(of: ")"), open < close else {
            return band.label
        }
        return String(band.label[band.label.index(after: open)..<close])
    }

    private static func designation(of band: MapFilterCatalog.BandOption) -> String {
        guard let open = band.label.firstIndex(of: "(") else { return "" }
        return band.label[..<open].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: " · ")
    }

    private var subtitle: String {
        draft.bands.isEmpty ? String(localized: "Toutes les bandes") : String(localized: "\(draft.bands.count) bandes choisies")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.xl) {
                    MapSheetPageHeader(title: String(localized: "Bandes"), subtitle: subtitle,
                                       backIdentifier: "map.filters.bands.back") { dismiss() }
                    VStack(alignment: .leading, spacing: SQSpace.sm) {
                        Text(marketName).sqKicker().accessibilityAddTraits(.isHeader)
                        MapRowsTile {
                            ForEach(Array(bands.enumerated()), id: \.element.band) { index, band in
                                MapCheckRow(isOn: draft.bands.contains(band.band),
                                            identifier: "map.filters.band.\(band.band)") {
                                    if draft.bands.contains(band.band) { draft.bands.remove(band.band) }
                                    else { draft.bands.insert(band.band) }
                                } label: {
                                    Text(Self.frequency(of: band))
                                        .font(SQType.callout(.bold)).monospacedDigit()
                                        .foregroundStyle(SQColor.label)
                                        .frame(minWidth: 46, alignment: .leading)
                                    let designation = Self.designation(of: band)
                                    Text(designation.isEmpty ? String(localized: "MHz") : String(localized: "MHz · \(designation)"))
                                        .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                                }
                                .mapRowDivider(index > 0)
                            }
                        }
                    }
                    if !draft.bands.isEmpty {
                        VStack(alignment: .leading, spacing: SQSpace.sm) {
                            Text("Un site doit avoir").sqKicker().accessibilityAddTraits(.isHeader)
                            MapSegmented(selection: $draft.bandMatch,
                                         options: BandMatchMode.allCases.map { ($0, $0.label) },
                                         identifier: "map.filters.bandMatch")
                            Text(draft.bandMatch.explanation)
                                .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.lg)
                .padding(.bottom, SQSpace.xl)
            }
            MapSubpageFooter(clearDisabled: draft.bands.isEmpty, confirmTitle: String(localized: "Valider les bandes"),
                             identifier: "map.filters.bands") {
                draft.bands.removeAll()
            } onConfirm: { dismiss() }
        }
        .background(SQColor.surface)
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
    }
}

/// Partage d'infrastructure, en lignes à cocher.
struct MapSharingPage: View {
    @Binding var draft: MapFilterSelection
    let options: [MapFilterCatalog.SharingOption]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.xl) {
                    MapSheetPageHeader(title: String(localized: "Partage"),
                                       subtitle: draft.sharing.isEmpty ? String(localized: "Tous les sites") : nil,
                                       backIdentifier: "map.filters.sharing.back") { dismiss() }
                    MapRowsTile {
                        ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                            MapCheckRow(isOn: draft.sharing.contains(option.value),
                                        identifier: "map.filters.sharing.\(option.value)") {
                                if draft.sharing.contains(option.value) { draft.sharing.remove(option.value) }
                                else { draft.sharing.insert(option.value) }
                            } label: {
                                Image(systemName: option.icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(SQColor.labelSecondary)
                                    .frame(width: 22)
                                    .accessibilityHidden(true)
                                Text(option.label).font(SQType.callout(.semibold)).foregroundStyle(SQColor.label)
                            }
                            .mapRowDivider(index > 0)
                        }
                    }
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.lg)
                .padding(.bottom, SQSpace.xl)
            }
            MapSubpageFooter(clearDisabled: draft.sharing.isEmpty, confirmTitle: String(localized: "Valider"),
                             identifier: "map.filters.sharing") {
                draft.sharing.removeAll()
            } onConfirm: { dismiss() }
        }
        .background(SQColor.surface)
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
    }
}

// MARK: - Pièces Halo des feuilles de la carte

/// En-tête de feuille Halo : titre 18, sous-titre gris, bouton fermer en puce.
struct MapSheetHeader: View {
    let title: String
    var subtitle: String? = nil
    let closeIdentifier: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(SQType.title).foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
                if let subtitle {
                    Text(subtitle).font(SQType.subhead).foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: closeIdentifier, action: onClose)
        }
    }
}

/// En-tête de page poussée : retour en puce, titre centré.
struct MapSheetPageHeader: View {
    let title: String
    var subtitle: String? = nil
    let backIdentifier: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: SQSpace.sm) {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: backIdentifier, action: onBack)
            VStack(spacing: 1) {
                Text(title).font(SQType.heading).foregroundStyle(SQColor.label).sqHeader()
                if let subtitle {
                    Text(subtitle).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
    }
}

/// Bouton rond de 44 pt posé sur une carte : fond de surface et ombre, comme
/// les boutons de l'onglet Carte. Le point signale un réglage modifié.
struct MapFloatingIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let identifier: String
    var tint: Color = SQColor.label
    var showsDot = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .sqSurface(SQColor.surface, in: Circle())
                .sqShadowCard()
                .overlay(alignment: .topTrailing) {
                    if showsDot {
                        Circle().fill(SQColor.brandRed)
                            .frame(width: 10, height: 10)
                            .overlay { Circle().strokeBorder(SQColor.surface, lineWidth: 2) }
                            .offset(x: -1, y: 1)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// Titre d'une page carte, en capsule à côté du bouton retour.
struct MapFloatingTitle: View {
    let title: LocalizedStringKey
    let identifier: String

    var body: some View {
        Text(title)
            .font(SQType.heading)
            .foregroundStyle(SQColor.label)
            .lineLimit(1)
            .padding(.horizontal, SQSpace.lg)
            .frame(minHeight: 44)
            .sqSurface(SQColor.surface, in: Capsule())
            .sqShadowCard()
            .sqHeader()
            .accessibilityIdentifier(identifier)
    }
}

/// Bouton rond de 44 pt sur le fond des puces.
struct MapChipIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.label)
                .frame(width: 44, height: 44)
                .sqSurface(SQColor.chip, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// Sélecteur segmenté pleine largeur (piste et pastille pleine). Les grands
/// textes l'empilent plutôt que de tronquer les libellés.
struct MapSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    let identifier: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
        layout {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                segment(option.0, label: option.1)
            }
        }
        .padding(SQSpace.xs)
        .background(SQColor.segTrack, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private func segment(_ value: Value, label: String) -> some View {
        let isSelected = value == selection
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : SQMotion.snappy) { selection = value }
        } label: {
            Text(LocalizedStringKey(label))
                .font(SQType.chip)
                .foregroundStyle(isSelected ? SQColor.label : SQColor.labelSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SQSpace.sm)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(SQColor.segThumb)
                            .shadow(color: SQColor.shadowSoft, radius: 2, y: 1)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).\(String(describing: value))")
    }
}

/// Tuile qui groupe des lignes séparées par un filet.
struct MapRowsTile<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, SQSpace.md)
            .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }
}

/// Ligne à cocher : contenu libre, case à droite, 46 pt de haut.
struct MapCheckRow<Label: View>: View {
    let isOn: Bool
    let identifier: String
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            HStack(spacing: SQSpace.sm2) {
                label()
                Spacer(minLength: SQSpace.sm)
                MapCheckbox(isOn: isOn)
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// Case Halo : contour pointillé au repos, carmin plein et coche une fois cochée.
struct MapCheckbox: View {
    let isOn: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        shape.fill(isOn ? SQColor.brandRed : Color.clear)
            .overlay { if !isOn { shape.strokeBorder(SQColor.dots, lineWidth: 1.5) } }
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(SQColor.onAccent)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

/// Étiquette de génération : la couleur de la carte, encre sombre.
struct MapTechTag: View {
    let technology: String
    let label: String

    var body: some View {
        Text(label)
            .font(SQFont.body(11, .heavy, relativeTo: .caption2))
            .foregroundStyle(Color(hex: 0x0F1312))
            .padding(.horizontal, 7)
            .frame(minHeight: 22)
            .background(SQBrand.techColor(technology), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Pied des sous-pages : « Effacer » et la validation, qui ramène aux filtres.
struct MapSubpageFooter: View {
    let clearDisabled: Bool
    let confirmTitle: String
    let identifier: String
    let onClear: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: SQSpace.sm2) {
            Button(action: onClear) {
                Text("Effacer")
                    .font(SQType.button).foregroundStyle(SQColor.label)
                    .padding(.horizontal, SQSpace.xs2)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(clearDisabled)
            .accessibilityIdentifier("\(identifier).clear")
            GradientButton(confirmTitle, action: onConfirm)
                .accessibilityIdentifier("\(identifier).confirm")
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.top, SQSpace.md)
        .padding(.bottom, SQSpace.sm)
        .background(SQColor.surface)
        .overlay(alignment: .top) { Rectangle().fill(SQColor.separator).frame(height: 1) }
    }
}

extension View {
    /// Filet entre deux lignes d'une même tuile.
    func mapRowDivider(_ shown: Bool) -> some View {
        overlay(alignment: .top) {
            if shown { Rectangle().fill(SQColor.separator).frame(height: 1).allowsHitTesting(false) }
        }
    }
}
