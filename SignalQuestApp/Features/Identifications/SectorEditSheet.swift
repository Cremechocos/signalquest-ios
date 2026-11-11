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

    /// Cellule dont on corrige le secteur : celle observée à l'ouverture, puis celle choisie.
    @Published private(set) var item: MyIdentification
    /// Les cellules du nœud, quand il en a plusieurs : on change de cellule sans quitter la feuille.
    let cells: [MyIdentification]
    /// Secteur proposé par la règle de l'opérateur (`sectorCheck.expected`), dans la
    /// numérotation stockée ; présélectionné à la place du secteur enregistré.
    let prefilledSector: Int?
    /// `checks.sectorCheck` de la liste : contrôle indisponible, aucune référence du PCI n'est montrée.
    let trustsSectorCheck: Bool
    private let antennas: AntennasServicing
    private let identify: IdentifyServicing

    init(item: MyIdentification, cells: [MyIdentification] = [], antennas: AntennasServicing, identify: IdentifyServicing,
         prefilledSector: Int? = nil, trustsSectorCheck: Bool = true) {
        self.item = item
        self.cells = cells.count > 1 ? cells : []
        self.prefilledSector = prefilledSector
        self.trustsSectorCheck = trustsSectorCheck
        self.antennas = antennas
        self.identify = identify
    }

    /// Secteur que la règle de l'opérateur prouve à partir du PCI : `derivedSector`, montré
    /// avant le choix. Un serveur plus ancien ne le sert pas : on se rabat sur `sectorCheck`.
    /// Absent, il n'est jamais remplacé par une valeur à nous.
    private var derivedValue: Int? {
        guard trustsSectorCheck else { return nil }
        if let derived = item.derivedSector { return derived }
        switch item.sectorCheck?.status {
        case .mismatch: return item.sectorCheck?.expected
        case .match: return item.sectors.count == 1 ? item.sectors.first : nil
        default: return nil
        }
    }

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

    func select(cell: MyIdentification) {
        guard cell.id != item.id else { return }
        item = cell
        errorMessage = nil
        infoMessage = nil
        if usesList { ensureListCovers(cell.sectors + [cell.derivedSector, cell.sectorCheck?.expected].compactMap { $0 }) }
        selectedIndex = cell.sectors.first.flatMap(storedIndex)
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
            ensureListCovers(item.sectors + [prefilledSector, item.derivedSector, item.sectorCheck?.expected].compactMap { $0 })
        } else {
            azimuths = unique
        }
        // Pré-sélection sur le secteur proposé par la règle, sinon sur celui enregistré, selon la convention de
        // numérotation de l'opérateur (SFR 0-based vs Orange/Bouygues/Free 1-based).
        if let first = prefilledSector ?? item.sectors.first {
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
            let result = try await identify.editSectors(
                siteId: item.siteId,
                enb: item.enb, gnb: item.gnb,
                pci: item.pciValue,
                cellId: item.cellId, ci: item.ci,
                tech: item.tech,
                operatorName: item.operatorName ?? "",
                marketCode: item.marketCode,
                sectors: [sectorNumber]
            )
            if result.changed {
                Haptics.success()
                // Le serveur renvoie le secteur déduit du PCI comme référence : s'il diffère
                // du choix enregistré, on le montre avant de fermer. Jamais une seconde fois
                // quand `derivedSector` l'avait déjà mis sur le radar.
                if derivedIndex == nil, !result.derived.isEmpty, result.derived != [sectorNumber] {
                    let derived = result.derived.map(String.init).joined(separator: ", ")
                    infoMessage = String(localized: "Secteur déduit du PCI : \(derived)")
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
                    subtitle: String(localized: "Touche le secteur qui dessert vraiment \(model.item.cellLabel)."),
                    closeIdentifier: "sector.cancel"
                ) { dismiss() }

                if !model.cells.isEmpty {
                    cellPicker
                }

                if model.isLoading {
                    SQSpinner().tint(SQColor.brandRed).frame(height: 260)
                } else if model.usesList {
                    sectorList
                    pciReference
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

    /// Les cellules du nœud, la cellule observée cochée : une ligne par cellule.
    private var cellPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ta cellule")
                .font(SQType.micro.weight(.semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(SQColor.labelSecondary)
                .padding(.bottom, SQSpace.xs)
            ForEach(model.cells) { cell in
                let isSelected = cell.id == model.item.id
                Button {
                    model.select(cell: cell)
                    Haptics.selection()
                } label: {
                    HStack(spacing: SQSpace.sm2) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? SQColor.accentInk : SQColor.labelTertiary)
                            .accessibilityHidden(true)
                        Text(cell.cellLabel)
                            .font(SQFont.body(14, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(SQColor.label)
                        Spacer(minLength: 0)
                        if let sector = cell.sectors.first {
                            Text("secteur \(sector) aujourd’hui")
                                .font(SQType.caption)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                                Text("indiqué par le PCI")
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
                        Text("Le PCI indique le secteur \(model.sectorLabel(forIndex: reference)) · \(Int(model.azimuths[reference].rounded()))°")
                            .monospacedDigit()
                    } else {
                        Text("Le PCI indique le secteur \(model.sectorLabel(forIndex: reference))")
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "diamond.fill").imageScale(.small).foregroundStyle(OutageTint.degradedInk)
                }
                .font(SQType.subhead(.semibold))
                .foregroundStyle(SQColor.label)
                Text("Garde ton choix si tu as vu l’antenne : le PCI n’est qu’un indice.")
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
                Text("Conforme au PCI")
            } icon: {
                Image(systemName: "checkmark").foregroundStyle(SQColor.success)
            }
            .font(SQType.subhead(.semibold))
            .foregroundStyle(SQColor.label)
                .accessibilityIdentifier("sector.pciMatch")
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
                            ? Text("Secteur \(displayNumber(index)), azimut \(Int(azimuth.rounded())) degrés, indiqué par le PCI")
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
