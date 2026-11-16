import SwiftUI
import UIKit

/// Banc du Bilan mensuel, sans réseau : `--qa-monthly-recap-full` (Bilan d'octobre 2026 du
/// contrat §3), `-partial` (données partielles), `-notfound` (404), `-error` (lecture ratée),
/// `-notready` (409), `-expired` (422), `-ended` (Premium terminé, 403) et `-share` (la feuille
/// de partage ouverte). `-entries` et `-free` passent par l'app : Profil et Notifications.
struct MonthlyRecapQAScreen: View {
    let variant: String

    static let screenVariants: Set<String> = ["full", "partial", "notfound", "error", "notready", "expired", "ended", "share"]

    #if DEBUG && targetEnvironment(simulator)
    var body: some View {
        NavigationStack {
            MonthlyRecapView(model: MonthlyRecapViewModel(
                initialMonth: initialMonth,
                service: MonthlyRecapQAService(variant: variant),
                loadBadgeTitles: { ["explorer_rural": AccountLocaleSync.appLocale == "fr" ? "Explorateur" : "Explorer"] },
                loadPreferences: {
                    var prefs = NotificationPreferences.empty
                    prefs.notifyMonthlyRecapPush = true
                    prefs.notifyMonthlyRecapEmail = true
                    prefs.recapShareIdentity = true
                    return prefs
                },
                savePreferences: { $0 }
            ))
        }
    }

    private var initialMonth: String? {
        switch variant {
        case "notfound": return "2026-09"
        case "notready": return "2026-11"
        case "expired": return "2025-09"
        default: return nil
        }
    }
    #else
    var body: some View { EmptyView() }
    #endif
}

#if DEBUG && targetEnvironment(simulator)
struct MonthlyRecapQAService: MonthlyRecapServicing {
    let variant: String

    func months() async throws -> [MonthlyRecapMonth] {
        if variant == "ended" { throw MonthlyRecapError.premiumRequired }
        return (0..<12).map { index in
            let month = Self.month(offset: index)
            return MonthlyRecapMonth(month: month, available: month != "2026-09" && month != "2026-04")
        }
    }

    func recap(month: String) async throws -> MonthlyRecap {
        try await Task.sleep(nanoseconds: 250_000_000)
        switch variant {
        case "notfound": throw MonthlyRecapError.notFound
        case "error": throw MonthlyRecapError.unavailable
        case "notready": throw MonthlyRecapError.notReady
        case "expired": throw MonthlyRecapError.invalidMonth
        case "ended": throw MonthlyRecapError.premiumRequired
        case "partial": return try Self.decode(Self.partialJSON)
        default: return try Self.decode(Self.fullJSON.replacingOccurrences(of: "\"2026-10\"", with: "\"\(month)\""))
        }
    }

    func image(month: String, options: MonthlyRecapImageOptions) async throws -> Data {
        try await Task.sleep(nanoseconds: 300_000_000)
        let size = CGSize(width: 540, height: 675)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.957, green: 0.949, blue: 0.925, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if options.showIdentity {
                UIColor(red: 0.945, green: 0.922, blue: 0.867, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width, height: 120))
            }
            let ink = UIColor(red: 0.11, green: 0.125, blue: 0.118, alpha: 1)
            let lines = [
                "SIGNALQUEST · " + MonthlyRecapPresentation.monthYear(month).uppercased(),
                options.showIdentity ? "Léa Martin" : "",
                "312 km · 46 speedtests",
                "18 antennes · 612 Mb/s",
                options.showIdentity ? "signalquest.fr/u/lea" : "",
            ]
            for (index, line) in lines.enumerated() where !line.isEmpty {
                (line as NSString).draw(at: CGPoint(x: 36, y: 150 + CGFloat(index) * 70), withAttributes: [
                    .font: UIFont.systemFont(ofSize: index == 1 ? 34 : 24, weight: index == 1 ? .heavy : .semibold),
                    .foregroundColor: ink,
                ])
            }
        }
        return image.pngData() ?? Data()
    }

    func eraseLocalData(ownerScopeId: String) async {}

    private static func month(offset: Int) -> String {
        var year = 2026
        var month = 10 - offset
        while month < 1 { month += 12; year -= 1 }
        return String(format: "%04d-%02d", year, month)
    }

    private static func decode(_ json: String) throws -> MonthlyRecap {
        try JSONDecoder().decode(MonthlyRecap.self, from: Data(json.utf8))
    }

    /// Le Bilan d'octobre 2026 de l'exemple du contrat, jours actifs complétés.
    static let fullJSON = """
    {"month":"2026-10","timeZone":"Europe/Paris",
     "period":{"start":"2026-10-01T00:00:00+02:00","end":"2026-11-01T00:00:00+01:00"},
     "frozenAt":"2026-11-01T04:02:11+01:00",
     "story":[{"key":"distanceAndIdentifications","params":{"distanceM":312000,"identifications":18,"firsts":2}},
              {"key":"bestDownload","params":{"bps":612000000,"generation":"5G","at":"2026-10-14T17:20:00+02:00","nearPlace":"Crest"}}],
     "field":{"sessions":9,"distanceM":312000,"longestSession":{"distanceM":84000,"at":"2026-10-14T09:12:00+02:00"}},
     "measures":{"speedtests":46,"medianDownloadBps":182000000,
                 "bestDownload":{"bps":612000000,"operatorKey":"sfr","generation":"5G","at":"2026-10-14T17:20:00+02:00","nearPlace":"Crest"},
                 "topNetwork":{"operatorKey":"sfr","speedtests":31}},
     "contributions":{"identifications":18,"firstIdentifications":2,"photos":11,"outagesReported":1},
     "progress":{"points":1240,"rank":{"position":37,"scope":"market","marketCode":"FR"},"longestStreakDays":12,
                 "badges":[{"id":"explorer_rural","unlockedAt":"2026-10-21T10:00:00+02:00"}]},
     "activeDays":{"daysInMonth":31,"days":[
       {"date":"2026-10-01","intensity":1},{"date":"2026-10-02","intensity":2},{"date":"2026-10-04","intensity":1},
       {"date":"2026-10-05","intensity":3},{"date":"2026-10-06","intensity":2},{"date":"2026-10-08","intensity":1},
       {"date":"2026-10-09","intensity":1},{"date":"2026-10-11","intensity":2},{"date":"2026-10-12","intensity":3},
       {"date":"2026-10-13","intensity":3},{"date":"2026-10-14","intensity":2},{"date":"2026-10-16","intensity":1},
       {"date":"2026-10-17","intensity":1},{"date":"2026-10-18","intensity":2},{"date":"2026-10-19","intensity":3},
       {"date":"2026-10-20","intensity":1},{"date":"2026-10-23","intensity":2},{"date":"2026-10-24","intensity":1},
       {"date":"2026-10-25","intensity":2},{"date":"2026-10-26","intensity":3},{"date":"2026-10-31","intensity":1}]},
     "previous":{"month":"2026-09","distanceM":223000,"speedtests":50,"identifications":12,"rankPosition":52}}
    """

    /// Un mois sans terrain ni progression : seules les mesures et une contribution restent.
    static let partialJSON = """
    {"month":"2026-10","timeZone":"Europe/Paris","frozenAt":"2026-11-01T04:02:11+01:00",
     "story":[{"key":"distanceAndIdentifications","params":{"distanceM":null,"identifications":3,"firsts":0}}],
     "field":null,
     "measures":{"speedtests":4,"medianDownloadBps":null,"bestDownload":null,"topNetwork":null},
     "contributions":{"identifications":3,"firstIdentifications":0,"photos":0,"outagesReported":null},
     "progress":{"points":null,"rank":null,"longestStreakDays":null,"badges":[]},
     "activeDays":{"daysInMonth":31,"days":[{"date":"2026-10-07","intensity":1},{"date":"2026-10-21","intensity":2}]},
     "previous":null}
    """
}
#endif
