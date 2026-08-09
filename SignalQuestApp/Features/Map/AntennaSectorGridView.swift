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
    /// Faisceaux hertziens. Ils n'entrent NI dans la grille NI dans le compte de
    /// secteurs — un FH ne porte pas de bande mobile — mais ils appartiennent à
    /// la rose : ce sont des directions réelles du pylône.
    var fhBeams: [AntennaFhLink] = []
    let technologies: [String]
    /// Bandes déclarées à l'ANFR mais pas encore allumées.
    let projectBands: [String]
    let antennaHeightMeters: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            technologyRow
            if columns.count > 1 {
                grid
            } else {
                // Un site mono-secteur (omni, indoor) n'a pas de colonnes à
                // comparer : la grille n'apporterait qu'une colonne de points.
                bandRow
            }
            if columns.count > 1 { stateLegend }
            // Une rose sans azimut n'est qu'un cercle vide : les datasets DROM ne
            // publient pas l'orientation des secteurs, autant le dire.
            if !columns.isEmpty || !fhBeams.isEmpty {
                AzimuthFanView(azimuths: columns.map(\.azimuth), fhAzimuths: fhBeams.map(\.azimuth), color: tint)
                    .frame(height: 170)
                    .frame(maxWidth: .infinity)
            }
            fhNote
            footnote
        }
    }

    /// Le backend n'envoie le détail par secteur que lorsque les secteurs
    /// DIFFÈRENT. Son absence n'est donc pas un trou : elle affirme que chaque
    /// secteur porte toutes les bandes du site, et la grille se remplit
    /// entièrement. C'est cette lecture qui permet de l'afficher toujours.
    private var columns: [AntennaSectorSystems] {
        if sectorSystems.count > 1 { return sectorSystems }
        return azimuths.map { AntennaSectorSystems(azimuth: $0, systems: siteBands) }
    }

    private var hasSectorDetail: Bool { sectorSystems.count > 1 }

    /// Toutes les bandes rencontrées, triées par technologie puis par fréquence
    /// décroissante — la 5G 3500 en haut, la 4G 700 en bas : c'est l'ordre dans
    /// lequel on cherche « est-ce que ce site a la 3500 ? ».
    private var rows: [String] {
        let measured = hasSectorDetail
            ? Array(Set(sectorSystems.flatMap(\.systems)))
            : siteBands
        // Une bande seulement déclarée mérite sa ligne : c'est justement ce qu'on
        // vient vérifier quand on se demande si la 3500 est allumée sur ce site.
        let plannedOnly = projectBands.filter { planned in
            !measured.contains { Self.technology(of: $0) == Self.technology(of: planned)
                && Self.frequency(in: $0) == Self.frequency(in: planned) }
        }
        return (measured + plannedOnly).sorted { left, right in
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

    /// Largeur de la colonne des bandes. FIXE, et c'est ce qui compte : c'est
    /// elle qui garantit que toutes les lignes alignent leurs colonnes, et elle
    /// rend la largeur de la grille prévisible, donc mesurable par
    /// `ViewThatFits`. En `maxWidth: .infinity`, le `HStack` la partageait à
    /// parts égales avec les colonnes de secteurs et l'écrasait à ~30 pt.
    private static let bandColumnWidth: CGFloat = 88

    /// Cas hétérogène : la grille, où l'écart saute aux yeux.
    ///
    /// La grille s'adapte à la largeur disponible au lieu de l'imposer. Avec des
    /// colonnes rigides de 42 pt, un site à dix secteurs réclamait 420 pt là où
    /// la fiche en propose ~325 : la colonne des bandes tombait à zéro (libellés
    /// invisibles) et surtout TOUTE la fiche devenait plus large que l'écran, que
    /// le ScrollView centrait alors — rognée des deux côtés, sur toute sa hauteur.
    /// Sous six secteurs, la première candidate passe et le rendu est inchangé.
    private var grid: some View {
        ViewThatFits(in: .horizontal) {
            gridBody(columnWidth: 42)
            gridBody(columnWidth: 34)
            gridBody(columnWidth: 27)
            gridBody(columnWidth: 22)
            // Filet de sécurité : au-delà d'une douzaine de secteurs, même la
            // grille la plus serrée déborde. Un ScrollView prend toujours la
            // largeur qu'on lui propose — la fiche reste cadrée quoi qu'il arrive.
            ScrollView(.horizontal, showsIndicators: false) {
                gridBody(columnWidth: 27)
            }
        }
    }

    private func gridBody(columnWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("")
                    .frame(width: Self.bandColumnWidth, alignment: .leading)
                Spacer(minLength: 0)
                ForEach(columns) { sector in
                    Text("\(Int(sector.azimuth.rounded()))°")
                        .font(SQFont.archivo(10.5, .bold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: columnWidth)
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
                        .frame(width: Self.bandColumnWidth, alignment: .leading)
                    Spacer(minLength: 0)
                    ForEach(columns) { sector in
                        cell(band: band, sector: sector)
                            .frame(width: columnWidth)
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

    /// État d'une bande sur un secteur. La couleur ne redit plus la technologie —
    /// elle est déjà portée par la ligne et par les badges du haut — mais répond
    /// à la seule question utile devant une grille : est-ce que ça émet ?
    private enum BandState {
        case active, planned, absent

        var color: Color {
            switch self {
            case .active: return SQColor.success
            case .planned: return SQColor.warning
            case .absent: return SQColor.separator
            }
        }

        var diameter: CGFloat {
            switch self {
            case .active: return 9
            case .planned: return 9
            case .absent: return 6
            }
        }
    }

    private func state(of band: String, on sector: AntennaSectorSystems) -> BandState {
        if sector.systems.contains(band) { return .active }
        return isPlanned(band) ? .planned : .absent
    }

    /// Les libellés du projet ANFR (« 5G 3500 ») ne s'écrivent pas comme ceux des
    /// systèmes en service (« 5G NR 3500 ») : on compare la technologie et la
    /// fréquence plutôt que les chaînes.
    private func isPlanned(_ band: String) -> Bool {
        let tech = Self.technology(of: band)
        let frequency = Self.frequency(in: band)
        return projectBands.contains { planned in
            Self.technology(of: planned) == tech && Self.frequency(in: planned) == frequency
        }
    }

    private func cell(band: String, sector: AntennaSectorSystems) -> some View {
        let state = state(of: band, on: sector)
        return Circle()
            .fill(state.color)
            .frame(width: state.diameter, height: state.diameter)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(accessibilityLabel(for: state, band: band, sector: sector))
    }

    private func accessibilityLabel(for state: BandState, band: String, sector: AntennaSectorSystems) -> String {
        let azimuth = Int(sector.azimuth.rounded())
        switch state {
        case .active: return String(localized: "\(band) en service sur le secteur \(azimuth) degrés")
        case .planned: return String(localized: "\(band) déclaré mais pas encore en service sur le secteur \(azimuth) degrés")
        case .absent: return String(localized: "\(band) absent du secteur \(azimuth) degrés")
        }
    }

    /// Légende des trois états — sans elle, trois couleurs de points ne veulent
    /// rien dire.
    private var stateLegend: some View {
        FlowLayout(spacing: 10) {
            legendDot(.active, label: String(localized: "en service"))
            if rows.contains(where: { isPlanned($0) }) {
                legendDot(.planned, label: String(localized: "déclaré, pas encore allumé"))
            }
            if rows.contains(where: { band in columns.contains { !$0.systems.contains(band) } }) {
                legendDot(.absent, label: String(localized: "absent"))
            }
        }
    }

    private func legendDot(_ state: BandState, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            Text(label)
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
        }
    }

    private func isUniform(_ band: String) -> Bool {
        columns.allSatisfy { $0.systems.contains(band) }
    }

    /// Ce que dit l'aiguille de la rose, et ce qu'elle ne dit pas.
    ///
    /// La légende est le dessin lui-même, repris en miniature : rien à traduire
    /// entre la rose et sa clé.
    @ViewBuilder
    private var fhNote: some View {
        if !fhBeams.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    FhNeedleKey(color: tint)
                        .frame(width: 26, height: 9)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                    Text(fhBeams.count == 1
                         ? String(localized: "Faisceau hertzien")
                         : String(localized: "\(fhBeams.count) faisceaux hertziens"))
                        .font(SQFont.body(11.5, .semibold))
                        .foregroundStyle(SQColor.label)
                }

                // Une ligne par parabole : direction, taille, et vers quoi elle
                // pointe. L'azimut tient une colonne fixe — sans elle, l'œil ne
                // retrouve plus la direction d'une ligne à l'autre.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(fhBeams.prefix(8)) { beam in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(Int(beam.azimuth.rounded()))°")
                                .font(SQFont.archivo(11.5, .bold))
                                .foregroundStyle(tint)
                                .frame(width: 34, alignment: .leading)
                            Text(describe(beam))
                                .font(SQType.micro)
                                .foregroundStyle(SQColor.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Dire d'où vient chaque limite vaut mieux que laisser croire à
                // un trou de l'app. Deux limites, deux natures : la fréquence
                // n'est pas publiée, le site visé n'est pas publié NON PLUS mais
                // se déduit — et une déduction se présente comme telle.
                Text(fhBeams.contains(where: { $0.target != nil })
                     ? "Des paraboles point-à-point : elles raccordent ce site au réseau, ne desservent personne, et ne comptent pas dans les secteurs. Le site visé est déduit du fait que les deux paraboles se répondent — le registre ne le publie pas, pas plus que les fréquences."
                     : "Des paraboles point-à-point : elles raccordent ce site au réseau, ne desservent personne, et ne comptent pas dans les secteurs. Le registre en publie la direction — ni la fréquence, ni le site visé.")
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// « parabole 0,6 m — vers le site 3012724 (SFR), à 4,7 km ». On n'écrit que
    /// ce qu'on sait : une parabole sans cible ne mentionne pas de cible, et une
    /// direction sans rien de plus ne rend pas une ligne vide.
    private func describe(_ beam: AntennaFhLink) -> String {
        var parts: [String] = []
        if let dish = beam.dishMeters {
            let size = dish.formatted(.number.precision(.fractionLength(0...1)))
            parts.append(String(localized: "parabole \(size) m"))
        }
        if let target = beam.target {
            let distance = SQUnits.distance(kilometers: target.distanceKm)
            let owner = target.operatorName.isEmpty ? "" : " (\(target.operatorName))"
            parts.append(String(localized: "vers le site \(target.supId)\(owner), à \(distance)"))
        }
        return parts.isEmpty ? String(localized: "direction seule") : parts.joined(separator: " — ")
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
        let count = columns.count
        if count == 0 {
            return String(localized: "L'orientation des secteurs n'est pas publiée pour ce site — seules ses bandes le sont.")
        }
        guard count > 1 else {
            // Pas « à l'ANFR » : la même grille sert le Canada (ISED), la Belgique
            // (BIPT) et la Suisse (OFCOM).
            return String(localized: "Bandes déclarées au registre pour ce site.")
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

/// L'aiguille de la rose, en miniature : trait pointillé, barre au bout. Le même
/// tracé que `AzimuthFanView`, pour que la légende n'ait rien à expliquer.
private struct FhNeedleKey: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            var needle = Path()
            needle.move(to: CGPoint(x: 0, y: y))
            needle.addLine(to: CGPoint(x: size.width - 2, y: y))
            context.stroke(
                needle,
                with: .color(color.opacity(0.75)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 2.5])
            )
            var dish = Path()
            dish.move(to: CGPoint(x: size.width - 2, y: 0))
            dish.addLine(to: CGPoint(x: size.width - 2, y: size.height))
            context.stroke(
                dish,
                with: .color(color.opacity(0.85)),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
            )
        }
        .accessibilityHidden(true)
    }
}
