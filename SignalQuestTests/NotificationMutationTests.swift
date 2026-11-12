import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import SignalQuest

@MainActor
final class NotificationMutationTests: XCTestCase {
    // MARK: NOTIF-I18N (contrat `notification-text-keys` v1, copie à l'octet de
    // `contracts/notification-text-keys/v1.json`, 982af8f46, servi le 12/11)

    private struct TextKeyVectors: Decodable {
        struct Key: Decodable { let key: String; let args: [String: String]; let title: String; let fr: String }
        struct Case: Decodable {
            struct Expect: Decodable { let textKey: String?; let textArgs: [String: JSONValue]? }
            let name: String
            let expect: Expect
        }
        let version: Int
        let keys: [Key]
        let cases: [Case]
    }

    private func textKeyVectors() throws -> TextKeyVectors {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/notification-text-keys/v1.json"))
        return try JSONDecoder().decode(TextKeyVectors.self, from: data)
    }

    func testNotificationTextCatalogMatchesTheContract() throws {
        let vectors = try textKeyVectors()
        XCTAssertEqual(vectors.version, 1)
        XCTAssertEqual(vectors.keys.count, 14)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: vectors.keys.map { ($0.key, $0.args) }), NotificationTextKey.contractArgs)
    }

    /// Chaque sortie servie s'écrit, titre et texte, comme le gabarit français du
    /// contrat. Écarts voulus : apostrophe typographique, tutoiement par défaut
    /// (référence du niveau corrigée par le serveur le 12/11) et « autre(s) personne(s) »,
    /// comme le texte de repli du serveur.
    func testEveryServedNotificationCaseRendersLikeTheContract() throws {
        guard Bundle.main.preferredLocalizations.first == "fr" else { return }
        let vectors = try textKeyVectors()
        XCTAssertEqual(vectors.cases.count, 35)
        let templates = Dictionary(uniqueKeysWithValues: vectors.keys.map { ($0.key, $0) })
        var rendered = 0
        for testCase in vectors.cases {
            guard let key = testCase.expect.textKey else {
                XCTAssertNil(NotificationTextKey(key: nil, args: testCase.expect.textArgs), testCase.name)
                continue
            }
            let text = try XCTUnwrap(NotificationTextKey(key: key, args: testCase.expect.textArgs), testCase.name)
            let template = try XCTUnwrap(templates[key])
            func fill(_ raw: String) -> String {
                var out = raw
                for (name, value) in testCase.expect.textArgs ?? [:] {
                    let shown: String
                    switch value {
                    case .string(let string): shown = string
                    case .number(let number): shown = String(Int(number))
                    default: shown = ""
                    }
                    out = out.replacingOccurrences(of: "{\(name)}", with: shown)
                }
                return out.replacingOccurrences(of: "'", with: "’")
                    .replacingOccurrences(of: "Vous passez", with: "Tu passes")
                    .replacingOccurrences(of: " autres ", with: " autres personnes ")
                    .replacingOccurrences(of: " 1 autres personnes ", with: " 1 autre personne ")
            }
            XCTAssertEqual(text.title, fill(template.title), testCase.name)
            XCTAssertEqual(text.message, fill(template.fr), testCase.name)
            rendered += 1
        }
        XCTAssertEqual(rendered, 24)
    }

    /// Tout ou rien : la ligne garde le texte du serveur dès qu'un argument manque,
    /// est vide ou mal typé, ou que la clé est inconnue.
    func testNotificationTextKeyRefusesWhatItCannotSay() {
        let name: JSONValue = .string("Léa B.")
        XCTAssertNil(NotificationTextKey(key: "notif.social.unknown", args: ["actorName": name]))
        XCTAssertNil(NotificationTextKey(key: "notif.social.comment", args: nil))
        XCTAssertNil(NotificationTextKey(key: "notif.social.comment", args: ["actorName": .string("  ")]))
        XCTAssertNil(NotificationTextKey(key: "notif.social.comment", args: ["actorName": .number(3)]))
        XCTAssertNil(NotificationTextKey(key: "notif.social.comment_group", args: ["actorName": name, "otherCount": .number(0)]))
        XCTAssertNil(NotificationTextKey(key: "notif.social.comment_group", args: ["actorName": name, "otherCount": .number(1.5)]))
        XCTAssertNil(NotificationTextKey(key: "notif.social.comment_group", args: ["actorName": name, "otherCount": .string("2")]))
        XCTAssertNil(NotificationTextKey(key: "notif.progress.level", args: ["newLevel": .number(0)]))
        XCTAssertNil(NotificationTextKey(key: "notif.progress.badge", args: ["badgeName": .string("Explorateur")]))
        XCTAssertNotNil(NotificationTextKey(key: "notif.social.comment", args: ["actorName": name, "extra": .null]))

        let fallback = AppNotification(id: "n", type: "social_comment", title: "Titre serveur", message: "Texte serveur",
            createdAt: nil, read: false, link: nil, metadata: nil, textKey: "notif.social.comment", textArgs: [:])
        XCTAssertEqual(fallback.displayTitle, "Titre serveur")
        XCTAssertEqual(fallback.displayMessage, "Texte serveur")
    }

    /// Les champs sont lus dans la liste ; des arguments illisibles ne font pas
    /// tomber la notification, qui garde alors son texte.
    func testNotificationDecodesTextKeyLeniently() throws {
        let served = Data(#"{"id":"n1","type":"social_comment","title":"T","message":"M","textKey":"notif.social.comment","textArgs":{"actorName":"Léa B."}}"#.utf8)
        let item = try JSONDecoder().decode(AppNotification.self, from: served)
        XCTAssertEqual(item.textKey, "notif.social.comment")
        XCTAssertEqual(item.textArgs, ["actorName": .string("Léa B.")])
        XCTAssertNotEqual(item.displayMessage, "M")

        let broken = Data(#"{"id":"n2","title":"T","message":"M","textKey":42,"textArgs":"oops"}"#.utf8)
        let kept = try JSONDecoder().decode(AppNotification.self, from: broken)
        XCTAssertNil(kept.textKey)
        XCTAssertNil(kept.textArgs)
        XCTAssertEqual(kept.displayTitle, "T")
        XCTAssertEqual(kept.displayMessage, "M")
    }

    /// Chaque phrase écrite par l'app a sa traduction anglaise et, quand elle
    /// s'adresse au membre, sa variante au « vous ».
    func testNotificationTextsAreTranslated() throws {
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let french = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj").flatMap(Bundle.init(path:)))
        let sentences = [
            "Nouvelle réponse", "Publication repartagée", "Tu as été mentionné", "Nouvel abonné",
            "%@ a aimé ta publication.", "%@ a réagi %@ à ta publication.",
            "%@ et %lld autres personnes ont réagi à ta publication.", "%@ et 1 autre personne ont réagi à ta publication.",
            "%@ a commenté ta publication.", "%@ et %lld autres personnes ont commenté ta publication.",
            "%@ a répondu à ton commentaire.", "%@ et %lld autres personnes ont répondu à ton commentaire.",
            "%@ a repartagé ta publication.", "%@ et %lld autres personnes ont repartagé ta publication.",
            "%@ t’a mentionné dans le réseau social.", "%@ et %lld autres personnes t’ont mentionné.",
            "%@ suit maintenant ton profil public.", "Badge « %@ » obtenu.", "Tu passes au niveau %lld.",
        ]
        let missing = "\u{1}missing"
        for sentence in sentences {
            XCTAssertNotEqual(english.localizedString(forKey: sentence, value: missing, table: nil), missing, sentence)
            let tutoiement = sentence.contains(" ta ") || sentence.contains(" ton ") || sentence.contains("t’")
                || sentence.hasPrefix("Tu ")
            if tutoiement {
                XCTAssertNotEqual(french.localizedString(forKey: "SQFormal|" + sentence, value: missing, table: nil), missing, sentence)
            }
        }
    }

    private func item(_ id: String, read: Bool = false) -> AppNotification {
        AppNotification(id: id, type: "social_comment", title: id, message: nil,
            createdAt: nil, read: read, link: nil, metadata: nil)
    }

    /// Les sections suivent le jour civil : « Aujourd’hui », les six jours d'avant,
    /// puis le reste ; une notification sans date va en « Plus ancien ». L'ordre
    /// du serveur est gardé dans chaque section.
    func testPeriodsGroupByCalendarDayAndKeepServerOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 1, minute: 10))!
        func dated(_ id: String, _ ago: TimeInterval?) -> AppNotification {
            AppNotification(id: id, type: nil, title: id, message: nil,
                createdAt: ago.map { now.addingTimeInterval(-$0) }, read: false, link: nil, metadata: nil)
        }
        XCTAssertEqual(NotificationPeriod.of(now.addingTimeInterval(-600), now: now, calendar: calendar), .today)
        // 01 h 10 moins deux heures : c'est hier, donc « Cette semaine ».
        XCTAssertEqual(NotificationPeriod.of(now.addingTimeInterval(-7_200), now: now, calendar: calendar), .thisWeek)
        XCTAssertEqual(NotificationPeriod.of(now.addingTimeInterval(-6 * 86_400), now: now, calendar: calendar), .thisWeek)
        XCTAssertEqual(NotificationPeriod.of(now.addingTimeInterval(-8 * 86_400), now: now, calendar: calendar), .older)
        XCTAssertEqual(NotificationPeriod.of(nil, now: now, calendar: calendar), .older)

        let groups = NotificationPeriod.groups([dated("a", 60), dated("old", 20 * 86_400), dated("b", 120), dated("none", nil)], now: now)
        XCTAssertEqual(groups.map(\.period), [.today, .older])
        XCTAssertEqual(groups.first?.items.map(\.id), ["a", "b"])
        XCTAssertEqual(groups.last?.items.map(\.id), ["old", "none"])
    }

    func testPageDecoderAcceptsNewCursorAndLegacyItems() throws {
        let current = Data(#"{"notifications":[{"id":"a","read":false}],"nextCursor":"after-a","unreadCount":51}"#.utf8)
        let page = try JSONDecoder.signalQuest.decode(AppNotificationPage.self, from: current)
        XCTAssertEqual(page.notifications.map(\.id), ["a"])
        XCTAssertEqual(page.nextCursor, "after-a")
        XCTAssertEqual(page.unreadCount, 51)

        let legacy = Data(#"{"items":[{"id":"b","read":true}]}"#.utf8)
        let oldPage = try JSONDecoder.signalQuest.decode(AppNotificationPage.self, from: legacy)
        XCTAssertEqual(oldPage.notifications.map(\.id), ["b"])
        XCTAssertNil(oldPage.nextCursor)
    }

    func testErrorAndNextPageControlsRender() async throws {
        let service = NotificationMutationMock(items: [item("a")], failReadOnce: true,
            nextCursor: "after-a", nextPage: [item("b")])
        let model = NotificationsCenterViewModel(service: service)
        await model.load()
        await model.markRead("a")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = UIDevice.current.userInterfaceIdiom == .pad
            ? CGSize(width: 700, height: 900) : CGSize(width: 360, height: 740)
        let view = NavigationStack {
            NotificationsCenterView(model: model)
        }
        .environmentObject(AppRouter())
        .environment(\.locale, Locale(identifier: "fr"))
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.isHidden = false
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "notifications-error-and-next-page"
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
    }

    func testOfflineReadRemainsUnreadUntilRetrySucceeds() async {
        let service = NotificationMutationMock(items: [item("a")], failReadOnce: true)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()

        await model.markRead("a")
        XCTAssertEqual(model.items.first?.read, false)
        XCTAssertEqual(model.failedAction, .markRead("a"))
        XCTAssertNotNil(model.actionErrorMessage)

        await model.retryFailedAction()
        XCTAssertEqual(model.items.first?.read, true)
        XCTAssertNil(model.failedAction)
        XCTAssertNil(model.actionErrorMessage)
        let count = await service.readCount()
        XCTAssertEqual(count, 2)
    }

    func testRelaunchReadsServerTruthAfterOfflineFailureAndRetry() async {
        let service = NotificationMutationMock(items: [item("a")], failReadOnce: true)
        let firstLaunch = NotificationsCenterViewModel(service: service)
        await firstLaunch.load()
        await firstLaunch.markRead("a")
        XCTAssertEqual(firstLaunch.items.first?.read, false)

        let reopened = NotificationsCenterViewModel(service: service)
        await reopened.load()
        XCTAssertEqual(reopened.items.first?.read, false)
        XCTAssertEqual(reopened.unreadCount, 1)
        await reopened.markRead("a")

        let afterRetry = NotificationsCenterViewModel(service: service)
        await afterRetry.load()
        XCTAssertEqual(afterRetry.items.first?.read, true)
        XCTAssertEqual(afterRetry.unreadCount, 0)
    }

    func testFailedGroupActionsPreserveItemsAndCanRetry() async {
        let service = NotificationMutationMock(items: [item("a"), item("b")],
            failMarkAllOnce: true, failDeleteOnce: true)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()

        await model.markAll()
        XCTAssertEqual(model.items.map(\.read), [false, false])
        XCTAssertEqual(model.failedAction, .markAll)
        await model.retryFailedAction()
        XCTAssertEqual(model.items.map(\.read), [true, true])

        await model.deleteAll()
        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(model.failedAction, .deleteAll)
        await model.retryFailedAction()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.failedAction)
    }

    /// Suppression unitaire : la ligne part tout de suite (animation de la liste), puis revient
    /// à sa place avec son compteur si le serveur refuse, et l'action se rejoue.
    func testSingleDeleteRemovesTheRowAndKeepsItWhenTheServerFails() async {
        let service = NotificationMutationMock(items: [item("a"), item("b", read: true)], failDeleteOnce: true)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()
        XCTAssertEqual(model.unreadCount, 1)

        let pending = try? XCTUnwrap(model.beginDelete("a"))
        XCTAssertEqual(model.items.map(\.id), ["b"], "Retirée avant la réponse du serveur")
        XCTAssertEqual(model.unreadCount, 0)
        if let pending { await model.commitDelete(pending) }
        XCTAssertEqual(model.items.map(\.id), ["a", "b"])
        XCTAssertEqual(model.failedAction, .delete("a"))
        XCTAssertNotNil(model.actionErrorMessage)
        XCTAssertEqual(model.unreadCount, 1, "Le refus rend la non-lue")

        await model.retryFailedAction()
        XCTAssertEqual(model.items.map(\.id), ["b"])
        XCTAssertEqual(model.unreadCount, 0)
        XCTAssertNil(model.failedAction)

        await model.delete("b")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.unreadCount, 0)
    }

    /// Une métadonnée hors plage ne doit pas arrêter l'app au tap ; l'année s'affiche hors de l'année courante.
    func testMetadataTextIgnoresNumbersThatAreNotWholeIntegers() {
        XCTAssertEqual(NotificationsCenterView.metaText(.string("site-1")), "site-1")
        XCTAssertEqual(NotificationsCenterView.metaText(.number(42)), "42")
        XCTAssertNil(NotificationsCenterView.metaText(.number(1e20)))
        XCTAssertNil(NotificationsCenterView.metaText(.number(.infinity)))
        XCTAssertNil(NotificationsCenterView.metaText(.number(.nan)))
        XCTAssertNil(NotificationsCenterView.metaText(.number(1.5)))
        XCTAssertNil(NotificationsCenterView.metaText(.string("")))
        XCTAssertNil(NotificationsCenterView.metaText(nil))
    }

    func testOlderNotificationsShowTheYearOnlyOutsideTheCurrentOne() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
        let sameYear = calendar.date(from: DateComponents(year: 2026, month: 1, day: 12))!
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 10, day: 12))!
        XCTAssertFalse(NotificationPeriod.isOutsideCurrentYear(sameYear, now: now, calendar: calendar))
        XCTAssertTrue(NotificationPeriod.isOutsideCurrentYear(lastYear, now: now, calendar: calendar))
    }

    func testOlderReloadCannotUndoAcknowledgedMarkAll() async {
        let gate = NotificationLoadGate()
        let service = NotificationMutationMock(items: [item("a")], delayedSecondList: gate)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()
        let staleLoad = Task { await model.load() }
        for _ in 0..<100 {
            if await service.listCount() == 2 { break }
            await Task.yield()
        }
        guard await service.listCount() == 2 else {
            await gate.finish()
            staleLoad.cancel()
            return XCTFail("The stale load never started")
        }

        await model.markAll()
        XCTAssertEqual(model.items.first?.read, true)
        await gate.finish()
        await staleLoad.value
        XCTAssertEqual(model.items.first?.read, true)
        XCTAssertFalse(model.isLoading)
    }

    func testOlderReloadCannotUndoAcknowledgedSingleRead() async {
        let gate = NotificationLoadGate()
        let service = NotificationMutationMock(items: [item("a")], delayedSecondList: gate)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()
        let staleLoad = Task { await model.load() }
        for _ in 0..<100 {
            if await service.listCount() == 2 { break }
            await Task.yield()
        }
        guard await service.listCount() == 2 else {
            await gate.finish()
            staleLoad.cancel()
            return XCTFail("The stale load never started")
        }

        await model.markRead("a")
        XCTAssertEqual(model.items.first?.read, true)
        await gate.finish()
        await staleLoad.value
        XCTAssertEqual(model.items.first?.read, true)
        XCTAssertFalse(model.isLoading)
    }

    func testGroupMutationWaitsForSingleReadToSettle() async {
        let gate = NotificationLoadGate()
        let service = NotificationMutationMock(items: [item("a")], delayedRead: gate)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()
        let pendingRead = Task { await model.markRead("a") }
        for _ in 0..<100 {
            if await service.readCount() == 1 { break }
            await Task.yield()
        }
        guard await service.readCount() == 1 else {
            await gate.finish()
            pendingRead.cancel()
            return XCTFail("The single read never started")
        }

        await model.markAll()
        let before = await service.markAllCount()
        XCTAssertEqual(before, 0)
        await gate.finish()
        await pendingRead.value
        await model.markAll()
        let after = await service.markAllCount()
        XCTAssertEqual(after, 1)
    }

    func testFiftyFirstNotificationLoadsWithoutDuplicates() async {
        let first = (0..<50).map { item("notice-\($0)") }
        let last = [item("notice-49"), item("notice-50")]
        let service = NotificationMutationMock(items: first, nextCursor: "after-50",
            nextPage: last, unreadTotal: 51)
        let model = NotificationsCenterViewModel(service: service)

        await model.load()
        XCTAssertEqual(model.items.count, 50)
        XCTAssertEqual(model.unreadCount, 51)
        XCTAssertEqual(model.nextCursor, "after-50")
        await model.loadMore()
        XCTAssertEqual(model.items.count, 51)
        XCTAssertEqual(model.items.last?.id, "notice-50")
        XCTAssertNil(model.nextCursor)
        let cursors = await service.requestedCursors()
        XCTAssertEqual(cursors, ["first", "after-50"])
    }

    func testFailedNextPagePreservesItemsAndRetriesTheCursor() async {
        let service = NotificationMutationMock(items: [item("a")], nextCursor: "after-a",
            nextPage: [item("b")], failNextPageOnce: true)
        let model = NotificationsCenterViewModel(service: service)

        await model.load()
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["a"])
        XCTAssertEqual(model.nextCursor, "after-a")
        XCTAssertNotNil(model.paginationErrorMessage)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["a", "b"])
        XCTAssertNil(model.paginationErrorMessage)
        let cursors = await service.requestedCursors()
        XCTAssertEqual(cursors, ["first", "after-a", "after-a"])
    }

    func testLatePageCannotRestoreNotificationsAfterDeleteAll() async {
        let gate = NotificationLoadGate()
        let service = NotificationMutationMock(items: [item("a")], nextCursor: "after-a",
            nextPage: [item("b")], delayedNextPage: gate)
        let model = NotificationsCenterViewModel(service: service)
        await model.load()
        let latePage = Task { await model.loadMore() }
        for _ in 0..<100 {
            if await service.listCount() == 2 { break }
            await Task.yield()
        }
        guard await service.listCount() == 2 else {
            await gate.finish()
            latePage.cancel()
            return XCTFail("The second page never started")
        }

        await model.deleteAll()
        await gate.finish()
        await latePage.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.nextCursor)
        XCTAssertEqual(model.unreadCount, 0)
        XCTAssertFalse(model.isLoadingMore)
    }
}

private actor NotificationLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { finished = true; continuation?.resume(); continuation = nil }
}

private actor NotificationMutationMock: NotificationsServicing {
    enum Failure: Error { case offline }
    private var rows: [AppNotification]
    private var readFailures: Int
    private var markAllFailures: Int
    private var deleteFailures: Int
    private let delayedSecondList: NotificationLoadGate?
    private let delayedRead: NotificationLoadGate?
    private let delayedNextPage: NotificationLoadGate?
    private let nextCursor: String?
    private let nextPage: [AppNotification]
    private let unreadTotal: Int?
    private var nextPageFailures: Int
    private var cursors: [String] = []
    private var lists = 0
    private var reads = 0
    private var markAlls = 0

    init(items: [AppNotification], failReadOnce: Bool = false,
         failMarkAllOnce: Bool = false, failDeleteOnce: Bool = false,
         delayedSecondList: NotificationLoadGate? = nil,
         delayedRead: NotificationLoadGate? = nil,
         nextCursor: String? = nil, nextPage: [AppNotification] = [],
         unreadTotal: Int? = nil, failNextPageOnce: Bool = false,
         delayedNextPage: NotificationLoadGate? = nil) {
        rows = items
        readFailures = failReadOnce ? 1 : 0
        markAllFailures = failMarkAllOnce ? 1 : 0
        deleteFailures = failDeleteOnce ? 1 : 0
        self.delayedSecondList = delayedSecondList
        self.delayedRead = delayedRead
        self.nextCursor = nextCursor
        self.nextPage = nextPage
        self.unreadTotal = unreadTotal
        nextPageFailures = failNextPageOnce ? 1 : 0
        self.delayedNextPage = delayedNextPage
    }

    func list(cursor: String?) async throws -> AppNotificationPage {
        lists += 1
        let snapshot = rows
        cursors.append(cursor ?? "first")
        if cursor != nil {
            await delayedNextPage?.wait()
            if nextPageFailures > 0 { nextPageFailures -= 1; throw Failure.offline }
            return AppNotificationPage(notifications: nextPage, nextCursor: nil,
                unreadCount: unreadTotal ?? snapshot.filter { $0.read != true }.count)
        }
        if lists == 2 { await delayedSecondList?.wait() }
        return AppNotificationPage(notifications: snapshot, nextCursor: nextCursor,
            unreadCount: unreadTotal ?? snapshot.filter { $0.read != true }.count)
    }
    func markRead(id: String) async throws {
        reads += 1
        await delayedRead?.wait()
        if readFailures > 0 { readFailures -= 1; throw Failure.offline }
        rows = rows.map { row in
            guard row.id == id else { return row }
            return AppNotification(id: row.id, type: row.type, title: row.title,
                message: row.message, createdAt: row.createdAt, read: true,
                link: row.link, metadata: row.metadata)
        }
    }
    func markAllRead() async throws {
        markAlls += 1
        if markAllFailures > 0 { markAllFailures -= 1; throw Failure.offline }
        rows = rows.map { row in
            AppNotification(id: row.id, type: row.type, title: row.title,
                message: row.message, createdAt: row.createdAt, read: true,
                link: row.link, metadata: row.metadata)
        }
    }
    func delete(id: String) async throws {
        if deleteFailures > 0 { deleteFailures -= 1; throw Failure.offline }
        rows.removeAll { $0.id == id }
    }
    func deleteAll() async throws {
        if deleteFailures > 0 { deleteFailures -= 1; throw Failure.offline }
        rows = []
    }
    func listCount() -> Int { lists }
    func readCount() -> Int { reads }
    func markAllCount() -> Int { markAlls }
    func requestedCursors() -> [String] { cursors }
}
