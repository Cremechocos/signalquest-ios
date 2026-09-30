import XCTest
@testable import SignalQuest

/// Tâches d'arrière-plan des envois en attente (plan 3, vague 1). Un
/// identifiant enregistré sans figurer dans l'Info.plist fait planter l'app au
/// lancement : les deux listes doivent rester alignées.
final class PendingQueueBackgroundTasksTests: XCTestCase {
    func testIdentifiersAndModesAreDeclaredInInfoPlist() throws {
        let permitted = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        )
        XCTAssertEqual(Set(permitted), Set(PendingQueueBackgroundTasks.identifiers))

        let modes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        XCTAssertTrue(modes.contains("fetch"), "Le rafraîchissement d'arrière-plan exige le mode fetch")
        XCTAssertTrue(modes.contains("processing"), "Le traitement d'arrière-plan exige le mode processing")
    }
}
