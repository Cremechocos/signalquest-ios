import SwiftUI
import UniformTypeIdentifiers

/// Page « Imports » calquée sur l'onglet Import d'Android : les cellules importées
/// (CSV eNB Analytics / .ntm NetMonster) sont groupées opérateur → antenne (eNB/gNB) →
/// cellule, avec statut d'identification résolu progressivement, et les actions
/// **identifier / voir les infos / supprimer**.
struct RadioLogImportView: View {
    @StateObject private var model: RadioLogImportsViewModel
    @State private var showPicker = false
    @State private var confirmDeleteAll = false
    @State private var detailRow: ParsedRadioLogRow?

    init(service: RadioLogImportServicing) {
        _model = StateObject(wrappedValue: RadioLogImportsViewModel(service: service))
    }

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .plainText, .text]
        if let ntm = UTType("fr.signalquest.ntm") { types.append(ntm) }
        return types
    }

    var body: some View {
        content
            .navigationTitle("Imports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 4) {
                        if !model.sections.isEmpty {
                            Menu {
                                Button(role: .destructive) { confirmDeleteAll = true } label: {
                                    Label("Supprimer tous les imports", systemImage: "trash")
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                        Button { showPicker = true } label: { Image(systemName: "square.and.arrow.down") }
                            .disabled(model.importing)
                    }
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: allowedTypes) { model.importPicked($0) }
            .confirmationDialog("Supprimer tous les imports ?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Tout supprimer", role: .destructive) { model.deleteAll() }
                Button("Annuler", role: .cancel) {}
            }
            .sheet(item: $detailRow) { row in
                NavigationStack { RadioLogCellDetailView(row: row, status: model.status(for: row)) { model.identifyCell(row) } }
            }
            .alert("Erreur", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorMessage ?? "") }
            .onAppear { if model.phase == .loading { model.load() } }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            emptyState
        case .error(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                importButton
            }.padding()
        case .ready:
            list
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 46)).foregroundStyle(.secondary)
            Text("Aucun import").font(.headline)
            Text("Importe un export « eNB Analytics » (CSV) ou NetMonster (.ntm) pour afficher, identifier et gérer les antennes détectées.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.importing { ProgressView() } else { importButton }
        }.padding(32)
    }

    private var importButton: some View {
        Button { showPicker = true } label: {
            Label("Choisir un fichier (.csv, .ntm)", systemImage: "square.and.arrow.down")
        }.buttonStyle(.borderedProminent)
    }

    private var list: some View {
        List {
            if model.resolving {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Résolution des identifications…").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.nodes) { node in nodeRow(node) }
                } header: {
                    Text("\(section.label) · \(section.antennaCount) antenne\(section.antennaCount > 1 ? "s" : "") · \(section.cellCount) cellule\(section.cellCount > 1 ? "s" : "")")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if model.importing { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
    }

    @ViewBuilder
    private func nodeRow(_ node: RadioLogImportNodeGroup) -> some View {
        DisclosureGroup {
            ForEach(node.cells) { cell in cellRow(cell) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(node.title).font(.body.weight(.semibold))
                    ForEach(node.techs, id: \.self) { t in techChip(t) }
                }
                Text("\(node.pciCount) PCI · \(node.cellCount) \(node.cellIdLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.deleteNode(node) } label: { Label("Supprimer", systemImage: "trash") }
            if node.cells.contains(where: { isIdentifiable($0) }) {
                Button { model.identifyNode(node) } label: { Label("Identifier", systemImage: "checkmark.seal") }.tint(.green)
            }
        }
    }

    @ViewBuilder
    private func cellRow(_ cell: ParsedRadioLogRow) -> some View {
        Button { detailRow = cell } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(RadioLogImportsViewModel.cellIdLabel(cell)) \(RadioLogImportsViewModel.cellValue(cell))")
                        .font(.subheadline).foregroundStyle(.primary)
                    if let pci = cell.pci {
                        Text("PCI \(pci)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                statusBadge(model.status(for: cell))
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.deleteCell(cell) } label: { Label("Supprimer", systemImage: "trash") }
            if isIdentifiable(cell) {
                Button { model.identifyCell(cell) } label: { Label("Identifier", systemImage: "checkmark.seal") }.tint(.green)
            }
        }
    }

    private func isIdentifiable(_ cell: ParsedRadioLogRow) -> Bool {
        if case .identifiable = model.status(for: cell) { return true }
        return false
    }

    private func techChip(_ tech: String) -> some View {
        Text(tech).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private func statusBadge(_ status: RadioLogImportCellStatus) -> some View {
        let (color, showSpinner): (Color, Bool) = {
            switch status {
            case .pending: return (.secondary, true)
            case .identifiable: return (.blue, false)
            case .notFound: return (.secondary, false)
            case .identified: return (.green, false)
            }
        }()
        HStack(spacing: 4) {
            if showSpinner { ProgressView().scaleEffect(0.6).frame(width: 10, height: 10) }
            Text(status.label).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Détail d'une cellule importée — « voir les infos » : tous les champs radio + le site
/// rattaché, avec l'action d'identification.
private struct RadioLogCellDetailView: View {
    let row: ParsedRadioLogRow
    let status: RadioLogImportCellStatus
    let onIdentify: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Cellule") {
                infoRow(RadioLogImportsViewModel.cellIdLabel(row), RadioLogImportsViewModel.cellValue(row))
                if let pci = row.pci { infoRow("PCI", "\(pci)") }
                if let tech = row.technology { infoRow("Technologie", tech) }
                if let cellId = row.cellId { infoRow("Cellule locale", cellId) }
            }
            Section("Nœud & opérateur") {
                infoRow("Opérateur", RadioLogImportsViewModel.operatorLabel(row))
                if let mcc = row.mcc, let mnc = row.mnc { infoRow("MCC / MNC", "\(mcc) / \(mnc)") }
                if let enb = row.enb { infoRow("eNB", enb) }
                if let gnb = row.gnb { infoRow("gNB", gnb) }
                if let tac = row.tac { infoRow("TAC", "\(tac)") }
            }
            Section("Radio") {
                if let earfcn = row.earfcn { infoRow("EARFCN", "\(earfcn)") }
                if let band = row.band { infoRow("Bande", "\(band)") }
                if let rsrp = row.rsrp { infoRow("RSRP", "\(rsrp) dBm") }
            }
            if let lat = row.latitude, let lon = row.longitude {
                Section("Position") { infoRow("Coordonnées", String(format: "%.5f, %.5f", lat, lon)) }
            }
            Section("Identification") {
                HStack {
                    Text("Statut")
                    Spacer()
                    Text(status.label).foregroundStyle(.secondary)
                }
                if case let .identifiable(siteId, distance) = status {
                    if !siteId.isEmpty { infoRow("Site", siteId) }
                    if let distance { infoRow("Distance", "≈ \(Int(distance)) m") }
                    Button { onIdentify(); dismiss() } label: {
                        Label("Identifier cette antenne", systemImage: "checkmark.seal.fill")
                    }
                }
            }
        }
        .navigationTitle(RadioLogImportsViewModel.nodeTitle(row))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Fermer") { dismiss() } } }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }.font(.subheadline)
    }
}
