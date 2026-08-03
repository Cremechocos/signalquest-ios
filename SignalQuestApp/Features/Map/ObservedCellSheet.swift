import SwiftUI
import CoreLocation

/// Fiche d'une cellule observée.
///
/// Une cellule observée n'est pas un site : c'est une **identité radio** dont on
/// connaît les mesures, et dont la position n'est qu'un centroïde — la moyenne
/// des points où on l'a captée, souvent à plusieurs centaines de mètres du
/// pylône réel. La fiche doit donc être franche sur ce qu'elle montre, et
/// proposer le geste qui manque : poser le vrai site.
struct ObservedCellSheet: View {
    let cell: AndroidCommunitySiteMarker
    /// Cellules du même endroit, proposées à la sélection : un pylône porte
    /// souvent plusieurs opérateurs, et les regrouper évite d'en créer autant
    /// de sites que d'opérateurs.
    let nearbyCells: [AndroidCommunitySiteMarker]
    let operatorLabel: (String) -> String
    let accent: Color
    /// Appelé avec les cellules retenues quand l'utilisateur veut créer le site.
    let onCreateSite: ([AndroidCommunitySiteMarker]) -> Void

    @State private var selectedIds: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private var radio: [(String, String?)] {
        [
            ("Opérateur", cell.operatorKey.map(operatorLabel)),
            ("Technologie", cell.radioNodeType),
            ("PLMN", plmn),
            ("eNB", cell.enb),
            ("gNB", cell.gnb),
            ("CI", cell.cellId ?? cell.ci),
            ("PCI", cell.pci.map(String.init)),
            ("TAC", cell.tac),
            ("EARFCN", cell.earfcn.map(String.init)),
            ("NR-ARFCN", cell.nrarfcn.map(String.init)),
            ("Bande", cell.band.map { "B\($0)" })
        ]
    }

    private var plmn: String? {
        guard let mcc = cell.mcc, let mnc = cell.mnc else { return nil }
        return String(format: "%03d-%02d", mcc, mnc)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg) {
                    header
                    provenanceBanner
                    section("Identifiants radio") { rows(radio) }
                    section("Ce qu'on en sait") { rows(evidence) }
                    if !groupCandidates.isEmpty { grouping }
                    createButton
                }
                .padding(SQSpace.lg)
            }
            .signalQuestBackground()
            .navigationTitle("Cellule observée")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }.tint(SQColor.brandRed)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.title2.weight(.semibold))
                .foregroundStyle(SQColor.onAccent)
                .frame(width: 46, height: 46)
                .background(accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(cell.enb.map { "eNB \($0)" } ?? cell.gnb.map { "gNB \($0)" } ?? "Cellule")
                    .font(SQFont.display(20, .bold))
                    .foregroundStyle(SQColor.label)
                if let key = cell.operatorKey {
                    Text(operatorLabel(key))
                        .font(SQFont.body(14.5, .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                }
            }
            Spacer()
        }
    }

    /// Le point de la carte n'est PAS le pylône. Le dire est la seule façon
    /// d'éviter qu'on prenne un centroïde à 1 km pour une position d'antenne.
    private var provenanceBanner: some View {
        HStack(alignment: .top, spacing: SQSpace.sm) {
            Image(systemName: "scope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SQColor.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Position estimée, pas relevée")
                    .font(SQFont.body(13.5, .semibold))
                    .foregroundStyle(SQColor.label)
                Text(radiusSentence)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    private var radiusSentence: String {
        guard let radius = cell.radiusMeters, radius > 0 else {
            return String(localized: "Ce point est la moyenne des endroits où la cellule a été captée — l'antenne est ailleurs.")
        }
        return String(localized: "Ce point est la moyenne des endroits où la cellule a été captée. L'antenne se trouve quelque part dans un rayon de \(SQUnits.distance(meters: radius)).")
    }

    private var evidence: [(String, String?)] {
        [
            ("Confiance", cell.confidenceLevel.map { level in
                cell.confidenceScore.map { "\(level) (\(Int($0))/100)" } ?? level
            }),
            ("Mesures", cell.observationCount.map { "\($0)" }),
            ("Contributeurs", cell.distinctUserCount.map { "\($0)" }),
            ("Précision GPS médiane", cell.medianAccuracyMeters.map { SQUnits.distance(meters: $0) }),
            ("Rayon d'incertitude", cell.radiusMeters.map { SQUnits.distance(meters: $0) }),
            ("Première mesure", cell.firstObservedAt.map { SignalFormatters.date($0) }),
            ("Dernière mesure", cell.lastObservedAt.map { SignalFormatters.date($0, relative: true) })
        ]
    }

    /// Autres cellules au même endroit — souvent le même pylône vu par d'autres
    /// opérateurs. Les cocher permet de créer UN site qui les porte toutes.
    private var groupCandidates: [AndroidCommunitySiteMarker] {
        nearbyCells.filter { $0.id != cell.id }
    }

    private var grouping: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Autres cellules à proximité")
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            Text("Un même pylône porte souvent plusieurs opérateurs. Coche celles qui sont sur le même support pour n'en faire qu'un site.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(groupCandidates, id: \.id) { other in
                    Button {
                        Haptics.selection()
                        if selectedIds.contains(other.id) { selectedIds.remove(other.id) }
                        else { selectedIds.insert(other.id) }
                    } label: {
                        HStack(spacing: SQSpace.sm) {
                            Image(systemName: selectedIds.contains(other.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17))
                                .foregroundStyle(selectedIds.contains(other.id) ? SQColor.success : SQColor.labelTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(other.operatorKey.map(operatorLabel) ?? "Opérateur inconnu")
                                    .font(SQFont.body(14, .semibold))
                                    .foregroundStyle(SQColor.label)
                                Text([other.enb.map { "eNB \($0)" }, other.radioNodeType]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(SQType.caption)
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, SQSpace.md)
                        .padding(.vertical, SQSpace.sm + 1)
                    }
                    .buttonStyle(SQPressButtonStyle())
                    Divider().overlay(SQColor.separator).padding(.leading, SQSpace.md)
                }
            }
            .padding(.vertical, SQSpace.xs)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
            .sqShadowCard()
        }
    }

    private var createButton: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Button {
                Haptics.selection()
                let selected = [cell] + groupCandidates.filter { selectedIds.contains($0.id) }
                onCreateSite(selected)
            } label: {
                HStack(spacing: SQSpace.sm) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 15, weight: .semibold))
                    Text(selectedIds.isEmpty
                         ? "Créer le site à partir de cette cellule"
                         : "Créer le site à partir de \(selectedIds.count + 1) cellules")
                        .font(SQFont.body(15, .semibold))
                }
                .foregroundStyle(SQColor.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SQSpace.md)
                .background(SQColor.brandRed, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            }
            .buttonStyle(SQPressButtonStyle())
            Text("Les identifiants radio sont repris tels quels ; c'est toi qui places l'antenne au bon endroit.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Habillage

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(LocalizedStringKey(title))
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.vertical, SQSpace.xs)
                .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
                .sqShadowCard()
        }
    }

    @ViewBuilder
    private func rows(_ values: [(String, String?)]) -> some View {
        ForEach(values.indices, id: \.self) { index in
            let (label, value) = values[index]
            if let value, !value.isEmpty {
                HStack(alignment: .top) {
                    Text(LocalizedStringKey(label))
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                    Spacer()
                    Text(value)
                        .font(SQFont.body(14, .semibold))
                        .foregroundStyle(SQColor.label)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, SQSpace.md)
                .padding(.vertical, SQSpace.sm + 1)
                Divider().overlay(SQColor.separator).padding(.leading, SQSpace.md)
            }
        }
    }
}
