import XCTest
@testable import SignalQuest

/// Plan 3, vague 2 : mentions dans un groupe et médias d'une conversation.
final class ConversationMentionsAndMediaTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testMentionMatchesTheStartOfTheHandleOrTheName() {
        let lea = MentionCandidate(id: "u2", name: "Léa Martin", handle: "lmartin", avatarUrl: nil)
        XCTAssertTrue(lea.matches("lm"))
        XCTAssertTrue(lea.matches("LE"), "Majuscules et accents ne comptent pas")
        XCTAssertFalse(lea.matches("martin"), "Le début seulement, pas le milieu")
        XCTAssertEqual(lea.displayName, "Léa Martin")
        XCTAssertEqual(MentionCandidate(id: "u3", name: "", handle: "nora", avatarUrl: nil).displayName, "@nora")
    }

    func testMentionSuggestionsAskForFriendsAndDropAccountsWithoutAHandle() async throws {
        var query: [String: String] = [:]
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/users/mention-suggestions")
            for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                query[item.name] = item.value
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"""
            {"users":[
              {"id":"u1","name":"Camille","handle":"camille","avatarUrl":null},
              {"id":"u2","name":"Sans pseudo","handle":null,"avatarUrl":"https://cdn.example/a.png"},
              {"id":"u3","name":"Carla","handle":"carla","avatarUrl":"https://cdn.example/c.png"}
            ]}
            """#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("mention-access-token")
        let api = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))

        let found = try await MessagesService(api: api).mentionSuggestions(prefix: "ca")

        XCTAssertEqual(found.map(\.handle), ["camille", "carla"])
        XCTAssertEqual(found.last?.avatarUrl?.absoluteString, "https://cdn.example/c.png")
        XCTAssertEqual(query["q"], "ca")
        XCTAssertEqual(query["friendsOnly"], "1", "Seuls les amis reçoivent la notification d'une mention")
        XCTAssertEqual(query["limit"], "10")
    }

    func testMediaGalleryTellsPhotosFromFiles() throws {
        let decoder = JSONDecoder()
        func attachment(_ json: String) throws -> MessageAttachment {
            try decoder.decode(MessageAttachment.self, from: Data(json.utf8))
        }
        XCTAssertTrue(ConversationMediaView.isImage(try attachment(#"{"kind":"IMAGE"}"#)))
        XCTAssertTrue(ConversationMediaView.isImage(try attachment(#"{"kind":"FILE","contentType":"image/heic"}"#)))
        XCTAssertFalse(ConversationMediaView.isImage(try attachment(#"{"kind":"FILE","contentType":"application/pdf"}"#)))
        XCTAssertFalse(ConversationMediaView.isImage(try attachment(#"{"kind":"AUDIO","contentType":"audio/mp4"}"#)))
    }
}
