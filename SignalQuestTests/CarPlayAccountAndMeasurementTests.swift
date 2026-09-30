import XCTest
@testable import SignalQuest

/// Lot 4h : CarPlay suit le compte et non chaque rafraîchissement du profil ;
/// un seul test de débit à la fois ; Siri dépose une demande de test ; « Y
/// aller » transmet sa destination au véhicule.
@MainActor
final class CarPlayAccountAndMeasurementTests: XCTestCase {
    private func renamed(_ user: AuthUser, name: String) throws -> AuthUser {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(user)) as? [String: Any]
        )
        object["name"] = name
        return try JSONDecoder().decode(AuthUser.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// Un profil rafraîchi (nom, points…) change l'état de session, mais pas le
    /// compte : la voiture ne se réinstalle pas et le guidage continue (CAR-01).
    func testProfileRefreshKeepsTheSameCarPlayAccount() throws {
        let refreshed = try renamed(.mock, name: "Autre nom")
        XCTAssertNotEqual(AuthSessionViewModel.State.authenticated(.mock), .authenticated(refreshed))
        XCTAssertEqual(CarPlayCoordinator.CarPlayAccountKey(.authenticated(.mock)),
                       CarPlayCoordinator.CarPlayAccountKey(.authenticated(refreshed)))
        XCTAssertEqual(CarPlayCoordinator.CarPlayAccountKey(.loggedOut),
                       CarPlayCoordinator.CarPlayAccountKey(.offline))
        XCTAssertNotEqual(CarPlayCoordinator.CarPlayAccountKey(.authenticated(.mock)),
                          CarPlayCoordinator.CarPlayAccountKey(.loggedOut))
    }

    /// Un seul test de débit à la fois, d'où qu'il soit lancé (CAR-05).
    func testOnlyOneSpeedtestRunsAtATime() {
        let gate = SpeedtestRunGate()
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertTrue(gate.isBusy)
        XCTAssertFalse(gate.tryAcquire(), "Un second test simultané doit être refusé")
        gate.release()
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(gate.tryAcquire(), "Les tests successifs (rafale, Drive Test) restent permis")
        gate.release()
    }

    /// « Y aller » sur l'iPhone porte sa destination jusqu'au véhicule : `.map`
    /// seul la perdait, et la voiture ne faisait rien (CAR-03).
    func testDirectionsRequestCarriesItsDestinationToTheCar() {
        var received: [CarPlayDashboardRoute.Destination] = []
        CarPlayDashboardRoute.setListener { received.append($0) }
        defer { CarPlayDashboardRoute.setListener(nil) }

        CarPlayDashboardRoute.request(.navigate(title: "Site 75-1234", latitude: 48.85, longitude: 2.35))

        XCTAssertEqual(received, [.navigate(title: "Site 75-1234", latitude: 48.85, longitude: 2.35)])
    }

    /// Siri, un raccourci ou le Centre de contrôle : l'onglet Tester s'ouvre avec
    /// une demande de test, que la vue confirme avant de lancer (MES-34).
    func testSiriRequestOpensTheTestTabWithAPendingStart() {
        let router = AppRouter()
        router.requestSpeedtestStart()
        XCTAssertEqual(router.selectedTab, .speed)
        XCTAssertTrue(router.pendingSpeedtestStart)
        XCTAssertTrue(router.hasPendingContentRoute)
    }
}
