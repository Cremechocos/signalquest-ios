import SwiftUI

/// Une explication : ce que la grandeur veut dire, un exemple, des repères et,
/// pour les fiches antenne, la lecture de la valeur en cours et un schéma.
///
/// Généralise l'ancienne entrée des fiches antenne : « Dégagement Fresnel :
/// 312 % » ne disait rien sans explication, et le reste de l'app avait le même
/// problème avec RSRP, gigue ou 5G NSA.
struct SQGlossaryEntry: Identifiable, Equatable {
    var id: String { title }
    let title: String
    /// Ce que la grandeur mesure, en une ou deux phrases simples.
    let definition: String
    /// Un cas concret, quand il aide.
    var example: String? = nil
    /// Lecture de la valeur en cours — nil quand elle est inconnue.
    var reading: String? = nil
    /// Repères chiffrés, quand ils aident à situer la valeur.
    var scale: [(String, String)] = []
    /// Schéma, quand la grandeur se montre mieux qu'elle ne se décrit.
    var illustration: AntennaGlossaryIllustration? = nil
    /// Termes proposés pour aller plus loin.
    var related: [SQTerm] = []

    static func == (lhs: SQGlossaryEntry, rhs: SQGlossaryEntry) -> Bool {
        lhs.title == rhs.title && lhs.reading == rhs.reading
    }
}

/// Explication d'un terme, en feuille sur iPhone et en popover sur iPad. Les
/// termes liés s'ouvrent sur place, sans empiler de feuilles.
struct SQGlossarySheet: View {
    @State private var entry: SQGlossaryEntry
    @Environment(\.dismiss) private var dismiss

    init(entry: SQGlossaryEntry) {
        _entry = State(initialValue: entry)
    }

    init(term: SQTerm) {
        self.init(entry: term.entry)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    if let reading = entry.reading {
                        Text(reading)
                            .font(SQType.heading)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(SQSpace.lg)
                            .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                    }

                    if let illustration = entry.illustration {
                        AntennaGlossaryIllustrationView(illustration: illustration)
                    }

                    Text(entry.definition)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .fixedSize(horizontal: false, vertical: true)

                    if let example = entry.example {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Par exemple").sqKicker()
                            Text(example)
                                .font(SQType.body)
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !entry.scale.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Repères").sqKicker()
                            ForEach(entry.scale, id: \.0) { bound, meaning in
                                HStack(alignment: .top, spacing: SQSpace.md) {
                                    Text(bound)
                                        .font(SQFont.archivo(12.5, .bold))
                                        .foregroundStyle(SQColor.accentInk)
                                        // « −90 à −100 dBm » tient sur une ligne.
                                        .frame(width: 116, alignment: .leading)
                                    Text(meaning)
                                        .font(SQType.caption)
                                        .foregroundStyle(SQColor.labelSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SQSpace.lg)
                        .sqCardBackground()
                    }

                    if !entry.related.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Voir aussi").sqKicker()
                            ForEach(entry.related) { term in
                                Button {
                                    Haptics.light()
                                    entry = term.entry
                                } label: {
                                    Label(term.entry.title, systemImage: "arrow.right.circle")
                                        .font(SQType.body)
                                        .foregroundStyle(SQColor.accentInk)
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(SQSpace.lg + 2)
            }
            .signalQuestBackground()
            .navigationTitle(entry.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                        .tint(SQColor.brandRed)
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 400, minHeight: 360, idealHeight: 520)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// ⓘ posé à côté d'un terme technique : l'explique sans quitter l'écran.
/// Glyphe discret, mais zone de toucher de 44 pt ; à placer seulement à la
/// première occurrence du terme dans un écran, après son libellé en clair.
struct SQInfoButton: View {
    let term: SQTerm
    @State private var isPresented = false

    var body: some View {
        Button {
            Haptics.light()
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .padding(15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-15)
        .accessibilityLabel(Text("Qu’est-ce que « \(term.entry.title) » ?"))
        .popover(isPresented: $isPresented) {
            SQGlossarySheet(term: term)
        }
    }
}

/// Tuile de mesure partagée (TRX-11) : libellé, valeur, unité, et au besoin
/// une icône, une précision et le ⓘ du terme affiché. VoiceOver lit « libellé :
/// valeur unité » d'un bloc et propose l'action « Expliquer ».
///
/// La valeur reste à l'encre, en brique (`accentInk`) si `highlight` : une
/// couleur de débit ou de qualité ne tient pas 4,5:1 sur la tuile. La couleur
/// qui porte le sens (réception, envoi, latence) va à l'icône.
struct SQMetricTile: View {
    enum Size {
        /// Figtree Bold 17 : grilles de stats.
        case regular
        /// Bricolage Bold 22, chiffres alignés : résultats d'une mesure.
        case large
    }

    let label: String
    let value: String
    var unit: String? = nil
    var term: SQTerm? = nil
    var highlight = false
    var icon: String? = nil
    var iconTint: Color = SQColor.labelSecondary
    var detail: String? = nil
    var size: Size = .regular
    /// Prend la hauteur que lui donne sa rangée (`HStack` en `fixedSize`) :
    /// des tuiles voisines de même hauteur, même si un libellé passe à la ligne.
    var fillsHeight = false

    var body: some View {
        SQMetricTileContent(
            label: label, value: value, unit: unit, highlight: highlight, icon: icon, iconTint: iconTint,
            detail: detail, size: size, fillsHeight: fillsHeight
        ) {
            if let term {
                SQInfoButton(term: term)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(label)) + Text(verbatim: " : ") + Text(verbatim: spokenValue))
        .modifier(SQOptionalExplains(term: term))
    }

    private var spokenValue: String {
        [[value, unit].compactMap { $0 }.joined(separator: " "), detail]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// Le dessin de la tuile, sans ses règles d'accessibilité : partagé avec les
/// tuiles qui ouvrent autre chose (fiche antenne).
struct SQMetricTileContent<Trailing: View>: View {
    let label: String
    let value: String
    var unit: String? = nil
    var highlight = false
    var icon: String? = nil
    var iconTint: Color = SQColor.labelSecondary
    var detail: String? = nil
    var size: SQMetricTile.Size = .regular
    var fillsHeight = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(iconTint)
                }
                Text(LocalizedStringKey(label))
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                trailing()
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(valueFont)
                    .foregroundStyle(highlight ? SQColor.accentInk : SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            if let detail {
                Text(detail)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .padding(SQSpace.md)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private var valueFont: Font {
        switch size {
        case .regular: return SQFont.archivo(17, .bold)
        case .large: return SQFont.display(22, .bold).monospacedDigit()
        }
    }
}

extension SQMetricTileContent where Trailing == EmptyView {
    init(
        label: String, value: String, unit: String? = nil, highlight: Bool = false, icon: String? = nil,
        iconTint: Color = SQColor.labelSecondary, detail: String? = nil, size: SQMetricTile.Size = .regular,
        fillsHeight: Bool = false
    ) {
        self.init(
            label: label, value: value, unit: unit, highlight: highlight, icon: icon, iconTint: iconTint,
            detail: detail, size: size, fillsHeight: fillsHeight, trailing: { EmptyView() }
        )
    }
}

private struct SQOptionalExplains: ViewModifier {
    let term: SQTerm?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let term {
            content.sqExplains(term)
        } else {
            content
        }
    }
}

extension View {
    /// Action VoiceOver « Expliquer » sur l'élément qui porte le terme : le lecteur
    /// d'écran n'a pas à chercher le ⓘ à côté.
    func sqExplains(_ term: SQTerm) -> some View {
        modifier(SQExplainsModifier(term: term))
    }
}

private struct SQExplainsModifier: ViewModifier {
    let term: SQTerm
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text("Expliquer")) { isPresented = true }
            .sheet(isPresented: $isPresented) { SQGlossarySheet(term: term) }
    }
}

/// Profil › Aide et glossaire : tous les termes, par famille, avec une recherche.
struct SQGlossaryView: View {
    @State private var query = ""
    @State private var selected: SQTerm?

    private var groups: [(group: SQGlossaryGroup, terms: [SQTerm])] {
        SQGlossaryGroup.allCases.compactMap { group in
            let terms = SQTerm.allCases.filter { $0.group == group && matches($0) }
            return terms.isEmpty ? nil : (group, terms)
        }
    }

    private func matches(_ term: SQTerm) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        let entry = term.entry
        return entry.title.localizedStandardContains(text) || entry.definition.localizedStandardContains(text)
    }

    var body: some View {
        List {
            ForEach(groups, id: \.group) { item in
                Section {
                    ForEach(item.terms) { term in
                        Button {
                            selected = term
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(term.entry.title)
                                    .font(SQType.body.weight(.semibold))
                                    .foregroundStyle(SQColor.label)
                                Text(term.entry.definition)
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(SQColor.surface)
                        .accessibilityIdentifier("glossary.term.\(term.rawValue)")
                    }
                } header: {
                    Text(item.group.title)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .signalQuestBackground()
        .overlay {
            if groups.isEmpty {
                EmptyStateView(
                    title: String(localized: "Aucun terme trouvé"),
                    message: String(localized: "Essaie un autre mot, par exemple « signal » ou « débit »."),
                    systemImage: "magnifyingglass"
                )
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Rechercher un terme"))
        .navigationTitle("Aide et glossaire")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { term in
            SQGlossarySheet(term: term)
        }
    }
}
