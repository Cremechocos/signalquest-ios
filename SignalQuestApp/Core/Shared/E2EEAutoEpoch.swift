import Foundation

/// Destinataires d'une époque face au journal des appareils (E2EE-AUTO), contrat
/// v2, §7.1 : composition d'un POST d'époque, lecture d'un manifeste et règle
/// d'envoi, sur des journaux déjà vérifiés (`E2EEAutoLog.verifyAccount`). Suit
/// `packages/core/e2ee-auto-epoch.ts` ; le vecteur `epoch-recipients-v1` fait foi.
/// Le contrôle des POST par le serveur n'est pas porté : l'app n'en lit que le
/// `409 E2EE_DEVICE_LIST_STALE` et ses `details.userIds`.
enum E2EEAutoEpoch {
    typealias Recipient = E2EEV2EpochManifest.Recipient

    /// `T` du §7.1 : la tolérance d'horloge du §3.4, bornes incluses.
    static let manifestToleranceMs = E2EEAutoLog.clockToleranceMs

    struct DeviceRef: Hashable, Sendable {
        let userId: String
        let deviceId: String
    }

    /// Empreinte D.0 sur des clés `b64` : `b64url(SHA-256(identityKey ‖ signingKey))`.
    static func fingerprint(identityKeyB64: String, signingKeyB64: String) -> String {
        E2EEV2Canonical.deviceFingerprint(
            identityKeyX963: Data(base64Encoded: identityKeyB64) ?? Data(),
            signingKeyX963: Data(base64Encoded: signingKeyB64) ?? Data()
        )
    }

    /// Empreinte D.0 sur les clés courantes de l'appareil (clé d'accord du dernier `ROTATE`).
    static func recipientFingerprint(_ device: E2EEAutoLog.DeviceState) -> String {
        fingerprint(identityKeyB64: device.identityKeyB64, signingKeyB64: device.signingKeyB64)
    }

    private static func utf8Precedes(_ left: String, _ right: String) -> Bool {
        Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
    }

    /// Composition d'un POST d'époque : tous les appareils `ACTIVE` des membres, sauf
    /// ceux que l'app exclut (appareil d'une partie divergente, §3.5), lignes triées par
    /// octets, et le `lastSeq` de chaque membre. nil si un membre n'a pas de journal
    /// vérifié (vide s'il n'a aucun maillon `ACCOUNT`) : faute d'appel.
    static func compose(
        memberUserIds: [String],
        accounts: [String: E2EEAutoLog.AccountState],
        excluded: Set<DeviceRef> = []
    ) -> (recipients: [Recipient], memberLogSeqs: [String: String])? {
        var recipients: [Recipient] = []
        var memberLogSeqs: [String: String] = [:]
        for userId in Set(memberUserIds).sorted(by: utf8Precedes) {
            guard let account = accounts[userId] else { return nil }
            memberLogSeqs[userId] = String(account.lastSeq)
            for device in account.devices.values
            where device.status == .active && !excluded.contains(DeviceRef(userId: userId, deviceId: device.deviceId)) {
                recipients.append(Recipient(
                    userId: userId, deviceId: device.deviceId, platform: device.platform.rawValue,
                    fingerprint: recipientFingerprint(device)
                ))
            }
        }
        return (recipients.sorted { utf8Precedes($0.line, $1.line) }, memberLogSeqs)
    }

    // MARK: - Lecture d'un manifeste

    enum RecipientError: String, Error, Sendable {
        case notMember = "NOT_MEMBER"
        case deviceUnknown = "DEVICE_UNKNOWN"
        case platform = "PLATFORM"
        case pending = "PENDING"
        case fingerprint = "FINGERPRINT"
        case addedAfterManifest = "ADDED_AFTER_MANIFEST"
        case keyRotated = "KEY_ROTATED"
        case revoked = "REVOKED"

        /// Échecs qu'un journal en retard explique : le lecteur relit le compte avant d'alerter.
        var isRefreshable: Bool { self == .deviceUnknown || self == .pending || self == .fingerprint }
    }

    enum ManifestCheck: Equatable, Sendable {
        case adoptable
        /// Refus de sécurité : l'époque tourne et une ligne de sécurité locale s'affiche.
        case alert(RecipientError, userId: String, deviceId: String)
        /// Journaux de ces comptes à relire et vérifier (§3.5), puis contrôle refait avec
        /// `refreshed`, qui ne passe à vrai qu'après une relecture aboutie à une tête à jour.
        case logBehind(userIds: [String])
        /// Horloge du créateur en avance : l'époque tourne, sans ligne de sécurité.
        case future
        /// `excludesWeb = 1` (époques d'avant la bascule) : l'époque tourne, sans ligne de sécurité.
        case excludesWeb
    }

    private struct Activated {
        let recipient: Recipient
        let device: E2EEAutoLog.DeviceState
        let activatedAtMs: Int64
        let keyVersion: Int
    }

    /// Contrôles d'une ligne qui ne dépendent pas de la date du manifeste.
    private static func shape(_ recipient: Recipient, account: E2EEAutoLog.AccountState?) -> Result<Activated, RecipientError> {
        guard let account, account.userId == recipient.userId else { return .failure(.notMember) }
        guard let device = account.devices[recipient.deviceId] else { return .failure(.deviceUnknown) }
        guard device.platform.rawValue == recipient.platform else { return .failure(.platform) }
        // Jamais activé : en attente, ou révoqué sans ACTIVATE (« Ce n'est pas moi » sur un appareil injecté).
        guard let activatedAtMs = device.activatedAtMs else { return .failure(.pending) }
        guard let key = device.identityKeys.first(where: {
            fingerprint(identityKeyB64: $0.identityKeyB64, signingKeyB64: device.signingKeyB64) == recipient.fingerprint
        }) else { return .failure(.fingerprint) }
        return .success(Activated(recipient: recipient, device: device, activatedAtMs: activatedAtMs, keyVersion: key.keyVersion))
    }

    /// Les seuls contrôles qu'une date de manifeste dans le futur peut tromper : à `manifeste − T` au plus.
    private static func retiredBefore(_ item: Activated, manifestCreatedAtMs: Int64) -> RecipientError? {
        let limit = manifestCreatedAtMs - manifestToleranceMs
        if let next = item.device.identityKeys.first(where: { $0.keyVersion == item.keyVersion + 1 }), next.sinceMs <= limit {
            return .keyRotated
        }
        if let revokedAtMs = item.device.revokedAtMs, revokedAtMs <= limit { return .revoked }
        return nil
    }

    /// Un manifeste d'époque auto déjà vérifié (signature, lignes, condensat) face aux
    /// journaux, dans l'ordre du §7.1 :
    /// 1. `excludesWeb = 1` : non adoptable, sans alerte ;
    /// 2. pour chaque ligne, les contrôles indépendants de la date (membre de l'appartenance
    ///    désignée par le manifeste, appareil connu, plateforme, déjà activé, empreinte d'une
    ///    de ses clés). Un échec définitif alerte aussitôt ; ceux qu'un journal en retard
    ///    explique rendent `logBehind` tant que `refreshed` est faux, puis alertent ;
    /// 3. `ADD` ou `ACTIVATE` au plus à `manifeste + T` ;
    /// 4. date au plus à `T` dans le futur de l'horloge corrigée, sauf ses propres manifestes ;
    /// 5. `ROTATE` et `REVOKE` au plus à `manifeste − T`.
    /// `memberUserIds` : l'appartenance du manifeste (`membershipChangeNumber`), pas la
    /// courante. Une époque refusée reste lisible.
    static func checkManifest(
        createdAtMs: Int64,
        excludesWeb: Bool,
        memberUserIds: [String],
        recipients: [Recipient],
        accounts: [String: E2EEAutoLog.AccountState],
        correctedNowMs: Int64,
        ownManifest: Bool,
        refreshed: Bool
    ) -> ManifestCheck {
        if excludesWeb { return .excludesWeb }
        let members = Set(memberUserIds)
        var checked: [Activated] = []
        var behind: Set<String> = []
        for recipient in recipients {
            // Un membre sans journal vérifié chez le lecteur se lit comme un journal en retard.
            let result = members.contains(recipient.userId)
                ? (accounts[recipient.userId].map { shape(recipient, account: $0) } ?? .failure(.deviceUnknown))
                : .failure(.notMember)
            switch result {
            case let .success(item):
                checked.append(item)
            case let .failure(error) where !refreshed && error.isRefreshable:
                behind.insert(recipient.userId)
            case let .failure(error):
                return .alert(error, userId: recipient.userId, deviceId: recipient.deviceId)
            }
        }
        if !behind.isEmpty { return .logBehind(userIds: behind.sorted(by: utf8Precedes)) }
        if let late = checked.first(where: { $0.activatedAtMs > createdAtMs + manifestToleranceMs }) {
            return .alert(.addedAfterManifest, userId: late.recipient.userId, deviceId: late.recipient.deviceId)
        }
        if !ownManifest && createdAtMs > correctedNowMs + manifestToleranceMs { return .future }
        for item in checked {
            if let retired = retiredBefore(item, manifestCreatedAtMs: createdAtMs) {
                return .alert(retired, userId: item.recipient.userId, deviceId: item.recipient.deviceId)
            }
        }
        return .adoptable
    }

    /// Règle d'envoi (§7.1) : seulement si chaque destinataire est `ACTIVE` dans le journal
    /// vérifié (ni révoqué, ni en attente, ni absent), quelle que soit la date du manifeste.
    static func isSendable(_ recipients: [Recipient], accounts: [String: E2EEAutoLog.AccountState]) -> Bool {
        recipients.allSatisfy { accounts[$0.userId]?.devices[$0.deviceId]?.status == .active }
    }
}
