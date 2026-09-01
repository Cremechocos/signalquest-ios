import Foundation

enum E2EEV2NotificationContextStoreError: Error, Equatable {
    case invalidContext
    case invalidRecord
}

protocol E2EEV2NotificationActivationStoring: Sendable {
    func revision() throws -> String?
    func activate(revision: String) throws
    func revoke() throws
}

final class E2EEV2NotificationMemoryActivationStore: E2EEV2NotificationActivationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func revision() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func activate(revision: String) { lock.lock(); value = revision; lock.unlock() }
    func revoke() { lock.lock(); value = nil; lock.unlock() }
}

/// The shared container carries only a random revision marker, never an owner,
/// token, key, sender name or message. Read from disk on every check, without a
/// cross-process UserDefaults cache that could lag behind a revocation.
final class E2EEV2NotificationFileActivationStore: E2EEV2NotificationActivationStoring, @unchecked Sendable {
    private let url: URL
    init(url: URL) { self.url = url }

    func revision() throws -> String? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 128) ?? Data()
            guard data.count <= 64, let text = String(data: data, encoding: .utf8) else {
                throw E2EEV2NotificationContextStoreError.invalidRecord
            }
            if text == "revoked" { return nil }
            guard UUID(uuidString: text) != nil else { throw E2EEV2NotificationContextStoreError.invalidRecord }
            return text
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func activate(revision: String) throws {
        guard UUID(uuidString: revision) != nil else { throw E2EEV2NotificationContextStoreError.invalidRecord }
        try Data(revision.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func revoke() throws {
        do {
            try Data("revoked".utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { return }
        }
    }
}

/// Separate service AND access group: the notification extension cannot query
/// the app's private E2EE history, recovery keys or unrelated account storage.
final class E2EEV2NotificationContextStore: @unchecked Sendable {
    private static let storageKey = "active-notification-context-v1"
    private let tokenStore: TokenStore
    private let activationStore: E2EEV2NotificationActivationStoring

    init(tokenStore: TokenStore, activationStore: E2EEV2NotificationActivationStoring = E2EEV2NotificationMemoryActivationStore()) {
        self.tokenStore = tokenStore
        self.activationStore = activationStore
    }

    static func configured(bundle: Bundle = .main) -> E2EEV2NotificationContextStore? {
        guard let group = bundle.object(forInfoDictionaryKey: "SQ_NOTIFICATION_KEYCHAIN_ACCESS_GROUP") as? String,
              !group.isEmpty, !group.contains("$("),
              group.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil,
              let appGroup = bundle.object(forInfoDictionaryKey: "SQ_APP_GROUP") as? String,
              !appGroup.isEmpty, !appGroup.contains("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return .init(tokenStore: KeychainStore(
            service: "fr.signalquest.ios.e2ee.notification-context.v1",
            accessGroup: group
        ), activationStore: E2EEV2NotificationFileActivationStore(
            url: container.appendingPathComponent("e2ee-notification-activation-v1")
        ))
    }

    func load(now: Date = Date()) throws -> E2EEV2NotificationContext? {
        let context = try loadForCredentialRefresh()
        return context?.isValid(now: now) == true ? context : nil
    }

    /// Only the authenticated app may renew credentials on an existing mirror.
    /// The extension always uses load(now:), which refuses expired credentials.
    func loadForCredentialRefresh() throws -> E2EEV2NotificationContext? {
        guard let activeRevision = try activationStore.revision() else { return nil }
        guard let raw = try tokenStore.string(for: Self.storageKey) else { return nil }
        guard raw.utf8.count <= 256 * 1_024,
              let data = raw.data(using: .utf8),
              let context = try? JSONDecoder().decode(E2EEV2NotificationContext.self, from: data) else {
            throw E2EEV2NotificationContextStoreError.invalidRecord
        }
        guard context.isStructurallyValid, context.revisionId == activeRevision,
              try activationStore.revision() == activeRevision else { return nil }
        return context
    }

    func isCurrent(_ expected: E2EEV2NotificationContext, now: Date = Date()) throws -> Bool {
        guard let current = try load(now: now) else { return false }
        return current.ownerScopeId == expected.ownerScopeId &&
            current.sessionId == expected.sessionId &&
            current.revisionId == expected.revisionId && current.privacy == expected.privacy
    }

    func permits(_ prepared: E2EEV2PreparedNotification, now: Date = Date()) throws -> Bool {
        guard let current = try load(now: now) else { return false }
        return current.ownerScopeId == prepared.ownerScopeId &&
            current.sessionId == prepared.sessionId &&
            current.revisionId == prepared.contextRevisionId &&
            current.privacy == prepared.presentation.privacy
    }

    @discardableResult
    func saveRuntime(_ context: E2EEV2NotificationContext, now: Date = Date()) throws -> Bool {
        guard E2EEV2RuntimeReadGate.enabled else { return false }
        try saveContractPreview(context, now: now)
        return true
    }

    /// Used by deterministic tests. Runtime callers must use saveRuntime.
    func saveContractPreview(_ context: E2EEV2NotificationContext, now: Date = Date()) throws {
        guard context.isValid(now: now) else { throw E2EEV2NotificationContextStoreError.invalidContext }
        let data = try JSONEncoder().encode(context)
        guard data.count <= 256 * 1_024,
              let raw = String(data: data, encoding: .utf8) else {
            throw E2EEV2NotificationContextStoreError.invalidContext
        }
        // Only this explicit, revocable preview mirror is available after first unlock.
        // The app's original private identity and history stores remain whenUnlocked.
        try activationStore.revoke()
        try tokenStore.set(raw, for: Self.storageKey, accessibility: .afterFirstUnlock)
        try activationStore.activate(revision: context.revisionId)
        guard try load(now: now) == context else { throw E2EEV2NotificationContextStoreError.invalidRecord }
    }

    func revoke() throws {
        var markerRevoked = false
        do { try activationStore.revoke(); markerRevoked = true } catch { /* Keychain deletion remains an alternative. */ }
        do { try tokenStore.remove(Self.storageKey) }
        catch { if !markerRevoked { throw error } }
    }
}
