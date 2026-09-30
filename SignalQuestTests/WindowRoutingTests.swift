import XCTest
@testable import SignalQuest

/// Lot 4i : un routeur par fenêtre iPad (TRX-08).
@MainActor
final class WindowRoutingTests: XCTestCase {
    /// La première fenêtre reprend le routeur initial, où une notification
    /// touchée app fermée a pu déposer sa route avant qu'elle n'existe.
    func testFirstWindowKeepsARouteDepositedBeforeItExisted() {
        let initial = AppRouter()
        let routing = WindowRouting(initial: initial)
        routing.active.route(toPost: "post-1")

        let first = routing.claimWindowRouter()

        XCTAssertTrue(first === initial)
        XCTAssertEqual(first.openPostId, "post-1")
    }

    /// Deux fenêtres, deux routeurs : changer d'onglet dans l'une ne change
    /// plus l'autre.
    func testSecondWindowNoLongerMirrorsTheFirst() {
        let routing = WindowRouting(initial: AppRouter())
        let first = routing.claimWindowRouter()
        let second = routing.claimWindowRouter()

        second.selectedTab = .map

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.selectedTab, .home)
    }

    /// Siri, une notification ou Plans visent la fenêtre passée au premier plan.
    func testExternalRoutesGoToTheActiveWindow() {
        let services = AppServices(config: .test)
        let first = services.routing.claimWindowRouter()
        let second = services.routing.claimWindowRouter()

        services.routing.activate(second)
        services.router.requestSpeedtestStart()

        XCTAssertTrue(second.pendingSpeedtestStart)
        XCTAssertFalse(first.pendingSpeedtestStart)
    }

    /// Réévaluée, une fenêtre garde le même routeur au lieu d'en réclamer un autre.
    func testAWindowClaimsItsRouterOnce() {
        let routing = WindowRouting(initial: AppRouter())
        let store = WindowRouterStore()

        let claimed = store.router(claimingFrom: routing)

        XCTAssertTrue(store.router(claimingFrom: routing) === claimed)
        XCTAssertFalse(routing.claimWindowRouter() === claimed)
    }
}
