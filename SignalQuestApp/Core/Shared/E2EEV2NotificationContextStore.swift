import CryptoKit
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
    private static let storageKey = "active-notification-context-v2"
    /// Contexte v1, qui portait les clés privées de l'appareil : effacé à
    /// chaque révocation et avant chaque activation, jamais relu.
    private static let legacyStorageKey = "active-notification-context-v1"
    private static let conversationPrefix = "notification-conversation-v1:"
    private static let shownPrefix = "notification-shown-v1:"
    /// Les écritures de l'extension sur ce qu'elle a montré, l'une après l'autre.
    private static let shownLock = NSLock()
    private let tokenStore: TokenStore
    private let activationStore: E2EEV2NotificationActivationStoring

    /// Ce que l'extension a montré d'une conversation : le plus haut compteur
    /// par appareil émetteur, pour un compte et une session. Aucune clé.
    private struct Shown: Codable, Equatable {
        static let currentVersion = 1
        let version: Int
        let ownerScopeId: String
        let sessionId: String
        let counters: [String: Int]
    }

    init(tokenStore: TokenStore, activationStore: E2EEV2NotificationActivationStoring = E2EEV2NotificationMemoryActivationStore()) {
        self.tokenStore = tokenStore
        self.activationStore = activationStore
    }

    static func configured(bundle: Bundle = .main) -> E2EEV2NotificationContextStore? {
        guard let group = bundle.object(forInfoDictionaryKey: "SQ_NOTIFICATION_KEYCHAIN_ACCESS_GROUP") as? String,
              !group.isEmpty, !group.contains("$("),
              group.range(of: #"^[A-Za-z0-9.-]+\z"#, options: .regularExpression) != nil,
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
        // Les entrées ne restent que d'un contexte actif du même compte, de la
        // même session et du même mode ; sinon (autre compte, révocation,
        // changement d'aperçu), elles partent toutes avant l'activation, ou
        // rien n'est activé.
        let previous = try? loadForCredentialRefresh()
        let keepsEntries = previous.map {
            $0.ownerScopeId == context.ownerScopeId && $0.sessionId == context.sessionId && $0.privacy == context.privacy
        } ?? false
        // Only this explicit, revocable preview mirror is available after first unlock.
        // The app's original private identity and history stores remain whenUnlocked.
        try activationStore.revoke()
        if !keepsEntries { try purgeEntries() }
        try tokenStore.set(raw, for: Self.storageKey, accessibility: .afterFirstUnlock)
        try activationStore.activate(revision: context.revisionId)
        guard try load(now: now) == context else { throw E2EEV2NotificationContextStoreError.invalidRecord }
    }

    /// Entrée d'une conversation (§2.6), écrite par l'app seulement tant qu'un
    /// contexte est actif : jamais en mode « aucun aperçu ».
    @discardableResult
    func saveConversationRuntime(_ entry: E2EEV2NotificationConversation, now: Date = Date()) throws -> Bool {
        guard E2EEV2RuntimeReadGate.enabled else { return false }
        try saveConversationContractPreview(entry, now: now)
        return true
    }

    /// Used by deterministic tests. Runtime callers must use saveConversationRuntime.
    /// Liée au contexte actif ; si celui-ci change pendant l'écriture
    /// (révocation, autre session), l'entrée repart aussitôt.
    func saveConversationContractPreview(_ entry: E2EEV2NotificationConversation, now: Date = Date()) throws {
        let key = Self.conversationKey(entry.conversationId)
        guard entry.isStructurallyValid, let context = try load(now: now),
              entry.ownerScopeId == context.ownerScopeId, entry.sessionId == context.sessionId,
              entry.hasEpochKeys == (context.privacy == .full) else {
            throw E2EEV2NotificationContextStoreError.invalidContext
        }
        let data = try JSONEncoder().encode(entry)
        guard data.count <= 256 * 1_024, let raw = String(data: data, encoding: .utf8) else {
            try? tokenStore.remove(key)
            throw E2EEV2NotificationContextStoreError.invalidContext
        }
        do {
            try tokenStore.set(raw, for: key, accessibility: .afterFirstUnlock)
        } catch {
            try? tokenStore.remove(key)
            throw error
        }
        guard (try? load(now: now))?.revisionId == context.revisionId else {
            try? tokenStore.remove(key)
            throw E2EEV2NotificationContextStoreError.invalidContext
        }
        pruneEntries(keeping: key, context: context, now: now)
    }

    /// Rien n'est lisible sans contexte actif, ni pour un autre compte ou une
    /// autre session que la sienne : un marqueur révoqué suffit à rendre
    /// muettes les entrées qu'une suppression aurait manquées. Une entrée
    /// illisible, étrangère ou trop vieille part dès qu'on la croise.
    func conversation(_ conversationId: String, now: Date = Date()) throws -> E2EEV2NotificationConversation? {
        guard let context = try load(now: now) else { return nil }
        let key = Self.conversationKey(conversationId)
        guard let raw = try tokenStore.string(for: key) else { return nil }
        guard raw.utf8.count <= 256 * 1_024, let data = raw.data(using: .utf8),
              let entry = try? JSONDecoder().decode(E2EEV2NotificationConversation.self, from: data),
              entry.conversationId == conversationId, entry.isStructurallyValid else {
            try? tokenStore.remove(key)
            throw E2EEV2NotificationContextStoreError.invalidRecord
        }
        guard entry.ownerScopeId == context.ownerScopeId, entry.sessionId == context.sessionId,
              entry.isFresh(nowMs: Int64(now.timeIntervalSince1970 * 1_000)) else {
            try? tokenStore.remove(key)
            return nil
        }
        return entry
    }

    /// Retient, d'un seul geste, un message que l'extension va montrer : vrai
    /// seulement si son compteur dépasse `floor` (le plus haut reçu par
    /// l'app) et tout ce qu'elle a déjà montré de cet appareil. Une lecture du
    /// trousseau qui échoue fait échouer : la notification reste générique.
    func claimShown(conversationId: String, deviceId: String, counter: Int, floor: Int, now: Date = Date()) throws -> Bool {
        guard E2EEV2Canonical.isOpaque(deviceId), (1...E2EEV2Canonical.maxSequenceNumber).contains(counter),
              let context = try load(now: now) else {
            throw E2EEV2NotificationContextStoreError.invalidContext
        }
        return try Self.shownLock.withLock {
            var counters = try shown(conversationId, context: context)?.counters ?? [:]
            guard counter > max(floor, counters[deviceId] ?? 0),
                  counters[deviceId] != nil || counters.count < E2EEV2NotificationConversation.maxSigningKeys else {
                return false
            }
            counters[deviceId] = counter
            let record = Shown(
                version: Shown.currentVersion, ownerScopeId: context.ownerScopeId, sessionId: context.sessionId,
                counters: counters
            )
            guard let raw = String(data: try JSONEncoder().encode(record), encoding: .utf8) else {
                throw E2EEV2NotificationContextStoreError.invalidRecord
            }
            try tokenStore.set(raw, for: Self.shownKey(conversationId), accessibility: .afterFirstUnlock)
            return true
        }
    }

    /// L'entrée seule, avant que l'app change l'état de la conversation : ce
    /// que l'extension a déjà montré reste retenu.
    func removeConversation(_ conversationId: String) throws {
        try tokenStore.remove(Self.conversationKey(conversationId))
    }

    /// L'entrée et ce que l'extension en a montré : conversation quittée.
    func forgetConversation(_ conversationId: String) throws {
        try tokenStore.remove(Self.conversationKey(conversationId))
        try Self.shownLock.withLock { try tokenStore.remove(Self.shownKey(conversationId)) }
    }

    /// Retire les entrées qui ne servent plus (autre compte ou session,
    /// illisibles, trop vieilles) ; au lancement de l'app et après chaque
    /// écriture.
    func prune(now: Date = Date()) throws {
        guard let context = try load(now: now) else { return }
        pruneEntries(keeping: nil, context: context, now: now)
    }

    func revoke() throws {
        var markerRevoked = false
        do { try activationStore.revoke(); markerRevoked = true } catch { /* Keychain deletion remains an alternative. */ }
        // Tout le service dédié d'un coup ; sinon chaque élément, l'un sans
        // dépendre de l'autre. Le marqueur révoqué suffit à les rendre muets,
        // et la prochaine activation les efface avant tout.
        do {
            try tokenStore.removeAll()
        } catch {
            do { try purgeEntries(includingContext: true) } catch { if !markerRevoked { throw error } }
        }
    }

    /// Efface entrées, comptes de l'extension et ancien contexte v1 ; chaque
    /// suppression est tentée, la première erreur remonte ensuite.
    private func purgeEntries(includingContext: Bool = false) throws {
        var firstError: Error?
        var keys = [Self.legacyStorageKey] + (includingContext ? [Self.storageKey] : [])
        for prefix in [Self.conversationPrefix, Self.shownPrefix] {
            do { keys += try tokenStore.keys(withPrefix: prefix) } catch { firstError = firstError ?? error }
        }
        for key in keys {
            do { try tokenStore.remove(key) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// Entrées d'un autre compte ou d'une autre session, illisibles ou trop
    /// vieilles : elles ne servent plus, leurs clés partent (au mieux).
    private func pruneEntries(keeping kept: String?, context: E2EEV2NotificationContext, now: Date) {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        for key in (try? tokenStore.keys(withPrefix: Self.conversationPrefix)) ?? [] where key != kept {
            let entry = (try? tokenStore.string(for: key))
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(E2EEV2NotificationConversation.self, from: $0) }
            let usable = entry.map {
                $0.isStructurallyValid && $0.ownerScopeId == context.ownerScopeId &&
                    $0.sessionId == context.sessionId && $0.isFresh(nowMs: nowMs)
            } ?? false
            if !usable { try? tokenStore.remove(key) }
        }
    }

    private func shown(_ conversationId: String, context: E2EEV2NotificationContext) throws -> Shown? {
        guard let raw = try tokenStore.string(for: Self.shownKey(conversationId)),
              raw.utf8.count <= 64 * 1_024, let data = raw.data(using: .utf8),
              let record = try? JSONDecoder().decode(Shown.self, from: data),
              record.version == Shown.currentVersion,
              record.ownerScopeId == context.ownerScopeId, record.sessionId == context.sessionId,
              record.counters.count <= E2EEV2NotificationConversation.maxSigningKeys,
              record.counters.allSatisfy({
                  E2EEV2Canonical.isOpaque($0.key) && (1...E2EEV2Canonical.maxSequenceNumber).contains($0.value)
              }) else { return nil }
        return record
    }

    private static func conversationKey(_ conversationId: String) -> String {
        conversationPrefix + digest(conversationId)
    }

    private static func shownKey(_ conversationId: String) -> String {
        shownPrefix + digest(conversationId)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
