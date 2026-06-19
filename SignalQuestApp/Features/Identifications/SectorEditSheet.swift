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

    let item: MyIdentification
    private let antennas: AntennasServicing
    private let identify: IdentifyServicing

    init(item: MyIdentification, antennas: AntennasServicing, identify: IdentifyServicing) {
        self.item = item
        self.antennas = antennas
        self.identify = identify
    }

    var operatorName: String { item.operatorName ?? "ALL" }
    var market: String { item.marketCode ?? "FR" }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let details = try? await antennas.details(id: item.siteId, market: market, operatorName: operatorName),
              let core = details.core else {
            errorMessage = "Impossible de charger les secteurs de ce site."
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
                forStoredValue: first, azimuthCount: unique.count, operatorName: item.operatorName
            )
        }
        if unique.isEmpty {
            errorMessage = "Ce site n'expose pas d'azimuts de secteur."
        }
    }

    /// Numéro de secteur affiché pour un index, dans la convention de l'opérateur.
    func sectorLabel(forIndex index: Int) -> Int {
        SectorNumbering.displayValue(index: index, operatorName: item.operatorName)
    }

    func submit() async {
        guard let selectedIndex, selectedIndex < azimuths.count else { return }
        // SECTOR-TELECOM-01 : valeur soumise dans la convention de l'opérateur
        // (un `index + 1` naïf écrivait une valeur fausse pour SFR).
        let sectorNumber = SectorNumbering.submissionValue(index: selectedIndex, operatorName: item.operatorName)
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
                done = true
            } else if result.isAutoDerived {
                // En France le secteur est imposé par le PCI : on l'affiche honnêtement.
                let derived = result.sectors.map(String.init).joined(separator: ", ")
                infoMessage = derived.isEmpty
                    ? "En France, le secteur est déterminé automatiquement à partir du PCI."
                    : "En France, le secteur est déterminé automatiquement à partir du PCI : secteur \(derived)."
                if let d = result.sectors.first, d >= 1, d <= azimuths.count { self.selectedIndex = d - 1 }
                Haptics.warning()
            } else {
                errorMessage = "Le secteur n'a pas pu être enregistré."
                Haptics.error()
            }
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
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
        NavigationStack {
            ScrollView {
                VStack(spacing: SQSpace.lg) {
                    Text("Touche le secteur réellement desservi par \(model.item.nodeLabel).")
                        .font(.subheadline)
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    if model.isLoading {
                        ProgressView().tint(SQColor.brandRed).frame(height: 260)
                    } else if model.azimuths.isEmpty {
                        ContentUnavailableCompat(
                            title: "Aucun secteur",
                            message: model.errorMessage ?? "Ce site n'expose pas d'azimuts.",
                            systemImage: "dot.radiowaves.right"
                        )
                    } else {
                        SelectableSectorRadar(
                            azimuths: model.azimuths,
                            selectedIndex: $model.selectedIndex,
                            color: model.item.kind == .gnb ? SQColor.brandOrange : SQColor.brandBlue,
                            displayNumber: { model.sectorLabel(forIndex: $0) }
                        )
                        .frame(height: 280)
                        .padding(SQSpace.md)

                        if let index = model.selectedIndex {
                            Text("Secteur \(model.sectorLabel(forIndex: index)) · azimut \(Int(model.azimuths[index].rounded()))°")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SQColor.label)
                        } else {
                            Text("Aucun secteur sélectionné")
                                .font(.subheadline)
                                .foregroundStyle(SQColor.labelSecondary)
                        }
                    }

                    if let info = model.infoMessage {
                        Label(info, systemImage: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(SQColor.brandBlue)
                            .padding(SQSpace.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SQColor.brandBlue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if let error = model.errorMessage, !model.azimuths.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(SQColor.warning)
                    }

                    saveButton
                }
                .padding()
            }
            .background(SQColor.bg.ignoresSafeArea())
            .navigationTitle("Corriger le secteur")
            .toolbarTitleInlineCompat()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }.tint(SQColor.brandRed)
                }
            }
            .task { await model.load() }
            .onChangeCompat(of: model.done) { _, done in
                if done { onDone(); dismiss() }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var saveButton: some View {
        if !model.azimuths.isEmpty {
            Button {
                Task { await model.submit() }
            } label: {
                HStack {
                    if model.isSubmitting { ProgressView().tint(.white) } else { Image(systemName: "checkmark") }
                    Text("Enregistrer le secteur").font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, SQSpace.md)
                .foregroundStyle(.white)
                .background(model.selectedIndex == nil ? SQColor.labelSecondary : SQColor.brandGreen,
                            in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.selectedIndex == nil || model.isSubmitting)
        }
    }
}

/// Radar d'azimuts tactile : chaque secteur est un cône (~65°) ; tape un cône pour
/// le sélectionner. Convention azimut 0° = nord, sens horaire (angle écran = az − 90).
struct SelectableSectorRadar: View {
    let azimuths: [Double]
    @Binding var selectedIndex: Int?
    var color: Color = SQColor.brandOrange
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
                    .stroke(SQColor.separator.opacity(0.5), lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)
                Circle()
                    .stroke(SQColor.separator.opacity(0.3), lineWidth: 1)
                    .frame(width: radius, height: radius)

                ForEach(Array(azimuths.enumerated()), id: \.offset) { index, azimuth in
                    let isSelected = index == selectedIndex
                    SectorWedge(azimuth: azimuth, halfBeam: halfBeam, radius: radius, center: center)
                        .fill(color.opacity(isSelected ? 0.55 : 0.16))
                    SectorWedge(azimuth: azimuth, halfBeam: halfBeam, radius: radius, center: center)
                        .stroke(color.opacity(isSelected ? 1 : 0.4), lineWidth: isSelected ? 2.5 : 1)
                    Text("\(displayNumber(index))")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? .white : color)
                        .padding(5)
                        .background(isSelected ? color : Color.clear, in: Circle())
                        .position(labelPosition(azimuth: azimuth, center: center, radius: radius))
                }

                Text("N")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(SQColor.labelSecondary)
                    .position(x: center.x, y: center.y - radius - 6)

                Circle().fill(color).frame(width: 12, height: 12).position(center)
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
        let r = radius * 0.62
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

/// État vide compatible iOS 16 (ContentUnavailableView est iOS 17+).
struct ContentUnavailableCompat: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: SQSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(SQColor.labelSecondary)
            Text(title).font(.headline).foregroundStyle(SQColor.label)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(SQColor.labelSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SQSpace.xl)
    }
}
