import XCTest
@testable import SignalQuest

/// Identité membre v1, point 2 : l'écran « Ton nom d'utilisateur » (garder ou changer, nom
/// affiché facultatif) et son effet sur la session.
@MainActor
final class UsernameConfirmationTests: XCTestCase {
    private func user(_ json: String) throws -> AuthUser {
        try JSONDecoder().decode(AuthUser.self, from: Data(json.utf8))
    }

    private func body(_ patch: UserProfilePatch) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
    }

    func testDueUntilConfirmedAndAlwaysWithoutAUsername() throws {
        XCTAssertTrue(try user(#"{"id":"u1","handle":"alex38","handleConfirmedAt":null}"#).needsHandleConfirmation)
        XCTAssertTrue(try user(#"{"id":"u1","handle":"alex38"}"#).needsHandleConfirmation, "Ancien cache sans le champ")
        XCTAssertTrue(try user(#"{"id":"u1","handle":null,"handleConfirmedAt":"2026-11-13T10:00:00.000Z"}"#)
            .needsHandleConfirmation)
        XCTAssertFalse(try user(#"{"id":"u1","handle":"alex38","handleConfirmedAt":"2026-11-13T10:00:00.000Z"}"#)
            .needsHandleConfirmation)
    }

    func testKeepingSendsConfirmHandleAndOnlyAChangedName() throws {
        let kept = try body(UsernameConfirmationView.patch(handle: nil, displayName: " Alexandre G. ", previousName: "Alexandre G."))
        XCTAssertEqual(kept["confirmHandle"] as? Bool, true)
        XCTAssertNil(kept["handle"])
        XCTAssertNil(kept["name"], "Nom inchangé : non envoyé")

        let named = try body(UsernameConfirmationView.patch(handle: nil, displayName: "Camille", previousName: nil))
        XCTAssertEqual(named["name"] as? String, "Camille")

        let cleared = try body(UsernameConfirmationView.patch(handle: nil, displayName: "   ", previousName: "Ancien"))
        XCTAssertEqual(cleared["name"] as? String, "", "Vidé : `\"\"`, que le serveur enregistre à null")
    }

    func testChangingSendsTheNewUsernameWithoutConfirmHandle() throws {
        let changed = try body(UsernameConfirmationView.patch(handle: "alex-g", displayName: "", previousName: nil))
        XCTAssertEqual(changed["handle"] as? String, "alex-g")
        XCTAssertNil(changed["confirmHandle"], "Choisir un nom remplit déjà handleConfirmedAt")
        XCTAssertNil(changed["name"])
    }

    func testProfileResponseUpdatesTheIdentityButKeepsTheAccountState() throws {
        let current = AuthUser.mock.withConfirmedTwoFactor(enabled: true)
        let response = try user(#"{"id":"\#(current.id)","name":null,"handle":"alex-g","handleConfirmedAt":"2026-11-13T10:00:00.000Z"}"#)
        let merged = current.withIdentity(of: response)
        XCTAssertEqual(merged.handle, "alex-g")
        XCTAssertNil(merged.name)
        XCTAssertFalse(merged.needsHandleConfirmation)
        XCTAssertEqual(merged.twoFactorEnabled, true, "La réponse du profil ne porte pas la 2FA")
        XCTAssertEqual(merged.email, current.email)
    }

    func testSessionShowsTheScreenOnlyAfterAServerReadAndHidesItOnceSaved() async throws {
        let unconfirmed = try user(#"{"id":"\#(AuthUser.mock.id)","email":"synthetic@example.invalid","handle":"alex38"}"#)
        let mock = MockAuthService()
        mock.storedCredentials = true
        mock.cacheUser(unconfirmed)
        mock.meResult = .failure(APIError.transport("offline"))
        let session = AuthSessionViewModel(service: mock)
        await session.bootstrap()
        for _ in 0..<100 where mock.meCallCount == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(session.serverProfileUserID, "Hors ligne, sur le seul cache : pas d'écran bloquant")

        let confirmed = try user(#"{"id":"\#(AuthUser.mock.id)","handle":"alex38","handleConfirmedAt":"2026-11-13T10:00:00.000Z"}"#)
        session.applyProfileIdentity(confirmed)
        XCTAssertEqual(session.serverProfileUserID, AuthUser.mock.id)
        guard case .authenticated(let shown) = session.state else { return XCTFail("Session perdue") }
        XCTAssertFalse(shown.needsHandleConfirmation)
        XCTAssertEqual(shown.email, "synthetic@example.invalid")
        XCTAssertEqual(mock.cachedUser()?.handleConfirmedAt, "2026-11-13T10:00:00.000Z")

        session.applyProfileIdentity(try user(#"{"id":"someone-else","handle":"x"}"#))
        guard case .authenticated(let still) = session.state else { return XCTFail("Session perdue") }
        XCTAssertEqual(still.id, AuthUser.mock.id, "Le profil d'un autre compte n'est jamais installé")
    }
}
