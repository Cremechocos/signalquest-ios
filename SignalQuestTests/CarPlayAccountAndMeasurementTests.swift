import XCTest
@testable import SignalQuest

/// Lot 4h : CarPlay suit le compte et non chaque rafraîchissement du profil ;
/// un seul test de débit à la fois ; Siri dépose une demande de test.
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
    /// compte : la voiture ne se réinstalle pas (CAR-01).
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
