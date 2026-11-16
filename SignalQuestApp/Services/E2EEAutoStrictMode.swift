import Foundation

/// Mode renforcé (E2EE-AUTO §6, retiré par l'amendement SD1) : l'app n'y met plus
/// le compte. Elle garde seulement la sortie, l'entrée `MODE NORMAL` signée, pour un
/// compte que le journal vérifié dit encore `STRICT`. Les règles reprises ici sont
/// celles du lecteur (§3.2) : l'app ne propose pas ce que le journal refuserait ensuite.
enum E2EEAutoStrictMode {
    static let path = "/api/e2ee/auto/mode"

    enum Refusal: Equatable, Sendable {
        /// Cet appareil n'est pas `ACTIVE` (en attente, révoqué ou absent du journal).
        case notActive
        /// Le compte est déjà en `NORMAL`.
        case unchanged
        /// Inscrit depuis moins de 24 h (§3.2, ancienneté depuis l'`ADD` ou l'`ADD_PENDING`).
        case tooRecent(eligibleAtMs: Int64)
    }

    /// Sortie du mode renforcé : `MODE NORMAL`, sans condition de deux appareils.
    static func refusal(account: E2EEAutoLog.AccountState, deviceId: String, nowMs: Int64) -> Refusal? {
        guard let device = account.devices[deviceId], device.status == .active else { return .notActive }
        guard account.mode == .strict else { return .unchanged }
        let eligibleAtMs = device.addedAtMs + E2EEAutoLog.signerMinAgeMs
        return nowMs >= eligibleAtMs ? nil : .tooRecent(eligibleAtMs: eligibleAtMs)
    }

    static func payload(userId: String, prevUserEntryHash: String, signerDeviceId: String, mode: E2EEAutoLog.Mode) -> String {
        E2EEAutoLog.Payload.mode(userId: userId, prevUserEntryHash: prevUserEntryHash, signerDeviceId: signerDeviceId, mode: mode)
    }

    /// Réponse : l'entrée `MODE` sur l'état signé, par cet appareil, signée par sa clé.
    static func parse(
        _ data: Data, userId: String, prevUserEntryHash: String, signerDeviceId: String, mode: E2EEAutoLog.Mode, signingKeyB64: String
    ) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let (entry, detail) = E2EEAutoEnrollmentContract.writtenEntry(object),
              case .mode(let writtenSigner, let writtenMode, let signatureB64) = detail,
              entry.op == .mode, entry.userId == userId, entry.prevUserEntryHash == prevUserEntryHash,
              writtenSigner == signerDeviceId, writtenMode == mode else { return false }
        return E2EEAutoLog.verify(
            publicKeyB64: signingKeyB64,
            payload: payload(userId: userId, prevUserEntryHash: prevUserEntryHash, signerDeviceId: signerDeviceId, mode: mode),
            signatureB64: signatureB64
        )
    }
}

/// Activation d'un appareil en attente (§3.1, §5.3 « Servir », §6) : l'appui
/// « C'est moi » signe la charge `SQ-E2EE-AUTO-ACTIVATE` et l'envoie dans le
/// `fulfil`, avec ou sans HK. Le serveur écrit l'`ACTIVATE` dans la même
/// transaction et le renvoie ; l'app ne le croit qu'après l'avoir vérifié.
enum E2EEAutoActivationContract {
    enum Refusal: Equatable, Sendable {
        /// L'approbateur n'est pas `ACTIVE`.
        case approverNotActive
        /// L'approbateur est inscrit depuis moins de 24 h (§3.2).
        case approverTooRecent(eligibleAtMs: Int64)
        /// La cible n'est pas en attente dans le journal vérifié (déjà active, révoquée ou inconnue).
        case notPending
    }

    static func refusal(account: E2EEAutoLog.AccountState, approverDeviceId: String, deviceId: String, nowMs: Int64) -> Refusal? {
        guard let approver = account.devices[approverDeviceId], approver.status == .active else { return .approverNotActive }
        guard account.devices[deviceId]?.status == .pending else { return .notPending }
        let eligibleAtMs = approver.addedAtMs + E2EEAutoLog.signerMinAgeMs
        return nowMs >= eligibleAtMs ? nil : .approverTooRecent(eligibleAtMs: eligibleAtMs)
    }

    /// La charge recopie à l'identique la plateforme, les deux clés et la `keyVersion` de l'appareil en attente.
    static func payload(userId: String, prevUserEntryHash: String, approverDeviceId: String, device: E2EEAutoLog.DeviceState) -> String {
        E2EEAutoLog.Payload.activate(
            userId: userId, prevUserEntryHash: prevUserEntryHash, approverDeviceId: approverDeviceId, deviceId: device.deviceId,
            identityKeyB64: device.identityKeyB64, signingKeyB64: device.signingKeyB64, keyVersion: device.keyVersion
        )
    }

    /// Objet `activation` du `fulfil`, signé sur la dernière entrée vérifiée du compte.
    static func activation(
        account: E2EEAutoLog.AccountState, approverDeviceId: String, deviceId: String, sign: (Data) throws -> Data
    ) throws -> [String: String]? {
        guard let device = account.devices[deviceId], device.status == .pending,
              let prevUserEntryHash = account.lastEntryHash else { return nil }
        let text = payload(userId: account.userId, prevUserEntryHash: prevUserEntryHash, approverDeviceId: approverDeviceId, device: device)
        return ["prevUserEntryHash": prevUserEntryHash, "signatureB64": try sign(Data(text.utf8)).base64EncodedString()]
    }

    /// `activation` de la réponse du `fulfil` : l'`ACTIVATE` de cet appareil en
    /// attente, sur l'état signé, par cet approbateur, signé par sa clé.
    static func parseWritten(
        _ object: [String: Any], account: E2EEAutoLog.AccountState, prevUserEntryHash: String,
        approverDeviceId: String, deviceId: String
    ) -> Bool {
        guard let device = account.devices[deviceId], let approver = account.devices[approverDeviceId],
              let (entry, detail) = E2EEAutoEnrollmentContract.writtenEntry(object),
              case .activate(let writtenApprover, let signatureB64) = detail,
              entry.op == .activate, entry.userId == account.userId, entry.prevUserEntryHash == prevUserEntryHash,
              entry.deviceId == deviceId, writtenApprover == approverDeviceId, entry.platform == device.platform.rawValue,
              entry.identityKeyB64 == device.identityKeyB64, entry.signingKeyB64 == device.signingKeyB64,
              entry.keyVersion == String(device.keyVersion) else { return false }
        return E2EEAutoLog.verify(
            publicKeyB64: approver.signingKeyB64,
            payload: payload(userId: account.userId, prevUserEntryHash: prevUserEntryHash, approverDeviceId: approverDeviceId, device: device),
            signatureB64: signatureB64
        )
    }
}
