import XCTest
@testable import SignalQuest

/// Le backend n'écrit `acceptedTermsVersion` / `acceptedTermsAt` QUE si
/// `acceptedTerms` est présent dans le corps de l'inscription. Il ne l'était
/// pas : aucun compte créé depuis iOS ne portait de trace de consentement,
/// alors que la case était bien affichée et bloquait le bouton de création.
///
/// C'est une exigence RGPD (preuve du consentement) et un attendu de la revue
/// App Store sur la guideline EULA.
final class SignupConsentTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeService() -> (AuthService, BodyBox) {
        let box = BodyBox()
        MockURLProtocol.requestHandler = { request in
            box.path = request.url?.path ?? ""
            box.body = request.sq_signupBody
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"user":null}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(
            config: .test,
            credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
            session: URLSession(configuration: configuration)
        )
        return (AuthService(api: api), box)
    }

    func testSignupTransmitsConsent() async throws {
        let (service, box) = makeService()
        _ = try? await service.signup(
            email: "a@b.fr", password: "motdepasse", name: "Alex", acceptedTerms: true
        )
        XCTAssertEqual(box.path, "/api/auth/signup")
        let json = try XCTUnwrap((try? JSONSerialization.jsonObject(with: box.body ?? Data())) as? [String: Any])
        XCTAssertEqual(json["acceptedTerms"] as? Bool, true,
                       "Sans ce champ, le backend n'enregistre aucune preuve de consentement")
        XCTAssertEqual(json["email"] as? String, "a@b.fr")
        XCTAssertEqual(json["name"] as? String, "Alex")
    }

    /// La valeur transmise est la valeur RÉELLE, pas un `true` littéral : un
    /// contournement de la validation d'UI ne doit pas enregistrer un
    /// consentement qui n'a pas eu lieu.
    func testSignupTransmitsRefusalFaithfully() async throws {
        let (service, box) = makeService()
        _ = try? await service.signup(
            email: "a@b.fr", password: "motdepasse", name: "Alex", acceptedTerms: false
        )
        let json = try XCTUnwrap((try? JSONSerialization.jsonObject(with: box.body ?? Data())) as? [String: Any])
        XCTAssertEqual(json["acceptedTerms"] as? Bool, false)
    }

    /// Le champ doit être encodé même s'il est faux — `nil`/absent est
    /// précisément ce qui rendait le consentement invisible côté serveur.
    func testEncodedRequestAlwaysCarriesTheKey() throws {
        for accepted in [true, false] {
            let data = try JSONEncoder.signalQuest.encode(
                SignupRequest(email: "a@b.fr", password: "x", name: "A", acceptedTerms: accepted)
            )
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(json["acceptedTerms"], "La clé doit toujours être présente")
            XCTAssertEqual(json["acceptedTerms"] as? Bool, accepted)
        }
    }
}

private final class BodyBox: @unchecked Sendable {
    var path = ""
    var body: Data?
}

private extension URLRequest {
    var sq_signupBody: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
