import Foundation
import XCTest
@testable import SignalQuest

/// Phase centrale seulement : Android prépare un scénario dédié avant ce test
/// puis le relit après. Le passage privé reste intact en cas de vérification ratée.
@MainActor
final class FavoritesMixedBackendInteropTests: XCTestCase {
    private struct Handoff: Decodable {
        let schemaVersion: Int
        let runId: UUID
        let baseURL: URL
        let database: String
        let controlKey: String
        let phase: String
        let scenario: FavoritesInteropScenario
    }

    func testNativeIOSUpdatesTheScenarioPreparedByAndroid() async throws {
        let config = try FavoritesInteropConfiguration.load() // Refuse le réseau sans opt-in.
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SQ_FAVORITES_MIXED_HANDOFF_PATH"] ?? environment["TEST_RUNNER_SQ_FAVORITES_MIXED_HANDOFF_PATH"] else {
            throw XCTSkip("Scénario Android/iOS partagé non demandé")
        }
        let file = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: file)
        try require(original.count < 512 * 1024, "Le passage de recette doit rester borné")
        let handoff = try JSONDecoder().decode(Handoff.self, from: original)
        try require(handoff.schemaVersion == 1 && handoff.phase == "android_before_passed", "Android doit avoir confirmé sa première phase")
        try require(handoff.baseURL == config.baseURL && handoff.database == config.database && handoff.controlKey == config.controlKey,
                    "Le passage doit appartenir au même serveur synthétique")
        let harness = try await FavoritesInteropHarness.openExisting(handoff.scenario)
        do {
            let ios = try harness.client(handoff.scenario.A, directoryName: "mixed-native-ios")
            await ios.service.load()
            try require(ios.service.hasLoaded && ios.service.errorMessage == nil, "Le client natif doit charger le snapshot Android")
            try require(Set(ios.service.favorites.map(\.id)) == ["FR:MIXED-SHARED", "FR:ANDROID-KEEP"], "Deux favoris Android attendus")
            try require(!ios.service.notifyOnIssues, "La préférence initiale Android doit être désactivée")

            let canadian = FavoriteAntenna(siteId: "MIXED-SHARED", market: "CA", operator: nil, name: "Mixed Canadian site")
            let french = FavoriteAntenna(siteId: "MIXED-SHARED", market: "FR", operator: nil)
            _ = await ios.service.toggle(canadian)
            try require(ios.service.pendingCount == 0 && ios.service.errorMessage == nil, "L'ajout CA doit être confirmé par le serveur")
            await ios.service.remove(french)
            await ios.service.setNotifyOnIssues(true)
            let expected: Set<String> = ["CA:MIXED-SHARED", "FR:ANDROID-KEEP"]
            try require(ios.service.pendingCount == 0 && ios.service.errorMessage == nil, "Les intentions iOS doivent toutes être confirmées")
            try require(Set(ios.service.favorites.map(\.id)) == expected && ios.service.notifyOnIssues, "Le snapshot iOS doit refléter les trois changements")

            let state = try await harness.databaseState()
            let account = try state.account(handoff.scenario.A)
            let other = try state.account(handoff.scenario.B)
            try require(account.favoriteKeys == expected && account.preferences.notifyFavoriteAntennaIssuesPush, "La base doit confirmer le résultat iOS")
            try require(account.receipts.count == 5 && account.receipts.allSatisfy { $0.outcome == "applied" },
                        "Deux intentions Android et trois intentions iOS doivent avoir un reçu appliqué")
            try require(other.favoriteKeys.isEmpty && other.receipts.isEmpty && !other.preferences.notifyFavoriteAntennaIssuesPush,
                        "Le compte témoin B ne doit pas changer")

            // Lire et préserver tous les champs Android, y compris ses UUID de
            // mutation. Aucun diagnostic n'imprime ce document ou ses jetons.
            var document = try JSONDecoder().decode([String: JSONValue].self, from: original)
            let databaseJSON = try await harness.databaseStateJSON()
            document["phase"] = .string("ios_native_passed")
            document["iosNative"] = .object([
                "completedAt": .string(Date().ISO8601Format()),
                "expectedKeys": .array(expected.sorted().map(JSONValue.string)),
                "notifyOnIssues": .bool(true),
                "databaseState": databaseJSON,
            ])
            // Ne pas écraser une autre phase si un orchestrateur a repris le fichier.
            try require(try Data(contentsOf: file) == original, "Le passage de recette a changé pendant le test")
            try JSONEncoder().encode(document).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            await harness.cleanUp(resetScenario: false)
        } catch {
            await harness.cleanUp(resetScenario: false)
            throw error
        }
    }

    private func require(_ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition else {
            XCTFail(message, file: file, line: line)
            throw FavoritesInteropError.invalidResponse
        }
    }
}
