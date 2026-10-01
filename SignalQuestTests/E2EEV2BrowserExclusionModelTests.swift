import XCTest
@testable import SignalQuest

/// Réglage « exclure les navigateurs » (§2.7, D.4) : qui peut le changer, et ce
/// que dit l'écran de chaque réponse de la messagerie v2.
@MainActor
final class E2EEV2BrowserExclusionModelTests: XCTestCase {
    private final class Changer: E2EEV2BrowserExclusionChanging, @unchecked Sendable {
        var results: [E2EEV2MembershipWriteResultV2]
        private(set) var calls: [Bool] = []

        init(_ results: [E2EEV2MembershipWriteResultV2]) { self.results = results }

        func setExcludesBrowsers(_ on: Bool) async -> E2EEV2MembershipWriteResultV2 {
            calls.append(on)
            return results.removeFirst()
        }
    }

    func testInAOneToOneEitherMemberChangesItAndAGroupMemberNever() async {
        let direct = Changer([.applied(changeNumber: 4)])
        let model = E2EEV2BrowserExclusionModel(excludesBrowsers: false, isGroup: false, isAdmin: false, changer: direct)
        XCTAssertTrue(model.canChange)
        await model.set(true)
        XCTAssertTrue(model.excludesBrowsers)
        XCTAssertNil(model.error)
        await model.set(true)
        XCTAssertEqual(direct.calls, [true], "Rien n'est signé quand rien ne change")

        let group = Changer([.applied(changeNumber: 9)])
        let member = E2EEV2BrowserExclusionModel(excludesBrowsers: true, isGroup: true, isAdmin: false, changer: group)
        XCTAssertFalse(member.canChange)
        await member.set(false)
        XCTAssertTrue(member.excludesBrowsers)
        XCTAssertTrue(group.calls.isEmpty, "Un membre d'un groupe n'envoie rien")
    }

    func testEachRefusalKeepsTheSettingAndSaysWhy() async throws {
        let bundle = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let changer = Changer([
            .needsSync, .failure(E2EEV2TransportFailure(kind: .retryable, message: "offline")),
            .notAllowed, .applied(changeNumber: 12),
        ])
        let model = E2EEV2BrowserExclusionModel(excludesBrowsers: false, isGroup: true, isAdmin: true, changer: changer)
        await model.set(true)
        XCTAssertFalse(model.excludesBrowsers)
        XCTAssertEqual(model.error, String(localized: "La conversation vient de changer. Réessaie."))
        await model.set(true)
        XCTAssertEqual(model.error, String(localized: "Impossible d’enregistrer ce réglage. Vérifie ta connexion et réessaie."))
        await model.set(true)
        XCTAssertEqual(model.error, String(localized: "Seul un admin du groupe peut changer ce réglage."))
        XCTAssertFalse(model.excludesBrowsers)
        await model.set(true)
        XCTAssertTrue(model.excludesBrowsers)
        XCTAssertNil(model.error, "Un succès efface l'erreur précédente")
        XCTAssertEqual(changer.calls, [true, true, true, true])
        XCTAssertEqual(
            bundle.localizedString(forKey: "La conversation vient de changer. Réessaie.", value: "MISSING", table: nil),
            "The conversation just changed. Try again."
        )

        let direct = Changer([.notAllowed])
        let oneToOne = E2EEV2BrowserExclusionModel(excludesBrowsers: false, isGroup: false, isAdmin: false, changer: direct)
        await oneToOne.set(true)
        XCTAssertEqual(oneToOne.error, String(localized: "Ce réglage ne peut plus être changé depuis ton compte."))
    }
}
