import SwiftUI

/// Les secteurs d'un site et ce qu'ils rayonnent, en grille : une ligne par
/// bande, une colonne par azimut.
///
/// La version précédente répétait la liste complète des bandes sous chaque
/// azimut. C'était non seulement redondant — en France les trois faces d'un
/// pylône portent presque toujours les mêmes bandes — mais trompeur : le dataset
/// n'associait alors aucune fréquence à un secteur, et cette répétition faisait
/// passer une duplication pour une mesure.
///
/// Le backend ne renvoie désormais le détail par secteur que lorsqu'il diffère
/// réellement. Quand tout est homogène, on affiche les bandes une seule fois et
/// on le dit.
struct AntennaSectorGridView: View {
    /// Azimuts du site, y compris quand aucun détail par secteur n'est disponible.
    let azimuths: [Double]
    /// Bandes du site, telles que publiées par l'ANFR (« LTE 800 », « 5G NR 3500 »).
    let siteBands: [String]
    /// Détail par secteur — vide quand tous les secteurs sont identiques.
    let sectorSystems: [AntennaSectorSystems]
    let technologies: [String]
    let antennaHeightMeters: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            technologyRow
            if hasSectorDetail {
                grid
            } else {
                bandRow
            }
            AzimuthFanView(azimuths: displayedAzimuths, color: tint)
                .frame(height: 170)
                .frame(maxWidth: .infinity)
            footnote
        }
    }

    private var hasSectorDetail: Bool { sectorSystems.count > 1 }

    private var displayedAzimuths: [Double] {
        hasSectorDetail ? sectorSystems.map(\.azimuth) : azimuths
    }

    /// Toutes les bandes rencontrées, triées par technologie puis par fréquence
    /// décroissante — la 5G 3500 en haut, la 4G 700 en bas : c'est l'ordre dans
    /// lequel on cherche « est-ce que ce site a la 3500 ? ».
    private var rows: [String] {
        let source = hasSectorDetail
            ? Array(Set(sectorSystems.flatMap(\.systems)))
            : siteBands
        return source.sorted { left, right in
            let leftRank = Self.technologyRank(left)
            let rightRank = Self.technologyRank(right)
            if leftRank != rightRank { return leftRank < rightRank }
            return (Self.frequency(in: left) ?? 0) > (Self.frequency(in: right) ?? 0)
        }
    }

    private var technologyRow: some View {
        FlowLayout(spacing: 5) {
            ForEach(technologies, id: \.self) { tech in
                Text(tech)
                    .font(SQFont.body(11, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SQBrand.techColor(tech), in: Capsule(style: .continuous))
            }
            if let antennaHeightMeters {
                Text("\(Int(antennaHeightMeters.rounded())) m")
                    .font(SQFont.body(11, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
            }
        }
    }

    /// Cas homogène : les bandes une seule fois.
    private var bandRow: some View {
        FlowLayout(spacing: 5) {
            ForEach(rows, id: \.self) { band in
                Text(band)
                    .font(SQFont.body(11, .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SQColor.surfaceMuted, in: Capsule(style: .continuous))
            }
        }
    }

    /// Cas hétérogène : la grille, où l'écart saute aux yeux.
    private var grid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(sectorSystems) { sector in
                    Text("\(Int(sector.azimuth.rounded()))°")
                        .font(SQFont.archivo(10.5, .bold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(width: 42)
                }
            }
            .padding(.bottom, 4)

            ForEach(rows, id: \.self) { band in
                HStack(spacing: 0) {
                    Text(band)
                        .font(SQFont.body(11.5))
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(sectorSystems) { sector in
                        cell(band: band, sector: sector)
                            .frame(width: 42)
                    }
                }
                .padding(.vertical, 5)
                .background(
                    // Seules les lignes où tous les secteurs ne sont pas d'accord
                    // sont surlignées : c'est là qu'est l'information.
                    isUniform(band) ? Color.clear : SQColor.surfaceMuted,
                    in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous)
                )
            }
        }
    }

    private func cell(band: String, sector: AntennaSectorSystems) -> some View {
        let present = sector.systems.contains(band)
        return Circle()
            .fill(present ? SQBrand.techColor(Self.technology(of: band)) : SQColor.separator)
            .frame(width: present ? 9 : 6, height: present ? 9 : 6)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(present
                ? String(localized: "\(band) présent sur le secteur \(Int(sector.azimuth.rounded())) degrés")
                : String(localized: "\(band) absent du secteur \(Int(sector.azimuth.rounded())) degrés"))
    }

    private func isUniform(_ band: String) -> Bool {
        sectorSystems.allSatisfy { $0.systems.contains(band) }
    }

    @ViewBuilder
    private var footnote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: hasSectorDetail ? "square.grid.3x1.below.line.grid.1x2" : "equal.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SQColor.labelTertiary)
            Text(hasSectorDetail
                 ? String(localized: "Les secteurs de ce site ne portent pas les mêmes bandes — les lignes surlignées sont celles qui diffèrent.")
                 : sectorCountLabel)
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sectorCountLabel: String {
        let count = displayedAzimuths.count
        guard count > 1 else {
            return String(localized: "Bandes déclarées à l'ANFR pour ce site.")
        }
        return String(localized: "Les \(count) secteurs portent les mêmes bandes.")
    }

    // MARK: Tri

    /// « 5G NR 3500 » → « 5G ». Le libellé ANFR porte la techno en tête.
    static func technology(of band: String) -> String {
        let upper = band.uppercased()
        if upper.contains("5G") || upper.contains("NR") { return "5G" }
        if upper.contains("LTE") || upper.contains("4G") { return "4G" }
        if upper.contains("UMTS") || upper.contains("3G") { return "3G" }
        if upper.contains("GSM") || upper.contains("2G") { return "2G" }
        return band
    }

    private static func technologyRank(_ band: String) -> Int {
        switch technology(of: band) {
        case "5G": return 0
        case "4G": return 1
        case "3G": return 2
        case "2G": return 3
        default: return 4
        }
    }

    private static func frequency(in band: String) -> Int? {
        guard let range = band.range(of: #"\d{3,4}"#, options: .regularExpression) else { return nil }
        return Int(band[range])
    }
}
