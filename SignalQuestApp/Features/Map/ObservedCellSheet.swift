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
    /// Appelé avec les cellules retenues quand l'utilisateur veut créer le site.
    let onCreateSite: ([AndroidCommunitySiteMarker]) -> Void

    @State private var selectedIds: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private var plmn: String? {
        guard let mcc = cell.mcc, let mnc = cell.mnc else { return nil }
        return String(format: "%03d-%02d", mcc, mnc)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.md) {
                header
                provenanceBanner
                VStack(spacing: SQSpace.sm) { rows(facts) }
                if !groupCandidates.isEmpty { grouping }
                createButton
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .sqSheet(background: SQColor.bg)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("Cellule observée").sqKicker()
                Text(title)
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
                HStack(spacing: SQSpace.xs2) {
                    if let tech = cell.radioNodeType, !tech.isEmpty {
                        MapTechTag(technology: tech, label: tech)
                    }
                    if let count = cell.distinctUserCount, count > 0 {
                        Text("vue par \(count) contributeurs")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "observedCell.close") { dismiss() }
        }
    }

    /// « eNB 812977 · Orange » : l'identité radio d'abord, l'opérateur ensuite.
    private var title: String {
        let identity = cell.enb.map { "eNB \($0)" } ?? cell.gnb.map { "gNB \($0)" } ?? String(localized: "Cellule")
        guard let key = cell.operatorKey else { return identity }
        return identity + " · " + operatorLabel(key)
    }

    /// Le point de la carte n'est PAS le pylône. Le dire est la seule façon
    /// d'éviter qu'on prenne un centroïde à 1 km pour une position d'antenne.
    private var provenanceBanner: some View {
        SQNotice(message: radiusSentence, title: String(localized: "Position estimée, pas relevée"),
                 systemImage: "scope", tone: .warning)
    }

    private var radiusSentence: String {
        guard let radius = cell.radiusMeters, radius > 0 else {
            return String(localized: "Ce point est la moyenne des endroits où la cellule a été captée — l'antenne est ailleurs.")
        }
        return String(localized: "Ce point est la moyenne des endroits où la cellule a été captée. L'antenne se trouve quelque part dans un rayon de \(SQUnits.distance(meters: radius)).")
    }

    /// Identifiants et fiabilité en une seule liste ; l'opérateur, la
    /// technologie et les contributeurs sont déjà dans l'en-tête.
    private var facts: [(String, String?)] {
        [
            ("PLMN", plmn),
            ("CI", cell.cellId ?? cell.ci),
            ("PCI", cell.pci.map(String.init)),
            ("TAC", cell.tac),
            ("EARFCN", cell.earfcn.map(String.init)),
            ("NR-ARFCN", cell.nrarfcn.map(String.init)),
            ("Bande", cell.band.map { SQUnits.band($0, isNR: cell.nrarfcn != nil) }),
            ("Confiance", cell.confidenceLevel.map { level in
                let label = Self.confidenceLabel(level)
                return cell.confidenceScore.map { "\(label) (\(Int($0))/100)" } ?? label
            }),
            ("Mesures", cell.observationCount.map { "\($0)" }),
            ("Précision GPS médiane", cell.medianAccuracyMeters.map { SQUnits.distance(meters: $0) }),
            ("Première mesure", cell.firstObservedAt.map { SignalFormatters.date($0) }),
            ("Dernière mesure", cell.lastObservedAt.map { SignalFormatters.date($0, relative: true) })
        ]
    }

    /// Niveau de confiance du serveur (« HIGH », « MEDIUM », « LOW ») dans la langue de l'app ; une
    /// valeur inconnue reste telle quelle plutôt que d'être devinée.
    static func confidenceLabel(_ level: String) -> String {
        switch level.uppercased() {
        case "HIGH": return String(localized: "Élevée")
        case "MEDIUM": return String(localized: "Moyenne")
        case "LOW": return String(localized: "Faible")
        default: return level
        }
    }

    /// Autres cellules au même endroit — souvent le même pylône vu par d'autres
    /// opérateurs. Les cocher permet de créer UN site qui les porte toutes.
    private var groupCandidates: [AndroidCommunitySiteMarker] {
        nearbyCells.filter { $0.id != cell.id }
    }

    private var grouping: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text("Autres cellules à proximité").sqKicker()
            VStack(spacing: 0) {
                ForEach(groupCandidates, id: \.id) { other in
                    candidateRow(other)
                    if other.id != groupCandidates.last?.id {
                        Divider().overlay(SQColor.separator)
                    }
                }
            }
            .padding(.horizontal, SQSpace.md)
            .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
            Text("Un même pylône porte souvent plusieurs opérateurs. Coche celles qui sont sur le même support pour n'en faire qu'un site.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func candidateRow(_ other: AndroidCommunitySiteMarker) -> some View {
        let isSelected = selectedIds.contains(other.id)
        let name = other.operatorKey.map(operatorLabel) ?? String(localized: "Opérateur inconnu")
        return Button {
            Haptics.selection()
            if isSelected { selectedIds.remove(other.id) } else { selectedIds.insert(other.id) }
        } label: {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? SQColor.label : SQColor.labelTertiary)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(SQBrand.operatorColor(name))
                    .frame(width: 4, height: 22)
                Text(([name] + [other.enb.map { "eNB \($0)" } ?? other.gnb.map { "gNB \($0)" }].compactMap { $0 })
                    .joined(separator: " · "))
                    .font(SQType.callout(.semibold))
                    .foregroundStyle(SQColor.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let tech = other.radioNodeType, !tech.isEmpty {
                    MapTechTag(technology: tech, label: tech)
                }
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Le bouton dit combien de cellules seront reprises et suit les cases.
    private var createButton: some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            GradientButton(
                selectedIds.isEmpty
                    ? String(localized: "Créer le site à partir de cette cellule")
                    : String(localized: "Créer le site à partir de \(selectedIds.count + 1) cellules"),
                systemImage: "plus",
                allowsMultiline: true
            ) {
                Haptics.selection()
                let selected = [cell] + groupCandidates.filter { selectedIds.contains($0.id) }
                onCreateSite(selected)
            }
            Text("Les identifiants radio sont repris tels quels ; c'est toi qui places l'antenne au bon endroit.")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func rows(_ values: [(String, String?)]) -> some View {
        ForEach(values.indices, id: \.self) { index in
            let (label, value) = values[index]
            if let value, !value.isEmpty {
                SQFactRow(label: label, value: value)
            }
        }
    }
}
