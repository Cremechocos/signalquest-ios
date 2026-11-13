import Foundation
import XCTest
@testable import SignalQuest

/// DISPUTED-SITE r1 : le relevé `radio` que le serveur compare, le contrôle avant le formulaire,
/// la contestation (`disputedSiteId`) et l'envoi en attente « à revoir ».
final class CustomSiteDisputeTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func cell(id: String, operatorKey: String, enb: String?, observations: Int, mcc: Int = 208, mnc: Int = 1) throws -> AndroidCommunitySiteMarker {
        var fields = ["\"id\": \"\(id)\"", "\"lat\": 45.19", "\"lng\": 5.72", "\"radioNodeType\": \"LTE\"",
                      "\"operatorKey\": \"\(operatorKey)\"", "\"observationCount\": \(observations)",
                      "\"mcc\": \(mcc)", "\"mnc\": \(mnc)", "\"pci\": 12", "\"cellId\": \"20890113\""]
        if let enb { fields.append("\"enb\": \"\(enb)\"") }
        return try JSONDecoder.signalQuest.decode(AndroidCommunitySiteMarker.self,
                                                  from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    private func decodeCheck(_ json: String) throws -> CustomSiteRadioCheck {
        try JSONDecoder.signalQuest.decode(CustomSiteRadioCheck.self, from: Data(json.utf8))
    }

    func testTheDraftCarriesTheMostObservedCellWithANodeAsRadio() throws {
        let cells = [
            try cell(id: "a", operatorKey: "ORANGE", enb: "81234", observations: 4),
            try cell(id: "b", operatorKey: "SFR", enb: "50211", observations: 40),
            try cell(id: "c", operatorKey: "FREE", enb: nil, observations: 90),
        ]
        let draft = CustomSiteDraft.fromObservedCells(cells, latitude: 45.19, longitude: 5.72, name: "Pylône", type: "PYLONE")
        let radio = try XCTUnwrap(draft.radio)
        XCTAssertEqual(radio.enb, "50211", "La cellule sans nœud ne compte pas, même plus observée")
        XCTAssertEqual(radio.mobileOperator, "SFR")
        XCTAssertEqual(radio.mcc, 208)
        XCTAssertEqual(radio.nodeLabel, "eNB 50211")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        let sent = try XCTUnwrap(object["radio"] as? [String: Any])
        XCTAssertEqual(sent["enb"] as? String, "50211")
        XCTAssertEqual(sent["mobileOperator"] as? String, "SFR")
        XCTAssertNil(object["disputedSiteId"], "Sans contestation, la clé n'est pas envoyée")

        XCTAssertNil(CustomSiteDraft.fromObservedCells([try cell(id: "d", operatorKey: "FREE", enb: nil, observations: 3)],
                                                       latitude: 45, longitude: 5, name: "Sans nœud", type: "PYLONE").radio)
    }

    func testCheckQueryReadsNodeCellOperatorAndMcc() {
        let radio = CustomSiteRadioSnapshot(enb: "81234", cellId: "20797442", mcc: 208, mnc: 1, mobileOperator: "ORANGE")
        XCTAssertEqual(CustomSitesService.checkQuery(radio).map { "\($0.name)=\($0.value ?? "")" },
                       ["enb=81234", "cellId=20797442", "operator=ORANGE", "mcc=208"])
    }

    func testCheckDecodesTheCurrentSiteAndBlocksOnlyAConfirmedNode() throws {
        let custom = try decodeCheck("""
        {"exists":true,"source":"custom","anfrSiteId":null,"registryMarket":null,"customSiteId":"cm1site",
         "customSiteName":"Pylône du stade","communityCandidateId":null,"identificationStatus":"identified",
         "currentSite":{"siteId":"cm1site","kind":"custom","ownedByRequester":false}}
        """)
        XCTAssertTrue(custom.blocksCreation)
        XCTAssertEqual(custom.linkedSiteId, "cm1site")
        XCTAssertEqual(custom.currentKind, .custom)
        XCTAssertEqual(custom.siteName, "Pylône du stade")

        let hypothesis = try decodeCheck(#"{"exists":true,"source":"anfr","anfrSiteId":"574340","identificationStatus":"hypothesis","currentSite":null}"#)
        XCTAssertFalse(hypothesis.blocksCreation, "Une hypothèse de l'algorithme laisse créer le site")
        XCTAssertEqual(hypothesis.linkedSiteId, "574340", "Sans currentSite, la Validation d'abord")
        XCTAssertEqual(hypothesis.currentKind, .official)
        XCTAssertNil(hypothesis.siteName, "Un site officiel n'a pas de nom de membre")

        let ised = try decodeCheck(#"{"exists":true,"source":"registry","registryMarket":"CA","anfrSiteId":"ab12","identificationStatus":"identified","currentSite":{"siteId":"ab12","kind":"official","ownedByRequester":false}}"#)
        XCTAssertEqual(CustomSiteAlreadyLinked(check: ised, radio: CustomSiteRadioSnapshot(enb: "1"), operatorLabel: nil).sourceLabel,
                       String(localized: "données officielles ISED"))

        let degraded = try decodeCheck(#"{"exists":false,"source":null,"degraded":true}"#)
        XCTAssertFalse(degraded.blocksCreation)
        XCTAssertNil(degraded.linkedSiteId)
    }

    func testADisputeNeverTargetsTheMembersOwnSiteAndFollowsTheSameNodeOnly() throws {
        let radio = CustomSiteRadioSnapshot(enb: "81234", mcc: 208, mnc: 1, mobileOperator: "ORANGE")
        let own = try decodeCheck(#"{"exists":true,"source":"custom","customSiteId":"mine","identificationStatus":"identified","currentSite":{"siteId":"mine","kind":"custom","ownedByRequester":true}}"#)
        XCTAssertNil(CustomSiteDispute(check: own, radio: radio), "Le serveur refuserait : DISPUTE_OWN_SITE")
        XCTAssertNil(CustomSiteDispute(check: own, radio: CustomSiteRadioSnapshot(cellId: "1")))

        let other = try decodeCheck(#"{"exists":true,"source":"custom","customSiteId":"cm1","customSiteName":"Château d'eau","identificationStatus":"identified","currentSite":{"siteId":"cm1","kind":"custom","ownedByRequester":false}}"#)
        let dispute = try XCTUnwrap(CustomSiteDispute(check: other, radio: radio))
        XCTAssertEqual(dispute.siteId, "cm1")
        XCTAssertTrue(dispute.applies(to: radio, check: other))
        var otherNode = radio
        otherNode.enb = "81235"
        XCTAssertFalse(dispute.applies(to: otherNode, check: other))
        let moved = try decodeCheck(#"{"exists":true,"source":"custom","customSiteId":"cm2","identificationStatus":"identified","currentSite":{"siteId":"cm2","kind":"custom","ownedByRequester":false}}"#)
        XCTAssertFalse(dispute.applies(to: radio, check: moved), "Le serveur désigne un autre site : la feuille revient")
    }

    /// Le rejeu d'un site en file trouve son nœud rattaché entre-temps : l'envoi reste, « à revoir »,
    /// et n'est plus rejoué ; « Créer quand même » repart avec un nouvel identifiant et `disputedSiteId`.
    func testReplayRefusedBecauseTheNodeFoundASiteWaitsForReviewThenCreateAnywayDisputesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CustomSiteDisputeTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = CustomSiteOutboxStore(rootURL: root, keyStore: InMemoryTokenStore())
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        try credentials.setAccessToken("test-token")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(config: .test, credentials: credentials, session: URLSession(configuration: configuration))
        let bodies = BodyLog()
        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(request.disputeBodyData)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            bodies.append(json)
            let refused = json["disputedSiteId"] == nil
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: refused ? 409 : 200, httpVersion: nil, headerFields: nil)!
            let data = refused
                ? Data(#"{"error":"Cette cellule est déjà rattachée au site \"Château d'eau\".","code":"RADIO_ALREADY_KNOWN","currentSite":{"siteId":"cm1","kind":"custom","ownedByRequester":false}}"#.utf8)
                : Data(#"{"site":{"id":"cm-new","slug":"pylone"}}"#.utf8)
            return (response, data)
        }
        let check = CustomSiteRadioCheck(exists: true, source: "custom", customSiteId: "cm1", customSiteName: "Château d'eau",
                                         identificationStatus: "identified",
                                         currentSite: CustomSiteCurrentSite(siteId: "cm1", kind: .custom, ownedByRequester: false))
        let service = CustomSitesService(api: client, currentUserId: { "owner@example.test" }, outbox: store,
                                         checkNode: { _ in check })
        var draft = CustomSiteDraft.fromObservedCells([try cell(id: "a", operatorKey: "ORANGE", enb: "81234", observations: 4)],
                                                      latitude: 45.19, longitude: 5.72, name: "Pylône du parc", type: "PYLONE")
        draft = draft.normalized()
        let staged = try await store.stage(userId: "owner@example.test", draft: draft)

        await service.retryPending()
        let reviews = await service.pendingReviews()
        XCTAssertEqual(reviews.map(\.requestId), [staged.requestId], "Le site n'est ni envoyé ni perdu")
        XCTAssertEqual(reviews.first?.check.linkedSiteId, "cm1")
        XCTAssertEqual(reviews.first?.name, "Pylône du parc")

        await service.retryPending()
        XCTAssertEqual(bodies.count, 1, "Un envoi à revoir n'est plus rejoué")

        let review = try XCTUnwrap(reviews.first)
        let result = try await service.createAnyway(review)
        XCTAssertFalse(result.isPending)
        let sent = try XCTUnwrap(bodies.last)
        XCTAssertEqual(sent["disputedSiteId"] as? String, "cm1")
        XCTAssertNotEqual(sent["clientRequestId"] as? String, staged.requestId, "Créer quand même = nouvelle demande")
        XCTAssertEqual((sent["radio"] as? [String: Any])?["enb"] as? String, "81234")
        let remaining = try await store.pending(userId: "owner@example.test")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAbandonRemovesTheReviewedSite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CustomSiteDisputeTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = CustomSiteOutboxStore(rootURL: root, keyStore: InMemoryTokenStore())
        let draft = CustomSiteDraft.fromObservedCells([try cell(id: "a", operatorKey: "ORANGE", enb: "81234", observations: 4)],
                                                      latitude: 45.19, longitude: 5.72, name: "Pylône du parc", type: "PYLONE")
        let staged = try await store.stage(userId: "owner", draft: draft)
        let check = CustomSiteRadioCheck(exists: true, source: "anfr", anfrSiteId: "574340", identificationStatus: "identified",
                                         currentSite: CustomSiteCurrentSite(siteId: "574340", kind: .official, ownedByRequester: false))
        try await store.markReview(userId: "owner", requestId: staged.requestId, check: check)
        let credentials = CredentialStore(tokenStore: InMemoryTokenStore())
        let service = CustomSitesService(api: APIClient(config: .test, credentials: credentials), currentUserId: { "owner" }, outbox: store)
        let reviews = await service.pendingReviews()
        let review = try XCTUnwrap(reviews.first)
        XCTAssertEqual(review.check.currentKind, .official)
        await service.abandon(review)
        let empty = await service.pendingReviews()
        XCTAssertTrue(empty.isEmpty)
    }
}

private final class BodyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []
    func append(_ body: [String: Any]) { lock.lock(); bodies.append(body); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return bodies.count }
    var last: [String: Any]? { lock.lock(); defer { lock.unlock() }; return bodies.last }
}

private extension URLRequest {
    var disputeBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4_096
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
