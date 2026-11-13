import XCTest
@testable import SignalQuest

/// Champ « Nom d'utilisateur » : états montrés pendant la saisie (identité membre v1).
@MainActor
final class UsernameAvailabilityModelTests: XCTestCase {
    private func makeModel(current: String? = nil, cooldownDays: Int? = nil) -> UsernameAvailabilityModel {
        UsernameAvailabilityModel(current: current) { handle in
            if let cooldownDays {
                return HandleAvailability(available: false, current: nil, cooldownActive: true,
                                          remainingDays: cooldownDays, code: "HANDLE_COOLDOWN")
            }
            let taken = handle == "pris"
            return HandleAvailability(handle: handle, available: !taken, current: nil, cooldownActive: nil,
                                      remainingDays: nil, code: taken ? "HANDLE_ALREADY_USED" : nil)
        }
    }

    private func settled(_ model: UsernameAvailabilityModel) async -> UsernameAvailabilityModel.Status {
        for _ in 0..<200 where model.status == .checking {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return model.status
    }

    func testLocalStatesNeedNoRequest() {
        let model = makeModel(current: "alex38")
        model.input = "  "
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.statusText)
        model.input = "a"
        XCTAssertEqual(model.status, .invalid)
        model.input = "@Alex38"
        XCTAssertEqual(model.status, .unchanged, "Ressaisir son nom actuel n'est pas un changement")
        XCTAssertFalse(model.canSubmit)
    }

    func testTakenAndAvailableAfterTheCheck() async {
        let model = makeModel()
        model.input = "Pris"
        XCTAssertEqual(model.status, .checking)
        let taken = await settled(model)
        XCTAssertEqual(taken, .taken)
        XCTAssertEqual(model.statusText, String(localized: "Déjà pris : choisis-en un autre."))

        model.input = "Élodie Martin"
        let available = await settled(model)
        XCTAssertEqual(available, .available)
        XCTAssertTrue(model.canSubmit)
        XCTAssertEqual(model.normalized, "elodie-martin")
        XCTAssertEqual(model.statusText, String(localized: "Disponible, enregistré comme \("elodie-martin")"))

        model.input = "elodie"
        _ = await settled(model)
        XCTAssertEqual(model.statusText, String(localized: "Disponible"), "Saisie déjà normalisée : rien à préciser")
    }

    func testCooldownAndServerRefusal() async {
        let model = makeModel(current: "alex38", cooldownDays: 12)
        model.input = "alex-g"
        let status = await settled(model)
        XCTAssertEqual(status, .cooldown(days: 12))
        model.reject(code: "HANDLE_ALREADY_USED")
        XCTAssertEqual(model.status, .taken)
        model.reject(code: "HANDLE_INVALID")
        XCTAssertEqual(model.status, .invalid)
    }

    func testNoCheckRouteIsAnError() {
        let model = UsernameAvailabilityModel()
        model.input = "alex38"
        XCTAssertEqual(model.status, .error)
    }
}
