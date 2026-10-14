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

        // Accepté par le serveur depuis le 29/09 (SOC-12).
        let story = try await capture {
            try await self.service.report(.story("s-1"), reason: .harassment, comment: nil)
        }
        XCTAssertEqual(story.path, "/api/social/reports")
        XCTAssertEqual(story.json["targetType"] as? String, "story")
        XCTAssertEqual(story.json["targetId"] as? String, "s-1")
    }

    /// Motifs proposés pour un message : ceux du web (SOC-12).
    func testMessageReportReasonsMatchTheWeb() {
        XCTAssertEqual(ReportReason.messageReasons.map(\.rawValue), ["spam", "harassment", "illegal", "other"])
    }

    /// Le schéma zod backend rejette toute raison hors de cet ensemble.
    func testReportReasonsMatchBackendEnum() {
        XCTAssertEqual(
            Set(ReportReason.allCases.map(\.rawValue)),
            ["spam", "harassment", "privacy", "illegal", "misleading", "other"]
        )
    }
}

/// « Bugs et idées » parle à `/api/bugs`, comme le web et Android : mêmes
/// champs, mêmes limites, et un décodage qui ne perd pas un signalement.
final class BugReportsServiceTests: XCTestCase {

    private var service: BugReportsService!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        service = BugReportsService(
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

    private func respond(status: Int = 200, _ json: String, into box: BugCaptureBox) {
        MockURLProtocol.requestHandler = { request in
            box.request = request
            box.body = request.httpBodyData
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }

    private let device = BugReportDevice(model: "iPhone 17 Pro", osVersion: "iOS 26.1", appVersion: "1.0 (170)",
                                         build: "170", network: "Wi‑Fi", screenSize: "402x874")

    func testSubmissionSendsDeviceInTheBodyAndOnlyTheContextTheAuthorChose() async throws {
        let box = BugCaptureBox()
        respond(status: 201, #"{"id":"b-1","title":"Carte blanche","description":"d","category":"ui","severity":"high","status":"open","createdAt":"2026-10-13T08:00:00.000Z"}"#, into: box)
        let submissionID = UUID()
        let submission = BugReportSubmission(
            category: .ui, title: "  Carte blanche  ", description: "La carte reste blanche.", severity: .high,
            steps: "   ", expectedResult: "La carte s'affiche", images: [], device: device, speedtest: nil,
            location: BugReportContext.Location(latitude: 45.18764, longitude: 5.72449)
        )
        let report = try await service.submit(submission, submissionID: submissionID)

        XCTAssertEqual(report.id, "b-1")
        XCTAssertEqual(report.category, .ui)
        XCTAssertEqual(box.request?.httpMethod, "POST")
        XCTAssertEqual(box.request?.url?.path, "/api/bugs")
        XCTAssertEqual(box.request?.value(forHTTPHeaderField: "Idempotency-Key"), "bug-report-\(submissionID.uuidString)")
        let json = try XCTUnwrap(box.json)
        XCTAssertEqual(json["title"] as? String, "Carte blanche")
        XCTAssertEqual(json["category"] as? String, "ui")
        XCTAssertEqual(json["severity"] as? String, "high")
        XCTAssertEqual(json["deviceModel"] as? String, "iPhone 17 Pro")
        XCTAssertEqual(json["deviceBrand"] as? String, "Apple")
        XCTAssertEqual(json["osVersion"] as? String, "iOS 26.1")
        XCTAssertEqual(json["appVersion"] as? String, "1.0 (170)")
        XCTAssertEqual(json["expectedResult"] as? String, "La carte s'affiche")
        XCTAssertNil(json["steps"], "Un champ blanc n'est pas envoyé")
        XCTAssertNil(json["images"], "Sans capture, pas de tableau vide")
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual(context["platform"] as? String, "ios")
        XCTAssertEqual(context["build"] as? String, "170")
        XCTAssertNil(context["speedtest"], "Le dernier speedtest ne part que s'il est coché")
        let location = try XCTUnwrap(context["location"] as? [String: Any])
        XCTAssertEqual(location["latitude"] as? Double, 45.19)
        XCTAssertEqual(location["longitude"] as? Double, 5.72)
        XCTAssertEqual(location["approx"] as? Bool, true)
    }

    func testSubmissionIsClippedToTheServerLimits() {
        let submission = BugReportSubmission(
            category: .feature, title: String(repeating: "a", count: 250), description: String(repeating: "b", count: 6000),
            severity: .medium, steps: nil, expectedResult: nil, images: Array(repeating: "data:image/jpeg;base64,AA", count: 7),
            device: device, speedtest: nil, location: nil
        )
        XCTAssertEqual(submission.title.count, 200)
        XCTAssertEqual(submission.description.count, 5000)
        XCTAssertEqual(submission.images?.count, 5)
        XCTAssertEqual(submission.category, "feature")
        XCTAssertNil(submission.context.location)
    }

    func testMyReportsKeepsValidItemsAndToleratesUnknownValues() async throws {
        let box = BugCaptureBox()
        respond(#"""
        [
          {"id":"b-1","title":"Carte","description":"d","category":"ui","severity":"critical","status":"in_progress","adminResponse":"Merci","updatedAt":"2026-10-12T08:00:00.000Z"},
          {"title":"sans identifiant"},
          {"id":"b-2","title":"Idée","description":"d","category":"feature","status":"wont_fix","images":["https://cdn.example/a.jpg"]},
          {"id":"b-3","title":"Inconnu","category":"quantum","severity":"extreme","status":"archived"}
        ]
        """#, into: box)
        let reports = try await service.myReports()

        XCTAssertEqual(box.request?.url?.path, "/api/bugs")
        XCTAssertEqual(box.request?.url?.query, "myBugs=true")
        XCTAssertEqual(reports.map(\.id), ["b-1", "b-2", "b-3"])
        XCTAssertEqual(reports[0].status, .inProgress)
        XCTAssertEqual(reports[0].severity, .critical)
        XCTAssertNotNil(reports[0].updatedAt)
        XCTAssertTrue(reports[1].isIdea)
        XCTAssertEqual(reports[1].status, .wontFix)
        XCTAssertFalse(reports[1].status.acceptsReplies)
        XCTAssertEqual(reports[1].images.count, 1)
        XCTAssertEqual(reports[2].category, .other)
        XCTAssertEqual(reports[2].severity, .medium)
        XCTAssertEqual(reports[2].status, .open)
    }

    func testCommentsTellTheTeamApartAndRepliesCarryText() async throws {
        let box = BugCaptureBox()
        respond(#"""
        [{"id":"c-1","content":"Ça arrive en 5G ?","isAdmin":true,"user":{"id":"u-9","name":"Modo","role":"admin"},"createdAt":"2026-10-12T21:14:00.000Z"},
         {"id":"c-2","content":"Oui","isAdmin":false,"user":{"id":"u-1","name":"Alex","role":"user"}}]
        """#, into: box)
        let comments = try await service.comments(bugId: "b 1")
        XCTAssertEqual(box.request?.url?.absoluteString.hasSuffix("/api/bugs/b%201/comments"), true,
                       "L'identifiant est encodé une seule fois : \(box.request?.url?.absoluteString ?? "-")")
        XCTAssertEqual(comments.map(\.isAdmin), [true, false])

        respond(status: 201, #"{"id":"c-3","content":"Toujours là","isAdmin":false}"#, into: box)
        let reply = try await service.addComment(bugId: "b-1", content: "Toujours là", images: [])
        XCTAssertEqual(reply.id, "c-3")
        XCTAssertEqual(box.request?.httpMethod, "POST")
        XCTAssertEqual(box.json?["content"] as? String, "Toujours là")
        XCTAssertNil(box.json?["images"])
    }

    func testDeleteAndRepliesFollowTheServerRules() async throws {
        let box = BugCaptureBox()
        respond(#"{"success":true}"#, into: box)
        try await service.delete(bugId: "b-1")
        XCTAssertEqual(box.request?.httpMethod, "DELETE")
        XCTAssertEqual(box.request?.url?.path, "/api/bugs/b-1")

        XCTAssertTrue(BugStatus.resolved.acceptsReplies, "Une réponse rouvre un signalement résolu")
        XCTAssertFalse(BugStatus.closed.acceptsReplies)
        XCTAssertEqual(Set(BugCategory.allCases.map(\.rawValue)),
                       ["crash", "ui", "network", "performance", "feature", "data", "other"])
        XCTAssertFalse(BugCategory.bugKinds.contains(.feature))
    }

    func testTheServerAloneSaysWhetherACommentSpeaksForTheTeam() throws {
        func decode(_ json: String) throws -> BugComment {
            try JSONDecoder.signalQuest.decode(BugComment.self, from: Data(json.utf8))
        }
        // Un admin qui écrit sur son propre signalement depuis l'app reste l'auteur.
        let asAuthor = try decode(#"{"id":"c-1","content":"Précision","isAdmin":false,"user":{"id":"u-a","name":"Alexandre","role":"admin"}}"#)
        let fromAdmin = try decode(#"{"id":"c-2","content":"On regarde","isAdmin":true,"user":{"id":"u-a","name":"Alexandre","role":"admin"}}"#)
        XCTAssertFalse(asAuthor.isAdmin)
        XCTAssertTrue(fromAdmin.isAdmin)
        XCTAssertEqual(fromAdmin.user?.name, "Alexandre")
    }

    private func report(_ id: String, status: String = "open", reply: String? = nil, updated: String) throws -> BugReport {
        var json: [String: Any] = ["id": id, "title": "t", "description": "d", "category": "ui",
                                   "severity": "low", "status": status, "updatedAt": updated]
        if let reply { json["adminResponse"] = reply }
        return try JSONDecoder.signalQuest.decode(BugReport.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testProfileBadgeCountsOnlyTeamActivityNotYetSeen() throws {
        let suite = "bugs-seen-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = "user:u-1"
        let old = try report("b-1", status: "resolved", reply: "Corrigé", updated: "2026-10-01T08:00:00.000Z")
        let mine = try report("b-2", updated: "2026-10-02T08:00:00.000Z")
        // Première lecture du compte : point de départ, rien ne s'allume.
        XCTAssertEqual(BugReportsSeenStore.unseenCount(in: [old, mine], ownerScopeId: scope, defaults: defaults), 0)

        let answered = try report("b-2", status: "in_progress", reply: "On regarde", updated: "2026-10-03T08:00:00.000Z")
        let newOne = try report("b-3", status: "in_progress", updated: "2026-10-04T08:00:00.000Z")
        let untouched = try report("b-4", updated: "2026-10-05T08:00:00.000Z")
        XCTAssertEqual(BugReportsSeenStore.unseenCount(in: [old, answered, newOne, untouched],
                                                       ownerScopeId: scope, defaults: defaults), 2)
        BugReportsSeenStore.markSeen(answered, ownerScopeId: scope, defaults: defaults)
        XCTAssertEqual(BugReportsSeenStore.unseenCount(in: [old, answered, newOne, untouched],
                                                       ownerScopeId: scope, defaults: defaults), 1)
        XCTAssertEqual(BugReportsSeenStore.unseenCount(in: [newOne], ownerScopeId: "guest", defaults: defaults), 0)
    }

    func testOfflineReportIsSealedPerAccountAndSentOnceTheNetworkIsBack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bug-outbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = BugReportOutboxStore(rootURL: root, keyStore: InMemoryTokenStore())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let service = BugReportsService(
            api: APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                           session: URLSession(configuration: config)),
            outbox: outbox,
            currentUserId: { "u-1" }
        )
        let id = UUID()
        let submission = BugReportSubmission(
            category: .network, title: "Pas de 5G", description: "Seulement de la 4G ici.", severity: .medium,
            steps: nil, expectedResult: nil, images: [], device: device, speedtest: nil,
            location: BugReportContext.Location(latitude: 45.18764, longitude: 5.72449)
        )
        try await service.stage(submission, submissionID: id)
        try await service.stage(submission, submissionID: id)
        var pending = await service.pendingCount()
        XCTAssertEqual(pending, 1, "Un second appui garde un seul signalement")

        // Scellé : le titre ne se lit pas sur le disque, et un autre compte ne voit rien.
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "enc" }
        XCTAssertEqual(files.count, 1)
        XCTAssertNil(try Data(contentsOf: files[0]).range(of: Data("Pas de 5G".utf8)))
        let otherAccount = try await outbox.pending(userId: "u-2")
        XCTAssertTrue(otherAccount.isEmpty)
        let mine = try await outbox.pending(userId: "u-1")
        XCTAssertEqual(mine.first?.submission, submission)

        // Serveur indisponible : rien n'est perdu.
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!, Data())
        }
        await service.retryPending()
        pending = await service.pendingCount()
        XCTAssertEqual(pending, 1)

        let box = BugCaptureBox()
        respond(status: 201, #"{"id":"b-9","title":"Pas de 5G","description":"d","category":"network","severity":"medium","status":"open"}"#, into: box)
        await service.retryPending()
        pending = await service.pendingCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(box.request?.url?.path, "/api/bugs")
        XCTAssertEqual(box.request?.value(forHTTPHeaderField: "Idempotency-Key"), "bug-report-\(id.uuidString)")
        XCTAssertEqual(box.json?["title"] as? String, "Pas de 5G")
        let context = try XCTUnwrap(box.json?["context"] as? [String: Any])
        XCTAssertEqual((context["location"] as? [String: Any])?["latitude"] as? Double, 45.19)
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "File vide = fichier effacé")
    }
}

/// Espace Admin : `/api/admin/bugs`, aux formes servies par le site (lot 9a).
final class AdminBugsServiceTests: XCTestCase {

    private var service: AdminBugsService!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        service = AdminBugsService(
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

    private func respond(status: Int = 200, _ json: String, into box: BugCaptureBox) {
        MockURLProtocol.requestHandler = { request in
            box.request = request
            box.body = request.httpBodyData
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }

    func testListSendsTheSegmentAndReadsCountsAndTriageFields() async throws {
        let box = BugCaptureBox()
        respond(#"""
        {"success":true,"data":{"bugs":[
          {"id":"b-1","title":"Plante","description":"d","category":"crash","severity":"critical","status":"open","source":"ios",
           "user":{"id":"u-1","name":"Camille","email":"c@example.invalid","avatarUrl":null},
           "assignee":{"id":"a-1","name":"Alex","isMe":true},"commentCount":3,"similarCount":2,
           "fixRelease":{"id":"r-1","version":"1.0 (171)","platform":"ios","status":"planned"}},
          {"title":"sans identifiant"}
        ],"pagination":{"totalCount":31,"totalPages":2,"currentPage":1,"limit":30},
        "counts":{"triage":4,"in_progress":1,"resolved":9,"ideas":2,"all":16,"critical":1,"mine":1}}}
        """#, into: box)
        var filters = AdminBugFilters()
        filters.source = .android
        filters.onlyMine = true
        filters.onlyCritical = true
        filters.query = "  carte  "
        let page = try await service.list(filters, page: 1)

        let items = URLComponents(url: box.request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(box.request?.url?.path, "/api/admin/bugs")
        XCTAssertEqual(query["segment"], "triage", "Sans segment, le serveur renverrait chaque conversation entière")
        XCTAssertEqual(query["source"], "android")
        XCTAssertEqual(query["assignee"], "me")
        XCTAssertEqual(query["critical"], "1")
        XCTAssertEqual(query["q"], "carte")
        XCTAssertEqual(query["page"], "1")

        XCTAssertEqual(page.bugs.map(\.id), ["b-1"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.count(.triage), 4)
        XCTAssertEqual(page.count(.inProgress), 1)
        let bug = try XCTUnwrap(page.bugs.first)
        XCTAssertEqual(bug.report.severity, .critical)
        XCTAssertEqual(bug.sourceLabel, "iOS")
        XCTAssertEqual(bug.reporter?.displayName, "Camille")
        XCTAssertEqual(bug.assignee?.isMe, true)
        XCTAssertEqual(bug.commentCount, 3)
        XCTAssertEqual(bug.similarCount, 2)
        XCTAssertEqual(bug.fixReleaseVersion, "1.0 (171)")
    }

    func testDetailTellsInternalNotesFromPublicReplies() async throws {
        let box = BugCaptureBox()
        respond(#"""
        {"success":true,"data":{"bug":{"id":"b 1","title":"Plante","description":"d","category":"crash","status":"in_progress",
          "stackTrace":"0 SignalQuest main","build":"171","legacyAdminNotes":null,
          "comments":[
            {"id":"c-2","content":"Merci","internal":false,"isAdmin":true,"createdAt":"2026-10-14T08:30:00.000Z","author":{"id":"a-1","name":"Alex","handle":"alex"}},
            {"id":"c-1","content":"Reproduit","internal":true,"isAdmin":true,"createdAt":"2026-10-14T08:10:00.000Z","author":{"id":"a-1","name":"Alex","handle":"alex"}},
            {"id":"c-3","content":"Toujours là","internal":false,"isAdmin":false,"createdAt":"2026-10-14T09:00:00.000Z","author":null,"authorName":"Camille"}
          ]},
          "assignees":[{"id":"a-1","name":"Alex","isMe":true},{"id":"a-2","name":null,"isMe":false}]}}
        """#, into: box)
        let detail = try await service.detail(id: "b 1")

        XCTAssertEqual(box.request?.url?.absoluteString.hasSuffix("/api/admin/bugs/b%201"), true,
                       "L'identifiant est encodé une seule fois : \(box.request?.url?.absoluteString ?? "-")")
        XCTAssertEqual(detail.comments.map(\.id), ["c-1", "c-2", "c-3"], "Discussion dans l'ordre du temps")
        XCTAssertEqual(detail.comments.map(\.isInternal), [true, false, false])
        XCTAssertEqual(detail.comments.map(\.comment.isAdmin), [true, true, false])
        XCTAssertEqual(detail.comments.last?.authorName, "Camille")
        XCTAssertEqual(detail.bug.stackTrace, "0 SignalQuest main")
        XCTAssertEqual(detail.bug.build, "171")
        XCTAssertEqual(detail.assignees.map(\.isMe), [true, false])
        XCTAssertEqual(detail.assignees.last?.displayName, String(localized: "Compte sans nom"))
    }

    func testPatchSendsOnlyWhatChangedAndCanUnassign() async throws {
        let box = BugCaptureBox()
        respond(#"{"success":true,"data":{"id":"b-1"}}"#, into: box)
        try await service.update(id: "b-1", AdminBugPatch(status: .inProgress, assignment: .me))
        XCTAssertEqual(box.request?.httpMethod, "PATCH")
        XCTAssertEqual(box.request?.url?.path, "/api/admin/bugs/b-1")
        XCTAssertEqual(box.json?["status"] as? String, "in_progress")
        XCTAssertEqual(box.json?["assigneeId"] as? String, "me")
        XCTAssertEqual(box.json?.count, 2)

        try await service.update(id: "b-1", AdminBugPatch(assignment: .nobody))
        XCTAssertEqual(box.json?.count, 1)
        XCTAssertTrue(box.json?["assigneeId"] is NSNull, "Désassigner envoie null, pas l'absence du champ")

        try await service.update(id: "b-1", AdminBugPatch(severity: .low, fixVersion: "1.0 (171)", adminResponse: "Corrigé"))
        XCTAssertEqual(box.json?["severity"] as? String, "low")
        XCTAssertEqual(box.json?["fixVersion"] as? String, "1.0 (171)")
        XCTAssertEqual(box.json?["adminResponse"] as? String, "Corrigé")
    }

    func testCommentSaysWhetherItIsInternal() async throws {
        let box = BugCaptureBox()
        respond(status: 201, #"{"success":true,"data":{"id":"c-9"}}"#, into: box)
        try await service.comment(id: "b-1", content: "Note", isInternal: true)
        XCTAssertEqual(box.request?.httpMethod, "POST")
        XCTAssertEqual(box.request?.url?.path, "/api/admin/bugs/b-1")
        XCTAssertEqual(box.json?["internal"] as? Bool, true, "Sans ce champ, le serveur publie la note au signaleur")
        XCTAssertEqual(box.json?["content"] as? String, "Note")

        try await service.comment(id: "b-1", content: "Réponse", isInternal: false)
        XCTAssertEqual(box.json?["internal"] as? Bool, false)
    }

    func testForbiddenAccountGetsAnError() async {
        let box = BugCaptureBox()
        respond(status: 403, #"{"error":"Accès administrateur requis"}"#, into: box)
        do {
            _ = try await service.list(AdminBugFilters(), page: 1)
            XCTFail("Un compte qui n'est pas administrateur ne doit rien lire")
        } catch {}
    }
}

private final class BugCaptureBox: @unchecked Sendable {
    var request: URLRequest?
    var body: Data?
    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] }
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
