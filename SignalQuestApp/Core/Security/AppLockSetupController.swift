import Foundation
import Combine

/// Owns one Settings window's confirmation. The final check and preference
/// mutation run together on MainActor, without an await between them.
@MainActor
final class AppLockSetupController: ObservableObject {
    @Published private(set) var isConfirming = false
    @Published private(set) var errorMessage: String?

    private let revision: @MainActor () -> UUID
    private let writeEnabled: @MainActor (Bool) -> Void
    private let authenticate: @MainActor () async -> Bool
    private var intent = UUID()
    private var task: Task<Void, Never>?
    private var pendingSession: (store: CredentialStore, snapshot: CredentialStore.Snapshot)?

    init(
        revision: @escaping @MainActor () -> UUID = { AppLockSettings.mutationRevision },
        setEnabled: @escaping @MainActor (Bool) -> Void = { AppLockSettings.setEnabled($0) },
        authenticate: @escaping @MainActor () async -> Bool = {
            await BiometricAuth.authenticate(
                reason: String(localized: "Confirme ton identité pour activer le verrouillage"))
        }
    ) {
        self.revision = revision
        writeEnabled = setEnabled
        self.authenticate = authenticate
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, credentials: CredentialStore) -> Task<Void, Never>? {
        cancel()
        let snapshot = credentials.snapshot()
        guard snapshot.accessToken?.isEmpty == false else {
            errorMessage = String(localized: "Reconnecte-toi pour modifier le verrouillage de SignalQuest.")
            return nil
        }
        guard enabled else {
            writeEnabled(false)
            return nil
        }
        let id = intent
        let expectedRevision = revision()
        pendingSession = (credentials, snapshot)
        isConfirming = true
        let authenticate = authenticate
        let confirmation = Task { [weak self] in
            let success = await authenticate()
            guard let self, self.intent == id else { return }
            self.task = nil
            self.pendingSession = nil
            self.isConfirming = false
            // HTTP token refresh is allowed. Logout/login, including the same
            // account, changes sessionID and revokes the old confirmation.
            guard !Task.isCancelled, credentials.isCurrent(snapshot),
                  self.revision() == expectedRevision else { return }
            guard success else {
                self.errorMessage = String(localized: "Le verrouillage n’a pas été activé. Réessaie avec la biométrie ou le code de l’appareil.")
                return
            }
            self.writeEnabled(true)
        }
        task = confirmation
        return confirmation
    }

    func cancelIfSessionChanged() {
        guard let pendingSession else { return }
        if !pendingSession.store.isCurrent(pendingSession.snapshot) { cancel() }
    }

    /// View disappearance and actual application backgrounding cancel the
    /// LAContext through BiometricAuth. A Face ID .inactive event does not.
    func cancel() {
        intent = UUID()
        task?.cancel()
        task = nil
        pendingSession = nil
        isConfirming = false
        errorMessage = nil
    }
}
