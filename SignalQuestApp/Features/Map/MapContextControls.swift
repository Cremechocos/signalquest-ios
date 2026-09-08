import SwiftUI

/// La présentation reste attachée à cet ancêtre stable quand la rangée se
/// replie, quand le mode change de largeur ou pendant un redimensionnement iPad.
struct MapContextControls: View {
    @Binding var byGeneration: Bool
    let showsCoverage: Bool
    let limitMessages: [String]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentedPanel: Panel?

    private enum Panel: String, Identifiable {
        case coverage, limits
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
                    MapCoverageDetails(byGeneration: $byGeneration)
                        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(360), .medium, .large])
                case .limits:
                    MapDisplayLimitDetails(messages: limitMessages)
                        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(240), .medium, .large])
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
                    Capsule().fill(band.swiftUIColor).frame(width: 4, height: 14)
                }
            }
        }
    }
}

private struct MapCoverageDetails: View {
    @Binding var byGeneration: Bool
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
                                legendEntry(band.title, color: band.swiftUIColor)
                            }
                        } else {
                            ForEach(CoverageQualityBand.visibleBands) { band in
                                legendEntry(band.title, color: band.swiftUIColor)
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

    private func legendEntry(_ title: String, color: Color) -> some View {
        HStack(spacing: SQSpace.md) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 24, height: 8)
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
