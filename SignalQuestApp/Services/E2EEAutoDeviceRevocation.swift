import Foundation

/// Révocation d'un appareil du compte (E2EE-AUTO §4.4) : requête signée par cet
/// appareil, le révocateur, sur la charge `SQ-E2EE-AUTO-REVOKE`. Comme pour
/// l'inscription, le serveur ne fait foi de rien : la réponse doit être le
/// `REVOKE` signé ici, et seule la relecture du journal montre l'appareil retiré.
enum E2EEAutoRevocationContract {
    static func revokePath(deviceId: String) -> String { "/api/e2ee/auto/devices/\(deviceId)/revoke" }

    static func payload(userId: String, prevUserEntryHash: String, revokerDeviceId: String, deviceId: String, reason: E2EEAutoLog.RevokeReason) -> String {
        E2EEAutoLog.Payload.revoke(
            userId: userId, prevUserEntryHash: prevUserEntryHash, revokerDeviceId: revokerDeviceId, deviceId: deviceId, reason: reason
        )
    }

    /// Corps exact (révision 8) ; `confirmationToken` hors signature, absent quand il ne sert pas.
    static func body(
        prevUserEntryHash: String, reason: E2EEAutoLog.RevokeReason, signatureB64: String, confirmationToken: String? = nil
    ) throws -> Data {
        var object: [String: Any] = ["prevUserEntryHash": prevUserEntryHash, "reason": reason.rawValue, "signatureB64": signatureB64]
        object["confirmationToken"] = confirmationToken
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Réponse : le `REVOKE` de la cible, sur l'état signé, par ce révocateur, signé par sa clé.
    static func parse(
        _ data: Data, userId: String, prevUserEntryHash: String, revokerDeviceId: String, deviceId: String,
        reason: E2EEAutoLog.RevokeReason, signingKeyB64: String
    ) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let (entry, detail) = E2EEAutoEnrollmentContract.writtenEntry(object),
              case .signedRevoke(let writtenReason, let writtenRevoker, let signatureB64) = detail,
              entry.op == .revoke, entry.userId == userId, entry.prevUserEntryHash == prevUserEntryHash,
              entry.deviceId == deviceId, writtenReason == reason, writtenRevoker == revokerDeviceId else { return false }
        return E2EEAutoLog.verify(
            publicKeyB64: signingKeyB64,
            payload: payload(userId: userId, prevUserEntryHash: prevUserEntryHash, revokerDeviceId: revokerDeviceId, deviceId: deviceId, reason: reason),
            signatureB64: signatureB64
        )
    }
}

actor E2EEAutoDeviceRevocation {
    struct Dependencies: Sendable {
        var userId: String
        var device: @Sendable () throws -> E2EEV2DeviceDescriptor
        var sign: @Sendable (Data) throws -> Data
        var post: @Sendable (_ path: String, _ body: Data, _ clockOffsetMs: Int64) async -> E2EEV2TransportResult<Data>
        var readOwnAccount: @Sendable () async -> E2EEAutoEnrollment.OwnAccount
        /// Auto-révocation écrite : retenue jusqu'à la prochaine connexion, puis clés effacées (§4.3).
        var forgetThisDevice: @Sendable () throws -> Void
        var nowMs: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    }

    enum Outcome: Equatable, Sendable {
        /// `REVOKE` écrit (ou déjà au journal) ; `ownDevice` : la session va être fermée.
        case revoked(ownDevice: Bool)
        /// Garde des 24 h : cet appareil ne révoque encore que lui-même.
        case tooRecent
        /// Cet appareil est en attente (mode renforcé) : il ne révoque rien.
        case notActive
        /// Cible absente du compte, ou `NOT_ME` sur soi-même.
        case notFound
        /// Cet appareil a lui-même été révoqué : l'inscription le purgera.
        case thisDeviceRevoked
        case updateRequired
        case reauthenticate
        case logRefused
        case retryLater
        case failed(String)
    }

    private let dependencies: Dependencies
    private var clockOffsetMs: Int64 = 0

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func revoke(deviceId: String, reason: E2EEAutoLog.RevokeReason) async -> Outcome {
        guard reason.isSigned, E2EEV2Canonical.isOpaque(deviceId) else { return .failed("e2ee-auto-revocation-invalid") }
        let device: E2EEV2DeviceDescriptor
        do { device = try dependencies.device() } catch { return .failed("e2ee-auto-device-unavailable") }
        let ownDevice = deviceId == device.deviceId
        if ownDevice && reason == .notMe { return .notFound }
        var account: E2EEAutoLog.AccountState
        switch await dependencies.readOwnAccount() {
        case .verified(let state): account = state
        case .refused: return .logRefused
        case .inconclusive: return .retryLater
        }
        for _ in 0..<2 {
            // Déjà retirée (réponse perdue, autre appareil) : rien à écrire.
            if account.devices[deviceId]?.status == .revoked { return done(ownDevice: ownDevice) }
            guard account.devices[deviceId] != nil else { return .notFound }
            guard let revoker = account.devices[device.deviceId], revoker.signingKeyB64 == device.publicSigningKeyB64 else { return .retryLater }
            switch revoker.status {
            case .revoked: return .thisDeviceRevoked
            case .pending: return .notActive
            case .active: break
            }
            guard let previous = account.lastEntryHash else { return .failed("e2ee-auto-revocation-state") }
            let payload = E2EEAutoRevocationContract.payload(
                userId: dependencies.userId, prevUserEntryHash: previous, revokerDeviceId: device.deviceId, deviceId: deviceId, reason: reason
            )
            let body: Data
            do {
                let signature = try dependencies.sign(Data(payload.utf8)).base64EncodedString()
                body = try E2EEAutoRevocationContract.body(prevUserEntryHash: previous, reason: reason, signatureB64: signature)
            } catch {
                return .failed("e2ee-auto-revocation-signature")
            }
            switch await post(E2EEAutoRevocationContract.revokePath(deviceId: deviceId), body) {
            case .success(let data, _, _):
                guard E2EEAutoRevocationContract.parse(
                    data, userId: dependencies.userId, prevUserEntryHash: previous, revokerDeviceId: device.deviceId,
                    deviceId: deviceId, reason: reason, signingKeyB64: device.publicSigningKeyB64
                ) else { return .failed("invalid-e2ee-auto-revocation-response") }
                return done(ownDevice: ownDevice)
            case .failure(let failure):
                switch failure.code {
                case "E2EE_DEVICE_TOO_RECENT", "E2EE_REVOKE_CONFIRMATION_INVALID": return .tooRecent
                case "E2EE_DEVICE_NOT_ACTIVE": return .notActive
                case "E2EE_DEVICE_NOT_FOUND": return .notFound
                default: break
                }
                let action = E2EEAutoEnrollmentPolicy.action(for: failure, keyVersion: device.keyVersion)
                switch action {
                case .revoked, .accountDeleted: return .thisDeviceRevoked
                case .updateRequired: return .updateRequired
                case .reauthenticate, .refreshSession: return .reauthenticate
                default: break
                }
                // Une autre entrée est passée, la cible est déjà retirée, ou la requête est
                // peut-être écrite : relire le compte, puis re-signer une seule fois.
                guard failure.code == "E2EE_DEVICE_ALREADY_REVOKED" || action == .rereadAndResign || action == .signerNotFound else {
                    switch action {
                    case .retryLater, .logClosed: return .retryLater
                    default: return .failed("e2ee-auto-revocation-refused")
                    }
                }
                switch await dependencies.readOwnAccount() {
                case .verified(let state): account = state
                case .refused: return .logRefused
                case .inconclusive: return .retryLater
                }
            }
        }
        if account.devices[deviceId]?.status == .revoked { return done(ownDevice: ownDevice) }
        return .retryLater
    }

    /// Un refus d'horodatage donne l'heure du serveur : une seule nouvelle signature (révision 8).
    private func post(_ path: String, _ body: Data) async -> E2EEV2TransportResult<Data> {
        let first = await dependencies.post(path, body, clockOffsetMs)
        guard case .failure(let failure) = first, let serverTimeMs = failure.serverTimeMs else { return first }
        clockOffsetMs = serverTimeMs - dependencies.nowMs()
        return await dependencies.post(path, body, clockOffsetMs)
    }

    /// Auto-révocation : la réinscription demande une nouvelle connexion (§4.3, `USER`).
    private func done(ownDevice: Bool) -> Outcome {
        if ownDevice { try? dependencies.forgetThisDevice() }
        return .revoked(ownDevice: ownDevice)
    }
}

extension E2EEAutoDeviceRevocation {
    /// Révocation pour la session courante, derrière l'interrupteur du mode
    /// automatique et la clé du journal épinglée (sans elles : nil).
    static func live(
        session: LocalAccountSession,
        api: APIClient,
        identityStore: E2EEV2DeviceIdentityStore = E2EEV2DeviceIdentityStore(),
        markerStore: TokenStore = KeychainStore(service: "fr.signalquest.ios.e2ee")
    ) -> E2EEAutoDeviceRevocation? {
        guard SQFeatures.e2eeAutoLogEnabled, session.ownerScopeId.hasPrefix("user:"),
              let reader = E2EEAutoLogReader.live(session: session, api: api, identityStore: identityStore) else { return nil }
        let owner = session.ownerScopeId, namespace = session.ownerNamespace, userId = String(owner.dropFirst(5))
        let transport = E2EEV2APITransport(api: api, identityStore: identityStore).bound(to: session)
        let credentials = api.credentials
        return E2EEAutoDeviceRevocation(Dependencies(
            userId: userId,
            device: {
                guard session.isCurrent, let device = try identityStore.load(ownerNamespace: namespace) else {
                    throw E2EEV2DeviceIdentityError.unauthenticated
                }
                return device
            },
            sign: { try identityStore.sign(canonicalRequest: $0, ownerNamespace: namespace) },
            post: { path, body, clockOffsetMs in
                await transport.postJSON(
                    path: path, body: body, expectedOwnerScopeId: owner, capabilitySet: .deviceLifecycle, clockOffsetMs: clockOffsetMs
                )
            },
            readOwnAccount: { await E2EEAutoDeviceRevocation.ownAccount(reader: reader, userId: userId) },
            forgetThisDevice: {
                try E2EEAutoRevocationMarker.record(
                    .init(reason: .user), store: markerStore, ownerNamespace: namespace, authToken: credentials.accessToken()
                )
                try identityStore.reset()
            }
        ))
    }

    /// Maillons relus, puis son propre compte jusqu'à la tête vérifiée. Les
    /// appareils apparus depuis la lecture précédente partent comme avec
    /// l'annuaire : rotation (§7) et alerte « Nouvel appareil » (§4.2).
    static func ownAccount(reader: E2EEAutoLogReader, userId: String) async -> E2EEAutoEnrollment.OwnAccount {
        do {
            if case .alert = try await reader.refreshLinks() { return .refused }
            guard case .success(let state)? = try await reader.account(userId) else { return .refused }
            let added = await reader.takeAddedDevices()
            if !added.isEmpty { E2EEAutoDeviceEvents.post(ownerScopeId: reader.ownerScopeId, added: added) }
            return .verified(state)
        } catch {
            return .inconclusive
        }
    }
}
