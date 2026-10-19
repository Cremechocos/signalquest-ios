import SwiftUI

@MainActor
final class MyIdentificationsViewModel: ObservableObject {
    @Published var items: [MyIdentification] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var withdrawingId: String?
    @Published var filter: Filter = .all { didSet { rebuild() } }
    @Published var toast: String?

    enum Filter: String, CaseIterable, Identifiable {
        case all, lte, nr
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return String(localized: "Toutes")
            case .lte: return "4G"
            case .nr: return "5G"
            }
        }
    }

    private let service: IdentifyServicing
    init(service: IdentifyServicing) { self.service = service }

    var filtered: [MyIdentification] { items(for: filter) }

    private func items(for filter: Filter) -> [MyIdentification] {
        switch filter {
        case .all: return items
        case .lte: return items.filter { $0.kind == .enb || $0.techLabel == "4G" }
        case .nr: return items.filter { $0.kind == .gnb || $0.techLabel == "5G" }
        }
    }

    /// Regroupement en nœuds, CALCULÉ UNE FOIS par changement d'entrée.
    ///
    /// En propriété calculée, `IdentifiedNodeGroup.group` — qui construit un
    /// dictionnaire, agrège les cellules et trie deux fois — repartait à chaque
    /// évaluation du `body`, donc à chaque frappe, chaque retrait, chaque
    /// bascule de filtre, et plusieurs fois par passe (la liste ET son état vide
    /// le lisent).
    @Published private(set) var filteredGroups: [IdentifiedNodeGroup] = []
    @Published private(set) var conflictCount = 0
    /// Nombre d'antennes par filtre, affiché dans le segment (« 4G · 9 »).
    @Published private(set) var counts: [Filter: Int] = [:]

    private func rebuild() {
        filteredGroups = IdentifiedNodeGroup.group(filtered)
        conflictCount = items.filter(\.conflict).count
        counts = Dictionary(uniqueKeysWithValues: Filter.allCases.map { filter in
            (filter, IdentifiedNodeGroup.group(items(for: filter)).count)
        })
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await service.mine(includeRelated: true)
            items = result.sorted { ($0.lastValidated ?? $0.createdAt ?? .distantPast) > ($1.lastValidated ?? $1.createdAt ?? .distantPast) }
            rebuild()
        } catch {
            if !error.isCancellation { errorMessage = error.userFacingMessage }
        }
    }

    func withdraw(_ item: MyIdentification) async {
        withdrawingId = item.id
        defer { withdrawingId = nil }
        do {
            let result = try await service.withdraw(
                siteId: item.siteId,
                enb: item.enb, gnb: item.gnb,
                pci: item.pciValue,
                cellId: item.cellId, ci: item.ci,
                tech: item.tech, reason: nil
            )
            if result.success {
                await load()
                toast = String(localized: "Identification retirée")
                Haptics.success()
            } else {
                toast = String(localized: "Retrait impossible")
                Haptics.error()
            }
        } catch {
            // En toast, visible à la fermeture de la fiche : la ligne d'erreur en
            // bas de liste passait inaperçue et laissait croire au retrait.
            toast = error.userFacingMessage
            Haptics.error()
        }
    }

    /// Suppression DÉFINITIVE (hard delete) des contributions solo de l'utilisateur.
    /// Les lignes confirmées par autrui sont seulement retirées (soft) côté serveur —
    /// on l'indique alors dans le toast pour ne pas laisser croire à un effacement total.
    func delete(_ item: MyIdentification) async {
        withdrawingId = item.id
        defer { withdrawingId = nil }
        do {
            let result = try await service.delete(
                siteId: item.siteId,
                enb: item.enb, gnb: item.gnb,
                pci: item.pciValue,
                cellId: item.cellId, ci: item.ci,
                tech: item.tech, reason: nil
            )
            if result.success {
                await load()
                toast = (result.deleted == 0 && result.softWithdrawn > 0)
                    ? String(localized: "Retirée : des cellules sont confirmées par d’autres")
                    : String(localized: "Identification supprimée")
                Haptics.success()
            } else {
                toast = String(localized: "Suppression impossible")
                Haptics.error()
            }
        } catch {
            // En toast, visible à la fermeture de la fiche : la ligne d'erreur en
            // bas de liste passait inaperçue et laissait croire au retrait.
            toast = error.userFacingMessage
            Haptics.error()
        }
    }
}

/// « Mes identifications » — les cellules→sites que l'utilisateur a identifiées
/// (compte partagé : inclut celles faites sur Android). Consultation + retrait.
struct MyIdentificationsView: View {
    @StateObject private var model: MyIdentificationsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingWithdraw: MyIdentification?
    @State private var selected: MyIdentification?

    init(service: IdentifyServicing) {
        _model = StateObject(wrappedValue: MyIdentificationsViewModel(service: service))
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: 0, bottom: SQSpace.xs, trailing: 0))
                    .listRowBackground(Color.clear)
                SQSegmentedFilter(
                    selection: $model.filter,
                    options: MyIdentificationsViewModel.Filter.allCases.map { filter in
                        (value: filter, label: segmentLabel(filter), icon: String?.none)
                    }
                )
                .accessibilityIdentifier("identifications.filter")
                // Le segment ajoute sa propre marge latérale de 16 pt : on la compense.
                .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: -SQSpace.lg, bottom: SQSpace.xs, trailing: -SQSpace.lg))
                .listRowBackground(Color.clear)

                if model.conflictCount > 0 {
                    conflictNote
                        .listRowInsets(EdgeInsets(top: SQSpace.xs, leading: 0, bottom: SQSpace.xs, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
            .listRowSeparator(.hidden)

            if model.filteredGroups.isEmpty && !model.isLoading, let errorMessage = model.errorMessage {
                // Un échec n'est pas une liste vide : « Aucune identification »
                // au-dessus de l'erreur se contredisait (AF-RAD-16).
                ErrorStateView(title: "Identifications indisponibles", message: errorMessage) {
                    Task { await model.load() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } else if model.filteredGroups.isEmpty && !model.isLoading {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } else {
                ForEach(model.filteredGroups) { group in
                    Section {
                        // Sans nœud, aucune ligne ne représente le groupe : seules ses
                        // cellules s'ouvrent et se retirent.
                        if group.kind != .unassigned {
                            Button {
                                selected = group.representative
                            } label: {
                                IdentificationNodeRow(group: group, isWithdrawing: model.withdrawingId == group.representative.id)
                            }
                                .buttonStyle(.plain)
                                .listRowBackground(SQColor.surface)
                                .listRowSeparatorTint(SQColor.separator)
                                .contentShape(Rectangle())
                                .accessibilityHint("Ouvre le détail de cette identification")
                                .accessibilityIdentifier("identifications.node.\(group.id)")
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingWithdraw = group.representative
                                    } label: {
                                        Label("Retirer", systemImage: "trash")
                                    }
                                }
                        }

                        ForEach(group.cells) { cell in
                            Button {
                                selected = cell.source
                            } label: {
                                IdentificationCellRow(
                                    cell: cell,
                                    isWithdrawing: model.withdrawingId == cell.source.id,
                                    indented: group.kind != .unassigned
                                )
                            }
                                .buttonStyle(.plain)
                                .listRowBackground(SQColor.surface)
                                .listRowSeparatorTint(SQColor.separator)
                                .contentShape(Rectangle())
                                .accessibilityHint("Ouvre le détail de cette cellule")
                                .accessibilityIdentifier("identifications.cell.\(cell.id)")
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingWithdraw = cell.source
                                    } label: {
                                        Label("Retirer", systemImage: "trash")
                                    }
                                }
                        }

                        if group.cells.isEmpty {
                            Text("Aucun identifiant de cellule (PCI/CI) associé à cette antenne.")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .padding(.leading, IdentificationNodeRow.textInset)
                                .listRowBackground(SQColor.surface)
                        }
                    } header: {
                        if group.kind == .unassigned {
                            Text(group.title).sqKicker()
                        }
                    }
                }
            }

            if let errorMessage = model.errorMessage, !model.filteredGroups.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.dangerInk)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .modifier(CompactListMargins())
        .scrollContentBackground(.hidden)
        .sqReadableWidth()
        .signalQuestBackground()
        .navigationTitle("Mes identifications")
        .toolbar(.hidden, for: .navigationBar)
        // Barre masquée : le balayage retour est rétabli, comme sur les autres écrans Halo.
        .sqKeepsSwipeBack()
        .refreshable { await model.load() }
        .overlay {
            if model.isLoading && model.items.isEmpty { SQSpinner().tint(SQColor.brandRed) }
        }
        .task { if model.items.isEmpty { await model.load() } }
        .confirmationDialog(
            "Retirer cette identification ?",
            isPresented: Binding(get: { pendingWithdraw != nil }, set: { if !$0 { pendingWithdraw = nil } }),
            presenting: pendingWithdraw
        ) { item in
            Button("Retirer", role: .destructive) {
                Task { await model.withdraw(item); pendingWithdraw = nil }
            }
            Button("Annuler", role: .cancel) { pendingWithdraw = nil }
        } message: { item in
            Text("« \(item.nodeLabel) » ne te sera plus attribuée. Tu pourras la ré-identifier.")
        }
        .sheet(item: $selected) { item in
            IdentificationDetailSheet(
                item: item,
                isWithdrawing: model.withdrawingId == item.id,
                onWithdraw: {
                    Task {
                        await model.withdraw(item)
                        selected = nil
                    }
                },
                onDelete: {
                    Task {
                        await model.delete(item)
                        selected = nil
                    }
                },
                onChanged: {
                    selected = nil
                    Task { await model.load() }
                }
            )
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(SQFont.body(13, .semibold))
                    .foregroundStyle(SQColor.onInk)
                    .padding(.horizontal, SQSpace.md).padding(.vertical, SQSpace.sm)
                    .background(SQColor.label, in: Capsule(style: .continuous))
                    .sqShadowCard()
                    .padding(.bottom, SQSpace.lg)
                    .accessibilityIdentifier("identifications.toast")
                    // Un message qui en remplace un autre relance la minuterie.
                    .task(id: toast) {
                        guard (try? await Task.sleep(nanoseconds: 2_200_000_000)) != nil else { return }
                        model.toast = nil
                    }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            MapChipIconButton(systemImage: "chevron.left", label: "Retour", identifier: "identifications.back") { dismiss() }
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Mes identifications")
                    .font(SQFont.display(28, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(SQColor.label)
                    .sqHeader()
                    .accessibilityIdentifier("identifications.title")
                Text("Les antennes que tu as reliées à un site, ici et sur Android.")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// « Toutes · 14 » : le nombre n'apparaît qu'une fois la liste chargée.
    private func segmentLabel(_ filter: MyIdentificationsViewModel.Filter) -> String {
        guard let count = model.counts[filter] else { return filter.label }
        return "\(filter.label) · \(count.formatted())"
    }

    private var conflictNote: some View {
        HStack(alignment: .top, spacing: SQSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OutageTint.degradedInk)
                .accessibilityHidden(true)
            // AttributedString : le gras d'une variante plurielle n'est pas interprété par Text.
            Text(AttributedString(localized: "**\(model.conflictCount) identification en conflit** : un autre site a plus de validations sur cette antenne. Vérifie-la ou retire-la."))
                .font(SQType.caption)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.warningSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("identifications.conflicts")
    }

    private var emptyState: some View {
        EmptyStateView(
            title: "Aucune identification",
            message: "Identifie une antenne depuis une session ou la carte. Tes identifications, y compris depuis Android, apparaîtront ici.",
            systemImage: "checkmark.seal"
        )
    }
}

/// Pastille de génération (« 4G », « 5G ») aux couleurs de la carte et des fiches.
private struct GenerationTile: View {
    let label: String
    var size: CGFloat = 44

    @Environment(\.colorScheme) private var colorScheme

    private var color: Color { SQBrand.techColor(label == "5G" ? "5G" : "4G") }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                .fill(color)
            Text(label)
                .font(SQFont.display(size > 48 ? 14 : 12, .bold))
                .foregroundStyle(SQBrand.operatorBadgeForeground(for: color, colorScheme: colorScheme))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Pastille « Conflit » : point de couleur et mot, comme les statuts du lot.
private struct ConflictPill: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(SQColor.warning).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text("Conflit")
        }
        .font(SQFont.body(12, .bold, relativeTo: .caption))
        .foregroundStyle(OutageTint.degradedInk)
        .padding(.horizontal, SQSpace.sm)
        .padding(.vertical, 3)
        .background(SQColor.warning.opacity(0.14), in: Capsule(style: .continuous))
        .fixedSize()
    }
}

private struct IdentificationNodeRow: View {
    let group: IdentifiedNodeGroup
    let isWithdrawing: Bool

    /// Retrait des cellules : leur pastille s'aligne sur le texte du nœud.
    static let textInset: CGFloat = 44 + SQSpace.md

    var body: some View {
        HStack(spacing: SQSpace.md) {
            GenerationTile(label: group.kind == .gnb ? "5G" : "4G")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: SQSpace.sm) {
                    Text(group.title)
                        .font(SQFont.body(15, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                        .sqSingleLine()
                    if group.conflict { ConflictPill() }
                }
                Text(group.subtitle)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(2)
                HStack(spacing: SQSpace.md) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill").accessibilityHidden(true)
                        Text("Validée \(group.validations) fois")
                    }
                    .foregroundStyle(OutageTint.resolvedInk)
                    if !group.sectorsUnion.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "dot.radiowaves.right").accessibilityHidden(true)
                            Text("\(group.sectorsUnion.count) secteurs")
                        }
                    }
                }
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            if isWithdrawing { SQSpinner() }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, SQSpace.xs)
        .accessibilityElement(children: .combine)
    }
}

private struct IdentificationCellRow: View {
    let cell: IdentifiedCell
    let isWithdrawing: Bool
    var indented = true

    /// « Secteur 2 · CI 160466202 » ; plusieurs secteurs restent listés.
    private var detail: Text? {
        var parts: [Text] = []
        if cell.sectors.count == 1, let sector = cell.sectors.first {
            parts.append(Text("Secteur \(sector)"))
        } else if !cell.sectors.isEmpty {
            parts.append(Text("Secteurs \(cell.sectors.map(String.init).joined(separator: ", "))"))
        }
        if let ci = cell.ci { parts.append(Text(verbatim: "CI \(ci)").monospacedDigit()) }
        guard var line = parts.first else { return nil }
        for part in parts.dropFirst() { line = line + Text(verbatim: " · ") + part }
        return line
    }

    var body: some View {
        HStack(spacing: SQSpace.sm2) {
            Image(systemName: "dot.radiowaves.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SQColor.accentInk)
                .frame(width: 30, height: 30)
                .background(SQColor.accentSoft, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(cell.label)
                    .font(SQFont.body(14, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                if let detail {
                    detail
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if isWithdrawing { SQSpinner() }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SQColor.labelTertiary)
                .accessibilityHidden(true)
        }
        .padding(.leading, indented ? IdentificationNodeRow.textInset : 0)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Fiche détaillée d'une identification : tous les identifiants radio + retrait.
private struct IdentificationDetailSheet: View {
    let item: MyIdentification
    let isWithdrawing: Bool
    let onWithdraw: () -> Void
    var onDelete: () -> Void = {}
    var onChanged: () -> Void = {}

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingWithdraw = false
    @State private var confirmingDelete = false
    @State private var showRemap = false
    @State private var showSector = false
    @State private var adoptBusy = false
    @State private var adoptError: String?

    private var is5G: Bool { item.kind == .gnb || item.techLabel == "5G" }
    /// Ré-attribution de site : seulement pour les nœuds eNB/gNB.
    private var canRemapSite: Bool { (item.kind == .enb || item.kind == .gnb) && (item.enb != nil || item.gnb != nil) }
    /// Correction de secteur : pour les cellules (PCI/CellID).
    private var canEditSector: Bool { item.kind == .pci || item.kind == .cellid }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapSheetHeader(title: "Identification", closeIdentifier: "identification.close") { dismiss() }
                header
                if item.conflict {
                    conflictSection
                }
                detailsCard
                editSection
                withdrawBlock
                dangerZone
            }
            .padding(SQSpace.lg)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .sheet(isPresented: $showRemap) {
            SiteRemapSheet(
                item: item,
                antennas: services.antennas,
                identify: services.identify,
                location: services.location,
                markets: services.markets,
                onDone: { onChanged(); dismiss() }
            )
        }
        .sheet(isPresented: $showSector) {
            SectorEditSheet(
                item: item,
                antennas: services.antennas,
                identify: services.identify,
                onDone: { onChanged(); dismiss() }
            )
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Conflit de consensus (MYID-TELECOM-02) : avertissement + bloc « Site communautaire »
    /// avec bouton « Adopter ce site » (parité Android).
    @ViewBuilder
    private var conflictSection: some View {
        // L'icône a sa colonne : le site communautaire et le bouton s'alignent sur le texte.
        HStack(alignment: .top, spacing: SQSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OutageTint.degradedInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text(AttributedString(localized: "**Conflit** : un autre site a plus de validations sur cette antenne."))
                    .font(SQType.subhead(.regular))
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                if let consensusId = item.conflictSiteId {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Site communautaire · \(consensusId)")
                            .font(SQFont.body(14, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                        if let line = consensusLine {
                            Text(line)
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    Button {
                        Haptics.medium()
                        Task { await adoptConsensus(toSiteId: consensusId) }
                    } label: {
                        HStack(spacing: SQSpace.xs2) {
                            if adoptBusy { SQSpinner().tint(SQColor.onAccent) } else { Image(systemName: "checkmark.seal.fill") }
                            Text("Adopter ce site").font(SQFont.body(13, .semibold))
                        }
                        .padding(.horizontal, SQSpace.md)
                        .frame(minHeight: 44)
                        .foregroundStyle(SQColor.onAccent)
                        .background(SQColor.brandRed, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .disabled(adoptBusy)
                    .accessibilityIdentifier("identification.adopt")
                    if let adoptError {
                        Text(adoptError).font(SQType.micro).foregroundStyle(SQColor.dangerInk)
                    }
                } else {
                    Text("Retire cette identification si elle est erronée.")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.warningSoft, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityIdentifier("identification.conflict")
    }

    /// « Quai Claude-Bernard · 6 validations ».
    private var consensusLine: String? {
        let parts = [
            item.conflictSiteAddress,
            item.conflictSiteValidations.map { String(localized: "\($0) validations") }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func adoptConsensus(toSiteId: String) async {
        adoptBusy = true
        adoptError = nil
        defer { adoptBusy = false }
        do {
            let result = try await services.identify.editSite(
                fromSiteId: item.siteId, toSiteId: toSiteId,
                enb: item.enb, gnb: item.gnb, reason: "adopt-consensus"
            )
            if result.success || result.moved > 0 || result.noop {
                Haptics.success()
                onChanged()
                dismiss()
            } else {
                adoptError = String(localized: "Adoption non appliquée.")
                Haptics.error()
            }
        } catch {
            adoptError = error.userFacingMessage
            Haptics.error()
        }
    }

    @ViewBuilder
    private var editSection: some View {
        if canRemapSite || canEditSector {
            VStack(alignment: .leading, spacing: SQSpace.sm) {
                Text("Corriger").sqKicker().accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    if canRemapSite {
                        editRow(
                            title: "Corriger le site",
                            subtitle: "Choisir le bon site sur la carte",
                            icon: "mappin.and.ellipse",
                            identifier: "identification.remap"
                        ) { showRemap = true }
                    }
                    if canRemapSite && canEditSector {
                        Divider().overlay(SQColor.separator).padding(.leading, 64)
                    }
                    if canEditSector {
                        editRow(
                            title: "Corriger le secteur",
                            subtitle: "Toucher le bon secteur sur le radar",
                            icon: "dot.radiowaves.right",
                            identifier: "identification.sector"
                        ) { showSector = true }
                    }
                }
                .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
            }
        }
    }

    private func editRow(title: LocalizedStringKey, subtitle: LocalizedStringKey, icon: String,
                         identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: SQSpace.md) {
                SQIconPastille(systemImage: icon, size: 36, tint: SQColor.accentInk, fill: SQColor.accentSoft)
                VStack(alignment: .leading, spacing: SQSpace.xxs) {
                    Text(title).font(SQFont.body(15, .semibold)).foregroundStyle(SQColor.label)
                    Text(subtitle).font(SQType.micro).foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityIdentifier(identifier)
    }

    private var header: some View {
        HStack(spacing: SQSpace.md) {
            GenerationTile(label: is5G ? "5G" : "4G", size: 52)
            VStack(alignment: .leading, spacing: SQSpace.xxs) {
                Text(item.operatorDisplayName ?? String(localized: "Opérateur inconnu"))
                    .font(SQFont.display(20, .bold))
                    .foregroundStyle(SQColor.label)
                Text(item.nodeLabel)
                    .font(SQType.subhead)
                    .monospacedDigit()
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var detailsCard: some View {
        VStack(spacing: SQSpace.sm) {
            SQFactRow(label: "Validations", value: item.validations.formatted())
            if !item.sectors.isEmpty {
                SQFactRow(label: "Secteurs", value: item.sectors.map(String.init).joined(separator: ", "))
            }
            if let band = item.band { SQFactRow(label: "Bande", value: SQUnits.band(band, technology: item.tech ?? (item.type == "gnb" ? "NR" : nil))) }
            if let ci = item.ci { SQFactRow(label: "CI / ECI", value: ci) }
            if let mcc = mccMnc { SQFactRow(label: "MCC / MNC", value: mcc) }
            if let market = item.marketCode { SQFactRow(label: "Marché", value: market) }
            if let source = sourceLabel { SQFactRow(label: "Source", value: source) }
            SQFactRow(label: "Identifiant site", value: item.siteId)
            if let created = item.createdAt { SQFactRow(label: "Créée le", value: created.formatted(date: .abbreviated, time: .shortened)) }
            if let validated = item.lastValidated { SQFactRow(label: "Dernière validation", value: validated.formatted(date: .abbreviated, time: .shortened)) }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.md)
        .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
        .accessibilityIdentifier("identification.details")
    }

    private var mccMnc: String? {
        guard item.operatorMcc != nil || item.operatorMnc != nil else { return nil }
        let mcc = item.operatorMcc.map(String.init) ?? "—"
        let mnc = item.operatorMnc.map(String.init) ?? "—"
        return "\(mcc) / \(mnc)"
    }

    /// « iPhone » / « Android » plutôt que la valeur brute du serveur.
    private var sourceLabel: String? {
        guard let source = item.source, !source.isEmpty else { return nil }
        switch source.lowercased() {
        case "ios", "iphone": return "iPhone"
        case "android": return "Android"
        default: return source
        }
    }

    private var withdrawBlock: some View {
        VStack(spacing: SQSpace.xs) {
            GradientButton(
                "Retirer cette identification",
                systemImage: "trash",
                isBusy: isWithdrawing,
                style: .destructive
            ) {
                confirmingWithdraw = true
            }
            .accessibilityIdentifier("identification.withdraw")
            .confirmationDialog("Retirer cette identification ?", isPresented: $confirmingWithdraw) {
                Button("Retirer", role: .destructive, action: onWithdraw)
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("« \(item.nodeLabel) » ne te sera plus attribuée. Tu pourras la ré-identifier.")
            }
            Text("Réversible : tu peux ré-identifier ce site.")
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    /// Geste irréversible (hard delete owner-scoped), à part du retrait : le serveur
    /// n'efface que les lignes solo et retire en soft celles confirmées par d'autres.
    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Zone sensible").sqKicker().accessibilityAddTraits(.isHeader)
            Button {
                confirmingDelete = true
            } label: {
                HStack(spacing: SQSpace.md) {
                    SQIconPastille(systemImage: "trash.slash", size: 36, tint: SQColor.dangerInk, fill: SQColor.danger.opacity(0.12))
                    VStack(alignment: .leading, spacing: SQSpace.xxs) {
                        Text("Supprimer définitivement")
                            .font(SQFont.body(15, .semibold))
                            .foregroundStyle(SQColor.dangerInk)
                        Text("Irréversible. Les cellules confirmées par d’autres sont seulement retirées.")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if isWithdrawing { SQSpinner().tint(SQColor.danger) }
                }
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
                .sqCardBackground(SQColor.surface, cornerRadius: SQRadius.lg, elevation: .rest)
            }
            .buttonStyle(SQPressButtonStyle())
            .disabled(isWithdrawing)
            .accessibilityIdentifier("identification.delete")
            .confirmationDialog("Supprimer définitivement ?", isPresented: $confirmingDelete) {
                Button("Supprimer définitivement", role: .destructive, action: onDelete)
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("« \(item.nodeLabel) » sera effacée définitivement. Les cellules confirmées par d’autres seront seulement retirées.")
            }
        }
        .padding(.top, SQSpace.md)
    }
}
