import SwiftUI
import MapKit

struct MapAdvancedFilterSheet: View {
    @State private var baseline: MapFilterSelection
    @State private var draft: MapFilterSelection
    @State private var originalDromRegion: DromRegion?
    @State private var expertsExpanded = false
    @State private var adjustmentNotice = false
    @State private var applyError: String?
    let allMarkets: [MarketRegistryEntry]
    let onApply: (MapFilterSelection) -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(selection: MapFilterSelection, allMarkets: [MarketRegistryEntry],
         dromRegion: DromRegion?, onApply: @escaping (MapFilterSelection) -> Bool) {
        _baseline = State(initialValue: selection)
        _draft = State(initialValue: selection)
        _originalDromRegion = State(initialValue: dromRegion)
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
    private var draftDromRegion: DromRegion? {
        guard catalogMarket.uppercased() == "DROM" else { return nil }
        if baseline.market.uppercased() == "DROM" { return originalDromRegion }
        guard let latitude = selectedEntry?.defaultCenterLatitude,
              let longitude = selectedEntry?.defaultCenterLongitude else { return nil }
        return DromRegion.from(latitude: latitude, longitude: longitude) ?? .guadeloupe
    }
    private var operators: [String] {
        selectedEntry.map { MapFilterSelection.operatorOptions(for: $0, dromRegion: draftDromRegion) } ?? ["ALL"]
    }
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 140), spacing: 8)]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Choisis ce que tu veux voir.")
                        .font(SQType.subhead).foregroundStyle(SQColor.labelSecondary)
                    countrySection
                    operatorSection
                    layerSection
                    DisclosureGroup(isExpanded: $expertsExpanded) {
                        expertSections.padding(.top, 20)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Réglages experts").font(SQType.heading).foregroundStyle(SQColor.label)
                            Text(expertSummary).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(SQColor.accentInk)
                    .disclosureGroupStyle(MapExpertDisclosureStyle())
                    if adjustmentNotice {
                        Text("Les options incompatibles ont été ajustées au pays choisi.")
                            .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                            .accessibilityIdentifier("map.filters.adjustment")
                    }
                }
                .padding(20)
            }
            .accessibilityIdentifier("map.filters.content")
            footer
            }
            .background(SQColor.surface)
            .navigationTitle("Filtres de la carte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(SQColor.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                        .tint(SQColor.accentInk)
                        .accessibilityIdentifier("map.filters.cancel")
                }
            }
        }
    }

    private var countrySection: some View {
        section("Pays") {
            Menu {
                ForEach(allMarkets) { entry in
                    Button {
                        changeMarket(to: entry)
                    } label: {
                        if entry.code.caseInsensitiveCompare(draft.market) == .orderedSame
                            || entry.marketCode.caseInsensitiveCompare(draft.market) == .orderedSame {
                            Label(marketTitle(entry), systemImage: "checkmark")
                        } else { Text(marketTitle(entry)) }
                    }
                    .accessibilityIdentifier("map.filters.country.\(entry.code)")
                }
            } label: {
                menuLabel(title: selectedEntry.map(marketName) ?? draft.market,
                          symbol: "globe", accessory: selectedEntry.map { flagEmoji($0.countryCode) })
            }
            .accessibilityIdentifier("map.filters.market")
            .disabled(allMarkets.isEmpty)
        }
    }

    private var operatorSection: some View {
        section("Opérateur") {
            Menu {
                ForEach(operators, id: \.self) { key in
                    Button { draft.operatorName = key } label: {
                        if key.caseInsensitiveCompare(draft.operatorName) == .orderedSame {
                            Label(operatorLabel(key), systemImage: "checkmark")
                        } else { Text(operatorLabel(key)) }
                    }
                }
            } label: { menuLabel(title: operatorLabel(draft.operatorName), symbol: "antenna.radiowaves.left.and.right") }
            .accessibilityIdentifier("map.filters.operator")
            if let region = draftDromRegion {
                Text(region.displayName).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
            }
        }
    }

    var layerOptions: [(MapDisplayItem.Kind, String, String)] {
        var options: [(MapDisplayItem.Kind, String, String)] = [
            (.antenna, selectedEntry?.isCommunityOnly == true ? String(localized: "Sites communautaires") : String(localized: "Antennes"), "antenna.radiowaves.left.and.right"),
            (.customSite, String(localized: "Sites ajoutés"), "mappin.and.ellipse"),
            (.speedtest, String(localized: "Speedtests"), "speedometer"),
            (.photo, String(localized: "Photos"), "photo"),
            (.friend, String(localized: "Amis"), "person.2"),
            (.coverage, String(localized: "Couverture"), "dot.radiowaves.left.and.right"),
            (.outage, String(localized: "Pannes"), "exclamationmark.triangle")
        ]
        if plannedAvailable || draft.layers.contains(.planned) {
            options.append((.planned, String(localized: "Prévisionnels"), "calendar.badge.clock"))
        }
        if communityAvailable || draft.layers.contains(.communitySite) {
            options.append((.communitySite, String(localized: "Cellules observées"), "dot.radiowaves.up.forward"))
        }
        return options
    }

    private var layerSection: some View {
        section("Couches") {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(layerOptions, id: \.0.rawValue) { kind, title, icon in
                    layerChip(kind, title: title, icon: icon, unavailable:
                        (kind == .coverage && draft.operatorName.uppercased() == "ALL")
                        || (kind == .planned && !plannedAvailable)
                        || (kind == .communitySite && !communityAvailable))
                }
            }
            if draft.operatorName.uppercased() == "ALL" {
                hint("Choisis un opérateur pour afficher la couverture.")
            }
            if selectedEntry?.isCommunityOnly == true {
                hint("Dans ce pays, les sites proviennent de la communauté.")
            }
            if !plannedAvailable { hint("Les sources prévisionnelles ne sont pas disponibles dans ce pays.") }
        }
    }

    private var expertSections: some View {
        VStack(alignment: .leading, spacing: 24) {
            section("Générations") {
                LazyVGrid(columns: columns, spacing: 8) {
                    chip("Toutes", icon: "sparkles", active: draft.technologies.isEmpty) { draft.technologies.removeAll() }
                    ForEach(MapFilterCatalog.technologies(forMarket: catalogMarket), id: \.value) { technology in
                        chip(technology.label, icon: "cellularbars", active: draft.technologies.contains(technology.value)) {
                            toggle(technology.value, in: &draft.technologies)
                        }.accessibilityIdentifier("map.filters.technology.\(technology.value)")
                    }
                }
            }
            section("Bandes et fréquences") {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(MapFilterCatalog.bands(forMarket: catalogMarket), id: \.band) { band in
                        chip(band.label, icon: "waveform", active: draft.bands.contains(band.band)) {
                            toggle(band.band, in: &draft.bands)
                        }.accessibilityIdentifier("map.filters.band.\(band.band)")
                    }
                }
                if !draft.bands.isEmpty {
                    Text("Croisement des bandes").font(SQType.subhead).foregroundStyle(SQColor.labelSecondary)
                    Menu {
                        ForEach(BandMatchMode.allCases, id: \.self) { mode in
                            Button { draft.bandMatch = mode } label: {
                                if draft.bandMatch == mode { Label(mode.label, systemImage: "checkmark") }
                                else { Text(mode.label) }
                            }
                        }
                    } label: { menuLabel(title: draft.bandMatch.label, symbol: "line.3.horizontal.decrease") }
                    .accessibilityLabel("Croisement des bandes")
                    .accessibilityValue(draft.bandMatch.label)
                    .accessibilityIdentifier("map.filters.bandMatch")
                    Text(draft.bandMatch.explanation).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            let sharing = MapFilterCatalog.sharing(forMarket: catalogMarket)
            if !sharing.isEmpty {
                section("Mutualisation") {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(sharing, id: \.value) { option in
                            chip(option.label, icon: option.icon, active: draft.sharing.contains(option.value)) {
                                toggle(option.value, in: &draft.sharing)
                            }.accessibilityIdentifier("map.filters.sharing.\(option.value)")
                        }
                    }
                }
            }
            section("Azimuts") {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(AzimuthStyle.allCases, id: \.self) { style in
                        chip(style.label, icon: style.icon, active: draft.azimuthStyle == style) { draft.azimuthStyle = style }
                            .accessibilityIdentifier("map.filters.azimuth.\(style.rawValue)")
                    }
                }
            }
            section("Période") {
                periodPicker("Speedtests", selection: $draft.speedtestDays, identifier: "map.filters.speedtestDays")
                periodPicker("Couverture", selection: $draft.coverageDays, identifier: "map.filters.coverageDays")
            }
            if communityAvailable {
                section("Cellules observées") {
                    Toggle("Inclure les cellules non consolidées", isOn: $draft.includeObserved)
                        .tint(SQColor.accent).accessibilityIdentifier("map.filters.includeObserved")
                    hint("Affiche aussi les cellules captées, en plus des sites probables consolidés")
                }
            }
            if plannedAvailable && draft.layers.contains(.planned) {
                section("Statut prévisionnel") {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(PlannedActivationStatus.allCases, id: \.self) { status in
                            chip(MapExplorerView.plannedStatusLabel(status), icon: MapExplorerView.plannedStatusGlyph(status), active: draft.plannedStatuses.contains(status)) {
                                toggle(status, in: &draft.plannedStatuses)
                            }.accessibilityIdentifier("map.filters.planned.\(status.rawValue)")
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let applyError {
                Text(applyError).font(SQType.caption).foregroundStyle(SQColor.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(draft == baseline ? String(localized: "Filtres actuels") : String(localized: "Modifications à appliquer"))
                    .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button { resetDraft() } label: {
                    Text("Réinitialiser")
                        .font(SQType.subhead).foregroundStyle(SQColor.accentInk)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("map.filters.reset")
            }
            GradientButton("Appliquer les filtres") {
                if onApply(draft) { dismiss() }
                else { applyError = String(localized: "Les pays disponibles ont changé. Vérifie ton choix.") }
            }
            .disabled(selectedEntry == nil)
            .accessibilityIdentifier("map.filters.done")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(SQColor.surface)
        .overlay(alignment: .top) { Rectangle().fill(SQColor.separator).frame(height: 0.5) }
    }

    private var expertSummary: String {
        let generations = draft.technologies.isEmpty ? String(localized: "Toutes générations") : draft.technologies.sorted().joined(separator: ", ")
        let catalogue = MapFilterCatalog.bands(forMarket: catalogMarket)
        let bands = draft.bands.isEmpty ? String(localized: "Toutes bandes")
            : catalogue.filter { draft.bands.contains($0.band) }.map(\.label).joined(separator: ", ")
        return [generations, bands, draft.azimuthStyle.label].joined(separator: " · ")
    }

    private func changeMarket(to entry: MarketRegistryEntry) {
        applyError = nil
        let previous = draft
        draft.market = entry.marketCode.isEmpty ? entry.code : entry.marketCode
        let normalized = draft.normalized(for: entry, dromRegion: draftDromRegion)
        adjustmentNotice = normalized.operatorName != previous.operatorName || normalized.bands != previous.bands
            || normalized.sharing != previous.sharing || normalized.technologies != previous.technologies
        draft = normalized
    }
    private func resetDraft() {
        applyError = nil
        draft = .defaults(market: baseline.market, operatorName: baseline.operatorName)
        if let selectedEntry { draft = draft.normalized(for: selectedEntry, dromRegion: draftDromRegion) }
        adjustmentNotice = false
    }
    private func layerChip(_ kind: MapDisplayItem.Kind, title: String, icon: String, unavailable: Bool = false) -> some View {
        chip(title, icon: icon, active: draft.layers.contains(kind), disabled: unavailable && !draft.layers.contains(kind)) {
            toggle(kind, in: &draft.layers)
        }.accessibilityIdentifier("map.layer.\(kind.rawValue)")
    }
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(SQType.heading).foregroundStyle(SQColor.label)
                .accessibilityAddTraits(.isHeader)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func chip(_ title: String, icon: String, active: Bool, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            HStack(spacing: 8) {
                Image(systemName: active ? "checkmark" : icon).frame(width: 16)
                Text(LocalizedStringKey(title)).fixedSize(horizontal: false, vertical: true)
            }
            .font(SQFont.body(14, .semibold, relativeTo: .subheadline))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .foregroundStyle(disabled ? SQColor.labelSecondary : active ? SQColor.accentInk : SQColor.label)
            .background(active ? SQColor.accentSoft : SQColor.surfaceMuted, in: Capsule())
            .overlay { if active { Capsule().strokeBorder(SQColor.accent, lineWidth: 1) } }
            .contentShape(Capsule())
        }
        .buttonStyle(SQPressButtonStyle()).disabled(disabled)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
    private func menuLabel(title: String, symbol: String, accessory: String? = nil) -> some View {
        HStack(spacing: 10) {
            if let accessory { Text(accessory).accessibilityHidden(true) }
            else { Image(systemName: symbol).foregroundStyle(SQColor.accentInk).accessibilityHidden(true) }
            Text(title).font(SQType.body).foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down").foregroundStyle(SQColor.labelSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 48)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 12))
    }
    private func periodPicker(_ title: LocalizedStringKey, selection: Binding<Int>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(SQType.subhead).foregroundStyle(SQColor.labelSecondary)
            Menu {
                ForEach([0, 7, 30, 90], id: \.self) { days in
                    Button { selection.wrappedValue = days } label: {
                        if selection.wrappedValue == days { Label(periodLabel(days), systemImage: "checkmark") }
                        else { Text(periodLabel(days)) }
                    }
                }
            } label: { menuLabel(title: periodLabel(selection.wrappedValue), symbol: "calendar") }
            .accessibilityLabel(Text(title))
            .accessibilityValue(periodLabel(selection.wrappedValue))
            .accessibilityIdentifier(identifier)
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
    private func toggle<Value: Hashable>(_ value: Value, in set: inout Set<Value>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
    private func operatorLabel(_ key: String) -> String {
        key.uppercased() == "ALL" ? String(localized: "Tous les opérateurs") : MarketRegistryEntry.operatorLabel(key, in: selectedEntry)
    }
    private func marketName(_ entry: MarketRegistryEntry) -> String {
        if entry.marketCode.uppercased() == "DROM" { return String(localized: "Outre-mer français") }
        return Locale.current.localizedString(forRegionCode: entry.countryCode.uppercased()) ?? entry.label
    }
    private func marketTitle(_ entry: MarketRegistryEntry) -> String { "\(flagEmoji(entry.countryCode)) \(marketName(entry))" }
    private func flagEmoji(_ code: String) -> String {
        let scalars = code.uppercased().unicodeScalars
        guard scalars.count == 2, scalars.allSatisfy({ (65...90).contains($0.value) }) else { return "🌐" }
        return String(String.UnicodeScalarView(scalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }
}

/// The whole heading is one control, including the space between its labels.
/// A centre tap must not depend on hitting the small native chevron.
private struct MapExpertDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : SQMotion.fast) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    configuration.label
                    Spacer(minLength: 8)
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(SQColor.accentInk)
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("map.filters.experts")
            .accessibilityValue(configuration.isExpanded ? Text("Développé") : Text("Réduit"))
            if configuration.isExpanded { configuration.content }
        }
    }
}
