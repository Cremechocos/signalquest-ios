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
}
