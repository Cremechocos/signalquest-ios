import Foundation
import XCTest
@testable import SignalQuest

/// Bilan mensuel (contrat Abonnements v1.20 §3, maquette validée le 16/11) : décodage
/// tolérant, phrases et chiffres en français et en anglais, lignes nulles retirées,
/// comparaisons, grille du lundi au dimanche, liens, routage et clé de notification.
@MainActor
final class MonthlyRecapTests: XCTestCase {
    private var isFrench: Bool { AccountLocaleSync.appLocale == "fr" }
    private var language: String { AccountLocaleSync.appLocale }

    private func recap(_ json: String) throws -> MonthlyRecap {
        try JSONDecoder().decode(MonthlyRecap.self, from: Data(json.utf8))
    }

    private func full() throws -> MonthlyRecap { try recap(MonthlyRecapQAService.fullJSON) }

    private func presentation(_ recap: MonthlyRecap, units: SQUnitsSystem = .metric) -> MonthlyRecapPresentation {
        MonthlyRecapPresentation(recap: recap, units: units, language: language,
                                 badgeTitles: ["explorer_rural": "Explorateur"])
    }

    // MARK: Décodage

    func testDecodesTheContractExample() throws {
        let recap = try full()
        XCTAssertEqual(recap.month, "2026-10")
        XCTAssertEqual(recap.timeZone, "Europe/Paris")
        XCTAssertEqual(recap.story.map(\.key), ["distanceAndIdentifications", "bestDownload"])
        XCTAssertEqual(recap.story.first?.number("distanceM"), 312_000)
        XCTAssertEqual(recap.story.last?.text("nearPlace"), "Crest")
        XCTAssertEqual(recap.field?.sessions, 9)
        XCTAssertEqual(recap.measures?.topNetwork?.operatorKey, "sfr")
        XCTAssertEqual(recap.contributions?.firstIdentifications, 2)
        XCTAssertEqual(recap.progress?.rank?.position, 37)
        XCTAssertEqual(recap.progress?.badges.map(\.id), ["explorer_rural"])
        XCTAssertEqual(recap.activeDays?.days.count, 21)
        XCTAssertEqual(recap.previous?.rankPosition, 52)
    }

    /// Un bloc mal formé tombe seul ; une phrase du récit sans clé aussi.
    func testMalformedBlocksFallAlone() throws {
        let recap = try recap("""
        {"month":"2026-10","field":"oops","measures":{"speedtests":"x"},
         "story":[{"params":{}},{"key":"bestDownload"},42],
         "contributions":{"identifications":4,"firstIdentifications":null,"photos":null,"outagesReported":null},
         "progress":{"points":10,"rank":null,"longestStreakDays":null,"badges":[]},"previous":null}
        """)
        XCTAssertNil(recap.field)
        XCTAssertNil(recap.measures)
        XCTAssertEqual(recap.story.map(\.key), ["bestDownload"])
        XCTAssertEqual(recap.contributions?.identifications, 4)
        XCTAssertEqual(recap.progress?.points, 10)
        XCTAssertNil(recap.previous)
        // Sans ses paramètres, la phrase du record n'est pas écrite.
        XCTAssertEqual(presentation(recap).storySentences, [])
    }

    func testMonthListKeepsWellFormedMonthsInServerOrder() throws {
        let list = try JSONDecoder().decode(MonthlyRecapMonthList.self, from: Data("""
        {"months":[{"month":"2026-10","available":true},{"month":"2026-13","available":true},
                   {"month":"2026-09","available":false},{"month":"2026-08"},{"month":7}]}
        """.utf8))
        XCTAssertEqual(list.months, [MonthlyRecapMonth(month: "2026-10", available: true),
                                     MonthlyRecapMonth(month: "2026-09", available: false)])
    }

    // MARK: Liens et routage

    func testMonthAndLinks() throws {
        XCTAssertTrue(MonthlyRecapLink.isMonth("2026-10"))
        XCTAssertTrue(MonthlyRecapLink.isMonth("2027-01"))
        for bad in ["2026-13", "2026-00", "2026-1", "26-10", "2026/10", "2026-1a", "２０２６-10", ""] {
            XCTAssertFalse(MonthlyRecapLink.isMonth(bad), bad)
        }
        let origin = try XCTUnwrap(URL(string: "https://signalquest.fr"))
        XCTAssertEqual(MonthlyRecapLink.month(from: try XCTUnwrap(URL(string: "https://signalquest.fr/profile/bilan/2026-10")),
                                              appOrigin: origin), "2026-10")
        XCTAssertNil(MonthlyRecapLink.month(from: try XCTUnwrap(URL(string: "https://evil.example/profile/bilan/2026-10")),
                                            appOrigin: origin))
        XCTAssertNil(MonthlyRecapLink.month(from: try XCTUnwrap(URL(string: "http://signalquest.fr/profile/bilan/2026-10")),
                                            appOrigin: origin))
        XCTAssertNil(MonthlyRecapLink.month(from: try XCTUnwrap(URL(string: "https://signalquest.fr/profile/bilan/2026-13")),
                                            appOrigin: origin))
        XCTAssertEqual(MonthlyRecapLink.month(fromPath: "/profile/bilan/2026-09"), "2026-09")
        XCTAssertNil(MonthlyRecapLink.month(fromPath: "/profile/bilan"))
    }

    func testRecapReadyNotificationOpensTheMonthOnTheProfile() {
        let router = AppRouter()
        router.handle(type: "recap.ready", conversationId: nil, postId: nil, month: "2026-10")
        XCTAssertEqual(router.selectedTab, .profile)
        XCTAssertEqual(router.openRecapMonth, "2026-10")

        let malformed = AppRouter()
        malformed.handle(type: "recap.ready", conversationId: nil, postId: nil, month: "2026-13")
        XCTAssertEqual(malformed.openRecapMonth, "", "un mois mal formé ouvre le dernier mois clos")
    }

    func testNotificationTextKeyWritesTheMonthWithItsElision() throws {
        let text = try XCTUnwrap(NotificationTextKey(key: "notif.recap.ready", args: ["month": .string("2026-10")]))
        XCTAssertEqual(text.title, isFrench ? "Ton bilan est prêt" : "Your recap is ready")
        XCTAssertEqual(text.message, isFrench ? "Découvre ton mois d’octobre." : "See your October.")
        let march = try XCTUnwrap(NotificationTextKey(key: "notif.recap.ready", args: ["month": .string("2027-03")]))
        XCTAssertEqual(march.message, isFrench ? "Découvre ton mois de mars." : "See your March.")
        XCTAssertNil(NotificationTextKey(key: "notif.recap.ready", args: ["month": .string("2026-13")]))
        XCTAssertNil(NotificationTextKey(key: "notif.recap.ready", args: [:]))
        XCTAssertNil(NotificationTextKey(key: "notif.recap.ready", args: ["month": .number(202610)]))
    }

    // MARK: Erreurs et états

    func testServerRefusalsMapToTheirScreens() {
        func map(_ status: Int, _ code: String?) -> MonthlyRecapError {
            MonthlyRecapError.from(APIError.http(status: status, code: code, message: "", requestId: nil, retryAfter: nil))
        }
        XCTAssertEqual(map(403, "PREMIUM_REQUIRED"), .premiumRequired)
        XCTAssertEqual(map(403, "FORBIDDEN"), .unavailable)
        XCTAssertEqual(map(404, "RECAP_NOT_FOUND"), .notFound)
        XCTAssertEqual(map(409, "RECAP_NOT_READY"), .notReady)
        XCTAssertEqual(map(422, "INVALID_MONTH"), .invalidMonth)
        XCTAssertEqual(map(500, "INTERNAL_ERROR"), .unavailable)
        XCTAssertEqual(MonthlyRecapError.from(APIError.transport("offline")), .unavailable)
    }

    func testStateMessages() {
        XCTAssertEqual(MonthlyRecapPresentation.message(for: .notFound, month: "2026-09"), isFrench
            ? "Pas de bilan pour septembre : aucune mesure ni contribution ce mois-là."
            : "No recap for September: no measurements or contributions that month.")
        XCTAssertEqual(MonthlyRecapPresentation.message(for: .notReady, month: "2026-11"), isFrench
            ? "Ton bilan de novembre sera prêt le 1er décembre."
            : "Your November recap will be ready on December 1.")
        XCTAssertEqual(MonthlyRecapPresentation.message(for: .notReady, month: "2026-12"), isFrench
            ? "Ton bilan de décembre sera prêt le 1er janvier."
            : "Your December recap will be ready on January 1.")
        XCTAssertEqual(MonthlyRecapPresentation.message(for: .notReady, month: "2026-08"), isFrench
            ? "Ton bilan d’août sera prêt le 1er septembre."
            : "Your August recap will be ready on September 1.")
        XCTAssertNil(MonthlyRecapPresentation.message(for: .premiumRequired, month: "2026-10"))
        XCTAssertEqual(MonthlyRecapPresentation.message(for: .unavailable, month: nil),
                       isFrench ? "Ton bilan n’a pas pu être lu." : "Your recap couldn’t be loaded.")
    }

    // MARK: Textes du Bilan complet

    func testFullRecapReadsLikeTheMockup() throws {
        let view = presentation(try full())
        XCTAssertEqual(view.title, isFrench ? "Ton mois d’octobre sur SignalQuest" : "Your month of October on SignalQuest")
        XCTAssertEqual(MonthlyRecapPresentation.monthYear("2026-10", language: language), isFrench ? "Octobre 2026" : "October 2026")
        XCTAssertTrue(view.subtitle.hasPrefix(isFrench ? "Du 1er au 31 octobre 2026 · arrêté le 1er\u{00A0}novembre à "
                                                       : "From the 1st to October 31, 2026 · frozen on November 1 at "),
                      view.subtitle)
        // Distance et débit insécables dans le récit : ils ne se coupent jamais en fin de ligne.
        let speed = MonthlyRecapPresentation.unbreakable(SQUnits.throughput(mbps: 612, locale: view.locale))
        XCTAssertEqual(view.storySentences, isFrench ? [
            "Tu as parcouru 312\u{00A0}km en mesurant le réseau et identifié 18 antennes, dont 2 que personne n’avait encore trouvées.",
            "Ton meilleur débit : \(speed) en 5G, le 14\u{00A0}octobre près de Crest.",
        ] : [
            "You covered 312\u{00A0}km measuring the network and identified 18 antennas, including 2 that nobody had found yet.",
            "Your best download speed: \(speed) on 5G, on October 14 near Crest.",
        ])
        XCTAssertEqual(view.figures.map(\.value), ["312 km", "46", "18", "+" + view.number(1240)])
        XCTAssertEqual(view.figures.map(\.label), isFrench
            ? ["en session de mesure", "speedtests", "antennes identifiées", "points"]
            : ["in measuring sessions", "speedtests", "antennas identified", "points"])

        let sections = Dictionary(uniqueKeysWithValues: view.sections.map { ($0.id, $0) })
        XCTAssertEqual(view.sections.map(\.id), ["field", "measures", "contributions", "progress"])
        XCTAssertEqual(sections["field"]?.rows.map(\.value), ["9", "312 km", "84 km"])
        XCTAssertEqual(sections["field"]?.rows.last?.detail, isFrench ? "14\u{00A0}octobre" : "October 14")
        XCTAssertEqual(sections["measures"]?.rows.map(\.id), ["speedtests", "median", "best", "topNetwork"])
        XCTAssertEqual(sections["measures"]?.rows.last?.value, "SFR")
        XCTAssertEqual(sections["measures"]?.rows.last?.detail, isFrench ? "31 tests sur 46" : "31 of 46 tests")
        XCTAssertNotNil(sections["measures"]?.note)
        XCTAssertEqual(sections["contributions"]?.rows.first?.detail, isFrench ? "dont 2 premières" : "including 2 firsts")
        let progress = try XCTUnwrap(sections["progress"])
        XCTAssertEqual(progress.rows.map(\.id), ["points", "rank", "streak", "badges"])
        XCTAssertEqual(progress.rows[1].value, isFrench ? "37e" : "37th")
        XCTAssertEqual(progress.rows[1].detail, "France")
        XCTAssertEqual(progress.rows[2].value, isFrench ? "12 jours" : "12 days")
        XCTAssertEqual(progress.rows[3].value, "Explorateur")
    }

    func testComparisonUsesInkSignsAndKeepsZero() throws {
        let view = presentation(try full())
        let comparison = try XCTUnwrap(view.comparison)
        XCTAssertEqual(comparison.title, isFrench ? "Par rapport à septembre" : "Compared with September")
        XCTAssertEqual(comparison.rows.map(\.value), isFrench
            ? ["+40\u{202F}%", "\u{2212}8\u{202F}%", "+6", "52e → 37e"]
            : ["+40%", "\u{2212}8%", "+6", "52nd → 37th"])
        XCTAssertEqual(view.percentChange(from: 50, to: 50), isFrench ? "0\u{202F}%" : "0%")
        XCTAssertEqual(view.signedDifference(0), "0")
        XCTAssertEqual(view.signedDifference(-3), "\u{2212}3")
    }

    func testActiveDaysStartOnMonday() throws {
        let view = presentation(try full())
        XCTAssertEqual(view.activeDayCount, 21)
        XCTAssertEqual(view.daysInMonth, 31)
        let grid = view.activeDayGrid
        // Le 1er octobre 2026 est un jeudi : trois cases vides devant, une derrière.
        XCTAssertEqual(grid.count, 35)
        XCTAssertEqual(grid.prefix(4).map(\.day), [nil, nil, nil, 1])
        XCTAssertEqual(grid[3].intensity, 1)
        XCTAssertEqual(grid[7].intensity, 3, "le 5 octobre")
        XCTAssertNil(grid.last?.day)
        XCTAssertEqual(view.weekdayLetters, isFrench ? ["L", "M", "M", "J", "V", "S", "D"] : ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertEqual(view.activeDaysCaption, isFrench
            ? "21 jours actifs sur 31, du lundi au dimanche. Plus le carré est foncé, plus le jour a compté de mesures et de contributions."
            : "21 active days out of 31, Monday to Sunday. The darker the square, the more measurements and contributions the day had.")
    }

    // MARK: Lignes nulles et unités

    func testNullOrZeroLinesDisappearAndEmptyCardsToo() throws {
        let view = presentation(try recap(MonthlyRecapQAService.partialJSON))
        XCTAssertEqual(view.storySentences, [isFrench ? "Tu as identifié 3 antennes." : "You identified 3 antennas."])
        XCTAssertEqual(view.figures.map(\.value), ["4", "3"])
        XCTAssertEqual(view.sections.map(\.id), ["measures", "contributions"])
        XCTAssertEqual(view.sections[0].rows.map(\.id), ["speedtests"])
        XCTAssertNil(view.sections[0].note, "sans médiane, record ni réseau, la note des données mobiles n'a pas lieu d'être")
        XCTAssertEqual(view.sections[1].rows.map(\.id), ["identifications"])
        XCTAssertNil(view.sections[1].rows[0].detail)
        XCTAssertNil(view.comparison)
        XCTAssertEqual(view.activeDayCount, 2)
    }

    func testSingularLabelsAndUnknownBadgesAndGenerations() throws {
        let recap = try recap("""
        {"month":"2026-10","story":[{"key":"bestDownload","params":{"bps":8400000,"generation":"WIFI","at":"2026-10-01T08:00:00+02:00"}}],
         "measures":{"speedtests":1,"medianDownloadBps":null,"bestDownload":null,"topNetwork":null},
         "contributions":{"identifications":1,"firstIdentifications":1,"photos":null,"outagesReported":null},
         "progress":{"points":1,"rank":{"position":1,"marketCode":"FR"},"longestStreakDays":null,"badges":[{"id":"unknown_badge"}]}}
        """)
        let view = presentation(recap)
        XCTAssertEqual(view.figures.map(\.label), isFrench ? ["speedtest", "antenne identifiée", "point"]
                                                           : ["speedtest", "antenna identified", "point"])
        let speed = MonthlyRecapPresentation.unbreakable(SQUnits.throughput(mbps: 8.4, locale: view.locale))
        XCTAssertEqual(view.storySentences, [isFrench ? "Ton meilleur débit : \(speed), le 1er\u{00A0}octobre."
                                                      : "Your best download speed: \(speed), on October 1."])
        let progress = try XCTUnwrap(view.sections.first { $0.id == "progress" })
        XCTAssertEqual(progress.rows.map(\.id), ["points", "rank"], "un badge inconnu du catalogue est ignoré")
        XCTAssertEqual(progress.rows[1].value, isFrench ? "1er" : "1st")
        let contributions = try XCTUnwrap(view.sections.first { $0.id == "contributions" })
        XCTAssertEqual(contributions.rows[0].detail, isFrench ? "dont 1 première" : "including 1 first")
    }

    func testDistancesFollowTheUnitsSetting() throws {
        let view = presentation(try full(), units: .imperial)
        XCTAssertEqual(view.figures.first?.value, "194 mi")
        XCTAssertEqual(view.roundedDistance(8_046.72), SQUnits.distanceCompact(meters: 8_046.72, system: .imperial, locale: view.locale))
        XCTAssertEqual(presentation(try full()).roundedDistance(312_400), "312 km")
    }

    // MARK: Service et modèle

    func testImageOptionsAreAllSent() {
        let options = MonthlyRecapImageOptions(language: "fr", formal: true, imperial: false, showIdentity: false)
        XCTAssertEqual(options.queryItems.map { "\($0.name)=\($0.value ?? "")" }, ["lang=fr", "address=vous", "units=km", "identity=0"])
    }

    func testOfflineCacheIsScopedToTheAccount() {
        let alice = MonthlyRecapService.cacheKey(ownerScopeId: "user:alice", month: "2026-10")
        let bob = MonthlyRecapService.cacheKey(ownerScopeId: "user:bob", month: "2026-10")
        XCTAssertNotEqual(alice, bob)
        XCTAssertTrue(alice.hasPrefix(MonthlyRecapService.cachePrefix(ownerScopeId: "user:alice")))
        XCTAssertFalse(alice.contains("alice"), "le cache ne porte pas l'identifiant en clair")
    }

    func testModelOpensTheLatestAvailableMonthAndNavigates() async throws {
        let service = RecordingRecapService(months: [
            MonthlyRecapMonth(month: "2026-10", available: false),
            MonthlyRecapMonth(month: "2026-09", available: true),
            MonthlyRecapMonth(month: "2026-08", available: false),
            MonthlyRecapMonth(month: "2026-07", available: true),
        ])
        let model = makeModel(service: service, initialMonth: nil)
        await model.start()
        XCTAssertEqual(model.month, "2026-09")
        XCTAssertNotNil(model.recap)
        XCTAssertEqual(model.olderMonth, "2026-07")
        XCTAssertNil(model.newerMonth)
        XCTAssertEqual(model.badgeTitles["explorer_rural"], "Explorateur")
        await model.select("2026-07")
        XCTAssertEqual(model.newerMonth, "2026-09")
        XCTAssertNil(model.olderMonth)
        let requested = await service.requested
        XCTAssertEqual(requested, ["2026-09", "2026-07"])
    }

    func testModelShowsThePremiumCardOnA403AndTheLinkedMonthOtherwise() async {
        let ended = makeModel(service: RecordingRecapService(months: [], failure: .premiumRequired), initialMonth: "2026-10")
        await ended.start()
        XCTAssertEqual(ended.phase, .failed(.premiumRequired))

        let linked = makeModel(service: RecordingRecapService(months: [MonthlyRecapMonth(month: "2026-10", available: true)],
                                                              recapFailure: .notReady), initialMonth: "2026-11")
        await linked.start()
        XCTAssertEqual(linked.month, "2026-11")
        XCTAssertEqual(linked.phase, .failed(.notReady))
    }

    func testShareIdentityIsSavedOnTheAccount() async {
        let model = makeModel(service: RecordingRecapService(months: []), initialMonth: nil)
        await model.start()
        XCTAssertTrue(model.sharesIdentity)
        XCTAssertTrue(model.receivesEmail)
        let saved = await model.setSharesIdentity(false)
        XCTAssertTrue(saved)
        XCTAssertFalse(model.sharesIdentity)
        XCTAssertTrue(model.receivesEmail, "le PATCH n'envoie que le choix de partage")
    }

    func testEmailCardFollowsTheSettingsClosedFromIt() async {
        let account = RecapPreferencesBox()
        let model = MonthlyRecapViewModel(
            initialMonth: nil,
            service: RecordingRecapService(months: []),
            loadBadgeTitles: { [:] },
            loadPreferences: { account.preferences },
            savePreferences: { $0 }
        )
        await model.start()
        XCTAssertTrue(model.receivesEmail)
        account.preferences.notifyMonthlyRecapEmail = false
        await model.reloadPreferences()
        XCTAssertFalse(model.receivesEmail, "la carte E-mail disparaît au retour des réglages")
    }

    private func makeModel(service: RecordingRecapService, initialMonth: String?) -> MonthlyRecapViewModel {
        MonthlyRecapViewModel(
            initialMonth: initialMonth,
            service: service,
            loadBadgeTitles: { ["explorer_rural": "Explorateur"] },
            loadPreferences: {
                var prefs = NotificationPreferences.empty
                prefs.notifyMonthlyRecapEmail = true
                return prefs
            },
            savePreferences: { patch in
                XCTAssertNil(patch.notifyMonthlyRecapEmail)
                return patch
            }
        )
    }
}

/// Préférences du compte, changées « dans les réglages » pendant le test.
private final class RecapPreferencesBox: @unchecked Sendable {
    var preferences: NotificationPreferences = {
        var prefs = NotificationPreferences.empty
        prefs.notifyMonthlyRecapEmail = true
        return prefs
    }()
}

private actor RecordingRecapService: MonthlyRecapServicing {
    let monthList: [MonthlyRecapMonth]
    let failure: MonthlyRecapError?
    let recapFailure: MonthlyRecapError?
    private(set) var requested: [String] = []

    init(months: [MonthlyRecapMonth], failure: MonthlyRecapError? = nil, recapFailure: MonthlyRecapError? = nil) {
        monthList = months
        self.failure = failure
        self.recapFailure = recapFailure
    }

    func months() async throws -> [MonthlyRecapMonth] {
        if let failure { throw failure }
        return monthList
    }

    func recap(month: String) async throws -> MonthlyRecap {
        requested.append(month)
        if let recapFailure { throw recapFailure }
        let json = MonthlyRecapQAService.fullJSON.replacingOccurrences(of: "\"2026-10\"", with: "\"\(month)\"")
        return try JSONDecoder().decode(MonthlyRecap.self, from: Data(json.utf8))
    }

    func image(month: String, options: MonthlyRecapImageOptions) async throws -> Data { Data() }
    func eraseLocalData(ownerScopeId: String) async {}
}
