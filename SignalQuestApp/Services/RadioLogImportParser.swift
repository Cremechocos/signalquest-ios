import Foundation

/// Parseur des exports « eNB Analytics » (CSV `ExportV5`) et fichiers `.ntm` (NetMonster).
/// Port Swift de `RadioLogImportParsers.kt` (chemin Android), conventions d'identité
/// cellule IDENTIQUES pour que l'identification soit cohérente entre les deux plateformes.
enum RadioLogImportParser {

    // Largeurs 3GPP — rejettent sentinelles ("inconnu" = Int64.max) et valeurs hors plage.
    private static let lteEnbMax: Int64 = 1_048_575        // 2^20 - 1
    private static let lteCiMax: Int64 = 268_435_455       // 2^28 - 1
    private static let nrCiMax: Int64 = 68_719_476_735     // 2^36 - 1

    struct Result: Sendable {
        let rows: [ParsedRadioLogRow]
        let totalLines: Int
    }

    static func parse(fileName: String?, content: String) -> Result {
        let name = (fileName ?? "").lowercased()
        let lines = content
            .split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if name.hasSuffix(".ntm") {
            let rows = lines.enumerated().compactMap { parseNtmLine($0.element, lineNumber: $0.offset + 1) }
            return Result(rows: rows, totalLines: lines.count)
        }
        return parseDelimited(lines: lines)
    }

    // MARK: - CSV avec en-tête (ExportV5 & assimilés)

    private static func parseDelimited(lines: [String]) -> Result {
        guard let first = lines.first else { return Result(rows: [], totalLines: 0) }
        let delimiter = detectDelimiter(first)
        let headers = splitLine(first, delimiter).map(normalizeHeader)
        let hasHeader = headers.contains { knownHeaders.contains($0) }
        guard hasHeader else { return Result(rows: [], totalLines: lines.count) }

        let dataLines = Array(lines.dropFirst())
        let rows = dataLines.enumerated().compactMap { index, line in
            parseHeaderRow(headers: headers, columns: splitLine(line, delimiter), lineNumber: index + 2)
        }
        return Result(rows: rows, totalLines: dataLines.count)
    }

    private static func parseHeaderRow(headers: [String], columns: [String], lineNumber: Int) -> ParsedRadioLogRow? {
        func value(_ aliases: String...) -> String? {
            for alias in aliases {
                let normalized = normalizeHeader(alias)
                if let index = headers.firstIndex(of: normalized), index < columns.count {
                    let trimmed = columns[index].trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && trimmed != "null" { return trimmed }
                }
            }
            return nil
        }

        let tech = normalizeTechnology(value("technology", "tech", "radio", "rat", "type", "xg"))
        let isNrRow = techIsNr(tech)

        // Cellule locale : on garde ≥ 0 (drop "-1" = inconnu, conserve la cellule 0).
        let ciText = value("eciCellId", "eci_cell_id", "cell_id", "cellid", "cell", "ci", "eci", "nci", "cid")
            .flatMap { text -> String? in (Int64(text) ?? 0) >= 0 ? text : nil }
        let nodeColumn = value("enb", "enodeb", "enb_id", "enbid", "enodebid", "node", "nodeid")
        let explicitGnb = value("gnb", "gnodeb", "gnb_id", "gnbid", "gnodebid")
        let explicitCi = value("ci", "eci", "nci", "cell", "cellid", "eciCellId", "eci_cell_id").flatMap { Int64($0) }

        // eNB Analytics « ExportV5 » loge le NCI complet dans la colonne « eNB » en 5G
        // (pas de colonne NCI/gNB dédiée). On le route vers l'identité complète + gNB
        // dérivé, au lieu de le prendre pour un eNB et de classer la cellule en LTE.
        let nrNciFromNodeColumn: Int64? = (isNrRow && explicitGnb == nil) ? nodeColumn.flatMap { Int64($0) } : nil
        let rawCi = sanitizeCellIdentity(explicitCi ?? nrNciFromNodeColumn, isNr: isNrRow)
        let enb = sanitizeEnb(nrNciFromNodeColumn != nil ? nil : nodeColumn) ?? inferLteEnb(rawCi, tech)
        let gnb = explicitGnb ?? inferNrGnb(rawCi, tech)
        let ci = rawCi ?? sanitizeCellIdentity(
            fullCellIdentity(cellId: ciText, enb: enb, gnb: gnb, tech: tech), isNr: isNrRow
        )
        let pci = value("pci", "physical_cell_id", "physicalCellId", "code").flatMap { Int($0) }.flatMap { (0...1007).contains($0) ? $0 : nil }

        if (enb ?? "").isEmpty, (gnb ?? "").isEmpty, (ciText ?? "").isEmpty, ci == nil, pci == nil {
            return nil
        }

        let operatorName = value("operator", "opérateur", "op", "network", "provider", "resolved_operator")
        let mcc = value("mcc") ?? RadioLogOperatorResolver.mccMnc(forOperator: operatorName)?.mcc
        let mnc = value("mnc", "net") ?? RadioLogOperatorResolver.mccMnc(forOperator: operatorName)?.mnc
        let (lat, lon) = coordinates(
            lat: value("latitude", "lat", "gps_lat", "gpslatitude").flatMap { Double($0) },
            lon: value("longitude", "lon", "lng", "gps_lon", "gpslongitude").flatMap { Double($0) }
        )

        return ParsedRadioLogRow(
            lineNumber: lineNumber,
            technology: tech,
            operatorName: operatorName,
            mcc: mcc,
            mnc: mnc,
            enb: enb,
            gnb: gnb,
            ci: ci,
            cellId: localCellId(ci: ci, ciText: ciText, isNr: isNrRow),
            pci: pci,
            tac: value("tac", "area", "lac").flatMap { Int($0) },
            earfcn: value("earfcn", "nrarfcn", "arfcn", "uarfcn").flatMap { Int($0) },
            band: value("band", "band_number").map { $0.replacingOccurrences(of: "B", with: "").replacingOccurrences(of: "n", with: "") }.flatMap { Int($0) },
            rsrp: value("rsrp", "rf").flatMap { Int($0) },
            latitude: lat,
            longitude: lon
        )
    }

    // MARK: - NetMonster .ntm — `RAT;MCC;MNC;CI;TAC;eNB;PCI;Lat;Lon;Location;EARFCN`

    private static func parseNtmLine(_ line: String, lineNumber: Int) -> ParsedRadioLogRow? {
        let columns = splitLine(line.trimmingCharacters(in: .whitespaces), ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard columns.count >= 7 else { return nil }
        func col(_ index: Int) -> String? {
            guard index < columns.count else { return nil }
            let trimmed = columns[index]
            return (trimmed.isEmpty || trimmed == "-" || trimmed == "null") ? nil : trimmed
        }

        let tech = normalizeTechnology(col(0))
        let isNr = techIsNr(tech)
        let isLte = techIsLte(tech)
        let mcc = col(1)
        let mnc = col(2).flatMap { Int($0).map(String.init) ?? $0 }
        let cellNumber = col(3).flatMap { Int64($0) }
        let tac = col(4).flatMap { Int($0) }
        let nodeField = col(5).flatMap { $0 == "0" ? nil : $0 }
        let pci = col(6).flatMap { Int($0) }.flatMap { (0...1007).contains($0) ? $0 : nil }
        let (lat, lon) = coordinates(lat: col(7).flatMap { Double($0) }, lon: col(8).flatMap { Double($0) })
        let earfcn = columns.count > 10 ? col(10).flatMap { Int($0) } : nil

        let enb = isLte ? nodeField : nil
        let gnb = isNr ? (nodeField ?? inferNrGnb(cellNumber, tech)) : nil
        let rawCi: Int64?
        if isLte, let node = nodeField.flatMap({ Int64($0) }), let cell = cellNumber, (0...255).contains(cell) {
            rawCi = node * 256 + cell
        } else {
            rawCi = cellNumber
        }
        let ci = sanitizeCellIdentity(rawCi, isNr: isNr)

        if (enb ?? "").isEmpty, (gnb ?? "").isEmpty, ci == nil, pci == nil { return nil }

        // Le .ntm porte déjà MCC/MNC en colonnes 1/2 — pas de résolution par nom nécessaire.
        return ParsedRadioLogRow(
            lineNumber: lineNumber,
            technology: tech,
            operatorName: nil,
            mcc: mcc,
            mnc: mnc,
            enb: enb,
            gnb: gnb,
            ci: ci,
            cellId: localCellId(ci: ci, ciText: col(3), isNr: isNr),
            pci: pci,
            tac: tac,
            earfcn: earfcn,
            band: nil,
            rsrp: nil,
            latitude: lat,
            longitude: lon
        )
    }

    // MARK: - Helpers identité (miroir CellIdentityNormalizer.kt)

    private static func fullCellIdentity(cellId: String?, enb: String?, gnb: String?, tech: String?) -> Int64? {
        guard let local = cellId.flatMap({ Int64($0) }), local >= 0 else { return nil }
        let isNr = !(gnb ?? "").isEmpty && techIsNr(tech)
        let isLte = !(enb ?? "").isEmpty || techIsLte(tech)
        if isNr, local <= 16383, let node = Int64(gnb ?? ""), node > 0 { return (node << 14) + local }
        if isLte, local <= 255, let node = Int64(enb ?? ""), node > 0 { return (node << 8) + local }
        return local > 0 ? local : nil
    }

    private static func localCellId(ci: Int64?, ciText: String?, isNr: Bool) -> String? {
        if let ci {
            let mask: Int64 = isNr ? 16383 : 255
            if ci > mask { return String(ci & mask) }
        }
        return ciText.flatMap { (Int64($0) ?? 0) >= 0 ? $0 : nil }
    }

    private static func sanitizeCellIdentity(_ value: Int64?, isNr: Bool) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value <= (isNr ? nrCiMax : lteCiMax) ? value : nil
    }

    private static func sanitizeEnb(_ value: String?) -> String? {
        guard let value, let numeric = Int64(value), (1...lteEnbMax).contains(numeric) else { return nil }
        return value
    }

    private static func inferLteEnb(_ ci: Int64?, _ tech: String?) -> String? {
        guard let ci, ci > 0 else { return nil }
        let likelyLte = (tech ?? "").isEmpty || techIsLte(tech)
        guard likelyLte else { return nil }
        let enb = ci / 256
        return enb > 0 ? String(enb) : nil
    }

    private static func inferNrGnb(_ nci: Int64?, _ tech: String?) -> String? {
        guard let nci, nci > 0, techIsNr(tech) else { return nil }
        let gnb = nci >> 14
        return gnb > 0 ? String(gnb) : nil
    }

    // MARK: - Petits utilitaires

    private static func techIsNr(_ tech: String?) -> Bool {
        let t = (tech ?? "").uppercased()
        return t.contains("NR") || t.contains("5G")
    }

    private static func techIsLte(_ tech: String?) -> Bool {
        let t = (tech ?? "").uppercased()
        return t.contains("LTE") || t.contains("4G")
    }

    private static func normalizeTechnology(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw.uppercased() {
        case "4", "4G", "LTE": return "LTE"
        case "5", "5G", "NR", "NR5G": return "NR"
        case "3", "3G", "UMTS", "WCDMA": return "UMTS"
        case "2", "2G", "GSM", "EDGE", "GPRS": return "GSM"
        default: return raw
        }
    }

    private static func coordinates(lat: Double?, lon: Double?) -> (Double?, Double?) {
        guard let lat, let lon, lat.isFinite, lon.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lon),
              !(lat == 0 && lon == 0) else { return (nil, nil) }
        return (lat, lon)
    }

    private static func detectDelimiter(_ header: String) -> Character {
        [";", ",", "\t"].max(by: { a, b in
            header.filter { $0 == a }.count < header.filter { $0 == b }.count
        }) ?? ";"
    }

    /// Split en préservant les colonnes vides (contrairement à `split`), gestion des guillemets.
    private static func splitLine(_ line: String, _ delimiter: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character? = iterator.next()
        while let c = pending {
            pending = iterator.next()
            if c == "\"" {
                if inQuotes, pending == "\"" { current.append("\""); pending = iterator.next() }
                else { inQuotes.toggle() }
            } else if c == delimiter && !inQuotes {
                result.append(current); current = ""
            } else {
                current.append(c)
            }
        }
        result.append(current)
        return result
    }

    private static func normalizeHeader(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let knownHeaders: Set<String> = [
        "lat", "latitude", "lon", "lng", "longitude", "enb", "gnb", "pci", "eci", "nci",
        "cellid", "cell", "ci", "ecicellid", "mcc", "mnc", "net", "mccmnc", "plmn",
        "technology", "radio", "tech", "xg", "operator", "op", "enbid", "gnbid", "nodeid", "area", "tac", "cid"
    ]
}
