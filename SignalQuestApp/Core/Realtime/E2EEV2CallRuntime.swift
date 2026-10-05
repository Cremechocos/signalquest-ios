import CryptoKit
import Foundation

/// Appel chiffré v2 (§10, E.4) au-dessus de la messagerie v2 : le descripteur
/// que l'appelant signe, les vérifications de l'appelé, et la session LiveKit
/// qui en découle (clé de trame v2, preuves de jonction). Les appareils et
/// l'époque viennent de la chaîne vérifiée gardée ici, jamais du serveur.
/// Fermé tant que le verrou d'appels l'est (`E2EEV2CallRuntimeGate`).
final class E2EEV2CallRuntime: @unchecked Sendable {
    enum Preparation: Equatable, Sendable {
        case prepared(E2EEV2SignedCallDescriptor)
        case runtimeClosed
        case localEpochUnavailable
        case deviceLocked
    }

    enum Verification: Equatable, Sendable {
        case verified(E2EEV2CallDescriptor)
        case refused(E2EEV2CallDescriptorCheck.Failure)
        /// Verrou fermé, ou conversation et appareils illisibles ici.
        case unavailable
    }

    enum SessionFailure: Error, Equatable {
        case runtimeClosed
        case localEpochUnavailable
        case deviceLocked
        case untrusted
    }

    /// Membres et appareils certifiés d'une conversation v2 gardée ; `true` :
    /// la relire d'abord.
    private let members: @Sendable (String, Bool) async -> E2EEV2MessagingRuntime.CallMembers?
    private let identityStore: E2EEV2DeviceIdentityStore
    private let keyStore: E2EEV2EpochKeyStore
    private let stateStore: E2EEV2ConversationStateStore
    private let nonces: E2EEV2CallNonceLedger
    private let contextStore: () -> E2EEV2NotificationContextStore?
    private let now: @Sendable () -> Date
    private let controlPlaneOpen: @Sendable () -> Bool
    private let mediaOpen: @Sendable (URL) -> Bool

    convenience init(messaging: E2EEV2MessagingRuntime) {
        self.init(members: { await messaging.callMembers(conversationId: $0, synchronizing: $1) })
    }

    init(
        members: @escaping @Sendable (String, Bool) async -> E2EEV2MessagingRuntime.CallMembers?,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        keyStore: E2EEV2EpochKeyStore = E2EEV2EpochKeyStore(),
        stateStore: E2EEV2ConversationStateStore = E2EEV2ConversationStateStore(),
        nonces: E2EEV2CallNonceLedger = .shared,
        contextStore: @escaping () -> E2EEV2NotificationContextStore? = { .configured() },
        now: @escaping @Sendable () -> Date = Date.init,
        controlPlaneOpen: @escaping @Sendable () -> Bool = { E2EEV2CallRuntimeGate.allowsControlPlane() },
        mediaOpen: @escaping @Sendable (URL) -> Bool = { E2EEV2CallRuntimeGate.allowsMedia(liveKitURL: $0) }
    ) {
        self.members = members
        self.identityStore = identityStore
        self.keyStore = keyStore
        self.stateStore = stateStore
        self.nonces = nonces
        self.contextStore = contextStore
        self.now = now
        self.controlPlaneOpen = controlPlaneOpen
        self.mediaOpen = mediaOpen
    }

    private var nowMs: Int64 { Int64(now().timeIntervalSince1970 * 1_000) }

    // MARK: Appelant

    /// Ce que l'écran peut proposer sans réseau : verrou ouvert, conversation
    /// v2 ici, époque courante vérifiée et sa clé. L'intersection « appels »
    /// est contrôlée par le serveur à l'initiation (`E2EE_CAPABILITY_MISSING`).
    func canStart(conversationId: String) -> Bool {
        guard controlPlaneOpen(), let session = LocalAccountScope.sessionSnapshot(), session.isCurrent,
              (try? stateStore.isV2(conversationId: conversationId, ownerNamespace: session.ownerNamespace)) == true,
              var epoch = try? E2EEV2VerifiedEpochKeys.current(
                  conversationId: conversationId, ownerNamespace: session.ownerNamespace,
                  keyStore: keyStore, stateStore: stateStore
              ) else { return false }
        epoch.epochKey.resetBytes(in: 0..<epoch.epochKey.count)
        return true
    }

    /// Descripteur signé par cet appareil (§10.1), sur l'époque courante
    /// vérifiée : `callId` et `callNonce` tirés ici, jamais par le serveur.
    func prepareOutgoing(conversationId: String) -> Preparation {
        guard controlPlaneOpen() else { return .runtimeClosed }
        guard let session = LocalAccountScope.sessionSnapshot(), session.isCurrent else { return .localEpochUnavailable }
        let namespace = session.ownerNamespace
        var epoch: E2EEV2StoredEpochKey
        do {
            guard (try stateStore.isV2(conversationId: conversationId, ownerNamespace: namespace)),
                  let current = try E2EEV2VerifiedEpochKeys.current(
                      conversationId: conversationId, ownerNamespace: namespace, keyStore: keyStore, stateStore: stateStore
                  ) else { return .localEpochUnavailable }
            epoch = current
        } catch where E2EEV2DeviceIdentityStore.isLocked(error) {
            return .deviceLocked
        } catch {
            return .localEpochUnavailable
        }
        defer { epoch.epochKey.resetBytes(in: 0..<epoch.epochKey.count) }
        do {
            let deviceId = try identityStore.signingDeviceId(ownerNamespace: namespace)
            let descriptor = try E2EEV2CallDescriptorFactory.make(
                conversationId: conversationId,
                callId: try E2EEV2CallDescriptorFactory.newCallId(),
                callerDeviceId: deviceId,
                epochId: epoch.epochId,
                epochNumber: epoch.epochNumber,
                keyCommitmentB64: epoch.keyCommitmentB64,
                callNonceB64: try E2EEV2CallDescriptorFactory.newCallNonceB64(),
                createdAtMs: nowMs,
                sign: { [identityStore] in try identityStore.sign(canonicalRequest: $0, ownerNamespace: namespace) }
            )
            // Son propre nonce est réservé : un rejeu de ce descripteur vers cet
            // appareil ne vaut que pour cet appel.
            _ = nonces.claim(descriptor.descriptor.callNonceB64, callId: descriptor.descriptor.callId, nowMs: nowMs)
            return .prepared(descriptor)
        } catch where E2EEV2DeviceIdentityStore.isLocked(error) {
            return .deviceLocked
        } catch {
            return .localEpochUnavailable
        }
    }

    /// `E2EE_EPOCH_STALE` à l'initiation : la conversation est relue avant un
    /// nouveau descripteur (nouveau `callNonce`).
    func synchronize(conversationId: String) async {
        _ = await members(conversationId, true)
    }

    // MARK: Appelé

    /// Vérifications de l'appelé (§10.1) : appareil appelant certifié d'un
    /// membre avec « appels vérifiés », signature, 60 secondes pour une
    /// sonnerie, époque la plus récente connue ici, nonce jamais vu pour un
    /// autre appel. Une époque plus récente que la sienne, ou un appareil
    /// inconnu, font relire la conversation une fois.
    func verify(
        _ candidate: E2EEV2SignedCallDescriptor,
        conversationId: String,
        callId: String,
        ringing: Bool
    ) async -> Verification {
        guard controlPlaneOpen() else { return .unavailable }
        var lastFailure: E2EEV2CallDescriptorCheck.Failure?
        for synchronizing in [false, true] {
            guard let members = await self.members(conversationId, synchronizing) else {
                // Conversation pas encore lue ici : elle l'est au second tour.
                if !synchronizing { continue }
                return .unavailable
            }
            // Son propre descripteur renvoyé à cet appareil ne le fait jamais sonner.
            if let own = try? identityStore.signingDeviceId(ownerNamespace: members.ownerNamespace),
               own == candidate.callerDeviceId {
                return .refused(.untrustedCaller)
            }
            let current = try? stateStore.currentEpoch(conversationId: conversationId, ownerNamespace: members.ownerNamespace)
            let checkedAt = nowMs
            let result = E2EEV2CallDescriptorCheck.verify(
                candidate,
                conversationId: conversationId,
                callId: callId,
                callerSigningKey: { deviceId in Self.callSigningKey(deviceId: deviceId, in: members, nowMs: checkedAt) },
                // Une époque gardée sans identifiant ni engagement n'est la « plus récente » de rien.
                latestEpoch: current.flatMap { epoch in
                    guard let epochId = epoch.epochId, let commitment = epoch.keyCommitmentB64 else { return nil }
                    return .init(epochId: epochId, epochNumber: epoch.epochNumber, keyCommitmentB64: commitment)
                },
                nonces: nonces,
                nowMs: checkedAt,
                ringing: ringing
            )
            switch result {
            case .success(let descriptor):
                return .verified(descriptor)
            case .failure(.notLatestEpoch) where !synchronizing
                && candidate.descriptor.epochNumber > (current?.epochNumber ?? 0):
                lastFailure = .notLatestEpoch
            case .failure(.untrustedCaller) where !synchronizing:
                lastFailure = .untrustedCaller
            case .failure(let failure):
                return .refused(failure)
            }
        }
        return .refused(lastFailure ?? .untrustedCaller)
    }

    // MARK: Média

    /// Session LiveKit d'un appel vérifié : clé de trame v2 tirée de l'époque
    /// que le descripteur désigne (§10.2), preuves de jonction signées par cet
    /// appareil et vérifiées contre les appareils certifiés des membres (§10.4).
    func liveKitSession(
        for candidate: E2EEV2SignedCallDescriptor,
        liveKitURL: URL
    ) async throws -> E2EEV2LiveKitSession {
        guard mediaOpen(liveKitURL) else { throw SessionFailure.runtimeClosed }
        let descriptor = candidate.descriptor
        guard let members = await self.members(descriptor.conversationId, false) else {
            throw SessionFailure.localEpochUnavailable
        }
        let namespace = members.ownerNamespace
        var locked = false
        guard var epoch = E2EEV2CallBridge.callEpoch(
            conversationId: descriptor.conversationId, epochNumber: descriptor.epochNumber, ownerNamespace: namespace,
            keyStore: keyStore, stateStore: stateStore, contextStore: contextStore(), locked: &locked
        ) else { throw locked ? SessionFailure.deviceLocked : SessionFailure.localEpochUnavailable }
        defer { epoch.epochKey.resetBytes(in: 0..<epoch.epochKey.count) }
        guard epoch.epochId == descriptor.epochId, epoch.keyCommitmentB64 == descriptor.keyCommitmentB64 else {
            throw SessionFailure.untrusted
        }
        let deviceId: String
        do {
            deviceId = try identityStore.signingDeviceId(ownerNamespace: namespace)
        } catch where E2EEV2DeviceIdentityStore.isLocked(error) {
            throw SessionFailure.deviceLocked
        }
        let devices = members.devices, joinedAtMs = nowMs
        let join = E2EEV2CallJoinConfiguration(
            context: .init(
                conversationId: descriptor.conversationId, callId: descriptor.callId,
                callNonceB64: descriptor.callNonceB64, createdAtMs: descriptor.createdAtMs
            ),
            userId: members.ownUserId,
            deviceId: deviceId,
            sign: { [identityStore] in try identityStore.sign(canonicalRequest: $0, ownerNamespace: namespace) },
            deviceSigningKey: { userId, deviceId in
                guard devices.device(userId: userId, deviceId: deviceId) != nil else { return nil }
                return Self.callSigningKey(deviceId: deviceId, in: members, nowMs: joinedAtMs)
            }
        )
        do {
            return try E2EEV2LiveKitSession.make(epochKey: epoch.epochKey, descriptor: descriptor, join: join)
        } catch {
            throw SessionFailure.untrusted
        }
    }

    /// Clé de l'appareil appelant : certifié, d'un membre, doté de « appels
    /// vérifiés » (§10.0), et pas un navigateur exclu de la conversation.
    static func callSigningKey(
        deviceId: String,
        in members: E2EEV2MessagingRuntime.CallMembers,
        nowMs: Int64
    ) -> P256.Signing.PublicKey? {
        guard let device = members.devices.device(deviceId: deviceId), members.members.contains(device.userId),
              device.supports("calls", nowMs: nowMs),
              !(members.excludesWeb && device.platform == "web") else { return nil }
        return device.signingKey
    }
}

/// Jetons push d'un appareil v2 (E.1, v0.4.19) : la sonnerie d'un appel
/// chiffré ne vise qu'eux. La requête, signée, lie aussi la session de
/// connexion à cet appareil, sans quoi `pending` ne montre aucun appel
/// chiffré. Le corps remplace l'ensemble : iOS ne lie que ses jetons APNs,
/// jamais FCM, pour ne pas sonner deux fois.
enum E2EEV2CallPushTokens {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedAPNs: String?

    /// Un nouveau jeton APNs : l'enregistrement repart.
    static let didChange = Notification.Name("SignalQuest.E2EEV2.CallPushTokensDidChange.v1")

    /// Jeton APNs de l'app, en hexadécimal, remis par `AppDelegate`.
    static var apnsToken: String? {
        get { lock.withLock { storedAPNs } }
        set {
            let changed = lock.withLock { () -> Bool in
                defer { storedAPNs = newValue }
                return storedAPNs != newValue
            }
            if changed { NotificationCenter.default.post(name: didChange, object: nil) }
        }
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// Environnement APNs du build : développement en Debug, production pour
    /// TestFlight et l'App Store.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// `{apnsVoipToken?, apnsToken?, environment}` ; nil sans aucun jeton
    /// valide (hexadécimal, 32 à 512 caractères).
    static func body(voipToken: String?, apnsToken: String?, environment: String = environment) -> Data? {
        func valid(_ token: String?) -> String? {
            guard let token, (32...512).contains(token.count),
                  token.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else { return nil }
            return token
        }
        var object: [String: E2EEV2JSON] = ["environment": .string(environment)]
        if let voip = valid(voipToken) { object["apnsVoipToken"] = .string(voip) }
        if let apns = valid(apnsToken) { object["apnsToken"] = .string(apns) }
        guard object.count > 1 else { return nil }
        return E2EEV2CanonicalJSON.encode(.object(object))
    }
}

/// Publie, à chaque connexion et à chaque nouveau jeton, ce qu'il faut à un
/// appareil iOS pour sonner : son document de capacités (« appels »), puis
/// ses jetons APNs. Un seul envoi à la fois, toujours avec le dernier état
/// connu des deux jetons, puisque chaque envoi remplace l'ensemble. Rien tant
/// que le verrou d'appels est fermé, sinon retirer « appels » s'il avait été
/// annoncé.
final class E2EEV2CallPushRegistrar: @unchecked Sendable {
    private let api: APIClient
    private let identityStore: E2EEV2DeviceIdentityStore
    private let capabilities: E2EEV2CapabilitiesPublicationStore
    private let open: @Sendable () -> Bool
    private let lock = NSLock()
    private var latestVoipToken: String?
    private var chain: Task<Bool, Never>?

    init(
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        capabilities: E2EEV2CapabilitiesPublicationStore = E2EEV2CapabilitiesPublicationStore(),
        open: @escaping @Sendable () -> Bool = { E2EEV2CallRuntimeGate.allowsControlPlane() }
    ) {
        self.api = api
        self.identityStore = identityStore
        self.capabilities = capabilities
        self.open = open
    }

    /// `voipToken` nil : le dernier jeton VoIP connu est gardé.
    @discardableResult
    func register(voipToken: String?) async -> Bool {
        let task: Task<Bool, Never> = lock.withLock {
            if let voipToken { latestVoipToken = voipToken }
            let previous = chain
            let next = Task { [weak self] () -> Bool in
                _ = await previous?.value
                return await self?.send() ?? false
            }
            chain = next
            return next
        }
        return await task.value
    }

    private func send() async -> Bool {
        guard let session = LocalAccountScope.sessionSnapshot(), session.isCurrent else { return false }
        let lifecycle = E2EEV2DeviceLifecycleCoordinator(api: api, identityStore: identityStore)
        guard open() else {
            // Verrou refermé après une annonce : « appels » est retiré.
            if let stored = try? capabilities.load(ownerNamespace: session.ownerNamespace),
               let document = try? E2EEV2CapabilitiesDocument.parse(document: stored.document),
               document.features.contains("calls") {
                _ = await lifecycle.publishCapabilitiesIfNeeded()
            }
            return false
        }
        guard let deviceId = try? identityStore.signingDeviceId(ownerNamespace: session.ownerNamespace) else { return false }
        // « Appels vérifiés » publié d'abord : l'intersection du serveur le lit
        // pour choisir les appareils qui sonnent.
        _ = await lifecycle.publishCapabilitiesIfNeeded()
        guard session.isCurrent else { return false }
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        let voip = lock.withLock { latestVoipToken }
        guard let body = E2EEV2CallPushTokens.body(voipToken: voip, apnsToken: E2EEV2CallPushTokens.apnsToken) else {
            // Aucun jeton encore : une lecture signée qui consomme sa preuve lie
            // quand même la session à l'appareil (E.1), pour que `pending` montre
            // les appels chiffrés.
            if case .success = await transport.getJSON(
                path: "/api/e2ee/v2/epoch-rotation-requirements", expectedOwnerScopeId: session.ownerScopeId,
                capabilitySet: .message
            ) { return true }
            return false
        }
        let result = await transport.putJSON(
            path: "/api/e2ee/v2/devices/\(deviceId)/push-tokens",
            body: body,
            expectedOwnerScopeId: session.ownerScopeId,
            capabilitySet: .calls
        )
        if case .success = result { return true }
        return false
    }
}
