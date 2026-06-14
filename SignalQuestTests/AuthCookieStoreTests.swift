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
}

