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
        /// « Retrouver mes messages partout » : une passkey sur cet appareil (§5.5, révision 22).
        case create
        /// « Mettre à jour ma passkey » : enveloppes d'une HK précédente (§5.6).
        case update(credentialIds: [String])
        /// Enveloppes périmées, mais cet appareil est inscrit depuis moins de 24 h (H1) : le
        /// remplacement serait refusé. Rien ne s'affiche ; les réglages disent « Réessaie demain ».
        case updateTomorrow
    }

    /// Ce que l'app propose ici (§5.5, amendement SD2), une fois la dernière HK du journal
    /// détenue (`hkPubB64` recoupé, pas seulement `current`) et le PRF disponible :
    /// - une passkey périmée se met à jour, par un appareil inscrit depuis 24 h (H1) ;
    /// - sinon, la création, sauf si HK est venue par une passkey de ce gestionnaire
    ///   (attachement `platform`) : HK venue par « C'est moi » ou d'une passkey d'un autre
    ///   appareil (`localPasskeyWanted`), ou bien la liste n'a aucune enveloppe à jour (synchro
    ///   du trousseau, HK créée ici). Le « une fois par appareil » est à l'appelant.
    static func offer(
        account: E2EEAutoLog.AccountState, deviceId: String, holdsLatestHistoryKey: Bool, prfAvailable: Bool,
        listed: [Listed], localPasskeyWanted: Bool, nowMs: Int64
    ) -> Offer {
        guard prfAvailable, holdsLatestHistoryKey, let latest = account.historyKeyPubB64,
              let own = account.devices[deviceId], own.status == .active else { return .none }
        let stale = listed.filter { !isCurrent($0, latest: latest) }.map(\.credentialId)
        if !stale.isEmpty {
            return nowMs - own.addedAtMs >= E2EEAutoLog.signerMinAgeMs ? .update(credentialIds: stale.sorted()) : .updateTomorrow
        }
        if localPasskeyWanted { return .create }
        return listed.contains { isCurrent($0, latest: latest) } ? .none : .create
    }

    /// À jour selon le serveur et selon le journal.
    static func isCurrent(_ item: Listed, latest: String) -> Bool {
        item.current && item.wrap.hkPubB64 == latest
    }

    /// Limite des dix enveloppes atteinte : la plus ancienne qui n'est pas à jour
    /// (`updatedAtMs` le plus bas, puis `credentialId`), nil si toutes le sont.
    static func oldestStale(_ listed: [Listed], latest: String?) -> Listed? {
        listed.filter { item in latest.map { !isCurrent(item, latest: $0) } ?? true }
            .min { ($0.updatedAtMs, $0.credentialId) < ($1.updatedAtMs, $1.credentialId) }
    }

    /// `200 { "deleted": true }`.
    static func isDeleted(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["deleted"],
              let deleted = object["deleted"] as? Bool, CFGetTypeID(object["deleted"] as CFTypeRef) == CFBooleanGetTypeID() else { return false }
        return deleted
    }

    static let maxWraps = 10
}
