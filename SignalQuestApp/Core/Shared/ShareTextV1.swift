import Foundation

/// share-text v1 : le texte d'un partage dans une conversation (« SQ speedtest 1 »…),
/// commun au web, à iOS et à Android. Contrat : `docs/share-text-contract.md` de
/// map-nextjs ; vecteur : copie à l'octet de `contracts/share-text/v1.json` (499dea289,
/// v1.2). Portage fidèle de `readShareTextV1` (`packages/core/share-text-v1.ts`).
///
/// Tout se lit en points de code Unicode, jamais en caractères Swift : « \r\n » est un
/// seul `Character`, et le contrat compte les longueurs en points de code.
enum ShareTextV1 {
    enum Kind: String, CaseIterable, Sendable {
        case site, speedtest, session, post
        case radioInfo = "radio-info"
    }

    struct Parsed: Equatable, Sendable {
        let kind: Kind
        /// Les champs reconnus et valides ; une ligne refusée est absente, jamais devinée.
        let fields: [String: String]
        /// Le lien, seulement s'il passe la liste blanche (§4) ; sinon `nil`, et il
        /// s'affiche en texte non cliquable.
        let safeLink: String?
    }

    static let maxValueCodePoints = 512

    static let keys: [Kind: [String]] = [
        .site: ["operator", "operator_name", "technologies", "enb", "gnb", "pci", "support", "anfr", "market", "address", "position", "link"],
        .speedtest: ["time", "download_mbps", "download_peak_mbps", "upload_mbps", "ping_ms", "connection", "operator", "operator_name", "brand", "market", "enb", "gnb", "address", "link"],
        .session: ["time", "points", "distance_km", "duration_min", "technologies", "connection", "link"],
        .post: ["post_id", "author_handle", "text", "link"],
        .radioInfo: [
            "time", "connection", "technology", "operator", "operator_name", "plmn", "market", "roaming",
            "rsrp_dbm", "rsrq_db", "sinr_db", "rssi_dbm", "band", "bandwidth_khz", "earfcn", "nrarfcn", "pci",
            "enb", "gnb", "cell_id", "tac", "ca", "nr_rsrp_dbm", "nr_rsrq_db", "nr_sinr_db", "nr_band", "nr_nrarfcn",
            "nr_pci", "position", "accuracy_m", "live_session", "link",
        ],
    ]

    // MARK: Lecture

    /// `nil` si ce n'est pas un partage v1 de type connu : le texte s'affiche tel quel,
    /// ou passe au lecteur de l'ancien format.
    static func read(_ text: String) -> Parsed? {
        let lines = splitLines(text)
        guard let header = lines.first, let kind = headerKind(header), let allowed = keys[kind].map(Set.init) else { return nil }
        var fields: [String: String] = [:]
        var seen = Set<String>()
        for line in lines.dropFirst() {
            let scalars = Array(line.unicodeScalars)
            guard let colon = scalars.firstIndex(of: ":"), colon > 0 else { continue }
            let key = jsTrim(String(String.UnicodeScalarView(scalars[..<colon])))
            guard matches(key, #"^[a-z0-9_]{1,40}$"#), allowed.contains(key), !seen.contains(key) else { continue }
            // La première occurrence d'une clé fait foi, même refusée.
            seen.insert(key)
            let value = jsTrim(String(String.UnicodeScalarView(scalars[(colon + 1)...])))
            guard !value.isEmpty, value.unicodeScalars.count <= maxValueCodePoints,
                  let validator = validators[key], validator(value) else { continue }
            fields[key] = value
        }
        if kind == .radioInfo {
            for key in radioInfoOutOfContext(fields) { fields[key] = nil }
        }
        if kind == .speedtest, let brand = fields["brand"], brandRepeatsNetwork(brand, fields) {
            fields["brand"] = nil
        }
        let safeLink = fields["link"].flatMap { isSafeLink($0, kind: kind) ? $0 : nil }
        return Parsed(kind: kind, fields: fields, safeLink: safeLink)
    }

    /// Ligne 1 comparée en entier (§2) : ni BOM, ni espace, ni autre version.
    private static func headerKind(_ line: String) -> Kind? {
        guard let match = groups(line, #"^SQ ([a-z-]{1,32}) ([1-9][0-9]{0,3})$"#), match.count == 2,
              match[1] == "1" else { return nil }
        return Kind(rawValue: match[0])
    }

    /// Lignes séparées par `\n` ; un `\r` final est retiré.
    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                lines.append(String(current)); current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines.map { line in
            var scalars = line.unicodeScalars
            if scalars.last == "\r" { scalars.removeLast() }
            return String(scalars)
        }
    }

    /// `String.prototype.trim` : blancs ECMAScript (dont U+FEFF, sans U+0085) et fins de ligne.
    private static func jsTrim(_ value: String) -> String {
        func isSpace(_ s: Unicode.Scalar) -> Bool {
            switch s.value {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
                 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
            default: return false
            }
        }
        var scalars = Array(value.unicodeScalars)
        while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
        while let last = scalars.last, isSpace(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    // MARK: Formats (§3)

    private static let generations = ["2G", "3G", "4G", "5G"]

    private static func unsigned(_ max: Int64) -> @Sendable (String) -> Bool {
        { matches($0, #"^(0|[1-9][0-9]{0,10})$"#) && (Int64($0) ?? .max) <= max }
    }

    private static func positive(_ max: Int64) -> @Sendable (String) -> Bool {
        { matches($0, #"^[1-9][0-9]{0,10}$"#) && (Int64($0) ?? .max) <= max }
    }

    /// Entier signé, sans zéro de tête ni `-0`.
    private static func signed(_ min: Int64, _ max: Int64) -> @Sendable (String) -> Bool {
        { value in
            guard matches(value, #"^(0|-?[1-9][0-9]{0,3})$"#), let number = Int64(value) else { return false }
            return number >= min && number <= max
        }
    }

    private static let boolean: @Sendable (String) -> Bool = { $0 == "true" || $0 == "false" }
    private static let oneDecimal: @Sendable (String) -> Bool = { matches($0, #"^(0|[1-9][0-9]{0,6})\.[0-9]$"#) }
    private static let identifier: @Sendable (String) -> Bool = { matches($0, #"^[A-Za-z0-9._:-]{1,64}$"#) }
    private static let freeText: @Sendable (String) -> Bool = { !$0.isEmpty }

    private static func isTechnologies(_ value: String) -> Bool {
        var previous = -1
        for part in value.components(separatedBy: ",") {
            guard let rank = generations.firstIndex(of: part), rank > previous else { return false }
            previous = rank
        }
        return true
    }

    /// ISO 8601 UTC à la milliseconde, et une vraie date, comme
    /// `new Date(v).toISOString() === v` : chaque champ dans sa plage (jamais un 30 février
    /// ni 24:00). Vérifié champ par champ : relire en `Date` (un `Double`) peut dériver
    /// d'une milliseconde.
    private static func isUtcMillis(_ value: String) -> Bool {
        guard let parts = groups(value, #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})\.[0-9]{3}Z$"#),
              parts.count == 6 else { return false }
        let n = parts.compactMap { Int($0) }
        guard n.count == 6 else { return false }
        let (year, month, day) = (n[0], n[1], n[2])
        guard (1...12).contains(month), n[3] < 24, n[4] < 60, n[5] < 60 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return (1...days).contains(day)
    }

    private static func isPosition(_ value: String) -> Bool {
        guard let parts = groups(value, #"^(-?(?:0|[1-9][0-9]?)\.[0-9]{5}),(-?(?:0|[1-9][0-9]{0,2})\.[0-9]{5})$"#),
              !value.hasPrefix("-0.00000"), !value.contains(",-0.00000"),
              let lat = Double(parts[0]), let lng = Double(parts[1]) else { return false }
        return abs(lat) <= 90 && abs(lng) <= 180
    }

    private static let validators: [String: @Sendable (String) -> Bool] = [
        "operator": { matches($0, #"^[A-Z0-9_]{1,40}$"#) },
        "operator_name": freeText,
        "brand": freeText,
        "technologies": isTechnologies,
        "enb": positive(1_048_575),
        "gnb": positive(4_294_967_295),
        "pci": unsigned(1_007),
        "support": identifier,
        "anfr": identifier,
        "market": { matches($0, #"^[A-Z]{2}$|^DROM$"#) },
        "address": freeText,
        "position": isPosition,
        "link": freeText,
        "time": isUtcMillis,
        "download_mbps": oneDecimal,
        "download_peak_mbps": oneDecimal,
        "upload_mbps": oneDecimal,
        "ping_ms": unsigned(1_000_000),
        "connection": { matches($0, #"^[A-Za-z0-9+_ -]{1,24}$"#) },
        "points": unsigned(1_000_000_000),
        "distance_km": oneDecimal,
        "duration_min": unsigned(1_000_000),
        "post_id": identifier,
        "author_handle": { matches($0, #"^[A-Za-z0-9_.]{1,40}$"#) },
        "text": freeText,
        "technology": { generations.contains($0) },
        "plmn": { matches($0, #"^[0-9]{5,6}$"#) },
        "roaming": boolean,
        "rsrp_dbm": signed(-156, -31),
        "rsrq_db": signed(-43, 20),
        "sinr_db": signed(-23, 40),
        "rssi_dbm": signed(-130, -20),
        "band": positive(1_024),
        "bandwidth_khz": positive(400_000),
        "earfcn": unsigned(262_143),
        "nrarfcn": unsigned(3_279_165),
        "cell_id": unsigned(68_719_476_735),
        "tac": unsigned(16_777_215),
        "ca": boolean,
        "accuracy_m": unsigned(100_000),
        "nr_rsrp_dbm": signed(-156, -31),
        "nr_rsrq_db": signed(-43, 20),
        "nr_sinr_db": signed(-23, 40),
        "nr_band": positive(1_024),
        "nr_nrarfcn": unsigned(3_279_165),
        "nr_pci": unsigned(1_007),
        "live_session": { matches($0, #"^[A-Za-z0-9_-]{1,64}$"#) },
    ]

    private static let radioCellKeys = ["band", "bandwidth_khz", "earfcn", "nrarfcn", "pci", "enb", "gnb", "cell_id", "tac", "ca"]
    private static let radioNRKeys = ["nr_rsrp_dbm", "nr_rsrq_db", "nr_sinr_db", "nr_band", "nr_nrarfcn", "nr_pci"]

    /// Clés d'un `radio-info` sans objet pour sa génération (§3).
    private static func radioInfoOutOfContext(_ fields: [String: String]) -> [String] {
        var keys: [String] = []
        let technology = fields["technology"]
        if technology == "2G" || technology == "3G" { keys += radioCellKeys }
        if technology == "4G" {
            if let cell = fields["cell_id"].flatMap(Int64.init), cell > 268_435_455 { keys.append("cell_id") }
            if let tac = fields["tac"].flatMap(Int64.init), tac > 65_535 { keys.append("tac") }
        }
        if fields["connection"] != "5G NSA" { keys += radioNRKeys }
        return keys.filter { fields[$0] != nil }
    }

    // MARK: Marque (v1.2)

    /// Forme comparable (§3, `brand`) : NFD, retrait des seuls U+0300 à U+036F, on ne
    /// garde que [A-Za-z0-9], puis minuscules ASCII. Jamais `lowercased()`, dont les
    /// tables dépendent d'Unicode.
    static func comparableName(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.decomposedStringWithCanonicalMapping.unicodeScalars {
            let v = scalar.value
            if (0x300...0x36F).contains(v) { continue }
            switch v {
            case 0x30...0x39, 0x61...0x7A: out.append(scalar)
            case 0x41...0x5A: out.append(Unicode.Scalar(v + 0x20)!)
            default: continue
            }
        }
        return String(out)
    }

    static func brandRepeatsNetwork(_ brand: String, _ fields: [String: String]) -> Bool {
        let target = comparableName(brand)
        return [fields["operator_name"], fields["operator"]].contains { $0.map(comparableName) == target }
    }

    // MARK: Liens (§4)

    private static let linkPaths: [Kind: [String]] = [
        .site: [#"^/carte$"#, #"^/site$"#],
        .speedtest: [#"^/speedtest/[A-Za-z0-9_-]{1,64}$"#, #"^/speedtest/web/[A-Za-z0-9_-]{1,64}$"#],
        .session: [#"^/sessions/[A-Za-z0-9_-]{1,64}$"#, #"^/sessions/shared/[A-Za-z0-9_-]{1,64}$"#],
        .post: [#"^/feed$"#, #"^/posts/[A-Za-z0-9_-]{1,64}$"#],
        .radioInfo: [#"^/carte$"#, #"^/messages$"#],
    ]

    /// Sur la chaîne brute, jamais normalisée : schéma et hôte sans casse, port absent ou
    /// 443, ni identifiants ni fragment, et un chemin attendu pour ce type.
    static func isSafeLink(_ link: String, kind: Kind) -> Bool {
        guard let match = groups(
            link, #"^https://(?:www\.)?signalquest\.fr(?::443)?(/[A-Za-z0-9_/.-]*)(\?[\x{21}-\x{22}\x{24}-\x{7e}]*)?$"#,
            caseInsensitive: true
        ) else { return false }
        let path = match[0]
        return (linkPaths[kind] ?? []).contains { matches(path, $0) }
    }

    // MARK: Aperçu (§5)

    /// L'aperçu d'un partage v1 pour la liste et les notifications : jamais l'en-tête brut.
    /// `nil` si ce n'est pas un partage v1 de type connu.
    static func preview(_ text: String, locale: Locale = .current) -> String? {
        guard let parsed = read(text) else { return nil }
        switch parsed.kind {
        case .speedtest:
            guard let down = parsed.fields["download_mbps"] else { return String(localized: "Speedtest") }
            // Une décimale, comme écrite, avec le séparateur de la langue (« 412,0 »).
            let separator = locale.decimalSeparator ?? "."
            let value = down.replacingOccurrences(of: ".", with: separator)
            return String(localized: "Speedtest \(value) Mbit/s")
        case .site: return String(localized: "Antenne partagée")
        case .session: return String(localized: "Session de couverture")
        case .post: return String(localized: "Publication partagée")
        case .radioInfo: return String(localized: "Mesure radio")
        }
    }

    // MARK: Expressions

    private static func matches(_ value: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
        regex(pattern, caseInsensitive: caseInsensitive)?.firstMatch(
            in: value, range: NSRange(value.startIndex..., in: value)
        ) != nil
    }

    /// Les groupes capturés (une chaîne vide pour un groupe absent), ou `nil`.
    private static func groups(_ value: String, _ pattern: String, caseInsensitive: Bool = false) -> [String]? {
        guard let expression = regex(pattern, caseInsensitive: caseInsensitive),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: value).map { String(value[$0]) } ?? ""
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = (caseInsensitive ? "i:" : "s:") + pattern
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cache[key] { return cached }
        // `$` d'ICU accepte une fin de ligne finale : ancré sur la fin de texte exacte.
        let anchored = pattern.replacingOccurrences(of: "$", with: #"\z"#)
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let expression = try? NSRegularExpression(pattern: anchored, options: options) else { return nil }
        cache[key] = expression
        return expression
    }
}
