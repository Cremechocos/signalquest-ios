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
    /// Mesure de la couverture hors génération : RSRP, RSRQ ou SINR (contrat v3).
    @Binding var coverageMeasure: SQQualityScale.Signal.Measure
    @Binding var azimuthStyle: AzimuthStyle
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
    /// Session vue seule : ses réglages passent en tête de la feuille.
    var sessionSection: MapSessionTraceSection? = nil
    @AppStorage(MapBackdrop.storageKey) private var backdropRaw = MapBackdrop.applePlan.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Icône des tuiles et son cadre, à l'échelle du libellé : le cadre de hauteur
    /// fixe aligne les libellés, quelle que soit la hauteur du symbole.
    @ScaledMetric(relativeTo: .footnote) private var layerIconSize: CGFloat = 18
    @ScaledMetric(relativeTo: .footnote) private var layerIconFrame: CGFloat = 22

    init(market: String, operatorName: String,
         layers: Binding<Set<MapDisplayItem.Kind>>,
         photosFriendsOnly: Binding<Bool> = .constant(false),
         byGeneration: Binding<Bool> = .constant(false),
         coverageMeasure: Binding<SQQualityScale.Signal.Measure> = .constant(.rsrp),
         azimuthStyle: Binding<AzimuthStyle> = .constant(.lobes),
         allMarkets: [MarketRegistryEntry], showsFriendsLayer: Bool = true,
         operatorOptions: [String] = ["ALL"],
         operatorLabel: @escaping (String) -> String = { $0 },
         operatorAccent: @escaping (String) -> Color = { _ in SQColor.labelSecondary },
         antennaOperators: [MapAntennaLegendOperator] = [],
         onChooseOperator: @escaping (String) -> Void = { _ in },
         onChooseMarket: @escaping (MarketRegistryEntry) -> Void = { _ in },
         onOpenANFR: ((MapANFRDestination) -> Void)? = nil,
         sessionSection: MapSessionTraceSection? = nil) {
        self.market = market
        self.operatorName = operatorName
        _layers = layers
        _photosFriendsOnly = photosFriendsOnly
        _byGeneration = byGeneration
        _coverageMeasure = coverageMeasure
        _azimuthStyle = azimuthStyle
        self.allMarkets = allMarkets
        self.showsFriendsLayer = showsFriendsLayer
        self.operatorOptions = operatorOptions
        self.operatorLabel = operatorLabel
        self.operatorAccent = operatorAccent
        self.antennaOperators = antennaOperators
        self.onChooseOperator = onChooseOperator
        self.onChooseMarket = onChooseMarket
        self.onOpenANFR = onOpenANFR
        self.sessionSection = sessionSection
    }

    private var selectedEntry: MarketRegistryEntry? {
        allMarkets.first { $0.code.caseInsensitiveCompare(market) == .orderedSame
            || $0.marketCode.caseInsensitiveCompare(market) == .orderedSame }
    }
    private var communityOnly: Bool { selectedEntry?.isCommunityOnly == true }
    private var communityAvailable: Bool { selectedEntry?.hasCommunityCells == true }
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
            // En « Tous », la couverture n'a rien à montrer : la tuile s'efface (l'indice
            // sous la grille dit pourquoi), sauf allumée, pour qu'on puisse l'éteindre.
            case .coverage where allOperators && !layers.contains(.coverage): return nil
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
                    if let sessionSection { sessionSection }
                    operatorSection
                    layerSection
                    if layers.contains(.coverage) && !allOperators { coverageSection }
                    if layers.contains(.antenna) { antennaSection }
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
            MapOperatorPicker(options: operatorOptions, selection: operatorName,
                              label: operatorLabel, accent: operatorAccent, onChoose: onChooseOperator)
        }
    }

    /// Rendu des azimuts, appliqué tout de suite et gardé sur l'appareil, comme
    /// la section « Antennes » des calques web et Android : un interrupteur, puis
    /// le dessin, proposé seulement quand il est allumé.
    private var antennaSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Antennes").sqKicker().accessibilityAddTraits(.isHeader)
            Toggle("Azimuts", isOn: azimuthsShown)
                .font(SQType.callout(.semibold))
                .foregroundStyle(SQColor.label)
                .tint(SQColor.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("map.layers.azimuth.toggle")
            if azimuthStyle != .hidden {
                MapSegmented(selection: $azimuthStyle,
                             options: [AzimuthStyle.lobes, .lines].map { ($0, $0.label) },
                             identifier: "map.layers.azimuth")
            }
        }
    }

    /// Ce que colore la couverture, à côté des couches plutôt qu'au fond de la
    /// légende (retour d'Alexandre du 21/11), comme les azimuts juste dessous.
    /// L'échelle tient en une ligne ; les bornes exactes restent dans la légende.
    private var coverageSection: some View {
        let coloring = CoverageColoring.binding(byGeneration: $byGeneration, measure: $coverageMeasure)
        return VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Couverture").sqKicker().accessibilityAddTraits(.isHeader)
            MapSegmented(selection: coloring, options: CoverageColoring.allCases.map { ($0, $0.title) },
                         identifier: "map.layers.coverage.mode")
            CoverageScaleStrip(coloring: coloring.wrappedValue, marketCode: market)
        }
    }

    private var azimuthsShown: Binding<Bool> {
        Binding(get: { azimuthStyle != .hidden },
                set: { azimuthStyle = $0 ? MapAzimuthStyleStore.lastDrawing() : .hidden })
    }

    /// Trois tuiles par rangée ; aux tailles d'accessibilité, une rangée par couche,
    /// pour qu'aucun mot ne se coupe en son milieu (« Couvertu / re »).
    private var layerColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: SQSpace.sm),
              count: dynamicTypeSize.isAccessibilitySize ? 1 : 3)
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
            if allOperators {
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
            let frameSide = min(layerIconFrame, 36)
            // En rangée, une largeur commune (les antennes sont larges) aligne les libellés.
            let symbol = Image(systemName: icon)
                .font(.system(size: min(layerIconSize, 30), weight: .medium))
                .frame(width: dynamicTypeSize.isAccessibilitySize ? frameSide * 1.5 : nil, height: frameSide)
                .accessibilityHidden(true)
            let label = Text(LocalizedStringKey(title))
                .font(SQType.chip)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: SQSpace.md) {
                        symbol
                        label.multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, SQSpace.md)
                    .padding(.vertical, SQSpace.sm)
                    .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    // Contenu calé en haut : les libellés d'une rangée partagent leur ligne de base.
                    VStack(spacing: SQSpace.xs) {
                        symbol
                        label.multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, SQSpace.xs)
                    .padding(.vertical, SQSpace.md)
                    .frame(maxWidth: .infinity, minHeight: 66, maxHeight: .infinity, alignment: .top)
                }
            }
            .foregroundStyle(isOn ? SQColor.bg : (disabled ? SQColor.labelTertiary : SQColor.ink2))
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
            // Calées en haut : un libellé sur deux lignes ne décale plus les vignettes ;
            // aux tailles d'accessibilité, une rangée par fond.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: SQSpace.sm))
                : AnyLayout(HStackLayout(alignment: .top, spacing: SQSpace.sm))
            layout {
                backdropTile(.applePlan, title: "Plan")
                backdropTile(.satellite, title: "Satellite")
                backdropTile(.topo, title: "Relief")
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
            // Un seul style de sélection dans la feuille : l'encre, comme l'aplat des tuiles.
            // L'anneau est décollé de la vignette : lisible sur Satellite comme sur Plan,
            // et le libellé garde sa graisse.
            let preview = backdropPreview(value)
                .clipShape(shape)
                .overlay { shape.strokeBorder(SQColor.separator, lineWidth: 1) }
                .frame(height: 44)
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: SQRadius.iconTile + 3, style: .continuous)
                        .strokeBorder(selected ? SQColor.label : .clear, lineWidth: 2)
                }
                .accessibilityHidden(true)
            let label = Text(LocalizedStringKey(title))
                .font(SQFont.body(12, .semibold, relativeTo: .footnote))
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: SQSpace.md) {
                        preview.frame(width: 72)
                        label.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 56)
                } else {
                    VStack(spacing: SQSpace.xs) {
                        preview
                        label.multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("map.backdrop.\(value.rawValue)")
    }

    @ViewBuilder
    private func backdropPreview(_ value: MapBackdrop) -> some View {
        switch value {
        case .satellite:
            LinearGradient(colors: [Color(hex: 0x4F5D4A), Color(hex: 0x7A8460), Color(hex: 0x3D4A3E)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .topo:
            LinearGradient(colors: [Color(hex: 0xDCD7C4), Color(hex: 0xB9B29A), Color(hex: 0xE6E1CF)],
                           startPoint: .top, endPoint: .bottom)
        default:
            MapPlanThumbnail()
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
                MapLegendPage(byGeneration: $byGeneration, measure: $coverageMeasure, marketCode: market,
                              operators: antennaOperators, showsCoverage: layers.contains(.coverage))
            } label: {
                MapSheetRow(title: String(localized: "Légende")) {
                    Image(systemName: "info.circle").font(.system(size: 17, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("map.legend")
            // La carte et les statistiques ANFR ne couvrent que la France et les DROM ;
            // le comparatif de zone sert dans tous les pays.
            if let onOpenANFR, !["FR", "DROM"].contains(market.uppercased()) {
                Divider().overlay(SQColor.separator)
                Button {
                    onOpenANFR(.zoneCompare)
                    dismiss()
                } label: {
                    MapSheetRow(title: String(localized: "Comparer les opérateurs ici")) {
                        Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 16, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("map.filters.anfr.zoneCompare")
            } else if let onOpenANFR {
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
                    Button {
                        onOpenANFR(.zoneCompare)
                        dismiss()
                    } label: { Label("Comparer les opérateurs ici", systemImage: "chart.bar.doc.horizontal") }
                        .accessibilityIdentifier("map.filters.anfr.zoneCompare")
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
            // Étiquette d'un `Menu`, la ligne centrerait sinon ses textes sur plusieurs lignes.
            .multilineTextAlignment(.leading)
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

/// Vignette du fond Plan : un bout de plan dessiné aux couleurs du thème (terre,
/// parc, rivière, deux routes), qui se lit en clair comme en sombre au lieu d'un
/// aplat de la couleur de la feuille.
struct MapPlanThumbnail: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: dark ? 0x2A2F2C : 0xF1EEE6)))
            context.fill(Path(roundedRect: CGRect(x: w * 0.64, y: h * 0.1, width: w * 0.24, height: h * 0.36), cornerRadius: 3),
                         with: .color(Color(hex: dark ? 0x2F4335 : 0xCDE3BF)))
            var river = Path()
            river.move(to: CGPoint(x: 0, y: h * 0.8))
            river.addCurve(to: CGPoint(x: w, y: h * 0.72),
                           control1: CGPoint(x: w * 0.35, y: h * 0.58), control2: CGPoint(x: w * 0.62, y: h * 1.0))
            context.stroke(river, with: .color(Color(hex: dark ? 0x23405A : 0xADD2EE)), lineWidth: h * 0.16)
            var roads = Path()
            roads.move(to: CGPoint(x: w * 0.2, y: 0))
            roads.addLine(to: CGPoint(x: w * 0.46, y: h))
            roads.move(to: CGPoint(x: 0, y: h * 0.38))
            roads.addLine(to: CGPoint(x: w, y: h * 0.3))
            context.stroke(roads, with: .color(Color(hex: dark ? 0x3C4340 : 0xD8D2C4)), lineWidth: 5)
            context.stroke(roads, with: .color(Color(hex: dark ? 0x5E6662 : 0xFFFFFF)), lineWidth: 3)
        }
    }
}

/// Choix de l'opérateur : une piste segmentée comme « Lobes / Traits », avec la
/// couleur de chaque opérateur sur la carte. Les segments gardent leur largeur
/// naturelle et se partagent le reste de la ligne ; quand ils ne tiennent pas
/// (beaucoup d'opérateurs, grand texte), la piste passe sur deux colonnes, puis
/// sur une seule aux tailles d'accessibilité.
struct MapOperatorPicker: View {
    let options: [String]
    let selection: String
    let label: (String) -> String
    let accent: (String) -> Color
    let onChoose: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Choix montré dès le toucher, le temps que la carte prenne le relais.
    @State private var pending: String?

    private var current: String { pending ?? selection }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                grid(columns: 1)
            } else {
                ViewThatFits(in: .horizontal) {
                    track(MapSegmentRowLayout(spacing: 3) { segments })
                    grid(columns: 2)
                }
            }
        }
        .onChangeCompat(of: selection) { _, _ in pending = nil }
    }

    private func grid(columns: Int) -> some View {
        track(LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns), spacing: 3) {
            segments
        })
    }

    private func track(_ content: some View) -> some View {
        content
            .padding(SQSpace.xs)
            .background(SQColor.segTrack, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private var segments: some View {
        ForEach(options, id: \.self) { key in segment(key) }
    }

    private func segment(_ key: String) -> some View {
        let isSelected = key.caseInsensitiveCompare(current) == .orderedSame
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : SQMotion.snappy) { pending = key }
            onChoose(key)
        } label: {
            HStack(spacing: SQSpace.xs2) {
                if key.uppercased() != "ALL" {
                    Circle().fill(accent(key)).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                Text(label(key))
                    .font(SQType.chip)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isSelected ? SQColor.label : SQColor.labelSecondary)
            .padding(.horizontal, SQSpace.xs)
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
        .accessibilityIdentifier("map.operator.option.\(key)")
    }
}

/// Segments sur une ligne à leur largeur naturelle, le reste partagé à parts
/// égales : « Bouygues » garde son nom entier à côté de « SFR ». La largeur idéale
/// (somme des segments) permet à `ViewThatFits` de choisir une autre forme.
struct MapSegmentRowLayout: Layout {
    var spacing: CGFloat = 3

    private func natural(_ subviews: Subviews) -> (sizes: [CGSize], width: CGFloat) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(subviews.count - 1, 0))
        return (sizes, width)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (sizes, width) = natural(subviews)
        let height = sizes.map(\.height).max() ?? 0
        guard let proposed = proposal.width, proposed.isFinite else { return CGSize(width: width, height: height) }
        return CGSize(width: max(proposed, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (sizes, width) = natural(subviews)
        let extra = max(0, bounds.width - width) / CGFloat(max(subviews.count, 1))
        var x = bounds.minX
        for (subview, size) in zip(subviews, sizes) {
            let segmentWidth = size.width + extra
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: segmentWidth, height: bounds.height))
            x += segmentWidth + spacing
        }
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
    @Binding var measure: SQQualityScale.Signal.Measure
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
            MapSegmented(selection: coloring, options: CoverageColoring.allCases.map { ($0, $0.title) },
                         identifier: "map.coverage.mode")
            VStack(alignment: .leading, spacing: SQSpace.md) {
                if byGeneration {
                    ForEach(CoverageGenerationBand.visibleBands) { band in
                        swatchEntry(band.title(forMarket: marketCode), color: band.swiftUIColor)
                    }
                    // Choix d'Alexandre du 21/11 : la 5G au repos (icône seule) reste en 4G.
                    Text("5G : seulement quand le téléphone l’utilisait.")
                        .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(CoverageQualityBand.visibleBands) { band in
                        swatchEntry(band.title, detail: band.bounds(for: measure), color: band.swiftUIColor, hatched: band.isHatched)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                        Text(measureNote)
                            .font(SQType.caption).foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        SQInfoButton(term: measureTerm)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(coloring.wrappedValue)
            .transition(.opacity)
            .animation(SQMotion.resolve(SQMotion.fast, reduceMotion), value: coloring.wrappedValue)
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

    /// Un seul choix pour la couche : RSRP, RSRQ, SINR ou Génération (contrat
    /// quality-scale-v3, 21/11). Génération garde son réglage d'avant.
    private var coloring: Binding<CoverageColoring> {
        CoverageColoring.binding(byGeneration: $byGeneration, measure: $measure)
    }

    private var measureNote: String {
        switch measure {
        case .rsrp: return String(localized: "Seuils de la 4G et de la 5G ; la 3G et la 2G ont les leurs.")
        case .rsrq, .sinr: return String(localized: "4G et 5G seulement : un point sans cette mesure n’est pas affiché.")
        }
    }

    private var measureTerm: SQTerm {
        switch measure {
        case .rsrp: return .rsrp
        case .rsrq: return .rsrq
        case .sinr: return .snr
        }
    }

    private func swatchEntry(_ title: String, detail: String? = nil, color: Color, hatched: Bool = false) -> some View {
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
            if let detail {
                Spacer(minLength: SQSpace.sm)
                Text(verbatim: detail).font(SQType.subhead).monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
        }
        // Niveau et bornes lus d'une traite ; sans bornes, rien ne change.
        .accessibilityElement(children: detail == nil ? .contain : .combine)
    }
}

/// Échelle de la couverture en une ligne : les teintes, de la meilleure à la
/// pire, et les deux extrêmes. Les bornes de chaque niveau sont dans la légende.
struct CoverageScaleStrip: View {
    let coloring: CoverageColoring
    let marketCode: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(spacing: 3) {
                ForEach(Array(coloring.swatches.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 3).fill(color).frame(height: 8)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: SQSpace.sm) {
                Text(verbatim: ends.best)
                Spacer(minLength: 0)
                Text(verbatim: ends.worst).multilineTextAlignment(.trailing)
            }
            .font(SQType.caption)
            .monospacedDigit()
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(ends.best), \(ends.worst)"))
        .accessibilityIdentifier("map.layers.coverage.scale")
    }

    var ends: (best: String, worst: String) {
        guard let measure = coloring.measure else {
            let bands = CoverageGenerationBand.visibleBands.filter { $0 != .none }
            return (bands.first?.title(forMarket: marketCode) ?? "", bands.last?.title(forMarket: marketCode) ?? "")
        }
        func end(_ band: CoverageQualityBand) -> String {
            [band.title, band.bounds(for: measure)].compactMap { $0 }.joined(separator: " ")
        }
        return (end(.excellent), end(.poor))
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

// MARK: - Trajet vu seul

/// Réglages de la session vue seule sur la carte (« Voir le tracé » d'un post,
/// contrat #958) : tracé ou points, couleur du signal ou de la génération, et
/// la légende des seuls niveaux présents. Rangés dans la feuille Carte, pas
/// posés sur la carte.
struct MapSessionTraceSection: View {
    @Binding var style: SessionTraceStyle
    @Binding var coloring: SessionPointColoring
    let points: [CoverageSessionPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Ce trajet").sqKicker().accessibilityAddTraits(.isHeader)
            MapSegmented(selection: $style,
                         options: [(.trace, String(localized: "Tracé")), (.points, String(localized: "Points"))],
                         identifier: "map.layers.session.style")
            MapSegmented(selection: $coloring,
                         options: [(.rsrp, String(localized: "Signal")), (.generation, String(localized: "Génération"))],
                         identifier: "map.layers.session.coloring")
            if !legend.isEmpty {
                MapFlowLayout(spacing: SQSpace.sm) {
                    ForEach(legend, id: \.label) { entry in
                        HStack(spacing: SQSpace.xs) {
                            swatch(entry.color, dashed: entry.dashed)
                            Text(verbatim: entry.label)
                                .font(SQType.caption(.semibold))
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .accessibilityIdentifier("map.layers.session.legend")
            }
        }
    }

    private struct LegendEntry {
        let color: Color
        let label: String
        var dashed = false
    }

    /// Du meilleur au pire, puis les états sans mesure ; seulement ce que le trajet contient.
    private var legend: [LegendEntry] {
        switch coloring {
        case .rsrp:
            let present = Set(points.map { SQQualityScale.Signal(dbm: $0.signalStrength, technology: $0.tech) })
            return SQQualityScale.Signal.allCases.filter(present.contains)
                .map { LegendEntry(color: $0.color, label: $0.label, dashed: $0.isHatched) }
        case .generation:
            let order: [SQQualityScale.Generation] = [.fiveG, .fourG, .threeG, .twoG, .none]
            let present = Set(points.map { SQQualityScale.Generation(technology: $0.tech) })
            return order.filter(present.contains).map { generation in
                let label: String
                switch generation {
                case .fiveG: label = "5G"
                case .fourG: label = "4G"
                case .threeG: label = "3G"
                case .twoG: label = "2G"
                case .none: label = String(localized: "Techno inconnue")
                }
                return LegendEntry(color: Color(hex: generation.hex), label: label)
            }
        }
    }

    private func swatch(_ color: Color, dashed: Bool) -> some View {
        Capsule()
            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .butt, dash: dashed ? [4, 3] : []))
            .frame(width: 18, height: 4)
            .accessibilityHidden(true)
    }
}
