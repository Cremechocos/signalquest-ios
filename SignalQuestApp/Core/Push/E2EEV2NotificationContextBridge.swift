import Foundation
import CoreFoundation

enum E2EEV2NotificationContextRefreshReason: String, Sendable {
    case foreground
    case credentials
    case preferences
    case identity
}

struct E2EEV2NotificationAccountSnapshot: Equatable, Sendable {
    let ownerScopeId: String
    let localOwnerScopeId: String
    let ownerNamespace: String
    let sessionId: String
    let authToken: String
    let expiresAtMs: Int64
    let privacy: E2EEV2NotificationPrivacy
    let noticeAcknowledged: Bool
}

enum E2EEV2NotificationDeviceApproval: Sendable {
    case approved(E2EEV2DeviceDescriptor)
    case notApproved
    case unavailable
}

enum E2EEV2NotificationContextRefreshResult: Equatable, Sendable {
    case dormant
    case noSession
    case awaitingNotice
    case hidden
    case unavailable
    case notApproved
    case stale
    case unchanged
    case ready
}

struct E2EEV2NotificationContextBridgeDependencies: Sendable {
    let snapshot: @Sendable () -> E2EEV2NotificationAccountSnapshot?
    let approval: @Sendable (E2EEV2NotificationAccountSnapshot) async -> E2EEV2NotificationDeviceApproval
    let senderNames: @Sendable (E2EEV2NotificationAccountSnapshot) async -> [String: String]
    let prepare: @Sendable (E2EEV2NotificationAccountSnapshot, E2EEV2DeviceDescriptor, [String: String]) throws -> E2EEV2NotificationContext
    let loadExisting: @Sendable () throws -> E2EEV2NotificationContext?
    let persist: @Sendable (E2EEV2NotificationContext) throws -> Bool
    let revoke: @Sendable () throws -> Void
    var now: @Sendable () -> Date = { Date() }
}

/// Serializes writes while allowing the network to suspend. A later request or
/// account/preference change invalidates all earlier in-flight preparations.
actor E2EEV2NotificationContextCoordinator {
    private var generation: UInt64 = 0

    func refreshRuntime(
        reason: E2EEV2NotificationContextRefreshReason,
        dependencies: E2EEV2NotificationContextBridgeDependencies
    ) async -> E2EEV2NotificationContextRefreshResult {
        guard E2EEV2RuntimeReadGate.enabled else { return .dormant }
        return await refreshContractPreview(reason: reason, dependencies: dependencies)
    }

    func refreshContractPreview(
        reason: E2EEV2NotificationContextRefreshReason,
        dependencies d: E2EEV2NotificationContextBridgeDependencies
    ) async -> E2EEV2NotificationContextRefreshResult {
        generation &+= 1
        let requestedGeneration = generation
        guard let account = d.snapshot() else {
            do { try d.revoke() } catch { return .unavailable }
            return .noSession
        }
        guard account.noticeAcknowledged else {
            do { try d.revoke() } catch { return .unavailable }
            return .awaitingNotice
        }
        guard account.privacy != .hidden else {
            do { try d.revoke() } catch { return .unavailable }
            return .hidden
        }
        guard account.expiresAtMs > Int64(d.now().timeIntervalSince1970 * 1_000) else {
            do { try d.revoke() } catch { return .unavailable }
            return .unavailable
        }
        do {
            // A token refresh may happen while the original whenUnlocked keys are
            // unavailable. Reuse only a mirror from this exact local session.
            // Every envelope fetch still revalidates approval on the server.
            if reason == .credentials, let existing = try d.loadExisting(),
               existing.ownerScopeId == account.ownerScopeId, existing.sessionId == account.sessionId {
                let renewed = E2EEV2NotificationContext(
                    version: 1, revisionId: UUID().uuidString.lowercased(),
                    ownerScopeId: account.ownerScopeId, sessionId: account.sessionId,
                    authToken: account.authToken, expiresAtMs: account.expiresAtMs,
                    descriptor: existing.descriptor, identityPrivateRawB64: existing.identityPrivateRawB64,
                    signingPrivateRawB64: existing.signingPrivateRawB64, privacy: account.privacy,
                    senderNames: existing.senderNames
                )
                return try persistIfCurrent(renewed, account: account, generation: requestedGeneration, dependencies: d)
            }
            let approval = await d.approval(account)
            guard generation == requestedGeneration, d.snapshot() == account else { return .stale }
            let descriptor: E2EEV2DeviceDescriptor
            switch approval {
            case .approved(let value): descriptor = value
            case .notApproved:
                try d.revoke()
                return .notApproved
            case .unavailable:
                return .unavailable
            }
            let names = await d.senderNames(account)
            guard generation == requestedGeneration, d.snapshot() == account else { return .stale }
            let prepared = try d.prepare(account, descriptor, names)
            return try persistIfCurrent(prepared, account: account, generation: requestedGeneration, dependencies: d)
        } catch {
            return .unavailable
        }
    }

    private func persistIfCurrent(
        _ context: E2EEV2NotificationContext,
        account: E2EEV2NotificationAccountSnapshot,
        generation requestedGeneration: UInt64,
        dependencies d: E2EEV2NotificationContextBridgeDependencies
    ) throws -> E2EEV2NotificationContextRefreshResult {
        guard generation == requestedGeneration, d.snapshot() == account else { return .stale }
        guard context.ownerScopeId == account.ownerScopeId, context.sessionId == account.sessionId,
              context.authToken == account.authToken, context.expiresAtMs == account.expiresAtMs,
              context.privacy == account.privacy, context.isValid(now: d.now()) else { return .unavailable }
        if let existing = try d.loadExisting(), existing.hasSameContent(as: context) { return .unchanged }
        guard try d.persist(context) else { return .unavailable }
        guard generation == requestedGeneration, d.snapshot() == account else {
            // No suspension between save and this check: another coordinator write
            // cannot replace this record before cleanup.
            try d.revoke()
            return .stale
        }
        return .ready
    }
}

enum E2EEV2NotificationSessionClaims {
    /// Binding check only, not JWT authentication. The API validates its signature.
    static func expirationMs(token: String, expectedUserId: String, now: Date) -> Int64? {
        guard token.utf8.count <= 16_384, !expectedUserId.isEmpty else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard let data = Data(base64Encoded: payload), data.count <= 12_288,
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              value["userId"] as? String == expectedUserId,
              value["kind"] == nil || value["kind"] as? String == "session",
              value["pendingTwoFactor"] == nil, value["scope"] == nil,
              let exp = value["exp"] as? NSNumber, CFGetTypeID(exp) != CFBooleanGetTypeID(),
              exp.doubleValue.isFinite, exp.doubleValue.rounded(.towardZero) == exp.doubleValue,
              exp.doubleValue > now.timeIntervalSince1970,
              exp.doubleValue < Double(Int64.max / 1_000) else { return nil }
        return exp.int64Value * 1_000
    }
}

final class E2EEV2NotificationContextBridge: @unchecked Sendable {
    private let api: APIClient
    private let identityStore: E2EEV2DeviceIdentityStore
    private let coordinator = E2EEV2NotificationContextCoordinator()

    init(api: APIClient, identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore()) {
        self.api = api
        self.identityStore = identityStore
    }

    func refreshRuntime(reason: E2EEV2NotificationContextRefreshReason) async -> E2EEV2NotificationContextRefreshResult {
        guard E2EEV2RuntimeReadGate.enabled else { return .dormant }
        guard let store = E2EEV2NotificationContextStore.configured() else { return .unavailable }
        return await coordinator.refreshRuntime(reason: reason, dependencies: .init(
            snapshot: { [self] in snapshot() },
            approval: { [self] in await approvedDevice(for: $0) },
            senderNames: { [self] in await senderNames(for: $0) },
            prepare: { [self] account, descriptor, names in
                try identityStore.makeNotificationContextRuntime(account: account, approvedDevice: descriptor, senderNames: names)
            },
            loadExisting: { try store.loadForCredentialRefresh() },
            persist: { try store.saveRuntime($0) },
            revoke: { try store.revoke() }
        ))
    }

    private func snapshot() -> E2EEV2NotificationAccountSnapshot? {
        guard let userId = LocalAccountScope.currentUserId,
              let sessionId = LocalAccountScope.currentSessionId,
              let token = api.credentials.accessToken(),
              let expiry = E2EEV2NotificationSessionClaims.expirationMs(token: token, expectedUserId: userId, now: Date()) else {
            return nil
        }
        let owner = PushOwnerScope.id(for: userId)
        let localOwner = "user:\(userId)"
        guard LocalAccountScope.currentUserId == userId, LocalAccountScope.currentSessionId == sessionId,
              api.credentials.accessToken() == token else { return nil }
        return .init(ownerScopeId: owner, localOwnerScopeId: localOwner,
            ownerNamespace: LocalAccountScope.storageNamespace(for: localOwner), sessionId: sessionId, authToken: token,
            expiresAtMs: expiry, privacy: E2EEV2NotificationPrivacyStore.get(ownerScopeId: owner),
            noticeAcknowledged: E2EEV2NotificationPrivacyStore.isNoticeAcknowledged(ownerScopeId: owner))
    }

    private func approvedDevice(for account: E2EEV2NotificationAccountSnapshot) async -> E2EEV2NotificationDeviceApproval {
        guard snapshot() == account,
              let local = try? identityStore.load(ownerNamespace: account.ownerNamespace) else { return .unavailable }
        let lifecycle = E2EEV2DeviceLifecycleCoordinator(api: api, identityStore: identityStore)
        switch await lifecycle.listDeviceInventory() {
        case .failed: return .unavailable
        case .success(let inventory):
            guard snapshot() == account else { return .unavailable }
            guard inventory.activationEnabled,
                  let remote = inventory.devices.first(where: { $0.descriptor.deviceId == local.deviceId }),
                  remote.status == .approved,
                  remote.descriptor.publicIdentityKeyB64 == local.publicIdentityKeyB64,
                  remote.descriptor.publicSigningKeyB64 == local.publicSigningKeyB64 else { return .notApproved }
            return .approved(remote.descriptor)
        }
    }

    private func senderNames(for account: E2EEV2NotificationAccountSnapshot) async -> [String: String] {
        guard snapshot() == account,
              let response = try? await api.request(APIEndpoint(path: "/api/messages/conversations"), as: ConversationsResponse.self),
              snapshot() == account else { return [:] }
        var names: [String: String] = [:]
        for conversation in response.conversations {
            for participant in conversation.participants where names.count < 500 {
                guard E2EEV2PortableInventoryContract.validOpaqueId(participant.userId) else { continue }
                let user = participant.user
                let label = user.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = (label?.isEmpty == false ? label : user.email.split(separator: "@").first.map(String.init)) ?? ""
                let clean = String(name.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
                if !clean.isEmpty { names[participant.userId] = clean }
            }
        }
        return names
    }
}

enum E2EEV2NotificationContextEvents {
    static let refresh = Notification.Name("SignalQuest.E2EEV2.NotificationContextRefresh.v1")

    static func requestRefresh(_ reason: E2EEV2NotificationContextRefreshReason) {
        NotificationCenter.default.post(name: refresh, object: nil, userInfo: ["reason": reason.rawValue])
    }

    @discardableResult
    static func revoke() -> Bool {
        do { try E2EEV2NotificationContextStore.configured()?.revoke(); return true }
        catch { return false }
    }

    static func identityDidChange(ownerNamespace: String) {
        guard let userId = LocalAccountScope.currentUserId,
              LocalAccountScope.storageNamespace == ownerNamespace else { return }
        LocalAccountScope.invalidateNotificationSession()
        revoke()
        LocalAccountScope.activate(userId: userId)
        E2EEV2NotificationScope.clearPostedNotifications()
        requestRefresh(.identity)
    }
}
