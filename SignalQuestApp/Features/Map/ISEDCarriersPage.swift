import SwiftUI

/// Porteuses d'un site canadien (contrat ISED r1, étapes b, c et g1), rangées en une
/// carte par secteur comme la fiche Web validée par Alexandre le 11/11
/// (`apps/web/lib/ised-sheet.ts`, mêmes règles, mêmes libellés).
///
/// Le serveur sert des valeurs typées (unité dans le nom du champ) : on les formate
/// dans la langue de l'app et on n'affiche que ce qui est connu. Une valeur absente
/// OMET la rangée, jamais de « — » ni de chiffre plausible, et aucune liste n'est
/// coupée sans le dire.
struct ISEDCarrierSheet: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
        /// Lecture VoiceOver du libellé quand l'abréviation (DL, UL, TDD) ne suffit pas.
        var spokenLabel: String? = nil
    }

    struct Carrier: Equatable {
        let title: String?
        let bandId: String?
        /// « 4G » ou « 5G », pour la couleur de génération.
        let generation: String?
        let rows: [Row]
    }

    struct Sector: Equatable {
        let title: String
        let rows: [Row]
        let note: String?
        let carriers: [Carrier]
    }

    let sectors: [Sector]
    let source: [String]
    /// Étape d : n° et catégorie de chaque licence, puis le titulaire. Vide tant que
    /// l'import ne sert pas les licences (le titulaire seul reste dans Technique).
    var licences: [Row] = []

    private static let nbsp = "\u{00A0}"

    static func make(carriers: [AntennaRadioCarrier], azimuths: [Double], datasetPublishedAt: String?,
                     licences: [ISEDSiteLicence] = [], holder: String? = nil,
                     locale: Locale = .current) -> ISEDCarrierSheet {
        let groups = group(carriers, azimuths: azimuths)
        let directional = groups.filter { $0.kind == .sector }
        let sectors = groups.map { group -> Sector in
            let title: String
            switch group.kind {
            case .omni: title = String(localized: "Antennes omnidirectionnelles")
            case .unknown: title = String(localized: "Orientation inconnue")
            case .sector:
                let index = (directional.firstIndex(of: group) ?? 0) + 1
                let azimuth = number(Double(group.azimuth ?? 0), 0, locale)
                title = String(localized: "Secteur \(index) · \(azimuth)° \(compassWord(Double(group.azimuth ?? 0)))")
            }
            let (rows, note) = sectorRows(group.carriers, omni: group.kind == .omni, locale: locale)
            return Sector(title: title, rows: rows, note: note,
                          carriers: group.carriers.map { carrierView($0, locale: locale) })
        }
        return ISEDCarrierSheet(sectors: sectors, source: sourceLines(carriers, datasetPublishedAt: datasetPublishedAt, locale: locale),
                                licences: licenceRows(licences, holder: holder))
    }

    private static func licenceRows(_ licences: [ISEDSiteLicence], holder: String?) -> [Row] {
        guard !licences.isEmpty else { return [] }
        var rows: [Row] = []
        for licence in licences {
            rows.append(Row(label: String(localized: "N° de licence"), value: licence.number))
            if let category = licence.category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty {
                rows.append(Row(label: String(localized: "Catégorie"), value: category))
            }
        }
        if let holder = holder?.trimmingCharacters(in: .whitespacesAndNewlines), !holder.isEmpty {
            rows.append(Row(label: String(localized: "Titulaire"), value: holder))
        }
        return rows
    }

    // MARK: Regroupement

    private enum Kind: Int { case sector, omni, unknown }

    private struct Group: Equatable {
        let key: String
        let azimuth: Int?
        let kind: Kind
        var carriers: [AntennaRadioCarrier]
    }

    /// Les azimuts du site (sans le faux 0° des omni) donnent les secteurs, même sans
    /// porteuse lisible ; une porteuse omni va dans sa propre carte, une porteuse sans
    /// azimut dans « Orientation inconnue ».
    private static func group(_ carriers: [AntennaRadioCarrier], azimuths: [Double]) -> [Group] {
        var groups: [Group] = []
        func add(_ key: String, _ azimuth: Int?, _ kind: Kind) -> Int {
            if let index = groups.firstIndex(where: { $0.key == key }) { return index }
            groups.append(Group(key: key, azimuth: azimuth, kind: kind, carriers: []))
            return groups.count - 1
        }
        for azimuth in azimuths where azimuth.isFinite {
            let rounded = Int(azimuth.rounded())
            _ = add("az:\(rounded)", rounded, .sector)
        }
        for carrier in carriers {
            let index: Int
            if carrier.omni == true {
                index = add("omni", nil, .omni)
            } else if let azimuth = carrier.sectorAzimuthDeg, azimuth.isFinite {
                let rounded = Int(azimuth.rounded())
                index = add("az:\(rounded)", rounded, .sector)
            } else {
                index = add("unknown", nil, .unknown)
            }
            groups[index].carriers.append(carrier)
        }
        return groups.enumerated().sorted { left, right in
            if left.element.kind != right.element.kind { return left.element.kind.rawValue < right.element.kind.rawValue }
            if left.element.azimuth != right.element.azimuth { return (left.element.azimuth ?? 0) < (right.element.azimuth ?? 0) }
            return left.offset < right.offset
        }.map(\.element)
    }

    // MARK: Secteur

    private static func sectorRows(_ carriers: [AntennaRadioCarrier], omni: Bool, locale: Locale) -> ([Row], String?) {
        var rows: [Row] = []
        func numbers(_ pick: (AntennaRadioCarrier) -> Double?, _ unit: String?) -> [String] {
            distinct(carriers.compactMap(pick).filter(\.isFinite)).map { value in
                let text = number(value, 1, locale)
                return unit.map { $0 == "°" ? "\(text)°" : "\(text)\(nbsp)\($0)" } ?? text
            }
        }
        if !omni {
            let widths = numbers(\.sectorBeamwidthDeg, "°")
            if !widths.isEmpty { rows.append(Row(label: String(localized: "Ouverture horizontale"), value: widths.joined(separator: ", "))) }
        }
        // « Samsung · active (AAS), 4 antennes » : fabricant, type en toutes lettres, nombre d'antennes au-delà d'une.
        let types = distinct(carriers.map { carrier -> String in
            let code = carrier.antennaType?.trimmingCharacters(in: .whitespaces).uppercased()
            let label = code.flatMap { $0.isEmpty ? nil : antennaTypeLabel($0) }
            let count = carrier.antennaCount.flatMap { $0 > 1 ? String(localized: "\(Int($0.rounded())) antennes") : nil }
            let body = [label, count].compactMap { $0 }.joined(separator: ", ")
            return [carrier.antennaManufacturer?.trimmed, body.isEmpty ? nil : body].compactMap { $0 }.joined(separator: " · ")
        }.filter { !$0.isEmpty })
        if !types.isEmpty { rows.append(Row(label: String(localized: "Type d’antenne"), value: types.joined(separator: " / "))) }
        let models = distinct(carriers.compactMap { $0.antennaModel?.trimmed })
        if !models.isEmpty { rows.append(Row(label: String(localized: "Modèle"), value: models.joined(separator: ", "))) }
        let heights = numbers(\.antennaHeightM, "m")
        if !heights.isEmpty { rows.append(Row(label: String(localized: "Hauteur de l’antenne"), value: heights.joined(separator: ", "))) }
        let tilts = numbers(\.tiltDeg, "°")
        if !tilts.isEmpty { rows.append(Row(label: String(localized: "Inclinaison"), value: tilts.joined(separator: ", "))) }
        let gains = numbers(\.gainDbi, "dBi")
        if !gains.isEmpty { rows.append(Row(label: String(localized: "Gain"), value: gains.joined(separator: ", "))) }

        // Étape g1 pas encore servie pour ce site : une phrase, pas des rangées vides.
        let g1Served = carriers.contains {
            $0.gainDbi != nil || $0.tiltDeg != nil || $0.antennaHeightM != nil || $0.antennaCount != nil
                || $0.antennaModel != nil || $0.antennaManufacturer != nil
        }
        let note = !carriers.isEmpty && !g1Served
            ? String(localized: "Gain, hauteur et inclinaison de l’antenne ne sont pas encore affichés pour ce site.")
            : nil
        return (rows, note)
    }

    private static func antennaTypeLabel(_ code: String) -> String {
        switch code {
        case "AAS": return String(localized: "active (AAS)")
        case "NAC": return String(localized: "non active, corrélée (NAC)")
        case "NAU": return String(localized: "non active, non corrélée (NAU)")
        default: return code
        }
    }

    // MARK: Porteuse

    /// Bande et techno d'affichage : `bandId` et `technologyDetail`, jamais `band` ni `technology`.
    static func identity(_ carrier: AntennaRadioCarrier) -> (bandId: String?, title: String?, generation: String?) {
        let bandId = carrier.bandId?.trimmed
        let detail = carrier.technologyDetail?.uppercased() ?? bandId.map { $0.hasPrefix("n") ? "5GNR" : "LTE" }
        switch detail {
        case "LTE": return (bandId, String(localized: "4G LTE"), "4G")
        case "5GNR": return (bandId, String(localized: "5G NR"), "5G")
        case "5GDSS": return (bandId, String(localized: "5G DSS"), "5G")
        default: return (bandId, nil, nil)
        }
    }

    private static func carrierView(_ carrier: AntennaRadioCarrier, locale: Locale) -> Carrier {
        var rows: [Row] = []
        if let width = carrier.bandwidthMhz, width.isFinite {
            rows.append(Row(label: String(localized: "Largeur du canal"), value: "\(number(width, 2, locale))\(nbsp)MHz"))
        }
        if carrier.duplex?.uppercased() == "TDD" {
            if let channel = channel(carrier.txRangeMhz ?? carrier.rxRangeMhz, carrier.txFrequencyMhz ?? carrier.rxFrequencyMhz, locale) {
                rows.append(Row(label: String(localized: "Fréquences"), value: channel))
            }
            rows.append(Row(label: String(localized: "Duplex"), value: "TDD",
                            spokenLabel: String(localized: "Duplex, répartition temporelle (TDD)")))
            if let share = carrier.downlinkAllocationPercent, share.isFinite {
                rows.append(Row(label: String(localized: "Part du temps en DL"),
                                value: (share / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(locale)),
                                spokenLabel: String(localized: "Part du temps en liaison descendante")))
            }
        } else {
            if let downlink = channel(carrier.txRangeMhz, carrier.txFrequencyMhz, locale) {
                rows.append(Row(label: String(localized: "Fréquences DL"), value: downlink,
                                spokenLabel: String(localized: "Fréquences en liaison descendante, de l’antenne vers le mobile")))
            }
            if let uplink = channel(carrier.rxRangeMhz, carrier.rxFrequencyMhz, locale) {
                rows.append(Row(label: String(localized: "Fréquences UL"), value: uplink,
                                spokenLabel: String(localized: "Fréquences en liaison montante, du mobile vers l’antenne")))
            }
        }
        if let dbm = carrier.txPowerDbm, dbm.isFinite {
            let power = "\(number(dbm, 1, locale))\(nbsp)dBm"
            rows.append(Row(label: String(localized: "Puissance d’émission"),
                            value: carrier.txPowerW.flatMap { $0.isFinite ? "\(power) (≈\(nbsp)\(watts($0, locale)))" : nil } ?? power))
        }
        let cellIds = carrier.cellIds.compactMap(\.trimmed)
        if !cellIds.isEmpty { rows.append(Row(label: String(localized: "Cell ID"), value: cellIds.joined(separator: ", "))) }
        let physicalIds = carrier.physicalIds.compactMap(\.trimmed)
        if !physicalIds.isEmpty { rows.append(Row(label: String(localized: "PCI"), value: physicalIds.joined(separator: ", "))) }
        let identity = identity(carrier)
        return Carrier(title: identity.title, bandId: identity.bandId, generation: identity.generation, rows: rows)
    }

    // MARK: Source

    private static func sourceLines(_ carriers: [AntennaRadioCarrier], datasetPublishedAt: String?, locale: Locale) -> [String] {
        var lines = [isedDate(datasetPublishedAt, locale).map { String(localized: "Registre ISED (Canada), extrait du \($0).") }
            ?? String(localized: "Registre ISED (Canada).")]
        // La configuration la plus récente : ISED date la mise en service, pas une « mise à jour ».
        if let since = isedDate(carriers.compactMap(\.dateLastChanged).filter { !$0.isEmpty }.max(), locale) {
            lines.append(String(localized: "Configuration en service depuis le \(since)."))
        }
        // `bandInferred` ne se lit que si `bandId` est servi.
        if carriers.contains(where: { $0.bandId?.trimmed != nil && $0.bandInferred == true }) {
            lines.append(String(localized: "Bande déduite des fréquences."))
        }
        if carriers.contains(where: { $0.txPowerUnitInferred == "W" && $0.txPowerDbm != nil }) {
            lines.append(String(localized: "Puissance déclarée en watts par le titulaire, convertie en dBm."))
        }
        return lines
    }

    // MARK: Formats

    static func number(_ value: Double, _ maxFraction: Int, _ locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(0...maxFraction)).locale(locale))
    }

    /// La plage si elle est connue (« 3 510–3 560 MHz »), sinon le centre.
    private static func channel(_ range: [Double]?, _ center: Double?, _ locale: Locale) -> String? {
        if let range, range.count == 2, range.allSatisfy(\.isFinite) {
            return "\(number(range[0], 1, locale))–\(number(range[1], 1, locale))\(nbsp)MHz"
        }
        return center.flatMap { $0.isFinite ? "\(number($0, 1, locale))\(nbsp)MHz" : nil }
    }

    /// 78 W, 8,5 W, 0,05 W.
    private static func watts(_ value: Double, _ locale: Locale) -> String {
        "\(number(value, value >= 10 ? 0 : value >= 1 ? 1 : 2, locale))\(nbsp)W"
    }

    /// « 1er nov. 2022 » en français, « Nov 1, 2022 » en anglais ; date ISO lue en UTC.
    static func isedDate(_ iso: String?, _ locale: Locale) -> String? {
        guard let iso, iso.count >= 10 else { return nil }
        let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        style.timeZone = calendar.timeZone
        let text = date.formatted(style)
        if locale.language.languageCode?.identifier == "fr", parts[2] == 1, text.hasPrefix("1 ") {
            return "1er" + text.dropFirst(1)
        }
        return text
    }

    /// Le point cardinal (8 secteurs de 45°) d'un azimut, en toutes lettres.
    static func compassWord(_ azimuth: Double) -> String {
        let index = Int((((azimuth.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        switch index {
        case 0: return String(localized: "nord")
        case 1: return String(localized: "nord-est")
        case 2: return String(localized: "est")
        case 3: return String(localized: "sud-est")
        case 4: return String(localized: "sud")
        case 5: return String(localized: "sud-ouest")
        case 6: return String(localized: "ouest")
        default: return String(localized: "nord-ouest")
        }
    }

    private static func distinct<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

private extension String {
    /// La chaîne sans espaces autour, nil si elle est vide.
    var trimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Page « Porteuses » d'un site canadien : une carte par secteur, ses porteuses, puis la source.
struct ISEDCarriersPage: View {
    let sheet: ISEDCarrierSheet

    var body: some View {
        ScrollView {
            content.padding(SQSpace.lg)
        }
        .background(SQColor.bg.ignoresSafeArea())
        .navigationTitle(Text("Porteuses"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("antenna.carriers.ised")
    }

    /// Les cartes de secteur puis la source, sans le défilement (rendu testable).
    var content: some View {
        VStack(alignment: .leading, spacing: SQSpace.md) {
            ForEach(Array(sheet.sectors.enumerated()), id: \.offset) { _, sector in
                sectorCard(sector)
            }
            if !sheet.licences.isEmpty {
                VStack(alignment: .leading, spacing: SQSpace.xs2) {
                    Text("Licences")
                        .font(SQType.heading)
                        .foregroundStyle(SQColor.label)
                        .accessibilityAddTraits(.isHeader)
                    rows(sheet.licences)
                }
                .padding(SQSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                .accessibilityIdentifier("antenna.carriers.ised.licences")
            }
            sourceBlock
        }
    }

    private func sectorCard(_ sector: ISEDCarrierSheet.Sector) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs2) {
            Text(sector.title)
                .font(SQType.heading)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            rows(sector.rows)
            if let note = sector.note {
                Text(note)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !sector.carriers.isEmpty {
                Text("Porteuses · \(sector.carriers.count)")
                    .sqKicker()
                    .padding(.top, SQSpace.sm)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(sector.carriers.enumerated()), id: \.offset) { _, carrier in
                    carrierBlock(carrier)
                }
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func carrierBlock(_ carrier: ISEDCarrierSheet.Carrier) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            HStack(spacing: SQSpace.xs2) {
                if let generation = carrier.generation {
                    Circle().fill(SQBrand.techColor(generation)).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                if let title = carrier.title {
                    Text(title).font(SQType.callout(.semibold)).foregroundStyle(SQColor.label)
                }
                if let bandId = carrier.bandId {
                    Text(verbatim: bandId)
                        .font(SQType.caption(.semibold).monospaced())
                        .foregroundStyle(SQColor.labelSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.sm, style: .continuous))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            rows(carrier.rows)
        }
        .padding(.top, SQSpace.sm)
        .overlay(alignment: .top) {
            Rectangle().fill(SQColor.separator).frame(height: 1).opacity(0.6)
        }
    }

    @ViewBuilder
    private func rows(_ rows: [ISEDCarrierSheet.Row]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            if let spoken = row.spokenLabel {
                SQFactRow(label: row.label, value: row.value)
                    .accessibilityLabel(Text(verbatim: spoken))
                    .accessibilityValue(Text(verbatim: row.value))
            } else {
                SQFactRow(label: row.label, value: row.value)
            }
        }
    }

    private var sourceBlock: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text("Source").sqKicker().accessibilityAddTraits(.isHeader)
            ForEach(Array(sheet.source.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, SQSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Provinces et territoires du Canada, pour l'en-tête d'un site ISED (« Québec »).
enum ISEDProvince {
    static func name(_ code: String?) -> String? {
        switch code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "AB": return String(localized: "Alberta")
        case "BC": return String(localized: "Colombie-Britannique")
        case "MB": return String(localized: "Manitoba")
        case "NB": return String(localized: "Nouveau-Brunswick")
        case "NL": return String(localized: "Terre-Neuve-et-Labrador")
        case "NS": return String(localized: "Nouvelle-Écosse")
        case "NT": return String(localized: "Territoires du Nord-Ouest")
        case "NU": return String(localized: "Nunavut")
        case "ON": return String(localized: "Ontario")
        case "PE": return String(localized: "Île-du-Prince-Édouard")
        case "QC": return String(localized: "Québec")
        case "SK": return String(localized: "Saskatchewan")
        case "YT": return String(localized: "Yukon")
        default: return nil
        }
    }
}
