import Foundation

/// Mode renforcé (E2EE-AUTO §6) : en `STRICT`, un nouvel appareil s'inscrit en
/// attente (`ADD_PENDING`) et ne devient actif que par « C'est moi » sur un
/// appareil actif. Les règles reprises ici sont celles du lecteur (§3.2) : l'app
/// ne propose pas ce que le journal refuserait ensuite.
enum E2EEAutoStrictMode {
    static let path = "/api/e2ee/auto/mode"

    enum Refusal: Equatable, Sendable {
        /// Cet appareil n'est pas `ACTIVE` (en attente, révoqué ou absent du journal).
        case notActive
        /// Le mode demandé est déjà celui du compte.
        case unchanged
        /// Inscrit depuis moins de 24 h (§3.2, ancienneté depuis l'`ADD` ou l'`ADD_PENDING`).
        case tooRecent(eligibleAtMs: Int64)
        /// `STRICT` sans un second appareil actif : personne ne pourrait activer un appareil en attente.
        case needsTwoDevices
    }

    static func refusal(account: E2EEAutoLog.AccountState, deviceId: String, mode: E2EEAutoLog.Mode, nowMs: Int64) -> Refusal? {
        guard let device = account.devices[deviceId], device.status == .active else { return .notActive }
        guard account.mode != mode else { return .unchanged }
        let eligibleAtMs = device.addedAtMs + E2EEAutoLog.signerMinAgeMs
        guard nowMs >= eligibleAtMs else { return .tooRecent(eligibleAtMs: eligibleAtMs) }
        if mode == .strict && account.devices.values.filter({ $0.status == .active }).count < 2 { return .needsTwoDevices }
        return nil
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

/// Enveloppes de HK par passkey (§5.5) : routes, lecture de la liste et choix
/// de ce que l'app propose. Le sceau et l'ouverture sont dans `E2EEAutoHistory`.
enum E2EEAutoPasskeyContract {
    static let listPath = "/api/e2ee/auto/history-key/passkey-wraps"

    /// `nil` pour un `credentialId` hors format : la requête ne part pas.
    static func path(credentialId: String) -> String? {
        E2EEAutoHistory.isPasskeyCredentialId(credentialId) ? "\(listPath)/\(credentialId)" : nil
    }

    struct Listed: Equatable, Sendable {
        let credentialId: String
        let wrap: E2EEAutoHistory.PasskeyWrap
        /// Vrai si `hkPubB64` est la dernière `HISTORY_KEY` selon le serveur : l'app le recoupe avec son journal.
        let current: Bool
        let updatedAtMs: Int64
    }

    /// Réponse du `GET` aux champs exacts, sinon nil.
    static func parseList(_ data: Data) -> [Listed]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["wraps"],
              let wraps = object["wraps"] as? [[String: Any]] else { return nil }
        var listed: [Listed] = []
        for item in wraps {
            guard Set(item.keys) == ["credentialId", "prfSaltB64", "nonceB64", "wrappedB64", "hkPubB64", "current", "updatedAtMs"],
                  let credentialId = item["credentialId"] as? String, E2EEAutoHistory.isPasskeyCredentialId(credentialId),
                  let current = item["current"] as? Bool, CFGetTypeID(item["current"] as CFTypeRef) == CFBooleanGetTypeID(),
                  let updatedAtText = item["updatedAtMs"] as? String, E2EEV2Canonical.isDecimal(updatedAtText),
                  let updatedAtMs = Int64(updatedAtText),
                  let wrap = E2EEAutoHistory.parsePasskeyWrap(item.filter { ["prfSaltB64", "nonceB64", "wrappedB64", "hkPubB64"].contains($0.key) })
            else { return nil }
            listed.append(Listed(credentialId: credentialId, wrap: wrap, current: current, updatedAtMs: updatedAtMs))
        }
        return listed
    }

    static func putBody(_ wrap: E2EEAutoHistory.PasskeyWrap) throws -> Data {
        try JSONSerialization.data(withJSONObject: wrap.jsonObject, options: [.sortedKeys])
    }

    enum Offer: Equatable, Sendable {
        case none
        /// « Protéger l'historique avec une passkey ».
        case create
        /// « Mettre à jour la passkey » : enveloppes d'une HK précédente (§5.6).
        case update(credentialIds: [String])
    }

    /// Sur iPhone, la passkey apporte peu face au trousseau synchronisé : créée
    /// seulement si le compte a aussi un appareil actif non Apple, et proposée une
    /// fois. Une passkey périmée se met à jour dès que cet appareil détient la
    /// dernière HK du journal (`hkPubB64` recoupé, pas seulement `current`).
    static func offer(
        account: E2EEAutoLog.AccountState, deviceId: String, holdsLatestHistoryKey: Bool, prfAvailable: Bool,
        listed: [Listed], creationDismissed: Bool
    ) -> Offer {
        guard prfAvailable, holdsLatestHistoryKey, let latest = account.historyKeyPubB64,
              account.devices[deviceId]?.status == .active else { return .none }
        let stale = listed.filter { !$0.current || $0.wrap.hkPubB64 != latest }.map(\.credentialId)
        if !stale.isEmpty { return .update(credentialIds: stale.sorted()) }
        guard listed.isEmpty, !creationDismissed else { return .none }
        let hasNonApple = account.devices.values.contains { $0.status == .active && $0.platform != .ios }
        return hasNonApple ? .create : .none
    }
}
