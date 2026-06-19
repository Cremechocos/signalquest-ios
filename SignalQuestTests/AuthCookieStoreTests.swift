import XCTest
@testable import SignalQuest

final class AuthCookieStoreTests: XCTestCase {
    func testParsesStoresAndClearsCookie() throws {
        let token = AuthCookieStore.parseAuthToken(from: "theme=dark; Path=/, auth_token=token-value; Path=/; HttpOnly")
        XCTAssertEqual(token, "token-value")

        let store = AuthCookieStore(tokenStore: InMemoryTokenStore())
        try store.store(token: "token-value")
        XCTAssertEqual(store.cookieHeader(), "auth_token=token-value")
        store.clear()
        XCTAssertNil(store.cookieHeader())
    }

    /// SEC-AUTH-02 : la purge des cookies au logout doit retirer auth_token du
    /// domaine signalquest.fr (et ses sous-domaines) SANS toucher aux cookies
    /// tiers ni à un domaine ressemblant mais distinct (evil-signalquest.fr.x).
    func testPurgeAuthCookiesRemovesAppDomainOnly() throws {
        let storage = HTTPCookieStorage.shared
        func cookie(_ domain: String, _ name: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: "v"])!
        }
        let app = cookie("signalquest.fr", "auth_token")
        let sub = cookie(".signalquest.fr", "session")
        let third = cookie("example.com", "keep")
        let lookalike = cookie("evil-signalquest.fr.attacker.com", "spoof")
        [app, sub, third, lookalike].forEach { storage.setCookie($0) }

        CredentialStore.purgeAuthCookies()

        let names = Set((storage.cookies ?? []).map(\.name))
        XCTAssertFalse(names.contains("auth_token"))
        XCTAssertFalse(names.contains("session"))
        XCTAssertTrue(names.contains("keep"))
        XCTAssertTrue(names.contains("spoof"))   // domaine ressemblant : conservé

        // Nettoyage des cookies de test résiduels.
        (storage.cookies ?? [])
            .filter { ["keep", "spoof"].contains($0.name) }
            .forEach { storage.deleteCookie($0) }
    }
}

