import XCTest
@testable import SignalQuest

/// Plan 3, vague 2 : aperçu d'un lien dans une conversation non chiffrée, lu
/// par le serveur, avec le domaine réel d'arrivée plutôt que le nom que la
/// page se donne.
final class MessageLinkPreviewTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFirstWebLinkOfTheText() {
        XCTAssertEqual(
            MessageLinkPreview.firstLink(in: "Regarde https://signalquest.fr/carte puis http://exemple.org")?.absoluteString,
            "https://signalquest.fr/carte"
        )
        XCTAssertNil(MessageLinkPreview.firstLink(in: "Écris-moi à lea@signalquest.fr"), "Une adresse e-mail n'est pas un lien web")
        XCTAssertNil(MessageLinkPreview.firstLink(in: "Rien à voir ici"))
    }

    func testCardShowsWhereTheLinkReallyLeads() throws {
        let link = try XCTUnwrap(URL(string: "https://bit.ly/abc"))
        let redirected = LinkPreview(url: link.absoluteString, finalUrl: "https://www.exemple-piege.com/login",
                                     title: "Ta banque", description: nil, siteName: "Ta banque")
        XCTAssertEqual(MessageLinkPreview.domain(of: redirected, link: link), "exemple-piege.com",
                       "Le domaine réel, jamais le nom que la page se donne")
        let direct = LinkPreview(url: link.absoluteString, finalUrl: nil, title: "Lien", description: nil, siteName: nil)
        XCTAssertEqual(MessageLinkPreview.domain(of: direct, link: link), "bit.ly")
    }

    func testPreviewIsAskedToTheServerOncePerLink() async throws {
        var requests: [URL] = []
        MockURLProtocol.requestHandler = { request in
            requests.append(request.url!)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"""
            {"preview":{"url":"https://exemple.org/a","finalUrl":"https://exemple.org/a","title":"Titre","description":null,"image":"https://exemple.org/i.png","siteName":"Exemple"},"requestId":"r1"}
            """#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("link-preview-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let store = LinkPreviewStore()
        let link = try XCTUnwrap(URL(string: "https://exemple.org/a"))

        let first = await store.preview(for: link, api: api)
        let second = await store.preview(for: link, api: api)

        XCTAssertEqual(first?.title, "Titre")
        XCTAssertEqual(second, first)
        XCTAssertEqual(requests.count, 1, "Une URL n'est demandée qu'une fois")
        let query = URLComponents(url: try XCTUnwrap(requests.first), resolvingAgainstBaseURL: false)
        XCTAssertEqual(query?.path, "/api/social/og")
        XCTAssertEqual(query?.queryItems?.first { $0.name == "url" }?.value, "https://exemple.org/a")
    }
}
