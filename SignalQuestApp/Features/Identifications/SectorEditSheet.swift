import SwiftUI

@MainActor
final class SectorEditViewModel: ObservableObject {
    @Published var azimuths: [Double] = []
    @Published var selectedIndex: Int?
    @Published var isLoading = false
    @Published var isSubmitting = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var done = false
    /// Secteur enregistré mais feuille gardée ouverte, le temps de lire la référence du serveur.
    @Published private(set) var savedAwaitingClose = false

    let item: MyIdentification
    private let antennas: AntennasServicing
    private let identify: IdentifyServicing

    init(item: MyIdentification, antennas: AntennasServicing, identify: IdentifyServicing) {
        self.item = item
        self.antennas = antennas
        self.identify = identify
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
        guard let details = try? await antennas.details(id: item.siteId, market: market, operatorName: operatorName),
              let core = details.core else {
            errorMessage = String(localized: "Impossible de charger les secteurs de ce site.")
            return
        }
        // Azimuts dédupliqués/triés : porteuses radio si dispo, sinon azimuts bruts.
        let carrierAzimuths = core.radioCarriers.compactMap { $0.sectorAzimuthDeg }
        let raw = carrierAzimuths.isEmpty ? core.azimuts : carrierAzimuths
        let unique = Array(Set(raw.map { (($0.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) }))
            .sorted()
        azimuths = unique
        // Pré-sélection sur le secteur déjà enregistré, selon la convention de
        // numérotation de l'opérateur (SFR 0-based vs Orange/Bouygues/Free 1-based).
        if let first = item.sectors.first {
            selectedIndex = SectorNumbering.index(
                forStoredValue: first, azimuthCount: unique.count, mccMnc: mccMnc, operatorName: item.operatorName
            )
        }
        if unique.isEmpty {
            errorMessage = String(localized: "Ce site n'expose pas d'azimuts de secteur.")
        }
    }

    /// Numéro de secteur affiché pour un index, dans la convention de l'opérateur.
    func sectorLabel(forIndex index: Int) -> Int {
        SectorNumbering.displayValue(index: index, mccMnc: mccMnc, operatorName: item.operatorName)
    }

    func submit() async {
        guard let selectedIndex, selectedIndex < azimuths.count else { return }
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
            if result.applied {
                Haptics.success()
                // Le serveur renvoie le secteur déduit du PCI comme référence : s'il diffère
                // du choix enregistré, on le montre avant de fermer.
                if !result.derived.isEmpty, result.derived != [sectorNumber] {
                    let derived = result.derived.map(String.init).joined(separator: ", ")
                    infoMessage = String(localized: "Secteur déduit du PCI : \(derived)")
                    savedAwaitingClose = true
                } else {
                    done = true
                }
            } else {
                errorMessage = result.message ?? String(localized: "Le secteur n'a pas pu être enregistré.")
                Haptics.error()
            }
        } catch {
            errorMessage = error.userFacingMessage
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
    let onDone: () -> Void

    init(item: MyIdentification, antennas: AntennasServicing, identify: IdentifyServicing, onDone: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SectorEditViewModel(item: item, antennas: antennas, identify: identify))
        self.onDone = onDone
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SQSpace.lg) {
                MapSheetHeader(
                    title: "Corriger le secteur",
                    subtitle: String(localized: "Touche le secteur qui dessert vraiment \(model.item.nodeLabel)."),
                    closeIdentifier: "sector.cancel"
                ) { dismiss() }

                if model.isLoading {
                    SQSpinner().tint(SQColor.brandRed).frame(height: 260)
                } else if model.azimuths.isEmpty {
                    EmptyStateView(
                        title: "Aucun secteur",
                        message: model.errorMessage ?? "Ce site n'expose pas d'azimuts.",
                        systemImage: "dot.radiowaves.right"
                    )
                } else {
                    SelectableSectorRadar(
                        azimuths: model.azimuths,
                        selectedIndex: $model.selectedIndex,
                        displayNumber: { model.sectorLabel(forIndex: $0) }
                    )
                    .frame(width: 260, height: 260)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("sector.radar")

                    selectionPill
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
                if let error = model.errorMessage, !model.azimuths.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(SQType.caption).foregroundStyle(OutageTint.degradedInk)
                }

                saveButton
            }
            .padding(SQSpace.lg)
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
        if let index = model.selectedIndex, index < model.azimuths.count {
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

    @ViewBuilder
    private var saveButton: some View {
        if model.savedAwaitingClose {
            GradientButton(String(localized: "Fermer"), style: .secondary) { model.finish() }
                .accessibilityIdentifier("sector.close")
        } else if !model.azimuths.isEmpty {
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
    var color: Color = SQColor.brandRed
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
                        .fill(isSelected ? color.opacity(0.55) : SQColor.labelTertiary.opacity(0.18))
                    if isSelected {
                        SectorWedge(azimuth: azimuth, halfBeam: halfBeam, radius: radius - 4, center: center)
                            .stroke(color, lineWidth: 2.5)
                    }
                    Text("\(displayNumber(index))")
                        .font(SQFont.display(14, .heavy))
                        .foregroundStyle(isSelected ? SQColor.onAccent : SQColor.label)
                        .frame(width: 28, height: 28)
                        .background(isSelected ? color : SQColor.surface, in: Circle())
                        .overlay(Circle().stroke(SQColor.separator, lineWidth: isSelected ? 0 : 1))
                        .position(labelPosition(azimuth: azimuth, center: center, radius: radius))
                        // SECTOR-A11Y-03 : chaque secteur est un élément accessible
                        // sélectionnable (le radar tactile est sinon invisible à VoiceOver).
                        .accessibilityElement()
                        .accessibilityLabel("Secteur \(displayNumber(index)), azimut \(Int(azimuth.rounded())) degrés")
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
