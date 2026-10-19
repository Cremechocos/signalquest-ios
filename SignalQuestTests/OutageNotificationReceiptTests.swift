import XCTest
@testable import SignalQuest

final class OutageNotificationReceiptTests: XCTestCase {
    func testReceiptPayloadIsBoundToCommunityOutageAndValidToken() throws {
        let token = String(repeating: "a", count: 43)
        let parsed = try XCTUnwrap(OutageNotificationReceiptPayload.parse([
            "type": "community_outage",
            "outageNotificationId": "notification-1",
            "outageNotificationReceiptToken": token,
        ], state: "received"))
        XCTAssertEqual(parsed.id, "notification-1")
        XCTAssertEqual(parsed.payload, .init(state: "received", receiptToken: token))
    }

    func testReceiptRejectsAnotherTypeInvalidTokenAndUnknownState() {
        let token = String(repeating: "a", count: 43)
        XCTAssertNil(OutageNotificationReceiptPayload.parse([
            "type": "message_new",
            "outageNotificationId": "notification-1",
            "outageNotificationReceiptToken": token,
        ], state: "received"))
        XCTAssertNil(OutageNotificationReceiptPayload.parse([
            "type": "community_outage",
            "outageNotificationId": "notification-1",
            "outageNotificationReceiptToken": "court",
        ], state: "received"))
        XCTAssertNil(OutageNotificationReceiptPayload.parse([
            "type": "community_outage",
            "outageNotificationId": "notification-1",
            "outageNotificationReceiptToken": token,
        ], state: "displayed"))
    }

    /// L'identifiant entre dans le chemin d'API du reçu : un séparateur ou un point-point ne passe pas.
    func testReceiptRejectsAnIdentifierThatCouldChangeThePath() {
        let token = String(repeating: "a", count: 43)
        for id in ["../../x", "a/b", "id?x=1", "id%2F", " id", "id ", "", "-id", String(repeating: "a", count: 129)] {
            XCTAssertNil(OutageNotificationReceiptPayload.parse([
                "type": "community_outage",
                "outageNotificationId": id,
                "outageNotificationReceiptToken": token,
            ], state: "opened"), "« \(id) » doit être refusé")
        }
        XCTAssertNotNil(OutageNotificationReceiptPayload.parse([
            "type": "community_outage",
            "outageNotificationId": "cm0abc123_DEF-9",
            "outageNotificationReceiptToken": token,
        ], state: "opened"))
    }

    func testClientVersionIncludesBuildForProductionDiagnostics() {
        XCTAssertEqual(
            APIClient.appVersionLabel(shortVersion: "1.0", build: "75"),
            "1.0 (75)"
        )
        XCTAssertEqual(APIClient.appVersionLabel(shortVersion: "1.0", build: nil), "1.0")
        XCTAssertNil(APIClient.appVersionLabel(shortVersion: " ", build: "75"))
    }

    /// Contrat d'en-têtes client v1 : le build part aussi seul, lisible par le
    /// serveur ; la version garde « 1.0 (161) » tant que le serveur l'y lit.
    func testTheBuildAlsoTravelsInItsOwnHeader() {
        XCTAssertEqual(
            APIClient.appVersionHeaders(shortVersion: "1.0", build: "161"),
            ["X-Client-App-Version": "1.0 (161)", "X-Client-App-Build": "161"]
        )
        XCTAssertEqual(APIClient.appVersionHeaders(shortVersion: "1.0", build: nil), ["X-Client-App-Version": "1.0"])
        XCTAssertEqual(APIClient.appVersionHeaders(shortVersion: "1.0", build: "0"), ["X-Client-App-Version": "1.0 (0)"])
    }
}
