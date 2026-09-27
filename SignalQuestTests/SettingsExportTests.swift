import XCTest
@testable import SignalQuest

private final class ExportUserService: UserServicing, @unchecked Sendable {
    enum Unused: Error { case notImplemented }
    let fetch: @Sendable () async throws -> Data

    init(fetch: @escaping @Sendable () async throws -> Data) { self.fetch = fetch }

    func exportPersonalData() async throws -> Data { try await fetch() }
    func profile() async throws -> AuthUser { throw Unused.notImplemented }
    func updateProfile(_ patch: UserProfilePatch) async throws -> AuthUser { throw Unused.notImplemented }
    func checkHandleAvailability(_ handle: String) async throws -> HandleAvailability { throw Unused.notImplemented }
    func uploadAvatar(data: Data, filename: String, mimeType: String) async throws -> AuthUser { throw Unused.notImplemented }
    func stats() async throws -> UserStats { throw Unused.notImplemented }
    func notificationPreferences() async throws -> NotificationPreferences { throw Unused.notImplemented }
    func updateNotificationPreferences(_ prefs: NotificationPreferences) async throws -> NotificationPreferences { throw Unused.notImplemented }
    func heartbeat() async throws { throw Unused.notImplemented }
    func accountDeletionPreview() async throws -> AccountDeletionPreview { throw Unused.notImplemented }
    func requestAccountDeletionEmailCode() async throws -> AccountDeletionEmailChallenge { throw Unused.notImplemented }
    func deleteAccount(using proof: AccountDeletionProof) async throws -> AccountDeletionResult { throw Unused.notImplemented }
}

private actor ExportGate {
    private var didStart = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<Data, Error>?

    func fetch() async throws -> Data {
        didStart = true
        startContinuation?.resume()
        startContinuation = nil
        return try await withCheckedThrowingContinuation { resultContinuation = $0 }
    }

    func waitForStart() async {
        if didStart { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func finish(with data: Data) {
        resultContinuation?.resume(returning: data)
        resultContinuation = nil
    }
}

@MainActor
final class SettingsExportTests: XCTestCase {
    func testShareDismissalRemovesUniqueExportFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-export-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory); LocalAccountScope.deactivate() }
        LocalAccountScope.activate(userId: "export-A")
        let expected = Data("{\"owner\":\"A\"}".utf8)
        let model = SettingsViewModel(userService: ExportUserService(fetch: { expected }),
                                      authService: MockAuthService(), exportDirectory: directory)

        await model.exportData()
        let first = try XCTUnwrap(model.exportedFile?.url)
        XCTAssertEqual(try Data(contentsOf: first), expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        model.clearExport()
        XCTAssertNil(model.exportedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))

        await model.exportData()
        let second = try XCTUnwrap(model.exportedFile?.url)
        XCTAssertNotEqual(second, first)
        LocalAccountScope.activate(userId: "export-B")
        model.clearExportIfAccountChanged(.authenticated(.mock))
        XCTAssertNil(model.exportedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testResponseFromAccountACannotBecomeAccountBExport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sq-export-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory); LocalAccountScope.deactivate() }
        LocalAccountScope.activate(userId: "export-A")
        let gate = ExportGate()
        let model = SettingsViewModel(userService: ExportUserService(fetch: { try await gate.fetch() }),
                                      authService: MockAuthService(), exportDirectory: directory)

        let export = Task { await model.exportData() }
        await gate.waitForStart()
        LocalAccountScope.activate(userId: "export-B")
        await gate.finish(with: Data("{\"owner\":\"A\"}".utf8))
        await export.value

        XCTAssertNil(model.exportedFile)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isExporting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
