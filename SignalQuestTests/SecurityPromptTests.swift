import XCTest
@testable import SignalQuest

/// Carte « Protège ton compte » (contrat 2FA r3.4, §6) : lecture du profil et règles locales,
/// alignées sur Android (16/11).
@MainActor
final class SecurityPromptTests: XCTestCase {
    private var defaults: UserDefaults!
    private var now = Date(timeIntervalSince1970: 1_794_786_000)

    override func setUp() {
        super.setUp()
        let suite = "security-prompt-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }

    private func coordinator() -> SecurityPromptCoordinator {
        SecurityPromptCoordinator(now: { [unowned self] in now }, defaults: defaults)
    }

    private func moments(_ userID: String = "u1") -> SecurityPromptMoments {
        SecurityPromptMoments(userID: userID, defaults: defaults)
    }

    private final class Calls { var reads = 0; var snoozes = 0 }

    private func evaluate(
        _ coordinator: SecurityPromptCoordinator, userID: String = "u1", calls: Calls,
        prompt: Result<SecurityPrompt?, Error>, snooze: Result<Void, Error> = .success(())
    ) async {
        await coordinator.evaluate(userID: userID, readPrompt: {
            calls.reads += 1
            return try prompt.get()
        }, snooze: {
            calls.snoozes += 1
            try snooze.get()
        })
    }

    private static let no2FA = SecurityPrompt(show: true, reason: "no_2fa")
    private static let noCodes = SecurityPrompt(show: true, reason: "no_backup_codes")

    // MARK: Profil

    func testProfileReadsThePromptAsOptional() throws {
        func user(_ prompt: String?) throws -> AuthUser {
            let field = prompt.map { #","securityPrompt":\#($0)"# } ?? ""
            return try JSONDecoder().decode(AuthUser.self, from: Data(#"{"id":"u1","email":"a@b.fr","role":"user","avatarUrl":null,"bio":null\#(field)}"#.utf8))
        }
        let served = try user(#"{"show":true,"reason":"no_backup_codes","snoozedUntil":null}"#)
        XCTAssertEqual(served.securityPrompt, SecurityPrompt(show: true, reason: "no_backup_codes"))
        XCTAssertEqual(served.securityPrompt?.knownReason, .noBackupCodes)
        XCTAssertNil(try user(nil).securityPrompt, "ancienne API : pas de carte")
        XCTAssertNil(try user("null").securityPrompt)
        let unknown = try user(#"{"show":true,"reason":"no_email","snoozedUntil":null}"#)
        XCTAssertNil(unknown.securityPrompt?.knownReason, "raison inconnue : rien à montrer")
        let snoozed = try user(#"{"show":false,"reason":"no_2fa","snoozedUntil":"2026-12-16T00:00:00.000Z"}"#)
        XCTAssertEqual(snoozed.securityPrompt?.snoozedUntil, "2026-12-16T00:00:00.000Z")
        let garbage = try user(#""oui""#)
        XCTAssertEqual(garbage.securityPrompt?.show, false, "un champ mal formé ne casse pas le profil")
        XCTAssertNil(served.withConfirmedTwoFactor(enabled: true).securityPrompt, "calculée avec l’ancien état")
    }

    // MARK: Moments

    func testNothingShowsWithoutAMoment() async {
        let coordinator = coordinator(), calls = Calls()
        await evaluate(coordinator, calls: calls, prompt: .success(Self.no2FA))
        XCTAssertNil(coordinator.card)
        XCTAssertEqual(calls.reads, 0, "pas de lecture du profil sans moment")
    }

    func testAnArmedMomentShowsTheCardOnceADay() async {
        let coordinator = coordinator(), calls = Calls()
        moments().arm()
        await evaluate(coordinator, calls: calls, prompt: .success(Self.no2FA))
        XCTAssertEqual(coordinator.card, .init(userID: "u1", reason: .noTwoFactor))
        XCTAssertEqual(coordinator.card(for: "u1")?.reason, .noTwoFactor)
        XCTAssertNil(coordinator.card(for: "u2"), "jamais la carte d’un autre compte")
        XCTAssertFalse(moments().isArmed)
        XCTAssertEqual(moments().shownDay, SecurityPromptMoments.localDay(now))

        // Montrée : elle reste, sans relire le profil.
        moments().arm()
        await evaluate(coordinator, calls: calls, prompt: .success(Self.noCodes))
        XCTAssertEqual(coordinator.card?.reason, .noTwoFactor)
        XCTAssertEqual(calls.reads, 1)

        // Le bouton la retire ; un moment du même jour tombe sans lecture.
        coordinator.dismissForAction()
        XCTAssertNil(coordinator.card)
        await evaluate(coordinator, calls: calls, prompt: .success(Self.noCodes))
        XCTAssertNil(coordinator.card)
        XCTAssertEqual(calls.reads, 1)
        XCTAssertFalse(moments().isArmed, "le moment du jour déjà vu tombe")

        // Le lendemain, un nouveau moment la remontre.
        now = now.addingTimeInterval(24 * 3_600)
        moments().arm()
        await evaluate(coordinator, calls: calls, prompt: .success(Self.noCodes))
        XCTAssertEqual(coordinator.card?.reason, .noBackupCodes)
        XCTAssertEqual(calls.reads, 2)
    }

    func testAMomentWaitsForAReadableProfileAndFallsOnNothingToShow() async {
        let coordinator = coordinator(), calls = Calls()
        moments().arm()
        await evaluate(coordinator, calls: calls, prompt: .failure(APIError.transport("offline")))
        XCTAssertNil(coordinator.card)
        XCTAssertTrue(moments().isArmed, "profil illisible : le moment attend")
        XCTAssertNil(moments().shownDay)

        await evaluate(coordinator, calls: calls, prompt: .success(SecurityPrompt(show: false, reason: "no_2fa", snoozedUntil: "2026-12-16T00:00:00.000Z")))
        XCTAssertNil(coordinator.card)
        XCTAssertFalse(moments().isArmed)
        XCTAssertNil(moments().shownDay, "rien de montré : la journée n’est pas comptée")

        for prompt in [SecurityPrompt(show: true, reason: "no_email"), nil] {
            moments().arm()
            await evaluate(coordinator, calls: calls, prompt: .success(prompt))
            XCTAssertNil(coordinator.card)
            XCTAssertFalse(moments().isArmed)
            XCTAssertNil(moments().shownDay)
        }
    }

    // MARK: « Plus tard »

    func testLaterHidesAtOnceAndResendsUntilTheServerAnswers() async {
        let coordinator = coordinator(), calls = Calls()
        moments().arm()
        await evaluate(coordinator, calls: calls, prompt: .success(Self.no2FA))
        XCTAssertNotNil(coordinator.card)

        // Hors réseau : la carte part tout de suite, le report reste à envoyer.
        await coordinator.later(snooze: { calls.snoozes += 1; throw APIError.transport("offline") })
        XCTAssertNil(coordinator.card)
        XCTAssertTrue(moments().snoozePending)

        // Tant qu'il n'est pas parti, aucune carte, même avec un moment armé (le lendemain).
        now = now.addingTimeInterval(24 * 3_600)
        moments().arm()
        await evaluate(coordinator, calls: calls, prompt: .success(Self.no2FA), snooze: .failure(APIError.http(status: 503, code: nil, message: "", requestId: nil, retryAfter: nil)))
        XCTAssertNil(coordinator.card)
        XCTAssertTrue(moments().snoozePending)
        XCTAssertEqual(calls.reads, 1, "le report passe avant la lecture du profil")

        // Report reçu : la lecture suit dans la même évaluation.
        await evaluate(coordinator, calls: calls, prompt: .success(SecurityPrompt(show: false, reason: "no_2fa", snoozedUntil: "2026-12-17T00:00:00.000Z")))
        XCTAssertFalse(moments().snoozePending)
        XCTAssertEqual(calls.snoozes, 3)
        XCTAssertEqual(calls.reads, 2)
        XCTAssertNil(coordinator.card)
    }

    func testRefusedSnoozeIsNotResent() {
        func http(_ status: Int) -> Error { APIError.http(status: status, code: nil, message: "", requestId: nil, retryAfter: nil) }
        XCTAssertTrue(SecurityPromptCoordinator.dropsSnooze(after: http(401)))
        XCTAssertTrue(SecurityPromptCoordinator.dropsSnooze(after: http(404)))
        XCTAssertTrue(SecurityPromptCoordinator.dropsSnooze(after: APIError.missingAuthToken))
        XCTAssertFalse(SecurityPromptCoordinator.dropsSnooze(after: http(429)))
        XCTAssertFalse(SecurityPromptCoordinator.dropsSnooze(after: http(500)))
        XCTAssertFalse(SecurityPromptCoordinator.dropsSnooze(after: APIError.transport("offline")))
    }

    // MARK: Repères

    func testMomentsArePerAccountAndDaysAreLocal() {
        XCTAssertNil(SecurityPromptMoments(ownerScopeId: "guest:abc", defaults: defaults), "un invité n’a pas de carte")
        SecurityPromptMoments(ownerScopeId: "user:u1", defaults: defaults)?.arm()
        XCTAssertTrue(moments("u1").isArmed)
        XCTAssertFalse(moments("u2").isArmed)
        let paris = TimeZone(identifier: "Europe/Paris")!
        // 15/11 à 23:30 UTC : déjà le 16 à Paris.
        let late = Date(timeIntervalSince1970: 1_794_785_400)
        XCTAssertEqual(SecurityPromptMoments.localDay(late, timeZone: paris), "2026-11-16")
        XCTAssertEqual(SecurityPromptMoments.localDay(late, timeZone: TimeZone(identifier: "UTC")!), "2026-11-15")
    }
}
