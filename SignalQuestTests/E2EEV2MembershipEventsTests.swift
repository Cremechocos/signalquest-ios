import XCTest
@testable import SignalQuest

/// Messages système vérifiés du fil v2 (§2.5, §2.7) : tirés de la chaîne
/// d'appartenance gardée, en français et en anglais, sans accord de genre.
final class E2EEV2MembershipEventsTests: XCTestCase {
    private let conversationId = "conv-membership-0001"
    private let alice = "user-alice-000001"
    private let bruno = "user-bruno-000002"
    private let chloe = "user-chloe-000003"
    private let david = "user-david-000004"
    private let outsider = "user-zoe-00000005"

    private var members: [String: MessageUser] {
        [
            alice: MessageUser(id: alice, name: "Alice", email: "alice@example.com", avatarUrl: nil),
            bruno: MessageUser(id: bruno, name: "Bruno", email: "bruno@example.com", avatarUrl: nil),
            chloe: MessageUser(id: chloe, name: "Chloé", email: "chloe@example.com", avatarUrl: nil),
        ]
    }

    private func genesis(
        isGroup: Bool, memberIds: [String], adminIds: [String], excludesWeb: Bool = false
    ) throws -> [E2EEV2MembershipChange] {
        try E2EEV2MembershipChain.genesis(
            conversationId: conversationId, memberIds: memberIds, adminIds: adminIds, isGroup: isGroup,
            excludesWeb: excludesWeb, actor: .init(userId: alice, deviceId: "device-alice-00001"), createdAtMs: 1_000
        )
    }

    private func change(_ number: Int, _ action: String, target: String, by actor: String) -> E2EEV2MembershipChange {
        E2EEV2MembershipChange(
            conversationId: conversationId, changeNumber: number, action: action, targetUserId: target,
            actorUserId: actor, actorDeviceId: "device-\(actor)", previousChangeDigest: "-",
            createdAtMs: Int64(2_000 + number)
        )
    }

    private func localizationBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    private func texts(
        _ changes: [E2EEV2MembershipChange], genesisLength: Int, isGroup: Bool = true, own: String,
        members: [String: MessageUser]? = nil, _ language: String
    ) throws -> [String] {
        E2EEV2MembershipEvents.present(
            changes, genesisLength: genesisLength, isGroup: isGroup, ownUserId: own,
            members: members ?? self.members, bundle: try localizationBundle(language)
        ).map(\.text)
    }

    /// La genèse se résume à qui a activé le chiffrement et aux admins ; la suite
    /// suit la chaîne, et un changement sans effet n'annonce rien.
    func testAGroupChainBecomesEventsInChainOrder() throws {
        let changes = try genesis(isGroup: true, memberIds: [alice, bruno, chloe], adminIds: [alice]) + [
            change(5, "ADD", target: david, by: alice),
            change(6, "ROLE_ADMIN", target: bruno, by: alice),
            change(7, "ROLE_ADMIN", target: bruno, by: alice),
            change(8, "EXCLUDE_WEB_ON", target: "-", by: bruno),
            change(9, "EXCLUDE_WEB_ON", target: "-", by: alice),
            change(10, "REMOVE", target: chloe, by: bruno),
            change(11, "ROLE_MEMBER", target: bruno, by: bruno),
            change(12, "EXCLUDE_WEB_OFF", target: "-", by: alice),
            change(13, "LEAVE", target: david, by: david),
        ]
        let events = E2EEV2MembershipEvents.present(
            changes, genesisLength: 4, isGroup: true, ownUserId: outsider, members: members
        )
        XCTAssertEqual(events.map(\.kind), [
            .enabled(by: alice), .admins([alice]), .added(david, by: alice), .madeAdmin(bruno, by: alice),
            .browsersExcluded(by: bruno), .removed(chloe, by: bruno), .adminRoleRemoved(bruno, by: bruno),
            .browsersAllowed(by: alice), .left(david),
        ])
        XCTAssertEqual(events.map(\.changeNumber), [1, 4, 5, 6, 8, 10, 11, 12, 13])
        XCTAssertEqual(Set(events.map(\.id)).count, events.count)
        XCTAssertEqual(events.first?.atMs, 1_000, "Heure signée par l'auteur")
        XCTAssertEqual(events.last?.atMs, 2_013)

        XCTAssertEqual(try texts(changes, genesisLength: 4, own: outsider, "fr"), [
            "Alice a activé le chiffrement de bout en bout de cette conversation.",
            "Admins : Alice.",
            "Alice a ajouté un membre.",
            "Alice a nommé Bruno admin.",
            "Bruno a exclu les navigateurs de cette conversation.",
            "Bruno a retiré Chloé du groupe.",
            "Bruno a renoncé au rôle d’admin.",
            "Alice a de nouveau autorisé les navigateurs dans cette conversation.",
            "Un membre a quitté le groupe.",
        ])
        XCTAssertEqual(try texts(changes, genesisLength: 4, own: outsider, "en"), [
            "Alice turned on end-to-end encryption for this conversation.",
            "Admins: Alice.",
            "Alice added a member.",
            "Alice made Bruno an admin.",
            "Bruno excluded web browsers from this conversation.",
            "Bruno removed Chloé from the group.",
            "Bruno stepped down as admin.",
            "Alice allowed web browsers in this conversation again.",
            "A member left the group.",
        ])
    }

    /// Ce que l'on a fait soi-même, et ce qui nous concerne, se dit à la deuxième
    /// personne ; un nom vide compte comme inconnu.
    func testYourOwnActionsAndWhatConcernsYouAreToldToYou() throws {
        let changes = try genesis(isGroup: true, memberIds: [alice, bruno, chloe], adminIds: [alice]) + [
            change(5, "ADD", target: david, by: alice),
            change(6, "ROLE_ADMIN", target: chloe, by: alice),
            change(7, "ROLE_MEMBER", target: chloe, by: alice),
            change(8, "REMOVE", target: chloe, by: alice),
            change(9, "EXCLUDE_WEB_ON", target: "-", by: alice),
            change(10, "EXCLUDE_WEB_OFF", target: "-", by: alice),
            change(11, "LEAVE", target: alice, by: alice),
        ]
        var withBlankName = members
        withBlankName[david] = MessageUser(id: david, name: " ", email: "", avatarUrl: nil)

        XCTAssertEqual(try texts(changes, genesisLength: 4, own: alice, members: withBlankName, "fr"), [
            "Tu as activé le chiffrement de bout en bout de cette conversation.",
            "Admins : toi.",
            "Tu as ajouté un membre.",
            "Tu as nommé Chloé admin.",
            "Tu as retiré le rôle d’admin à Chloé.",
            "Tu as retiré Chloé du groupe.",
            "Tu as exclu les navigateurs de cette conversation.",
            "Tu as de nouveau autorisé les navigateurs dans cette conversation.",
            "Tu as quitté le groupe.",
        ])
        XCTAssertEqual(try texts(changes, genesisLength: 4, own: alice, members: withBlankName, "en"), [
            "You turned on end-to-end encryption for this conversation.",
            "Admins: you.",
            "You added a member.",
            "You made Chloé an admin.",
            "You removed Chloé’s admin role.",
            "You removed Chloé from the group.",
            "You excluded web browsers from this conversation.",
            "You allowed web browsers in this conversation again.",
            "You left the group.",
        ])
        let chloeFrench = try texts(changes, genesisLength: 4, own: chloe, "fr")
        XCTAssertEqual(Array(chloeFrench[3...5]), [
            "Alice t’a donné le rôle d’admin.",
            "Alice t’a retiré le rôle d’admin.",
            "Alice t’a fait sortir du groupe.",
        ])
        let chloeEnglish = try texts(changes, genesisLength: 4, own: chloe, "en")
        XCTAssertEqual(Array(chloeEnglish[3...5]), [
            "Alice made you an admin.", "Alice removed your admin role.", "Alice removed you from the group.",
        ])
        XCTAssertEqual(try texts(changes, genesisLength: 4, own: david, "fr")[2], "Alice t’a fait entrer dans le groupe.")
        XCTAssertEqual(try texts(changes, genesisLength: 4, own: david, "en")[2], "Alice added you.")
        XCTAssertEqual(try texts(changes, genesisLength: 4, own: chloe, "fr")[8], "Alice a quitté le groupe.")
    }

    /// Tête-à-tête : pas d'admins, navigateurs exclus dès la genèse, départ de la conversation.
    func testAOneToOneChainAnnouncesBrowsersAndDepartures() throws {
        let changes = try genesis(isGroup: false, memberIds: [alice, bruno], adminIds: [], excludesWeb: true) + [
            change(4, "EXCLUDE_WEB_OFF", target: "-", by: bruno),
            change(5, "LEAVE", target: bruno, by: bruno),
        ]
        let events = E2EEV2MembershipEvents.present(
            changes, genesisLength: 3, isGroup: false, ownUserId: alice, members: members
        )
        XCTAssertEqual(events.map(\.kind), [
            .enabled(by: alice), .browsersExcluded(by: alice), .browsersAllowed(by: bruno), .left(bruno),
        ])
        XCTAssertEqual(try texts(changes, genesisLength: 3, isGroup: false, own: alice, "fr"), [
            "Tu as activé le chiffrement de bout en bout de cette conversation.",
            "Tu as exclu les navigateurs de cette conversation.",
            "Bruno a de nouveau autorisé les navigateurs dans cette conversation.",
            "Bruno a quitté la conversation.",
        ])
        XCTAssertEqual(try texts(changes, genesisLength: 3, isGroup: false, own: bruno, "en"), [
            "Alice turned on end-to-end encryption for this conversation.",
            "Alice excluded web browsers from this conversation.",
            "You allowed web browsers in this conversation again.",
            "You left the conversation.",
        ])
    }

    /// La chaîne gardée se relit maillon par maillon : un maillon manquant la refuse.
    func testTheKeptChainReadsBackAndAMissingLinkIsRefused() throws {
        let changes = try genesis(isGroup: true, memberIds: [alice, bruno, chloe], adminIds: [alice, bruno])
        let chain = changes.map { E2EEV2SignedString(canonical: $0.canonical, signatureB64: "AA==") }
        XCTAssertEqual(try E2EEV2MembershipEvents.changes(from: chain), changes)
        XCTAssertEqual(try texts(changes, genesisLength: changes.count, own: chloe, "fr")[1], "Admins : Alice, Bruno.")

        var broken = chain
        broken.remove(at: 1)
        XCTAssertThrowsError(try E2EEV2MembershipEvents.changes(from: broken))
    }
}
