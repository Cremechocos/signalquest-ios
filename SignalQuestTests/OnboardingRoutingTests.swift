import XCTest
@testable import SignalQuest

@MainActor
final class OnboardingRoutingTests: XCTestCase {
    func testAcknowledgedGuestKeepsTheChosenTabForSubsequentSignIn() async throws {
        let name = "sq-onboarding-guest-route-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for destination in [OnboardingEntryDestination.map, .measure] {
            defaults.removePersistentDomain(forName: name)
            let entry = OnboardingEntryState(defaults: defaults)
            let router = AppRouter()
            entry.finish(destination: destination)
            let lease = try XCTUnwrap(entry.reserveGuestPresentation(try XCTUnwrap(entry.pending), sceneID: UUID()))
            XCTAssertTrue(router.acknowledgeOnboardingGuest(lease))
            XCTAssertEqual(router.selectedTab, destination == .map ? .map : .speed)
            XCTAssertNil(entry.pending)
            XCTAssertFalse(router.pendingDriveTest)
            router.selectedTab = .profile
            XCTAssertFalse(router.acknowledgeOnboardingGuest(lease))
            XCTAssertEqual(router.selectedTab, .profile, "Repeated appearance cannot overwrite later navigation")
        }
    }

    func testRouteArrivingBeforeGuestAppearanceKeepsPriority() async throws {
        let name = "sq-onboarding-guest-priority-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = OnboardingEntryState(defaults: defaults)
        entry.finish(destination: .measure)
        let request = try XCTUnwrap(entry.pending)
        let lease = try XCTUnwrap(entry.reserveGuestPresentation(request, sceneID: UUID()))
        let router = AppRouter()
        router.route(toConversation: "conversation-synthetic-priority")
        XCTAssertFalse(router.acknowledgeOnboardingGuest(lease))
        XCTAssertFalse(lease.didPresent)
        XCTAssertEqual(entry.pending, request)
        XCTAssertEqual(router.selectedTab, .community)
        XCTAssertEqual(router.openConversationId, "conversation-synthetic-priority")
    }

    func testMeasureSelectsSpeedWithoutStartingDriveTestOrChangingDeepLinkFields() async {
        let router = AppRouter()
        router.selectedTab = .home
        XCTAssertTrue(router.routeFromOnboarding(to: .measure))
        XCTAssertEqual(router.selectedTab, .speed)
        XCTAssertFalse(router.pendingDriveTest)
        XCTAssertNil(router.pendingMapFocus)
        XCTAssertNil(router.openConversationId)
    }

    func testMapSelectsMapWithoutRequestingACoordinate() async {
        let router = AppRouter()
        router.selectedTab = .home
        XCTAssertTrue(router.routeFromOnboarding(to: .map))
        XCTAssertEqual(router.selectedTab, .map)
        XCTAssertNil(router.pendingMapFocus)
        XCTAssertFalse(router.pendingDriveTest)
    }

    func testConversationDeepLinkKeepsItsDestination() async {
        let router = AppRouter()
        router.route(toConversation: "conversation-synthetic")
        XCTAssertFalse(router.routeFromOnboarding(to: .measure))
        XCTAssertEqual(router.selectedTab, .community)
        XCTAssertEqual(router.openConversationId, "conversation-synthetic")
        XCTAssertTrue(router.openMessagesInbox)
    }

    func testProfileApprovalKeepsItsDestination() async {
        let router = AppRouter()
        router.route(toE2EEDeviceApproval: "approval-synthetic")
        XCTAssertFalse(router.routeFromOnboarding(to: .map))
        XCTAssertEqual(router.selectedTab, .profile)
        XCTAssertEqual(router.openE2EEDeviceApprovalId, "approval-synthetic")
    }

    func testMapContentAndDriveTestIntentsCannotBeOverwritten() async {
        let map = AppRouter()
        map.route(toSite: "site-synthetic")
        XCTAssertFalse(map.routeFromOnboarding(to: .measure))
        XCTAssertEqual(map.openSiteId, "site-synthetic")
        let drive = AppRouter()
        drive.selectedTab = .speed
        drive.pendingDriveTest = true
        XCTAssertFalse(drive.routeFromOnboarding(to: .map))
        XCTAssertTrue(drive.pendingDriveTest)
        XCTAssertEqual(drive.selectedTab, .speed)
    }
}
