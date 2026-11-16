import Foundation

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
