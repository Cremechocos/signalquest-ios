import XCTest
@testable import SignalQuest

final class PasswordResetLinkTests: XCTestCase {
    private let origin = URL(string: "https://app.example.invalid")!
    private let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    func testEmailLinkOpensAResetRequestWithoutExposingItsSecretInDescriptions() throws {
        let result = PasswordResetLink.parse(URL(string: "https://app.example.invalid/reset-password?token=\(token)")!, origin: origin)
        guard case .request(let request) = result else { return XCTFail("The actual email link must be recognized") }
        XCTAssertEqual(request.token, token)
        XCTAssertFalse(String(describing: request).contains(token))
        XCTAssertFalse(String(reflecting: request).contains(token))
    }

    func testOtherOriginsSchemesAndPathsCannotProvideAResetSecret() {
        for value in ["http://app.example.invalid/reset-password?token=x", "https://attacker.invalid/reset-password?token=x",
                      "https://app.example.invalid.attacker.invalid/reset-password?token=x", "https://app.example.invalid:444/reset-password?token=x",
                      "https://user:password@app.example.invalid/reset-password?token=x", "https://app.example.invalid/profile?token=x"] {
            guard case .unrelated = PasswordResetLink.parse(URL(string: value)!, origin: origin) else {
                XCTFail("A foreign or credentialed URL is not a trusted recovery link: \(value)"); continue
            }
        }
    }

    func testRecognizedButMalformedLinksProduceAnInvalidLinkState() {
        for suffix in ["", "?token=", "?token=a&token=b", "?token=a&extra=value", "?token=a#fragment", "?token=%0Asecret", "?token=" + String(repeating: "x", count: 2049)] {
            guard case .invalid = PasswordResetLink.parse(URL(string: "https://app.example.invalid/reset-password" + suffix)!, origin: origin) else {
                XCTFail("A malformed recovery link needs explicit feedback"); continue
            }
        }
    }

    func testEncodedOpaqueTokenIsDecodedOnce() {
        let result = PasswordResetLink.parse(URL(string: "https://app.example.invalid/reset-password?token=opaque%2Bvalue%252F")!, origin: origin)
        guard case .request(let request) = result else { return XCTFail("Opaque token must be preserved") }
        XCTAssertEqual(request.token, "opaque+value%2F")
    }
}
