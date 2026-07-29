import SwiftUI

private typealias M = RadioLogsMetrics
private typealias P = RadioLogsPalette

/// « Trier et filtrer » — le tri devient un réglage de premier plan, plus un
/// comportement figé. Chaque option dit ce qu'elle FAIT : « Pertinence » sans
/// explication ne veut rien dire pour qui ouvre la feuille la première fois.
struct RadioLogsFilterSheet: View {
    @ObservedObject var model: RadioLogsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SQSheetHandle()

                Text("Trier et filtrer")
                    .font(SQFont.display(M.sheetTitleSize, .bold))
                    .foregroundStyle(P.ink)
                Text("\(model.totalCount.formatted()) sites · \(model.logCount.formatted()) relevés")
                    .font(SQFont.body(M.sheetSubtitleSize))
                    .monospacedDigit()
                    .foregroundStyle(P.muted)
                    .padding(.bottom, M.sheetSubtitleBottom)

                group("Trier par") {
                    FlowOptions(
                        options: RadioLogsViewModel.SortOrder.allCases.map {
                            Option(id: $0.id, label: $0.label, hint: $0.hint, isOn: model.sortOrder == $0)
                        }
                    ) { id in
                        guard let value = RadioLogsViewModel.SortOrder(rawValue: id) else { return }
                        model.sortOrder = value
                        Haptics.selection()
                    }
                }

                group("N'afficher que") {
                    FlowOptions(
                        options: RadioLogsViewModel.Filter.allCases.map {
                            Option(
                                id: $0.id,
                                label: "\($0.label) · \(model.count(for: $0).formatted())",
                                hint: nil,
                                isOn: model.filter == $0
                            )
                        }
                    ) { id in
                        guard let value = RadioLogsViewModel.Filter(rawValue: id) else { return }
                        model.filter = value
                        Haptics.selection()
                    }
                }

                toggleRow(
                    title: "Grouper par opérateur",
                    hint: "SFR, Orange, Free, Bouygues",
                    isOn: $model.groupByOperator
                )
                toggleRow(
                    title: "Vérifier en données mobiles",
                    hint: "une passe complète représente quelques dizaines de requêtes",
                    isOn: $model.scanOnCellular
                )
            }
            .padding(.horizontal, M.sheetPaddingH)
            .padding(.bottom, M.sheetPaddingBottom)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .presentationDetentsCompat()
    }

    // MARK: Briques

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(SQFont.body(M.groupHeaderSize, .bold))
                .foregroundStyle(P.muted)
                .padding(.bottom, M.groupHeaderBottom)
            content()
        }
        .padding(.bottom, M.groupBottom)
    }

    private func toggleRow(title: String, hint: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: M.toggleRowGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SQFont.body(M.toggleLabelSize, .semibold))
                    .foregroundStyle(P.ink)
                Text(hint)
                    .font(SQFont.body(M.toggleHintSize))
                    .foregroundStyle(P.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(P.accent)
        }
        .padding(.vertical, M.toggleRowPaddingV)
        .overlay(alignment: .top) {
            Rectangle().fill(P.hair).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    struct Option: Identifiable {
        let id: String
        let label: String
        let hint: String?
        let isOn: Bool
    }

    /// `.opts` — options qui reviennent à la ligne quand elles ne tiennent pas.
    /// Écrit à la main plutôt qu'avec un `Grid` : le nombre d'options par ligne
    /// dépend de la longueur des libellés, qui change avec la langue et la taille
    /// de police choisie par l'utilisateur.
    struct FlowOptions: View {
        let options: [Option]
        let onSelect: (String) -> Void

        var body: some View {
            FlowLayoutCompat(spacing: M.optionGap) {
                ForEach(options) { option in
                    Button {
                        onSelect(option.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(SQFont.body(M.optionSize, .semibold))
                            if let hint = option.hint {
                                Text(hint)
                                    .font(SQFont.body(M.optionHintSize))
                                    .opacity(0.75)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(option.isOn ? P.accentInk : P.chipInk)
                        .padding(.horizontal, M.optionPaddingH)
                        .padding(.vertical, M.optionPaddingV)
                        .background {
                            RoundedRectangle(cornerRadius: M.optionRadius, style: .continuous)
                                .fill(option.isOn ? P.accentSoft : P.chip)
                                .overlay {
                                    if option.isOn {
                                        RoundedRectangle(cornerRadius: M.optionRadius, style: .continuous)
                                            .strokeBorder(P.accent.opacity(0.34), lineWidth: 1)
                                    }
                                }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option.isOn ? .isSelected : [])
                }
            }
        }
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
