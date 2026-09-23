import XCTest

@MainActor
final class CommunityFirstContentQATests: XCTestCase {
    func testFirstPostIsReachableWithoutScrollingAndPulseCanExpand() {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: "fr")
        defer { app.terminate() }

        let community = SignalQuestUITestSupport.tab(named: "Communauté", in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 15))
        community.tap()

        let firstPost = app.descendants(matching: .any)["feed.item.demo-post-1"]
        XCTAssertTrue(firstPost.waitForExistence(timeout: 15), "Premier post démo introuvable")
        let dock = app.descendants(matching: .any)["main.navigation"]
        let visibleBottom = dock.exists ? dock.frame.minY : app.frame.maxY
        print("SQ_FEED_FIRST_POST minY=\(firstPost.frame.minY) visibleBottom=\(visibleBottom)")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "community-first-post-collapsed"
        before.lifetime = .keepAlways
        add(before)
        XCTAssertLessThan(firstPost.frame.minY, visibleBottom - 44,
                          "Le premier post doit commencer avant le dock, sans défilement")

        let pulseToggle = app.buttons["community.networkPulse.toggle"]
        XCTAssertTrue(pulseToggle.waitForExistence(timeout: 5), "Détails réseau non découvrables")
        XCTAssertFalse(app.descendants(matching: .any)["community.networkPulse"].exists)
        pulseToggle.tap()
        XCTAssertTrue(app.descendants(matching: .any)["community.networkPulse"]
            .waitForExistence(timeout: 5), "Pouls réseau non accessible après ouverture")
    }

    func testFirstPostIsReachableAfterOneScrollAtAccessibilityXXL() {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: [
            "--mock-auth", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXL"
        ], locale: "fr")
        defer { app.terminate() }

        let community = SignalQuestUITestSupport.tab(named: "Communauté", in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 15))
        community.tap()
        let pulseToggle = app.buttons["community.networkPulse.toggle"]
        XCTAssertTrue(pulseToggle.waitForExistence(timeout: 15))
        XCTAssertTrue(pulseToggle.isHittable, "Pouls réseau replié inaccessible en AX XXL")

        app.scrollViews.firstMatch.swipeUp()
        let firstPost = app.descendants(matching: .any)["feed.item.demo-post-1"]
        XCTAssertTrue(firstPost.waitForExistence(timeout: 10))
        XCTAssertTrue(firstPost.isHittable, "Premier post inaccessible après un défilement AX XXL")
        let dock = app.descendants(matching: .any)["main.navigation"]
        let storyNames = app.staticTexts.matching(identifier: "feed.story.name").allElementsBoundByIndex
        XCTAssertFalse(storyNames.isEmpty, "Libellés des stories introuvables après défilement")
        for name in storyNames {
            XCTAssertTrue(name.isHittable, "Story illisible après défilement AX XXL")
            if dock.exists {
                XCTAssertLessThan(name.frame.maxY, dock.frame.minY,
                                  "Libellé de story encore sous la navigation")
            }
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "community-first-post-accessibility-xxl"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testEnglishDisclosureKeepsFirstPostVisibleOnSmallIPhone() {
        continueAfterFailure = false
        let app = XCUIApplication()
        SignalQuestUITestSupport.launch(app, arguments: ["--mock-auth"], locale: "en")
        defer { app.terminate() }

        let community = SignalQuestUITestSupport.tab(named: "Community", in: app)
        XCTAssertTrue(community.waitForExistence(timeout: 15))
        community.tap()
        let pulseToggle = app.buttons["community.networkPulse.toggle"]
        XCTAssertTrue(pulseToggle.waitForExistence(timeout: 15))
        XCTAssertTrue(pulseToggle.label.contains("Network pulse"), "Libellé anglais absent")

        let firstPost = app.descendants(matching: .any)["feed.item.demo-post-1"]
        XCTAssertTrue(firstPost.waitForExistence(timeout: 15))
        let dock = app.descendants(matching: .any)["main.navigation"]
        let visibleBottom = dock.exists ? dock.frame.minY : app.frame.maxY
        XCTAssertLessThan(firstPost.frame.minY, visibleBottom - 44)
    }
}
