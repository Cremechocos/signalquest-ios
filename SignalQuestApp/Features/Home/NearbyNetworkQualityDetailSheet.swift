import SwiftUI

/// Explique le verdict « Réseau … » de l'Accueil : d'où viennent les données
/// (mesures communautaires filtrées sur un opérateur identifié, dans un rayon donné) et
/// comment il est calculé (le moins bon de la couverture et du débit). Lecture seule.
struct NearbyNetworkQualityDetailSheet: View {
    let quality: NearbyNetworkQuality
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                header
                Text("Ce verdict s’appuie sur les mesures partagées par la communauté à moins de \(radiusText) de toi, pour le réseau \(quality.operatorLabel).")
                    .font(SQType.callout)
                    .foregroundStyle(SQColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                criteriaTile
                SQNotice(message: String(localized: "On retient le moins bon des deux critères : un réseau « au top » doit bien capter et être rapide.")
                         + " " + limitingText)
                VStack(spacing: SQSpace.sm) {
                    SQFactRow(label: String(localized: "Mesures"), value: quality.sampleCount.formatted(.number))
                    SQFactRow(label: String(localized: "Rayon"), value: radiusText)
                    SQFactRow(label: String(localized: "Opérateur"), value: operatorSourceText)
                }
                Text("En itinérance, l’opérateur estimé ne confirme pas le réseau radio utilisé.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .presentationDetents([.medium, .large])
        .sqSheet()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: SQSpace.sm2) {
            VStack(alignment: .leading, spacing: SQSpace.xs) {
                Text("D’où vient ce verdict").sqKicker()
                Text(verbatim: "\(quality.operatorLabel) · \(quality.level.title)")
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .sqHeader()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "home.verdict.close") { dismiss() }
        }
    }

    private var operatorSourceText: String {
        switch quality.operatorSource {
        case .ipAsn: return String(localized: "estimé par l’accès Internet")
        case .simPlmn: return String(localized: "déduit de la SIM")
        }
    }

    // MARK: Les deux critères

    private var criteriaTile: some View {
        VStack(spacing: SQSpace.md) {
            criterionRow(
                icon: "antenna.radiowaves.left.and.right",
                title: String(localized: "Signal"),
                band: quality.signalBand,
                valueText: quality.medianRsrpDbm.map { "\($0) dBm" } ?? "—",
                caption: String(localized: "Force du signal capté : plus la valeur est proche de zéro, plus il est puissant.")
            )
            Divider().overlay(SQColor.separator)
            criterionRow(
                icon: "speedometer",
                title: String(localized: "Débit"),
                band: quality.speedBand,
                valueText: quality.medianDownloadMbps.map { SQUnits.throughput(mbps: Double($0)) } ?? "—",
                caption: String(localized: "Vitesse de téléchargement typique mesurée sur ce réseau.")
            )
        }
        .padding(SQSpace.md)
        .sqSurface(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func criterionRow(icon: String, title: String, band: CoverageQualityBand, valueText: String, caption: String) -> some View {
        let known = band != .unknown
        return HStack(alignment: .top, spacing: SQSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SQColor.ink2)
                .frame(width: 38, height: 38)
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.iconTile, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SQSpace.xs2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: title).font(SQType.rowTitle).foregroundStyle(SQColor.label)
                    Spacer(minLength: SQSpace.sm)
                    Text(verbatim: valueText).font(SQType.rowTitle).monospacedDigit().foregroundStyle(SQColor.label)
                }
                // Texte à l'encre, couleur portée par le point : la teinte de la bande sur
                // sa propre teinte ne tient pas 4,5:1.
                HStack(spacing: 5) {
                    if known {
                        Circle().fill(band.swiftUIColor).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    Text(verbatim: known ? band.title : String(localized: "Pas assez de mesures"))
                        .font(SQType.caption(.bold))
                        .foregroundStyle(known ? SQColor.label : SQColor.labelSecondary)
                }
                .padding(.horizontal, SQSpace.sm)
                .padding(.vertical, 3)
                .background(known ? band.swiftUIColor.opacity(0.14) : SQColor.chip, in: Capsule(style: .continuous))
                Text(verbatim: caption)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// La phrase qui dit quel critère fixe le verdict ; en gras dans l'encadré.
    private var limitingText: String {
        switch limiting {
        case .coverage: return String(localized: "**Ici, c’est le signal qui tire le verdict vers le bas.**")
        case .speed: return String(localized: "**Ici, c’est le débit qui tire le verdict vers le bas.**")
        case .tie: return String(localized: "**Ici, signal et débit sont au même niveau.**")
        case .coverageOnly: return String(localized: "**Ici, seul le signal a assez de mesures : le verdict s’appuie dessus.**")
        case .speedOnly: return String(localized: "**Ici, seul le débit a assez de mesures : le verdict s’appuie dessus.**")
        }
    }

    // MARK: Dérivés

    private enum Limiting { case coverage, speed, tie, coverageOnly, speedOnly }

    /// Quel critère fixe le verdict (le rang le plus bas), ou lequel est seul disponible.
    private var limiting: Limiting {
        switch (quality.signalBand.qualityRank, quality.speedBand.qualityRank) {
        case let (signal?, speed?):
            if signal < speed { return .coverage }
            if speed < signal { return .speed }
            return .tie
        case (nil, _?): return .speedOnly
        case (_?, nil): return .coverageOnly
        case (nil, nil): return .tie
        }
    }

    private var radiusText: String {
        SQUnits.distanceCompact(meters: Double(quality.radiusMeters))
    }
}
