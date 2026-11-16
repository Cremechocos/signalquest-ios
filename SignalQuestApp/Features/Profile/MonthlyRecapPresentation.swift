import Foundation

/// Textes et chiffres du Bilan mensuel, sans vue : les mêmes règles que le Web (contrat
/// Abonnements v1.20 §3 et maquette validée le 16/11), testables en français et en anglais.
///
/// Règles : une valeur nulle ou à 0 n'a pas de ligne, une carte sans ligne disparaît ; une
/// comparaison à 0 % reste ; les comparaisons n'ont ni vert ni rouge et prennent le vrai
/// signe moins (U+2212) ; distances en km ou en miles selon le réglage d'unités ; débits
/// par `SQUnits.throughput`, comme partout dans l'app. Aucun lieu hors de la phrase du record.
struct MonthlyRecapPresentation {
    struct Figure: Equatable, Hashable {
        let value: String
        let label: String
    }

    struct Row: Equatable, Identifiable {
        let id: String
        let label: String
        let value: String
        var detail: String? = nil
        /// Pastille de couleur de l'opérateur devant la valeur ou le détail.
        var operatorKey: String? = nil
    }

    struct Section: Equatable, Identifiable {
        let id: String
        let title: String
        let rows: [Row]
        var note: String? = nil
    }

    /// Une case de la grille des jours actifs ; `day == nil` pour les cases hors du mois.
    struct DayCell: Equatable, Hashable {
        let day: Int?
        let intensity: Int
    }

    let recap: MonthlyRecap
    var units: SQUnitsSystem = SQUnits.current
    /// « fr » ou « en » : la langue de l'app, jamais celle de la région de l'iPhone.
    var language: String = AccountLocaleSync.appLocale
    /// Noms des badges du catalogue (`/api/gamification/catalog`) ; un id inconnu est ignoré.
    var badgeTitles: [String: String] = [:]

    var locale: Locale { Self.locale(for: language) }

    static func locale(for language: String) -> Locale {
        Locale(identifier: language == "fr" ? "fr_FR" : "en_US")
    }

    var timeZone: TimeZone {
        recap.timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "Europe/Paris") ?? .current
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    // MARK: - En-tête

    /// « Ton mois d’octobre sur SignalQuest » / « Your month of October on SignalQuest ».
    var title: String { Self.title(for: recap.month) }

    static func title(for month: String) -> String {
        let monthOf = monthOf(month)
        return String(localized: "Ton mois \(monthOf) sur SignalQuest")
    }

    /// « Du 1er au 31 octobre 2026 · arrêté le 1er novembre à 04:02 ».
    var subtitle: String {
        var parts: [String] = []
        if let lastDay = lastDayOfMonth {
            let formatter = dateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            let end = formatter.string(from: lastDay)
            parts.append(String(localized: "Du 1er au \(end)"))
        }
        if let frozen = recap.frozenAt.flatMap(Self.date(from:)) {
            let formatter = dateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let day = dayMonth(frozen)
            let time = formatter.string(from: frozen)
            parts.append(String(localized: "arrêté le \(day) à \(time)"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Récit

    var storySentences: [String] {
        recap.story.compactMap { entry in
            switch entry.key {
            case "distanceAndIdentifications": return distanceAndIdentificationsSentence(entry)
            case "bestDownload": return bestDownloadSentence(entry)
            default: return nil
            }
        }
    }

    private func distanceAndIdentificationsSentence(_ entry: MonthlyRecap.StoryEntry) -> String? {
        let distance = entry.number("distanceM").flatMap { $0 > 0 ? Self.unbreakable(roundedDistance($0)) : nil }
        let identified = entry.number("identifications").map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        let firsts = entry.number("firstIdentifications") ?? entry.number("firsts")
        let antennas = identified.map { antennaPhrase(count: $0, firsts: firsts.map { Int($0) } ?? 0) }
        switch (distance, antennas) {
        case let (distance?, antennas?):
            return String(localized: "Tu as parcouru \(distance) en mesurant le réseau et identifié \(antennas).")
        case let (distance?, nil):
            return String(localized: "Tu as parcouru \(distance) en mesurant le réseau.")
        case let (nil, antennas?):
            return String(localized: "Tu as identifié \(antennas).")
        case (nil, nil):
            return nil
        }
    }

    /// « 18 antennes, dont 2 que personne n’avait encore trouvées ».
    private func antennaPhrase(count: Int, firsts: Int) -> String {
        let base = String(localized: "\(count) antennes")
        guard firsts > 0 else { return base }
        let clause = firsts == 1
            ? String(localized: ", dont 1 que personne n’avait encore trouvée")
            : String(localized: ", dont \(firsts) que personne n’avait encore trouvées")
        return base + clause
    }

    private func bestDownloadSentence(_ entry: MonthlyRecap.StoryEntry) -> String? {
        guard let bps = entry.number("bps"), bps > 0,
              let at = entry.text("at").flatMap(Self.date(from:)) else { return nil }
        let speed = Self.unbreakable(speedText(bps: bps))
        let day = dayMonth(at)
        let place = entry.text("nearPlace")
        switch (Self.generation(entry.text("generation")), place) {
        case let (generation?, place?):
            return String(localized: "Ton meilleur débit : \(speed) en \(generation), le \(day) près de \(place).")
        case let (generation?, nil):
            return String(localized: "Ton meilleur débit : \(speed) en \(generation), le \(day).")
        case let (nil, place?):
            return String(localized: "Ton meilleur débit : \(speed), le \(day) près de \(place).")
        case (nil, nil):
            return String(localized: "Ton meilleur débit : \(speed), le \(day).")
        }
    }

    // MARK: - Grands chiffres

    var figures: [Figure] {
        var figures: [Figure] = []
        if let meters = recap.field?.distanceM, meters > 0 {
            figures.append(Figure(value: roundedDistance(meters), label: String(localized: "en session de mesure")))
        }
        if let count = recap.measures?.speedtests, count > 0 {
            figures.append(Figure(value: number(count),
                                  label: count == 1 ? String(localized: "speedtest") : String(localized: "speedtests")))
        }
        if let count = recap.contributions?.identifications, count > 0 {
            figures.append(Figure(value: number(count), label: count == 1
                                  ? String(localized: "antenne identifiée") : String(localized: "antennes identifiées")))
        }
        if let points = recap.progress?.points, points > 0 {
            figures.append(Figure(value: "+" + number(points),
                                  label: points == 1 ? String(localized: "point") : String(localized: "points")))
        }
        return figures
    }

    // MARK: - Cartes

    var sections: [Section] {
        [fieldSection, measuresSection, contributionsSection, progressSection].compactMap { $0 }
    }

    private var fieldSection: Section? {
        guard let field = recap.field else { return nil }
        var rows: [Row] = []
        if field.sessions > 0 {
            rows.append(Row(id: "sessions", label: String(localized: "Sessions"), value: number(field.sessions)))
        }
        if let meters = field.distanceM, meters > 0 {
            rows.append(Row(id: "distance", label: String(localized: "Distance"), value: roundedDistance(meters)))
        }
        if let longest = field.longestSession, longest.distanceM > 0 {
            rows.append(Row(id: "longestSession", label: String(localized: "Plus longue session"),
                            value: roundedDistance(longest.distanceM),
                            detail: Self.date(from: longest.at).map(dayMonth)))
        }
        return rows.isEmpty ? nil : Section(id: "field", title: String(localized: "Sur le terrain"), rows: rows)
    }

    private var measuresSection: Section? {
        guard let measures = recap.measures else { return nil }
        var rows: [Row] = []
        var hasMobileOnlyRow = false
        if measures.speedtests > 0 {
            rows.append(Row(id: "speedtests", label: String(localized: "Speedtests"), value: number(measures.speedtests)))
        }
        if let median = measures.medianDownloadBps, median > 0 {
            rows.append(Row(id: "median", label: String(localized: "Débit descendant médian"), value: speedText(bps: median)))
            hasMobileOnlyRow = true
        }
        if let best = measures.bestDownload, best.bps > 0 {
            let detail = [best.operatorKey.map(Self.operatorName), Self.generation(best.generation),
                          Self.date(from: best.at).map(dayMonth)].compactMap { $0 }
            rows.append(Row(id: "best", label: String(localized: "Meilleur débit"), value: speedText(bps: best.bps),
                            detail: detail.isEmpty ? nil : detail.joined(separator: " · "), operatorKey: best.operatorKey))
            hasMobileOnlyRow = true
        }
        if let top = measures.topNetwork, top.speedtests > 0 {
            let total = measures.speedtests
            let share: String? = total >= top.speedtests
                ? (top.speedtests == 1
                    ? String(localized: "1 test sur \(total)")
                    : String(localized: "\(top.speedtests) tests sur \(total)"))
                : nil
            rows.append(Row(id: "topNetwork", label: String(localized: "Réseau le plus mesuré"),
                            value: Self.operatorName(top.operatorKey), detail: share, operatorKey: top.operatorKey))
            hasMobileOnlyRow = true
        }
        guard !rows.isEmpty else { return nil }
        return Section(
            id: "measures", title: String(localized: "Tes mesures"), rows: rows,
            note: hasMobileOnlyRow
                ? String(localized: "Médiane, record et réseau : speedtests en données mobiles. Le Wi-Fi ne compte que dans le nombre de speedtests.")
                : nil
        )
    }

    private var contributionsSection: Section? {
        guard let contributions = recap.contributions else { return nil }
        var rows: [Row] = []
        if let count = contributions.identifications, count > 0 {
            let firsts = contributions.firstIdentifications ?? 0
            let detail: String? = firsts <= 0 ? nil
                : (firsts == 1 ? String(localized: "dont 1 première") : String(localized: "dont \(firsts) premières"))
            rows.append(Row(id: "identifications", label: String(localized: "Antennes identifiées"),
                            value: number(count), detail: detail))
        }
        if let count = contributions.photos, count > 0 {
            rows.append(Row(id: "photos", label: String(localized: "Photos publiées"), value: number(count)))
        }
        if let count = contributions.outagesReported, count > 0 {
            rows.append(Row(id: "outages", label: String(localized: "Pannes signalées"), value: number(count)))
        }
        return rows.isEmpty ? nil : Section(id: "contributions", title: String(localized: "Ce que tu as apporté"), rows: rows)
    }

    private var progressSection: Section? {
        guard let progress = recap.progress else { return nil }
        var rows: [Row] = []
        if let points = progress.points, points > 0 {
            rows.append(Row(id: "points", label: String(localized: "Points gagnés"), value: "+" + number(points)))
        }
        if let rank = progress.rank, rank.position > 0 {
            rows.append(Row(id: "rank", label: String(localized: "Rang du mois"), value: ordinal(rank.position),
                            detail: rank.marketCode.flatMap { locale.localizedString(forRegionCode: $0.uppercased()) }))
        }
        if let days = progress.longestStreakDays, days > 0 {
            rows.append(Row(id: "streak", label: String(localized: "Plus longue série"), value: String(localized: "\(days) jours")))
        }
        let badges = progress.badges.compactMap { badgeTitles[$0.id] }
        if !badges.isEmpty {
            rows.append(Row(id: "badges", label: String(localized: "Badges débloqués"),
                            value: badges.formatted(.list(type: .and).locale(locale))))
        }
        return rows.isEmpty ? nil : Section(id: "progress", title: String(localized: "Ta progression"), rows: rows)
    }

    // MARK: - Jours actifs

    var activeDayCount: Int {
        Set((recap.activeDays?.days ?? []).filter { (1...3).contains($0.intensity) }.compactMap { Self.dayNumber($0.date) }).count
    }

    var daysInMonth: Int {
        if let days = recap.activeDays?.daysInMonth, (28...31).contains(days) { return days }
        guard let first = firstDayOfMonth, let range = calendar.range(of: .day, in: .month, for: first) else { return 31 }
        return range.count
    }

    /// Lettres des jours, du lundi au dimanche : « L M M J V S D » / « M T W T F S S ».
    var weekdayLetters: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return [] }
        return Array(symbols[1...]) + [symbols[0]]
    }

    /// Cases de la grille, lundi en premier, complétées pour finir la dernière semaine.
    var activeDayGrid: [DayCell] {
        guard let first = firstDayOfMonth else { return [] }
        // `weekday` : 1 = dimanche … 7 = samedi ; décalage depuis le lundi.
        let leading = (calendar.component(.weekday, from: first) + 5) % 7
        var intensities: [Int: Int] = [:]
        for day in recap.activeDays?.days ?? [] {
            guard let number = Self.dayNumber(day.date), (1...3).contains(day.intensity) else { continue }
            intensities[number] = max(intensities[number] ?? 0, day.intensity)
        }
        var cells = Array(repeating: DayCell(day: nil, intensity: 0), count: leading)
        cells += (1...daysInMonth).map { DayCell(day: $0, intensity: intensities[$0] ?? 0) }
        let trailing = (7 - cells.count % 7) % 7
        cells += Array(repeating: DayCell(day: nil, intensity: 0), count: trailing)
        return cells
    }

    var activeDaysCaption: String {
        let count = activeDayCount
        let total = daysInMonth
        let first = count == 1
            ? String(localized: "1 jour actif sur \(total), du lundi au dimanche.")
            : String(localized: "\(count) jours actifs sur \(total), du lundi au dimanche.")
        return first + " " + String(localized: "Plus le carré est foncé, plus le jour a compté de mesures et de contributions.")
    }

    /// « 21 jours actifs sur 31 en octobre », pour VoiceOver.
    var activeDaysAccessibilityLabel: String {
        let count = activeDayCount
        let total = daysInMonth
        let name = Self.monthName(recap.month, language: language)
        return count == 1
            ? String(localized: "1 jour actif sur \(total) en \(name)")
            : String(localized: "\(count) jours actifs sur \(total) en \(name)")
    }

    // MARK: - Comparaison avec le mois précédent

    var comparison: Section? {
        guard let previous = recap.previous, MonthlyRecapLink.isMonth(previous.month) else { return nil }
        var rows: [Row] = []
        if let before = previous.distanceM {
            let now = recap.field?.distanceM ?? 0
            if before > 0 {
                rows.append(Row(id: "distance", label: String(localized: "Distance"), value: percentChange(from: before, to: now)))
            } else if now > 0 {
                rows.append(Row(id: "distance", label: String(localized: "Distance"), value: "+" + roundedDistance(now)))
            }
        }
        if let before = previous.speedtests {
            let now = recap.measures?.speedtests ?? 0
            if before > 0 {
                rows.append(Row(id: "speedtests", label: String(localized: "Speedtests"),
                                value: percentChange(from: Double(before), to: Double(now))))
            } else if now > 0 {
                rows.append(Row(id: "speedtests", label: String(localized: "Speedtests"), value: "+" + number(now)))
            }
        }
        if let before = previous.identifications {
            let now = recap.contributions?.identifications ?? 0
            if before > 0 || now > 0 {
                rows.append(Row(id: "identifications", label: String(localized: "Antennes identifiées"),
                                value: signedDifference(now - before)))
            }
        }
        if let before = previous.rankPosition, before > 0, let now = recap.progress?.rank?.position, now > 0 {
            rows.append(Row(id: "rank", label: String(localized: "Rang"), value: "\(ordinal(before)) → \(ordinal(now))"))
        }
        guard !rows.isEmpty else { return nil }
        let name = Self.monthName(previous.month, language: language)
        return Section(id: "comparison", title: String(localized: "Par rapport à \(name)"), rows: rows)
    }

    /// « +40 % », « −8 % », « 0 % » ; « +40% » en anglais.
    func percentChange(from before: Double, to now: Double) -> String {
        let percent = Int(((now - before) / before * 100).rounded())
        let magnitude = abs(percent).formatted(.number.locale(locale))
        let sign = percent > 0 ? "+" : (percent < 0 ? "\u{2212}" : "")
        return language == "fr" ? "\(sign)\(magnitude)\u{202F}%" : "\(sign)\(magnitude)%"
    }

    func signedDifference(_ difference: Int) -> String {
        let magnitude = abs(difference).formatted(.number.locale(locale))
        return difference > 0 ? "+\(magnitude)" : (difference < 0 ? "\u{2212}\(magnitude)" : magnitude)
    }

    // MARK: - Formats

    func ordinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    func number(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    func speedText(bps: Double) -> String {
        SQUnits.throughput(mbps: bps / 1_000_000, locale: locale)
    }

    /// Dans le récit, « 312 km » et « 612 Mb/s » ne se coupent jamais en fin de ligne,
    /// même aux tailles d'accessibilité.
    static func unbreakable(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// Distance d'un Bilan : entière dès 10 km ou 10 miles (« 312 km »), une décimale en dessous.
    func roundedDistance(_ meters: Double) -> String {
        let unit = units == .imperial ? 1_609.344 : 1_000
        let whole = meters / unit >= 10 ? (meters / unit).rounded() * unit : meters
        return SQUnits.distanceCompact(meters: whole, system: units, locale: locale)
    }

    /// « 14 octobre », « 1er novembre » ; « October 14 » en anglais.
    func dayMonth(_ date: Date) -> String {
        if language == "fr" {
            let day = calendar.component(.day, from: date)
            let name = Self.monthSymbol(calendar.component(.month, from: date), language: language)
            return (day == 1 ? "1er" : "\(day)") + "\u{00A0}" + name
        }
        let formatter = dateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        return formatter.string(from: date)
    }

    private func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.calendar = calendar
        return formatter
    }

    private var firstDayOfMonth: Date? {
        guard let (year, month) = Self.components(recap.month) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12))
    }

    private var lastDayOfMonth: Date? {
        guard let first = firstDayOfMonth else { return nil }
        return calendar.date(byAdding: .day, value: daysInMonth - 1, to: first)
    }

    // MARK: - Mois

    static func components(_ month: String) -> (year: Int, month: Int)? {
        guard MonthlyRecapLink.isMonth(month) else { return nil }
        let parts = month.split(separator: "-")
        guard let year = Int(parts[0]), let value = Int(parts[1]) else { return nil }
        return (year, value)
    }

    /// Le mois qui suit (« 2026-12 » → « 2027-01 »).
    static func nextMonth(_ month: String) -> String? {
        guard let (year, value) = components(month) else { return nil }
        let next = value == 12 ? (year + 1, 1) : (year, value + 1)
        return String(format: "%04d-%02d", next.0, next.1)
    }

    static func monthSymbol(_ month: Int, language: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale(for: language)
        let symbols = formatter.standaloneMonthSymbols ?? []
        guard (1...12).contains(month), symbols.count == 12 else { return "" }
        let symbol = symbols[month - 1]
        // Le français écrit les mois en minuscules dans une phrase.
        return language == "fr" ? symbol.lowercased() : symbol
    }

    /// « octobre » / « October ».
    static func monthName(_ month: String, language: String = AccountLocaleSync.appLocale) -> String {
        guard let (_, value) = components(month) else { return month }
        return monthSymbol(value, language: language)
    }

    /// « Octobre 2026 » / « October 2026 ».
    static func monthYear(_ month: String, language: String = AccountLocaleSync.appLocale) -> String {
        guard let (year, value) = components(month) else { return month }
        let name = monthSymbol(value, language: language)
        return name.prefix(1).uppercased() + name.dropFirst() + " " + String(year)
    }

    /// Le mois avec sa préposition élidée, « d’octobre », « de mars » ; le nom seul en anglais.
    static func monthOf(_ month: String) -> String {
        switch components(month)?.month {
        case 1: return String(localized: "de janvier", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        case 2: return String(localized: "de février", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        case 3: return String(localized: "de mars", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        case 4: return String(localized: "d’avril", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        case 5: return String(localized: "de mai", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        case 6: return String(localized: "de juin", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        case 7: return String(localized: "de juillet", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        case 8: return String(localized: "d’août", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        case 9: return String(localized: "de septembre", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        case 10: return String(localized: "d’octobre", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        case 11: return String(localized: "de novembre", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        case 12: return String(localized: "de décembre", comment: "Mois avec sa préposition ; le nom seul en anglais.")
        default: return month
        }
    }

    // MARK: - États

    /// Texte d'un mois sans Bilan affichable ; `nil` pour Premium requis, qui a sa carte.
    static func message(for error: MonthlyRecapError, month: String?) -> String? {
        switch error {
        case .notFound:
            let name = month.map { monthName($0) } ?? ""
            return String(localized: "Pas de bilan pour \(name) : aucune mesure ni contribution ce mois-là.")
        case .notReady:
            guard let month, let next = nextMonth(month) else {
                return String(localized: "Ton bilan n’a pas pu être lu.")
            }
            let monthOf = monthOf(month)
            let nextName = monthName(next)
            return String(localized: "Ton bilan \(monthOf) sera prêt le 1er \(nextName).")
        case .invalidMonth:
            return String(localized: "Ce bilan n’est plus consultable. Les bilans restent disponibles 12 mois.")
        case .unavailable:
            return String(localized: "Ton bilan n’a pas pu être lu.")
        case .premiumRequired:
            return nil
        }
    }

    // MARK: - Lecture des valeurs

    static func date(from value: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    /// Le jour d'une date « 2026-10-14 » ; `nil` si la forme est autre.
    static func dayNumber(_ date: String) -> Int? {
        let parts = date.prefix(10).split(separator: "-")
        guard parts.count == 3, let day = Int(parts[2]), (1...31).contains(day) else { return nil }
        return day
    }

    /// Génération affichable : « 5G », « 4G »… ; toute autre valeur est tue.
    static func generation(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).uppercased(), raw.count == 2,
              raw.hasSuffix("G"), let digit = Int(raw.prefix(1)), (2...6).contains(digit) else { return nil }
        return raw
    }

    /// Nom complet de l'opérateur (« SFR », « Bouygues Telecom ») ; la clé brute s'il est inconnu.
    static func operatorName(_ key: String) -> String {
        let colors = SQBrand.operatorColors(key)
        return colors.name == SQBrand.defaultOperator.name ? key : colors.name
    }
}
