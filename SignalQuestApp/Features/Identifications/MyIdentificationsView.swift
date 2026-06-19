import SwiftUI

@MainActor
final class MyIdentificationsViewModel: ObservableObject {
    @Published var items: [MyIdentification] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var withdrawingId: String?
    @Published var filter: Filter = .all
    @Published var toast: String?

    enum Filter: String, CaseIterable, Identifiable {
        case all, lte, nr
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "Toutes"
            case .lte: return "4G"
            case .nr: return "5G"
            }
        }
    }

    private let service: IdentifyServicing
    init(service: IdentifyServicing) { self.service = service }

    var filtered: [MyIdentification] {
        switch filter {
        case .all: return items
        case .lte: return items.filter { $0.kind == .enb || $0.techLabel == "4G" }
        case .nr: return items.filter { $0.kind == .gnb || $0.techLabel == "5G" }
        }
    }

    var filteredGroups: [IdentifiedNodeGroup] {
        IdentifiedNodeGroup.group(filtered)
    }

    var conflictCount: Int { items.filter(\.conflict).count }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await service.mine(includeRelated: true)
            items = result.sorted { ($0.lastValidated ?? $0.createdAt ?? .distantPast) > ($1.lastValidated ?? $1.createdAt ?? .distantPast) }
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
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
                toast = "Identification retirée"
                Haptics.success()
            } else {
                toast = "Retrait impossible"
                Haptics.error()
            }
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}

/// « Mes identifications » — les cellules→sites que l'utilisateur a identifiées
/// (compte partagé : inclut celles faites sur Android). Consultation + retrait.
struct MyIdentificationsView: View {
    @StateObject private var model: MyIdentificationsViewModel
    @State private var pendingWithdraw: MyIdentification?
    @State private var selected: MyIdentification?

    init(service: IdentifyServicing) {
        _model = StateObject(wrappedValue: MyIdentificationsViewModel(service: service))
    }

    var body: some View {
        List {
            Section {
                Picker("Filtre", selection: $model.filter) {
                    ForEach(MyIdentificationsViewModel.Filter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: SQSpace.sm, leading: SQSpace.md, bottom: SQSpace.sm, trailing: SQSpace.md))
                .listRowBackground(Color.clear)
            }

            if model.conflictCount > 0 {
                Label("\(model.conflictCount) en conflit — un autre site domine ce nœud. Vérifie ou retire.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(SQColor.warning)
                    .listRowBackground(Color.clear)
            }

            if model.filteredGroups.isEmpty && !model.isLoading {
                emptyState.listRowBackground(Color.clear)
            } else {
                ForEach(model.filteredGroups) { group in
                    Section {
                        IdentificationNodeRow(group: group, isWithdrawing: model.withdrawingId == group.representative.id)
                            .listRowBackground(SQColor.surface)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = group.representative }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingWithdraw = group.representative
                                } label: {
                                    Label("Retirer", systemImage: "trash")
                                }
                            }

                        ForEach(group.cells) { cell in
                            IdentificationCellRow(cell: cell, isWithdrawing: model.withdrawingId == cell.source.id)
                                .listRowBackground(SQColor.surface)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = cell.source }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingWithdraw = cell.source
                                    } label: {
                                        Label("Retirer", systemImage: "trash")
                                    }
                                }
                        }

                        if group.cells.isEmpty {
                            Text("Aucun PCI/CI associé pour ce nœud.")
                                .font(.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                                .listRowBackground(SQColor.surface)
                        }
                    } header: {
                        Text(group.title)
                            .font(SQFont.archivo(12, .semibold))
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(SQColor.warning)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SQColor.bg.ignoresSafeArea())
        .navigationTitle("Mes identifications")
        .toolbarTitleInlineCompat()
        .refreshable { await model.load() }
        .overlay {
            if model.isLoading && model.items.isEmpty { ProgressView().tint(SQColor.brandRed) }
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
            Text("« \(item.nodeLabel) » ne te sera plus attribuée. Les lignes liées sont rechargées depuis le serveur après retrait.")
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
                onChanged: {
                    selected = nil
                    Task { await model.load() }
                }
            )
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, SQSpace.md).padding(.vertical, SQSpace.sm)
                    .background(SQColor.label.opacity(0.9), in: Capsule())
                    .padding(.bottom, SQSpace.lg)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        model.toast = nil
                    }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: SQSpace.md) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44))
                .foregroundStyle(SQColor.labelSecondary)
            Text("Aucune identification")
                .font(.headline)
                .foregroundStyle(SQColor.label)
            Text("Identifie une antenne depuis une session ou la carte. Tes identifications — y compris depuis Android — apparaîtront ici.")
                .font(.subheadline)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.xxl)
    }
}

private struct IdentificationNodeRow: View {
    let group: IdentifiedNodeGroup
    let isWithdrawing: Bool

    private var is5G: Bool { group.kind == .gnb }

    var body: some View {
        HStack(spacing: SQSpace.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(is5G ? SQColor.brandOrange : SQColor.brandBlue)
                Text(is5G ? "5G" : "4G")
                    .font(SQFont.archivo(12, .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: SQSpace.sm) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                    if group.conflict {
                        Text("conflit")
                            .font(SQType.micro)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(SQColor.warning.opacity(0.18), in: Capsule())
                            .foregroundStyle(SQColor.warning)
                    }
                }
                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
                HStack(spacing: SQSpace.sm) {
                    Label("validée \(group.validations)×", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(SQColor.brandGreen)
                    if !group.sectorsUnion.isEmpty {
                        Label("\(group.sectorsUnion.count) secteur\(group.sectorsUnion.count > 1 ? "s" : "")", systemImage: "dot.radiowaves.right")
                    }
                }
                .font(.caption2)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(1)
            }
            Spacer()
            if isWithdrawing { ProgressView() }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(SQColor.labelSecondary)
        }
        .padding(.vertical, 4)
    }
}

private struct IdentificationCellRow: View {
    let cell: IdentifiedCell
    let isWithdrawing: Bool

    var body: some View {
        HStack(spacing: SQSpace.md) {
            Image(systemName: "dot.radiowaves.right")
                .font(.headline)
                .foregroundStyle(SQColor.brandOrange)
                .frame(width: 44, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(cell.label)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(SQColor.label)
                HStack(spacing: SQSpace.sm) {
                    if let ci = cell.ci {
                        Text("CI \(ci)")
                    }
                    if !cell.sectors.isEmpty {
                        Text("Secteurs \(cell.sectors.map(String.init).joined(separator: ", "))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(SQColor.labelSecondary)
                .lineLimit(1)
            }
            Spacer()
            if isWithdrawing { ProgressView() }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(SQColor.labelSecondary)
        }
        .padding(.vertical, 3)
    }
}

/// Fiche détaillée d'une identification : tous les identifiants radio + retrait.
private struct IdentificationDetailSheet: View {
    let item: MyIdentification
    let isWithdrawing: Bool
    let onWithdraw: () -> Void
    var onChanged: () -> Void = {}

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingWithdraw = false
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    header
                    if item.conflict {
                        conflictSection
                    }
                    detailsCard
                    editSection
                    withdrawButton
                }
                .padding()
            }
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle("Identification")
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }.tint(SQColor.brandRed)
                }
            }
            .sheet(isPresented: $showRemap) {
                SiteRemapSheet(
                    item: item,
                    antennas: services.antennas,
                    identify: services.identify,
                    location: services.location,
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
        }
        .presentationDetents([.medium, .large])
    }

    /// Conflit de consensus (MYID-TELECOM-02) : avertissement + bloc « Site communautaire
    /// (consensus) » avec bouton « Adopter le site communautaire » (parité Android).
    @ViewBuilder
    private var conflictSection: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Label("Conflit : un autre site domine ce nœud en validations.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(SQColor.warning)
            if let consensusId = item.conflictSiteId {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Site communautaire (consensus)")
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                    Text(item.conflictSiteAddress ?? "Site \(consensusId)")
                        .font(SQFont.archivo(14, .semibold))
                        .foregroundStyle(SQColor.label)
                    if let v = item.conflictSiteValidations {
                        Text("\(v) validation\(v > 1 ? "s" : "")")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
                Button {
                    Task { await adoptConsensus(toSiteId: consensusId) }
                } label: {
                    HStack(spacing: SQSpace.xs + 2) {
                        if adoptBusy { ProgressView().tint(.white) } else { Image(systemName: "checkmark.seal.fill") }
                        Text("Adopter le site communautaire").font(SQType.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SQSpace.sm + 2)
                    .foregroundStyle(.white)
                    .background(SQColor.brandGreen, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(adoptBusy)
                if let adoptError {
                    Text(adoptError).font(.caption2).foregroundStyle(SQColor.danger)
                }
            } else {
                Text("Retire cette identification si elle est erronée.")
                    .font(.caption)
                    .foregroundStyle(SQColor.labelSecondary)
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                adoptError = "Adoption non appliquée."
                Haptics.error()
            }
        } catch {
            adoptError = error.localizedDescription
            Haptics.error()
        }
    }

    @ViewBuilder
    private var editSection: some View {
        if canRemapSite || canEditSector {
            VStack(spacing: SQSpace.sm) {
                if canRemapSite {
                    editRow(
                        title: "Corriger le site",
                        subtitle: "Choisir le bon site sur la carte",
                        icon: "mappin.and.ellipse",
                        tint: SQColor.brandBlue
                    ) { showRemap = true }
                }
                if canEditSector {
                    editRow(
                        title: "Corriger le secteur",
                        subtitle: "Sélectionner le bon secteur sur le radar",
                        icon: "dot.radiowaves.right",
                        tint: SQColor.brandOrange
                    ) { showSector = true }
                }
            }
        }
    }

    private func editRow(title: String, subtitle: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: SQSpace.md) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(SQColor.label)
                    Text(subtitle).font(.caption2).foregroundStyle(SQColor.labelSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(SQColor.labelSecondary)
            }
            .padding(SQSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: SQSpace.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(is5G ? SQColor.brandOrange : SQColor.brandBlue)
                Text(item.techLabel).font(SQFont.archivo(14, .heavy)).foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.operatorName ?? "Opérateur inconnu")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(SQColor.label)
                Text(item.nodeLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(SQColor.labelSecondary)
            }
            Spacer()
        }
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            infoRow("Validations", "\(item.validations)×")
            if !item.sectors.isEmpty {
                infoRow("Secteurs", item.sectors.map(String.init).joined(separator: ", "))
            }
            if let band = item.band { infoRow("Bande", "B\(band)") }
            if let ci = item.ci { infoRow("CI / ECI", ci) }
            if let mcc = mccMnc { infoRow("MCC / MNC", mcc) }
            if let market = item.marketCode { infoRow("Marché", market) }
            if let source = item.source { infoRow("Source", source) }
            infoRow("Identifiant site", item.siteId, mono: true)
            if let created = item.createdAt { infoRow("Créée le", created.formatted(date: .abbreviated, time: .shortened)) }
            if let validated = item.lastValidated { infoRow("Dernière validation", validated.formatted(date: .abbreviated, time: .shortened)) }
        }
        .padding(.horizontal, SQSpace.md)
        .padding(.vertical, SQSpace.xs)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var mccMnc: String? {
        guard item.operatorMcc != nil || item.operatorMnc != nil else { return nil }
        let mcc = item.operatorMcc.map(String.init) ?? "—"
        let mnc = item.operatorMnc.map(String.init) ?? "—"
        return "\(mcc) / \(mnc)"
    }

    private var withdrawButton: some View {
        Button(role: .destructive) {
            confirmingWithdraw = true
        } label: {
            HStack {
                if isWithdrawing { ProgressView().tint(.white) } else { Image(systemName: "trash") }
                Text("Retirer cette identification").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, SQSpace.md)
            .foregroundStyle(.white)
            .background(SQColor.danger, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isWithdrawing)
        .confirmationDialog("Retirer cette identification ?", isPresented: $confirmingWithdraw) {
            Button("Retirer", role: .destructive, action: onWithdraw)
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("« \(item.nodeLabel) » ne te sera plus attribuée. Réversible en ré-identifiant.")
        }
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(SQColor.labelSecondary)
                Spacer()
                Text(value)
                    .font(mono ? .subheadline.monospaced() : .subheadline.weight(.semibold))
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            .padding(.vertical, SQSpace.sm)
        }
    }
}
