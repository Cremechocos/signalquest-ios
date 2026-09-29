import XCTest
@testable import SignalQuest

/// Date de la liste des conversations (UI-12) : « il y a 2 m. » se lisait
/// minutes ou mois.
final class ConversationListDateTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()
    private let fr = Locale(identifier: "fr_FR")

    private func date(_ day: Int, _ hour: Int, month: Int = 9, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 5))!
    }

    func testTodayShowsTheTime() {
        let now = date(29, 23)
        XCTAssertEqual(ConversationListDate.label(for: date(29, 14), now: now, calendar: calendar, locale: fr), "14:05")
    }

    func testYesterdayIsNamed() {
        let now = date(29, 9)
        XCTAssertEqual(ConversationListDate.label(for: date(28, 22), now: now, calendar: calendar, locale: fr),
                       String(localized: "Hier"))
    }

    func testThisWeekShowsTheWeekday() {
        let now = date(29, 9) // mardi
        XCTAssertEqual(ConversationListDate.label(for: date(25, 10), now: now, calendar: calendar, locale: fr), "vendredi")
    }

    func testOlderShowsTheDateAndTheYearOnlyWhenItDiffers() {
        let now = date(29, 9)
        XCTAssertEqual(ConversationListDate.label(for: date(12, 10), now: now, calendar: calendar, locale: fr), "12 sept.")
        XCTAssertEqual(ConversationListDate.label(for: date(12, 10, month: 9, year: 2025), now: now, calendar: calendar, locale: fr),
                       "12 sept. 2025")
    }
}

/// Règle unique de non-lu pour la liste et le badge (SOC-23) : le badge
/// comptait son propre dernier message comme non lu.
final class ConversationUnreadRuleTests: XCTestCase {

    private func conversation(lastSender: String, lastAt: Date?, readAt: Date?) -> MessageConversation {
        let last = MessageItem(
            id: "m-1", conversationId: "c-1", senderId: lastSender, kind: "TEXT", content: "Salut",
            e2eeVersion: nil, e2eeIvB64: nil, e2eeCiphertextB64: nil, e2eeAadB64: nil, metadata: nil,
            createdAt: lastAt, editedAt: nil, deletedAt: nil, replyToId: nil, threadReplyCount: 0,
            sender: nil, attachments: [], reactions: []
        )
        return MessageConversation(
            id: "c-1", title: nil, isGroup: false, e2eeEnabled: false, groupPhotoUrl: nil, createdAt: nil,
            updatedAt: nil, lastMessageAt: lastAt, lastReadAt: readAt, pinnedAt: nil, participants: [], lastMessage: last
        )
    }

    func testOwnLastMessageIsNeverUnread() {
        let now = Date()
        XCTAssertFalse(conversation(lastSender: "me", lastAt: now, readAt: nil).isUnread(currentUserId: "me"))
    }

    func testOthersMessageAfterLastReadIsUnread() {
        let now = Date()
        XCTAssertTrue(conversation(lastSender: "other", lastAt: now, readAt: now.addingTimeInterval(-60)).isUnread(currentUserId: "me"))
        XCTAssertTrue(conversation(lastSender: "other", lastAt: now, readAt: nil).isUnread(currentUserId: "me"))
        XCTAssertFalse(conversation(lastSender: "other", lastAt: now, readAt: now.addingTimeInterval(60)).isUnread(currentUserId: "me"))
    }
}
