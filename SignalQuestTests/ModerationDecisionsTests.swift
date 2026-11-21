import XCTest
@testable import SignalQuest

/// MOD-1 sur iOS : les décisions de modération du compte, leur exposé des motifs
/// (DSA art. 17) et leur recours (art. 20), comme le serveur les sert
/// (`serializeDecision`, contrat moderation-decisions-v1 révision 1.2).
///
/// Avant ce lot, iOS n'avait aucun écran : le push `moderation_decision` ne portait
/// que `decisionId`, le routeur tombait dans son repli et rien ne s'ouvrait.
@MainActor
final class ModerationDecisionsTests: XCTestCase {

    /// Masquage automatique après trois signalements (G7, #1482) : la forme exacte
    /// de `serializeDecision`, avec les valeurs du test serveur.
    private let automatedPost = #"""
    {
      "id": "dec-1",
      "decidedAt": "2026-11-21T09:30:00.000Z",
      "target": { "type": "social_post", "id": "post-1", "createdAt": "2026-11-20T18:00:00.000Z",
                  "excerpt": "Publication de test G7", "thumbnailUrl": null },
      "action": "hidden",
      "accountRestriction": null,
      "until": null,
      "reason": { "code": "misinformation", "label": "Information inexacte", "text": null, "textLocale": null },
      "rule": { "id": "R5", "version": "1.0.1", "title": "Des informations exactes" },
      "automated": true,
      "appeal": { "possible": true, "deadline": "2027-05-21T09:30:00.000Z", "status": "none", "filedAt": null,
                  "decidedAt": null, "outcomeLabel": null, "outcomeText": null, "outcomeTextLocale": null }
    }
    """#

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.signalQuest.decode(T.self, from: Data(json.utf8))
    }

    func testAnAutomatedHidingReadsAsAnAutomatedDecisionWithItsRuleAndAppeal() throws {
        let decision = try decode(ModerationDecision.self, automatedPost)
        XCTAssertEqual(decision.id, "dec-1")
        XCTAssertTrue(decision.automated)
        XCTAssertEqual(decision.target.type, "social_post")
        XCTAssertEqual(decision.target.excerpt, "Publication de test G7")
        XCTAssertNil(decision.target.thumbnailPath)
        XCTAssertNil(decision.reason.text, "aucune précision : rien ne doit se lire comme la note d'un modérateur")
        XCTAssertTrue(decision.appeal.possible)
        XCTAssertNotNil(decision.appeal.deadline)

        XCTAssertEqual(ModerationDecisionText.action(decision.action), "Contenu masqué")
        XCTAssertEqual(ModerationDecisionText.target(decision.target.type), "Ta publication")
        XCTAssertEqual(ModerationDecisionText.decidedBy(automated: decision.automated), "Décidé automatiquement, sans examen humain")
        XCTAssertEqual(ModerationDecisionText.scope(decision), "Masqué pour tout le monde")
        XCTAssertEqual(ModerationDecisionText.rule(decision.rule), "R5 · Des informations exactes")
        let status = try XCTUnwrap(ModerationDecisionText.appealStatus(decision.appeal))
        XCTAssertTrue(status.hasPrefix("Tu peux contester jusqu’au "), status)
        XCTAssertNil(ModerationDecisionText.appealPill(decision.appeal))
    }

    /// Les cinq cibles d'un masquage automatique ont chacune leur libellé.
    func testTheFiveAutoHiddenTargetsHaveTheirOwnLabel() {
        let labels = ["social_post", "social_story", "site_comment", "room_message", "photo"].map(ModerationDecisionText.target)
        XCTAssertEqual(labels, ["Ta publication", "Ta story", "Ton message sur un site", "Ton message dans un salon", "Ta photo"])
        XCTAssertFalse(labels.contains(ModerationDecisionText.target("inconnu")))
    }

    /// Un état futur du contrat (une décision « levée », r2) ne casse ni la liste ni
    /// l'écran : libellés génériques, aucun recours proposé que le serveur refuserait.
    func testUnknownValuesFallBackWithoutDroppingTheList() throws {
        let json = #"""
        { "decisions": [
            \#(automatedPost),
            { "id": "dec-2", "decidedAt": "2026-11-01T08:00:00.000Z",
              "target": { "type": "future_target", "id": "x" }, "action": "lifted",
              "reason": { "code": "other", "label": "Non-respect des règles" }, "rule": null, "automated": false,
              "appeal": { "possible": false, "status": "lifted", "outcomeLabel": "Décision levée par l’équipe" } },
            { "decidedAt": "2026-10-01T08:00:00.000Z", "action": "removed" }
          ], "nextCursor": "abc", "unseenCount": -3 }
        """#
        let page = try decode(ModerationDecisionsPage.self, json)
        XCTAssertEqual(page.decisions.map(\.id), ["dec-1", "dec-2"], "une décision sans identifiant est ignorée, pas la page")
        XCTAssertEqual(page.nextCursor, "abc")
        XCTAssertEqual(page.unseenCount, 0)

        let future = page.decisions[1]
        XCTAssertEqual(ModerationDecisionText.action(future.action), "Décision de l’équipe")
        XCTAssertEqual(ModerationDecisionText.target(future.target.type), "Ton contenu")
        XCTAssertNil(ModerationDecisionText.scope(future), "aucune portée inventée")
        XCTAssertEqual(ModerationDecisionText.rule(future.rule), "Aucune règle citée")
        XCTAssertEqual(ModerationDecisionText.appealStatus(future.appeal), "Décision levée par l’équipe")
        XCTAssertNil(ModerationDecisionText.appealPill(future.appeal))
    }

    func testAnAccountRestrictionSaysUntilWhen() throws {
        let json = #"""
        { "id": "dec-3", "decidedAt": "2026-11-01T08:00:00.000Z", "target": { "type": "account", "id": "u" },
          "action": "account_suspended", "accountRestriction": { "type": "suspended", "until": null },
          "reason": { "code": "impersonation" }, "automated": false,
          "appeal": { "possible": false, "status": "pending", "filedAt": "2026-11-02T08:00:00.000Z" } }
        """#
        let decision = try decode(ModerationDecision.self, json)
        XCTAssertEqual(ModerationDecisionText.scope(decision), "Compte suspendu, sans date de fin")
        XCTAssertEqual(ModerationDecisionText.appealPill(decision.appeal), "Contestée")
        XCTAssertTrue(ModerationDecisionText.appealStatus(decision.appeal)?.hasPrefix("Contestation envoyée le ") == true)
        XCTAssertNil(decision.reason.label, "le motif sans libellé se dit « Motif non précisé » à l'écran")
    }

    /// Seule la route des miniatures MOD-1 est suivie : jamais une adresse arbitraire,
    /// qui partirait avec le cookie de session.
    func testOnlyTheModerationThumbnailRouteIsFollowed() {
        XCTAssertEqual(ModerationDecision.thumbnailPath("/api/me/moderation/decisions/dec-1/thumbnail"),
                       "/api/me/moderation/decisions/dec-1/thumbnail")
        for value in ["https://example.com/api/me/moderation/decisions/x/thumbnail",
                      "/api/me/moderation/decisions/../../user/thumbnail",
                      "/api/photos/1/thumbnail", "/api/me/moderation/decisions/x/thumbnail?redirect=1"] {
            XCTAssertNil(ModerationDecision.thumbnailPath(value), value)
        }
        XCTAssertEqual(ModerationDecisionsService.safeId("cmi8x2k0p0001abc_-9"), "cmi8x2k0p0001abc_-9")
        for id in ["a/../b", "", "dec 1", "dé1", String(repeating: "a", count: 65)] {
            XCTAssertNil(ModerationDecisionsService.safeId(id), id)
        }
    }

    // MARK: Requêtes

    private func service(locale: String = "fr", formal: Bool = false) -> ModerationDecisionsService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return ModerationDecisionsService(
            api: APIClient(config: .test, credentials: CredentialStore(tokenStore: InMemoryTokenStore()),
                           session: URLSession(configuration: config)),
            locale: { locale }, formal: { formal }
        )
    }

    private final class Box: @unchecked Sendable {
        var requests: [URLRequest] = []
        var bodies: [Data] = []
    }

    private func respond(_ box: Box, status: Int = 200, _ json: String) {
        MockURLProtocol.requestHandler = { request in
            box.requests.append(request)
            box.bodies.append(request.httpBodyData ?? Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (response, Data(json.utf8))
        }
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testTheListAsksForTheAppLanguageAndTheCursor() async throws {
        let box = Box()
        respond(box, #"{ "decisions": [\#(automatedPost)], "nextCursor": null, "unseenCount": 1 }"#)
        let page = try await service(locale: "en").page(cursor: "c-1", limit: 20)
        XCTAssertEqual(page.decisions.count, 1)
        XCTAssertEqual(page.unseenCount, 1)
        let request = try XCTUnwrap(box.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/me/moderation/decisions")
        XCTAssertEqual(query(request), ["locale": "en", "limit": "20", "cursor": "c-1"])
    }

    func testAnAppealPostsTheTrimmedMessageAndReturnsTheUpdatedDecision() async throws {
        let box = Box()
        let pending = automatedPost.replacingOccurrences(of: #""possible": true"#, with: #""possible": false"#)
            .replacingOccurrences(of: #""status": "none""#, with: #""status": "pending""#)
        respond(box, status: 201, #"{ "appeal": {}, "decision": \#(pending) }"#)
        let decision = try await service().appeal(decisionId: "dec-1", message: "  Ce n’était pas faux.  \n")
        XCTAssertEqual(decision.appeal.status, "pending")
        let request = try XCTUnwrap(box.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/me/moderation/decisions/dec-1/appeal")
        XCTAssertEqual(query(request)["locale"], "fr")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: box.bodies[0]) as? [String: String])
        XCTAssertEqual(body, ["message": "Ce n’était pas faux."])
    }

    func testAnAppealAlreadyFiledOrTooLateSaysSo() async throws {
        let box = Box()
        respond(box, status: 409, #"{ "code": "APPEAL_EXISTS", "message": "Un recours a déjà été déposé" }"#)
        do {
            _ = try await service().appeal(decisionId: "dec-1", message: "Un message assez long")
            XCTFail("409 attendu")
        } catch {
            XCTAssertEqual(ModerationDecisionText.appealError(error), "Une contestation est déjà en cours pour cette décision.")
        }
        respond(box, status: 422, #"{ "code": "APPEAL_CLOSED", "message": "Le délai de recours de 6 mois est dépassé" }"#)
        do {
            _ = try await service().appeal(decisionId: "dec-1", message: "Un message assez long")
            XCTFail("422 attendu")
        } catch {
            XCTAssertEqual(ModerationDecisionText.appealError(error), "Le délai pour contester est passé.")
        }
    }

    func testSeenMarksUpToTheNewestDecision() async throws {
        let box = Box()
        respond(box, #"{ "unseenCount": 0 }"#)
        let remaining = try await service().markSeen(upTo: "dec-1")
        XCTAssertEqual(remaining, 0)
        let request = try XCTUnwrap(box.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/me/moderation/decisions/seen")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: box.bodies[0]) as? [String: String])
        XCTAssertEqual(body, ["upTo": "dec-1"])
    }

    /// Les règles se lisent dans la version citée par la décision et dans le ton du compte (ADDR-1).
    func testRulesAreReadInTheCitedVersionAndTheChosenTone() async throws {
        let box = Box()
        respond(box, #"""
        { "version": "1.0.0", "effectiveDate": "2026-10-19", "locale": "fr", "fallback": false, "addressForm": "formal",
          "rules": [ { "id": "R5", "title": "Des informations exactes", "summary": "Pas de fausse identification.", "text": "Texte." } ],
          "updatedAt": "2026-10-19" }
        """#)
        let rules = try await service(formal: true).communityRules(version: "1.0.0")
        XCTAssertEqual(rules.version, "1.0.0")
        XCTAssertEqual(rules.rules.map(\.id), ["R5"])
        XCTAssertNotNil(rules.effectiveDate)
        let request = try XCTUnwrap(box.requests.first)
        XCTAssertEqual(request.url?.path, "/api/public/community-rules")
        XCTAssertEqual(query(request), ["locale": "fr", "addressForm": "formal", "version": "1.0.0"])
    }

    // MARK: Notifications

    func testTheDecisionPushOpensTheDecision() {
        let router = AppRouter()
        router.handle(type: "moderation_decision", conversationId: nil, postId: nil, decisionId: "dec-1")
        XCTAssertEqual(router.selectedTab, .profile)
        XCTAssertEqual(router.openModerationDecisionId, "dec-1")
        XCTAssertTrue(router.hasPendingContentRoute)

        let withoutId = AppRouter()
        withoutId.handle(type: "moderation_decision", conversationId: nil, postId: nil)
        XCTAssertEqual(withoutId.openModerationDecisionId, "", "sans identifiant : la liste des décisions")
    }

    /// L'avis des administrateurs (« Recours contre une décision ») ouvre la page d'administration.
    func testTheAdminAppealNoticeOpensTheAdminPage() {
        let router = AppRouter()
        router.handle(type: "moderation_appeal", conversationId: nil, postId: nil)
        XCTAssertNil(router.openModerationDecisionId)
        XCTAssertFalse(router.hasPendingContentRoute)
        let base = URL(string: "https://signalquest.fr")!
        XCTAssertEqual(NotificationsCenterView.adminWebURL(type: "moderation_appeal", link: "/admin/moderation", base: base)?.absoluteString,
                       "https://signalquest.fr/admin/moderation")
        XCTAssertEqual(NotificationsCenterView.title(for: "moderation_decision"), "Décision de modération")
    }
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
