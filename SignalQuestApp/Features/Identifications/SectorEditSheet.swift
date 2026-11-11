import SwiftUI

@MainActor
final class SectorEditViewModel: ObservableObject {
    @Published var azimuths: [Double] = []
    /// Support sans schéma possible (au plus un azimut connu) : les secteurs se choisissent dans
    /// une liste de `listCount` lignes, trois par défaut. 0 = le radar.
    @Published private(set) var listCount = 0
    @Published var selectedIndex: Int?
    @Published var isLoading = false
    @Published var isSubmitting = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var done = false
    /// Secteur enregistré mais feuille gardée ouverte, le temps de lire la référence du serveur.
    @Published private(set) var savedAwaitingClose = false

    /// SECTOR-PCI r1 : la rangée dont on corrige le secteur (un PCI du nœud, ou une ligne sans PCI),
    /// celle de la cellule observée à l'ouverture, puis celle choisie.
    @Published private(set) var row: SectorRow
    /// Les rangées du nœud, quand il en a plusieurs : on change de PCI sans quitter la feuille.
    let rows: [SectorRow]
    /// La ligne qui porte l'opérateur, le marché et le support de la rangée.
    var item: MyIdentification { row.primary }
    /// Secteur proposé par la règle de l'opérateur (`sectorCheck.expected`), dans la
    /// numérotation stockée ; présélectionné à la place du secteur enregistré.
    let prefilledSector: Int?
    /// `checks.sectorCheck` de la liste : contrôle indisponible, aucune référence du PCI n'est montrée.
    let trustsSectorCheck: Bool
    private let antennas: AntennasServicing
    private let identify: IdentifyServicing

    init(item: MyIdentification, cells: [MyIdentification] = [], antennas: AntennasServicing, identify: IdentifyServicing,
         prefilledSector: Int? = nil, trustsSectorCheck: Bool = true) {
        let all = SectorRow.rows(cells.isEmpty ? [item] : cells)
        self.row = all.first { $0.members.contains { $0.id == item.id } }
            ?? SectorRow.rows([item]).first ?? SectorRow(pci: nil, members: [item])
        self.rows = all.count > 1 ? all : []
        self.prefilledSector = prefilledSector
        self.trustsSectorCheck = trustsSectorCheck
        self.antennas = antennas
        self.identify = identify
    }

    /// Secteur que la règle de l'opérateur prouve à partir du numéro de cellule, montré avant
    /// le choix : seulement quand toutes les lignes de la rangée s'accordent. Absent, il n'est
    /// jamais remplacé par une valeur à nous.
    private var derivedValue: Int? {
        guard trustsSectorCheck, case let .sector(value) = row.reference else { return nil }
        return value
    }

    /// Les cellules du PCI ne donnent pas le même secteur : « désaccord entre cellules ».
    var referenceDisagrees: Bool { trustsSectorCheck && row.reference == .disagreement }

    private var derivedIndex: Int? { derivedValue.flatMap(storedIndex) }

    /// Le secteur du PCI, tant que le choix en diffère : dessiné en pointillés.
    var referenceIndex: Int? {
        guard let derivedIndex, derivedIndex != selectedIndex else { return nil }
        return derivedIndex
    }

    /// Le secteur choisi est celui que le PCI indique.
    var selectionMatchesPci: Bool {
        derivedIndex != nil && derivedIndex == selectedIndex
    }

    /// Le choix se fait dans une liste plutôt que sur le radar.
    var usesList: Bool { listCount > 0 }
    /// Secteurs proposés : les azimuts du radar, ou les lignes de la liste.
    var slotCount: Int { usesList ? listCount : azimuths.count }
    static let defaultListCount = 3
    /// Borne commune aux apps, mesurée en base le 02/11 : aucun secteur enregistré au-delà de 5,
    /// hors deux saisies isolées. Le secteur stocké ou prouvé l'élargit au besoin.
    static let maxListCount = 6

    private func storedIndex(_ value: Int) -> Int? {
        SectorNumbering.index(forStoredValue: value, azimuthCount: slotCount, mccMnc: mccMnc, operatorName: item.operatorName)
    }

    /// « Ajouter un secteur » : la ligne suivante, dans la même convention d'opérateur.
    func addListSlot() {
        guard listCount < Self.maxListCount else { return }
        listCount += 1
    }

    /// Assez de lignes pour montrer le secteur enregistré et celui du PCI.
    private func ensureListCovers(_ values: [Int]) {
        for value in values {
            // Au-delà de la borne, une valeur enregistrée reste affichable : jamais de perte.
            if let index = SectorNumbering.index(forStoredValue: value, azimuthCount: max(Self.maxListCount, value + 1),
                                                 mccMnc: mccMnc, operatorName: item.operatorName) {
                listCount = max(listCount, index + 1)
            }
        }
    }

    func select(row next: SectorRow) {
        guard next.id != row.id else { return }
        row = next
        errorMessage = nil
        infoMessage = nil
        if usesList { ensureListCovers(next.storedSectors + next.members.compactMap(\.referenceSector)) }
        selectedIndex = Self.initialSector(of: next).flatMap(storedIndex)
    }

    /// Secteur présélectionné : le secteur enregistré commun, aucun quand les lignes du PCI
    /// ne s'accordent pas (le choix les réalignera).
    private static func initialSector(of row: SectorRow) -> Int? {
        row.commonSectors.first
    }

    var operatorName: String { item.operatorName ?? "ALL" }
    /// PLMN de l'identification : il départage les MVNO, que le seul nom ne reconnaît pas.
    private var mccMnc: String? { SectorNumbering.plmn(mcc: item.operatorMcc, mnc: item.operatorMnc) }

    var market: String? {
        let value = item.marketCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return value.isEmpty ? nil : value
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let market else {
            errorMessage = String(localized: "Le marché de cette identification n'est pas renseigné. Aucun pays ne sera déduit automatiquement.")
            return
        }
        let details: AntennaDetails
        do {
            details = try await antennas.details(id: item.siteId, market: market, operatorName: operatorName)
        } catch {
            errorMessage = String(localized: "Impossible de charger les secteurs de ce site.")
            return
        }
        // Azimuts dédupliqués/triés : porteuses radio si dispo, sinon azimuts bruts.
        let carrierAzimuths = details.core?.radioCarriers.compactMap { $0.sectorAzimuthDeg } ?? []
        let raw = carrierAzimuths.isEmpty ? details.core?.azimuts ?? [] : carrierAzimuths
        let unique = Array(Set(raw.map { (($0.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) }))
            .sorted()
        // Support communautaire ou personnalisé, au plus un azimut : pas de schéma possible,
        // une liste. Les numéros passent par `SectorNumbering` comme sur le radar (SFR en base 0).
        if unique.count <= 1 {
            listCount = Self.defaultListCount
            ensureListCovers(row.storedSectors + [prefilledSector].compactMap { $0 } + row.members.compactMap(\.referenceSector))
        } else {
            azimuths = unique
        }
        // Pré-sélection sur le secteur proposé par la règle, sinon sur celui enregistré, selon la convention de
        // numérotation de l'opérateur (SFR 0-based vs Orange/Bouygues/Free 1-based).
        if let first = prefilledSector ?? Self.initialSector(of: row) {
            selectedIndex = storedIndex(first)
        }
    }

    /// Numéro de secteur affiché pour un index, dans la convention de l'opérateur.
    func sectorLabel(forIndex index: Int) -> Int {
        SectorNumbering.displayValue(index: index, mccMnc: mccMnc, operatorName: item.operatorName)
    }

    func submit() async {
        guard let selectedIndex, selectedIndex < slotCount else { return }
        // SECTOR-TELECOM-01 : valeur soumise dans la convention de l'opérateur
        // (un `index + 1` naïf écrivait une valeur fausse pour SFR).
        let sectorNumber = SectorNumbering.submissionValue(index: selectedIndex, mccMnc: mccMnc, operatorName: item.operatorName)
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await send(sectors: [sectorNumber])
            if result.changed {
                Haptics.success()
                // Le serveur renvoie le secteur déduit du PCI comme référence : s'il diffère
                // du choix enregistré, on le montre avant de fermer. Jamais une seconde fois
                // quand `derivedSector` l'avait déjà mis sur le radar.
                if derivedIndex == nil, !referenceDisagrees, !result.derived.isEmpty, result.derived != [sectorNumber] {
                    let derived = result.derived.map(String.init).joined(separator: ", ")
                    infoMessage = String(localized: "Secteur déduit du numéro de cellule : \(derived)")
                    savedAwaitingClose = true
                } else {
                    done = true
                }
            } else {
                errorMessage = result.applied ? IdentificationCorrectionText.nothingChanged
                    : result.message ?? String(localized: "Le secteur n'a pas pu être enregistré.")
                Haptics.error()
            }
        } catch {
            errorMessage = IdentificationCorrectionText.failure(error)
            Haptics.error()
        }
    }

    func finish() { done = true }

    /// Une rangée de PCI part en portée PCI : le nœud et le PCI, sans cellId ni CI, et le serveur
    /// réaligne toutes ses lignes. Sans `scope` dans la réponse, le serveur ne connaît pas cette
    /// portée et n'a touché que la ligne pci : chaque cellule est alors renvoyée seule.
    /// Une ligne sans PCI, ou sans nœud, reste en portée cellule.
    private func send(sectors: [Int]) async throws -> EditSectorsResult {
        let line = item
        guard let pci = row.pci, row.usesPciScope else {
            return try await edit(line, enb: line.enb, gnb: line.gnb, pci: line.pciValue,
                                  cellId: line.cellId, ci: line.ci, sectors: sectors)
        }
        let first = try await edit(line, enb: row.enb, gnb: row.gnb, pci: String(pci),
                                   cellId: nil, ci: nil, sectors: sectors)
        guard first.scope == nil, !row.cells.isEmpty else { return first }
        var updated = first.applied ? first.updated : 0
        var applied = first.applied
        var derived = first.derived
        var refusal = first.applied ? nil : first.message
        for cell in row.cells {
            let next = try await edit(cell, enb: cell.enb ?? row.enb, gnb: cell.gnb ?? row.gnb, pci: cell.pciValue,
                                      cellId: cell.cellId, ci: cell.ci, sectors: sectors)
            if next.applied {
                applied = true
                updated += next.updated
                if derived.isEmpty { derived = next.derived }
            } else {
                refusal = refusal ?? next.message
            }
        }
        return EditSectorsResult(applied: applied, updated: updated, sectors: sectors, derived: derived,
                                 message: refusal, scope: "cell")
    }

    private func edit(_ line: MyIdentification, enb: String?, gnb: String?, pci: String?,
                      cellId: String?, ci: String?, sectors: [Int]) async throws -> EditSectorsResult {
        try await identify.editSectors(
            siteId: line.siteId,
            enb: enb, gnb: gnb,
            pci: pci,
            cellId: cellId, ci: ci,
            tech: line.tech,
            operatorName: line.operatorName ?? "",
            marketCode: line.marketCode,
            sectors: sectors
        )
    }
}

/// Libellés communs de SECTOR-PCI r1, partagés par la feuille et le bloc « Tes identifications ici ».
enum SectorRowText {
    /// « secteurs 1 et 2 · à réaligner ».
    static func misaligned(_ sectors: [Int]) -> String {
        let list = ListFormatter.localizedString(byJoining: sectors.map(String.init))
        return String(localized: "secteurs \(list) · à réaligner")
    }

    static var realignNote: String {
        String(localized: "Ses cellules ont des secteurs différents : ton choix les réaligne.")
    }
}

/// Corriger le secteur d'une cellule (PCI/CellID) : l'utilisateur tape le bon
/// secteur sur un radar d'azimuts (comme la fiche antenne).
struct SectorEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SectorEditViewModel
    /// « Pas le bon support ? » : la feuille se ferme sur le choix du support sur la carte.
    let onMove: (() -> Void)?
    /// « Recharger mes identifications » après un échec que seule une relecture règle.
    let onReload: (() -> Void)?
    let onDone: () -> Void

    init(item: MyIdentification, cells: [MyIdentification] = [], antennas: AntennasServicing, identify: IdentifyServicing,
         prefilledSector: Int? = nil, trustsSectorCheck: Bool = true,
         onMove: (() -> Void)? = nil, onReload: (() -> Void)? = nil, onDone: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SectorEditViewModel(item: item, cells: cells, antennas: antennas, identify: identify,
                                                               prefilledSector: prefilledSector, trustsSectorCheck: trustsSectorCheck))
        self.onMove = onMove
        self.onReload = onReload
        self.onDone = onDone
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SQSpace.lg) {
                MapSheetHeader(
                    title: "Corriger le secteur",
                    subtitle: String(localized: "Touche le secteur qui dessert vraiment \(model.row.label)."),
                    closeIdentifier: "sector.cancel"
                ) { dismiss() }

                if !model.rows.isEmpty {
                    rowPicker
                }

                if model.isLoading {
                    SQSpinner().tint(SQColor.brandRed).frame(height: 260)
                } else if model.usesList {
                    sectorList
                    pciReference
                    scopeNote
                } else if model.azimuths.isEmpty {
                    EmptyStateView(
                        title: "Aucun secteur",
                        message: model.errorMessage ?? "Impossible de charger les secteurs de ce site.",
                        systemImage: "dot.radiowaves.right"
                    )
                } else {
                    SelectableSectorRadar(
                        azimuths: model.azimuths,
                        selectedIndex: $model.selectedIndex,
                        referenceIndex: model.referenceIndex,
                        displayNumber: { model.sectorLabel(forIndex: $0) }
                    )
                    .frame(width: 260, height: 260)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("sector.radar")

                    selectionPill
                    pciReference
                    scopeNote
                }

                if let info = model.infoMessage {
                    HStack(alignment: .top, spacing: SQSpace.sm) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(SQColor.labelSecondary)
                            .accessibilityHidden(true)
                        Text(info)
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(SQSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sector.info")
                }
                if let error = model.errorMessage, model.slotCount > 0 {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption).foregroundStyle(OutageTint.degradedInk)
                    if let onReload, IdentificationCorrectionText.needsReload(error) {
                        GradientButton(IdentificationCorrectionText.reload, systemImage: "arrow.clockwise", style: .secondary) {
                            onReload()
                            dismiss()
                        }
                        .accessibilityIdentifier("sector.reloadMine")
                    }
                }

                if let onMove, !model.savedAwaitingClose {
                    moveLink(onMove)
                }
            }
            .padding(SQSpace.lg)
        }
        // Bouton épinglé au bas : dans une feuille empilée sur la fiche, le bas du
        // défilement passait sous le bord de l'écran et « Enregistrer » restait hors d'atteinte.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveButton
                .padding(.horizontal, SQSpace.lg)
                .padding(.top, SQSpace.sm)
                .padding(.bottom, SQSpace.md)
                .frame(maxWidth: .infinity)
                .background(SQColor.bg.ignoresSafeArea(edges: .bottom))
        }
        .background(SQColor.bg.ignoresSafeArea())
        .task { await model.load() }
        .onChangeCompat(of: model.done) { _, done in
            if done { onDone(); dismiss() }
        }
        .onDisappear {
            // Fermée au glissement après l'enregistrement : la liste doit quand même se rafraîchir.
            if model.savedAwaitingClose, !model.done { onDone() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// « Secteur 2 · 120° » : le numéro suit la convention de l'opérateur.
    @ViewBuilder
    private var selectionPill: some View {
        if model.usesList {
            EmptyView()
        } else if let index = model.selectedIndex, index < model.azimuths.count {
            HStack(spacing: SQSpace.xs) {
                Image(systemName: "dot.radiowaves.right").accessibilityHidden(true)
                Text("Secteur \(model.sectorLabel(forIndex: index)) · \(Int(model.azimuths[index].rounded()))°")
                    .monospacedDigit()
            }
            .font(SQFont.body(14, .semibold))
            .foregroundStyle(SQColor.accentInk)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.xs2)
            .background(SQColor.accentSoft, in: Capsule(style: .continuous))
            .accessibilityIdentifier("sector.selection")
        } else {
            Text("Aucun secteur sélectionné")
                .font(SQType.subhead)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    /// Les rangées du nœud, celle de la cellule observée cochée : une par PCI, puis « Sans PCI ».
    private var rowPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("À corriger")
                .font(SQType.micro.weight(.semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.bottom, SQSpace.xs)
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                if row.pci == nil, index == 0 || model.rows[index - 1].pci != nil {
                    Text("Sans PCI")
                        .font(SQType.micro.weight(.semibold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(SQColor.labelTertiary)
                        .padding(.top, SQSpace.sm)
                        .padding(.bottom, SQSpace.xs)
                        .accessibilityAddTraits(.isHeader)
                }
                let isSelected = row.id == model.row.id
                Button {
                    model.select(row: row)
                    Haptics.selection()
                } label: {
                    HStack(spacing: SQSpace.sm2) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? SQColor.accentInk : SQColor.labelTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: row.label)
                                .font(SQFont.body(14, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(SQColor.label)
                            if row.pci != nil, row.cells.count > 1 {
                                Text("\(row.cells.count) cellules")
                                    .font(SQType.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if row.isMisaligned {
                            Text(SectorRowText.misaligned(row.storedSectors))
                                .font(SQType.caption)
                                .foregroundStyle(OutageTint.degradedInk)
                                .multilineTextAlignment(.trailing)
                        } else if let sector = row.commonSectors.first {
                            Text("secteur \(sector) aujourd’hui")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("sector.cell")
                Divider()
            }
        }
    }

    /// Sans schéma : une ligne par secteur, trois par défaut, puis « Ajouter un secteur ».
    private var sectorList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ce support n’a pas d’azimuts connus : choisis le numéro de son secteur.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, SQSpace.sm)
            ForEach(0..<model.listCount, id: \.self) { index in
                let isSelected = index == model.selectedIndex
                Button {
                    model.selectedIndex = index
                    Haptics.selection()
                } label: {
                    HStack(spacing: SQSpace.sm2) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? SQColor.accentInk : SQColor.labelTertiary)
                            .accessibilityHidden(true)
                        Text("Secteur \(model.sectorLabel(forIndex: index))")
                            .font(SQFont.body(15, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                        Spacer(minLength: 0)
                        if index == model.referenceIndex {
                            Label {
                                Text("indiqué par le numéro de cellule")
                            } icon: {
                                Image(systemName: "diamond.fill").imageScale(.small).foregroundStyle(OutageTint.degradedInk)
                            }
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("sector.listRow")
                Divider()
            }
            if model.listCount < SectorEditViewModel.maxListCount {
                Button {
                    model.addListSlot()
                } label: {
                    Label("Ajouter un secteur", systemImage: "plus")
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(SQColor.accentInk)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sector.addSlot")
            }
        }
        .accessibilityIdentifier("sector.list")
    }

    /// Le secteur que le PCI indique, quand il diffère, ou l'accord avec le choix.
    /// Une indication, jamais un refus : le choix du membre est gardé.
    @ViewBuilder
    private var pciReference: some View {
        if let reference = model.referenceIndex, reference < model.slotCount {
            VStack(spacing: SQSpace.xs) {
                Label {
                    if reference < model.azimuths.count {
                        Text("Le numéro de cellule indique le secteur \(model.sectorLabel(forIndex: reference)) · \(Int(model.azimuths[reference].rounded()))°")
                            .monospacedDigit()
                    } else {
                        Text("Le numéro de cellule indique le secteur \(model.sectorLabel(forIndex: reference))")
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "diamond.fill").imageScale(.small).foregroundStyle(OutageTint.degradedInk)
                }
                .font(SQType.subhead(.semibold))
                .foregroundStyle(SQColor.label)
                Text("Garde ton choix si tu as vu l’antenne : le numéro de cellule n’est qu’un indice.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sector.pciReference")
        } else if model.selectionMatchesPci {
            Label {
                Text("Conforme au numéro de cellule")
            } icon: {
                Image(systemName: "checkmark").foregroundStyle(SQColor.success)
            }
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.label)
                .accessibilityIdentifier("sector.pciMatch")
        } else if model.referenceDisagrees {
            Label {
                Text("Désaccord entre cellules")
            } icon: {
                Image(systemName: "questionmark.diamond").imageScale(.small).foregroundStyle(SQColor.labelSecondary)
            }
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.label)
            .accessibilityIdentifier("sector.referenceDisagrees")
        }
    }

    /// Portée de la correction : tout le PCI, et ses lignes réalignées quand elles divergent.
    @ViewBuilder
    private var scopeNote: some View {
        if model.row.usesPciScope, model.row.isMisaligned || model.row.cells.count > 1 {
            Text(model.row.isMisaligned
                 ? SectorRowText.realignNote
                 : String(localized: "Tout le PCI est corrigé : ses \(model.row.cells.count) cellules prennent ce secteur."))
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("sector.scopeNote")
        }
    }

    /// « Pas le bon support ? » : la correction passe au choix du support sur la carte.
    private func moveLink(_ onMove: @escaping () -> Void) -> some View {
        Button {
            onMove()
        } label: {
            HStack(spacing: SQSpace.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pas le bon support ?")
                        .font(SQType.subhead(.semibold))
                        .foregroundStyle(SQColor.label)
                    Text("Choisir le bon sur la carte")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .padding(.top, SQSpace.sm)
            .overlay(alignment: .top) { Rectangle().fill(SQColor.separator).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("sector.move")
    }

    @ViewBuilder
    private var saveButton: some View {
        if model.savedAwaitingClose {
            GradientButton(String(localized: "Fermer"), style: .secondary) { model.finish() }
                .accessibilityIdentifier("sector.close")
        } else if model.slotCount > 0 {
            GradientButton(
                "Enregistrer le secteur",
                systemImage: "checkmark",
                isBusy: model.isSubmitting,
                style: .primary
            ) {
                Task { await model.submit() }
            }
            .disabled(model.selectedIndex == nil || model.isSubmitting)
            .opacity(model.selectedIndex == nil ? 0.5 : 1)
            .accessibilityIdentifier("sector.save")
        }
    }
}

/// Radar d'azimuts tactile : chaque secteur est un cône (~65°) ; tape un cône pour
/// le sélectionner. Convention azimut 0° = nord, sens horaire (angle écran = az − 90).
struct SelectableSectorRadar: View {
    let azimuths: [Double]
    @Binding var selectedIndex: Int?
    /// Secteur que le PCI indique : en pointillés, doublé de son libellé sous le radar.
    var referenceIndex: Int? = nil
    /// Le choix est plein à l'encre (Halo : jamais de carmin plein), son numéro en couleur papier.
    var color: Color = SQColor.label
    var onColor: Color = SQColor.onInk
    /// Numéro de secteur affiché pour un index (convention opérateur). 1-based par défaut.
    var displayNumber: (Int) -> Int = { $0 + 1 }

    private let halfBeam: Double = 32.5

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = side / 2 - 14

            ZStack {
                Circle()
                    .fill(SQColor.surfaceMuted)
                    .overlay(Circle().stroke(SQColor.separator, lineWidth: 1.5))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                Circle()
                    .stroke(SQColor.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                    .frame(width: radius * 1.1, height: radius * 1.1)
                    .position(center)

                ForEach(Array(azimuths.enumerated()), id: \.offset) { index, azimuth in
                    let isSelected = index == selectedIndex
                    SectorWedge(azimuth: azimuth, halfBeam: halfBeam, radius: radius - 4, center: center)
                        .fill(isSelected ? color.opacity(0.85) : SQColor.labelTertiary.opacity(0.18))
                    if isSelected {
                        SectorWedge(azimuth: azimuth, halfBeam: halfBeam, radius: radius - 4, center: center)
                            .stroke(color, lineWidth: 2.5)
                    } else if index == referenceIndex {
                        SectorWedge(azimuth: azimuth, halfBeam: halfBeam, radius: radius - 4, center: center)
                            .stroke(OutageTint.degradedInk, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    }
                    Text("\(displayNumber(index))")
                        .font(SQFont.display(14, .heavy))
                        .foregroundStyle(isSelected ? onColor : SQColor.label)
                        .frame(width: 28, height: 28)
                        .background(isSelected ? color : SQColor.surface, in: Circle())
                        .overlay(Circle().stroke(SQColor.separator, lineWidth: isSelected ? 0 : 1))
                        .position(labelPosition(azimuth: azimuth, center: center, radius: radius))
                        // SECTOR-A11Y-03 : chaque secteur est un élément accessible
                        // sélectionnable (le radar tactile est sinon invisible à VoiceOver).
                        .accessibilityElement()
                        .accessibilityLabel(index == referenceIndex
                            ? Text("Secteur \(displayNumber(index)), azimut \(Int(azimuth.rounded())) degrés, indiqué par le numéro de cellule")
                            : Text("Secteur \(displayNumber(index)), azimut \(Int(azimuth.rounded())) degrés"))
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction {
                            selectedIndex = index
                            Haptics.selection()
                        }
                }

                Text("N")
                    .font(SQFont.display(12, .heavy))
                    .foregroundStyle(SQColor.labelSecondary)
                    .position(x: center.x, y: center.y - radius - 8)
                    .accessibilityHidden(true)

                Circle().fill(SQColor.label).frame(width: 10, height: 10).position(center)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        if let hit = hitTest(value.location, center: center, radius: radius) {
                            selectedIndex = hit
                            Haptics.selection()
                        }
                    }
            )
        }
    }

    private func labelPosition(azimuth: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let screen = (azimuth - 90) * .pi / 180
        let r = radius * 0.72
        return CGPoint(x: center.x + r * cos(screen), y: center.y + r * sin(screen))
    }

    private func hitTest(_ point: CGPoint, center: CGPoint, radius: CGFloat) -> Int? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        guard distance <= radius * 1.08 else { return nil }
        let screenAngle = atan2(dy, dx) * 180 / .pi
        var azimuth = screenAngle + 90
        azimuth = (azimuth.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)

        var best: Int?
        var bestDiff = halfBeam
        for (index, az) in azimuths.enumerated() {
            let diff = angularDistance(azimuth, az)
            if diff <= bestDiff {
                bestDiff = diff
                best = index
            }
        }
        return best
    }

    private func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

/// Cône (wedge) d'un secteur, centré sur son azimut.
struct SectorWedge: Shape {
    let azimuth: Double
    let halfBeam: Double
    let radius: CGFloat
    let center: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(azimuth - 90 - halfBeam),
            endAngle: .degrees(azimuth - 90 + halfBeam),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
