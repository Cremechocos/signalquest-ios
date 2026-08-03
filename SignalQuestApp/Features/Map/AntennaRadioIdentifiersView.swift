import SwiftUI
import UIKit

/// Les identifiants radio d'un site, rangés comme on les cherche sur le terrain :
/// l'identité du site d'abord (eNB / gNB), puis un bloc par secteur.
///
/// La version précédente empilait des lignes clé-valeur — « PCI », « Cell ID »,
/// huit valeurs à la suite — sans jamais dire quelle cellule appartenait à quel
/// secteur. C'est pourtant la seule question qu'on se pose devant un pylône :
/// *celui qui pointe vers moi, c'est lequel ?*
struct AntennaRadioIdentifiersView: View {
    let identifiers: AntennaCellIdentifiers
    /// Azimuts du site, pour donner son orientation à chaque secteur.
    let azimuths: [Double]
    let tint: Color

    @State private var expandedSector: Int?
    @State private var copiedValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            siteIdentityRow
            ForEach(sectors) { sector in
                sectorCard(sector)
            }
            if !looseCells.isEmpty {
                looseCellsCard
            }
        }
    }

    // MARK: Identité du site

    private var siteIdentityRow: some View {
        HStack(spacing: 8) {
            if !identifiers.enb.isEmpty {
                identityTile(label: "eNB · 4G", values: identifiers.enb, color: SQBrand.techColor("4G"))
            }
            if !identifiers.gnb.isEmpty {
                identityTile(label: "gNB · 5G", values: identifiers.gnb, color: SQBrand.techColor("5G"))
            }
            if identifiers.enb.isEmpty && identifiers.gnb.isEmpty {
                Text("Aucun identifiant de site connu pour cet opérateur.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func identityTile(label: String, values: [String], color: Color) -> some View {
        Button {
            copy(values.joined(separator: " "))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(label)
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelSecondary)
                    Spacer(minLength: 0)
                    Image(systemName: copiedValue == values.joined(separator: " ") ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SQColor.labelTertiary)
                }
                Text(values.prefix(2).map(Self.grouped).joined(separator: " · "))
                    .font(SQFont.archivo(17, .bold))
                    .monospacedDigit()
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SQSpace.sm + 2)
            .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("\(label), \(values.joined(separator: ", ")). Toucher pour copier.")
    }

    // MARK: Secteurs

    private func sectorCard(_ sector: RadioSector) -> some View {
        let isExpanded = expandedSector == sector.id
        return VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            Button {
                Haptics.light()
                withAnimation(SQMotion.standard) {
                    expandedSector = isExpanded ? nil : sector.id
                }
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: SQSpace.xs + 2) {
                        Text(sector.title)
                            .font(SQFont.archivo(13, .bold))
                            .foregroundStyle(SQColor.label)
                        Spacer(minLength: 0)
                        ForEach(sector.technologies, id: \.self) { tech in
                            Text(tech)
                                .font(SQFont.body(10, .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(SQBrand.techColor(tech), in: Capsule(style: .continuous))
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SQColor.labelTertiary)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                    if !sector.pcis.isEmpty {
                        FlowChips(items: sector.pcis.map { "PCI \($0.value)" }, tint: tint)
                    }
                    if !isExpanded, !sector.cells.isEmpty {
                        Text("\(sector.cells.count) cellule\(sector.cells.count > 1 ? "s" : "")")
                            .font(SQType.micro)
                            .foregroundStyle(SQColor.labelTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SQPressButtonStyle())
            .accessibilityHint(isExpanded ? "Toucher pour replier les cellules" : "Toucher pour voir les cellules")

            if isExpanded {
                ForEach(sector.cells) { cell in
                    cellRow(cell)
                }
                if sector.cells.isEmpty {
                    Text("Aucune cellule identifiée sur ce secteur.")
                        .font(SQType.micro)
                        .foregroundStyle(SQColor.labelTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.md)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    /// Une cellule : son identité en tête, ses caractéristiques radio en dessous.
    /// Un tap copie la valeur — sur le terrain, on la recopie dans un carnet ou
    /// un outil tiers, et retaper quinze chiffres est le meilleur moyen de se
    /// tromper.
    private func cellRow(_ cell: AntennaCellIdEntry) -> some View {
        Button {
            copy(cell.value)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: SQSpace.xs) {
                    Text(cell.ci.map { "CI \($0)" } ?? "ECI \(cell.value)")
                        .font(SQFont.archivo(13, .bold))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.label)
                    Spacer(minLength: 0)
                    Image(systemName: copiedValue == cell.value ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SQColor.labelTertiary)
                }
                if cell.ci != nil {
                    Text("ECI \(cell.value)")
                        .font(SQFont.body(11))
                        .monospacedDigit()
                        .foregroundStyle(SQColor.labelSecondary)
                }
                let facts = [
                    cell.band.map { "B\($0)" },
                    cell.frequency,
                    cell.earfcn.map { "EARFCN \($0)" },
                    cell.arfcn.map { "ARFCN \($0)" },
                    cell.pci.map { "PCI \($0)" }
                ].compactMap { $0 }
                if !facts.isEmpty {
                    FlowChips(items: facts, tint: SQColor.labelSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SQSpace.sm)
            .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SQPressButtonStyle())
        .accessibilityLabel("Cellule \(cell.value). Toucher pour copier.")
    }

    private var looseCellsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cellules non rattachées à un secteur")
                .font(SQFont.archivo(13, .bold))
                .foregroundStyle(SQColor.label)
            ForEach(looseCells) { cell in
                cellRow(cell)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SQSpace.md)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
    }

    // MARK: Regroupement

    struct RadioSector: Identifiable {
        let id: Int
        let azimuth: Double?
        let pcis: [AntennaPciEntry]
        let cells: [AntennaCellIdEntry]

        var technologies: [String] {
            var seen: [String] = []
            for tech in pcis.compactMap(\.tech) + cells.compactMap(\.tech) where !seen.contains(tech) {
                seen.append(tech)
            }
            return seen.sorted(by: >) // 5G avant 4G
        }

        var title: String {
            guard let azimuth else { return String(localized: "Secteur \(id)") }
            return String(localized: "Secteur \(id) · \(Int(azimuth.rounded()))°")
        }
    }

    /// Un secteur par numéro connu. Une cellule sans secteur explicite est
    /// rattachée par son PCI : c'est le lien que le backend garantit, et sans lui
    /// la majorité des cellules resteraient orphelines.
    private var sectors: [RadioSector] {
        var pcisBySector: [Int: [AntennaPciEntry]] = [:]
        var sectorByPci: [String: Int] = [:]
        for entry in identifiers.pci {
            guard let sector = entry.sector else { continue }
            pcisBySector[sector, default: []].append(entry)
            sectorByPci[entry.value] = sector
        }
        var cellsBySector: [Int: [AntennaCellIdEntry]] = [:]
        for cell in identifiers.cellId {
            guard let sector = cell.sector ?? cell.pci.flatMap({ sectorByPci[$0] }) else { continue }
            cellsBySector[sector, default: []].append(cell)
        }
        let numbers = Set(pcisBySector.keys).union(cellsBySector.keys).sorted()
        return numbers.map { number in
            RadioSector(
                id: number,
                // Les secteurs sont numérotés à partir de 1 et suivent l'ordre des
                // azimuts publiés par l'ANFR.
                azimuth: azimuths.indices.contains(number - 1) ? azimuths[number - 1] : nil,
                pcis: pcisBySector[number] ?? [],
                cells: cellsBySector[number] ?? []
            )
        }
    }

    /// Ce qui n'a pu être rattaché à aucun secteur — affiché quand même, plutôt
    /// que perdu en silence.
    private var looseCells: [AntennaCellIdEntry] {
        var sectorByPci: [String: Int] = [:]
        for entry in identifiers.pci where entry.sector != nil {
            sectorByPci[entry.value] = entry.sector
        }
        return identifiers.cellId.filter { cell in
            cell.sector == nil && cell.pci.flatMap { sectorByPci[$0] } == nil
        }
    }

    // MARK: Copie

    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        withAnimation(SQMotion.snappy) { copiedValue = value }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run {
                withAnimation(SQMotion.standard) {
                    if copiedValue == value { copiedValue = nil }
                }
            }
        }
    }

    /// Groupe les chiffres par trois — un eNB à six chiffres se lit et se recopie
    /// beaucoup plus sûrement ainsi.
    private static func grouped(_ value: String) -> String {
        guard value.count > 4, value.allSatisfy(\.isNumber) else { return value }
        var result = ""
        for (offset, character) in value.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { result.append(" ") }
            result.append(character)
        }
        return String(result.reversed())
    }
}

/// Puces qui passent à la ligne. `LazyVGrid` ne sait pas faire du flux libre, et
/// un `ScrollView` horizontal cacherait des valeurs qu'on cherche justement à
/// comparer d'un coup d'œil.
struct FlowChips: View {
    let items: [String]
    let tint: Color

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(SQFont.body(10.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.13), in: Capsule(style: .continuous))
            }
        }
    }
}

/// Disposition en flux : place les éléments de gauche à droite et passe à la
/// ligne quand la largeur est atteinte.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var total = CGSize.zero
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                total.width = max(total.width, lineWidth)
                total.height += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
        total.width = max(total.width, lineWidth)
        total.height += lineHeight
        return total
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
