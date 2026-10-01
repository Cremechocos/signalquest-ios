import SwiftUI

/// La présentation reste attachée à cet ancêtre stable quand la rangée se
/// replie, quand le mode change de largeur ou pendant un redimensionnement iPad.
struct MapContextControls: View {
    @Binding var byGeneration: Bool
    let showsCoverage: Bool
    let limitMessages: [String]
    /// Opérateurs du marché affiché, dans la couleur de leurs marqueurs.
    var antennaOperators: [MapAntennaLegendOperator] = []
    /// Marché affiché : la 4G se lit « LTE » en Amérique du Nord.
    var marketCode: String?
    /// Au zoom où les secteurs se dessinent : couleurs et traits n'avaient
    /// aucune légende (UI-11).
    var showsAntennaKey = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedPanel: Panel?

    private enum Panel: String, Identifiable {
        case coverage, limits, antennas
        var id: Self { self }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SQSpace.sm) { controls }
                .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: SQSpace.sm) { controls }
        }
        .sheet(item: $presentedPanel) { panel in
            Group {
                switch panel {
                case .coverage:
                    MapCoverageDetails(byGeneration: $byGeneration, marketCode: marketCode)
                        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(360), .medium, .large])
                case .limits:
                    MapDisplayLimitDetails(messages: limitMessages)
                        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(240), .medium, .large])
                case .antennas:
                    MapAntennaLegendDetails(operators: antennaOperators)
                        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                }
            }
            .presentationDragIndicator(.visible)
            .presentationBackgroundCompat(SQColor.surface)
        }
        .onChangeCompat(of: showsCoverage) { _, visible in
            if !visible && presentedPanel == .coverage { presentedPanel = nil }
        }
        .onChangeCompat(of: limitMessages.isEmpty) { _, empty in
            if empty && presentedPanel == .limits { presentedPanel = nil }
        }
        .onChangeCompat(of: showsAntennaKey) { _, visible in
            if !visible && presentedPanel == .antennas { presentedPanel = nil }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if showsCoverage {
            MapCoverageKeyControl(byGeneration: byGeneration) { presentedPanel = .coverage }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        }
        if !limitMessages.isEmpty {
            MapDisplayLimitControl { presentedPanel = .limits }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        }
        if showsAntennaKey {
            MapAntennaKeyControl(operators: antennaOperators) { presentedPanel = .antennas }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
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

/// Pastille « Antennes » : les couleurs des opérateurs en aperçu, la légende
/// complète à la demande.
private struct MapAntennaKeyControl: View {
    let operators: [MapAntennaLegendOperator]
    let onOpen: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            HStack(spacing: SQSpace.sm) {
                HStack(spacing: 3) {
                    ForEach(operators.prefix(5)) { op in
                        Circle().fill(op.color).frame(width: 8, height: 8)
                    }
                }
                .accessibilityHidden(true)
                Text("Antennes")
                    .font(SQFont.body(13, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("map.antenna.legend.label")
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(SQColor.label)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs)
            .frame(minHeight: 44)
            .background(SQColor.surface, in: Capsule())
            .sqShadowSoft()
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("Légende des antennes")
        .accessibilityHint("Couleurs des opérateurs, secteurs et repères des sites")
        .accessibilityIdentifier("map.antenna.legend")
    }
}

/// Comment lire un site sur la carte zoomée : couleurs des opérateurs, parts
/// d'un site partagé, traits de secteur, anneau 5G et coche 4G.
private struct MapAntennaLegendDetails: View {
    let operators: [MapAntennaLegendOperator]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    if !operators.isEmpty {
                        VStack(alignment: .leading, spacing: SQSpace.md) {
                            Text("Opérateurs").font(SQType.subhead).foregroundStyle(SQColor.labelSecondary)
                            ForEach(operators) { op in
                                entry(op.label) { Circle().fill(op.color).frame(width: 12, height: 12) }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        Text("Sur un site").font(SQType.subhead).foregroundStyle(SQColor.labelSecondary)
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
                .padding(SQSpace.xl)
            }
            .background(SQColor.surface)
            .navigationTitle("Antennes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                        .tint(SQColor.accentInk)
                        .accessibilityIdentifier("map.antenna.legend.close")
                }
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
}

/// La carte garde uniquement la couleur active et un aperçu de sa légende.
/// Le réglage complet est présenté à la demande, sans déclencher de requête.
private struct MapCoverageKeyControl: View {
    let byGeneration: Bool
    let onOpen: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var modeTitle: String {
        byGeneration ? String(localized: "Génération") : String(localized: "Signal")
    }

    var body: some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            HStack(spacing: SQSpace.sm) {
                swatches
                    .id(byGeneration)
                    .transition(.opacity)
                    .accessibilityHidden(true)
                Text(modeTitle)
                    .font(SQFont.body(13, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(SQColor.label)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs)
            .frame(minHeight: 44)
            .background(SQColor.surface, in: Capsule())
            .sqShadowSoft()
            .animation(SQMotion.resolve(SQMotion.fast, reduceMotion), value: byGeneration)
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("Couverture")
        .accessibilityValue(modeTitle)
        .accessibilityHint("Choisir les couleurs et consulter la légende")
        .accessibilityIdentifier("map.coverage.legend")
    }

    private var swatches: some View {
        HStack(spacing: 2) {
            if byGeneration {
                ForEach(CoverageGenerationBand.visibleBands) { band in
                    Capsule().fill(band.swiftUIColor).frame(width: 4, height: 14)
                }
            } else {
                ForEach(CoverageQualityBand.visibleBands) { band in
                    if band.isHatched {
                        SQHatchedSwatch(color: band.swiftUIColor).clipShape(Capsule()).frame(width: 4, height: 14)
                    } else {
                        Capsule().fill(band.swiftUIColor).frame(width: 4, height: 14)
                    }
                }
            }
        }
    }
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

private struct MapCoverageDetails: View {
    @Binding var byGeneration: Bool
    let marketCode: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: SQSpace.xs) {
                            accessibleMode("Signal", value: false)
                            accessibleMode("Génération", value: true)
                        }
                    } else {
                        Picker("Coloration couverture", selection: $byGeneration) {
                            Text("Signal").tag(false)
                            Text("Génération").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("map.coverage.mode")
                    }
                    VStack(alignment: .leading, spacing: SQSpace.md) {
                        if byGeneration {
                            ForEach(CoverageGenerationBand.visibleBands) { band in
                                legendEntry(band.title(forMarket: marketCode), color: band.swiftUIColor)
                            }
                        } else {
                            ForEach(CoverageQualityBand.visibleBands) { band in
                                legendEntry(band.title, color: band.swiftUIColor, hatched: band.isHatched)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(byGeneration)
                    .transition(.opacity)
                    .animation(SQMotion.resolve(SQMotion.fast, reduceMotion), value: byGeneration)
                }
                .padding(SQSpace.xl)
            }
            .background(SQColor.surface)
            .navigationTitle("Couverture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                        .tint(SQColor.accentInk)
                        .accessibilityIdentifier("map.coverage.legend.close")
                }
            }
        }
    }

    private func accessibleMode(_ title: LocalizedStringKey, value: Bool) -> some View {
        Button { byGeneration = value } label: {
            HStack(spacing: SQSpace.md) {
                Text(title).font(SQType.subhead)
                Spacer(minLength: SQSpace.sm)
                Image(systemName: byGeneration == value ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(byGeneration == value ? SQColor.accentInk : SQColor.labelSecondary)
            }
            .foregroundStyle(SQColor.label)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityAddTraits(byGeneration == value ? .isSelected : [])
    }

    private func legendEntry(_ title: String, color: Color, hatched: Bool = false) -> some View {
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
            HStack(spacing: SQSpace.xs + 2) {
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
            .background(SQColor.surface, in: Capsule())
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
        NavigationStack {
            ScrollView {
                Text(messages.joined(separator: "\n\n"))
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(SQSpace.xl)
                    .accessibilityIdentifier("map.status.limit.detail")
            }
            .background(SQColor.surface)
            .navigationTitle("Vue partielle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                        .tint(SQColor.accentInk)
                        .accessibilityIdentifier("map.status.limit.close")
                }
            }
        }
    }
}
