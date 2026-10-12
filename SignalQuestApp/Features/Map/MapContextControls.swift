import SwiftUI

/// Pastille « Vue partielle » : la seule information posée sur la carte en
/// dehors des contrôles. La présentation reste attachée à cet ancêtre stable
/// quand la pastille apparaît ou disparaît.
struct MapContextControls: View {
    let limitMessages: [String]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsLimits = false

    var body: some View {
        VStack(spacing: 0) {
            if !limitMessages.isEmpty {
                MapDisplayLimitControl { showsLimits = true }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .sheet(isPresented: $showsLimits) {
            MapDisplayLimitDetails(messages: limitMessages)
                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(260), .medium, .large])
                .sqSheet()
        }
        .onChangeCompat(of: limitMessages.isEmpty) { _, empty in
            if empty { showsLimits = false }
        }
    }
}

/// Un opérateur de la légende des antennes.
struct MapAntennaLegendOperator: Identifiable, Equatable {
    let key: String
    let label: String
    let color: Color
    var id: String { key }
}

/// Échantillon hachuré de la légende : « sans réseau constaté » (contrat
/// quality-scale v1), reconnaissable sans la couleur.
struct SQHatchedSwatch: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(color.opacity(0.25)))
            var stripes = Path()
            let step = max(size.height / 2, 3)
            var x = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.stroke(stripes, with: .color(color), lineWidth: 1.2)
            context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(color), lineWidth: 1)
        }
    }
}

// MARK: - Feuille Carte

/// Feuille Carte : ce que la carte montre, réglé d'un geste. Opérateur, couches
/// et fond s'appliquent tout de suite, la carte se met à jour derrière la
/// feuille ; les filtres fins restent dans la feuille Filtres.
struct MapLayersSheet: View {
    let market: String
    let operatorName: String
    @Binding var layers: Set<MapDisplayItem.Kind>
    @Binding var photosFriendsOnly: Bool
    @Binding var byGeneration: Bool
    let allMarkets: [MarketRegistryEntry]
    /// Sans compte, la couche Amis ne peut rien afficher : on ne la propose pas.
    let showsFriendsLayer: Bool
    let operatorOptions: [String]
    let operatorLabel: (String) -> String
    let operatorAccent: (String) -> Color
    let antennaOperators: [MapAntennaLegendOperator]
    let onChooseOperator: (String) -> Void
    let onChooseMarket: (MarketRegistryEntry) -> Void
    /// Registre ANFR ; `nil` masque la ligne.
    let onOpenANFR: ((MapANFRDestination) -> Void)?
    @AppStorage(MapBackdrop.storageKey) private var backdropRaw = MapBackdrop.applePlan.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(market: String, operatorName: String,
         layers: Binding<Set<MapDisplayItem.Kind>>,
         photosFriendsOnly: Binding<Bool> = .constant(false),
         byGeneration: Binding<Bool> = .constant(false),
         allMarkets: [MarketRegistryEntry], showsFriendsLayer: Bool = true,
         operatorOptions: [String] = ["ALL"],
         operatorLabel: @escaping (String) -> String = { $0 },
         operatorAccent: @escaping (String) -> Color = { _ in SQColor.labelSecondary },
         antennaOperators: [MapAntennaLegendOperator] = [],
         onChooseOperator: @escaping (String) -> Void = { _ in },
         onChooseMarket: @escaping (MarketRegistryEntry) -> Void = { _ in },
         onOpenANFR: ((MapANFRDestination) -> Void)? = nil) {
        self.market = market
        self.operatorName = operatorName
        _layers = layers
        _photosFriendsOnly = photosFriendsOnly
        _byGeneration = byGeneration
        self.allMarkets = allMarkets
        self.showsFriendsLayer = showsFriendsLayer
        self.operatorOptions = operatorOptions
        self.operatorLabel = operatorLabel
        self.operatorAccent = operatorAccent
        self.antennaOperators = antennaOperators
        self.onChooseOperator = onChooseOperator
        self.onChooseMarket = onChooseMarket
        self.onOpenANFR = onOpenANFR
    }

    private var selectedEntry: MarketRegistryEntry? {
        allMarkets.first { $0.code.caseInsensitiveCompare(market) == .orderedSame
            || $0.marketCode.caseInsensitiveCompare(market) == .orderedSame }
    }
    private var communityOnly: Bool { selectedEntry?.isCommunityOnly == true }
    private var communityAvailable: Bool { selectedEntry?.capabilities.communityLayers == true }
    private var plannedAvailable: Bool { selectedEntry?.capabilities.previsionnel == true }
    private var allOperators: Bool { operatorName.uppercased() == "ALL" }

    /// Ordre de lecture des couches, aussi celui de la pastille d'état.
    static let layerOrder: [MapDisplayItem.Kind] = [
        .antenna, .coverage, .speedtest, .outage, .planned, .friend, .photo, .customSite, .communitySite
    ]

    static func layerTitle(_ kind: MapDisplayItem.Kind, communityOnly: Bool = false) -> String {
        switch kind {
        case .antenna: return communityOnly ? String(localized: "Sites communautaires") : String(localized: "Antennes")
        case .coverage: return String(localized: "Couverture")
        case .speedtest: return String(localized: "Débits")
        case .outage, .communityOutage: return String(localized: "Pannes")
        case .planned: return String(localized: "Prévus")
        case .friend: return String(localized: "Amis")
        case .photo: return String(localized: "Photos")
        case .customSite: return String(localized: "Sites ajoutés")
        case .communitySite: return String(localized: "Cellules")
        case .validation: return String(localized: "Validations")
        case .session: return String(localized: "Sessions")
        }
    }

    static func layerIcon(_ kind: MapDisplayItem.Kind) -> String {
        switch kind {
        case .antenna: return "antenna.radiowaves.left.and.right"
        case .coverage: return "dot.radiowaves.left.and.right"
        case .speedtest: return "speedometer"
        case .outage, .communityOutage: return "exclamationmark.triangle"
        case .planned: return "clock"
        case .friend: return "person.2"
        case .photo: return "camera"
        case .customSite: return "mappin.and.ellipse"
        case .communitySite: return "scope"
        case .validation: return "checkmark.seal"
        case .session: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    /// Couches proposées dans ce pays, dans l'ordre de la grille.
    var layerOptions: [(MapDisplayItem.Kind, String, String)] {
        Self.layerOrder.compactMap { kind in
            switch kind {
            case .friend where !showsFriendsLayer: return nil
            case .planned where !plannedAvailable && !layers.contains(.planned): return nil
            case .communitySite where !communityAvailable && !layers.contains(.communitySite): return nil
            default: return (kind, Self.layerTitle(kind, communityOnly: communityOnly), Self.layerIcon(kind))
            }
        }
    }

    private func isUnavailable(_ kind: MapDisplayItem.Kind) -> Bool {
        (kind == .coverage && allOperators)
            || (kind == .planned && !plannedAvailable)
            || (kind == .communitySite && !communityAvailable)
    }

    private var subtitle: String {
        let shown = layerOptions.filter { layers.contains($0.0) }.map(\.1)
        let layersText = shown.isEmpty ? String(localized: "Aucune couche")
            : (ListFormatter.localizedString(byJoining: shown))
        return "\(operatorLabel(operatorName)) · \(layersText)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    MapSheetHeader(title: String(localized: "Carte"), subtitle: subtitle,
                                   closeIdentifier: "map.layers.close") { dismiss() }
                    operatorSection
                    layerSection
                    backdropSection
                    moreRows
                }
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.lg)
                .padding(.bottom, SQSpace.xl)
            }
            .background(SQColor.surface)
            .toolbar(.hidden, for: .navigationBar)
            .accessibilityIdentifier("map.layers.content")
        }
    }

    private var operatorSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Opérateur").sqKicker().accessibilityAddTraits(.isHeader)
            MapFlowLayout(spacing: SQSpace.xs2) {
                ForEach(operatorOptions, id: \.self) { key in
                    let selected = key.caseInsensitiveCompare(operatorName) == .orderedSame
                    Button {
                        Haptics.selection()
                        onChooseOperator(key)
                    } label: {
                        HStack(spacing: SQSpace.xs2) {
                            if key.uppercased() != "ALL" {
                                Circle().fill(operatorAccent(key)).frame(width: 8, height: 8)
                                    .overlay { Circle().strokeBorder(SQColor.bg.opacity(selected ? 0.6 : 0), lineWidth: 1) }
                                    .accessibilityHidden(true)
                            }
                            Text(operatorLabel(key)).font(SQType.chip)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(selected ? SQColor.bg : SQColor.chipInk)
                        .padding(.horizontal, SQSpace.md)
                        .frame(minHeight: 44)
                        .sqSurface(selected ? SQColor.label : SQColor.chip, in: Capsule(style: .continuous))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("map.operator.option.\(key)")
                }
            }
        }
    }

    private var layerColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm),
              count: dynamicTypeSize.isAccessibilitySize ? 2 : 3)
    }

    private var layerSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Couches").sqKicker().accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: layerColumns, spacing: SQSpace.sm) {
                ForEach(layerOptions, id: \.0.rawValue) { kind, title, icon in
                    layerTile(kind, title: title, icon: icon)
                }
            }
            if showsFriendsLayer && layers.contains(.photo) {
                Toggle("Photos de mes amis seulement", isOn: $photosFriendsOnly)
                    .font(SQType.callout(.semibold))
                    .foregroundStyle(SQColor.label)
                    .tint(SQColor.accent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("map.filters.photosFriendsOnly")
            }
            if allOperators && layerOptions.contains(where: { $0.0 == .coverage }) {
                hint("Choisis un opérateur pour afficher la couverture.")
            }
            if communityOnly { hint("Dans ce pays, les sites proviennent de la communauté.") }
        }
    }

    private func layerTile(_ kind: MapDisplayItem.Kind, title: String, icon: String) -> some View {
        let isOn = layers.contains(kind)
        let disabled = isUnavailable(kind) && !isOn
        return Button {
            Haptics.selection()
            if isOn { layers.remove(kind) } else { layers.insert(kind) }
        } label: {
            VStack(spacing: SQSpace.xs) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                    .font(SQType.chip)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isOn ? SQColor.bg : (disabled ? SQColor.labelTertiary : SQColor.ink2))
            .padding(.horizontal, SQSpace.xs)
            .padding(.vertical, SQSpace.sm)
            .frame(maxWidth: .infinity, minHeight: 66)
            .sqSurface(isOn ? SQColor.label : SQColor.surfaceMuted,
                       in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        }
        .buttonStyle(SQPressButtonStyle())
        .disabled(disabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("map.layer.\(kind.rawValue)")
    }

    private var backdrop: MapBackdrop { MapBackdrop.resolve(backdropRaw) }

    private var backdropSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Fond").sqKicker().accessibilityAddTraits(.isHeader)
            HStack(spacing: SQSpace.sm) {
                backdropTile(.applePlan, title: String(localized: "Plan"))
                backdropTile(.satellite, title: String(localized: "Satellite"))
                backdropTile(.topo, title: String(localized: "Relief"))
            }
        }
    }

    private func backdropTile(_ value: MapBackdrop, title: String) -> some View {
        let selected = backdrop == value
        let shape = RoundedRectangle(cornerRadius: SQRadius.iconTile, style: .continuous)
        return Button {
            Haptics.selection()
            backdropRaw = value.rawValue
        } label: {
            VStack(spacing: SQSpace.xs) {
                shape.fill(backdropPreview(value))
                    .frame(height: 44)
                    .overlay {
                        shape.strokeBorder(selected ? SQColor.brandRed : SQColor.separator,
                                           lineWidth: selected ? 2.5 : 1)
                    }
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                    .font(SQFont.body(12, selected ? .heavy : .semibold, relativeTo: .footnote))
                    .foregroundStyle(SQColor.label)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("map.backdrop.\(value.rawValue)")
    }

    private func backdropPreview(_ value: MapBackdrop) -> LinearGradient {
        switch value {
        case .satellite:
            return LinearGradient(colors: [Color(hex: 0x4F5D4A), Color(hex: 0x7A8460), Color(hex: 0x3D4A3E)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .topo:
            return LinearGradient(colors: [Color(hex: 0xDCD7C4), Color(hex: 0xB9B29A), Color(hex: 0xE6E1CF)],
                                  startPoint: .top, endPoint: .bottom)
        default:
            return LinearGradient(colors: [SQColor.bg, SQColor.surfaceMuted], startPoint: .top, endPoint: .bottom)
        }
    }

    private var moreRows: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(allMarkets) { entry in
                    Button {
                        onChooseMarket(entry)
                    } label: {
                        if entry.code.caseInsensitiveCompare(market) == .orderedSame
                            || entry.marketCode.caseInsensitiveCompare(market) == .orderedSame {
                            Label(MapMarketNaming.title(entry), systemImage: "checkmark")
                        } else { Text(MapMarketNaming.title(entry)) }
                    }
                    .accessibilityIdentifier("map.filters.country.\(entry.code)")
                }
            } label: {
                MapSheetRow(title: String(localized: "Pays"),
                            value: selectedEntry.map(MapMarketNaming.name) ?? market) {
                    Text(selectedEntry.map { MapMarketNaming.flag($0.countryCode) } ?? "🌐")
                }
            }
            .accessibilityIdentifier("map.filters.market")
            .disabled(allMarkets.isEmpty)
            Divider().overlay(SQColor.separator)
            NavigationLink {
                MapLegendPage(byGeneration: $byGeneration, marketCode: market,
                              operators: antennaOperators, showsCoverage: layers.contains(.coverage))
            } label: {
                MapSheetRow(title: String(localized: "Légende")) {
                    Image(systemName: "info.circle").font(.system(size: 17, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("map.legend")
            if let onOpenANFR {
                Divider().overlay(SQColor.separator)
                Menu {
                    Button {
                        onOpenANFR(.map)
                        dismiss()
                    } label: { Label("Carte ANFR", systemImage: "map") }
                        .accessibilityIdentifier("map.filters.anfr.map")
                    Button {
                        onOpenANFR(.stats)
                        dismiss()
                    } label: { Label("Statistiques ANFR", systemImage: "chart.bar.xaxis") }
                        .accessibilityIdentifier("map.filters.anfr.stats")
                } label: {
                    MapSheetRow(title: String(localized: "Registre ANFR"),
                                subtitle: String(localized: "Carte et statistiques")) {
                        Image(systemName: "chart.bar").font(.system(size: 16, weight: .medium))
                    }
                }
                .accessibilityIdentifier("map.anfr")
            }
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Noms et drapeaux des pays du registre, partagés par la feuille Carte.
enum MapMarketNaming {
    static func name(_ entry: MarketRegistryEntry) -> String {
        if entry.marketCode.uppercased() == "DROM" { return String(localized: "Outre-mer français") }
        return Locale.current.localizedString(forRegionCode: entry.countryCode.uppercased()) ?? entry.label
    }

    static func title(_ entry: MarketRegistryEntry) -> String { "\(flag(entry.countryCode)) \(name(entry))" }

    static func flag(_ code: String) -> String {
        let scalars = code.uppercased().unicodeScalars
        guard scalars.count == 2, scalars.allSatisfy({ (65...90).contains($0.value) }) else { return "🌐" }
        return String(String.UnicodeScalarView(scalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }
}

/// Ligne de navigation Halo : tuile d'icône, titre, valeur grise et chevron.
struct MapSheetRow<Icon: View>: View {
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: SQSpace.md) {
            icon()
                .foregroundStyle(SQColor.ink2)
                .frame(width: 38, height: 38)
                .background(SQColor.chip, in: RoundedRectangle(cornerRadius: SQRadius.iconTile, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title)).font(SQType.callout(.semibold)).foregroundStyle(SQColor.label)
                if let subtitle {
                    Text(LocalizedStringKey(subtitle)).font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: SQSpace.sm)
            if let value {
                Text(value).font(SQType.caption.weight(.semibold)).foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.trailing)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// Retour à la ligne des pastilles (opérateurs) : iOS 16 n'a pas de `FlowLayout`.
struct MapFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Légende

/// Comment lire la carte : couleurs de la couverture (signal ou génération),
/// opérateurs, parts d'un site partagé, traits de secteur, anneau 5G, coche 4G.
/// Page poussée depuis la feuille Carte.
struct MapLegendPage: View {
    @Binding var byGeneration: Bool
    let marketCode: String?
    let operators: [MapAntennaLegendOperator]
    let showsCoverage: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                MapSheetPageHeader(title: String(localized: "Légende"), backIdentifier: "map.legend.back") { dismiss() }
                coverageSection
                if !operators.isEmpty {
                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        Text("Opérateurs").sqKicker().accessibilityAddTraits(.isHeader)
                        ForEach(operators) { op in
                            entry(op.label) { Circle().fill(op.color).frame(width: 12, height: 12) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: SQSpace.md) {
                    Text("Sur un site").sqKicker().accessibilityAddTraits(.isHeader)
                    entry(String(localized: "Site partagé : une part par opérateur"), term: .siteSharing) {
                        Image(systemName: "chart.pie.fill").foregroundStyle(SQColor.label)
                    }
                    entry(String(localized: "Trait : direction d’un secteur"), term: .azimuth) {
                        Capsule().fill(SQColor.label).frame(width: 18, height: 3)
                    }
                    entry(String(localized: "Anneau : le site émet en 5G, vert quand son identifiant 5G est connu"), term: .cellIdentifiers) {
                        Circle().strokeBorder(SQColor.success, lineWidth: 3).frame(width: 16, height: 16)
                    }
                    entry(String(localized: "Coche : identifiant 4G connu")) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(SQColor.success)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .background(SQColor.surface)
        .toolbar(.hidden, for: .navigationBar)
        .sqKeepsSwipeBack()
        .accessibilityIdentifier("map.legend.content")
    }

    private var coverageSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            Text("Couverture").sqKicker().accessibilityAddTraits(.isHeader)
            MapSegmented(
                selection: $byGeneration,
                options: [(false, String(localized: "Signal")), (true, String(localized: "Génération"))],
                identifier: "map.coverage.mode"
            )
            VStack(alignment: .leading, spacing: SQSpace.md) {
                if byGeneration {
                    ForEach(CoverageGenerationBand.visibleBands) { band in
                        swatchEntry(band.title(forMarket: marketCode), color: band.swiftUIColor)
                    }
                } else {
                    ForEach(CoverageQualityBand.visibleBands) { band in
                        swatchEntry(band.title, color: band.swiftUIColor, hatched: band.isHatched)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(byGeneration)
            .transition(.opacity)
            .animation(SQMotion.resolve(SQMotion.fast, reduceMotion), value: byGeneration)
            if !showsCoverage {
                Text("Active la couche Couverture pour voir ces couleurs sur la carte.")
                    .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func entry<Symbol: View>(_ title: String, term: SQTerm? = nil, @ViewBuilder symbol: () -> Symbol) -> some View {
        HStack(spacing: SQSpace.md) {
            symbol()
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title).font(SQType.subhead).foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let term { SQInfoButton(term: term) }
        }
    }

    private func swatchEntry(_ title: String, color: Color, hatched: Bool = false) -> some View {
        HStack(spacing: SQSpace.md) {
            Group {
                if hatched {
                    SQHatchedSwatch(color: color).clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(color)
                }
            }
            .frame(width: 24, height: 8)
            .accessibilityHidden(true)
            Text(title).font(SQType.subhead).foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Une limite reste visible tant qu'elle concerne les données affichées.
/// Son explication ne recouvre la carte que lorsque l'utilisateur la demande.
private struct MapDisplayLimitControl: View {
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: SQSpace.xs2) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14, weight: .medium))
                    .accessibilityHidden(true)
                Text("Vue partielle")
                    .font(SQFont.body(13, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(SQColor.label)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs)
            .frame(minHeight: 44)
            .sqSurface(SQColor.surface, in: Capsule())
            .sqShadowSoft()
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityHint("Consulter les limites des données affichées")
        .accessibilityIdentifier("map.status.limit")
    }
}

private struct MapDisplayLimitDetails: View {
    let messages: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapSheetHeader(title: String(localized: "Vue partielle"),
                               closeIdentifier: "map.status.limit.close") { dismiss() }
                Text(messages.joined(separator: "\n\n"))
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("map.status.limit.detail")
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .background(SQColor.surface)
    }
}
