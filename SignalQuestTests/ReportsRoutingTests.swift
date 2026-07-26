import XCTest
@testable import SignalQuest

/// Chaque cible de signalement doit partir sur l'endpoint qui la comprend, avec
/// le corps que son schéma zod attend.
///
/// Régression : `targetType` était une `String` libre et le signalement de photo
/// envoyait `"photo"` à `/api/social/reports`, dont le schéma n'accepte que
/// `post|comment|profile` — 400 systématique sur un contenu généré par les
/// utilisateurs, donc un flux de modération visiblement cassé (Guideline 1.2).
final class ReportsRoutingTests: XCTestCase {

    private var service: ReportsService!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        service = ReportsService(
            api: APIClient(
                config: .test,
                credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                session: URLSession(configuration: config)
            )
        )
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        service = nil
        super.tearDown()
    }

    /// Capture le chemin et le corps de la requête sortante.
    private func capture(
        _ body: @escaping () async throws -> Void
    ) async throws -> (path: String, json: [String: Any]) {
        let box = CaptureBox()
        MockURLProtocol.requestHandler = { request in
            box.path = request.url?.path ?? ""
            box.body = request.httpBodyData
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"success":true}"#.utf8))
        }
        try await body()
        let json = (try? JSONSerialization.jsonObject(with: box.body ?? Data())) as? [String: Any] ?? [:]
        return (box.path, json)
    }

    func testPhotoReportGoesToDedicatedEndpoint() async throws {
        let result = try await capture {
            try await self.service.report(.photo("photo-42"), reason: .spam, comment: "gênant")
        }
        XCTAssertEqual(result.path, "/api/photos/photo-42/report")
        XCTAssertEqual(result.json["reason"] as? String, "spam")
        XCTAssertEqual(result.json["description"] as? String, "gênant")
        XCTAssertNil(result.json["targetType"], "Le schéma photo n'accepte pas targetType")
        XCTAssertNil(result.json["targetId"], "L'identifiant est porté par l'URL")
    }

    func testPhotoCommentReportGoesToDedicatedEndpoint() async throws {
        let result = try await capture {
            try await self.service.report(.photoComment("c-7"), reason: .harassment, comment: nil)
        }
        XCTAssertEqual(result.path, "/api/photos/comments/c-7/report")
        XCTAssertEqual(result.json["reason"] as? String, "harassment")
        XCTAssertNil(result.json["description"], "Un commentaire vide ne doit pas être envoyé")
    }

    func testPhotoAppealGoesToAppealEndpoint() async throws {
        let result = try await capture {
            try await self.service.appealPhoto(id: "photo-9", reason: .other, comment: "erreur de modération")
        }
        XCTAssertEqual(result.path, "/api/photos/photo-9/appeal")
        XCTAssertEqual(result.json["description"] as? String, "erreur de modération")
    }

    /// Les cibles sociales gardent l'endpoint et le corps historiques.
    func testSocialTargetsKeepTheSharedEndpoint() async throws {
        let post = try await capture {
            try await self.service.report(.post("p-1"), reason: .misleading, comment: nil)
        }
        XCTAssertEqual(post.path, "/api/social/reports")
        XCTAssertEqual(post.json["targetType"] as? String, "post")
        XCTAssertEqual(post.json["targetId"] as? String, "p-1")

        let profile = try await capture {
            try await self.service.report(.profile("u-1"), reason: .privacy, comment: nil)
        }
        XCTAssertEqual(profile.path, "/api/social/reports")
        XCTAssertEqual(profile.json["targetType"] as? String, "profile",
                       "« user » côté UI doit devenir « profile » côté backend")

        let comment = try await capture {
            try await self.service.report(.comment("c-1"), reason: .illegal, comment: nil)
        }
        XCTAssertEqual(comment.json["targetType"] as? String, "comment")
    }

    /// Le schéma zod backend rejette toute raison hors de cet ensemble.
    func testReportReasonsMatchBackendEnum() {
        XCTAssertEqual(
            Set(ReportReason.allCases.map(\.rawValue)),
            ["spam", "harassment", "privacy", "illegal", "misleading", "other"]
        )
    }
}

/// Boîte de capture non isolée : `MockURLProtocol.requestHandler` est appelé
/// depuis la queue de l'URLSession.
private final class CaptureBox: @unchecked Sendable {
    var path: String = ""
    var body: Data?
}

private extension URLRequest {
    /// `URLProtocol` vide `httpBody` au profit d'un flux : il faut lire les deux.
    var httpBodyData: Data? {
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
