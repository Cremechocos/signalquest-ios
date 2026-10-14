import SwiftUI

private typealias M = RadioLogsMetrics
private typealias P = RadioLogsPalette

/// « Trier et afficher » — le tri et les deux réglages de la page. Le filtre
/// Tous / Identifiés / À identifier n'y figure plus : il reste sur la page, en
/// segment, et l'avoir aux deux endroits ne disait pas lequel faisait foi.
/// Chaque option dit ce qu'elle FAIT, pas seulement son nom.
struct RadioLogsFilterSheet: View {
    @ObservedObject var model: RadioLogsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.xl) {
                header

                section("Trier par") {
                    VStack(spacing: 0) {
                        ForEach(Array(RadioLogsViewModel.SortOrder.allCases.enumerated()), id: \.element.id) { index, order in
                            if index > 0 { divider }
                            sortRow(order)
                        }
                    }
                    .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
                }

                section("Présentation") {
                    VStack(spacing: 0) {
                        toggleRow(
                            title: "Grouper par opérateur",
                            hint: "SFR, Orange, Free, Bouygues Telecom",
                            isOn: $model.groupByOperator,
                            identifier: "radioLogs.sort.group"
                        )
                        divider
                        toggleRow(
                            title: "Vérifier en données mobiles",
                            hint: "Une vérification complète fait quelques dizaines de requêtes.",
                            isOn: $model.scanOnCellular,
                            identifier: "radioLogs.sort.cellular"
                        )
                    }
                    .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
                }

                if !model.hasDefaultDisplaySettings {
                    Button {
                        model.resetDisplaySettings()
                        Haptics.selection()
                    } label: {
                        Text("Revenir aux réglages par défaut")
                            .font(SQFont.body(15, .semibold))
                            .foregroundStyle(SQColor.accentInk)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("radioLogs.sort.reset")
                }
            }
            .padding(.horizontal, M.sheetPaddingH)
            .padding(.top, SQSpace.xl)
            .padding(.bottom, M.sheetPaddingBottom)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .presentationDetentsCompat()
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("radioLogs.sortSheet")
    }

    // MARK: Briques

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Trier et afficher")
                    .font(SQFont.display(22, .bold, relativeTo: .title2))
                    .foregroundStyle(P.ink)
                    .sqHeader()
                Text(verbatim: [String(localized: "\(model.totalCount) site"), String(localized: "\(model.logCount) relevé")].joined(separator: " · "))
                    .font(SQType.callout)
                    .monospacedDigit()
                    .foregroundStyle(P.muted)
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Text("OK")
                    .font(SQFont.body(15, .bold))
                    .foregroundStyle(SQColor.onAccent)
                    .padding(.horizontal, SQSpace.lg)
                    .frame(minHeight: 44)
                    .background(SQColor.brandRed, in: Capsule(style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityIdentifier("radioLogs.sort.done")
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title).sqKicker()
            content()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(SQColor.separator)
            .frame(height: 1)
            .padding(.leading, SQSpace.md)
    }

    private func sortRow(_ order: RadioLogsViewModel.SortOrder) -> some View {
        let isOn = model.sortOrder == order
        return Button {
            model.sortOrder = order
            Haptics.selection()
        } label: {
            HStack(spacing: SQSpace.md) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(order.label)
                        .font(SQFont.body(15, .semibold))
                        .foregroundStyle(P.ink)
                    Text(order.hint)
                        .font(SQType.caption)
                        .foregroundStyle(P.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(SQColor.accentInk)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("radioLogs.sort.\(order.rawValue)")
    }

    private func toggleRow(title: LocalizedStringKey, hint: LocalizedStringKey, isOn: Binding<Bool>, identifier: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(SQFont.body(15, .semibold))
                    .foregroundStyle(P.ink)
                Text(hint)
                    .font(SQType.caption)
                    .foregroundStyle(P.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(P.accent)
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.sm)
        .frame(minHeight: 56)
        .accessibilityIdentifier(identifier)
    }
}

/// Disposition en flot. `Layout` n'existe qu'à partir d'iOS 16 — la cible de
/// l'app — donc pas de repli à écrire, mais le nom garde le suffixe `Compat`
/// utilisé partout ailleurs pour les vues qui encapsulent une API versionnée.
struct FlowLayoutCompat: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var rowHeights: [CGFloat] = [0]
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let current = rows[rows.count - 1]
            let candidate = current == 0 ? size.width : current + spacing + size.width
            if candidate > maxWidth, current > 0 {
                rows.append(size.width)
                rowHeights.append(size.height)
            } else {
                rows[rows.count - 1] = candidate
                rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
            }
        }
        let height = rowHeights.reduce(0, +) + spacing * CGFloat(max(0, rowHeights.count - 1))
        return CGSize(width: rows.max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension View {
    /// Feuille à hauteur moyenne, redimensionnable. `presentationDetents` exige
    /// iOS 16 — la cible — mais l'appel reste isolé ici pour que le jour où l'on
    /// remonte la cible, il n'y ait qu'un endroit à toucher.
    func presentationDetentsCompat() -> some View {
        presentationDetents([.medium, .large])
    }
}
