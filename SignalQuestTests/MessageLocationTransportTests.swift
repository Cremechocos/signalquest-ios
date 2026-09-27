import XCTest
@testable import SignalQuest

@MainActor
final class MessageLocationTransportTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testExpiredLocationIsNotReplayedAfterServer503() async throws {
        let fixture = LocationRetryFixture()
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("synthetic-location-owner")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = fixture.respond
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = MessagesService(api: APIClient(config: .test, credentials: credentials, session: session))
        let conversation = MessageConversation(
            id: "synthetic-conversation", title: nil, isGroup: false, e2eeEnabled: false,
            groupPhotoUrl: nil, createdAt: nil, updatedAt: nil, lastMessageAt: nil,
            lastReadAt: nil, pinnedAt: nil, participants: [], lastMessage: nil
        )
        let observedAt = Date(timeIntervalSince1970: 1_790_000_000)

        do {
            _ = try await service.sendLocation(
                latitude: 48.8566, longitude: 2.3522, place: "Paris", accuracyMeters: 12.5,
                observedAt: observedAt, in: conversation,
                expectedSessionID: credentials.snapshot().sessionID,
                validateBeforeSend: { try fixture.validate() }
            )
            XCTFail("Une position périmée ne doit pas être rejouée")
        } catch {
            XCTAssertEqual(error as? APIError, .cancelled)
        }

        XCTAssertEqual(fixture.requestCount, 1, "Le 503 ne doit pas rejouer les coordonnées périmées")
        XCTAssertGreaterThanOrEqual(fixture.validationCount, 3,
                                    "L'admission doit être revérifiée après le 503")
        let body = try fixture.firstBody()
        XCTAssertEqual(body["kind"] as? String, "LOCATION")
        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        let location = try XCTUnwrap(metadata["location"] as? [String: Any])
        XCTAssertEqual(location["lat"] as? Double, 48.8566)
        XCTAssertEqual(location["lng"] as? Double, 2.3522)
        XCTAssertEqual(location["accuracyMeters"] as? Double, 12.5)
        let encodedTime = try XCTUnwrap(location["observedAt"] as? String)
        XCTAssertEqual(try XCTUnwrap(SQDateParsing.parse(encodedTime)).timeIntervalSince1970,
                       observedAt.timeIntervalSince1970, accuracy: 0.001)
    }
}

private final class LocationRetryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var validations = 0
    private var bodies: [Data] = []

    var requestCount: Int { lock.withLock { bodies.count } }
    var validationCount: Int { lock.withLock { validations } }

    func validate() throws {
        let isExpired = lock.withLock { () -> Bool in
            validations += 1
            return expired
        }
        if isExpired { throw APIError.cancelled }
    }

    func firstBody() throws -> [String: Any] {
        let data = try XCTUnwrap(lock.withLock { bodies.first })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func respond(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        guard url.path == "/api/messages/conversations/synthetic-conversation/messages" else {
            throw URLError(.unsupportedURL)
        }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        lock.withLock {
            bodies.append(data)
            expired = true
        }
        return (HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil,
                                headerFields: ["Retry-After": "0"])!,
                Data("{\"error\":\"synthetic-unavailable\"}".utf8))
    }
}
