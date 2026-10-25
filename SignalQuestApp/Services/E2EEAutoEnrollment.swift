import Foundation

/// Inscription automatique de l'appareil au journal (E2EE-AUTO §4.1) et son
/// cycle de vie (§4.3) : avec les clés v2 existantes, sans mot de passe ni
/// jeton Apple gardé en mémoire, et sans approbation par un autre appareil.
/// Le serveur ne fait foi de rien : seule la relecture du journal vérifié dit
/// si l'appareil est inscrit, en attente, révoqué, ou si sa clé a tourné.
enum E2EEAutoEnrollmentContract {
    static let registerPath = "/api/e2ee/auto/devices"

    static func rotatePath(deviceId: String) -> String { "/api/e2ee/auto/devices/\(deviceId)/rotate" }

    /// Libellé tiré de la plateforme, sans nom ni numéro de version (§4.1) :
    /// il sert à reconnaître son appareil, il ne prouve rien.
    static func label(isPad: Bool) -> String { isPad ? "iPad" : "iPhone" }

    static func registrationBody(device: E2EEV2DeviceDescriptor, label: String, historyKeyPresent: Bool) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "deviceId": device.deviceId, "platform": device.platform,
            "identityKeyB64": device.publicIdentityKeyB64, "signingKeyB64": device.publicSigningKeyB64,
            "keyVersion": device.keyVersion, "label": label, "historyKey": historyKeyPresent ? "present" : "absent",
        ] as [String: Any], options: [.sortedKeys])
    }

    enum Status: String, Equatable, Sendable {
        case active = "ACTIVE"
        case pending = "PENDING"
    }

    struct Registration: Equatable, Sendable {
        let status: Status
        let entry: E2EEAutoLog.Entry
    }

    /// Réponse d'inscription : l'entrée doit être l'`ADD` (ou l'`ADD_PENDING` en
    /// mode renforcé) de cet appareil, avec ses deux clés, et son maillon doit la porter.
    static func parseRegistration(_ data: Data, userId: String, device: E2EEV2DeviceDescriptor) -> Registration? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = (object["status"] as? String).flatMap(Status.init(rawValue:)),
              let (entry, detail) = writtenEntry(object),
              entry.userId == userId, entry.deviceId == device.deviceId,
              entry.platform == device.platform,
              entry.identityKeyB64 == device.publicIdentityKeyB64, entry.signingKeyB64 == device.publicSigningKeyB64,
              entry.keyVersion == String(device.keyVersion) else { return nil }
        switch (status, detail) {
        case (.active, .add(genesis: false)), (.pending, .addPending): return Registration(status: status, entry: entry)
        default: return nil
        }
    }

    /// Charge signée d'une rotation (§3.1) : l'état du compte au `prevUserEntryHash` vérifié.
    static func rotationPayload(
        userId: String, prevUserEntryHash: String, rotation: E2EEV2DeviceIdentityStore.AgreementKeyRotation
    ) -> String {
        E2EEAutoLog.Payload.rotate(
            userId: userId, prevUserEntryHash: prevUserEntryHash, deviceId: rotation.deviceId,
            newIdentityKeyB64: rotation.identityKeyB64, keyVersion: rotation.keyVersion
        )
    }

    static func rotationBody(
        prevUserEntryHash: String, rotation: E2EEV2DeviceIdentityStore.AgreementKeyRotation, signatureB64: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "prevUserEntryHash": prevUserEntryHash, "identityKeyB64": rotation.identityKeyB64,
            "keyVersion": rotation.keyVersion, "signatureB64": signatureB64,
        ] as [String: Any], options: [.sortedKeys])
    }

    /// Réponse de rotation : le `ROTATE` de cet appareil, sur l'état signé, signé par sa clé.
    static func parseRotation(
        _ data: Data, userId: String, prevUserEntryHash: String,
        rotation: E2EEV2DeviceIdentityStore.AgreementKeyRotation, signingKeyB64: String
    ) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let (entry, detail) = writtenEntry(object), case .rotate(let signatureB64) = detail,
              entry.userId == userId, entry.prevUserEntryHash == prevUserEntryHash, entry.deviceId == rotation.deviceId,
              entry.identityKeyB64 == rotation.identityKeyB64, entry.keyVersion == String(rotation.keyVersion) else { return false }
        return E2EEAutoLog.verify(
            publicKeyB64: signingKeyB64,
            payload: rotationPayload(userId: userId, prevUserEntryHash: prevUserEntryHash, rotation: rotation),
            signatureB64: signatureB64
        )
    }

    /// `entry` et `link` en textes bruts, `head` présente : le maillon porte l'entrée.
    private static func writtenEntry(_ object: [String: Any]) -> (E2EEAutoLog.Entry, E2EEAutoLog.Detail)? {
        guard let entryText = object["entry"] as? String, let linkText = object["link"] as? String,
              let head = object["head"] as? [String: Any], head["text"] is String, head["signatureB64"] is String,
              let parsed = E2EEAutoLog.parseEntry(entryText), let link = E2EEAutoLog.parseLink(linkText),
              link.kind == .entry, !link.genesis, link.seq == parsed.entry.seq, link.hash == E2EEAutoLog.digest(entryText)
        else { return nil }
        return parsed
    }
}

/// Ce que fait l'app d'un refus du serveur (§4.1, §4.3).
enum E2EEAutoEnrollmentPolicy {
    enum Action: Equatable, Sendable {
        /// Nouveau `deviceId` et nouvelles clés : clés refusées, ou appareil retiré pour inactivité.
        case newIdentity
        /// Appareil révoqué (§4.3) : purge, et aucune réinscription avant une nouvelle connexion.
        case revoked(E2EEAutoLog.RevokeReason?)
        case accountDeleted
        case rereadAndResign
        case updateRequired
        case reauthenticate
        case retryLater
        case failed
    }

    static func action(for failure: E2EEV2TransportFailure, keyVersion: Int = 1) -> Action {
        switch failure.code {
        case "E2EE_DEVICE_KEY_MISMATCH": return .newIdentity
        case "E2EE_DEVICE_REVOKED":
            switch failure.reason.flatMap(E2EEAutoLog.RevokeReason.init(rawValue:)) {
            case .accountDeleted?: return .accountDeleted
            // Seul cas de réinscription sur la session encore valide.
            case .inactive?: return .newIdentity
            case let reason: return .revoked(reason)
            }
        // Appareil v2 inconnu du journal sous une `keyVersion` reprise (révision 7) : il repart de 1.
        case "E2EE_DEVICE_REGISTRATION_INVALID" where keyVersion != 1: return .newIdentity
        case "E2EE_LOG_STALE": return .rereadAndResign
        case "E2EE_UPDATE_REQUIRED": return .updateRequired
        default: break
        }
        switch failure.kind {
        case .activationBlocked where failure.statusCode == 426: return .updateRequired
        case .authentication: return .reauthenticate
        case .retryable, .localState: return .retryLater
        case .activationBlocked, .permanent: return .failed
        }
    }
}

/// Inscription puis rotation, l'état venant toujours du journal vérifié du compte.
actor E2EEAutoEnrollment {
    struct Dependencies: Sendable {
        var userId: String
        var label: String
        var historyKeyPresent: @Sendable () -> Bool = { false }
        /// L'identité v2 de l'appareil, créée si besoin.
        var device: @Sendable () throws -> E2EEV2DeviceDescriptor
        /// Efface l'identité locale : la prochaine lecture en crée une nouvelle.
        var resetDevice: @Sendable () throws -> Void
        var dueRotation: @Sendable () throws -> E2EEV2DeviceIdentityStore.AgreementKeyRotation?
        var activateRotation: @Sendable (E2EEV2DeviceIdentityStore.AgreementKeyRotation) throws -> Void
        var sign: @Sendable (Data) throws -> Data
        var post: @Sendable (_ path: String, _ body: Data) async -> E2EEV2TransportResult<Data>
        /// Maillons relus, puis le journal de son propre compte jusqu'à la tête vérifiée.
        var readOwnAccount: @Sendable () async -> OwnAccount
        /// Révocation retenue pour la connexion en cours (§4.3).
        var revocation: @Sendable () -> Revocation?
        /// Retient la révocation jusqu'à la prochaine connexion de l'utilisateur.
        var recordRevocation: @Sendable (Revocation) throws -> Void
    }

    enum OwnAccount: Equatable, Sendable {
        case verified(E2EEAutoLog.AccountState)
        /// Journal refusé, alerte, ou `404` sur son propre compte (révision 6) : rien n'est écrit.
        case refused
        /// Erreur réseau, `5xx`, page incohérente : l'inscription n'en dépend pas.
        case inconclusive
    }

    struct Revocation: Equatable, Sendable {
        let reason: E2EEAutoLog.RevokeReason?
    }

    enum Outcome: Equatable, Sendable {
        case active(deviceId: String, rotated: Bool)
        case pending(deviceId: String)
        /// Inscrit d'après le serveur ; la relecture du journal le confirmera.
        case registered(deviceId: String, status: E2EEAutoEnrollmentContract.Status)
        /// Identité locale effacée : un nouveau passage, lié à la session d'après, inscrit la nouvelle.
        case identityReplaced
        /// Appareil révoqué : clés purgées, rien jusqu'à une nouvelle connexion.
        case revoked(E2EEAutoLog.RevokeReason?)
        case accountDeleted
        case updateRequired
        case reauthenticate
        case retryLater
        /// Journal du compte refusé par le vérificateur : rien n'est écrit.
        case logRefused
        case failed(String)
    }

    private let dependencies: Dependencies

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func run() async -> Outcome {
        // Avant toute identité : un appareil révoqué n'en recrée pas sur la même connexion.
        if let revocation = dependencies.revocation() { return .revoked(revocation.reason) }
        do {
            let device = try dependencies.device()
            let account: E2EEAutoLog.AccountState?
            switch await dependencies.readOwnAccount() {
            case .verified(let state): account = state
            case .refused: return .logRefused
            case .inconclusive: account = nil
            }
            if let account, let state = account.devices[device.deviceId] {
                switch Self.judge(state, device: device) {
                case .revoked(.accountDeleted?): return .accountDeleted
                case .revoked(.inactive?), .otherKeys: return try replaceIdentity()
                case .revoked(let reason): return try revoke(reason)
                // Un appareil en attente tourne aussi sa clé (révision 7).
                case .active, .pending: return try await rotateIfDue(device: device, account: account)
                }
            }
            switch await dependencies.post(
                E2EEAutoEnrollmentContract.registerPath,
                try E2EEAutoEnrollmentContract.registrationBody(
                    device: device, label: dependencies.label, historyKeyPresent: dependencies.historyKeyPresent()
                )
            ) {
            case .success(let data, _, _):
                guard let registration = E2EEAutoEnrollmentContract.parseRegistration(data, userId: dependencies.userId, device: device) else {
                    return .failed("invalid-e2ee-auto-registration-response")
                }
                return .registered(deviceId: device.deviceId, status: registration.status)
            case .failure(let failure):
                return try refused(E2EEAutoEnrollmentPolicy.action(for: failure, keyVersion: device.keyVersion))
            }
        } catch {
            return .failed("e2ee-auto-device-identity-unavailable")
        }
    }

    enum Judgement: Equatable {
        case active
        case pending
        case revoked(E2EEAutoLog.RevokeReason?)
        /// Même `deviceId` sous d'autres clés : cette identité n'est pas la sienne.
        case otherKeys
    }

    /// L'appareil tel que le journal vérifié le connaît, face à l'identité locale.
    /// Une clé d'accord plus récente que la locale n'est jugée qu'à la rotation.
    static func judge(_ state: E2EEAutoLog.DeviceState, device: E2EEV2DeviceDescriptor) -> Judgement {
        if state.status == .revoked { return .revoked(state.revokeReason) }
        guard state.signingKeyB64 == device.publicSigningKeyB64,
              state.identityKeys.contains(where: { $0.keyVersion == device.keyVersion && $0.identityKeyB64 == device.publicIdentityKeyB64 })
        else { return .otherKeys }
        return state.status == .pending ? .pending : .active
    }

    private func replaceIdentity() throws -> Outcome {
        try dependencies.resetDevice()
        return .identityReplaced
    }

    /// Retenue d'abord : une purge suivie d'une relance ne doit jamais réinscrire l'appareil.
    private func revoke(_ reason: E2EEAutoLog.RevokeReason?) throws -> Outcome {
        try dependencies.recordRevocation(Revocation(reason: reason))
        try dependencies.resetDevice()
        return .revoked(reason)
    }

    private func refused(_ action: E2EEAutoEnrollmentPolicy.Action) throws -> Outcome {
        switch action {
        case .newIdentity: return try replaceIdentity()
        case .revoked(let reason): return try revoke(reason)
        case .accountDeleted: return .accountDeleted
        case .updateRequired: return .updateRequired
        case .reauthenticate: return .reauthenticate
        case .retryLater, .rereadAndResign: return .retryLater
        case .failed: return .failed("e2ee-auto-request-refused")
        }
    }

    private func rotateIfDue(device: E2EEV2DeviceDescriptor, account: E2EEAutoLog.AccountState) async throws -> Outcome {
        let pending = account.devices[device.deviceId]?.status == .pending
        func done(rotated: Bool) -> Outcome { pending ? .pending(deviceId: device.deviceId) : .active(deviceId: device.deviceId, rotated: rotated) }
        guard let rotation = try dependencies.dueRotation() else { return done(rotated: false) }
        var account = account
        for attempt in 0..<2 {
            // Réponse perdue d'une rotation déjà inscrite : le journal porte la nouvelle clé.
            if let state = account.devices[device.deviceId], state.keyVersion == rotation.keyVersion,
               state.identityKeyB64 == rotation.identityKeyB64 {
                try dependencies.activateRotation(rotation)
                return done(rotated: true)
            }
            guard let previous = account.lastEntryHash, account.devices[device.deviceId]?.keyVersion == device.keyVersion else {
                return .failed("e2ee-auto-rotation-state")
            }
            let payload = E2EEAutoEnrollmentContract.rotationPayload(userId: dependencies.userId, prevUserEntryHash: previous, rotation: rotation)
            let signature = try dependencies.sign(Data(payload.utf8)).base64EncodedString()
            switch await dependencies.post(
                E2EEAutoEnrollmentContract.rotatePath(deviceId: device.deviceId),
                try E2EEAutoEnrollmentContract.rotationBody(prevUserEntryHash: previous, rotation: rotation, signatureB64: signature)
            ) {
            case .success(let data, _, _):
                guard E2EEAutoEnrollmentContract.parseRotation(
                    data, userId: dependencies.userId, prevUserEntryHash: previous, rotation: rotation,
                    signingKeyB64: device.publicSigningKeyB64
                ) else { return .failed("invalid-e2ee-auto-rotation-response") }
                try dependencies.activateRotation(rotation)
                return done(rotated: true)
            case .failure(let failure):
                let action = E2EEAutoEnrollmentPolicy.action(for: failure, keyVersion: device.keyVersion)
                // Une autre entrée du compte est passée entre-temps : relire, puis re-signer une fois.
                guard action == .rereadAndResign, attempt == 0 else { return try refused(action) }
                guard case .verified(let state) = await dependencies.readOwnAccount() else { return .retryLater }
                account = state
            }
        }
        return .retryLater
    }
}

/// Révocation retenue (§4.3), liée à la connexion par l'empreinte du cookie :
/// une relance de l'app la garde, seule une nouvelle connexion la lève. Le
/// `sessionId` local ne convient pas : une identité neuve le renouvelle.
enum E2EEAutoRevocationMarker {
    static func key(ownerNamespace: String) -> String { "e2ee-auto-revoked-v1:\(ownerNamespace)" }

    static func read(store: TokenStore, ownerNamespace: String, authToken: String?) -> E2EEAutoEnrollment.Revocation? {
        guard let raw = try? store.string(for: key(ownerNamespace: ownerNamespace)) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let connection = object["connection"] as? String else {
            try? store.remove(key(ownerNamespace: ownerNamespace))
            return nil
        }
        let revocation = E2EEAutoEnrollment.Revocation(reason: (object["reason"] as? String).flatMap(E2EEAutoLog.RevokeReason.init(rawValue:)))
        guard let authToken else { return revocation }
        guard connection == E2EEAutoLog.digest(authToken) else {
            try? store.remove(key(ownerNamespace: ownerNamespace))
            return nil
        }
        return revocation
    }

    static func record(_ revocation: E2EEAutoEnrollment.Revocation, store: TokenStore, ownerNamespace: String, authToken: String?) throws {
        guard let authToken else { throw E2EEV2DeviceIdentityError.unauthenticated }
        var object: [String: Any] = ["connection": E2EEAutoLog.digest(authToken)]
        if let reason = revocation.reason { object["reason"] = reason.rawValue }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try store.set(String(decoding: data, as: UTF8.self), for: key(ownerNamespace: ownerNamespace), accessibility: .afterFirstUnlock)
    }
}

extension E2EEAutoEnrollment {
    /// Inscription de la session courante, derrière l'interrupteur du mode
    /// automatique et la clé du journal épinglée (sans elles : nil).
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        label: String,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        markerStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee")
    ) -> E2EEAutoEnrollment? {
        guard SQFeatures.e2eeAutoLogEnabled, session.ownerScopeId.hasPrefix("user:"),
              let reader = E2EEAutoLogReader.live(session: session, api: api, identityStore: identityStore) else { return nil }
        let owner = session.ownerScopeId, namespace = session.ownerNamespace, userId = String(owner.dropFirst(5))
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        let credentials = api.credentials
        @Sendable func current() throws {
            guard session.isCurrent else { throw E2EEV2DeviceIdentityError.unauthenticated }
        }
        return E2EEAutoEnrollment(Dependencies(
            userId: userId, label: label,
            device: { try current(); return try identityStore.loadOrCreate(ownerNamespace: namespace) },
            resetDevice: { try current(); try identityStore.reset() },
            dueRotation: {
                try current()
                return try identityStore.agreementKeyRotation(ownerNamespace: namespace, nowMs: Int64(Date().timeIntervalSince1970 * 1_000))
            },
            activateRotation: { rotation in
                try current()
                try identityStore.activateAgreementKey(rotation, ownerNamespace: namespace, nowMs: Int64(Date().timeIntervalSince1970 * 1_000))
            },
            sign: { try identityStore.sign(canonicalRequest: $0, ownerNamespace: namespace) },
            post: { path, body in
                await transport.postJSON(path: path, body: body, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle)
            },
            readOwnAccount: {
                do {
                    if case .alert = try await reader.refreshLinks() { return .refused }
                    guard case .success(let state)? = try await reader.account(userId) else { return .refused }
                    return .verified(state)
                } catch {
                    return .inconclusive
                }
            },
            revocation: {
                E2EEAutoRevocationMarker.read(store: markerStore, ownerNamespace: namespace, authToken: credentials.accessToken())
            },
            recordRevocation: { revocation in
                try E2EEAutoRevocationMarker.record(revocation, store: markerStore, ownerNamespace: namespace, authToken: credentials.accessToken())
            }
        ))
    }

    /// Passages pour la session courante. Une identité neuve renouvelle la
    /// session locale (contexte de notification) : elle est donc créée avant de
    /// lier le passage, et une identité remplacée en relance un, une seule fois.
    static func runLive(
        api: APIClient,
        label: String,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        markerStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee")
    ) async -> Outcome? {
        guard SQFeatures.e2eeAutoLogEnabled, E2EEAutoLogReader.productionLogKeys != nil else { return nil }
        var outcome: Outcome?
        for _ in 0..<2 {
            guard let scope = LocalAccountScope.sessionSnapshot() else { return outcome }
            if let revocation = E2EEAutoRevocationMarker.read(
                store: markerStore, ownerNamespace: scope.ownerNamespace, authToken: api.credentials.accessToken()
            ) { return .revoked(revocation.reason) }
            _ = try? identityStore.loadOrCreate(ownerNamespace: scope.ownerNamespace)
            guard let session = LocalAccountScope.sessionSnapshot(), session.ownerScopeId == scope.ownerScopeId,
                  let enrollment = live(session: session, api: api, label: label, identityStore: identityStore, markerStore: markerStore)
            else { return outcome }
            outcome = await enrollment.run()
            guard outcome == .identityReplaced else { return outcome }
        }
        return outcome
    }
}

extension E2EEAutoEnrollment.Outcome {
    /// Étape pour la trace, sans identifiant.
    var traceStep: String {
        switch self {
        case .active(_, let rotated): return rotated ? "active-rotated" : "active"
        case .pending: return "pending"
        case .registered(_, let status): return "registered-\(status.rawValue.lowercased())"
        case .identityReplaced: return "identity-replaced"
        case .revoked(let reason): return "revoked-\(reason?.rawValue.lowercased() ?? "unknown")"
        case .accountDeleted: return "account-deleted"
        case .updateRequired: return "update-required"
        case .reauthenticate: return "reauthenticate"
        case .retryLater: return "retry-later"
        case .logRefused: return "log-refused"
        case .failed(let reason): return reason
        }
    }
}
