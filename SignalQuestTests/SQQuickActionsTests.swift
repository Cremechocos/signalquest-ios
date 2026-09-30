import XCTest
import UIKit
@testable import SignalQuest

/// Actions rapides de l'icône (plan 3, vague 1) : chaque action pose la route
/// que l'app consomme au premier plan, comme Siri et Spotlight.
final class SQQuickActionsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        drainRoutes()
    }

    override func tearDown() {
        drainRoutes()
        super.tearDown()
    }

    func testMessagesIsOfferedOnlyWhenSignedIn() {
        XCTAssertEqual(SQQuickActions.items(signedIn: false).map(\.type), [
            SQQuickActions.Kind.speedtest.rawValue,
            SQQuickActions.Kind.driveTest.rawValue,
            SQQuickActions.Kind.map.rawValue,
        ])
        XCTAssertEqual(SQQuickActions.items(signedIn: true).last?.type, SQQuickActions.Kind.messages.rawValue)
        XCTAssertTrue(SQQuickActions.items(signedIn: true).allSatisfy { !$0.localizedTitle.isEmpty })
    }

    func testEachActionPostsItsRoute() {
        XCTAssertTrue(SQQuickActions.handle(item(.speedtest)))
        XCTAssertTrue(SQIntentRoute.consumeSpeedtest())
        XCTAssertTrue(SQQuickActions.handle(item(.driveTest)))
        XCTAssertTrue(SQIntentRoute.consumeDriveTest())
        XCTAssertTrue(SQQuickActions.handle(item(.map)))
        XCTAssertTrue(SQIntentRoute.consumeMap())
        XCTAssertTrue(SQQuickActions.handle(item(.messages)))
        XCTAssertTrue(SQIntentRoute.consumeMessages())
    }

    func testUnknownActionIsIgnored() {
        XCTAssertFalse(SQQuickActions.handle(UIApplicationShortcutItem(type: "autre", localizedTitle: "Autre")))
        XCTAssertFalse(SQIntentRoute.consumeSpeedtest())
        XCTAssertFalse(SQIntentRoute.consumeMap())
    }

    private func item(_ kind: SQQuickActions.Kind) -> UIApplicationShortcutItem {
        UIApplicationShortcutItem(type: kind.rawValue, localizedTitle: kind.rawValue)
    }

    private func drainRoutes() {
        _ = SQIntentRoute.consumeSpeedtest()
        _ = SQIntentRoute.consumeDriveTest()
        _ = SQIntentRoute.consumeMap()
        _ = SQIntentRoute.consumeMessages()
    }
}
